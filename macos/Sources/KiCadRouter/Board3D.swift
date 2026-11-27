// Ported from KiCad 10.0.8: 3d-viewer/3d_canvas/board_adapter.cpp (BOARD_ADAPTER: InitSettings, the layers' thicknesses
// from the stackup and their z positions; GetLayerColors and GetDefaultColors, the colours from the stackup or the 3D
// view's defaults; GetDefaultVisibleLayers, Is3dLayerEnabled, IsFootprintShown, GetFootprintZPos, createBoardPolygon),
// 3d-viewer/3d_canvas/create_layer_items.cpp (createLayers: each layer's polygons, as the OpenGL renderer builds them
// with its copper thickness on, the holes' polygons; buildPadOutlineAsPolygon, transformFPShapesToPolySet,
// transformFPTextToPolySet), 3d-viewer/3d_canvas/create_3Dgraphic_brd_items.cpp (createTrackWithMargin: the mask's
// openings over tracks as the viewer draws them), 3d-viewer/3d_rendering/opengl/create_scene.cpp (RENDER_3D_OPENGL::
// reload: each layer clipped to the board and its holes taken out, the board body with its holes;
// generatePlatedHoleShells, generateViaBarrels) and 3d-viewer/3d_rendering/opengl/render_3d_opengl.cpp (Redraw and
// renderSolderMaskLayer: what is drawn where, the solder mask as the board's outline less its openings; the inner
// layers left out under an opaque board; get3dModelsFromFootprint: where a footprint's 3D models go), with
// common/settings/builtin_color_themes.h (the 3D view's default colours), include/gal/color4d.h and common/gal/
// color4d.cpp (COLOR4D's Mix and its colours from "#RRGGBBAA"), pcbnew/board.cpp (GetBoardPolygonOutlines with its
// unplated holes), pcbnew/footprint.cpp (TransformPadsToPolySet), pcbnew/pad.cpp (GetSolderMaskExpansion,
// GetSolderPasteMargin, TransformHoleToPolygon), pcbnew/pcb_track.cpp (TransformShapeToPolygon, IsTented,
// GetSolderMaskExpansion) and pcbnew/pcb_text.cpp (TransformTextToPolySet).
// Copyright (C) 2015-2023 Mario Luzeiro; Copyright (C) 2023 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// A board as KiCad's 3D viewer builds it (BOARD_ADAPTER::InitSettings and createLayers, and what RENDER_3D_OPENGL's
/// reload and Redraw make of them): the board body, each copper, solder mask, silkscreen, paste and adhesive layer and
/// the plated holes as polygons in the board's nanometres (y down, as the board has them), each with the z range KiCad
/// gives it (nanometres, up from the middle of the board) and its colour, and where each footprint's 3D models go.
///
/// KiCad's OpenGL renderer draws a layer's faces from shapes it keeps for each item (round segments, circles,
/// triangles) and its walls from the layer's polygons; these are the polygons (createLayers' with
/// `opengl_copper_thickness` on), clipped and holed as reload clips the walls, with two of the faces' ways where the
/// polygons go another (the solder mask's openings over tracks: `maskOpening`; blind vias' holes in copper). Where the
/// faces and polygons differ in kind the polygons are kept: a dashed line is solid, a hole in copper is as wide as its
/// plating where the faces stop half way.
public struct Board3D {
    /// What the 3D view shows (its LAYER_3D_* flags, those of GetVisibleLayers this port follows)
    public enum Visibility: Hashable, CaseIterable, Sendable {
        case board, platedBarrels, copperTop, copperBottom, silkscreenTop, silkscreenBottom, soldermaskTop, soldermaskBottom
        case solderpaste, adhesive, fpReferences, fpValues, fpText
        case throughHoleModels, smdModels, virtualModels, modelsNotInPosFiles, modelsMarkedDNP
    }

    /// GetDefaultVisibleLayers: everything but the user layers, the models of footprints left out of position files
    /// and those not fitted
    public static let defaultVisible: Set<Visibility> = Set(Visibility.allCases).subtracting([.modelsNotInPosFiles, .modelsMarkedDNP])

    /// The 3D view's settings this port follows (EDA_3D_VIEWER_SETTINGS' render settings, their defaults)
    public struct Settings: Sendable {
        public var visible = Board3D.defaultVisible
        /// use_stackup_colors: the board's, masks' and silkscreens' colours and the copper's finish from the stackup
        public var useStackupColors = true
        public var showZones = true
        /// subtract_mask_from_silk: the silkscreen taken off where the mask is open
        public var subtractMaskFromSilk = false
        /// clip_silk_on_via_annuli: the silkscreen taken off over vias' and plated holes' rings
        public var clipSilkOnViaAnnuli = false
        public init() {}
    }

    /// A COLOR4D: red, green, blue and alpha from 0 to 1
    public struct Color: Sendable, Equatable {
        public var r, g, b, a: Double
        public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double) { (self.r, self.g, self.b, self.a) = (r, g, b, a) }

        /// COLOR4D( wxString ): "#RRGGBB" or "#RRGGBBAA" (SetFromHexString); nil for one it cannot read
        public init?(hex: String) {
            let s = hex.trimmingCharacters(in: .whitespaces)
            guard s.count >= 7, s.hasPrefix("#") else { return nil }
            // (wxSscanf's %lx: the hex digits from the start, as many as there are)
            let digits = s.dropFirst().prefix { $0.isHexDigit }
            guard !digits.isEmpty, let v = UInt64(digits.prefix(16), radix: 16) else { return nil }
            if s.count >= 9 {
                self.init(Double((v >> 24) & 0xFF) / 255, Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255,
                          Double(v & 0xFF) / 255)
            } else {
                self.init(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255, 1)
            }
        }

        /// COLOR4D::Mix: this mixed into `other` by `factor`, this colour's alpha kept
        func mix(_ other: Color, _ factor: Double) -> Color {
            Color(other.r * (1 - factor) + r * factor, other.g * (1 - factor) + g * factor, other.b * (1 - factor) + b * factor, a)
        }

