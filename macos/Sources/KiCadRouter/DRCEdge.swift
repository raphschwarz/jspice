// Ported from KiCad 10.0.7: pcbnew/drc/drc_test_provider_edge_clearance.cpp (copper against the board's edges: the
// R-tree of its Edge.Cuts and Margin drawings, rectangles and outlines cut into their sides, and of unplated slots, and
// each copper item's search of it), pcbnew/drc/drc_engine.cpp (the implicit edge clearance rule), pcbnew/pad.cpp and
// pcbnew/pcb_track.cpp (a pad's and a via's shape as asked of no particular copper layer).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

extension BoardDRC {
    /// One of the edges KiCad's edge clearance check gathers: a drawing on Edge.Cuts or Margin (or a side of one, as
    /// it cuts a rectangle or an outline up), or an unplated slot
    final class EdgeItem {
        let uuid: String
        /// Its shape as the check collides it (PCB_SHAPE::GetEffectiveShape; a slot's hole)
        let shapes: [Shape]
        /// The R-tree's pieces of it (DRC_RTREE::Insert: a pad's hole a second time)
        let indexed: [Shape]

        init(uuid: String, shapes: [Shape], indexed: [Shape]? = nil) {
            self.uuid = uuid
            self.shapes = shapes
            self.indexed = indexed ?? shapes
        }
    }

    struct EdgeEntry {
        let edge: EdgeItem
        let shape: Shape
    }

    /// The pieces DRC_TEST_PROVIDER_EDGE_CLEARANCE::Run makes of a drawing on Edge.Cuts or Margin: an outlined
    /// rectangle's sides (and rounded corners), an outlined polygon's sides, else the drawing whole
    func edgePieces(_ node: SExpr, placement: BoardWorld.FootprintPlacement?) -> [EdgeItem] {
        guard var d = world.readDrawing(node, placement: placement) else { return [] }
        // (on Edge.Cuts its line has no width)
        if node.value("layer") == "Edge.Cuts" { d.width = 0 }
        let uuid = node.value("uuid") ?? ""
        switch d.kind {
        case .rect where !d.filled && d.cornerRadius == 0:
            // (each a copy of the rectangle made a segment, its end's x, its end's y, its start's x or its start's
            // y set to the other corner's)
            let (s, e) = (d.start, d.end)
            return [Seg(s, IPoint(s.x, e.y)), Seg(s, IPoint(e.x, s.y)), Seg(IPoint(e.x, s.y), e), Seg(IPoint(s.x, e.y), e)]
                .map { EdgeItem(uuid: uuid, shapes: [.segment($0, width: d.width)]) }
        case .rect where !d.filled:
            // (MakeEffectiveShapes( true ): its sides and rounded corners, each a copy of the rectangle made a segment
            // or an arc, an arc's geometry set by its ends and middle, and its shape made again from that)
            return (world.effectiveShapes(d) ?? []).map { s in
                guard case .arc(let a) = s else { return EdgeItem(uuid: uuid, shapes: [s]) }
                var arc = BoardWorld.arcDrawing(a.start, a.mid, a.end)
                arc.width = d.width
                return EdgeItem(uuid: uuid, shapes: world.effectiveShapes(arc) ?? [s])
            }
        case .poly where !d.filled:
            // (its outline's sides, each one of its own)
            return (world.effectiveShapes(d) ?? []).map { EdgeItem(uuid: uuid, shapes: [$0]) }
        default:
            guard let shapes = world.effectiveShapes(d), !shapes.isEmpty else { return [] }
            return [EdgeItem(uuid: uuid, shapes: shapes)]
        }
    }

    /// The edges' R-trees, Edge.Cuts' and Margin's: the board's drawings on them, then the footprints', in the order
    /// forEachGeometryItem gathers them, and then the unplated slots (drilled round holes are hole clearances' to
    /// check, not a mill's), each piece's box grown by the largest edge clearance
    func edgeTrees(_ c: Copper) -> (edges: RTree<EdgeEntry, Double>, margin: RTree<EdgeEntry, Double>) {
        let largest = settings.edgeClearance
        let edgeLayers: Set<String> = ["Edge.Cuts", "Margin"]
        let drawingHeads: Set<String> = ["line", "rect", "arc", "circle", "poly", "curve"]
        func isEdgeDrawing(_ node: SExpr, _ prefix: String) -> Bool {
            guard let head = node.head, head.hasPrefix(prefix), drawingHeads.contains(String(head.dropFirst(3))) else { return false }
            return node.value("layer").map(edgeLayers.contains) ?? false
        }
        let edgeTree = RTree<EdgeEntry, Double>(), marginTree = RTree<EdgeEntry, Double>()
        func insert(_ e: EdgeItem, _ tree: RTree<EdgeEntry, Double>) {
            for s in e.indexed { tree.insert(s.bbox.inflated(largest), EdgeEntry(edge: e, shape: s)) }
        }
        var edges: [(EdgeItem, margin: Bool)] = []
        for node in board.root.items where isEdgeDrawing(node, "gr_") {
            edges += edgePieces(node, placement: nil).map { ($0, node.value("layer") == "Margin") }
        }
        for fp in board.root.all("footprint") {
            let placement = BoardWorld.FootprintPlacement(fp)
            for node in fp.items where isEdgeDrawing(node, "fp_") {
                edges += edgePieces(node, placement: placement).map { ($0, node.value("layer") == "Margin") }
            }
        }
        for (e, margin) in edges { insert(e, margin ? marginTree : edgeTree) }
        for pad in c.footprintPads.joined() {
            guard let p = pad.pad, p.pad.attribute == .npth, let hole = pad.hole, p.pad.drill.x != p.pad.drill.y else { continue }
            insert(EdgeItem(uuid: pad.uuid, shapes: [hole], indexed: [hole, hole]), edgeTree)
        }
        return (edgeTree, marginTree)
    }

