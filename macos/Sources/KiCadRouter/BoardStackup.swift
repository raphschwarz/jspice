// A board's physical stackup as KiCad 10.0.7 keeps it, reads it, writes it and makes it anew:
// pcbnew/board_stackup_manager/board_stackup.h and board_stackup.cpp (BOARD_STACKUP_ITEM and its defaults,
// BOARD_STACKUP::BuildDefaultStackupList, SynchronizeWithBoard, BuildBoardThicknessFromStackup, FormatBoardStackup),
// the stackup as pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr_parser.cpp reads it (parseBoardStackup, and the default
// stackup parseSetup builds for a board with none), and as the Board Setup dialog's Physical Stackup page
// (pcbnew/board_stackup_manager/panel_board_stackup.cpp) brings it to a new copper layer count: buildLayerStackPanel's
// stackup of every layer, initialized from the board's; the values through its controls (synchronizeWithBoard,
// transferDataFromUIToStackup: dielectric types, unspecified materials, colors from its lists, stackup_predefined_prms.cpp);
// onCopperLayersSelCount's setDefaultLayerWidths (the board's thickness kept, 0.1 mm prepregs) and
// TransferDataFromWindow. Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// A board's physical stackup, as KiCad keeps it (BOARD_STACKUP): its layers top to bottom (silkscreens, pastes,
/// masks, copper and the dielectrics between), each with what KiCad knows of it, and the board's finish and edges
public struct BoardStackup: Sendable, Equatable {
    /// What a stackup layer is (BOARD_STACKUP_ITEM_TYPE)
    public enum Kind: Sendable, Equatable {
        case copper, dielectric, solderPaste, solderMask, silkscreen
    }

    /// One of a layer's sublayers (DIELECTRIC_PRMS: a dielectric can have several; any other layer has one), as a
    /// new one is (its constructor's values)
    public struct Sublayer: Sendable, Equatable {
        public var material = ""
        /// nm
        public var thickness = 0
        public var thicknessLocked = false
        public var epsilonR = 1.0
        public var lossTangent = 0.0
        public var color = ""
        public init() {}
    }

    /// A stackup layer (BOARD_STACKUP_ITEM)
    public struct Item: Sendable, Equatable {
        public var kind: Kind
        /// The board layer it is, by its canonical name; nil for a dielectric
        public var layer: String?
        /// A dielectric's number, from 1 at the top
        public var dielectricID = 1
        /// Its type as KiCad writes it ("copper", "core", "prepreg", "Top Solder Mask"...)
        public var typeName: String
        public var sublayers = [Sublayer()]
        public var enabled = true

        /// A new layer of a kind, as BOARD_STACKUP_ITEM's constructor makes it
        public init(_ kind: Kind) {
            self.kind = kind
            switch kind {
            case .copper:
                typeName = "copper"
                sublayers[0].thickness = BoardStackup.copperDefaultThickness
            case .dielectric:
                typeName = "core"
                sublayers[0].color = BoardStackup.notSpecified
                sublayers[0].material = "FR4"
                sublayers[0].lossTangent = 0.02
                sublayers[0].epsilonR = 4.5
            case .solderPaste:
                typeName = "solderpaste"
            case .solderMask:
                typeName = "soldermask"
                sublayers[0].color = BoardStackup.notSpecified
                sublayers[0].material = BoardStackup.notSpecified
                sublayers[0].thickness = BoardStackup.maskDefaultThickness
                sublayers[0].epsilonR = 3.3
            case .silkscreen:
                typeName = "silkscreen"
                sublayers[0].color = BoardStackup.notSpecified
                sublayers[0].material = BoardStackup.notSpecified
                sublayers[0].epsilonR = 1.0
            }
        }

