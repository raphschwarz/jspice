// Ported from KiCad 10.0.8: pcbnew/tools/pcb_grid_helper.cpp (PCB_GRID_HELPER: BestSnapAnchor, queryVisible,
// computeAnchors, GetArcAnchors, nearestAnchor, GetBoardIntersectable, FindSquareDistanceToItem: where the pointer
// snaps to the board's items, the magnetic points), common/tool/grid_helper.cpp (GRID_HELPER: Align, AlignGrid,
// computeNearest, SnapToConstructionLines, the visible grid), common/tool/construction_manager.cpp
// (SNAP_LINE_MANAGER: SetSnapLineOrigin, SetSnapLineEnd, SetSnappedAnchor, GetNearestSnapLinePoint, SetDirections:
// the snap lines through the last point snapped to), include/gal/graphics_abstraction_layer.h (GetVisibleGridSize),
// common/advanced_config.cpp (SnapHysteresis), pcbnew/pcbnew_settings.h and pcbnew_settings.cpp (MAGNETIC_SETTINGS:
// the Magnetic Points preferences and their defaults), libs/kimath/src/geometry/intersection.cpp
// (INTERSECTION_VISITOR), nearest.cpp (GetNearestPoint), shape_utils.cpp (GetCircleKeyPoints, BoxToSegs), oval.cpp
// (GetOvalKeyPoints), shape_segment.cpp (BySizeAndCenter) and shape_arc.cpp (Intersect, IntersectLine,
// sliceContainsPoint), and pcbnew/router/pns_tool_base.cpp (TOOL_BASE::checkSnap: the router's magnetic pads and
// tracks); and the tools that snap with it: pcbnew/tools/edit_tool_move_fct.cpp (EDIT_TOOL::doMoveSelection: a
// move's pick-up point, PCB_GRID_HELPER::BestDragOrigin, its auxiliary axes and the items it skips),
// pcbnew/tools/pcb_grid_helper.cpp's GetItemGrid and GetGridSize and common/tool/grid_helper.cpp's GetSelectionGrid
// (the grid of each kind of item), pcbnew/tools/drawing_tool.cpp (DRAWING_TOOL::DrawZone, PlaceText),
// common/preview_items/polygon_geom_manager.cpp (AddPoint, SetLeaderMode, SetCursorPosition, NewPointClosesOutline) and
// pcbnew/tools/zone_create_helper.cpp (OnComplete: a zone's outline drawn), pcbnew/tools/board_editor_control.cpp
// (PlaceFootprint: no grid helper, the cursor's grid point, common/gal/graphics_abstraction_layer.cpp's
// GetGridPoint) and pcbnew/tools/pcb_point_editor.cpp (the point editor's drag: the BestSnapAnchor of each edit
// point, its layers, its snap lines, the construction geometry of its item's copy).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

// MARK: - The Magnetic Points preferences

/// MAGNETIC_OPTIONS: when the pointer snaps to pads or tracks
public enum MagneticOption: Int, Sendable, CaseIterable {
    /// Never
    case noEffect = 0
    /// While routing only (the router's own snapping, TOOL_BASE::checkSnap)
    case captureCursorInTrackTool = 1
    /// Always: moving, drawing and routing (PCB_GRID_HELPER's anchors too)
    case captureAlways = 2
}

/// MAGNETIC_SETTINGS: the PCB editor's Magnetic Points preferences (pcbnew.json's editing.magnetic_pads,
/// magnetic_tracks, magnetic_graphics and magnetic_all_layers), KiCad's defaults where it has none: pads and tracks
/// while routing only, graphics snapped to, items on the layer worked on only
public struct MagneticSettings: Sendable, Equatable {
    public var pads = MagneticOption.captureCursorInTrackTool
    public var tracks = MagneticOption.captureCursorInTrackTool
    public var graphics = true
    public var allLayers = false

    public init() {}

    /// As KiCad reads them from its pcbnew.json (PCBNEW_SETTINGS' PARAMs: a value of another kind its default)
    public init(pcbnewSettings json: [String: Any]?) {
        let e = json?["editing"] as? [String: Any] ?? [:]
        if let v = e["magnetic_pads"] as? Int, let o = MagneticOption(rawValue: v) { pads = o }
        if let v = e["magnetic_tracks"] as? Int, let o = MagneticOption(rawValue: v) { tracks = o }
        if let v = e["magnetic_graphics"] as? Bool { graphics = v }
        if let v = e["magnetic_all_layers"] as? Bool { allLayers = v }
    }

    /// TOOL_BASE::checkSnap: whether the router snaps the end of the track being routed to a pad (or a track or via)
    public var routerSnapsToPads: Bool { pads != .noEffect }
    public var routerSnapsToTracks: Bool { tracks != .noEffect }
}

// MARK: - The board's items, as the grid helper finds anchors on them

/// The board's items as PCB_GRID_HELPER takes its anchors from them: footprints (their positions and the centres of
/// their boxes, their points), pads (their centres, the key points of their outlines and holes), tracks, arcs and
/// vias, graphics (their ends, corners, middles, centres, quadrants), zones (their corners), targets
public struct SnapBoard: Sendable {
    public struct Item: Sendable {
        public enum Kind: Sendable { case footprint, pad, track, arc, via, shape, zone, target, point }
        public var kind: Kind
        public var uuid: String
        /// BOARD_ITEM::GetLayerSet, by KiCad layer id
        public var layers: [Int]
        /// Its box in the view (ViewBBox): a track's or via's bounding box twice the board's biggest clearance out, a
        /// pad's its mask margin and the board's worst clearance out (pad clearances shown, KiCad's default), a
        /// footprint's the worst clearance out, a graphic's its width out, a zone's its outline's
        public var box: IBox
        /// The footprint it is of, by item index
        public var footprint: Int?
        var start = IPoint.zero, end = IPoint.zero, mid = IPoint.zero, center = IPoint.zero
        var drawing: BoardWorld.Drawing?
        var pad: BoardWorld.Pad?
        /// A zone's corners, its outlines' and holes' one after another (CIterateWithHoles); a footprint's points
        var points: [IPoint] = []
        /// A footprint's pads, by item index
        var pads: [Int] = []
        /// A footprint's side: F.Cu (0), B.Cu (2)
        var side = 0
        /// A pad's own box (PAD::GetBoundingBox), a footprint's (GetBoundingBox( false ))
        var ownBox: IBox?
        /// A track's or arc's width, a via's diameter, a target's size (for hit testing)
        var width = 0
        /// A zone's outlines and holes (its m_Poly's chains)
        var rings: [[IPoint]] = []
        /// A pad's effective polygon (ERROR_INSIDE) and its hole's shape
        var hitPolygon: PolySet?
        var hole: Shape?
    }

    public private(set) var items: [Item] = []

