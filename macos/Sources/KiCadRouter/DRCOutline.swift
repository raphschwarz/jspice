// Ported from KiCad 10.0.7: pcbnew/drc/drc_test_provider_misc.cpp (testOutline, its error handler and
// findClosestOutlineGap: the board's outline, DRCE_INVALID_OUTLINE), pcbnew/convert_shape_list_to_polygon.cpp
// (TestBoardOutlinesGraphicItems, buildChainedClosedContour, BuildBoardPolygonOutlines and isCopperOutside, with the
// conversion in Outlines.swift), pcbnew/board.cpp and pcbnew/footprint.cpp (BOARD::Visit and FOOTPRINT::Visit: the
// order PCB_TYPE_COLLECTOR collects the drawings in, each footprint's and then the board's), common/eda_shape.cpp
// (makeEffectiveShapes of the drawings) and libs/kimath/src/geometry/shape_nearest_points.cpp (SHAPE::NearestPoints of
// the shapes they are made of).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

extension BoardDRC {
    /// The board's own item (BOARD), which KiCad names where an outline's fault is no drawing's: KiCad gives it a new
    /// uuid each time it reads the board, so it is given the nil one here (KIID's niluuid)
    public static let boardUUID = "00000000-0000-0000-0000-000000000000"

    /// A drawing on Edge.Cuts, as the outline check takes it
    struct EdgeCut {
        let uuid: String
        /// As ConvertOutlineToPolygon takes it
        let shape: OutlineShape
        /// GetEffectiveShape: a SHAPE_COMPOUND of these
        let effective: [Shape]
        /// The footprint it is drawn in (its index), nil for the board's own
        let footprint: Int?
    }

    /// The board's drawings on Edge.Cuts, in the order PCB_TYPE_COLLECTOR collects them: each footprint's in turn, then
    /// the board's own
    func edgeCuts() -> [EdgeCut] {
        var out: [EdgeCut] = []
        func add(_ node: SExpr, _ placement: BoardWorld.FootprintPlacement?, _ footprint: Int?) {
            guard node.value("layer") == "Edge.Cuts", let o = world.outlineShape(node, placement: placement) else { return }
            out.append(EdgeCut(uuid: node.value("uuid") ?? "", shape: o, effective: edgeEffectiveShapes(node, placement, o),
                               footprint: footprint))
        }
        for (i, fp) in board.root.all("footprint").enumerated() {
            let placement = BoardWorld.FootprintPlacement(fp)
            for node in fp.items where BoardWorld.footprintShapeHeads.contains(node.head ?? "") { add(node, placement, i) }
        }
        let boardHeads: Set<String> = ["gr_line", "gr_rect", "gr_circle", "gr_arc", "gr_poly", "gr_curve"]
        for node in board.root.items where boardHeads.contains(node.head ?? "") { add(node, nil, nil) }
        return out
    }

    /// A drawing's effective shapes (EDA_SHAPE::makeEffectiveShapes), its width and fill as KiCad reads them (a line
    /// of no width 0.1 mm wide, a rectangle or circle of none with no fill clause filled)
    func edgeEffectiveShapes(_ node: SExpr, _ placement: BoardWorld.FootprintPlacement?, _ o: OutlineShape) -> [Shape] {
        let kind = String((node.head ?? "").dropFirst(3))
        let filled: Bool
        if let fill = node["fill"] {
            let v = fill.text(at: 0) ?? fill["type"]?.text(at: 0)
            filled = v == "yes" || v == "solid" || v == "hatch" || v == "reverse_hatch" || v == "cross_hatch"
        } else {
            let raw = node["stroke"]?["width"].map { BoardWorld.iu($0, 0) } ?? node["width"].map { BoardWorld.iu($0, 0) } ?? 0
            filled = (raw == 0 && (kind == "rect" || kind == "circle")) || (kind == "poly" && node.value("layer") != "Edge.Cuts")
        }
        let w = o.width
        switch o.kind {
        case .bezier:
            // (its points with the board's maximum error, each step a segment)
            let pts = Outlines.bezierPoints(o.start, o.control1, o.control2, o.end, maxError: world.rules.maxError)
            return zip(pts, pts.dropFirst()).map { .segment(Seg($0, $1), width: w) }
        default:
            break
        }
        guard var d = world.readDrawing(node, placement: placement) else {
            // (a rounded rectangle turned off square: a polygon of its outline)
            guard o.kind == .poly, !o.points.isEmpty else { return [] }
            let l = LineChain(o.points, closed: true)
            var out: [Shape] = []
            if filled { out.append(.simple(l)) }
            if w > 0 || !filled { for i in 0..<l.segmentCount { out.append(.segment(l.segment(i), width: w)) } }
            return out
        }
        d.width = w
        d.filled = filled
        return world.effectiveShapes(d) ?? []
    }

