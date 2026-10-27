// Ported from KiCad 10.0.7: pcbnew/convert_shape_list_to_polygon.cpp (ConvertOutlineToPolygon and
// doConvertOutlineToPolygon with what they call: processClosedShape, processShapeSegment, findNeighbours and the
// chaining of open shapes end to end, buildContourHierarchy, findCrossingContours, addOutlinesToPolygon,
// addHolesToPolygon, checkSelfIntersections; its arcs never kept in the polygons, as all but KiCad's STEP export ask),
// the radius search it asks of its KD-tree of the shapes' ends (thirdparty/nanoflann: every end nearer than the
// chaining distance, its squared distance worked out in doubles, which the search's own order then does not matter
// to, KiCad sorting what it finds; and the nearest ends to an open chain's end, for which its tree and its search's
// order do matter, ported too: KDTreeSingleIndexAdaptor's build and knnSearch) and libs/kimath/src/bezier_curves.cpp
// (BEZIER_POLY::GetPoly of a cubic curve).
// Copyright (C) 2017 Jean-Pierre Charras; Copyright (C) 2015 SoftPLC Corporation, Dick Hollenbeck; Copyright The KiCad
// Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md); the KD-tree (KDTree), from nanoflann:
// Copyright 2008-2009 Marius Muja, David G. Lowe; Copyright 2011-2025 Jose Luis Blanco; BSD license (see
// KICAD-NOTICE.md).

import Foundation

/// A drawing as KiCad's ConvertOutlineToPolygon takes one (a PCB_SHAPE, what of it the conversion asks)
public struct OutlineShape: Sendable {
    public enum Kind: Sendable { case segment, arc, circle, rect, poly, bezier }
    public var kind: Kind
    /// GetStart and GetEnd: a segment's, arc's or curve's ends (an arc's as KiCad turns them, counter-clockwise), a
    /// rectangle's corners, a circle's centre and a point on it; a polygon's are what they were before it was one
    /// (a rectangle's corners as drawn in its footprint, before the footprint was turned off square), else (0, 0)
    public var start = IPoint.zero
    public var end = IPoint.zero
    /// An arc's centre and its middle (GetArcMid: the point it was read with, unless its ends were swapped)
    public var center = IPoint.zero
    public var mid = IPoint.zero
    /// A circle's radius (GetRadius)
    public var radius = 0
    /// A rectangle's corner radius, and the maximum error its rounded corners are made with (GetMaxError: the
    /// board's)
    public var cornerRadius = 0
    public var maxError = 5000
    /// A polygon's points (each of its outlines', not their holes')
    public var points: [IPoint] = []
    /// A curve's control points
    public var control1 = IPoint.zero
    public var control2 = IPoint.zero
    /// Its line's width (GetWidth)
    public var width = 0

    public init(kind: Kind) { self.kind = kind }
}

/// KiCad's ConvertOutlineToPolygon: closed outlines, and the holes in them, made of a list of drawings
public enum Outlines {
    /// What KiCad's OUTLINE_ERROR_HANDLER is told: what is wrong, the drawings it is about (their indices in the
    /// list) and where
    public typealias ErrorHandler = (_ message: String, _ a: Int?, _ b: Int?, _ at: IPoint) -> Void

    /// Polygons with holes made of `shapes` (ConvertOutlineToPolygon, with aAllowUseArcsInPolygons false): closed
    /// shapes each a contour of its own, open ones chained end to end where their ends are within `chainingEpsilon`
    /// of each other, curves made points `maxError` from them at most; contours inside an even number of others
    /// outlines and the others holes. False if a contour does not close, or the polygons cross themselves; what it
    /// made of them is in `polygons` then too, as far as it got.
    public static func convertOutlineToPolygon(_ shapes: [OutlineShape], _ polygons: inout PolySet, maxError: Int,
                                               chainingEpsilon: Int, allowDisjoint: Bool,
                                               errorHandler: ErrorHandler? = nil) -> Bool {
        var width = 0
        return convertOutlineToPolygon(shapes, &polygons, maxError: maxError, chainingEpsilon: chainingEpsilon,
                                       allowDisjoint: allowDisjoint, errorHandler: errorHandler, firstOutlineWidth: &width)
    }