    public init(board: KiCadBoard, project: [String: Any]? = nil) {
        let world = BoardWorld(board: board, project: project)
        // (BOARD::GetMaxClearanceValue; BOARD_DESIGN_SETTINGS::GetBiggestClearanceValue of the board's minimums and
        // net classes, a rules file's clearances left out)
        let maxClearance = world.rules.maxClearance ?? 0
        let biggestClearance = max(world.rules.clearance, world.rules.holeClearance, world.rules.holeToHole,
                                   world.rules.edgeClearance, world.netClasses.worstClearance)
        let boardMaskMargin = BoardWorld.iu(board.root["setup"]?["pad_to_mask_clearance"], 0)
        func ids(_ names: [String]) -> [Int] {
            var out: [Int] = []
            for n in names {
                if n == "*.Cu" || n == "F&B.Cu" {
                    out += n == "*.Cu" ? [0, 2] + (1...30).map { 2 + 2 * $0 } : [0, 2]
                } else if n.hasPrefix("*.") {
                    let suffix = String(n.dropFirst(1))
                    out += ["F" + suffix, "B" + suffix].compactMap { KiCadLayers.ids[$0] }
                } else if let id = KiCadLayers.ids[n] {
                    out.append(id)
                }
            }
            return out
        }
        func layerNames(_ node: SExpr) -> [String] {
            if let l = node["layers"] { return l.arguments.map(\.text) }
            if let l = node.value("layer") { return [l] }
            return []
        }
        func drawingItem(_ node: SExpr, _ placement: BoardWorld.FootprintPlacement?, footprint: Int?) -> Item? {
            guard var d = world.readDrawing(node, placement: placement) else { return nil }
            var item = Item(kind: .shape, uuid: node.value("uuid") ?? "", layers: ids(layerNames(node)), box: IBox(d.start, d.start),
                            footprint: footprint)
            if d.kind == .arc {
                // (GetArcMid: the middle it was read with, while its ends are those it was read with)
                let local = BoardWorld.point(node["start"]), m = BoardWorld.point(node["mid"])
                let s = placement.map { $0.apply(local) } ?? local
                if s == d.start {
                    item.mid = placement.map { $0.apply(m) } ?? m
                } else {
                    item.mid = KiMath.rotate(d.start, around: d.center, -d.arcAngle / 2.0)
                }
            }
            if d.kind == .bezier {
                let pts = (node["pts"]?.arguments ?? []).filter { $0.head == "xy" }.map(BoardWorld.point)
                guard let first = pts.first, let last = pts.last else { return nil }
                d.start = placement.map { $0.apply(first) } ?? first
                d.end = placement.map { $0.apply(last) } ?? last
            }
            item.drawing = d
            var box = IBox(d.start, d.end)
            switch d.kind {
            case .circle:
                let r = d.radius
                box = IBox(minX: d.start.x - r, minY: d.start.y - r, maxX: d.start.x + r, maxY: d.start.y + r)
            case .arc:
                box = IBox(d.start, d.end)
                box.merge(item.mid)
            case .poly:
                box = IBox(points: d.poly) ?? box
            default: break
            }
            // (EDA_SHAPE's box, half its width out, then PCB_SHAPE::ViewBBox's whole width more)
            item.box = box.inflated(d.width / 2 + d.width)
            return item
        }
        for node in board.root.items {
            let uuid = node.value("uuid") ?? ""
            switch node.head ?? "" {
            case "segment", "arc":
                let s = BoardWorld.point(node["start"]), e = BoardWorld.point(node["end"])
                let w = BoardWorld.iu(node["width"], 0)
                var item = Item(kind: node.head == "arc" ? .arc : .track, uuid: uuid, layers: ids(layerNames(node)),
                                box: IBox(s, e), start: s, end: e)
                if node.head == "arc" {
                    item.mid = BoardWorld.point(node["mid"])
                    item.center = KiMath.arcCenter(s, item.mid, e)
                    item.box.merge(item.mid)
                }
                item.box = item.box.inflated(w / 2 + 2 * biggestClearance)
                item.width = w
                items.append(item)
            case "via":
                let at = BoardWorld.point(node["at"]), r = BoardWorld.iu(node["size"], 0) / 2
                let names = node["layers"]?.arguments.map(\.text) ?? ["F.Cu", "B.Cu"]
                // (a via's layers: every copper layer from its first to its last)
                let span = ids(names).filter(KiCadLayers.isCopper).map(KiCadLayers.stackOrder)
                let all = [0, 2] + (1...30).map { 2 + 2 * $0 }
                let layers = all.filter { span.isEmpty || (span.min()! ... span.max()!).contains(KiCadLayers.stackOrder($0)) }
                var via = Item(kind: .via, uuid: uuid, layers: layers,
                               box: IBox(minX: at.x - r, minY: at.y - r, maxX: at.x + r, maxY: at.y + r).inflated(2 * biggestClearance),
                               start: at)
                via.width = 2 * r
                items.append(via)
            case "gr_line", "gr_rect", "gr_circle", "gr_arc", "gr_poly", "gr_curve":
                if let item = drawingItem(node, nil, footprint: nil) { items.append(item) }
            case "zone":
                let polygons = BoardWorld.zoneOutline(node).polygons
                let corners = polygons.flatMap { $0.flatMap(\.points) }
                guard let box = IBox(points: corners) else { continue }
                var item = Item(kind: .zone, uuid: uuid, layers: ids(layerNames(node)), box: box)
                item.points = corners
                item.rings = polygons.flatMap { $0.map(\.points) }
                items.append(item)
            case "target":
                let at = BoardWorld.point(node["at"])
                var target = Item(kind: .target, uuid: uuid, layers: ids(layerNames(node)), box: IBox(at, at), start: at)
                target.width = BoardWorld.iu(node["size"], 0)
                items.append(target)
            default:
                break
            }
        }
        let boxes = BoxSelection(board: board, project: project)
        for (n, fp) in board.root.all("footprint").enumerated() {
            let placement = BoardWorld.FootprintPlacement(fp)
            let f = n < boxes.footprints.count ? boxes.footprints[n] : nil
            let side = fp.value("layer") == "B.Cu" ? 2 : 0
            let fpBox = f?.box ?? IBox(placement.position, placement.position)
            var footprint = Item(kind: .footprint, uuid: fp.value("uuid") ?? "", layers: [side], box: fpBox.inflated(maxClearance),
                                 start: placement.position, center: fpBox.center)
            footprint.side = side
            footprint.ownBox = fpBox
            let index = items.count
            items.append(footprint)
            var children: [Int] = []
            for node in fp.all("pad") {
                let p = world.readPad(node, placement)
                let primitives = (node["primitives"]?.arguments ?? []).filter { $0.head != "gr_bbox" && $0.head != "gr_vector" }
                let hole = world.holeShape(p)
                var box = hole.bbox
                if p.kind == .custom {
                    guard let poly = world.padPolygon(p, primitives: primitives, errorLocation: .inside) else { continue }
                    for chain in poly.polygons.flatMap({ $0 }) { for q in chain.points { box.merge(q) } }
                } else {
                    for s in world.effectiveShapes(p) { box.merge(s.bbox) }
                }
                // (PAD::ViewBBox: its mask's margin, its own or its footprint's or the board's, and the clearance)
                let mask = node["solder_mask_margin"].map { BoardWorld.iu($0, 0) } ?? fp["solder_mask_margin"].map { BoardWorld.iu($0, 0) }
                    ?? boardMaskMargin
                var item = Item(kind: .pad, uuid: node.value("uuid") ?? "", layers: ids(p.layers), box: box.inflated(max(mask, 0) + maxClearance),
                                footprint: index, start: p.pos)
                item.pad = p
                item.ownBox = box
                let effective = world.padPolygon(p, primitives: primitives, errorLocation: .inside)
                if p.kind == .custom, let poly = effective {
                    // (GetEffectivePolygon( ERROR_INSIDE )'s first outline)
                    item.points = poly.polygons.first?.first?.points ?? []
                }
                item.hitPolygon = effective
                item.hole = hole
                children.append(items.count)
                items.append(item)
            }
            for node in fp.items where ["fp_line", "fp_rect", "fp_circle", "fp_arc", "fp_poly", "fp_curve"].contains(node.head ?? "") {
                if let item = drawingItem(node, placement, footprint: index) {
                    items.append(item)
                }
            }
            for point in fp.all("point") {
                items[index].points.append(BoardWorld.point(point["at"]))
            }
            items[index].pads = children
        }
    }
}

// MARK: - What the view shows of it

/// The view the pointer snaps in (KIGFX::VIEW with its GAL and render settings, as the grid helper asks them): its
/// scale, its grid, what it shows of the board
public struct SnapView: Sendable {
    /// The board's appearance (its layers and objects shown, its high contrast mode and active layer)
    public var appearance: KiCadBoardAppearance
    /// The layers the board has
    public var enabledLayers: Set<Int>
    /// How far a screen pixel is on the board, nm (VIEW::ToWorld( 1 ))
    public var worldPerPixel: Double
    /// The grid (GRID_HELPER::GetGrid and GetOrigin)
    public var grid: IPoint
    public var gridOrigin = IPoint.zero
    /// Whether the grid is snapped to (the GAL's grid snapping)
    public var gridSnapping = true
    /// The grid overrides (the grid settings' overrides, where enabled): a grid of its own for what a tool asks
    public var overrides: [GridKind: IPoint] = [:]
    /// KiCad 10's extension snaps (ADVANCED_CFG's EnableExtensionSnaps, on by default): the construction geometry of
    /// the items the pointer snaps to (and rests on) snapped to, and a crossing of items only where each is involved
    /// in it
    public var extensionSnaps = true
    /// Its activation by hovering over an item, off any anchor (ExtensionSnapActivateOnHover, on by default)
    public var extensionSnapsOnHover = true

    public init(appearance: KiCadBoardAppearance, enabledLayers: Set<Int>, worldPerPixel: Double, grid: IPoint,
                gridOrigin: IPoint = .zero) {
        self.appearance = appearance
        self.enabledLayers = enabledLayers
        self.worldPerPixel = worldPerPixel
        self.grid = grid
        self.gridOrigin = gridOrigin
    }

    /// GAL::GetVisibleGridSize: the grid (a tenth of a micrometre at least) made ten times coarser until its points
    /// are more than the grid's least spacing apart on the screen (ten pixels; twice that for small crosses)
    public var visibleGrid: DPoint {
        var size = DPoint(max(100, Double(grid.x)), max(100, Double(grid.y)))
        let threshold = 10.0 * worldPerPixel
        while min(size.x, size.y) <= threshold { size = size * 10 }
        return size
    }

    /// PCB_GRID_HELPER::GetGridSize: the grid of the kind asked for, its override's if it has one, else the view's
    public func gridSize(_ kind: GridKind) -> IPoint {
        kind == .current ? grid : overrides[kind] ?? grid
    }

    var isHighContrast: Bool { appearance.highContrast != .normal }

    func layerShown(_ id: Int) -> Bool { appearance.isLayerVisible(id, enabled: enabledLayers) }

    /// Whether the view shows an item at all, and on a layer active in high contrast (queryVisible: VIEW::Query of
    /// the visible layers, VIEW::IsVisible, the high contrast layers, the item's level of detail)
    func shows(_ item: SnapBoard.Item, in board: SnapBoard) -> Bool {
        let a = appearance
        func sideShown(_ fp: Int?) -> Bool {
            guard let fp else { return true }
            return board.items[fp].side == 2 ? a.isVisible(.footprintsBack) : a.isVisible(.footprintsFront)
        }
        let layers = item.layers.filter(layerShown)
        if layers.isEmpty && item.kind != .footprint { return false }
        if isHighContrast && !item.layers.contains(a.activeLayer) { return false }
        switch item.kind {
        case .footprint: return sideShown(board.items.firstIndex { $0.uuid == item.uuid && $0.kind == .footprint })
        case .pad: return a.isVisible(.pads) && sideShown(item.footprint)
        case .track, .arc: return a.isVisible(.tracks)
        case .via: return a.isVisible(.vias)
        case .zone: return a.isVisible(.zones)
        case .shape, .point: return sideShown(item.footprint)
        case .target: return true
        }
    }
}