    /// A zone's fill (a SHAPE_POLY_SET, cut into triangles as a zone's fill is, in cells) against an edge (a
    /// drawing's SHAPE_COMPOUND), as SHAPE_POLY_SET::Collide collides a compound: the edge's pieces against each
    /// triangle in turn, the nearest the first found nearest, and where
    static func fillCollideAt(_ fill: PolySet, _ edge: [Shape], _ clearance: Int) -> (actual: Int, location: IPoint)? {
        var best: (actual: Int, location: IPoint)?
        for tpoly in fill.triangulatedPolygons {
            for i in tpoly.triangles.indices {
                let (a, b, c) = tpoly.triangle(i)
                guard let hit = collideAt(edge, [.simple(LineChain([a, b, c], closed: true))], clearance) else { continue }
                if best == nil || hit.actual < best!.actual { best = hit }
            }
        }
        return best.map { (max(0, $0.actual), $0.location) }
    }

    /// DRC_TEST_PROVIDER_EDGE_CLEARANCE: copper too near the board's edges (silkscreen's not checked)
    func checkEdgeClearances(_ out: inout Report, _ c: Copper) {
        guard !out.exceeded("copper_edge_clearance") else { return }
        let largest = settings.edgeClearance
        let epsilon = settings.epsilon
        let (edgeTree, marginTree) = edgeTrees(c)
        let castellated = c.footprintPads.flatMap { $0.filter(\.castellated) }
        let fps = board.root.all("footprint")

        let severity = settings.severity("copper_edge_clearance")
        var emitted = Set<String>()
        /// testAgainstEdge: false where a violation is found (or one already reported there)
        func testAgainstEdge(_ item: CopperItem, _ itemShapes: [Shape], _ fill: PolySet?, _ edge: EdgeItem) -> Bool {
            let minClearance = settings.edgeClearance
            let clearance = max(0, minClearance - epsilon)
            guard severity != "ignore", minClearance >= 0,
                  let (actual, pos) = fill.map({ Self.fillCollideAt($0, edge.shapes, clearance) })
                      ?? Self.collideAt(itemShapes, edge.shapes, clearance) else { return true }
            if item.kind == .track || item.kind == .arc {
                // (a track may run into the edge in a castellated pad's hole)
                for pad in castellated {
                    if let h = pad.hole, Self.collide([h], [.circle(center: pos, radius: 0)], 0) != nil { return true }
                }
            }
            // (the same item, edge and place reported once)
            guard emitted.insert("\(item.uuid) \(edge.uuid) \(pos.x) \(pos.y)").inserted else { return false }
            let detail = minClearance > 0
                ? Self.formatMsg({ "(\($0) clearance \($1); actual \($2))" }, "board setup constraints edge", minClearance, actual) : nil
            out.add("copper_edge_clearance", detail, [edge.uuid, item.uuid])
            // (one edge is enough)
            return false
        }

        /// QueryColliding of a tree with an item's shape, the edges colliding with it at the largest edge clearance
        /// visited in the tree's order until one is reported
        func query(_ tree: RTree<EdgeEntry, Double>, _ item: CopperItem, _ shapes: [Shape], _ fill: PolySet?) {
            guard var box = shapes.first?.bbox else { return }
            for s in shapes.dropFirst() { box.merge(s.bbox) }
            var colliding = Set<ObjectIdentifier>()
            _ = tree.search(box.inflated(largest)) { entry in
                let id = ObjectIdentifier(entry.edge)
                if colliding.contains(id) { return true }
                guard Self.collide(shapes, [entry.shape], largest) != nil else { return true }
                colliding.insert(id)
                return testAgainstEdge(item, shapes, fill, entry.edge)
            }
        }

        // the items, in forEachGeometryItem's order: tracks, the board's drawings and zones, then each footprint's
        // pads, drawings and zones
        var items = c.tracks + c.drawings + c.zones.filter { $0.footprint == nil }
        for i in fps.indices { items += c.footprintPads[i] + c.footprintDrawings[i] + c.zones.filter { $0.footprint == i } }
        for item in items {
            guard !out.exceeded("copper_edge_clearance") else { return }
            guard item.copper && !item.layers.isEmpty else { continue }
            // each shape it is tested by: a pad's and a via's on F.Cu (its padstack's one layer), a zone's fill on
            // each of its layers, else its own
            var tested: [[Shape]] = []
            switch item.kind {
            case .pad:
                guard let p = item.pad?.pad, p.attribute != .conn, !item.castellated else { continue }
                // (a plated pad not flashed there: its hole; otherwise its pad, whether on F.Cu or not)
                tested = [item.shapes[0] ?? item.outline]
            case .via:
                guard let v = item.via else { continue }
                let flashed = item.layers.contains(0) && item.flashed.contains(0)
                tested = [[.circle(center: v.start, radius: (flashed ? v.diameter : v.drill) / 2)]]
            case .zone:
                tested = item.layers.compactMap { l in item.fills[l].map { $0.map { Shape.simple($0) } } }
            case .track, .arc, .shape:
                tested = [item.shapes[item.layers[0]] ?? []]
            }
            for shapes in tested where !shapes.isEmpty {
                // (a zone's fill on the layer cut into triangles, as KiCad's DRC cuts it)
                var fill: PolySet?
                if item.kind == .zone {
                    var f = PolySet(shapes.compactMap { if case .simple(let c) = $0 { return [c] } else { return nil } })
                    f.cacheTriangulation(partition: true)
                    fill = f
                }
                query(edgeTree, item, shapes, fill)
                query(marginTree, item, shapes, fill)
            }
        }
    }
}