    /// The same, and the width the first outline it adds keeps (each contour has its first shape's width, a
    /// polygon made by Clipper2 none), which KiCad's courtyards keep when they are malformed
    static func convertOutlineToPolygon(_ shapes: [OutlineShape], _ polygons: inout PolySet, maxError: Int,
                                        chainingEpsilon: Int, allowDisjoint: Bool, errorHandler: ErrorHandler?,
                                        firstOutlineWidth: inout Int) -> Bool {
        if shapes.isEmpty { return true }
        var remaining = Set(shapes.indices)
        var nextSeed = 0
        let tree = EndpointTree(shapes)
        var reportedGaps = Set<[Int]>()
        // (SKIP_STRUCT: the shapes already in a contour)
        var skip = [Bool](repeating: false, count: shapes.count)
        var owners: [SegKey: Int] = [:]
        func fetchOwner(_ s: Seg) -> Int? { owners[SegKey(s.a, s.b)] }
        var contours: [LineChain] = []
        // (SetWidth: each contour its first shape's width)
        var widths: [Int] = []

        while !remaining.isEmpty {
            while nextSeed < shapes.count && !remaining.contains(nextSeed) { nextSeed += 1 }
            if nextSeed >= shapes.count { break }
            let graphic = nextSeed
            skip[graphic] = true
            remaining.remove(graphic)
            var contour = LineChain()
            let g = shapes[graphic]
            widths.append(g.width)
            if g.kind == .poly || g.kind == .circle || g.kind == .rect {
                processClosedShape(g, graphic, &contour, &owners, maxError)
                contours.append(contour)
                continue
            }
            // open shapes chained
            var chain = [graphic]
            var closed = false
            var frontPt = g.start, backPt = g.end
            func extendChain(_ forward: Bool) {
                var curr = forward ? chain[chain.count - 1] : chain[0]
                var prev = forward ? backPt : frontPt
                while true {
                    let next = findNeighbours(curr, prev, tree, Double(chainingEpsilon)) { skip[$0] }
                    if let a = next.available {
                        skip[a] = true
                        remaining.remove(a)
                        if forward { chain.append(a) } else { chain.insert(a, at: 0) }
                        prev = closerToFirst(prev, shapes[a].start, shapes[a].end) ? shapes[a].end : shapes[a].start
                        curr = a
                        continue
                    }
                    let chainPt = forward ? frontPt : backPt
                    if chain.count > 1 && closeEnough(prev, chainPt, chainingEpsilon) {
                        closed = true
                    } else if let c = next.consumed {
                        // (reported, and nothing more made of it)
                        errorHandler?("(self-intersecting)", curr, c, prev)
                    }
                    if forward { backPt = prev } else { frontPt = prev }
                    break
                }
            }
            extendChain(true)
            if !closed { extendChain(false) }

            let first = chain[0]
            let startPt = chain.count > 1 ? freeEnd(shapes[first], shapes[chain[1]]) : shapes[first].start
            contour.append(startPt)
            var prevPt = startPt
            for s in chain { processShapeSegment(shapes[s], s, &contour, &prevPt, &owners, maxError, chainingEpsilon) }

            // the contour closed if it comes back to where it started
            if closeEnough(contour.point(0), contour.lastPoint, chainingEpsilon) {
                if contour.point(0) != contour.lastPoint && contour.pointCount > 2 {
                    let owner = fetchOwner(contour.segment(-1))
                    // (its arcs made points: its last point is no arc's end)
                    contour.setPoint(-1, contour.point(0))
                    if let owner { owners[SegKey(contour.points[contour.pointCount - 2], contour.lastPoint)] = owner }
                }
                contour.setClosed(true)
            } else if let errorHandler {
                // (each end's shape and the nearest other shape, among the eight ends nearest it, a lone shape with
                // itself: each pair once; where the gap is, the ends themselves here, not the nearest points)
                func reportGap(_ pt: IPoint) {
                    let found = tree.knnSearch(pt, 8)
                    guard let a = found.first.map({ tree.ends[$0].shape }) else { return }
                    let b = found.dropFirst().map { tree.ends[$0].shape }.first { $0 != a } ?? a
                    guard reportedGaps.insert([min(a, b), max(a, b)]).inserted else { return }
                    errorHandler("(not a closed shape)", a, b, pt)
                }
                reportGap(contour.point(0))
                reportGap(contour.lastPoint)
            }
            contours.append(contour)
        }

        // every contour closed
        if contours.contains(where: { !$0.isClosed }) { return false }

        let hierarchy = buildContourHierarchy(contours)
        let crossing = findCrossingContours(contours)
        var contourToOutline: [Int: Int] = [:]
        let hadOutlines = polygons.outlineCount > 0
        if !addOutlinesToPolygon(contours, hierarchy, crossing, &polygons, allowDisjoint, errorHandler, fetchOwner,
                                 &contourToOutline) {
            return false
        }
        if !hadOutlines, let first = contourToOutline.first(where: { $0.value == 0 }) { firstOutlineWidth = widths[first.key] }
        if addHolesToPolygon(contours, hierarchy, contourToOutline, &polygons, crossing) { firstOutlineWidth = 0 }
        return checkSelfIntersections(polygons, errorHandler, fetchOwner)
    }

    // MARK: - Chaining

    /// A segment's ends, the key KiCad's shape owners are kept by
    struct SegKey: Hashable {
        let a: IPoint, b: IPoint
        init(_ a: IPoint, _ b: IPoint) { (self.a, self.b) = (a, b) }
    }