// MARK: - The grid helper

/// GRID_HELPER_GRIDS: the grid a tool snaps to, of the kind of what it places or moves (the view's own grid unless
/// the grid overrides give that kind one of its own)
public enum GridKind: Sendable, Hashable {
    case current, connectable, wires, vias, text, graphics
}

/// KiCad's PCB_GRID_HELPER as a tool uses it to snap the pointer (BestSnapAnchor): to the nearest of the anchors of
/// the items the view shows near it, the magnetic points (pads and tracks where the Magnetic Points preferences say
/// always, graphics where they say so, footprints' origins; on the layers given, or all of them), within 25 pixels
/// of it (the visible grid's step at most), let go 5 pixels farther than it was caught (the snap hysteresis); else
/// to a snap line through the point last snapped to, horizontal or vertical, where the pointer is near it; else to
/// the grid. Kept from one pointer event to the next, as a tool keeps its grid helper: the anchor snapped to, the
/// snap line, and KiCad 10's construction geometry (CONSTRUCTION_MANAGER, BoardConstruction.swift): the extensions
/// of the items the pointer snaps to (a line's rays on from its ends, the rest of an arc's circle and its centre, a
/// circle's or rectangle's centre) or hovers over, taken at once for the first two and then where the pointer rests
/// (`rested`, KiCad's timer), their crossings with each other, with the snap lines and with the items near the
/// pointer snapped to (and the crossings of items only where each was so involved). The view's `extensionSnaps` off
/// snaps as KiCad does with ADVANCED_CFG's EnableExtensionSnaps off.
public struct PCBGridHelper: Sendable {
    /// ANCHOR_FLAGS
    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let corner = Flags(rawValue: 1), outline = Flags(rawValue: 2), snappable = Flags(rawValue: 4)
        public static let origin = Flags(rawValue: 8), vertical = Flags(rawValue: 16), horizontal = Flags(rawValue: 32)
        public static let constructed = Flags(rawValue: 64)
    }

    /// An anchor: where, what kind, the items it is of (by index; none for a snap line's)
    public struct Anchor: Sendable, Equatable {
        public var pos: IPoint
        public var flags: Flags
        public var items: [Int?]

        /// ANCHOR::Distance
        func distance(_ p: IPoint) -> Double { DPoint(p - pos).norm }
    }

    /// INTERSECTABLE_GEOM (and NEARABLE_GEOM): an item's ideal geometry, of no width
    enum Geometry: Sendable {
        case seg(Seg)
        case line(Seg)
        /// HALF_LINE: from `a` through `b` and on
        case halfLine(Seg)
        case circle(Circle)
        case arc(ShapeArc)
        case box(IBox)
    }

    public let board: SnapBoard
    public var magnetic: MagneticSettings
    /// m_enableSnap (Shift turns it off), m_enableGrid (Ctrl, or the grid not snapped to), m_enableSnapLine
    public var enableSnap = true
    public var enableGrid = true
    public var enableSnapLine = true
    /// A point not snapped to by a snap line (SetSkipPoint: the start of the line being drawn)
    public var skipPoint: IPoint?
    /// The grid's auxiliary axes (SetAuxAxes: through where a move started)
    public var auxAxis: IPoint?

    /// m_snapItem: the anchor last snapped to
    public private(set) var snapItem: Anchor?
    /// SNAP_LINE_MANAGER: the snap line's origin and end, its directions, the one it now runs in
    public private(set) var snapLineOrigin: IPoint?
    public private(set) var snapLineEnd: IPoint?
    public private(set) var directions: [IPoint] = [IPoint(1, 0), IPoint(0, 1)]
    var activeDirection: Int?
    /// The anchors the last BestSnapAnchor found (for showing them), and m_pointOnLineCandidates
    public private(set) var anchors: [Anchor] = []
    var pointOnLineCandidates: [Geometry] = []
    /// The construction geometry (SNAP_MANAGER's CONSTRUCTION_MANAGER), and the points of it the pointer does not snap
    /// to but a snap line may go through (SetReferenceOnlyPoints: the ends of the point editor's item)
    public internal(set) var construction = ConstructionManager()
    public internal(set) var referenceOnlyPoints: [IPoint] = []

    public init(board: SnapBoard, magnetic: MagneticSettings = MagneticSettings()) {
        self.board = board
        self.magnetic = magnetic
    }

    /// GRID_HELPER::FullReset: the snap line and the construction geometry forgotten (SNAP_MANAGER::Clear; the
    /// anchors found, which the next BestSnapAnchor finds again); the anchor snapped to, the skip point and the
    /// reference-only points kept, as KiCad keeps them
    public mutating func fullReset() {
        clearSnapLine()
        construction.clear()
        anchors = []
    }

    /// ClearSkipPoint
    public mutating func clearSkipPoint() { skipPoint = nil }

    // MARK: Snap lines (SNAP_LINE_MANAGER)

    static func normalizeDirection(_ d: IPoint) -> IPoint {
        if d.x == 0 && d.y == 0 { return .zero }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = gcd(abs(d.x), abs(d.y))
        var dx = d.x, dy = d.y
        if g > 0 {
            dx /= g
            dy /= g
        }
        if dx < 0 || (dx == 0 && dy < 0) {
            dx = -dx
            dy = -dy
        }
        return IPoint(dx, dy)
    }

    func directionIndex(_ delta: IPoint) -> Int? {
        let n = Self.normalizeDirection(delta)
        if n == .zero { return nil }
        return directions.firstIndex(of: n)
    }

    /// SetSnapLineDirections (a move's: those the angle snap mode lets it go in)
    public mutating func setSnapLineDirections(_ dirs: [IPoint]) {
        var unique: [IPoint] = []
        for d in dirs {
            let n = Self.normalizeDirection(d)
            if n != .zero && !unique.contains(n) { unique.append(n) }
        }
        guard unique != directions else { return }
        directions = unique
        activeDirection = nil
        if let o = snapLineOrigin, let e = snapLineEnd, directionIndex(e - o) == nil { snapLineEnd = nil }
        if directions.isEmpty { clearSnapLine() }
    }

    public mutating func setSnapLineOrigin(_ p: IPoint) {
        if snapLineOrigin == p && snapLineEnd == nil { return }
        snapLineOrigin = p
        snapLineEnd = nil
        activeDirection = nil
    }

    mutating func setSnapLineEnd(_ p: IPoint?) {
        guard let o = snapLineOrigin, p != snapLineEnd else { return }
        snapLineEnd = p
        activeDirection = p.flatMap { directionIndex($0 - o) }
    }

    public mutating func clearSnapLine() {
        snapLineOrigin = nil
        snapLineEnd = nil
        activeDirection = nil
    }

    mutating func setSnappedAnchor(_ p: IPoint) {
        if let o = snapLineOrigin {
            if directionIndex(p - o) != nil { setSnapLineEnd(p) } else { setSnapLineOrigin(p) }
        } else {
            setSnapLineOrigin(p)
        }
    }

    /// SNAP_LINE_MANAGER::GetNearestSnapLinePoint
    func nearestSnapLinePoint(_ cursor: IPoint, nearestGrid: IPoint, distToNearest: Int?, snapRange: Int, gridSize: DPoint,
                              gridOrigin: IPoint) -> IPoint? {
        guard let o = snapLineOrigin, !directions.isEmpty else { return nil }
        let gridBetterThanNearest = distToNearest == nil || distToNearest! > snapRange
        let gridActive = gridSize.x > 0 && gridSize.y > 0
        if !gridBetterThanNearest { return nil }
        let escapeRange = 2 * snapRange
        let origin = DPoint(o), cur = DPoint(cursor)
        let delta = cur - origin
        var bestPerp = Double.greatestFiniteMagnitude
        var best: IPoint?
        for direction in directions {
            let dir = DPoint(direction)
            let len = dir.norm
            if len == 0 { continue }
            let unit = dir / len
            let along = delta.x * unit.x + delta.y * unit.y
            let projection = origin + unit * along
            let offset = delta - unit * along
            let perp = offset.norm
            if perp > Double(snapRange) { continue }
            if perp >= Double(escapeRange) {
                let diff = (EDAAngle(delta) - EDAAngle(dir)).normalized180.degrees
                if abs(diff) > 4 { continue }
            }
            var snap = projection
            if gridActive {
                if direction.x == 0 && direction.y != 0 {
                    snap = DPoint(origin.x, Double(nearestGrid.y))
                } else if direction.y == 0 && direction.x != 0 {
                    snap = DPoint(Double(nearestGrid.x), origin.y)
                } else {
                    snap = Self.diagonalGridPoint(projection, origin: origin, unit: unit, cursor: cur, grid: gridSize,
                                                  gridOrigin: DPoint(gridOrigin))
                }
            }
            if perp < bestPerp {
                bestPerp = perp
                best = snap.rounded
            }
        }
        return best
    }

    /// The grid point near a diagonal line's projection that is nearest the line (and the cursor, a tenth as much)
    static func diagonalGridPoint(_ projection: DPoint, origin: DPoint, unit: DPoint, cursor: DPoint, grid: DPoint,
                                  gridOrigin: DPoint) -> DPoint {
        let rel = projection - gridOrigin
        var bestScore = Double.greatestFiniteMagnitude
        var bestPt = projection
        for dx in -1...1 {
            for dy in -1...1 {
                let gx = (rel.x / grid.x).rounded(.toNearestOrAwayFromZero) * grid.x + Double(dx) * grid.x
                let gy = (rel.y / grid.y).rounded(.toNearestOrAwayFromZero) * grid.y + Double(dy) * grid.y
                let pt = DPoint(gx + gridOrigin.x, gy + gridOrigin.y)
                let gd = pt - origin
                let ga = gd.x * unit.x + gd.y * unit.y
                let gproj = origin + unit * ga
                let perp = (pt - gproj).norm
                let score = perp + (pt - cursor).norm * 0.1
                if score < bestScore {
                    bestScore = score
                    bestPt = pt
                }
            }
        }
        return bestPt
    }

    /// GRID_HELPER::SnapToConstructionLines: the snap lines through the snap line's origin, the one the pointer is
    /// nearest (half as far again for the one it now runs in), at the grid's point along it
    func snapToConstructionLines(_ point: IPoint, nearestGrid: IPoint, grid: DPoint, snapRange: Double, view: SnapView) -> IPoint? {
        guard let o = snapLineOrigin, !directions.isEmpty else { return nil }
        let origin = DPoint(o), cur = DPoint(point)
        let delta = cur - origin
        var best: IPoint?
        var bestPerp = Double.greatestFiniteMagnitude, bestDistance = Double.greatestFiniteMagnitude
        for (i, dir) in directions.enumerated() {
            let v = DPoint(dir)
            let len = v.norm
            if len == 0 { continue }
            let unit = v / len
            let along = delta.x * unit.x + delta.y * unit.y
            let projection = origin + unit * along
            let perp = (delta - unit * along).norm
            var threshold = snapRange
            if activeDirection == i { threshold *= 1.5 }
            if perp > threshold { continue }
            var candidate = projection
            if canUseGrid(view) {
                if dir.x == 0 && dir.y != 0 {
                    candidate = DPoint(origin.x, Double(nearestGrid.y))
                } else if dir.y == 0 && dir.x != 0 {
                    candidate = DPoint(Double(nearestGrid.x), origin.y)
                } else {
                    candidate = Self.diagonalGridPoint(projection, origin: origin, unit: unit, cursor: cur, grid: grid,
                                                       gridOrigin: DPoint(view.gridOrigin))
                }
            }
            let c = candidate.rounded
            if c == skipPoint { continue }
            let distance = DPoint(c - point).norm
            if perp < bestPerp || (abs(perp - bestPerp) < 1e-9 && distance < bestDistance) {
                bestPerp = perp
                bestDistance = distance
                best = c
            }
        }
        return best
    }

    // MARK: The grid

    func canUseGrid(_ view: SnapView) -> Bool { enableGrid && view.gridSnapping }

    /// GRID_HELPER::Align: the point of the grid of `kind` nearest `p` (its auxiliary axes where nearer); `p` with
    /// no grid
    public func align(_ p: IPoint, view: SnapView, grid kind: GridKind = .current) -> IPoint {
        guard canUseGrid(view) else { return p }
        let g = view.gridSize(kind), o = view.gridOrigin
        var n = IPoint(KiMath.round(Double(p.x - o.x) / Double(g.x)) * g.x + o.x, KiMath.round(Double(p.y - o.y) / Double(g.y)) * g.y + o.y)
        if let aux = auxAxis {
            if abs(aux.x - p.x) < abs(n.x - p.x) { n.x = aux.x }
            if abs(aux.y - p.y) < abs(n.y - p.y) { n.y = aux.y }
        }
        return n
    }

    // MARK: BestSnapAnchor

    /// PCB_GRID_HELPER::BestSnapAnchor: where the pointer at `origin` goes, snapping to the items on `layers` (KiCad
    /// ids; all of them with the Magnetic Points' all layers; none of them, empty) but those of `skip` (their uuids,
    /// with what is in them), else to the grid of `grid`'s kind
    public mutating func bestSnapAnchor(_ origin: IPoint, layers: Set<Int>, view: SnapView, grid kind: GridKind = .current,
                                        skip: Set<String> = []) -> IPoint {
        let snapSize = 25.0
        let snapScale = view.worldPerPixel * snapSize
        let snapRange = KiMath.round(enableGrid ? min(snapScale, view.visibleGrid.x) : snapScale)
        let horizon = IBox(minX: KiMath.round(Double(origin.x) - Double(snapRange) / 2), minY: KiMath.round(Double(origin.y) - Double(snapRange) / 2),
                           maxX: KiMath.round(Double(origin.x) - Double(snapRange) / 2 + Double(snapRange)),
                           maxY: KiMath.round(Double(origin.y) - Double(snapRange) / 2 + Double(snapRange)))
        let visible = queryVisible(horizon, view: view, skip: skip)
        computeAnchors(visible, origin, view: view, layers: layers)
        let nearest = nearestAnchor(origin, .snappable, involvedOnly: view.extensionSnaps)
        let nearestGrid = align(origin, view: view, grid: kind)
        let gridSize = DPoint(view.gridSize(kind))
        // (SnapHysteresis: 5 pixels)
        let hysteresis = KiMath.round(view.worldPerPixel * 5)
        let snapIn = max(0, snapRange - hysteresis), snapOut = snapRange + hysteresis
        var snapDist: Int? = nearest.map { Int($0.distance(origin)) }
        if let s = snapItem {
            let existing = Int(s.distance(origin))
            if snapDist == nil || existing < snapDist! { snapDist = existing }
        }
        // (a point of the construction geometry not snapped to, a snap line going through it)
        func referenceOnly(_ p: IPoint) -> Bool { referenceOnlyPoints.contains(p) }
        var snapValid = false
        if enableSnap {
            // (existing snap lines before new snaps)
            if enableSnapLine {
                var lineSnap = nearestSnapLinePoint(origin, nearestGrid: nearestGrid, distToNearest: snapDist, snapRange: snapRange,
                                                    gridSize: gridSize, gridOrigin: view.gridOrigin)
                if lineSnap == nil {
                    lineSnap = snapToConstructionLines(origin, nearestGrid: nearestGrid, grid: gridSize, snapRange: Double(snapRange), view: view)
                }
                if let l = lineSnap, l != skipPoint {
                    // (an anchor near enough before a grid point along the line)
                    let preferAnchor = nearest.map { $0.distance(origin) <= Double(snapIn) } ?? false
                    if !preferAnchor {
                        setSnapLineEnd(l)
                        snapValid = true
                        if !referenceOnly(l) { return l }
                    }
                }
            }
            if let s = snapItem {
                if Int(s.distance(origin)) <= snapOut {
                    if let n = nearest, referenceOnly(n.pos), n.distance(origin) <= Double(snapRange) { setSnapLineOrigin(n.pos) }
                    setSnappedAnchor(s.pos)
                    return s.pos
                }
                snapItem = nil
            }
            if let n = nearest, n.distance(origin) <= Double(snapIn) {
                if referenceOnly(n.pos) {
                    // (not snapped to, but the snap line from it)
                    setSnapLineOrigin(n.pos)
                } else {
                    // (an item's own point, not a crossing, proposes the item's construction geometry)
                    if !n.flags.contains(.constructed) { proposeConstruction(for: n.items, layers: layers, view: view) }
                    snapItem = n
                    setSnappedAnchor(n.pos)
                    return n.pos
                }
                snapValid = true
            } else if view.extensionSnapsOnHover {
                // (an exact hit on an item, off its points, proposes it too)
                for i in visible where board.hitTest(i, origin) {
                    proposeConstruction(for: [i], layers: layers, view: view)
                    snapValid = true
                    break
                }
            }
            // (on-element snaps where there is no grid to snap to)
            if !enableGrid, let p = Self.nearestPoint(pointOnLineCandidates, origin), DPoint(p - origin).norm <= Double(snapRange) {
                // (the snap line's end cleared, its origin kept)
                setSnapLineEnd(nil)
                return p
            }
        }
        snapItem = nil
        if !snapValid { construction.cancelProposal() }
        setSnapLineEnd(nil)
        return nearestGrid
    }

    /// The item an anchor snapped to is of (GetSnapped), by index (the item itself for the point editor's copy of it)
    public var snapped: Int? {
        guard let first = snapItem?.items.first, let i = first else { return nil }
        return i >= 0 ? i : -1 - i
    }

    // MARK: The items near the pointer, and their anchors

    /// queryVisible: the items the view shows whose boxes meet `area`, but those of `skip` and their footprints'
    func queryVisible(_ area: IBox, view: SnapView, skip: Set<String>) -> [Int] {
        var out: [Int] = []
        for (i, item) in board.items.enumerated() where item.box.intersects(area) && view.shows(item, in: board) {
            if skip.contains(item.uuid) { continue }
            if let fp = item.footprint, skip.contains(board.items[fp].uuid) { continue }
            out.append(i)
        }
        return out
    }

    mutating func addAnchor(_ p: IPoint, _ flags: Flags, _ item: Int?) {
        anchors.append(Anchor(pos: p, flags: flags, items: [item]))
    }

    /// computeAnchors of the items (not for a drag: their intersections too, and their geometry kept for snapping
    /// to points on them)
    mutating func computeAnchors(_ indices: [Int], _ refPos: IPoint, view: SnapView, layers: Set<Int>) {
        anchors = []
        var intersectables: [(item: Int?, geometry: Geometry)] = []
        for i in indices {
            let item = board.items[i]
            // (an item on none of the layers asked for, but with the Magnetic Points' all layers)
            if !magnetic.allLayers && Set(item.layers).isDisjoint(with: layers) { continue }
            computeAnchors(i, refPos, view: view)
            if let g = Self.intersectable(item) { intersectables.append((i, g)) }
        }
        // (the construction items, SNAP_MANAGER::GetConstructionItems: the construction geometry taken, then the snap
        // lines through the snap line's origin, of no item; their points snapped to as they are)
        for batch in constructionItems() {
            for c in batch {
                for d in c.constructions {
                    switch d {
                    case .line(let l): intersectables.append((c.item, .line(l)))
                    case .halfLine(let h): intersectables.append((c.item, .halfLine(h)))
                    case .circle(let circle): intersectables.append((c.item, .circle(circle)))
                    case .arc(let arc): intersectables.append((c.item, .arc(arc)))
                    case .point(let p): anchors.append(Anchor(pos: p, flags: [.snappable, .constructed], items: [c.item]))
                    }
                }
            }
        }
        for a in intersectables.indices {
            for b in (a + 1)..<max(a + 1, intersectables.count) where b < intersectables.count {
                if intersectables[a].item == intersectables[b].item { continue }
                for p in Self.intersections(intersectables[b].geometry, intersectables[a].geometry) {
                    anchors.append(Anchor(pos: p, flags: [.snappable, .constructed],
                                          items: [intersectables[a].item, intersectables[b].item]))
                }
            }
        }
        pointOnLineCandidates = intersectables.map(\.geometry)
    }

    /// GetBoardIntersectable: a graphic's line, circle, arc or rectangle; a track's line, an arc track's arc
    static func intersectable(_ item: SnapBoard.Item) -> Geometry? {
        switch item.kind {
        case .shape:
            guard let d = item.drawing else { return nil }
            switch d.kind {
            case .segment: return .seg(Seg(d.start, d.end))
            case .circle: return .circle(Circle(d.start, d.radius))
            case .arc: return .arc(ShapeArc(start: d.start, mid: item.mid, end: d.end))
            case .rect: return .box(IBox(d.start, d.end))
            default: return nil
            }
        case .track: return .seg(Seg(item.start, item.end))
        case .arc: return .arc(ShapeArc(start: item.start, mid: item.mid, end: item.end))
        default: return nil
        }
    }

    /// INTERSECTION_VISITOR of `b` against `a` (findIntersections: a rectangle as its four sides)
    static func intersections(_ a: Geometry, _ b: Geometry) -> [IPoint] {
        func sides(_ box: IBox) -> [Seg] {
            let c = [IPoint(box.minX, box.minY), IPoint(box.maxX, box.minY), IPoint(box.maxX, box.maxY), IPoint(box.minX, box.maxY)]
            return [Seg(c[0], c[1]), Seg(c[1], c[2]), Seg(c[2], c[3]), Seg(c[3], c[0])]
        }
        func segSeg(_ s: Seg, _ t: Seg) -> [IPoint] { s.intersect(t).map { [$0] } ?? [] }
        func segCircle(_ s: Seg, _ c: Circle) -> [IPoint] { c.intersect(s) }
        func segArc(_ s: Seg, _ arc: ShapeArc) -> [IPoint] { arc.intersectLine(s).filter { s.contains($0) } }
        func arcCircle(_ arc: ShapeArc, _ c: Circle) -> [IPoint] {
            guard arc.radius < Double(Int32.max) / 2 else { return [] }
            return Circle(arc.center, KiMath.cInt(arc.radius)).intersect(c).filter { arc.sliceContainsPoint($0) }
        }
        func arcArc(_ x: ShapeArc, _ y: ShapeArc) -> [IPoint] {
            guard x.radius < Double(Int32.max) / 2, y.radius < Double(Int32.max) / 2 else { return [] }
            return Circle(x.center, KiMath.cInt(x.radius)).intersect(Circle(y.center, KiMath.cInt(y.radius)))
                .filter { x.sliceContainsPoint($0) && y.sliceContainsPoint($0) }
        }
        func lineSeg(_ line: Seg, _ s: Seg) -> [IPoint] {
            // (LINE::Intersect( SEG ): as two lines, where it is on the segment)
            guard let p = s.intersect(line, lines: true), s.contains(p) else { return [] }
            return [p]
        }
        func halfLineSeg(_ h: Seg, _ s: Seg) -> [IPoint] { halfLineIntersect(h, s).map { [$0] } ?? [] }
        func onHalfLine(_ h: Seg, _ pts: [IPoint]) -> [IPoint] { pts.filter { halfLineContains(h, $0) } }
        // (the visitor's dispatch: `a` the visited geometry, `b` the other)
        switch (a, b) {
        case (.line(let l), .seg(let s)), (.seg(let s), .line(let l)): return lineSeg(l, s)
        // (LINE::Intersect( LINE ) of the other with the visited: the visited's segment's, as lines)
        case (.line(let l), .line(let m)): return l.intersect(m, lines: true).map { [$0] } ?? []
        case (.line(let l), .circle(let c)), (.circle(let c), .line(let l)): return c.intersectLine(l)
        case (.line(let l), .arc(let arc)), (.arc(let arc), .line(let l)): return arc.intersectLine(l)
        case (.line(let l), .box(let r)): return sides(r).flatMap { lineSeg(l, $0) }
        case (.halfLine(let h), .seg(let s)), (.seg(let s), .halfLine(let h)): return halfLineSeg(h, s)
        // (HALF_LINE::Intersect( HALF_LINE ) of the other with the visited)
        case (.halfLine(let h), .halfLine(let other)): return halfLineIntersect(other, halfLine: h).map { [$0] } ?? []
        case (.halfLine(let h), .line(let l)), (.line(let l), .halfLine(let h)): return lineHalfLineIntersect(l, h).map { [$0] } ?? []
        case (.halfLine(let h), .circle(let c)), (.circle(let c), .halfLine(let h)): return onHalfLine(h, c.intersectLine(h))
        case (.halfLine(let h), .arc(let arc)), (.arc(let arc), .halfLine(let h)): return onHalfLine(h, arc.intersectLine(h))
        case (.halfLine(let h), .box(let r)): return sides(r).flatMap { halfLineSeg(h, $0) }
        case (.seg(let s), .box(let r)): return sides(r).flatMap { segSeg(s, $0) }
        case (.seg(let s), .seg(let t)): return segSeg(s, t)
        case (.seg(let s), .circle(let c)): return segCircle(s, c)
        case (.seg(let s), .arc(let arc)): return segArc(s, arc)
        case (.circle(let c), .seg(let s)): return segCircle(s, c)
        case (.circle(let c), .circle(let d)): return c.intersect(d)
        case (.circle(let c), .arc(let arc)): return arcCircle(arc, c)
        case (.circle(let c), .box(let r)): return sides(r).flatMap { segCircle($0, c) }
        case (.arc(let arc), .seg(let s)): return segArc(s, arc)
        case (.arc(let arc), .circle(let c)): return arcCircle(arc, c)
        case (.arc(let x), .arc(let y)): return arcArc(x, y)
        case (.arc(let arc), .box(let r)): return sides(r).flatMap { segArc($0, arc) }
        case (.box(let r), _): return sides(r).flatMap { intersections(.seg($0), b) }
        }
    }

    /// GetNearestPoint of the geometries: the nearest point on any of them (their distances cut to whole nanometres)
    static func nearestPoint(_ geoms: [Geometry], _ p: IPoint) -> IPoint? {
        var best: IPoint?
        var bestDistance = Int.max
        for g in geoms {
            let n = nearest(g, p)
            let d = Int(DPoint(n - p).norm)
            if best == nil || d < bestDistance {
                best = n
                bestDistance = d
            }
        }
        return best
    }

    /// GetNearestPoint of one geometry (a rectangle's: the nearest of its sides' nearest points, the last of equals)
    static func nearest(_ g: Geometry, _ p: IPoint) -> IPoint {
        switch g {
        case .seg(let s): return s.nearestPoint(p)
        // (LINE::NearestPoint: on the whole line; HALF_LINE's: from its start on)
        case .line(let l): return l.lineProject(p)
        case .halfLine(let h): return halfLineNearest(h, p)
        case .circle(let c): return c.nearestPoint(p)
        case .arc(let a): return a.nearestPoint(p)
        case .box(let r):
            let c = [IPoint(r.minX, r.minY), IPoint(r.maxX, r.minY), IPoint(r.maxX, r.maxY), IPoint(r.minX, r.maxY)]
            var nearest = IPoint.zero, best = Int.max
            for i in 0..<4 {
                let n = Seg(c[i], c[(i + 1) % 4]).nearestPoint(p)
                let d = Int(DPoint(n - p).norm)
                if d <= best {
                    nearest = n
                    best = d
                }
            }
            return nearest
        }
    }

    /// computeAnchors of one item (snapping to it, not dragging it: aFrom false), as the view shows it
    mutating func computeAnchors(_ i: Int, _ refPos: IPoint, view: SnapView) {
        let item = board.items[i]
        let a = view.appearance
        func checkVisibility(_ it: SnapBoard.Item) -> Bool {
            !view.isHighContrast || it.layers.contains(a.activeLayer)
        }
        switch item.kind {
        case .footprint:
            let footprintVisible = checkVisibility(item)
            if magnetic.pads == .captureAlways {
                for p in item.pads where board.items[p].ownBox?.contains(refPos) ?? false {
                    let pad = board.items[p]
                    guard view.shows(pad, in: board), checkVisibility(pad) else { continue }
                    if !view.isHighContrast || KiCadLayers.isCopper(a.activeLayer) { padAnchors(p) }
                }
            }
            for q in item.points { addAnchor(q, [.origin, .snappable], i) }
            if !footprintVisible { break }
            // (not where its side's footprints are hidden)
            guard item.side == 2 ? a.isVisible(.footprintsBack) : a.isVisible(.footprintsFront) else { break }
            addAnchor(item.start, [.origin, .snappable], i)
            let g = view.grid
            if (item.center - item.start).squaredNorm > g.x * g.x + g.y * g.y { addAnchor(item.center, [.origin, .snappable], i) }
        case .pad:
            guard magnetic.pads == .captureAlways, checkVisibility(item) else { break }
            if !view.isHighContrast || KiCadLayers.isCopper(a.activeLayer) { padAnchors(i) }
        case .shape:
            guard magnetic.graphics, checkVisibility(item), let d = item.drawing else { break }
            shapeAnchors(d, item.mid, i, refPos)
        case .track, .arc:
            guard magnetic.tracks == .captureAlways, checkVisibility(item) else { break }
            addAnchor(item.start, [.corner, .snappable], i)
            addAnchor(item.end, [.corner, .snappable], i)
            if item.kind == .arc {
                // (GetArcAnchors: its middle; its centre an origin, not snapped to)
                addAnchor(item.mid, [.corner, .snappable], i)
                addAnchor(item.center, .origin, i)
            } else {
                // (BOARD_ITEM::GetCenter: its box's centre)
                addAnchor(IBox(item.start, item.end).center, .origin, i)
            }
        case .target:
            addAnchor(item.start, [.origin, .corner, .snappable], i)
        case .via:
            guard magnetic.tracks == .captureAlways, checkVisibility(item) else { break }
            addAnchor(item.start, [.origin, .corner, .snappable], i)
        case .zone:
            guard checkVisibility(item) else { break }
            for q in item.points { addAnchor(q, [.corner, .snappable], i) }
            addAnchor(LineChain(item.points, closed: true).nearestPoint(refPos), .outline, i)
        case .point:
            addAnchor(item.start, [.origin, .snappable], i)
        }
    }

    /// handlePadShape: a pad's centre, and the key points of its shape and its hole
    mutating func padAnchors(_ i: Int) {
        guard let p = board.items[i].pad else { return }
        addAnchor(p.pos, [.origin, .snappable], i)
        let outline: Flags = [.outline, .snappable]
        switch p.kind {
        case .circle:
            for q in Self.circleKeyPoints(p.shapePos, p.size.x / 2, includeCenter: false) { addAnchor(q, outline, i) }
        case .oval:
            for q in Self.ovalKeyPoints(size: p.size, center: p.pos, rotation: p.orientation) { addAnchor(q, outline, i) }
        case .rect, .trapezoid, .roundrect, .chamferedRect:
            let half = p.size.divided(by: 2)
            let trap = p.kind == .trapezoid ? p.delta.divided(by: 2) : .zero
            var corners = [IPoint(-half.x - trap.y, half.y + trap.x), IPoint(half.x + trap.y, half.y - trap.x),
                           IPoint(half.x - trap.y, -half.y + trap.x), IPoint(-half.x + trap.y, -half.y - trap.x)]
            corners = corners.map { KiMath.rotate($0, p.orientation) + p.shapePos }
            for k in 0..<4 {
                let s = Seg(corners[k], corners[(k + 1) % 4])
                addAnchor(s.a, outline, i)
                addAnchor(s.center, outline, i)
                if k == 3 { addAnchor(s.b, outline, i) }
            }
        case .custom:
            for q in board.items[i].points { addAnchor(q, outline, i) }
        }
        if p.drill.x > 0 && p.drill.y > 0 {
            let pts = p.drill.x == p.drill.y ? Self.circleKeyPoints(p.pos, p.drill.x / 2, includeCenter: true)
                : Self.ovalKeyPoints(size: p.drill, center: p.pos, rotation: p.orientation)
            for q in pts { addAnchor(q, outline, i) }
        }
    }

    /// handleShape: a graphic's ends, corners, middles, centre, quadrants
    mutating func shapeAnchors(_ d: BoardWorld.Drawing, _ mid: IPoint, _ i: Int, _ refPos: IPoint) {
        let snap: Flags = [.corner, .snappable]
        switch d.kind {
        case .circle:
            let r = KiMath.round(DPoint(d.start - d.end).norm)
            addAnchor(d.start, [.origin, .snappable], i)
            for q in [IPoint(-r, 0), IPoint(r, 0), IPoint(0, -r), IPoint(0, r)] { addAnchor(d.start + q, [.outline, .snappable], i) }
        case .arc:
            addAnchor(d.start, snap, i)
            addAnchor(d.end, snap, i)
            addAnchor(mid, snap, i)
            addAnchor(d.center, [.origin, .snappable], i)
        case .rect:
            let box = IBox(d.start, d.end)
            let tl = IPoint(box.minX, box.minY), tr = IPoint(box.maxX, box.minY), br = IPoint(box.maxX, box.maxY), bl = IPoint(box.minX, box.maxY)
            addAnchor(box.center, snap, i)
            for (p, q) in [(tl, tr), (tr, br), (br, bl), (bl, tl)] {
                addAnchor(p, snap, i)
                addAnchor(Seg(p, q).center, snap, i)
            }
        case .segment:
            addAnchor(d.start, snap, i)
            addAnchor(d.end, snap, i)
            // (EDA_SHAPE::GetCenter of a line: its middle)
            addAnchor(d.start + (d.end - d.start).divided(by: 2), snap, i)
        case .poly:
            for q in d.poly { addAnchor(q, snap, i) }
            addAnchor(LineChain(d.poly, closed: true).nearestPoint(refPos), .outline, i)
        case .bezier:
            addAnchor(d.start, snap, i)
            addAnchor(d.end, snap, i)
            addAnchor(d.start, [.origin, .snappable], i)
        }
    }

    /// KIGEOM::GetCircleKeyPoints: its quadrants (and centre)
    static func circleKeyPoints(_ c: IPoint, _ r: Int, includeCenter: Bool) -> [IPoint] {
        (includeCenter ? [IPoint.zero] : []).map { $0 + c } + [IPoint(0, r), IPoint(r, 0), IPoint(0, -r), IPoint(-r, 0)].map { $0 + c }
    }

    /// EDA_ANGLE::IsCardinal: a multiple of 90°
    static func isCardinal(_ a: EDAAngle) -> Bool {
        var t = a.degrees
        while t < 0 { t += 90 }
        while t >= 90 { t -= 90 }
        return t == 0
    }

    /// KIGEOM::GetOvalKeyPoints of SHAPE_SEGMENT::BySizeAndCenter (centre, cap tips, side midpoints, and where it is
    /// turned off square, its cardinal extremes)
    static func ovalKeyPoints(size: IPoint, center: IPoint, rotation r: EDAAngle) -> [IPoint] {
        var segVec = IPoint.zero
        let width: Int
        if size.x > size.y {
            width = size.y
            segVec.x = size.x - width
        } else {
            width = size.x
            segVec.y = size.y - width
        }
        segVec = KiMath.rotate(segVec, r)
        let a = center - segVec.divided(by: 2), b = center + segVec.divided(by: 2)
        let seg = Seg(a, b)
        let halfWidth = width / 2
        let halfLen = (seg.length + width) / 2
        let rotation = EDAAngle(b - a) - .a90
        var pts: [IPoint] = [.zero, IPoint(halfWidth, 0), IPoint(-halfWidth, 0), IPoint(0, halfLen), IPoint(0, -halfLen)]
        let toCap = halfLen - halfWidth
        if !isCardinal(rotation) {
            let radial = IPoint(0, halfWidth)
            var rot = rotation.normalized90
            let toX = KiMath.rotate(radial, rot)
            rot = (rot - .a90).normalized90
            let toY = KiMath.rotate(radial, rot)
            pts += [IPoint(0, toCap) + toY, IPoint(0, toCap) + toX, IPoint(0, -toCap) - toY, IPoint(0, -toCap) - toX]
        }
        return pts.map { KiMath.rotate($0, -rotation) + seg.center }
    }

    /// nearestAnchor: the nearest anchor of the flags (with extension snaps, `involvedOnly`: one made of crossing
    /// geometry not where an item of it is not involved in the construction geometry taken: then, if it is the
    /// nearest, none); of several at the same place, the one of the item nearest the pointer (FindSquareDistanceToItem:
    /// its geometry's nearest point; else the anchor's own distance)
    func nearestAnchor(_ pos: IPoint, _ flags: Flags, involvedOnly: Bool = false) -> Anchor? {
        var minDist = Double.greatestFiniteMagnitude
        var atMin: [Anchor] = []
        for a in anchors where a.flags.isSuperset(of: flags) {
            if let first = atMin.first, a.pos == first.pos {
                atMin.append(a)
            } else {
                let d = DPoint(a.pos - pos).squaredNorm
                if d < minDist {
                    minDist = d
                    atMin = [a]
                }
            }
        }
        if involvedOnly {
            atMin.removeAll { $0.flags.contains(.constructed) && !construction.involvesAll($0.items) }
        }
        var minToItem = Double.greatestFiniteMagnitude
        var best: Anchor?
        for a in atMin {
            var toItem = Double.greatestFiniteMagnitude
            for case let i? in a.items {
                if let g = Self.intersectable(boardItem(i)) {
                    let n = Self.nearest(g, pos)
                    toItem = min(toItem, DPoint(n - pos).squaredNorm)
                }
            }
            toItem = min(toItem, minDist)
            if toItem < minToItem {
                minToItem = toItem
                best = a
            }
        }
        return best
    }
}