        static let black = Color(0, 0, 0, 1)
        static let clear = Color(0, 0, 0, 0)
    }

    /// The colours the board is drawn in (BOARD_ADAPTER's m_BoardBodyColor and the rest)
    public struct Colors: Sendable, Equatable {
        public var backgroundTop, backgroundBottom, board, copper, silkscreenTop, silkscreenBottom, soldermaskTop, soldermaskBottom,
                   solderpaste: Color
    }

    public enum Kind: Sendable, Equatable {
        case body, copper, soldermask, silkscreen, solderpaste, adhesive, platedHoles, viaBarrel
    }

    /// What is drawn: polygons (nm, the board's coordinates) between two heights (nm, up from the board's middle)
    public struct Slab: Sendable {
        public var kind: Kind
        /// The board layer it is, by its canonical name (nil for the body, the plated holes and a via's barrel)
        public var layer: String?
        public var polygons: PolySet
        public var bottom: Double
        public var top: Double
        public var color: Color
    }

    /// A footprint's 3D model (FP_3DMODEL) and where it goes (get3dModelsFromFootprint)
    public struct Model: Sendable {
        /// The footprint's reference and uuid
        public var reference: String
        public var footprint: String
        /// The file as the footprint names it (its variables not yet filled in)
        public var filename: String
        public var opacity: Double
        /// The model's own millimetres to the scene's (millimetres, x along the board's x, y against the board's y,
        /// z up from the board's middle): a 4x4 matrix, column by column
        public var transform: [Double]
    }

    /// The board layers' z ranges (nm): each layer's bottom and top as InitSettings sets them (a back layer's "top"
    /// below its "bottom", as KiCad has it)
    public private(set) var layerZ: [String: (bottom: Double, top: Double)] = [:]
    /// m_boardBodyThickness3DU and the rest, in nm
    public private(set) var bodyThickness = 0.0, frontCopperThickness = 0.0, backCopperThickness = 0.0
    public private(set) var frontMaskThickness = 0.0, backMaskThickness = 0.0
    public let nonCopperLayerThickness = Double(Board3D.defaultTechLayerThickness)
    public let solderPasteLayerThickness = Double(Board3D.solderPasteLayerThickness)
    public private(set) var colors: Colors
    /// The board's outline as the viewer has it (createBoardPolygon: its unplated holes taken out), and whether it
    /// could be made from the board's edges (a box round them where it could not)
    public private(set) var boardPolygon = PolySet()
    public private(set) var outlineValid = false
    /// The slabs, in the order they are drawn: the layers (copper, then the others), the plated holes and barrels,
    /// the board body, then the masks
    public private(set) var slabs: [Slab] = []
    public private(set) var models: [Model] = []
    /// What the board has that the port does not make, by name (what is drawn then may not be what KiCad draws)
    public private(set) var unsupported: Set<String> = []

    // KiCad's constants (board_adapter.cpp)
    static let defaultBoardThickness = 1_600_000
    static let defaultCopperThickness = 35_000
    /// DEFAULT_TECH_LAYER_THICKNESS: the solder mask's and silkscreen's
    static let defaultTechLayerThickness = 25_000
    static let solderPasteLayerThickness = 40_000
    /// ADVANCED_CFG's m_HoleWallThickness, 0.020 mm (BOARD_DESIGN_SETTINGS::GetHolePlatingThickness)
    public static let holePlatingThickness = 20_000

    let drc: BoardDRC
    var world: BoardWorld { drc.world }
    let settings: Settings
    let maxError: Int
    /// Each copper layer's polygons and the others' (m_layers_poly), by name
    var layerPolys: [String: PolySet] = [:]
    var thODPolys = PolySet(), npthODPolys = PolySet(), viaTHODPolys = PolySet(), viaAnnuliPolys = PolySet()
    var layerHoleOD: [String: PolySet] = [:], layerHoleID: [String: PolySet] = [:]

    /// The 3D view of `board`, its project's JSON in `project` (its design settings' silkscreen line width and maximum
    /// error; nil for KiCad's defaults)
    public init(board: KiCadBoard, project: [String: Any]? = nil, settings: Settings = Settings()) {
        drc = BoardDRC(board: board, project: project)
        self.settings = settings
        maxError = drc.settings.maxError
        colors = Colors(backgroundTop: Color(0.8, 0.8, 0.9, 1), backgroundBottom: Color(0.4, 0.4, 0.5, 1), board: .black, copper: .black,
                        silkscreenTop: .black, silkscreenBottom: .black, soldermaskTop: .black, soldermaskBottom: .black, solderpaste: .black)
        let copper = drc.makeCopper()
        drc.ruleState.copper = copper
        createBoardPolygon()
        initSettings()
        colors = layerColors()
        createLayers(copper, project: project)
        makeSlabs()
        placeModels()
    }

    /// The same, the project read from its file
    public init(board: KiCadBoard, projectURL: URL?, settings: Settings = Settings()) {
        let json = projectURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        self.init(board: board, project: json, settings: settings)
    }

    // MARK: - The layers' names

    /// The board's enabled layers (its (layers ...)), by name
    var enabledLayers: Set<String> { Set((drc.board.root["layers"]?.arguments ?? []).compactMap { $0.text(at: 0) }) }

    /// The copper layers top to bottom (LAYER_RANGE( F_Cu, B_Cu, count )), at least two
    var copperNames: [String] { BoardStackup.copperNames(max(2, world.copperLayers)) }

    static func isFront(_ layer: String) -> Bool { layer.hasPrefix("F.") }
    static func isBack(_ layer: String) -> Bool { layer.hasPrefix("B.") }

    /// Is3dLayerEnabled: the layer on the board, and shown
    func is3dLayerEnabled(_ layer: String, _ flags: Set<Visibility>) -> Bool {
        guard enabledLayers.contains(layer) || copperNames.contains(layer) else { return false }
        switch layer {
        case "B.Cu": return flags.contains(.copperBottom)
        case "F.Cu": return flags.contains(.copperTop)
        case "B.Adhes", "F.Adhes": return flags.contains(.adhesive)
        case "B.Paste", "F.Paste": return flags.contains(.solderpaste)
        case "B.SilkS": return flags.contains(.silkscreenBottom)
        case "F.SilkS": return flags.contains(.silkscreenTop)
        case "B.Mask": return flags.contains(.soldermaskBottom)
        case "F.Mask": return flags.contains(.soldermaskTop)
        // (the inner copper layers, shown as the board shows them: all of them, the port keeping no other)
        case _ where layer.hasSuffix(".Cu"): return true
        // (the user layers are not drawn by this port)
        default: return false
        }
    }

    // MARK: - InitSettings

    /// InitSettings: the layers' thicknesses from the stackup (the body its dielectrics and inner copper, the outer
    /// copper and masks their own, at least a micrometre), then each layer's z
    mutating func initSettings() {
        bodyThickness = Double(Self.defaultBoardThickness)
        frontCopperThickness = Double(Self.defaultCopperThickness)
        backCopperThickness = Double(Self.defaultCopperThickness)
        frontMaskThickness = Double(Self.defaultTechLayerThickness)
        backMaskThickness = Double(Self.defaultTechLayerThickness)
        let stackup = BoardStackup.read(drc.board).stackup
        if !stackup.items.isEmpty {
            var body = 0
            for item in stackup.items {
                switch item.kind {
                case .dielectric:
                    body += item.thickness
                case .copper:
                    let t = max(item.sublayers[0].thickness, 1000)
                    if item.layer == "F.Cu" {
                        frontCopperThickness = Double(t)
                    } else if item.layer == "B.Cu" {
                        backCopperThickness = Double(t)
                    } else if item.enabled {
                        body += t
                    }
                case .solderMask:
                    let t = max(item.sublayers[0].thickness, 1000)
                    if item.layer == "F.Mask" { frontMaskThickness = Double(t) } else if item.layer == "B.Mask" { backMaskThickness = Double(t) }
                default:
                    break
                }
            }
            bodyThickness = Double(body)
        }
        // the copper layers: the front's bottom at half the body up, the others spaced evenly down to the back's,
        // each as thick as the outer layer on its side
        let names = copperNames
        let n = names.count
        for (pos, name) in names.enumerated() {
            let bottom = bodyThickness / 2 - bodyThickness * Double(pos) / Double(n - 1)
            let top = pos < n / 2 ? bottom + frontCopperThickness : bottom - backCopperThickness
            layerZ[name] = (bottom, top)
        }
        // the other layers, from the outer copper's top out
        let offset = nonCopperLayerThickness * 1.1
        let backTop = layerZ["B.Cu"]!.top, frontTop = layerZ["F.Cu"]!.top
        func set(_ layer: String, _ bottom: Double, _ top: Double) { layerZ[layer] = (bottom, top) }
        set("B.Mask", backTop, backTop - backMaskThickness)
        set("B.Paste", backTop, backTop - solderPasteLayerThickness)
        set("F.Mask", frontTop, frontTop + frontMaskThickness)
        set("F.Paste", frontTop, frontTop + solderPasteLayerThickness)
        set("B.SilkS", backTop - offset, backTop - offset - nonCopperLayerThickness)
        set("F.SilkS", frontTop + offset, frontTop + offset + nonCopperLayerThickness)
        for layer in ["B.Adhes", "B.CrtYd", "B.Fab"] { set(layer, backTop - 2 * offset, backTop - 2 * offset - nonCopperLayerThickness) }
        for layer in ["F.Adhes", "F.CrtYd", "F.Fab", "Dwgs.User", "Cmts.User", "Eco1.User", "Eco2.User", "Edge.Cuts", "Margin"] {
            set(layer, frontTop + 2 * offset, frontTop + 2 * offset + nonCopperLayerThickness)
        }
    }

    /// A layer's z range as getLayerZPos takes it: its lower and upper z
    func zRange(_ layer: String) -> (low: Double, high: Double) {
        let z = layerZ[layer]!
        return (min(z.bottom, z.top), max(z.bottom, z.top))
    }

    // MARK: - Colours

    /// The stackup's colour lists (BOARD_ADAPTER's g_SilkColors and the rest)
    static let silkColors: [(String, Color)] = [
        (BoardStackup.notSpecified, Color(245 / 255, 245 / 255, 245 / 255, 1)), ("Green", Color(20 / 255, 51 / 255, 36 / 255, 1)),
        ("Red", Color(181 / 255, 19 / 255, 21 / 255, 1)), ("Blue", Color(2 / 255, 59 / 255, 162 / 255, 1)),
        ("Black", Color(11 / 255, 11 / 255, 11 / 255, 1)), ("White", Color(245 / 255, 245 / 255, 245 / 255, 1)),
        ("Purple", Color(32 / 255, 2 / 255, 53 / 255, 1)), ("Yellow", Color(194 / 255, 195 / 255, 0, 1)),
    ]
    static let maskColors: [(String, Color)] = [
        (BoardStackup.notSpecified, Color(20 / 255, 51 / 255, 36 / 255, 0.83)), ("Green", Color(20 / 255, 51 / 255, 36 / 255, 0.83)),
        ("Light Green", Color(91 / 255, 168 / 255, 12 / 255, 0.83)), ("Saturated Green", Color(13 / 255, 104 / 255, 11 / 255, 0.83)),
        ("Red", Color(181 / 255, 19 / 255, 21 / 255, 0.83)), ("Light Red", Color(210 / 255, 40 / 255, 14 / 255, 0.83)),
        ("Red/Orange", Color(239 / 255, 53 / 255, 41 / 255, 0.83)), ("Blue", Color(2 / 255, 59 / 255, 162 / 255, 0.83)),
        ("Light Blue 1", Color(54 / 255, 79 / 255, 116 / 255, 0.83)), ("Light Blue 2", Color(61 / 255, 85 / 255, 130 / 255, 0.83)),
        ("Green/Blue", Color(21 / 255, 70 / 255, 80 / 255, 0.83)), ("Black", Color(11 / 255, 11 / 255, 11 / 255, 0.83)),
        ("White", Color(245 / 255, 245 / 255, 245 / 255, 0.83)), ("Purple", Color(32 / 255, 2 / 255, 53 / 255, 0.83)),
        ("Light Purple", Color(119 / 255, 31 / 255, 91 / 255, 0.83)), ("Yellow", Color(194 / 255, 195 / 255, 0, 0.83)),
    ]
    static let finishColors: [(String, Color)] = [
        ("Copper", Color(184 / 255, 115 / 255, 50 / 255, 1)), ("Gold", Color(178 / 255, 156 / 255, 0, 1)),
        ("Silver", Color(213 / 255, 213 / 255, 213 / 255, 1)), ("Tin", Color(160 / 255, 160 / 255, 160 / 255, 1)),
    ]
    static let boardColors: [(String, Color)] = [
        ("FR4 natural, dark", Color(51 / 255, 43 / 255, 22 / 255, 0.83)), ("FR4 natural", Color(109 / 255, 116 / 255, 75 / 255, 0.83)),
        ("PTFE natural", Color(252 / 255, 252 / 255, 250 / 255, 0.90)), ("Polyimide", Color(205 / 255, 130 / 255, 0, 0.68)),
        ("Phenolic natural", Color(92 / 255, 17 / 255, 6 / 255, 0.90)), ("Brown 1", Color(146 / 255, 99 / 255, 47 / 255, 0.83)),
        ("Brown 2", Color(160 / 255, 123 / 255, 54 / 255, 0.83)), ("Brown 3", Color(146 / 255, 99 / 255, 47 / 255, 0.83)),
        ("Aluminum", Color(213 / 255, 213 / 255, 213 / 255, 1)),
    ]

    /// GetLayerColors with no preset of the user's: the default colour theme's 3D colours, then, where the view uses
    /// the stackup's, the silkscreens', masks' and dielectrics' colours (the dielectrics mixed, each over the ones
    /// above it) and the copper's finish
    func layerColors() -> Colors {
        // (builtin_color_themes.h's LAYER_3D_* colours)
        var c = Colors(backgroundTop: Color(0.8, 0.8, 0.9, 1), backgroundBottom: Color(0.4, 0.4, 0.5, 1), board: Color(0.2, 0.17, 0.09, 0.9),
                       copper: Color(0.7, 0.61, 0.0, 1), silkscreenTop: Color(0.9, 0.9, 0.9, 1), silkscreenBottom: Color(0.9, 0.9, 0.9, 1),
                       soldermaskTop: Color(0.08, 0.2, 0.14, 0.83), soldermaskBottom: Color(0.08, 0.2, 0.14, 0.83),
                       solderpaste: Color(0.5, 0.5, 0.5, 1))
        guard settings.useStackupColors else { return c }
        let stackup = BoardStackup.read(drc.board).stackup
        func find(_ name: String, _ list: [(String, Color)]) -> Color {
            if name.hasPrefix("#") { return Color(hex: name) ?? .black }
            return list.first { $0.0 == name }?.1 ?? .black
        }
        var body = Color.clear
        for item in stackup.items {
            let name = item.sublayers[0].color
            switch item.kind {
            case .silkscreen:
                if item.layer == "F.SilkS" { c.silkscreenTop = find(name, Self.silkColors) } else { c.silkscreenBottom = find(name, Self.silkColors) }
            case .solderMask:
                if item.layer == "F.Mask" { c.soldermaskTop = find(name, Self.maskColors) } else { c.soldermaskBottom = find(name, Self.maskColors) }
            case .dielectric:
                let layer = find(name, Self.boardColors)
                body = body == .clear ? layer : body.mix(layer, 1 - layer.a)
                body.a += (1 - body.a) * layer.a / 2
            default:
                break
            }
        }
        if body != .clear { c.board = body }
        let finish = stackup.finish
        if finish.hasSuffix("OSP") {
            c.copper = find("Copper", Self.finishColors)
        } else if finish.hasSuffix("IG") || finish.hasSuffix("gold") {
            c.copper = find("Gold", Self.finishColors)
        } else if finish.hasPrefix("HAL") || finish.hasPrefix("HASL") || finish.hasSuffix("tin") || finish.hasSuffix("nickel") {
            c.copper = find("Tin", Self.finishColors)
        } else if finish.hasSuffix("silver") {
            c.copper = find("Silver", Self.finishColors)
        }
        return c
    }

    // MARK: - The board's outline

    /// createBoardPolygon: GetBoardPolygonOutlines( poly, true, nullptr, false, true ): the outline of the board's
    /// edges (a box round them where it cannot be made), each unplated pad's hole taken out of it, simplified
    mutating func createBoardPolygon() {
        var outlines = PolySet()
        var errors: [BoardDRC.OutlineError]?
        var success = drc.buildBoardPolygonOutlines(drc.edgeCuts(), maxError: maxError, &outlines, &errors)
        if !success || outlines.outlineCount == 0 {
            success = false
            // GetBoardEdgesBoundingBox: the board's and its footprints' drawings on Edge.Cuts, by their boxes
            var box: IBox?
            func merge(_ node: SExpr, _ placement: BoardWorld.FootprintPlacement?) {
                guard node.value("layer") == "Edge.Cuts", let o = world.outlineShape(node, placement: placement) else { return }
                let b = BoardDRC.drawingBox(o, filled: BoardDRC.solidFill(node), maxError: maxError).0
                if box == nil { box = b } else { box!.merge(b) }
            }
            for node in drc.board.root.items where Self.boardDrawingHeads.contains(node.head ?? "") { merge(node, nil) }
            for fp in drc.board.root.all("footprint") {
                let placement = BoardWorld.FootprintPlacement(fp)
                for node in fp.items where BoardWorld.footprintShapeHeads.contains(node.head ?? "") { merge(node, placement) }
            }
            if box == nil || box!.width == 0 || box!.height == 0 {
                // (ComputeBoundingBox of everything on the board, which the port does not make)
                unsupported.insert("board outline inferred from its items")
                box = box ?? IBox(minX: 0, minY: 0, maxX: 0, maxY: 0)
                if box!.width == 0 || box!.height == 0 { box = box!.inflated(1_000_000) }
            }
            let b = box!
            outlines = PolySet()
            outlines.newOutline()
            for p in [IPoint(b.minX, b.minY), IPoint(b.minX, b.maxY), IPoint(b.maxX, b.maxY), IPoint(b.maxX, b.minY)] { outlines.append(p) }
        }
        outlines.simplify()
        for (i, fp) in drc.board.root.all("footprint").enumerated() {
            for (j, _) in fp.all("pad").enumerated() {
                let p = drc.footprints[i].pads[j]
                guard p.pad.attribute == .npth else { continue }
                let hole = holePolygon(p.pad, 0)
                if hole.outlineCount > 0 { outlines.booleanSubtract(hole) }
            }
        }
        outlines.simplify()
        boardPolygon = outlines
        outlineValid = success
    }

    static let boardDrawingHeads: Set<String> = ["gr_line", "gr_rect", "gr_arc", "gr_circle", "gr_poly", "gr_curve"]

    // MARK: - The items' polygons

    /// PAD::TransformHoleToPolygon: the hole as an oval grown by `clearance`, the error inside
    func holePolygon(_ p: BoardWorld.Pad, _ clearance: Int) -> PolySet {
        guard p.drill.x > 0 && p.drill.y > 0, case .segment(let s, let w) = world.holeShape(p) else { return PolySet() }
        return PadPolygon.oval(start: s.a, end: s.b, width: w + clearance * 2, maxError: maxError, errorLocation: .inside)
    }

    /// PAD::GetSolderMaskExpansion on a mask layer: none for a pad on no copper; the pad's, its footprint's or the
    /// board's, no less than half its size's lesser side taken off
    func padMaskExpansion(_ p: BoardDRC.Pad, _ node: SExpr, _ fp: SExpr) -> Int {
        guard !world.copper(p.pad.layers).isEmpty else { return 0 }
        let boardMargin = drc.board.root["setup"]?["pad_to_mask_clearance"].map { BoardWorld.iu($0, 0) } ?? 0
        var margin = node["solder_mask_margin"].map { BoardWorld.iu($0, 0) } ?? fp["solder_mask_margin"].map { BoardWorld.iu($0, 0) } ?? boardMargin
        if margin < 0 { margin = max(margin, -min(p.pad.size.x, p.pad.size.y) / 2) }
        return margin
    }

    /// PAD::GetSolderPasteMargin on a paste layer: none for a pad on no copper; the pad's, its footprint's or the
    /// board's margin plus its ratio of the pad's size, no less than half the size taken off (but for a custom pad)
    func padPasteMargin(_ p: BoardDRC.Pad, _ node: SExpr, _ fp: SExpr) -> IPoint {
        guard !world.copper(p.pad.layers).isEmpty else { return .zero }
        let setup = drc.board.root["setup"]
        let margin = node["solder_paste_margin"].map { BoardWorld.iu($0, 0) } ?? fp["solder_paste_margin"].map { BoardWorld.iu($0, 0) }
            ?? setup?["pad_to_paste_clearance"].map { BoardWorld.iu($0, 0) } ?? 0
        let ratio = node["solder_paste_margin_ratio"]?.number(at: 0) ?? fp["solder_paste_margin_ratio"]?.number(at: 0)
            ?? setup?["pad_to_paste_clearance_ratio"]?.number(at: 0) ?? 0
        var out = IPoint(margin + KiMath.round(Double(p.pad.size.x) * ratio), margin + KiMath.round(Double(p.pad.size.y) * ratio))
        if p.pad.kind != .custom {
            if out.x < -p.pad.size.x / 2 { out.x = -p.pad.size.x / 2 }
            if out.y < -p.pad.size.y / 2 { out.y = -p.pad.size.y / 2 }
        }
        return out
    }

    /// One pad of FOOTPRINT::TransformPadsToPolySet on a layer: grown by its mask expansion on a mask layer and its
    /// paste margin on a paste layer; where the growth is negative or not the same both ways (and the pad not custom),
    /// a pad that much larger made instead
    mutating func padOnLayer(_ p: BoardDRC.Pad, _ node: SExpr, _ fp: SExpr, _ layer: String, _ out: inout PolySet) {
        var clearance = IPoint.zero
        if layer.hasSuffix(".Mask") {
            let m = padMaskExpansion(p, node, fp)
            clearance = IPoint(m, m)
        } else if layer.hasSuffix(".Paste") {
            clearance = padPasteMargin(p, node, fp)
        }
        var pad = p.pad
        var grow = clearance.x
        if (clearance.x < 0 || clearance.x != clearance.y) && pad.kind != .custom {
            let size = pad.size + clearance + clearance
            guard size.x > 0 && size.y > 0 else { return }
            pad.size = size
            grow = 0
        }
        guard let poly = world.padPolygon(pad, primitives: p.primitives, errorLocation: .inside, clearance: grow, arcError: maxError) else {
            unsupported.insert("custom pad curve or old arc")
            return
        }
        out.append(poly)
    }

    /// buildPadOutlineAsPolygon: a pad drawn on a silkscreen as its outline: a ring for a round pad, the sides of its
    /// polygon (the error inside) for any other, as lines `width` wide
    mutating func padOutline(_ p: BoardDRC.Pad, _ width: Int, _ out: inout PolySet) {
        if p.pad.kind == .circle {
            out.append(PadPolygon.ring(center: p.pad.shapePos, radius: p.pad.size.x / 2, width: width, maxError: maxError,
                                       errorLocation: .inside))
            return
        }
        guard let poly = world.padPolygon(p.pad, primitives: p.primitives, errorLocation: .inside, arcError: maxError),
              let path = poly.polygons.first?.first else {
            unsupported.insert("custom pad curve or old arc")
            return
        }
        let pts = path.points
        for i in pts.indices {
            out.append(PadPolygon.oval(start: pts[i], end: pts[(i + 1) % pts.count], width: width, maxError: maxError, errorLocation: .inside))
        }
    }

    /// A drawing's TransformShapeToPolySet, grown by `margin` (nil for one the port does not make)
    mutating func shapePolygon(_ node: SExpr, placement: BoardWorld.FootprintPlacement?, margin: Int) -> PolySet? {
        if let fill = node["fill"], let v = fill.text(at: 0) ?? fill["type"]?.text(at: 0), v.hasSuffix("hatch") {
            // (TransformShapeToPolySet draws a hatched fill's hatching, which the port does not make: drawn solid)
            unsupported.insert("hatched drawing")
        }
        guard let poly = drc.drawingPolygon(node, placement: placement, maxError: maxError, errorLocation: .inside, clearance: margin) else {
            unsupported.insert("drawing in the oldest format")
            return nil
        }
        return poly
    }

    /// PCB_TEXT::TransformTextToPolySet: its strokes, each an oval of the pen's width (the error inside), united
    mutating func textPolygon(_ node: SExpr, footprint: SExpr?) -> PolySet? {
        var reason: String?
        guard let t = BoardWorld.textStrokes(node, footprint: footprint, unsupported: { reason = $0 }) else {
            unsupported.insert(reason ?? "text")
            return nil
        }
        var poly = PolySet()
        for s in t.segments { poly.append(PadPolygon.oval(start: s.a, end: s.b, width: t.width, maxError: maxError, errorLocation: .inside)) }
        poly.simplify()
        return poly
    }

    /// Whether a drawing is on a layer (BOARD_ITEM::IsOnLayer: its layer, and a copper drawing's mask layer where its
    /// layers have it), and whether it has a solder mask of its own (PCB_SHAPE::HasSolderMask)
    static func drawingLayers(_ node: SExpr) -> (layers: [String], hasMask: Bool) {
        let names = node["layers"]?.arguments.map(\.text) ?? node.value("layer").map { [$0] } ?? []
        guard let first = names.first else { return ([], false) }
        var layers = [first]
        var mask = false
        if first == "F.Cu" && names.contains("F.Mask") { layers.append("F.Mask"); mask = true }
        if first == "B.Cu" && names.contains("B.Mask") { layers.append("B.Mask"); mask = true }
        return (layers, mask)
    }

    /// PCB_SHAPE::GetSolderMaskExpansion: its own margin or the board's, no less than half its width taken off unless
    /// it is filled
    func shapeMaskExpansion(_ node: SExpr) -> Int {
        let boardMargin = drc.board.root["setup"]?["pad_to_mask_clearance"].map { BoardWorld.iu($0, 0) } ?? 0
        var margin = node["solder_mask_margin"].map { BoardWorld.iu($0, 0) } ?? boardMargin
        if margin < 0 && !BoardDRC.solidFill(node) {
            let width = node["stroke"]?["width"].map { BoardWorld.iu($0, 0) } ?? node["width"].map { BoardWorld.iu($0, 0) } ?? 0
            margin = max(margin, -width / 2)
        }
        return margin
    }

    /// transformFPTextToPolySet: a footprint's texts on the layer, then its fields shown on it
    mutating func footprintTexts(_ fp: SExpr, _ layer: String, _ flags: Set<Visibility>, _ out: inout PolySet) {
        for node in fp.items {
            if node.head == "fp_text", let kind = node.text(at: 0), kind != "reference", kind != "value" {
                guard flags.contains(.fpText) else { continue }
                let text = node.text(at: 1) ?? ""
                if text == "${REFERENCE}" && !flags.contains(.fpReferences) { continue }
                if text == "${VALUE}" && !flags.contains(.fpValues) { continue }
                if node.value("layer") == layer, let p = textPolygon(node, footprint: fp) { out.append(p) }
            } else if ["fp_text_box", "table", "barcode"].contains(node.head ?? ""), node.value("layer") == layer {
                unsupported.insert("footprint text box, table or barcode")
            }
        }
        for (name, node) in Self.fields(fp) {
            guard flags.contains(.fpText) else { continue }
            if name == "Reference" && !flags.contains(.fpReferences) { continue }
            if name == "Value" && !flags.contains(.fpValues) { continue }
            // (a hidden field is passed over before its text is made, as IsVisible is asked first)
            guard node.value("layer") == layer, !Self.hiddenField(node) else { continue }
            var reason: String?
            guard let t = BoardWorld.textStrokes(node, footprint: fp, unsupported: { reason = $0 }) else {
                unsupported.insert(reason ?? "text")
                continue
            }
            guard t.visible, let p = textPolygon(node, footprint: fp) else { continue }
            out.append(p)
        }
    }

    /// Whether a field is hidden as KiCad reads it: (hide yes), or a bare hide in it or in its effects
    static func hiddenField(_ node: SExpr) -> Bool {
        func hidden(_ n: SExpr) -> Bool? {
            var out: Bool?
            for item in n.items {
                if item.kind == .symbol, item.text == "hide" { out = true }
                if item.head == "hide" { out = !(item.text(at: 0) == "no" || item.text(at: 0) == "false") }
            }
            return out
        }
        return node["effects"].flatMap(hidden) ?? hidden(node) ?? false
    }

    /// A footprint's fields (GetFields): the four every footprint has, then the user's, each as last read
    static func fields(_ fp: SExpr) -> [(String, SExpr)] {
        var fields: [(name: String, node: SExpr?)] = ["Reference", "Value", "Datasheet", "Description"].map { ($0, nil) }
        for node in fp.items {
            var name: String?
            if node.head == "property", let n = node.text(at: 0), n != "ki_fp_filters" && n != "Footprint" { name = n }
            if node.head == "fp_text", node.text(at: 0) == "reference" { name = "Reference" }
            if node.head == "fp_text", node.text(at: 0) == "value" { name = "Value" }
            guard let name else { continue }
            if let k = fields.firstIndex(where: { $0.name == name }) { fields[k].node = node } else { fields.append((name, node)) }
        }
        return fields.compactMap { f in f.node.map { (f.name, $0) } }
    }

    /// transformFPShapesToPolySet: a footprint's drawings on the layer, those with a mask of their own grown by its
    /// expansion on a mask layer
    mutating func footprintShapes(_ fp: SExpr, _ layer: String, _ out: inout PolySet) {
        let placement = BoardWorld.FootprintPlacement(fp)
        for node in fp.items {
            let head = node.head ?? ""
            if BoardWorld.footprintShapeHeads.contains(head) {
                let (layers, hasMask) = Self.drawingLayers(node)
                guard layers.contains(layer) else { continue }
                let margin = layer.hasSuffix(".Mask") && hasMask ? shapeMaskExpansion(node) : 0
                if let p = shapePolygon(node, placement: placement, margin: margin) { out.append(p) }
            } else if head == "dimension" || head == "barcode", Self.drawingLayers(node).layers.contains(layer) {
                unsupported.insert("dimension or barcode")
            }
        }
    }

    /// The board's drawings and texts on the layer (m_board->Drawings()), as createLayers adds them to a layer's
    /// polygons
    mutating func boardDrawings(_ layer: String, _ out: inout PolySet) {
        for node in drc.board.root.items {
            let head = node.head ?? ""
            if Self.boardDrawingHeads.contains(head) {
                let (layers, hasMask) = Self.drawingLayers(node)
                guard layers.contains(layer) else { continue }
                let margin = layer.hasSuffix(".Mask") && hasMask ? shapeMaskExpansion(node) : 0
                if let p = shapePolygon(node, placement: nil, margin: margin) { out.append(p) }
            } else if head == "gr_text" {
                guard node.value("layer") == layer, let p = textPolygon(node, footprint: nil) else { continue }
                out.append(p)
            } else if ["gr_text_box", "dimension", "table", "barcode"].contains(head) {
                let names = node["layers"]?.arguments.map(\.text) ?? node.value("layer").map { [$0] } ?? []
                if names.contains(layer) { unsupported.insert("board text box, dimension, table or barcode") }
            }
        }
    }

    /// TransformSolidAreasShapesToPolygon of the board's zones on the layer (BOARD::Zones: not the footprints'): their
    /// fills as the file has them
    func zoneFills(_ layer: String, _ out: inout PolySet) {
        for zone in drc.board.root.all("zone") {
            guard zone["keepout"] == nil, drc.layerSet(zone).contains(layer) else { continue }
            for fill in zone.all("filled_polygon") where fill.value("layer") == layer {
                let pts = (fill["pts"]?.arguments ?? []).filter { $0.head == "xy" }.map { BoardWorld.point($0) }
                guard pts.count >= 3 else { continue }
                out.addOutline(LineChain(pts, closed: true))
            }
        }
    }

    // MARK: - createLayers

    mutating func createLayers(_ copper: BoardDRC.Copper, project: [String: Any]?) {
        let flags = settings.visible
        let board = drc.board
        let byUUID = Dictionary(copper.items.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        var trackNodes: [String: SExpr] = [:]
        for node in board.root.items where ["segment", "arc", "via"].contains(node.head ?? "") {
            if let u = node.value("uuid") { trackNodes[u] = node }
        }
        // the tracks and vias (tracks on layers not shown left out)
        let trackList = drc.tracks.filter { $0.kind == .via || is3dLayerEnabled($0.layer, flags) }
        let layerIDs = copperNames.filter { is3dLayerEnabled($0, flags) }
        let plating = Self.holePlatingThickness
        let fps = board.root.all("footprint")
        func layerIndex(_ name: String) -> Int? { world.layerIndex[name] }
        func viaOn(_ t: BoardDRC.Track, _ layer: String) -> Bool {
            guard let l = layerIndex(layer) else { return false }
            return l >= t.layers.start && l <= t.layers.end
        }
        func viaFlashed(_ t: BoardDRC.Track, _ layer: String) -> Bool {
            guard let l = layerIndex(layer), let item = byUUID[t.uuid] else { return false }
            return item.flashed.contains(l)
        }

        // the vias' holes: a blind or buried via's on each layer it is on, a through via's once
        for layer in layerIDs {
            var od = PolySet(), id = PolySet()
            for t in trackList where t.kind == .via && viaOn(t, layer) {
                let outer = t.drill / 2 + plating
                if t.viaType != .through {
                    od.addOutline(PadPolygon.circle(center: t.start, radius: outer, maxError: maxError, errorLocation: .inside))
                    id.addOutline(PadPolygon.circle(center: t.start, radius: t.drill / 2, maxError: maxError, errorLocation: .inside))
                } else if layer == layerIDs[0] {
                    let ring = KiMath.round(Double(t.diameter) / 2)
                    thODPolys.addOutline(PadPolygon.circle(center: t.start, radius: outer, maxError: maxError, errorLocation: .inside))
                    viaTHODPolys.addOutline(PadPolygon.circle(center: t.start, radius: outer, maxError: maxError, errorLocation: .inside))
                    if settings.clipSilkOnViaAnnuli {
                        viaAnnuliPolys.addOutline(PadPolygon.circle(center: t.start, radius: ring, maxError: maxError, errorLocation: .inside))
                    }
                }
                if let node = trackNodes[t.uuid], ["backdrill", "tertiary_drill", "front_post_machining", "back_post_machining"]
                    .contains(where: { node[$0] != nil }) {
                    unsupported.insert("backdrilled or post-machined via")
                }
            }
            layerHoleOD[layer] = od
            layerHoleID[layer] = id
        }

        // each copper layer: its tracks and vias, its footprints' pads, texts and drawings, the board's drawings and
        // texts, its zones
        for layer in layerIDs {
            var poly = PolySet()
            for t in trackList {
                switch t.kind {
                case .via:
                    guard viaOn(t, layer), viaFlashed(t, layer) else { continue }
                    poly.addOutline(PadPolygon.circle(center: t.start, radius: t.diameter / 2, maxError: maxError, errorLocation: .inside))
                case .arc:
                    guard t.layer == layer else { continue }
                    poly.append(PadPolygon.arc(start: t.start, mid: t.mid, end: t.end, width: t.width, maxError: maxError, errorLocation: .inside))
                case .track:
                    guard t.layer == layer else { continue }
                    poly.append(PadPolygon.oval(start: t.start, end: t.end, width: t.width, maxError: maxError, errorLocation: .inside))
                }
            }
            for (i, fp) in fps.enumerated() {
                for (j, node) in fp.all("pad").enumerated() {
                    // (PAD::FlashLayer)
                    guard let l = layerIndex(layer), copper.footprintPads[i][j].flashed.contains(l) else { continue }
                    padOnLayer(drc.footprints[i].pads[j], node, fp, layer, &poly)
                }
                footprintTexts(fp, layer, flags, &poly)
                footprintShapes(fp, layer, &poly)
            }
            boardDrawings(layer, &poly)
            if settings.showZones { zoneFills(layer, &poly) }
            poly.simplify()
            layerPolys[layer] = poly
        }

        // the pads' holes: a plated one grown by the plating, an unplated one as it is
        for (i, fp) in fps.enumerated() {
            for (j, node) in fp.all("pad").enumerated() {
                let p = drc.footprints[i].pads[j]
                guard p.hasHole else { continue }
                if p.pad.attribute != .npth {
                    if settings.clipSilkOnViaAnnuli { viaAnnuliPolys.append(holePolygon(p.pad, plating)) }
                    thODPolys.append(holePolygon(p.pad, plating))
                } else {
                    if settings.clipSilkOnViaAnnuli { viaAnnuliPolys.append(holePolygon(p.pad, 0)) }
                    npthODPolys.append(holePolygon(p.pad, 0))
                }
                if ["backdrill", "tertiary_drill", "front_post_machining", "back_post_machining"].contains(where: { node[$0] != nil }) {
                    unsupported.insert("backdrilled or post-machined pad")
                }
            }
        }
        thODPolys.simplify()
        npthODPolys.simplify()
        viaTHODPolys.simplify()
        viaAnnuliPolys.simplify()

        // the technical layers
        let techLayers = ["B.Adhes", "F.Adhes", "B.Paste", "F.Paste", "B.SilkS", "F.SilkS", "B.Mask", "F.Mask"]
        var enabledFlags = flags
        if settings.subtractMaskFromSilk { enabledFlags.formUnion([.soldermaskTop, .soldermaskBottom]) }
        let ds = (project?["board"] as? [String: Any])?["design_settings"] as? [String: Any]
        let silkWidth = ((ds?["defaults"] as? [String: Any])?["silk_line_width"] as? NSNumber).map { BoardWorld.iuScaled($0.doubleValue) } ?? 100_000
        let boardMaskExpansion = board.root["setup"]?["pad_to_mask_clearance"].map { BoardWorld.iu($0, 0) } ?? 0
        let tenting = BoardDRC.frontBack(board.root["setup"]?["tenting"])
        for layer in techLayers {
            guard is3dLayerEnabled(layer, enabledFlags) else { continue }
            var poly = PolySet()
            boardDrawings(layer, &poly)
            if layer == "F.Mask" || layer == "B.Mask" {
                // the mask's openings over vias not tented and over tracks with a mask of their own (as the viewer
                // draws them, createTrackWithMargin: a track's opening its own expansion wide, only on its own side)
                let front = layer == "F.Mask"
                let copperLayer = front ? "F.Cu" : "B.Cu"
                for t in drc.tracks {
                    let node = trackNodes[t.uuid]
                    if t.kind == .via {
                        let tent = BoardDRC.frontBack(node?["tenting"])
                        let tented = front ? (tent.front ?? tenting.front ?? false) : (tent.back ?? tenting.back ?? false)
                        // (PCB_VIA::IsOnLayer of a mask layer: not tented, and spanning that side's copper)
                        guard !tented, viaOn(t, copperLayer), viaFlashed(t, copperLayer) else { continue }
                        poly.addOutline(PadPolygon.circle(center: t.start, radius: t.diameter / 2 + boardMaskExpansion, maxError: maxError,
                                                          errorLocation: .inside))
                    } else {
                        let names = node?["layers"]?.arguments.map(\.text) ?? []
                        guard t.layer == copperLayer, names.contains(layer) else { continue }
                        var margin = node?["solder_mask_margin"].map { BoardWorld.iu($0, 0) } ?? boardMaskExpansion
                        if margin < 0 { margin = max(margin, -t.width / 2) }
                        let width = t.width + 2 * margin
                        if t.kind == .arc {
                            poly.append(PadPolygon.arc(start: t.start, mid: t.mid, end: t.end, width: width, maxError: maxError,
                                                       errorLocation: .inside))
                        } else {
                            poly.append(PadPolygon.oval(start: t.start, end: t.end, width: width, maxError: maxError, errorLocation: .inside))
                        }
                    }
                }
            }
            for (i, fp) in fps.enumerated() {
                for (j, node) in fp.all("pad").enumerated() {
                    let p = drc.footprints[i].pads[j]
                    guard drc.layerSet(node).contains(layer) else { continue }
                    if layer.hasSuffix(".SilkS") {
                        padOutline(p, silkWidth, &poly)
                    } else {
                        padOnLayer(p, node, fp, layer, &poly)
                    }
                }
                footprintTexts(fp, layer, flags, &poly)
                footprintShapes(fp, layer, &poly)
            }
            if settings.showZones || layer.hasSuffix(".Mask") { zoneFills(layer, &poly) }
            poly.simplify()
            layerPolys[layer] = poly
        }
        for layer in layerIDs {
            layerHoleOD[layer]?.simplify()
            layerHoleID[layer]?.simplify()
        }
        if trackNodes.values.contains(where: { $0["padstack"] != nil }) || fps.contains(where: { $0.all("pad").contains { $0["padstack"] != nil } }) {
            unsupported.insert("padstack")
        }
        if board.root.all("via").contains(where: { $0["capping"] != nil || $0["covering"] != nil || $0["plugging"] != nil || $0["filling"] != nil }) {
            unsupported.insert("via capping, covering, plugging or filling")
        }
    }

    // MARK: - reload and Redraw: what is drawn

    mutating func makeSlabs() {
        let flags = settings.visible
        var out: [Slab] = []
        // the layers (m_layers, by layer id: copper first)
        let showBoard = flags.contains(.board)
        for layer in copperNames where layerPolys[layer] != nil && is3dLayerEnabled(layer, flags) {
            // (Redraw: the inner layers not drawn under a board this opaque)
            if layer != "F.Cu" && layer != "B.Cu" && showBoard && colors.board.a > 0.8 { continue }
            var poly = layerPolys[layer]!
            poly.booleanIntersection(boardPolygon)
            poly.booleanSubtract(thODPolys)
            poly.booleanSubtract(npthODPolys)
            // (the faces: a blind or buried via's hole taken out of the layers it is on)
            if let od = layerHoleOD[layer], od.outlineCount > 0 { poly.booleanSubtract(od) }
            let z = zRange(layer)
            out.append(Slab(kind: .copper, layer: layer, polygons: poly, bottom: z.low, top: z.high, color: colors.copper))
        }
        for layer in ["F.Paste", "B.Paste", "F.SilkS", "B.SilkS", "F.Adhes", "B.Adhes"] where layerPolys[layer] != nil && is3dLayerEnabled(layer, flags) {
            var poly = layerPolys[layer]!
            poly.booleanIntersection(boardPolygon)
            let silk = layer.hasSuffix(".SilkS")
            if silk && settings.clipSilkOnViaAnnuli {
                poly.booleanSubtract(viaAnnuliPolys)
            } else {
                poly.booleanSubtract(thODPolys)
            }
            poly.booleanSubtract(npthODPolys)
            if silk && settings.subtractMaskFromSilk, let mask = layerPolys[layer == "F.SilkS" ? "F.Mask" : "B.Mask"] {
                poly.booleanSubtract(mask)
            }
            let z = zRange(layer)
            let kind: Kind = silk ? .silkscreen : layer.hasSuffix(".Paste") ? .solderpaste : .adhesive
            let color: Color
            switch layer {
            case "F.SilkS": color = colors.silkscreenTop
            case "B.SilkS": color = colors.silkscreenBottom
            case "F.Paste", "B.Paste": color = colors.solderpaste
            // (setLayerMaterial: an adhesive layer in the board editor's colour, which the port does not keep)
            default: color = Color(0.85, 0.85, 0.85, 1)
            }
            out.append(Slab(kind: kind, layer: layer, polygons: poly, bottom: z.low, top: z.high, color: color))
        }
        // the plated holes' walls (generatePlatedHoleShells), from the front copper's top to the back's bottom
        if flags.contains(.platedBarrels) {
            var outer = PolySet(), inner = PolySet()
            let plating = Self.holePlatingThickness
            for t in drc.tracks where t.kind == .via && t.viaType == .through {
                outer.addOutline(PadPolygon.circle(center: t.start, radius: t.drill / 2 + plating, maxError: maxError, errorLocation: .inside))
                inner.addOutline(PadPolygon.circle(center: t.start, radius: t.drill / 2, maxError: maxError, errorLocation: .inside))
            }
            for f in drc.footprints {
                for p in f.pads where p.pad.attribute != .npth && p.hasHole {
                    outer.append(holePolygon(p.pad, plating))
                    inner.append(holePolygon(p.pad, 0))
                }
            }
            if outer.outlineCount > 0 {
                outer.booleanSubtract(inner)
                // (less the anti-board: what of the board's outline they are in)
                outer.booleanIntersection(boardPolygon)
                out.append(Slab(kind: .platedHoles, layer: nil, polygons: outer, bottom: zRange("B.Cu").low, top: zRange("F.Cu").high,
                                color: colors.copper))
            }
            // a blind or buried via's barrel (generateViaBarrels), from its top layer's top to its bottom layer's
            // bottom
            for t in drc.tracks where t.kind == .via && t.viaType != .through {
                let names = copperNames
                guard t.layers.start < names.count, t.layers.end < names.count else { continue }
                // (GetCircleSegmentCount of its drill: as many segments as the board's error asks of its radius)
                let segs = KiMath.arcToSegmentCount(t.drill / 2, maxError, .a360)
                let ring = PolySet([[Self.circle(t.start, t.drill / 2 + plating, segs), Self.circle(t.start, t.drill / 2, segs)]])
                out.append(Slab(kind: .viaBarrel, layer: nil, polygons: ring, bottom: zRange(names[t.layers.end]).low,
                                top: zRange(names[t.layers.start]).high, color: colors.copper))
            }
        }
        // the board body, its holes taken out
        if showBoard {
            var body = boardPolygon
            body.booleanSubtract(thODPolys)
            body.booleanSubtract(npthODPolys)
            out.append(Slab(kind: .body, layer: nil, polygons: body, bottom: -bodyThickness / 2, top: bodyThickness / 2, color: colors.board))
        }
        // the masks (renderSolderMaskLayer): the board's outline less the mask's openings and the plated holes, from
        // the front mask's bottom up (the back's top down) as thick as a technical layer is
        for layer in ["B.Mask", "F.Mask"] {
            let flag: Visibility = layer == "F.Mask" ? .soldermaskTop : .soldermaskBottom
            guard flags.contains(flag) else { continue }
            var mask = boardPolygon
            if let openings = layerPolys[layer] {
                var o = openings
                o.booleanIntersection(boardPolygon)
                mask.booleanSubtract(o)
            }
            mask.booleanSubtract(thODPolys)
            let z = layer == "F.Mask" ? layerZ["F.Mask"]!.bottom : layerZ["B.Mask"]!.top
            out.append(Slab(kind: .soldermask, layer: layer, polygons: mask, bottom: z, top: z + nonCopperLayerThickness,
                            color: layer == "F.Mask" ? colors.soldermaskTop : colors.soldermaskBottom))
        }
        slabs = out
    }

    /// A circle of `segments` (generateRing's points: the first at angle 0, turning the board's way)
    static func circle(_ c: IPoint, _ r: Int, _ segments: Int) -> LineChain {
        let n = max(segments, 3)
        var chain = LineChain()
        for i in 0..<n {
            let a = 2 * Double.pi * Double(i) / Double(n)
            chain.append(IPoint(c.x + KiMath.round(Double(r) * cos(a)), c.y + KiMath.round(Double(r) * sin(a))))
        }
        chain.setClosed(true)
        return chain
    }

    // MARK: - The footprints' models

    /// IsFootprintShown: a footprint left out of position files or not fitted only if those are shown; an SMD one
    /// with the SMD models, a through-hole one with those, any other with the virtual ones
    func isFootprintShown(_ fp: SExpr) -> Bool {
        let attr = fp["attr"]?.arguments.map(\.text) ?? []
        let flags = settings.visible
        if attr.contains("exclude_from_pos_files") && !flags.contains(.modelsNotInPosFiles) { return false }
        if attr.contains("dnp") && !flags.contains(.modelsMarkedDNP) { return false }
        if attr.contains("smd") { return flags.contains(.smdModels) }
        if attr.contains("through_hole") { return flags.contains(.throughHoleModels) }
        return flags.contains(.virtualModels)
    }

    /// GetFootprintZPos: a flipped footprint's models from the back paste's bottom, any other's from the front
    /// paste's top
    func footprintZ(flipped: Bool) -> Double { flipped ? layerZ["B.Paste"]!.bottom : layerZ["F.Paste"]!.top }

    /// get3dModelsFromFootprint: each model shown, placed at the footprint's position and turned with it (a flipped
    /// one turned over about y, then about z), then moved by its offset, turned by its rotation (z, y, then x,
    /// negated) and scaled; in millimetres
    mutating func placeModels() {
        var out: [Model] = []
        for fp in drc.board.root.all("footprint") where isFootprintShown(fp) {
            let pos = BoardWorld.point(fp["at"])
            let orientation = (fp["at"]?.number(at: 2) ?? 0) * .pi / 180
            let flipped = fp.value("layer") == "B.Cu"
            var m = Matrix4.translation(Double(pos.x) / 1e6, -Double(pos.y) / 1e6, footprintZ(flipped: flipped) / 1e6)
            if orientation != 0 { m = m * Matrix4.rotation(orientation, axis: 2) }
            if flipped { m = m * Matrix4.rotation(.pi, axis: 1) * Matrix4.rotation(.pi, axis: 2) }
            let reference = BoardWorld.FootprintPlacement(fp).reference
            for model in fp.all("model") {
                guard let file = model.text(at: 0), !file.isEmpty else { continue }
                if model.value("hide") == "yes" || model.arguments.contains(where: { $0.kind == .symbol && $0.text == "hide" }) { continue }
                func xyz(_ key: String, _ fallback: Double) -> (Double, Double, Double) {
                    guard let v = model[key]?["xyz"] else { return (fallback, fallback, fallback) }
                    return (v.number(at: 0) ?? fallback, v.number(at: 1) ?? fallback, v.number(at: 2) ?? fallback)
                }
                var offset = xyz("offset", 0)
                // (the oldest boards' offset, in inches)
                if model["offset"] == nil, model["at"] != nil {
                    let at = xyz("at", 0)
                    offset = (at.0 * 25.4, at.1 * 25.4, at.2 * 25.4)
                }
                let rotation = xyz("rotate", 0), scale = xyz("scale", 1)
                var mtx = Matrix4.translation(offset.0, offset.1, offset.2)
                mtx = mtx * Matrix4.rotation(-rotation.2 * .pi / 180, axis: 2)
                mtx = mtx * Matrix4.rotation(-rotation.1 * .pi / 180, axis: 1)
                mtx = mtx * Matrix4.rotation(-rotation.0 * .pi / 180, axis: 0)
                mtx = mtx * Matrix4.scale(scale.0, scale.1, scale.2)
                out.append(Model(reference: reference, footprint: fp.value("uuid") ?? "", filename: file,
                                 opacity: model["opacity"]?.number(at: 0) ?? 1, transform: (m * mtx).columns))
            }
        }
        models = out
    }
}