    // MARK: - SHAPE::NearestPoints

    /// The nearest points of two drawings' effective shapes (SHAPE_COMPOUNDs): those of the nearest pair of their
    /// pieces, the first found of those as near
    static func nearestPoints(_ a: [Shape], _ b: [Shape]) -> (IPoint, IPoint)? {
        var best: (IPoint, IPoint)?
        var minDistSq = Int.max
        for sa in a {
            for sb in b {
                guard let (pa, pb) = nearestPoints(sa, sb) else { continue }
                let d = (pb - pa).squaredNorm
                if d < minDistSq {
                    minDistSq = d
                    best = (pa, pb)
                }
            }
        }
        return best
    }

    /// nearestPointsSingleShapes, of the shapes drawings are made of: segments, arcs, circles and polygons (SHAPE_SIMPLE,
    /// a SHAPE_LINE_CHAIN_BASE, its arcs not looked at)
    static func nearestPoints(_ a: Shape, _ b: Shape) -> (IPoint, IPoint)? {
        func swapped(_ p: (IPoint, IPoint)?) -> (IPoint, IPoint)? { p.map { ($0.1, $0.0) } }
        func segs(_ l: LineChain) -> [Seg] { (0..<l.segmentCount).map(l.segment) }
        switch (a, b) {
        case let (.circle(c1, r1), .circle(c2, r2)): return circleCircle(c1, r1, c2, r2)
        case let (.circle(c, r), .segment(s, w)): return swapped(segmentCircle(s, w, c, r))
        case let (.circle(c, r), .simple(l)): return circleChain(c, r, segs(l))
        case let (.circle(c, r), .arc(arc)):
            let (pa, pb, _) = arc.nearestPoints(circle: c, r)
            return (pb, pa)
        case let (.segment(s, w), .circle(c, r)): return segmentCircle(s, w, c, r)
        case let (.segment(s1, w1), .segment(s2, w2)):
            var (pa, pb) = segSeg(s1, s2)
            pa = pa + (pb - pa).resized(w1 / 2)
            pb = pb + (pa - pb).resized(w2 / 2)
            return (pa, pb)
        case let (.segment(s, w), .simple(l)): return segmentChain(s, w, segs(l))
        case let (.segment(s, w), .arc(arc)): return swapped(arcSegment(arc, s, w))
        case let (.simple(l), .circle(c, r)): return swapped(circleChain(c, r, segs(l)))
        case let (.simple(l), .segment(s, w)): return swapped(segmentChain(s, w, segs(l)))
        case let (.simple(l1), .simple(l2)): return chainChain(segs(l1), segs(l2))
        case let (.simple(l), .arc(arc)):
            // (each segment against the arc, by the distance the arc gives)
            var best: (IPoint, IPoint)?
            var minDistSq = Int.max
            for s in segs(l) {
                let (onArc, onSeg, d) = arc.nearestPoints(s)
                if d < minDistSq {
                    minDistSq = d
                    best = (onSeg, onArc)
                }
            }
            return best
        case let (.arc(arc), .circle(c, r)):
            let (pa, pb, _) = arc.nearestPoints(circle: c, r)
            return (pa, pb)
        case let (.arc(arc), .segment(s, w)): return arcSegment(arc, s, w)
        case let (.arc(arc), .simple(l)):
            // (always found: the origin twice if the polygon has no segments)
            var best = (IPoint.zero, IPoint.zero)
            var minDistSq = Int.max
            for s in segs(l) {
                let (pa, pb, d) = arc.nearestPoints(s)
                if d < minDistSq {
                    minDistSq = d
                    best = (pa, pb)
                }
            }
            return best
        case let (.arc(a1), .arc(a2)):
            let (pa, pb, _) = a1.nearestPoints(a2)
            return (pa, pb)
        default:
            return nil
        }
    }