    /// close_enough: whether two points are no further apart than `limit`
    static func closeEnough(_ a: IPoint, _ b: IPoint, _ limit: Int) -> Bool { (a - b).squaredNorm <= limit * limit }

    /// closer_to_first: whether `first` is nearer `ref` than `second` is
    static func closerToFirst(_ ref: IPoint, _ first: IPoint, _ second: IPoint) -> Bool {
        (ref - first).squaredNorm < (ref - second).squaredNorm
    }

    /// free_end: the end of `first` that does not join `second`
    static func freeEnd(_ first: OutlineShape, _ second: OutlineShape) -> IPoint {
        func gap(_ p: IPoint) -> Int { min((p - second.start).squaredNorm, (p - second.end).squaredNorm) }
        return gap(first.start) <= gap(first.end) ? first.end : first.start
    }

    /// The shapes' ends, each shape's start then its end, in the list's order (PCB_SHAPE_ENDPOINTS_ADAPTOR), and the
    /// radius search KiCad's nanoflann KD-tree of them answers: every end whose squared distance, in doubles, is less
    /// than the radius's (nanoflann's search finds the same ends whatever its tree, its bounds exact for the ends
    /// that near; it is sorted after)
    struct EndpointTree {
        let ends: [(p: IPoint, shape: Int)]
        /// The ends' indices by their x
        let byX: [Int]

        init(_ shapes: [OutlineShape]) {
            var ends: [(p: IPoint, shape: Int)] = []
            ends.reserveCapacity(shapes.count * 2)
            for (i, s) in shapes.enumerated() {
                ends.append((s.start, i))
                ends.append((s.end, i))
            }
            self.ends = ends
            byX = ends.indices.sorted { ends[$0].p.x != ends[$1].p.x ? ends[$0].p.x < ends[$1].p.x : $0 < $1 }
            kdTree = KDTree(ends.map { [Double($0.p.x), Double($0.p.y)] })
        }

        let kdTree: KDTree

        /// The `k` ends nearest `q`, nearest first, those as near in the order the KD-tree's search meets them
        /// (knnSearch)
        func knnSearch(_ q: IPoint, _ k: Int) -> [Int] { kdTree.knnSearch([Double(q.x), Double(q.y)], k) }

        /// The ends within `radius` of `q` (strictly), with their squared distances (radiusSearch)
        func radiusSearch(_ q: IPoint, _ radius: Double) -> [(index: Int, dist: Double)] {
            let qx = Double(q.x), qy = Double(q.y)
            // (an end further than the radius along x is further away: the window is a little wider)
            let reach = Int(radius.squareRoot()) + 1
            var lo = 0, hi = byX.count
            while lo < hi {
                let m = (lo + hi) / 2
                if ends[byX[m]].p.x < q.x - reach { lo = m + 1 } else { hi = m }
            }
            var out: [(index: Int, dist: Double)] = []
            var i = lo
            while i < byX.count && ends[byX[i]].p.x <= q.x + reach {
                let e = ends[byX[i]].p
                let d0 = qx - Double(e.x), d1 = qy - Double(e.y)
                var dist = 0.0
                dist += d0 * d0
                dist += d1 * d1
                if dist < radius { out.append((byX[i], dist)) }
                i += 1
            }
            return out
        }
    }

    /// CHAIN_NEIGHBOURS
    struct Neighbours {
        /// The nearest shape not chained yet
        var available: Int?
        /// The nearest one already chained
        var consumed: Int?
    }

    /// findNeighbours: the shapes other than `shape` with an end within the chaining distance of `point`, nearest
    /// first (by their ends' order where they are as near)
    static func findNeighbours(_ shape: Int, _ point: IPoint, _ tree: EndpointTree, _ chainingEpsilon: Double,
                               _ isConsumed: (Int) -> Bool) -> Neighbours {
        var matches = tree.radiusSearch(point, chainingEpsilon * chainingEpsilon)
        // (closerEndpoint: by distance, then by index, a total order)
        matches.sort { $0.dist != $1.dist ? $0.dist < $1.dist : $0.index < $1.index }
        var result = Neighbours()
        for m in matches {
            let candidate = tree.ends[m.index].shape
            if candidate == shape { continue }
            if isConsumed(candidate) {
                if result.consumed == nil { result.consumed = candidate }
            } else if result.available == nil {
                result.available = candidate
            }
            if result.available != nil && result.consumed != nil { break }
        }
        return result
    }

    // MARK: - Contours