/// A 4x4 matrix of doubles (glm::mat4's, column by column), as the viewer composes a model's place with them
public struct Matrix4: Sendable, Equatable {
    /// m[column][row]
    public var m: [[Double]]

    public static let identity = Matrix4(m: (0..<4).map { c in (0..<4).map { r in c == r ? 1 : 0 } })

    public static func translation(_ x: Double, _ y: Double, _ z: Double) -> Matrix4 {
        var t = identity
        t.m[3] = [x, y, z, 1]
        return t
    }

    public static func scale(_ x: Double, _ y: Double, _ z: Double) -> Matrix4 {
        var s = identity
        (s.m[0][0], s.m[1][1], s.m[2][2]) = (x, y, z)
        return s
    }

    /// glm::rotate's matrix: `angle` radians about the x (0), y (1) or z (2) axis, counter-clockwise looking down it
    public static func rotation(_ angle: Double, axis: Int) -> Matrix4 {
        var r = identity
        let c = cos(angle), s = sin(angle)
        let (i, j) = axis == 0 ? (1, 2) : axis == 1 ? (2, 0) : (0, 1)
        r.m[i][i] = c
        r.m[i][j] = s
        r.m[j][i] = -s
        r.m[j][j] = c
        return r
    }

    public static func * (a: Matrix4, b: Matrix4) -> Matrix4 {
        var out = Matrix4(m: Array(repeating: Array(repeating: 0, count: 4), count: 4))
        for c in 0..<4 {
            for r in 0..<4 {
                var v = 0.0
                for k in 0..<4 { v += a.m[k][r] * b.m[c][k] }
                out.m[c][r] = v
            }
        }
        return out
    }

    public init(m: [[Double]]) { self.m = m }

    /// From 16 numbers, column by column
    public init(columns: [Double]) { m = (0..<4).map { c in Array(columns[(c * 4)..<(c * 4 + 4)]) } }

    public var columns: [Double] { m.flatMap { $0 } }

    /// A point moved by the matrix
    public func apply(_ p: (Double, Double, Double)) -> (Double, Double, Double) {
        (m[0][0] * p.0 + m[1][0] * p.1 + m[2][0] * p.2 + m[3][0],
         m[0][1] * p.0 + m[1][1] * p.1 + m[2][1] * p.2 + m[3][1],
         m[0][2] * p.0 + m[1][2] * p.1 + m[2][2] * p.2 + m[3][2])
    }
}