    /// NearestPoints of two circles
    static func circleCircle(_ c1: IPoint, _ r1: Int, _ c2: IPoint, _ r2: Int) -> (IPoint, IPoint) {
        let delta = c2 - c1
        if delta.norm == 0 { return (c1 + IPoint(r1, 0), c2 + IPoint(r2, 0)) }
        return (c1 + delta.resized(r1), c2 - delta.resized(r2))
    }

    /// NearestPoints of a circle and a SEG: on the circle, on the segment
    static func circleSeg(_ c: IPoint, _ r: Int, _ s: Seg) -> (IPoint, IPoint) {
        let pb = s.nearestPoint(c)
        // (the centre on the segment: square to it)
        let dir = pb == c ? (s.b - s.a).perpendicular.resized(r) : (pb - c).resized(r)
        return (c + dir, pb)
    }

    /// NearestPoints of a circle and a line chain's segments
    static func circleChain(_ c: IPoint, _ r: Int, _ segs: [Seg]) -> (IPoint, IPoint)? {
        var best: (IPoint, IPoint)?
        var minDistSq = Int.max
        for s in segs {
            let (pa, pb) = circleSeg(c, r, s)
            let d = (pb - pa).squaredNorm
            if d < minDistSq {
                minDistSq = d
                best = (pa, pb)
            }
        }
        return best
    }

    /// NearestPoints of two SEGs
    static func segSeg(_ a: Seg, _ b: Seg) -> (IPoint, IPoint) {
        let pa = a.nearestPoint(b)
        return (pa, b.nearestPoint(pa))
    }

    /// NearestPoints of two line chains' segments, each pair
    static func chainChain(_ a: [Seg], _ b: [Seg]) -> (IPoint, IPoint)? {
        var best: (IPoint, IPoint)?
        var minDistSq = Int.max
        for sa in a {
            for sb in b {
                let (pa, pb) = segSeg(sa, sb)
                let d = (pb - pa).squaredNorm
                if d < minDistSq {
                    minDistSq = d
                    best = (pa, pb)
                }
            }
        }
        return best
    }

    /// NearestPoints of a SHAPE_SEGMENT and a circle, the segment's point moved half its width towards the circle's
    static func segmentCircle(_ s: Seg, _ w: Int, _ c: IPoint, _ r: Int) -> (IPoint, IPoint) {
        let (pc, ps) = circleSeg(c, r, s)
        return (ps + (pc - ps).resized(w / 2), pc)
    }

    /// NearestPoints of a SHAPE_SEGMENT and a line chain
    static func segmentChain(_ s: Seg, _ w: Int, _ segs: [Seg]) -> (IPoint, IPoint)? {
        guard let (pa, pb) = chainChain([s], segs) else { return nil }
        return (pa + (pb - pa).resized(w / 2), pb)
    }

    /// NearestPoints of a SHAPE_ARC and a SHAPE_SEGMENT, the segment's point moved half its width towards the arc's
    static func arcSegment(_ arc: ShapeArc, _ s: Seg, _ w: Int) -> (IPoint, IPoint) {
        let (pa, pb, _) = arc.nearestPoints(s)
        return (pa, pb + (pa - pb).resized(w / 2))
    }