        public var isThicknessEditable: Bool { kind == .copper || kind == .dielectric || kind == .solderMask }
        public var isColorEditable: Bool { kind == .dielectric || kind == .solderMask || kind == .silkscreen }
        public var isMaterialEditable: Bool { isColorEditable }
        public var hasEpsilonR: Bool { kind == .dielectric || kind == .solderMask }
        public var hasLossTangent: Bool { hasEpsilonR }
        public func hasMaterialValue(_ sublayer: Int) -> Bool {
            isMaterialEditable && BoardStackup.isSpecified(sublayers[sublayer].material)
        }
        /// Its thickness, every sublayer's, nm
        public var thickness: Int { sublayers.reduce(0) { $0 + $1.thickness } }
    }

    public var items: [Item] = []
    public var finish = "None"
    public var dielectricConstraints = false
    /// 0 none, 1 an edge connector, 2 a bevelled one (BS_EDGE_CONNECTOR_CONSTRAINTS)
    public var edgeConnector = 0
    public var edgePlating = false

    public init(items: [Item] = []) { self.items = items }

    /// BOARD_STACKUP_ITEM::GetCopperDefaultThickness and GetMaskDefaultThickness, nm
    public static let copperDefaultThickness = 35_000
    public static let maskDefaultThickness = 10_000
    /// A board's thickness where its file gives none (BOARD_DESIGN_SETTINGS' default), nm
    public static let defaultBoardThickness = 1_600_000
    /// NotSpecifiedPrm
    public static let notSpecified = "Not specified"

    /// IsPrmSpecified
    public static func isSpecified(_ value: String) -> Bool {
        !value.isEmpty && value.caseInsensitiveCompare(notSpecified) != .orderedSame
    }

    // MARK: - Layers

    /// The copper layers' canonical names, front to back, of a board of `count` (LSET::AllCuMask(count).CuStack())
    public static func copperNames(_ count: Int) -> [String] {
        guard count >= 2 else { return ["F.Cu"] }
        return ["F.Cu"] + (1..<(count - 1)).map { "In\($0).Cu" } + ["B.Cu"]
    }

    /// The layers a stackup can hold (StackupAllowedBrdLayers) other than copper, top to bottom, with their kinds and the
    /// type names BuildDefaultStackupList gives them
    static let topLayers: [(String, Kind, String)] = [("F.SilkS", .silkscreen, "Top Silk Screen"),
                                                      ("F.Paste", .solderPaste, "Top Solder Paste"),
                                                      ("F.Mask", .solderMask, "Top Solder Mask")]
    static let bottomLayers: [(String, Kind, String)] = [("B.Mask", .solderMask, "Bottom Solder Mask"),
                                                         ("B.Paste", .solderPaste, "Bottom Solder Paste"),
                                                         ("B.SilkS", .silkscreen, "Bottom Silk Screen")]

    /// What a board has that its stackup depends on (its BOARD_DESIGN_SETTINGS): its enabled layers (canonical names),
    /// its copper layer count and its thickness (nm)
    public struct BoardSettings: Sendable, Equatable {
        public var enabledLayers: Set<String>
        public var copperLayers: Int
        public var thickness: Int

        public init(enabledLayers: Set<String>, copperLayers: Int, thickness: Int) {
            self.enabledLayers = enabledLayers
            self.copperLayers = copperLayers
            self.thickness = thickness
        }

        /// A board file's: the layers of its (layers ...), its copper layers among them, its (general (thickness))
        public init(_ board: KiCadBoard) {
            let names = (board.root["layers"]?.arguments ?? []).compactMap { $0.text(at: 0) }
            enabledLayers = Set(names)
            copperLayers = max(2, names.filter { $0.hasSuffix(".Cu") }.count)
            thickness = board.root["general"]?["thickness"].map { BoardWorld.iu($0, 0) } ?? BoardStackup.defaultBoardThickness
        }
    }