// MARK: - The point a selection is picked up by

extension PCBGridHelper {
    /// PCB_GRID_HELPER::GetItemGrid: the grid an item snaps to, by its kind (a footprint's or pad's the connectable
    /// items', a graphic's the graphics', a track's the wires', a via's the vias')
    public func itemGrid(_ i: Int) -> GridKind {
        switch board.items[i].kind {
        case .footprint, .pad: return .connectable
        case .shape: return .graphics
        case .track, .arc: return .wires
        case .via: return .vias
        default: return .current
        }
    }

    /// GRID_HELPER::GetSelectionGrid: of the items' grids, the first item's, or another's that is coarser
    public func selectionGrid(_ indices: [Int], view: SnapView) -> GridKind {
        guard let first = indices.first else { return .current }
        var grid = itemGrid(first)
        for i in indices {
            let g = itemGrid(i)
            // (VECTOR2D's operator >: the longer)
            if view.gridSize(g).squaredNorm > view.gridSize(grid).squaredNorm { grid = g }
        }
        return grid
    }

    /// The board's items of these uuids, by index
    public func indices(of uuids: [String]) -> [Int] {
        uuids.compactMap { u in board.items.firstIndex { $0.uuid == u } }
    }

    /// PCB_GRID_HELPER::BestDragOrigin: the point of the items (by index; a footprint's pads among them as a move has
    /// them) nearest `mouse` to pick them up by: the nearest of their origins (footprints' positions and centres, the
    /// centres of their pads the mouse is on, pads', vias', tracks' middles), else of their corners if nearer, else,
    /// farther than `lineSnapMinCornerDistance` (KiCad's 50 pixels, nm) from both, the nearest point of their
    /// outlines if nearer; the mouse itself where they have none
    public mutating func bestDragOrigin(_ mouse: IPoint, items: [Int], view: SnapView, lineSnapMinCornerDistance: Double) -> IPoint {
        anchors = []
        // (computeAnchors( aFrom, aForDrag ): every item's anchors as a drag's, no layers matched, no intersections)
        for i in items { dragAnchors(i, mouse, view: view) }
        pointOnLineCandidates = []
        let outline = nearestAnchor(mouse, .outline), corner = nearestAnchor(mouse, .corner), origin = nearestAnchor(mouse, .origin)
        var best: Anchor?
        var minDist = Double.greatestFiniteMagnitude
        if let origin {
            minDist = origin.distance(mouse)
            best = origin
        }
        if let corner, corner.distance(mouse) < minDist {
            minDist = corner.distance(mouse)
            best = corner
        }
        if let outline, minDist > lineSnapMinCornerDistance && outline.distance(mouse) < minDist { best = outline }
        return best?.pos ?? mouse
    }