    /// SHAPE_COMPOUND::BBox: its pieces' boxes merged (an empty one's at the origin)
    static func compoundBox(_ shapes: [Shape]) -> IBox {
        guard var box = shapes.first?.bbox else { return IBox(minX: 0, minY: 0, maxX: 0, maxY: 0) }
        for s in shapes.dropFirst() { box.merge(s.bbox) }
        return box
    }

    // MARK: - The outline's drawings (TestBoardOutlinesGraphicItems)

    /// What the outline's error handler is told: what is wrong, and the drawings it is about (their indices in the
    /// Edge.Cuts drawings)
    typealias OutlineError = (message: String, a: Int?, b: Int?)

    /// TestBoardOutlinesGraphicItems: false if a drawing on Edge.Cuts is too small to see (1 µm or less), or two closed
    /// contours (closed drawings, and open ones chained into a loop) cross
    func testBoardOutlinesGraphicItems(_ cuts: [EdgeCut], _ errors: inout [OutlineError]) -> Bool {
        var success = true
        let minDist = 1000
        for (i, c) in cuts.enumerated() {
            let s = c.shape
            switch s.kind {
            case .rect:
                let dim = (s.end - s.start).norm
                if dim <= minDist {
                    success = false
                    errors.append(("(rectangle has null or very small size: \(dim) nm)", i, nil))
                }
            case .circle:
                if s.radius <= minDist {
                    success = false
                    errors.append(("(circle has null or very small radius: \(s.radius) nm)", i, nil))
                }
            case .segment:
                let dim = (s.end - s.start).norm
                if dim <= minDist {
                    success = false
                    errors.append(("(segment has null or very small length: \(dim) nm)", i, nil))
                }
            case .arc:
                // (the size from its ends through its middle, roughly)
                let dim = (s.mid - s.start).norm + (s.end - s.mid).norm
                if dim <= minDist {
                    success = false
                    errors.append(("(arc has null or very small size: \(dim) nm)", i, nil))
                }
            case .poly, .bezier:
                break
            }
        }
        let maxError = world.rules.maxError
        var closed: [(owner: Int, contour: LineChain)] = []
        var open: [Int] = []
        for (i, c) in cuts.enumerated() {
            switch c.shape.kind {
            case .poly, .circle, .rect:
                var contour = LineChain()
                var owners: [Outlines.SegKey: Int] = [:]
                Outlines.processClosedShape(c.shape, i, &contour, &owners, maxError)
                closed.append((i, contour))
            case .segment, .arc, .bezier:
                open.append(i)
            }
        }
        // the open drawings chained into closed contours, each owned by the first of its chain (the open drawings a
        // std::set by their addresses, the order KiCad read them in: the order they are listed in here)
        if !open.isEmpty {
            let shapes = open.map { cuts[$0].shape }
            let tree = Outlines.EndpointTree(shapes)
            var remaining = Set(shapes.indices)
            while let start = remaining.min() {
                if let (contour, owner) = Self.buildChainedClosedContour(start, &remaining, tree, shapes, maxError: maxError,
                                                                        chainingEpsilon: Self.outlinesChainingEpsilon) {
                    closed.append((open[owner], contour))
                } else {
                    remaining.remove(start)
                }
            }
        }
        // (touching only is no crossing)
        for ii in closed.indices {
            for jj in closed.indices where jj > ii {
                if closed[ii].contour.intersect(closed[jj].contour, excludeColinearAndTouching: true).isEmpty { continue }
                success = false
                errors.append(("(self-intersecting)", closed[ii].owner, closed[jj].owner))
            }
        }
        return success
    }