    /// processClosedShape: a polygon's, circle's or rectangle's outline (a circle's and a rounded rectangle's arcs as
    /// points)
    static func processClosedShape(_ s: OutlineShape, _ index: Int, _ contour: inout LineChain, _ owners: inout [SegKey: Int],
                                   _ maxError: Int) {
        func own() {
            for i in stride(from: 1, to: contour.pointCount, by: 1) { owners[SegKey(contour.points[i - 1], contour.points[i])] = index }
        }
        switch s.kind {
        case .poly:
            for p in s.points { contour.append(p) }
            own()
            contour.setClosed(true)
        case .circle:
            let center = s.start
            let start = center + IPoint(s.radius, 0)
            contour.append(ShapeArc(center: center, start: start, angle: .a360), maxError: maxError)
            contour.setClosed(true)
            own()
            contour.clearArcs()
        case .rect where s.cornerRadius > 0:
            // (ROUNDRECT, normalized, made a polygon with the drawing's maximum error)
            let rr = BoardWorld.roundRect(start: s.start, width: s.end.x - s.start.x, height: s.end.y - s.start.y,
                                          radius: s.cornerRadius, maxError: s.maxError / 5)
            contour.append(LineChain(rr.points))
            own()
            contour.setClosed(true)
        case .rect:
            // (GetRectCorners)
            for p in [s.start, IPoint(s.end.x, s.start.y), s.end, IPoint(s.start.x, s.end.y)] { contour.append(p) }
            own()
            contour.setClosed(true)
        default:
            break
        }
    }

    /// processShapeSegment: an open shape's points added to a chain's contour, from its end nearer the point before
    static func processShapeSegment(_ s: OutlineShape, _ index: Int, _ contour: inout LineChain, _ prevPt: inout IPoint,
                                    _ owners: inout [SegKey: Int], _ maxError: Int, _ chainingEpsilon: Int) {
        switch s.kind {
        case .segment:
            let nextPt = closerToFirst(prevPt, s.start, s.end) ? s.end : s.start
            contour.append(nextPt)
            owners[SegKey(prevPt, nextPt)] = index
            prevPt = nextPt
        case .arc:
            var pstart = s.start, pend = s.end
            let pmid = s.mid
            if !closeEnough(prevPt, pstart, chainingEpsilon) && !closeEnough(prevPt, pend, chainingEpsilon) { return }
            if closerToFirst(prevPt, pend, pstart) { swap(&pstart, &pend) }
            // (the arc drawn from where the chain is, through its middle)
            pstart = prevPt
            var arcChain = LineChain()
            arcChain.append(ShapeArc(start: pstart, mid: pmid, end: pend), maxError: maxError)
            arcChain.clearArcs()
            for i in stride(from: 1, to: arcChain.pointCount, by: 1) { owners[SegKey(arcChain.points[i - 1], arcChain.points[i])] = index }
            contour.append(arcChain)
            prevPt = pend
        case .bezier:
            var nextPt: IPoint
            var reverse = false
            if closerToFirst(prevPt, s.start, s.end) {
                nextPt = s.end
            } else {
                nextPt = s.start
                reverse = true
            }
            let pts = bezierPoints(s.start, s.control1, s.control2, s.end, maxError: maxError)
            for pt in reverse ? pts.reversed() : pts {
                if prevPt == pt { continue }
                contour.append(pt)
                owners[SegKey(prevPt, pt)] = index
                prevPt = pt
            }
            prevPt = nextPt
        default:
            break
        }
    }

    /// buildContourHierarchy: for each contour with points, the others its first point is inside
    static func buildContourHierarchy(_ contours: [LineChain]) -> [(contour: Int, parents: [Int])] {
        var out: [(contour: Int, parents: [Int])] = []
        for i in contours.indices {
            guard contours[i].pointCount >= 1 else { continue }
            let firstPt = contours[i].point(0)
            var parents: [Int] = []
            for j in contours.indices where j != i {
                // (the bounding box KiCad tries first, of all the points the contour ever had, decides nothing the
                // test does not)
                if contours[j].pointInside(firstPt, accuracy: 0) { parents.append(j) }
            }
            out.append((i, parents))
        }
        return out
    }

    /// findCrossingContours: the contours that cross another (or touch it, but not along it)
    static func findCrossingContours(_ contours: [LineChain]) -> Set<Int> {
        var crossing = Set<Int>()
        for i in contours.indices {
            for j in contours.indices where j > i {
                if !contours[i].intersect(contours[j], excludeColinearAndTouching: true).isEmpty {
                    crossing.insert(i)
                    crossing.insert(j)
                }
            }
        }
        return crossing
    }