    /// The stackup KiCad builds by default (BuildDefaultStackupList): of `settings`' layers, its dielectrics of the
    /// board's thickness less its copper and masks' shared out between them, cores and prepregs in turn, FR4; with no
    /// settings, of every layer a stackup can hold (32 copper), its dielectrics as for a 1.6 mm board of
    /// `activeCopperLayers` copper layers
    public static func defaultStackup(_ settings: BoardSettings?, activeCopperLayers: Int = 0) -> BoardStackup {
        let enabled = settings?.enabledLayers
        let copperCount = settings?.copperLayers ?? 32
        var active = copperCount
        if settings == nil && activeCopperLayers > 0 { active = activeCopperLayers }
        let thickness = settings?.thickness ?? defaultBoardThickness
        var diel = thickness - copperDefaultThickness * active
        let masks = enabled.map { e in ["F.Mask", "B.Mask"].filter(e.contains).count } ?? 2
        diel -= maskDefaultThickness * masks
        diel /= max(1, active - 1)
        func has(_ layer: String) -> Bool { enabled?.contains(layer) ?? true }
        var stackup = BoardStackup()
        func addSide(_ list: [(String, Kind, String)]) {
            for (layer, kind, name) in list where has(layer) {
                var item = Item(kind)
                item.layer = layer
                item.typeName = name
                stackup.items.append(item)
            }
        }
        addSide(topLayers)
        let copper = copperNames(32).filter { enabled == nil || enabled!.contains($0) }
        for (i, layer) in copper.enumerated() {
            var item = Item(.copper)
            item.layer = layer
            stackup.items.append(item)
            if layer == "B.Cu" { break }
            var d = Item(.dielectric)
            d.sublayers[0].thickness = diel
            d.dielectricID = i + 1
            d.typeName = i % 2 == 0 ? "core" : "prepreg"
            d.sublayers[0].material = "FR4"
            stackup.items.append(d)
        }
        addSide(bottomLayers)
        return stackup
    }

    // MARK: - Reading and writing

    /// The stackup of a board's file: its setup's (stackup ...) as parseBoardStackup reads it (each layer by its
    /// canonical name among the board's layers, any other a dielectric, numbered from the top; its sublayers; the
    /// finish and edges), or, where it has none, the default one KiCad builds for it; and whether the file has one
    /// (m_HasStackup)
    public static func read(_ board: KiCadBoard) -> (stackup: BoardStackup, inFile: Bool) {
        let settings = BoardSettings(board)
        guard let node = board.root["setup"]?["stackup"] else { return (defaultStackup(settings), false) }
        return (parse(node, enabledLayers: settings.enabledLayers), true)
    }

    /// A (stackup ...) as parseBoardStackup reads it
    public static func parse(_ node: SExpr, enabledLayers: Set<String>) -> BoardStackup {
        var stackup = BoardStackup()
        var dielectric = 1
        var seen: Set<String> = []
        var duplicated = false
        for entry in node.arguments where entry.isList {
            switch entry.head {
            case "copper_finish": stackup.finish = entry.text(at: 0) ?? ""
            case "edge_plating": stackup.edgePlating = entry.text(at: 0) == "yes"
            case "dielectric_constraints": stackup.dielectricConstraints = entry.text(at: 0) == "yes"
            case "edge_connector":
                let v = entry.text(at: 0)
                stackup.edgeConnector = v == "yes" ? 1 : v == "bevelled" ? 2 : 0
            case "layer":
                guard let name = entry.text(at: 0) else { continue }
                let layer = enabledLayers.contains(name) ? name : nil
                let kind: Kind
                switch layer {
                case "F.SilkS", "B.SilkS": kind = .silkscreen
                case "F.Mask", "B.Mask": kind = .solderMask
                case "F.Paste", "B.Paste": kind = .solderPaste
                case nil: kind = .dielectric
                case let l? where l.hasSuffix(".Cu"): kind = .copper
                default: continue  // (KiCad refuses the file: "Expecting layer_name")
                }
                if let layer, !seen.insert(layer).inserted { duplicated = true }
                var item = Item(kind)
                item.layer = layer
                if kind == .dielectric {
                    item.dielectricID = dielectric
                    dielectric += 1
                }
                var sub = 0
                for field in entry.arguments.dropFirst() {
                    if field.kind == .symbol && field.text == "addsublayer" {
                        sub += 1
                        item.sublayers.append(Sublayer())
                        continue
                    }
                    guard field.isList else { continue }
                    switch field.head {
                    case "type": item.typeName = field.text(at: 0) ?? item.typeName
                    case "thickness":
                        item.sublayers[sub].thickness = BoardWorld.iu(field, 0)
                        if kind == .dielectric && field.text(at: 1) == "locked" { item.sublayers[sub].thicknessLocked = true }
                    case "material": item.sublayers[sub].material = field.text(at: 0) ?? ""
                    case "epsilon_r": item.sublayers[sub].epsilonR = field.number(at: 0) ?? 0
                    case "loss_tangent": item.sublayers[sub].lossTangent = field.number(at: 0) ?? 0
                    case "color": item.sublayers[sub].color = field.text(at: 0) ?? ""
                    default: break
                    }
                }
                // (a stackup repeated by an old board append: the rest read, not kept)
                if !duplicated && stackup.items.count < 128 { stackup.items.append(item) }
            default:
                break
            }
        }
        return stackup
    }