    /// computeAnchors of one item for picking it up by (aFrom true, KiCad's selection filter letting everything
    /// through): pads' centres only, an arc's ends and middle but not its centre, a footprint's position whether it is
    /// shown on the active layer or not (not where its side's footprints are hidden)
    mutating func dragAnchors(_ i: Int, _ refPos: IPoint, view: SnapView) {
        let item = board.items[i]
        let a = view.appearance
        // (checkVisibility of an item being moved: the view's flags not asked, it is on an active layer)
        func checkVisibility(_ it: SnapBoard.Item) -> Bool { !view.isHighContrast || it.layers.contains(a.activeLayer) }
        func padCentre(_ p: Int) {
            guard let pad = board.items[p].pad else { return }
            if !view.isHighContrast || KiCadLayers.isCopper(a.activeLayer) { addAnchor(pad.pos, [.origin, .snappable], p) }
        }
        switch item.kind {
        case .footprint:
            for p in item.pads where board.items[p].ownBox?.contains(refPos) ?? false {
                guard checkVisibility(board.items[p]) else { continue }
                padCentre(p)
            }
            for q in item.points { addAnchor(q, [.origin, .snappable], i) }
            guard item.side == 2 ? a.isVisible(.footprintsBack) : a.isVisible(.footprintsFront) else { break }
            addAnchor(item.start, [.origin, .snappable], i)
            let g = view.grid
            if (item.center - item.start).squaredNorm > g.x * g.x + g.y * g.y { addAnchor(item.center, [.origin, .snappable], i) }
        case .pad:
            if checkVisibility(item) { padCentre(i) }
        case .shape:
            guard checkVisibility(item), let d = item.drawing else { break }
            shapeAnchors(d, item.mid, i, refPos)
        case .track, .arc:
            guard checkVisibility(item) else { break }
            addAnchor(item.start, [.corner, .snappable], i)
            addAnchor(item.end, [.corner, .snappable], i)
            if item.kind == .arc {
                addAnchor(item.mid, [.corner, .snappable], i)
            } else {
                addAnchor(IBox(item.start, item.end).center, .origin, i)
            }
        case .target:
            addAnchor(item.start, [.origin, .corner, .snappable], i)
        case .via:
            if checkVisibility(item) { addAnchor(item.start, [.origin, .corner, .snappable], i) }
        case .zone:
            guard checkVisibility(item) else { break }
            for q in item.points { addAnchor(q, [.corner, .snappable], i) }
            addAnchor(LineChain(item.points, closed: true).nearestPoint(refPos), .outline, i)
        case .point:
            if checkVisibility(item) { addAnchor(item.start, [.origin, .snappable], i) }
        }
    }

