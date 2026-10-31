// Graphics and dimensions drawn on the board and edited, each as one change, as KiCad's PCB editor commits them
// (KiCad 10.0.7): pcbnew/tools/drawing_tool.cpp (Draw Line, Draw Rectangle, Draw Circle, Draw Arc, Draw Dimension),
// pcbnew/tools/zone_create_helper.cpp (Draw Polygon), pcbnew/tools/pcb_point_editor.cpp (Move Point, PCB_POINT_EDITOR::
// addCorner and removeCorner: Add Zone Corner, Split Segment, Split Arc, Remove Polygon Corner). The graphics' and
// dimensions' geometry is BoardGraphics.swift's and Dimensions.swift's. GNU General Public License version 3 or later,
// as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

extension BoardEditing {
    /// The pens new graphics take on each layer (the project's line widths, KiCad's own where it has none)
    public var lineWidths: LineWidths { LineWidths(project: project) }

    /// What new dimensions take from the project (KiCad's own where it has none)
    public var dimensionDefaults: DimensionDefaults { DimensionDefaults(project: project) }

    /// A drawing tool of `kind` on `layer`, its pens the project's
    public func graphicTool(_ kind: GraphicTool.Kind, layer: String, angleSnap: LeaderMode = .direct) -> GraphicTool {
        GraphicTool(kind, layer: layer, widths: lineWidths, angleSnap: angleSnap)
    }

    /// A dimension tool of `kind` on `layer`, its text and style the project's
    public func dimensionTool(_ kind: BoardDimension.Kind, layer: String, angleSnap: LeaderMode = .direct) -> DimensionTool {
        DimensionTool(kind, layer: layer, defaults: dimensionDefaults, widths: lineWidths, texts: textDefaults, angleSnap: angleSnap)
    }

    /// The names KiCad gives the change that draws each graphic
    static func drawName(_ shape: BoardShape) -> String {
        switch shape.kind {
        case .segment: return "Draw Line"
        case .rectangle: return "Draw Rectangle"
        case .circle: return "Draw Circle"
        case .arc: return "Draw Arc"
        case .polygon: return "Draw Polygon"
        }
    }

    /// A graphic drawn (a GraphicTool's), put on the board after its other drawings, as one change (Edit.drawings has
    /// it; Edit.outline is set for one on Edge.Cuts)
    public func addShape(_ shape: BoardShape) -> Edit? {
        guard !isRouting else { return nil }
        let uuid = KiCadBoard.newUUID()
        router.board.addDrawing(shape.node(uuid: uuid))
        router.boardChanged()
        return change(Self.drawName(shape), outline: shape.layer == "Edge.Cuts", drawings: [uuid])
    }

    /// A dimension drawn (a DimensionTool's), as one change (Draw Dimension)
    public func addDimension(_ dimension: BoardDimension) -> Edit? {
        guard !isRouting else { return nil }
        let uuid = KiCadBoard.newUUID()
        router.board.addDrawing(dimension.node(uuid: uuid))
        router.boardChanged()
        return change("Draw Dimension", drawings: [uuid])
    }

    /// The board's own text, graphic or dimension of id `uuid` (on any layer, its outline's too)
    func drawingNode(_ uuid: String) -> SExpr? {
        router.board.root.items.first { Self.drawingHeads.contains($0.head ?? "") && $0.value("uuid") == uuid }
    }

    static let drawingHeads: Set<String> = KiCadDrawing.heads.union(["gr_text", "gr_text_box", "dimension"])

    /// The board's graphic of id `uuid`, as KiCad reads it (nil for a curve, a polygon with arcs, or none)
    public func shape(_ uuid: String) -> BoardShape? { drawingNode(uuid).flatMap { BoardShape($0) } }

    /// The board's dimension of id `uuid`, as KiCad reads it
    public func dimension(_ uuid: String) -> BoardDimension? { drawingNode(uuid).flatMap(BoardDimension.init) }

    /// A graphic of the board's made `shape` (its point editor's drag, KiCad's Move Point), as one change; nil if it
    /// has no graphic of that id or the graphic is as it was
    public func setShape(_ uuid: String, to shape: BoardShape, name: String = "Move Point") -> Edit? {
        guard !isRouting, let node = drawingNode(uuid), let was = BoardShape(node) else { return nil }
        let before = node.compact
        shape.write(into: node)
        if let layer = node["layer"], shape.layer != was.layer { layer.items[1] = SExpr(string: shape.layer) }
        guard node.compact != before else { return nil }
        router.boardChanged()
        return change(name, outline: shape.layer == "Edge.Cuts" || was.layer == "Edge.Cuts", drawings: [uuid])
    }