    /// A number as FormatDouble2Str writes it
    static func formatDouble(_ v: Double) -> String {
        if v != 0 && abs(v) <= 0.0001 {
            var s = String(format: "%.16f", v)
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            return s
        }
        return String(format: "%.10g", v)
    }

    /// A length (nm) as FormatInternalUnits writes it, in mm
    static func formatLength(_ nm: Int) -> String {
        let mm = Double(nm) / 1e6
        if mm != 0 && abs(mm) <= 0.0001 {
            var s = String(format: "%.10f", mm)
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            return s
        }
        return String(format: "%.10g", mm)
    }

    /// The (stackup ...) KiCad writes of it (FormatBoardStackup: the layers, each named by its board layer or as
    /// "dielectric N", their sublayers' values where they mean something, the finish, the dielectric constraints and
    /// the edges); nil for an empty stackup, which KiCad does not write
    public var node: SExpr? {
        guard !items.isEmpty else { return nil }
        var out: [SExprConvertible] = []
        for item in items {
            var fields: [SExprConvertible] = [item.layer ?? "dielectric \(item.dielectricID)", SExpr("type", item.typeName)]
            for (i, s) in item.sublayers.enumerated() {
                if i > 0 { fields.append(Keyword("addsublayer")) }
                if item.isColorEditable && Self.isSpecified(s.color) { fields.append(SExpr("color", s.color)) }
                if item.isThicknessEditable {
                    var t: [SExprConvertible] = [Keyword(Self.formatLength(s.thickness))]
                    if item.kind == .dielectric && s.thicknessLocked { t.append(Keyword("locked")) }
                    fields.append(SExpr("thickness", t))
                }
                if item.hasMaterialValue(i) {
                    fields.append(SExpr("material", s.material))
                    if item.hasEpsilonR { fields.append(SExpr("epsilon_r", Keyword(Self.formatDouble(s.epsilonR)))) }
                    if item.hasLossTangent { fields.append(SExpr("loss_tangent", Keyword(Self.formatDouble(s.lossTangent)))) }
                }
            }
            out.append(SExpr("layer", fields))
        }
        if Self.isSpecified(finish) { out.append(SExpr("copper_finish", finish)) }
        out.append(SExpr("dielectric_constraints", Keyword(dielectricConstraints ? "yes" : "no")))
        if edgeConnector > 0 { out.append(SExpr("edge_connector", Keyword(edgeConnector > 1 ? "bevelled" : "yes"))) }
        if edgePlating { out.append(SExpr("edge_plating", Keyword("yes"))) }
        return SExpr("stackup", out)
    }