    /// addOutlinesToPolygon: the contours inside an even number of others the outlines (but one nested in another
    /// and crossing one, a cut-out's wall)
    static func addOutlinesToPolygon(_ contours: [LineChain], _ hierarchy: [(contour: Int, parents: [Int])],
                                     _ crossing: Set<Int>, _ polygons: inout PolySet, _ allowDisjoint: Bool,
                                     _ errorHandler: ErrorHandler?, _ fetchOwner: (Seg) -> Int?,
                                     _ contourToOutline: inout [Int: Int]) -> Bool {
        for (index, parents) in hierarchy where parents.count % 2 == 0 {
            if !parents.isEmpty && crossing.contains(index) { continue }
            if !allowDisjoint && polygons.outlineCount > 0, let errorHandler {
                if let a = fetchOwner(polygons.polygons[0][0].segment(0)), let b = fetchOwner(contours[index].segment(0)) {
                    errorHandler("(multiple board outlines not supported)", a, b, contours[index].point(0))
                    return false
                }
            }
            polygons.addOutline(contours[index])
            contourToOutline[index] = polygons.outlineCount - 1
        }
        return true
    }

    /// addHolesToPolygon: the contours inside an odd number of others holes in the one directly round them; where
    /// contours cross, the holes (and contours crossing others) cut out of the outlines and the islands in holes
    /// added to them instead (true then, if Clipper2 made the polygons again)
    @discardableResult
    static func addHolesToPolygon(_ contours: [LineChain], _ hierarchy: [(contour: Int, parents: [Int])],
                                  _ contourToOutline: [Int: Int], _ polygons: inout PolySet, _ crossing: Set<Int>) -> Bool {
        if crossing.isEmpty {
            var depth: [Int: Int] = [:]
            for (index, parents) in hierarchy { depth[index] = parents.count }
            for (index, parents) in hierarchy where parents.count % 2 == 1 {
                for parent in parents where depth[parent] == parents.count - 1 {
                    polygons.addHole(contours[index], outline: contourToOutline[parent]!)
                    break
                }
            }
            return false
        }
        var cutouts = PolySet(), islands = PolySet()
        for (index, parents) in hierarchy where !parents.isEmpty {
            if parents.count % 2 == 1 || crossing.contains(index) {
                cutouts.addOutline(contours[index])
            } else {
                islands.addOutline(contours[index])
            }
        }
        if cutouts.outlineCount > 0 {
            cutouts.simplify()
            polygons.booleanSubtract(cutouts)
        }
        if islands.outlineCount > 0 {
            islands.simplify()
            polygons.booleanAdd(islands)
        }
        return cutouts.outlineCount > 0 || islands.outlineCount > 0
    }

    /// checkSelfIntersections: false if two of the polygons' segments are the same or cross, as KiCad finds them:
    /// each segment's ends in order, the segments sorted, each tried against those after it until one starts
    /// further from the origin than it ends (VECTOR2's operator> compares lengths, which the sort does not go by:
    /// KiCad stops where it stops)
    static func checkSelfIntersections(_ polygons: PolySet, _ errorHandler: ErrorHandler?, _ fetchOwner: (Seg) -> Int?) -> Bool {
        var selfIntersecting = false
        var segments: [Seg] = []
        func lexLess(_ a: IPoint, _ b: IPoint) -> Bool { a.x != b.x ? a.x < b.x : a.y < b.y }
        for poly in polygons.polygons {
            for chain in poly {
                for i in 0..<chain.segmentCount {
                    var s = chain.segment(i)
                    if lexLess(s.b, s.a) { s = Seg(s.b, s.a) }
                    segments.append(s)
                }
            }
        }
        Clipper.introSort(&segments) { a, b in a.a != b.a ? lexLess(a.a, b.a) : lexLess(a.b, b.b) }
        for i in segments.indices {
            let seg1 = segments[i]
            for j in stride(from: i + 1, to: segments.count, by: 1) {
                let seg2 = segments[j]
                if seg2.a.squaredNorm > seg1.b.squaredNorm { break }
                if (seg1.a == seg2.a && seg1.b == seg2.b) || (seg1.a == seg2.b && seg1.b == seg2.a) {
                    errorHandler?("(self-intersecting)", fetchOwner(seg1), fetchOwner(seg2), seg1.a)
                    selfIntersecting = true
                } else if let p = seg1.intersect(seg2, ignoreEndpoints: true) {
                    errorHandler?("(self-intersecting)", fetchOwner(seg1), fetchOwner(seg2), p)
                    selfIntersecting = true
                }
            }
        }
        return !selfIntersecting
    }

    // MARK: - Curves (BEZIER_POLY)

    /// A cubic Bézier curve's points, no further than `maxError` from it (EDA_SHAPE::RebuildBezierToSegmentsPointsList:
    /// BEZIER_POLY::GetPoly, by Hain et al.'s parabolic approximation, its points rounded)
    public static func bezierPoints(_ start: IPoint, _ c1: IPoint, _ c2: IPoint, _ end: IPoint, maxError: Int) -> [IPoint] {
        var out: [DPoint] = []
        Bezier([DPoint(start), DPoint(c1), DPoint(c2), DPoint(end)]).getPoly(&out, Double(maxError))
        return out.map { IPoint(KiMath.round($0.x), KiMath.round($0.y)) }
    }

    /// BEZIER_POLY of a cubic curve
    struct Bezier {
        var p: [DPoint]