    /// GAL::GetGridPoint: the grid's point nearest `p` (where KiCad's view controls put the cursor, which a tool that
    /// asks no grid helper takes: Add Footprint's)
    public static func gridPoint(_ p: DPoint, view: SnapView) -> IPoint {
        let g = view.grid, o = view.gridOrigin
        return IPoint(KiMath.round(Double(KiMath.round((p.x - Double(o.x)) / Double(g.x)) * g.x) + Double(o.x)),
                      KiMath.round(Double(KiMath.round((p.y - Double(o.y)) / Double(g.y)) * g.y) + Double(o.y)))
    }
}

// MARK: - Moving a selection

/// KiCad's Move (EDIT_TOOL::doMoveSelection) as it snaps: the selection picked up by the point of it nearest the
/// mouse (BestDragOrigin), which the pointer goes to (the Move Warps Cursor preference, KiCad's default) and the
/// grid's auxiliary axes go through; then at each motion the pointer snapped (BestSnapAnchor, on the active layer, the
/// selection's grid, the selection itself and what is in it skipped; Shift no snapping to items, Ctrl no grid) and the
/// selection moved by as much as the snapped pointer moved. The angle snap mode's lines (45° or 90°) run from where it
/// was picked up; with its direct mode there are none.
public struct SelectionMove: Sendable {
    public private(set) var helper: PCBGridHelper
    /// Where the selection is picked up (the selection's reference point)
    public let dragOrigin: IPoint
    /// m_cursor: the snapped pointer, and where it was when the move began
    public private(set) var cursor: IPoint
    public let start: IPoint
    let skip: Set<String>
    let grid: GridKind