    /// The board's thickness its stackup makes (BuildBoardThicknessFromStackup: its copper, dielectrics and masks, of
    /// its layers enabled), nm
    public var boardThickness: Int {
        items.filter { $0.isThicknessEditable && $0.enabled }.reduce(0) { $0 + $1.thickness }
    }

    // MARK: - Brought to the board's layers

    /// Whether two stackup layers are the same layer: the same board layer, or dielectrics of the same number
    static func same(_ a: Item, _ b: Item) -> Bool {
        if let l = a.layer { return b.layer == l }
        return b.layer == nil && a.dielectricID == b.dielectricID
    }

    /// The stackup brought to the board's layers as KiCad brings it before writing a Gerber job file
    /// (SynchronizeWithBoard): the default stackup of `settings`, each layer the one this stackup has of it where it
    /// has it; whether anything had to change (a layer gone, or one added), as KiCad reports "Board stackup settings
    /// not up to date"
    @discardableResult
    public mutating func synchronize(with settings: BoardSettings) -> Bool {
        var change = false
        var stackup = Self.defaultStackup(settings)
        for current in items where !stackup.items.contains(where: { Self.same(current, $0) }) {
            change = true
            break
        }
        for i in stackup.items.indices {
            if let initial = items.first(where: { Self.same(stackup.items[i], $0) }) {
                stackup.items[i] = initial
            } else {
                change = true
            }
        }
        stackup.dielectricConstraints = dielectricConstraints
        stackup.edgeConnector = edgeConnector
        stackup.edgePlating = edgePlating
        stackup.finish = finish
        self = stackup
        return change
    }

    // MARK: - The Board Setup dialog's Physical Stackup page

    /// The standard colors the dialog offers for a kind of layer (GetStandardColors: names only), the last the user
    /// defined one
    static func standardColors(_ kind: Kind) -> [String] {
        switch kind {
        case .silkscreen, .solderMask: return [notSpecified, "Green", "Red", "Blue", "Purple", "Black", "White", "Yellow", "User defined"]
        case .dielectric: return [notSpecified, "FR4 natural", "PTFE natural", "Polyimide", "Phenolic natural", "Aluminum", "User defined"]
        default: return []
        }
    }

    /// A color as the dialog's color box gives it back: a user defined one ("#RRGGBB[AA]") as COLOR4D::ToHexString
    /// writes it, a standard one by its name, any other not specified
    static func colorThroughDialog(_ color: String, _ kind: Kind) -> String {
        if color.hasPrefix("#") {
            let hex = color.dropFirst()
            guard hex.count == 6 || hex.count == 8, UInt64(hex, radix: 16) != nil else { return color }
            return "#" + (hex + (hex.count == 6 ? "FF" : "")).uppercased()
        }
        let list = standardColors(kind)
        let i = list.firstIndex(of: color) ?? 0
        // (KiCad's "User defined" picks its default user color, which is not ported: the name is kept)
        return i == list.count - 1 ? color : list[i]
    }

    /// A number as the dialog shows it and reads it back (UIDouble2Str, then ToDouble)
    static func doubleThroughDialog(_ v: Double) -> Double {
        let text = v != 0 && abs(v) <= 0.0001 ? String(format: "%.16f", v) : String(format: "%.10g", v)
        return Double(text) ?? v
    }