        init(_ p: [DPoint]) { self.p = p }

        static func cross(_ a: DPoint, _ b: DPoint) -> Double { a.x * b.y - a.y * b.x }
        static func dot(_ a: DPoint, _ b: DPoint) -> Double { a.x * b.x + a.y * b.y }
        /// a + t * (b - a)
        static func lerp(_ a: DPoint, _ b: DPoint, _ t: Double) -> DPoint { DPoint(a.x + t * (b.x - a.x), a.y + t * (b.y - a.y)) }

        var isNaN: Bool { p.contains { $0.x.isNaN || $0.y.isNaN } }

        func isFlat(_ maxError: Double) -> Bool {
            let delta = p[3] - p[0]
            let d21 = p[1] - p[0], d31 = p[2] - p[0]
            let cross1 = Self.cross(delta, d21), cross2 = Self.cross(delta, d31)
            let invDeltaSq = 1.0 / delta.squaredNorm
            let d1 = (cross1 * cross1) * invDeltaSq
            let d2 = (cross2 * cross2) * invDeltaSq
            let factor = cross1 * cross2 > 0.0 ? 3.0 / 4.0 : 4.0 / 9.0
            let f2 = factor * factor
            let tol = maxError * maxError
            return d1 * f2 <= tol && d2 * f2 <= tol
        }

        func numberOfInflectionPoints() -> Int {
            let d21 = p[1] - p[0], d32 = p[2] - p[1], d43 = p[3] - p[2]
            let cross1 = Self.cross(d21, d32) * Self.cross(d32, d43)
            let cross2 = Self.cross(d21, d32) * Self.cross(d21, d43)
            if cross1 < 0.0 { return 1 }
            if cross2 > 0.0 { return 0 }
            let b1 = Self.dot(d21, d32) > 0.0
            let b2 = Self.dot(d32, d43) > 0.0
            if b1 != b2 { return 0 }
            return -1
        }

        func thirdControlPointDeviation() -> Double {
            let delta = p[1] - p[0]
            let lenSq = delta.squaredNorm
            if lenSq < 1e-6 { return 0.0 }
            let len = lenSq.squareRoot()
            let r = (p[1].y - p[0].y) / len
            let s = (p[0].x - p[1].x) / len
            let u = (p[1].x * p[0].y - p[0].x * p[1].y) / len
            return abs(r * p[2].x + s * p[2].y + u)
        }

        func subdivide(_ t: Double) -> (left: Bezier, right: Bezier) {
            let leftCtrl1 = Self.lerp(p[0], p[1], t)
            let tmp = Self.lerp(p[1], p[2], t)
            let leftCtrl2 = Self.lerp(leftCtrl1, tmp, t)
            let rightCtrl2 = Self.lerp(p[2], p[3], t)
            let rightCtrl1 = Self.lerp(tmp, rightCtrl2, t)
            let shared = Self.lerp(leftCtrl2, rightCtrl1, t)
            return (Bezier([p[0], leftCtrl1, leftCtrl2, shared]), Bezier([shared, rightCtrl1, rightCtrl2, p[3]]))
        }

        func recursiveSegmentation(_ out: inout [DPoint], _ threshold: Double) {
            var stack = [self]
            while let b = stack.last {
                if b.p[3] == b.p[0] {
                    stack.removeLast()
                } else if b.isFlat(threshold) {
                    out.append(b.p[3])
                    stack.removeLast()
                } else {
                    let (left, right) = b.subdivide(0.5)
                    stack[stack.count - 1] = right
                    stack.append(left)
                }
            }
        }

        func findInflectionPoints(_ t1Out: inout Double, _ t2Out: inout Double) -> Int {
            let a3 = DPoint(-p[0].x + 3 * p[1].x - 3 * p[2].x + p[3].x, -p[0].y + 3 * p[1].y - 3 * p[2].y + p[3].y)
            let b3 = DPoint(3 * p[0].x - 6 * p[1].x + 3 * p[2].x, 3 * p[0].y - 6 * p[1].y + 3 * p[2].y)
            let c3 = DPoint(-3 * p[0].x + 3 * p[1].x, -3 * p[0].y + 3 * p[1].y)
            let a = 3 * Self.cross(a3, b3)
            let b = 3 * Self.cross(a3, c3)
            let c = Self.cross(b3, c3)
            let r2 = b * b - 4 * a * c
            t1Out = 0
            t2Out = 0
            if r2 >= 0.0 && a != 0.0 {
                let r = r2.squareRoot()
                var t1 = (-b + r) / (2 * a)
                var t2 = (-b - r) / (2 * a)
                if (t1 > 0.0 && t1 < 1.0) && (t2 > 0.0 && t2 < 1.0) {
                    if t1 > t2 { swap(&t1, &t2) }
                    t1Out = t1
                    t2Out = t2
                    return t2 - t1 > 0.00001 ? 2 : 1
                } else if t1 > 0.0 && t1 < 1.0 {
                    t1Out = t1
                    return 1
                } else if t2 > 0.0 && t2 < 1.0 {
                    t1Out = t2
                    return 1
                }
                return 0
            }
            return 0
        }