    /// PCB_POINT_EDITOR::addCorner with the pointer at `p` (mm): a polygon's nearest side split there (Add Zone
    /// Corner: a side's end there, its middle instead), a line split in two there (Split Segment), an arc split there
    /// (Split Arc); one change, nil for another graphic
    public func addCorner(_ uuid: String, at p: KiCadPoint) -> Edit? {
        guard !isRouting, let node = drawingNode(uuid), var shape = BoardShape(node) else { return nil }
        let cursor = Self.nm(p)
        switch shape.kind {
        case .polygon:
            guard shape.points.count >= 2 else { return nil }
            var nearest = 0, next = 0
            var nearestDist = UInt32.max
            for i in shape.points.indices {
                let j = (i + 1) % shape.points.count
                let d = UInt32(truncatingIfNeeded: Seg(shape.points[i], shape.points[j]).distance(cursor))
                if d < nearestDist {
                    nearestDist = d
                    nearest = i
                    next = j
                }
            }
            let side = Seg(shape.points[nearest], shape.points[next])
            var point = side.nearestPoint(cursor)
            // (VECTOR2I / 2: each coordinate rounded, halves away from nought)
            if point == side.a || point == side.b { point = (side.a + side.b).divided(by: 2) }
            // (SHAPE_POLY_SET::InsertVertex: before the corner the side ends at, the first where it is the closing side)
            shape.points.insert(point, at: next)
            shape.write(into: node)
            router.boardChanged()
            return change("Add Zone Corner", outline: shape.layer == "Edge.Cuts", drawings: [uuid])
        case .segment, .arc:
            let breakPoint: IPoint
            var second = shape
            if shape.kind == .segment {
                breakPoint = Seg(shape.start, shape.end).nearestPoint(cursor)
                second.start = breakPoint
                shape.end = breakPoint
            } else {
                let arc = ShapeArc(start: shape.start, mid: shape.arcMidPoint, end: shape.end)
                breakPoint = arc.nearestPoint(cursor)
                shape.end = breakPoint
                second.end = arc.end
                second.start = breakPoint
            }
            shape.write(into: node)
            let newUUID = KiCadBoard.newUUID()
            let copy = node.copy()
            second.write(into: copy)
            copy["uuid"]?.items[1] = SExpr(string: newUUID)
            router.board.addDrawing(copy)
            router.boardChanged()
            return change(shape.kind == .segment ? "Split Segment" : "Split Arc", outline: shape.layer == "Edge.Cuts", drawings: [uuid, newUUID])
        default:
            return nil
        }
    }

    /// PCB_POINT_EDITOR::removeCorner: a polygon's corner `index` taken away (Remove Polygon Corner); the polygon
    /// taken away where it has three corners or fewer; one change
    public func removeCorner(_ uuid: String, index: Int) -> Edit? {
        guard !isRouting, let node = drawingNode(uuid), var shape = BoardShape(node), shape.kind == .polygon,
              shape.points.indices.contains(index) else { return nil }
        if shape.points.count > 3 {
            shape.points.remove(at: index)
            shape.write(into: node)
        } else {
            router.board.root.remove(node)
        }
        router.boardChanged()
        return change("Remove Polygon Corner", outline: shape.layer == "Edge.Cuts", drawings: [uuid])
    }

    // MARK: - Moving, turning and taking away

    /// The board's texts, graphics and dimensions of these ids, its outline's among them
    func drawingNodes(_ uuids: Set<String>) -> [SExpr] {
        router.board.root.items.filter { Self.drawingHeads.contains($0.head ?? "") && uuids.contains($0.value("uuid") ?? "") }
    }

    /// A drawing node moved by `d` (nm), as KiCad moves the item it is (EDA_SHAPE::move, PCB_DIMENSION_BASE::Move, a
    /// text's position)
    static func move(_ node: SExpr, by d: IPoint) {
        if node.head == "dimension", var dim = BoardDimension(node) {
            dim.move(d)
            replace(node, with: dim)
            return
        }
        if let s = BoardShape(node, normalized: false) {
            var moved = s
            moved.move(d)
            moved.write(into: node)
            return
        }
        // a text, or a polygon with arcs: its points shifted
        func shifted(_ list: SExpr) {
            guard let x = list.number(at: 0), let y = list.number(at: 1) else { return }
            list.items[1] = BoardShape.mm(BoardWorld.iu(x) + d.x).sexpr
            list.items[2] = BoardShape.mm(BoardWorld.iu(y) + d.y).sexpr
        }
        for head in ["at", "start", "end", "center", "mid"] { if let list = node[head] { shifted(list) } }
        for item in node["pts"]?.items ?? [] {
            if item.head == "xy" { shifted(item) }
            if item.head == "arc" { for head in ["start", "mid", "end"] { if let list = item[head] { shifted(list) } } }
        }
    }

    /// A dimension node made `dim` as KiCad writes it, its id and lock kept
    static func replace(_ node: SExpr, with dim: BoardDimension) {
        let made = dim.node(uuid: node.value("uuid") ?? KiCadBoard.newUUID(), locked: node["locked"].map { $0.text(at: 0) != "no" } ?? false)
        node.items = made.items
    }
}