    /// The move of the items of `uuids` (a footprint's pads with it) begun with the mouse at `mouse`; `cursor`, where
    /// the cursor was then, is where the pointer stays if the move does not warp it there (warpsCursor false)
    public init(board: SnapBoard, items uuids: [String], mouse: IPoint, view: SnapView, magnetic: MagneticSettings,
                angleSnap: LeaderMode = .direct, warpsCursor: Bool = true, cursor: IPoint? = nil) {
        var helper = PCBGridHelper(board: board, magnetic: magnetic)
        let chosen = helper.indices(of: uuids)
        var indices = chosen
        // (sel_items: each footprint's pads after the items selected)
        for i in chosen where board.items[i].kind == .footprint { indices += board.items[i].pads }
        skip = Set(indices.map { board.items[$0].uuid })
        grid = helper.selectionGrid(chosen, view: view)
        let originalCursor = cursor ?? helper.align(mouse, view: view)
        // (configureAngleSnap: the angle snap mode's directions, from where the cursor is)
        switch angleSnap {
        case .deg45: helper.setSnapLineDirections([IPoint(1, 0), IPoint(0, 1), IPoint(1, 1), IPoint(1, -1)])
        case .deg90: helper.setSnapLineDirections([IPoint(1, 0), IPoint(0, 1)])
        case .direct: helper.setSnapLineDirections([])
        }
        if angleSnap == .direct { helper.clearSnapLine() } else { helper.setSnapLineOrigin(originalCursor) }
        // (the drag started: picked up by its point nearest the mouse)
        let origin = helper.bestDragOrigin(mouse, items: indices, view: view, lineSnapMinCornerDistance: 50 * view.worldPerPixel)
        if angleSnap != .direct { helper.setSnapLineOrigin(origin) }
        helper.auxAxis = origin
        dragOrigin = origin
        self.cursor = warpsCursor ? origin : originalCursor
        start = self.cursor
        self.helper = helper
    }