        func cubicParabolicApprox(_ out: inout [DPoint], _ maxError: Double) {
            var c = self
            while true {
                if c.isNaN { break }
                if c.isFlat(maxError) {
                    out.append(c.p[3])
                    break
                }
                let d = c.thirdControlPointDeviation()
                let t = 2 * (maxError / (3.0 * d)).squareRoot()
                if t > 1.0 {
                    c.recursiveSegmentation(&out, maxError)
                    break
                }
                let (b1, b2) = c.subdivide(t)
                if b1.isFlat(maxError) {
                    out.append(b1.p[3])
                } else {
                    b1.recursiveSegmentation(&out, maxError)
                }
                c = b2
            }
        }

        func getCubicPoly(_ out: inout [DPoint], _ maxError: Double) {
            out.append(p[0])
            if numberOfInflectionPoints() == 0 {
                cubicParabolicApprox(&out, maxError)
                return
            }
            var t1 = 0.0, t2 = 0.0
            var n = findInflectionPoints(&t1, &t2)
            if n == 2 {
                let (sub1, tmp1) = subdivide(t1)
                sub1.cubicParabolicApprox(&out, maxError)
                n = tmp1.findInflectionPoints(&t1, &t2)
                guard n == 1 || n == 2 else {
                    out.append(tmp1.p[3])
                    return
                }
                let (sub2, sub3) = tmp1.subdivide(t1)
                sub2.recursiveSegmentation(&out, maxError)
                sub3.cubicParabolicApprox(&out, maxError)
            } else if n == 1 {
                let (sub1, sub2) = subdivide(t1)
                sub1.cubicParabolicApprox(&out, maxError)
                sub2.cubicParabolicApprox(&out, maxError)
            } else {
                cubicParabolicApprox(&out, maxError)
            }
        }

        func getPoly(_ out: inout [DPoint], _ maxError: Double) {
            getCubicPoly(&out, maxError <= 0.0 ? 10.0 : maxError)
        }
    }
}

/// thirdparty/nanoflann's KDTreeSingleIndexAdaptor for points in the plane, with its L2_Simple_Adaptor's squared
/// distances, as KiCad builds it (leaves of up to 10 points, the points' indices reordered as it splits them) and
/// its KNNResultSet search: the order its search meets points in decides which of those as near comes first
struct KDTree {
    private final class Node {
        var left = 0, right = 0
        var divfeat = 0
        var divlow = 0.0, divhigh = 0.0
        var child1: Node?, child2: Node?
    }

    private let points: [[Double]]
    private var vAcc: [Int]
    private var root: Node?
    private var rootBox: [(low: Double, high: Double)] = []
    private let leafMaxSize = 10

    init(_ points: [[Double]]) {
        self.points = points
        vAcc = Array(points.indices)
        guard !points.isEmpty else { return }
        var box = (0..<2).map { i in (low: points[0][i], high: points[0][i]) }
        for k in 1..<points.count {
            for i in 0..<2 {
                let v = points[vAcc[k]][i]
                if v < box[i].low { box[i].low = v }
                if v > box[i].high { box[i].high = v }
            }
        }
        rootBox = box
        root = divideTree(0, points.count, &box)
    }

    private func value(_ k: Int, _ dim: Int) -> Double { points[vAcc[k]][dim] }

    private mutating func divideTree(_ left: Int, _ right: Int, _ box: inout [(low: Double, high: Double)]) -> Node {
        let node = Node()
        if right - left <= leafMaxSize {
            node.left = left
            node.right = right
            for i in 0..<2 { box[i] = (value(left, i), value(left, i)) }
            for k in (left + 1)..<max(right, left + 1) {
                for i in 0..<2 {
                    let v = value(k, i)
                    if box[i].low > v { box[i].low = v }
                    if box[i].high < v { box[i].high = v }
                }
            }
        } else {
            let (idx, cutfeat, cutval) = middleSplit(left, right - left, box)
            node.divfeat = cutfeat
            var leftBox = box
            leftBox[cutfeat].high = cutval
            node.child1 = divideTree(left, left + idx, &leftBox)
            var rightBox = box
            rightBox[cutfeat].low = cutval
            node.child2 = divideTree(left + idx, right, &rightBox)
            node.divlow = leftBox[cutfeat].high
            node.divhigh = rightBox[cutfeat].low
            for i in 0..<2 { box[i] = (min(leftBox[i].low, rightBox[i].low), max(leftBox[i].high, rightBox[i].high)) }
        }
        return node
    }