    /// buildChainedClosedContour: the open drawings chained from `start`, those left in `remaining`, as
    /// doConvertOutlineToPolygon chains them; the contour they make if they close (a polygon of three points at
    /// least), and the first drawing of the chain, those in it taken out of `remaining`
    static func buildChainedClosedContour(_ start: Int, _ remaining: inout Set<Int>, _ tree: Outlines.EndpointTree,
                                          _ shapes: [OutlineShape], maxError: Int, chainingEpsilon: Int) -> (LineChain, Int)? {
        var chain = [start]
        var closed = false
        var frontPt = shapes[start].start, backPt = shapes[start].end
        var visited: Set<Int> = [start]
        let left = remaining
        func extendChain(_ forward: Bool) {
            var curr = forward ? chain[chain.count - 1] : chain[0]
            var prev = forward ? backPt : frontPt
            while true {
                // (the tree has every open drawing: those chained already, by an earlier chain or this one, passed over)
                let next = Outlines.findNeighbours(curr, prev, tree, Double(chainingEpsilon)) { !left.contains($0) || visited.contains($0) }
                if let a = next.available {
                    visited.insert(a)
                    if forward { chain.append(a) } else { chain.insert(a, at: 0) }
                    prev = Outlines.closerToFirst(prev, shapes[a].start, shapes[a].end) ? shapes[a].end : shapes[a].start
                    curr = a
                    continue
                }
                let chainPt = forward ? frontPt : backPt
                if chain.count > 1 && Outlines.closeEnough(prev, chainPt, chainingEpsilon) { closed = true }
                if forward { backPt = prev } else { frontPt = prev }
                break
            }
        }
        extendChain(true)
        if !closed { extendChain(false) }
        if !closed { return nil }
        let first = chain[0]
        let startPt = chain.count > 1 ? Outlines.freeEnd(shapes[first], shapes[chain[1]]) : shapes[first].start
        var contour = LineChain()
        contour.append(startPt)
        var prevPt = startPt
        var owners: [Outlines.SegKey: Int] = [:]
        for s in chain { Outlines.processShapeSegment(shapes[s], s, &contour, &prevPt, &owners, maxError, chainingEpsilon) }
        if contour.pointCount < 3 { return nil }
        if contour.point(0) != contour.lastPoint { contour.setPoint(-1, contour.point(0)) }
        contour.setClosed(true)
        for s in chain { remaining.remove(s) }
        return (contour, first)
    }

    // MARK: - The outline (BuildBoardPolygonOutlines)

    /// BOARD::GetOutlinesChainingEpsilon: DEFAULT_CHAINING_EPSILON_MM, 10 µm (only KiCad's STEP export sets another)
    static let outlinesChainingEpsilon = 10_000

    /// isCopperOutside: whether a pad of the footprint is wholly outside its outlines (its polygon, as on all its
    /// layers, and theirs have nothing in common)
    func isCopperOutside(_ footprint: Int, _ outlines: PolySet) -> Bool {
        for p in footprints[footprint].pads {
            guard let poly = world.padPolygon(p.pad, primitives: p.primitives, errorLocation: .inside) else { return true }
            var common = outlines
            common.booleanIntersection(poly)
            if common.outlineCount == 0 { return true }
        }
        return false
    }

    /// BuildBoardPolygonOutlines' success (what it makes of the outline the check has no use for): each footprint's
    /// drawings on Edge.Cuts made polygons first, with no error handler, and left out of the board's outline where they
    /// are holes in it (closed, and round copper of the footprint's or more than one outline); then the rest, the
    /// board's and the other footprints', with the handler, its outlines allowed to be apart
    func buildBoardPolygonOutlines(_ cuts: [EdgeCut], _ errors: inout [OutlineError]) -> Bool {
        let maxError = BoardWorld.iuMM(0.05), chainingEpsilon = Self.outlinesChainingEpsilon
        var success = false
        // (SKIP_STRUCT: a hole's drawings, left set)
        var skip = [Bool](repeating: false, count: cuts.count)
        for f in footprints.indices {
            let list = cuts.indices.filter { cuts[$0].footprint == f }
            if list.isEmpty { continue }
            var fpOutlines = PolySet()
            success = Outlines.convertOutlineToPolygon(list.map { cuts[$0].shape }, &fpOutlines, maxError: maxError,
                                                       chainingEpsilon: chainingEpsilon, allowDisjoint: false)
            if success && (isCopperOutside(f, fpOutlines) || fpOutlines.outlineCount > 1) {
                for i in list { skip[i] = true }
            }
        }
        let segList = cuts.indices.filter { !skip[$0] }
        if !segList.isEmpty {
            var outlines = PolySet()
            var found: [OutlineError] = []
            success = Outlines.convertOutlineToPolygon(segList.map { cuts[$0].shape }, &outlines, maxError: maxError,
                                                       chainingEpsilon: chainingEpsilon, allowDisjoint: true) { message, a, b, _ in
                found.append((message, a.map { segList[$0] }, b.map { segList[$0] }))
            }
            errors += found
        }
        // (where it fails KiCad infers an outline, which says nothing more)
        return success
    }