    /// The mouse moved to `mouse` (where the pointer is, warped to the drag origin when the move began): the snapped
    /// pointer, on the active layer's items (`layers`); `shift` snaps to no items, `ctrl` to no grid
    @discardableResult
    public mutating func moved(to mouse: IPoint, layers: Set<Int>, view: SnapView, shift: Bool = false, ctrl: Bool = false) -> IPoint {
        helper.enableSnap = !shift
        helper.enableGrid = !ctrl
        cursor = helper.bestSnapAnchor(mouse, layers: layers, view: view, grid: grid, skip: skip)
        return cursor
    }

    /// How far the selection has moved
    public var offset: IPoint { cursor - start }

    /// The pointer rested long enough for the construction geometry proposed to be taken (PCBGridHelper.rested)
    public mutating func rested() { helper.rested() }
}

// MARK: - The point editor's snapping

/// PCB_POINT_EDITOR's grid helper as the point editor asks it to snap an edit point being dragged: BestSnapAnchor of
/// the item's grid, the item itself skipped, snapping to the items on the item's own layers (OBJECT_LAYERS, an edit
/// point's default), on all of them (ALL_LAYERS, a dimension's ends) or on none (an empty layer set: the grid alone,
/// but with the Magnetic Points' all layers); its auxiliary axes through where a drag of a point began
public struct PointEditorSnap: Sendable {
    public enum Layers: Sendable { case none, item, all }

    public var helper: PCBGridHelper
    public var view: SnapView
    /// The item's layers, its grid, and its uuid
    public var itemLayers: Set<Int>
    public var grid: GridKind
    public var skip: Set<String>

    /// Whether the drag has set its snap lines (updateSnapLineDirections)
    public private(set) var linesSet = false

    public init(helper: PCBGridHelper, view: SnapView, itemLayers: Set<Int>, grid: GridKind, skip: Set<String>) {
        self.helper = helper
        self.view = view
        self.itemLayers = itemLayers
        self.grid = grid
        self.skip = skip
        // (updateSnapLineDirections as a drag starts with the point held to no angle: no snap lines)
        self.helper.setSnapLineDirections([])
    }

    /// The point editor's snapping of the item of `uuid` on `board`, as the item's kind has it (a graphic's grid is
    /// the graphics'), its drag begun: a copy of the item as it was its persistent construction geometry (a line's
    /// line, an arc's circle and centre, their ends a snap line goes through but the pointer does not snap to)
    public init(board: SnapBoard, item uuid: String, magnetic: MagneticSettings, view: SnapView) {
        let helper = PCBGridHelper(board: board, magnetic: magnetic)
        let i = helper.indices(of: [uuid]).first
        self.init(helper: helper, view: view, itemLayers: Set(i.map { board.items[$0].layers } ?? []),
                  grid: i.map(helper.itemGrid) ?? .current, skip: [uuid])
        // (AddConstructionItems( { clone }, false, true ) as the drag starts)
        if let i { self.helper.addConstructionItems([-1 - i], extensionOnly: false, persistent: true, view: view) }
    }

    /// BestSnapAnchor of `p`
    public mutating func snap(_ p: IPoint, _ layers: Layers) -> IPoint {
        let set: Set<Int>
        switch layers {
        case .none: set = []
        case .item: set = itemLayers
        case .all: set = Set(helper.board.items.flatMap(\.layers))
        }
        return helper.bestSnapAnchor(p, layers: set, view: view, grid: grid, skip: skip)
    }

    /// The Shift and Ctrl of the event: no snapping to items, no grid
    public mutating func modifiers(shift: Bool, ctrl: Bool) {
        helper.enableSnap = !shift
        helper.enableGrid = !ctrl
    }

    /// SetAuxAxes at the start of a drag of a point (not of a line moved by whole grid steps, SNAP_BY_GRID)
    public mutating func dragBegun(at p: IPoint) { helper.auxAxis = p }

    /// updateSnapLineDirections: the snap lines of a point held to the angle snap mode's angles from `origin` (where
    /// it is held from: EC_45DEGREE's four directions, EC_90DEGREE's two); none for a point not held so
    public mutating func snapLines(_ mode: LeaderMode, from origin: IPoint?) {
        linesSet = true
        var directions: [IPoint] = []
        if origin != nil {
            switch mode {
            case .deg45: directions = [IPoint(1, 0), IPoint(0, 1), IPoint(1, 1), IPoint(1, -1)]
            case .deg90: directions = [IPoint(1, 0), IPoint(0, 1)]
            case .direct: break
            }
        }
        helper.setSnapLineDirections(directions)
        if let origin, !directions.isEmpty { helper.setSnapLineOrigin(origin) }
        helper.setSnapLineEnd(nil)
    }

    /// After a drag event of a point held to the angle snap mode's angles: the snap lines from where it is held from,
    /// ending where the constraint put it (`end`; none where it was not the constraint that put it there)
    public mutating func snapLinesFollow(from origin: IPoint, to end: IPoint?) {
        helper.setSnapLineOrigin(origin)
        helper.setSnapLineEnd(end)
    }

    /// The grid helper's GetUseGrid, GetGrid and GetSnap
    public var usesGrid: Bool { helper.canUseGrid(view) }
    public var gridSize: IPoint { view.gridSize(grid) }
    public var snaps: Bool { helper.enableSnap }
}

// MARK: - Drawing a zone's outline

/// POLYGON_GEOM_MANAGER as DRAWING_TOOL::DrawZone uses it: the pointer's moves (SetCursorPosition) draw the leader
/// from the last corner to the snapped pointer, in the line mode (the angle snap mode, LEADER_MODE: free, or two lines
/// at 45° or at 90°; Ctrl lets it go free); each click at the snapped pointer locks in the leader's end as a corner
/// (and its bend before it; none where it is the last again: SHAPE_LINE_CHAIN::Append), one on the first corner
/// closes the outline (NewPointClosesOutline), as a double click does. A click with no move given since the last
/// is taken as made where the pointer moved to it.
public struct PolygonDrawing: Sendable {
    var geometry = PolygonGeometry()
    /// The line mode (the editor's angle snap mode)
    public var leaderMode: LeaderMode
    private var moved = false

    public init(leaderMode: LeaderMode = .direct) {
        self.leaderMode = leaderMode
    }

    /// The corners locked in so far
    public var corners: [IPoint] { geometry.locked.points }

    /// The outline as the preview shows it: the corners, the leader to the pointer and, at 45° and 90°, the loop back
    /// to the first corner
    public var preview: [IPoint] {
        var pts = geometry.locked.points
        pts += geometry.leader.points.dropFirst()
        pts += geometry.loop.points.dropFirst().dropLast()
        return pts
    }

    /// The pointer moved to `p` (snapped), `ctrl` (Ctrl) letting the leader go free (SetLeaderMode, SetCursorPosition)
    public mutating func move(to p: IPoint, ctrl: Bool = false) {
        geometry.leaderMode = ctrl ? .direct : leaderMode
        geometry.setCursor(p)
        moved = true
    }

    /// A click at `p` (snapped): whether it closes the outline
    public mutating func click(_ p: IPoint, ctrl: Bool = false) -> Bool {
        geometry.leaderMode = ctrl ? .direct : leaderMode
        if geometry.closesOutline(p) { return true }
        if !moved { geometry.setCursor(p) }
        geometry.addPoint(p)
        moved = false
        return false
    }

    /// DeleteLastCorner
    public mutating func deleteLastCorner() {
        _ = geometry.deleteLastCorner()
        if !geometry.inProgress { geometry.reset() }
    }

    /// ZONE_CREATE_HELPER::OnComplete's outline: none for fewer than three corners; else the corners (and at 45° and
    /// 90° the leader's and the loop's), closed and simplified (SHAPE_LINE_CHAIN::Simplify( true ): its tolerance the
    /// bool's one, a nanometre), the first corner left out where it lies within a nanometre of the line through its
    /// neighbours
    public var outline: [IPoint]? { geometry.completed() }
}