    /// The stackup the Board Setup dialog gives a board of this stackup and `settings` when its copper layer count is
    /// set to `copperLayers` on its Physical Stackup page and the dialog is closed with OK: its stackup of every
    /// layer, each the board's own where the board has it (buildLayerStackPanel), the layers of the new count shown,
    /// the unlocked dielectrics' thicknesses set anew to keep the board as thick as the stackup made it, prepregs of
    /// 0.1 mm and cores of the rest, or all alike where the cores would be thinner (setDefaultLayerWidths), the
    /// values as its controls give them back (transferDataFromUIToStackup), and the layers shown kept
    /// (TransferDataFromWindow). Its board thickness is then `boardThickness`.
    public func throughBoardSetup(_ settings: BoardSettings, copperLayers: Int) -> BoardStackup {
        // buildLayerStackPanel( true ): a full stackup, initialized from the board's
        var full = Self.defaultStackup(nil, activeCopperLayers: settings.copperLayers)
        for i in full.items.indices {
            if let own = items.first(where: { Self.same(full.items[i], $0) }) { full.items[i] = own }
        }
        // (the rows shown, as showOnlyActiveLayers shows them for a count of copper layers)
        let allowed: Set<String> = Set(Self.copperNames(32)).union(["F.SilkS", "F.Mask", "F.Paste", "B.SilkS", "B.Mask", "B.Paste"])
        let shownLayers = settings.enabledLayers.intersection(allowed)
        func shown(_ item: Item, copper: Int) -> Bool {
            if item.layer == nil { return item.dielectricID < copper }
            let layer = item.layer!
            if layer.hasSuffix(".Cu") { return Set(Self.copperNames(copper)).contains(layer) }
            return shownLayers.contains(layer)
        }
        // (the board's thickness as the page shows it: of its rows shown, computeBoardThickness)
        let oldThickness = full.items.filter { $0.isThicknessEditable && shown($0, copper: settings.copperLayers) }
            .reduce(0) { $0 + $1.thickness }
        // the controls, as synchronizeWithBoard and lazyBuildRowUI fill them: the dielectrics' type choices
        var isCore = full.items.map { $0.typeName == "core" }
        for i in full.items.indices { full.items[i].enabled = shown(full.items[i], copper: copperLayers) }
        // setDefaultLayerWidths( oldBoardWidth )
        let prepregDefault = 100_000
        let dielectrics = copperLayers - 1
        var cores = copperLayers / 2 - 1
        var current = false
        if copperLayers == 2 {
            cores = 1
            current = true
        }
        let prepregs = dielectrics - cores
        var fixed = 0
        for item in full.items where item.isThicknessEditable && item.enabled {
            for (j, s) in item.sublayers.enumerated() {
                // (a dielectric's further sublayers, masks, copper and locked thicknesses)
                if (item.kind == .dielectric && j > 0) || item.kind == .solderMask || item.kind == .copper || s.thicknessLocked {
                    fixed += s.thickness
                }
            }
        }
        var remaining = oldThickness - fixed - prepregDefault * prepregs
        var prepreg = prepregDefault
        var core = cores > 0 ? remaining / cores : 0
        if core < prepreg {
            remaining = oldThickness - fixed
            prepreg = max(0, remaining / max(1, dielectrics))
            core = prepreg
        }
        for i in full.items.indices where full.items[i].kind == .dielectric && full.items[i].enabled {
            if full.items[i].sublayers[0].thicknessLocked {
                current.toggle()
                continue
            }
            full.items[i].sublayers[0].thickness = current ? core : prepreg
            isCore[i] = current
            current.toggle()
        }
        // transferDataFromUIToStackup, of the rows shown; then the board's stackup is the layers shown
        var out = BoardStackup()
        for (i, var item) in full.items.enumerated() where item.enabled {
            if item.kind == .dielectric { item.typeName = isCore[i] ? "core" : "prepreg" }
            for j in item.sublayers.indices {
                if item.hasEpsilonR {
                    item.sublayers[j].epsilonR = Self.doubleThroughDialog(item.sublayers[j].epsilonR)
                    item.sublayers[j].lossTangent = Self.doubleThroughDialog(item.sublayers[j].lossTangent)
                }
                if item.isMaterialEditable && !Self.isSpecified(item.sublayers[j].material) {
                    item.sublayers[j].material = Self.notSpecified
                }
                if item.isColorEditable { item.sublayers[j].color = Self.colorThroughDialog(item.sublayers[j].color, item.kind) }
            }
            out.items.append(item)
        }
        out.finish = finish
        out.dielectricConstraints = dielectricConstraints
        out.edgeConnector = edgeConnector
        out.edgePlating = edgePlating
        return out
    }
}
