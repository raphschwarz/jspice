// Ported from KiCad 10.0.7: pcbnew/drc/drc_test_provider_edge_clearance.cpp (copper and silkscreen against the board's
// edges: the R-tree of its Edge.Cuts and Margin drawings, rectangles and outlines cut into their sides, and of unplated
// slots, each item's search of it, and resolveSilkDisposition: silkscreen the board's outline cuts across),
// pcbnew/drc/drc_engine.cpp (EvalRules of the edge and silk clearances between an edge and an item), pcbnew/drc/drc_rtree.h
// (GetObjectsAt), common/eda_shape.cpp (hitTest), libs/kimath/src/geometry/shape_poly_set.cpp (Contains),
// pcbnew/pad.cpp and pcbnew/pcb_track.cpp (a pad's and a via's shape as asked of no particular copper layer).
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
        /// The drawing it is (the PCB_SHAPE KiCad clones, its line no wider on Edge.Cuts); nil for a slot
        let drawing: BoardWorld.Drawing?
        /// A slot's pad
        let pad: CopperItem?
        /// A drawing's layer (Edge.Cuts or Margin) and footprint, and the edge as the rules see it, once asked
        var layer = "Edge.Cuts"
        var footprint: Int?
        var rule: RuleItem?

        init(uuid: String, shapes: [Shape], indexed: [Shape]? = nil, drawing: BoardWorld.Drawing? = nil, pad: CopperItem? = nil) {
            self.uuid = uuid
            self.shapes = shapes
            self.indexed = indexed ?? shapes
            self.drawing = drawing
            self.pad = pad
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
                .map { EdgeItem(uuid: uuid, shapes: [.segment($0, width: d.width)], drawing: Self.segmentDrawing($0, d.width)) }
        case .rect where !d.filled:
            // (MakeEffectiveShapes( true ): its sides and rounded corners, each a copy of the rectangle made a segment
            // or an arc, an arc's geometry set by its ends and middle, and its shape made again from that)
            return (world.effectiveShapes(d) ?? []).map { s in
                guard case .arc(let a) = s else {
                    guard case .segment(let g, _) = s else { return EdgeItem(uuid: uuid, shapes: [s]) }
                    return EdgeItem(uuid: uuid, shapes: [s], drawing: Self.segmentDrawing(g, d.width))
                }
                var arc = BoardWorld.arcDrawing(a.start, a.mid, a.end)
                arc.width = d.width
                return EdgeItem(uuid: uuid, shapes: world.effectiveShapes(arc) ?? [s], drawing: arc)
            }
        case .poly where !d.filled:
            // (its outline's sides, each one of its own)
            return (world.effectiveShapes(d) ?? []).map { s in
                guard case .segment(let g, _) = s else { return EdgeItem(uuid: uuid, shapes: [s]) }
                return EdgeItem(uuid: uuid, shapes: [s], drawing: Self.segmentDrawing(g, d.width))
            }
        default:
            guard let shapes = world.effectiveShapes(d), !shapes.isEmpty else { return [] }
            return [EdgeItem(uuid: uuid, shapes: shapes, drawing: d)]
        }
    }

    static func segmentDrawing(_ s: Seg, _ width: Int) -> BoardWorld.Drawing {
        var d = BoardWorld.Drawing(kind: .segment, start: s.a, end: s.b)
        d.width = width
        return d
    }

    /// EDA_SHAPE::hitTest of a point: within `accuracy` (and half its line) of a drawing's line, or in it if filled
    static func hitTest(_ d: BoardWorld.Drawing, _ p: IPoint, _ accuracy: Int) -> Bool {
        var maxdist = Double(accuracy)
        if d.width > 0 { maxdist += Double(d.width) / 2.0 }
        switch d.kind {
        case .circle:
            let radius = Double(d.radius), dist = p.distance(d.start)
            return d.filled ? dist <= radius + maxdist : abs(radius - dist) <= maxdist
        case .arc:
            if p.distance(d.start) <= maxdist || p.distance(d.end) <= maxdist { return true }
            let radius = Double(max(1, KiMath.round(d.center.distance(d.start))))
            let rel = DPoint(Double(p.x - d.center.x), Double(p.y - d.center.y))
            let dist = rel.norm
            if d.filled ? dist > radius + maxdist : abs(radius - dist) > maxdist { return false }
            var startAngle = EDAAngle(DPoint(d.start - d.center)), endAngle = EDAAngle(DPoint(d.end - d.center))
            if endAngle == startAngle { endAngle = startAngle + .a360 }
            while endAngle < startAngle { endAngle += .a360 }
            startAngle = startAngle.normalized
            endAngle = endAngle.normalized
            let relAngle = EDAAngle(rel).normalized
            return endAngle > startAngle ? relAngle >= startAngle && relAngle <= endAngle
                                         : relAngle >= startAngle || relAngle <= endAngle
        case .segment:
            return KiMath.testSegmentHit(p, d.start, d.end, Int(maxdist))
        case .rect, .poly:
            let pts = d.kind == .rect ? [d.start, IPoint(d.end.x, d.start.y), d.end, IPoint(d.start.x, d.end.y)] : d.poly
            let chain = d.chain ?? LineChain(pts, closed: true)
            if d.filled && (chain.pointInside(p) || chain.edgeContainingPoint(p, accuracy: Int(maxdist) - 1) >= 0) { return true }
            for i in 0..<chain.segmentCount where chain.segment(i).squaredDistance(p) <= Int(maxdist) * Int(maxdist) { return true }
            return false
        case .bezier:
            return false
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
        for (i, fp) in board.root.all("footprint").enumerated() {
            let placement = BoardWorld.FootprintPlacement(fp)
            for node in fp.items where isEdgeDrawing(node, "fp_") {
                edges += edgePieces(node, placement: placement).map { e in
                    e.footprint = i
                    return (e, node.value("layer") == "Margin")
                }
            }
        }
        for (e, margin) in edges where margin { e.layer = "Margin" }
        for (e, margin) in edges { insert(e, margin ? marginTree : edgeTree) }
        for pad in c.footprintPads.joined() {
            guard let p = pad.pad, p.pad.attribute == .npth, let hole = pad.hole, p.pad.drill.x != p.pad.drill.y else { continue }
            insert(EdgeItem(uuid: pad.uuid, shapes: [hole], indexed: [hole, hole], pad: pad), edgeTree)
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

    /// DRC_TEST_PROVIDER_EDGE_CLEARANCE: copper too near the board's edges, and silkscreen on them
    func checkEdgeClearances(_ out: inout Report, _ c: Copper, _ boardItems: [BoardItem], _ outline: SilkOutline?) {
        guard !out.exceeded("copper_edge_clearance") || !silkLimitReached(out, "silk_edge_clearance") else { return }
        let largest = largestEdgeClearance
        let epsilon = settings.epsilon
        let (edgeTree, marginTree) = edgeTrees(c)
        let castellated = c.footprintPads.flatMap { $0.filter(\.castellated) }
        let fps = board.root.all("footprint")

        let severity = settings.severity("copper_edge_clearance")
        var emitted = Set<String>()
        /// testAgainstEdge: false where a violation is found (or one already reported there)
        func testAgainstEdge(_ item: CopperItem, _ itemShapes: [Shape], _ fill: PolySet?, _ edge: EdgeItem) -> Bool {
            let constraint = ruleState.engine.evalRules(.edgeClearance, edgeRule(edge, c), ruleItem(item, c), layer: KiLayer.undefined)
            let minClearance = constraint.value.min
            let clearance = max(0, minClearance - epsilon)
            guard severity != "ignore", constraint.severity != .ignore, minClearance >= 0,
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
                ? Self.formatMsg({ "(\($0) clearance \($1); actual \($2))" }, constraint.ruleName, minClearance, actual) : nil
            out.add("copper_edge_clearance", detail, [edge.uuid, item.uuid], rule: constraint.parentRule)
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
            guard !out.exceeded("copper_edge_clearance") else { break }
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
        checkSilkEdges(&out, c, boardItems, outline, edgeTree, marginTree, &emitted)
    }

    /// m_largestEdgeClearance: the worst edge clearance of the rules (QueryWorstConstraint), 0 if none is above 0
    var largestEdgeClearance: Int { ruleState.engine.worstConstraint(.edgeClearance)?.value.min ?? 0 }

    /// An edge as the rules see it: a drawing on Edge.Cuts or Margin (each piece KiCad cuts one into a copy of it,
    /// its line no wider on Edge.Cuts), or a slot's pad
    func edgeRule(_ edge: EdgeItem, _ c: Copper) -> RuleItem {
        if let r = edge.rule { return r }
        let r: RuleItem
        if let pad = edge.pad {
            r = ruleItem(pad, c)
        } else {
            r = RuleItem(.shape, uuid: edge.uuid)
            r.parentFootprint = edge.footprint.map { ruleState.footprints[$0] }
            r.layer = KiLayer.id(edge.layer) ?? KiLayer.edgeCuts
            r.layerSet = KiLayerSet([r.layer])
            let shapes = edge.shapes
            r.effectiveShape = { _ in shapes }
            r.compoundShape = shapes.count > 1
            if var box = shapes.first?.bbox {
                for s in shapes.dropFirst() { box.merge(s.bbox) }
                r.bbox = box
            }
            r.netClass = ruleNetClass("")
            r.netCode = 0
            // (a piece KiCad cut out of a rectangle or an outline is a segment or an arc: no rectangle's width)
            if let d = edge.drawing { r.properties["Width"] = .int(d.kind == .rect ? d.end.x - d.start.x : 0) }
        }
        edge.rule = r
        return r
    }

    /// The edge check's silkscreen: each item on a silk layer against the edges, and one no edge reaches that the
    /// board's outline cuts across (resolveSilkDisposition)
    func checkSilkEdges(_ out: inout Report, _ c: Copper, _ items: [BoardItem], _ outline: SilkOutline?,
                        _ edgeTree: RTree<EdgeEntry, Double>, _ marginTree: RTree<EdgeEntry, Double>, _ emitted: inout Set<String>) {
        let type = "silk_edge_clearance"
        let largest = largestEdgeClearance, epsilon = settings.epsilon
        let engine = ruleState.engine
        enum Disposition { case unknown, onBoard, offBoard, crossesEdge }
        var disposition: [ObjectIdentifier: Disposition] = [:]

        /// testAgainstEdge of the silk rule: false where a violation is found (or one already reported there)
        func testAgainstEdge(_ item: BoardItem, _ itemShapes: [Shape], _ edge: EdgeItem) -> Bool {
            let constraint = engine.evalRules(.silkClearance, edgeRule(edge, c), ruleItem(item, c), layer: KiLayer.undefined)
            let minClearance = constraint.value.min
            guard constraint.severity != .ignore, minClearance >= 0,
                  let (actual, pos) = Self.collideAt(itemShapes, edge.shapes, max(0, minClearance - epsilon)) else {
                return true
            }
            guard emitted.insert("\(item.uuid) \(edge.uuid) \(pos.x) \(pos.y)").inserted else { return false }
            let detail = minClearance > 0
                ? Self.formatMsg({ "(\($0) clearance \($1); actual \($2))" }, constraint.ruleName, minClearance, actual) : nil
            out.add(type, detail, [edge.uuid, item.uuid], rule: constraint.parentRule)
            disposition[ObjectIdentifier(item)] = .crossesEdge
            return false
        }

        /// QueryColliding of a tree with the item (its box), the edges its shape collides with at the largest edge
        /// clearance visited in the tree's order until one is reported
        func query(_ tree: RTree<EdgeEntry, Double>, _ item: BoardItem, _ shapes: [Shape]) {
            var colliding = Set<ObjectIdentifier>()
            _ = tree.search(item.bbox.inflated(largest)) { entry in
                let id = ObjectIdentifier(entry.edge)
                if colliding.contains(id) { return true }
                guard Self.collide(shapes, [entry.shape], largest) != nil else { return true }
                colliding.insert(id)
                return testAgainstEdge(item, shapes, entry.edge)
            }
        }

        /// resolveSilkDisposition: the item's pieces' centres on the board and off it both (one shape is on or off);
        /// one crossing is reported against the edge drawing at the outline's point nearest its centre
        func resolve(_ item: BoardItem, _ shapes: [Shape], _ outline: SilkOutline) {
            func side(_ p: IPoint) -> Disposition {
                outline.set.polygons.contains { Self.containsSingle($0, p, 0) } ? .onBoard : .offBoard
            }
            var d = Disposition.unknown
            if item.compound {
                for s in shapes {
                    let e = side(s.bbox.center)
                    if d == .unknown {
                        d = e
                    } else if d != e {
                        d = .crossesEdge
                        break
                    }
                }
            } else if var box = shapes.first?.bbox {
                for s in shapes.dropFirst() { box.merge(s.bbox) }
                d = side(box.center)
            }
            disposition[ObjectIdentifier(item)] = d
            guard d == .crossesEdge else { return }
            let itemPos = item.center
            var nearest = outline.set.polygons[0][0].nearestPoint(itemPos, allowInternalShapePoints: false)
            for poly in outline.set.polygons.dropFirst() {
                let other = poly[0].nearestPoint(itemPos, allowInternalShapePoints: false)
                if other.squaredDistance(itemPos) < nearest.squaredDistance(itemPos) { nearest = other }
            }
            // (GetObjectsAt: the edges whose boxes hold the point, an unordered set of them, the first the point hits
            // taken: where it hits two drawings, whichever KiCad's set happens to hold first)
            var seen = Set<ObjectIdentifier>()
            var hits: [EdgeItem] = []
            _ = edgeTree.search(IBox(nearest, nearest).inflated(epsilon)) { entry in
                guard seen.insert(ObjectIdentifier(entry.edge)).inserted else { return true }
                if let d = entry.edge.drawing {
                    if Self.hitTest(d, nearest, epsilon) { hits.append(entry.edge) }
                } else if let p = entry.edge.pad?.pad {
                    // (PAD::HitTest: in its polygon, the error inside, or on its hole)
                    let inPad = world.padPolygon(p.pad, primitives: p.primitives, errorLocation: .inside)?.polygons
                        .contains { Self.containsSingle($0, nearest, epsilon) } ?? false
                    if inPad || Self.collide(entry.edge.shapes, [.circle(center: nearest, radius: 0)], epsilon) != nil {
                        hits.append(entry.edge)
                    }
                }
                return true
            }
            guard let edge = hits.first else { return }
            if Set(hits.map(\.uuid)).count > 1 { for e in hits { out.addUnsure(type, [e.uuid, item.uuid]) } }
            let constraint = engine.evalRules(.silkClearance, edgeRule(edge, c), ruleItem(item, c), layer: KiLayer.undefined)
            let minClearance = constraint.value.min
            guard constraint.severity != .ignore && minClearance >= 0 else { return }
            let detail = minClearance > 0
                ? Self.formatMsg({ "(\($0) clearance \($1); actual \($2))" }, constraint.ruleName, minClearance, 0) : nil
            out.add(type, detail, [edge.uuid, item.uuid], rule: constraint.parentRule)
        }

        guard !silkLimitReached(out, type) else { return }
        for item in items {
            guard !silkLimitReached(out, type) else { break }
            if item.invisibleText || item.ruleArea { continue }
            if item.kind == .pad && (item.castellated || item.connector) { continue }
            guard item.isOnLayer("F.SilkS") || item.isOnLayer("B.SilkS") else { continue }
            // (a zone's fill on each of its layers; anything else's shape on no layer in particular)
            let layersToTest: [String?] = item.kind == .zone
                ? item.layers.sorted { (Self.layerID($0) ?? Int.max) < (Self.layerID($1) ?? Int.max) } : [nil]
            for layer in layersToTest {
                var shapes = item.shapes
                if let layer { shapes = item.shapes(on: layer) } else if item.kind == .pad { shapes = item.copper?.shapes[0] ?? item.shapes }
                query(edgeTree, item, shapes)
                query(marginTree, item, shapes)
                if (disposition[ObjectIdentifier(item)] ?? .unknown) == .unknown, let outline { resolve(item, shapes, outline) }
            }
        }
    }
}