    // MARK: - The check (DRC_TEST_PROVIDER_MISC::testOutline)

    /// findClosestOutlineGap: the two drawings on Edge.Cuts nearest each other, each pair in the collector's order,
    /// the first found of those as near, and how far apart they are
    func findClosestOutlineGap(_ cuts: [EdgeCut]) -> (a: Int, b: Int, distance: Int)? {
        var best = Int.max
        var out: (a: Int, b: Int, distance: Int)?
        for ii in cuts.indices {
            for jj in cuts.indices where jj > ii {
                guard let (pa, pb) = Self.nearestPoints(cuts[ii].effective, cuts[jj].effective) else { continue }
                let dist = (pa - pb).norm
                if dist < best {
                    best = dist
                    out = (ii, jj, dist)
                }
            }
        }
        return out
    }

    func checkOutline(_ out: inout Report) {
        guard !out.exceeded("invalid_outline") else { return }
        let cuts = edgeCuts()

        /// The error handler: the drawings it is told of, or the two nearest each other where it is not told of two,
        /// and their gap if their boxes do not overlap
        func report(_ e: OutlineError) {
            guard !out.exceeded("invalid_outline") else { return }
            var itemA = e.a, itemB = e.b
            if itemA == nil { swap(&itemA, &itemB) }
            var gap = 0
            var usedGap = false
            var shapeA: Int?, shapeB: Int?
            if let a = itemA, let b = itemB {
                (shapeA, shapeB) = (a, b)
            } else {
                let closest = findClosestOutlineGap(cuts)
                (shapeA, shapeB) = (closest?.a, closest?.b)
                gap = closest?.distance ?? 0
                (itemA, itemB) = (shapeA, shapeB)
                usedGap = closest != nil
            }
            if let a = shapeA, let b = shapeB {
                let overlap = Self.compoundBox(cuts[a].effective).intersection(Self.compoundBox(cuts[b].effective))
                if overlap.maxX - overlap.minX > 0 && overlap.maxY - overlap.minY > 0 {
                    usedGap = false
                } else if let (pa, pb) = Self.nearestPoints(cuts[a].effective, cuts[b].effective) {
                    gap = (pa - pb).norm
                    usedGap = true
                }
            }
            let detail = itemA != nil && itemB != nil && usedGap ? "\(e.message) (gap \(Self.messageText(gap)))" : e.message
            out.add("invalid_outline", detail, [itemA, itemB].compactMap { $0.map { cuts[$0].uuid } })
        }

        var errors: [OutlineError] = []
        // drawings too small to see, closed contours crossing
        if !testBoardOutlinesGraphicItems(cuts, &errors) && errors.isEmpty {
            // (never so: each failure is told the handler)
            out.add("invalid_outline", "(Suspicious items found on Edge.Cuts layer)", [Self.boardUUID])
        }
        let errorHandled = !errors.isEmpty
        for e in errors { report(e) }
        // the outline (its error handler told all the conversion of the board's drawings finds)
        var more: [OutlineError] = []
        if !buildBoardPolygonOutlines(cuts, &more) && !errorHandled && more.isEmpty {
            out.add("invalid_outline", "(no edges found on Edge.Cuts layer)", [Self.boardUUID])
        }
        for e in more { report(e) }
    }
}