    private mutating func middleSplit(_ ind: Int, _ count: Int, _ box: [(low: Double, high: Double)]) -> (Int, Int, Double) {
        let eps = 0.00001
        var maxSpan = box[0].high - box[0].low
        for i in 1..<2 where box[i].high - box[i].low > maxSpan { maxSpan = box[i].high - box[i].low }
        var maxSpread = -1.0
        var cutfeat = 0
        var minElem = 0.0, maxElem = 0.0
        for i in 0..<2 where box[i].high - box[i].low >= (1 - eps) * maxSpan {
            var lo = value(ind, i), hi = lo
            for k in 1..<count {
                let v = value(ind + k, i)
                if v < lo { lo = v }
                if v > hi { hi = v }
            }
            if hi - lo > maxSpread {
                cutfeat = i
                maxSpread = hi - lo
                minElem = lo
                maxElem = hi
            }
        }
        let splitVal = (box[cutfeat].low + box[cutfeat].high) / 2
        let cutval = splitVal < minElem ? minElem : splitVal > maxElem ? maxElem : splitVal
        let (lim1, lim2) = planeSplit(ind, count, cutfeat, cutval)
        let index = lim1 > count / 2 ? lim1 : lim2 < count / 2 ? lim2 : count / 2
        return (index, cutfeat, cutval)
    }

    /// planeSplit: those less than the cut first, then those equal, then those greater
    private mutating func planeSplit(_ ind: Int, _ count: Int, _ cutfeat: Int, _ cutval: Double) -> (Int, Int) {
        var left = 0, right = count - 1
        while true {
            while left <= right && value(ind + left, cutfeat) < cutval { left += 1 }
            while right != 0 && left <= right && value(ind + right, cutfeat) >= cutval { right -= 1 }
            if left > right || right == 0 { break }
            vAcc.swapAt(ind + left, ind + right)
            left += 1
            right -= 1
        }
        let lim1 = left
        right = count - 1
        while true {
            while left <= right && value(ind + left, cutfeat) <= cutval { left += 1 }
            while right != 0 && left <= right && value(ind + right, cutfeat) > cutval { right -= 1 }
            if left > right || right == 0 { break }
            vAcc.swapAt(ind + left, ind + right)
            left += 1
            right -= 1
        }
        return (lim1, left)
    }

    /// knnSearch: the `k` nearest points' indices, nearest first, a point as near as one found already after it
    func knnSearch(_ q: [Double], _ k: Int) -> [Int] {
        guard let root, k > 0 else { return [] }
        var indices = [Int](repeating: 0, count: k), dists = [Double](repeating: 0, count: k)
        var count = 0
        func worstDist() -> Double { count < k || count == 0 ? Double.greatestFiniteMagnitude : dists[count - 1] }
        func addPoint(_ dist: Double, _ index: Int) {
            var i = count
            while i > 0 {
                if dists[i - 1] > dist {
                    if i < k { (dists[i], indices[i]) = (dists[i - 1], indices[i - 1]) }
                } else {
                    break
                }
                i -= 1
            }
            if i < k { (dists[i], indices[i]) = (dist, index) }
            if count < k { count += 1 }
        }
        func searchLevel(_ node: Node, _ mindist: Double, _ ds: inout [Double]) {
            if node.child1 == nil && node.child2 == nil {
                let worst = worstDist()
                for i in node.left..<node.right {
                    let p = points[vAcc[i]]
                    var dist = 0.0
                    for d in 0..<2 {
                        let diff = q[d] - p[d]
                        dist += diff * diff
                    }
                    if dist < worst { addPoint(dist, vAcc[i]) }
                }
                return
            }
            let idx = node.divfeat
            let val = q[idx]
            let diff1 = val - node.divlow, diff2 = val - node.divhigh
            let best: Node, other: Node
            let cutDist: Double
            if diff1 + diff2 < 0 {
                (best, other) = (node.child1!, node.child2!)
                cutDist = (val - node.divhigh) * (val - node.divhigh)
            } else {
                (best, other) = (node.child2!, node.child1!)
                cutDist = (val - node.divlow) * (val - node.divlow)
            }
            searchLevel(best, mindist, &ds)
            let dst = ds[idx]
            let md = mindist + cutDist - dst
            ds[idx] = cutDist
            if md * 1 <= worstDist() { searchLevel(other, md, &ds) }
            ds[idx] = dst
        }
        var ds = [0.0, 0.0]
        var dist = 0.0
        for i in 0..<2 {
            if q[i] < rootBox[i].low {
                ds[i] = (q[i] - rootBox[i].low) * (q[i] - rootBox[i].low)
                dist += ds[i]
            }
            if q[i] > rootBox[i].high {
                ds[i] = (q[i] - rootBox[i].high) * (q[i] - rootBox[i].high)
                dist += ds[i]
            }
        }
        searchLevel(root, dist, &ds)
        return Array(indices.prefix(count))
    }
}
