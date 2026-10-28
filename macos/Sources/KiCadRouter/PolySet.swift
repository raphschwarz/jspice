// Ported from KiCad 10.0.7: libs/kimath/include/geometry/shape_poly_set.h and libs/kimath/src/geometry/shape_poly_set.cpp
// (SHAPE_POLY_SET as far as KiCad's router uses one: CacheTriangulation( false ) and what it calls, Fracture with its
// cache-friendly fracture, Simplify with splitCollinearOutlines and the Clipper2 union of booleanOp and importTree,
// splitSelfTouchingOutlines, SimplifyOutlines, PointInside; and as far as a custom pad's outline needs one:
// Append, BooleanAdd, BooleanIntersection, Inflate with inflate2, Rotate, Move), libs/kimath/src/geometry/shape_line_chain.cpp
// (convertToClipper2, and a SHAPE_LINE_CHAIN made from a Clipper2 path) and libs/kimath/include/geometry/
// shape_line_chain.h (CLIPPER_Z_VALUE).
// Copyright (C) 2015-2019 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// The arcs a point lies on, carried through Clipper2 as its z value (KiCad's CLIPPER_Z_VALUE): indices into the
/// arcs of the chains clipped, -1 for none
struct ClipperZValue {
    var firstArcIdx = -1
    var secondArcIdx = -1
}

extension LineChain {
    /// The closed chain as a Clipper2 path, turned round if it does not wind as asked (counter-clockwise with y up for
    /// `requiredOrientation`), each point's z the index of its arcs in `zValues` (KiCad's convertToClipper2; the
    /// port's chains have no arcs, so each point is on none)
    func convertToClipper2(_ requiredOrientation: Bool, _ zValues: inout [ClipperZValue],
                           _ arcBuffer: inout [ShapeArc]) -> Clipper.Path64 {
        let orientation = area(absolute: false) >= 0
        let input = orientation != requiredOrientation ? reversed() : self
        var path = Clipper.Path64()
        path.reserveCapacity(input.pointCount)
        for p in input.points {
            path.append(Clipper.Point64(p.x, p.y, zValues.count))
            zValues.append(ClipperZValue())
        }
        return path
    }

    /// A Clipper2 path as a closed chain (KiCad's SHAPE_LINE_CHAIN from a Path64): a point the same as the one before
    /// it left out, the first and last not merged, and the arcs its z values name (none, from the port's chains)
    init(clipperPath path: Clipper.Path64, _ zValues: [ClipperZValue], _ arcBuffer: [ShapeArc]) {
        self.init()
        setClosed(true)
        for p in path { append(IPoint(p.x, p.y)) }
    }
}

/// Polygons, each an outline and the holes in it (KiCad's SHAPE_POLY_SET, what its router does with one): a keepout
/// zone's outline cut into triangles as KiCad cuts it, simplified by Clipper2 and its holes fractured into it first
public struct PolySet: Sendable {
    /// Each polygon: its outline, then its holes (closed chains)
    public var polygons: [[LineChain]] = []
    /// What the last triangulation made, one for each outline it cut (KiCad keeps them whether it succeeded or not)
    public private(set) var triangulatedPolygons: [TriangulatedPolygon] = []
    private var triangulationValid = false
    /// The points the triangulation was made from, or failed on (KiCad keeps a hash of them)
    private var triangulatedPoints: [[[IPoint]]]?
    private var failedPoints: [[[IPoint]]]?

    public init() {}

    public init(_ polygons: [[LineChain]]) { self.polygons = polygons }

    public var outlineCount: Int { polygons.count }

    public func holeCount(_ outline: Int) -> Int { polygons[outline].count < 2 ? 0 : polygons[outline].count - 1 }

    /// A new outline, empty and closed; its index (KiCad's NewOutline)
    @discardableResult
    public mutating func newOutline() -> Int {
        var empty = LineChain()
        empty.setClosed(true)
        polygons.append([empty])
        return polygons.count - 1
    }

    /// A new hole, empty and closed, in `outline` (-1 the last); its index among the last outline's holes (KiCad's
    /// NewHole)
    @discardableResult
    public mutating func newHole(_ outline: Int = -1) -> Int {
        var empty = LineChain()
        empty.setClosed(true)
        polygons[outline < 0 ? outline + polygons.count : outline].append(empty)
        return polygons[polygons.count - 1].count - 2
    }

    /// A point added to an outline (-1 the last) or to one of its holes, unless it is the point before it (KiCad's
    /// SHAPE_POLY_SET::Append); how many points that chain has
    @discardableResult
    public mutating func append(_ p: IPoint, outline: Int = -1, hole: Int = -1, allowDuplication: Bool = false) -> Int {
        let o = outline < 0 ? outline + polygons.count : outline
        let i = hole < 0 ? 0 : hole + 1
        polygons[o][i].append(p, allowDuplication: allowDuplication)
        return polygons[o][i].pointCount
    }

    /// An outline added as a polygon of its own, closed if it was not (KiCad's AddOutline); its index
    @discardableResult
    public mutating func addOutline(_ outline: LineChain) -> Int {
        var o = outline
        if !o.isClosed { o.setClosed(true) }
        polygons.append([o])
        return polygons.count - 1
    }

    /// A hole added to `outline` (-1 the last); its index among its holes (KiCad's AddHole)
    @discardableResult
    public mutating func addHole(_ hole: LineChain, outline: Int = -1) -> Int {
        let o = outline < 0 ? outline + polygons.count : outline
        polygons[o].append(hole)
        return polygons[o].count - 2
    }

    /// The arcs made polylines (KiCad's ClearArcs): the port's chains have none
    public mutating func clearArcs() {}

    /// Whether `p` is inside one of the outlines, their holes not looked at (KiCad's SHAPE_POLY_SET::PointInside)
    public func pointInside(_ p: IPoint, accuracy: Int = 0) -> Bool {
        polygons.contains { $0[0].pointInside(p, accuracy: accuracy) }
    }

    /// Every chain simplified: points within `tolerance` of the line from the point kept before them to the one after
    /// taken out (KiCad's SimplifyOutlines)
    public mutating func simplifyOutlines(_ tolerance: Int = 0) {
        for i in polygons.indices {
            for j in polygons[i].indices { polygons[i][j].simplify(tolerance) }
        }
    }

    /// Another set's polygons added after this one's (KiCad's Append of a SHAPE_POLY_SET)
    public mutating func append(_ other: PolySet) { polygons += other.polygons }

    /// Every point turned about `center` (KiCad's Rotate)
    public mutating func rotate(_ angle: EDAAngle, around center: IPoint = .zero) {
        for i in polygons.indices {
            for j in polygons[i].indices { polygons[i][j] = polygons[i][j].rotated(angle, around: center) }
        }
    }

    /// Every point moved by `d` (KiCad's Move)
    public mutating func move(_ d: IPoint) {
        for i in polygons.indices {
            for j in polygons[i].indices { polygons[i][j] = polygons[i][j].moved(d) }
        }
    }

    // MARK: - Clipper2

    /// The set made its union with `b` (KiCad's BooleanAdd)
    public mutating func booleanAdd(_ b: PolySet) { booleanOp(.union, self, b) }

    /// The set made its intersection with `b` (KiCad's BooleanIntersection)
    public mutating func booleanIntersection(_ b: PolySet) { booleanOp(.intersection, self, b) }

    /// What of it is not in `b` (BooleanSubtract)
    public mutating func booleanSubtract(_ b: PolySet) { booleanOp(.difference, self, b) }

    /// How an outline's corners are offset (KiCad's CORNER_STRATEGY)
    public enum CornerStrategy { case allowAcuteCorners, chamferAcuteCorners, roundAcuteCorners, chamferAllCorners, roundAllCorners }

    /// Every outline grown by `amount` (shrunk if it is negative), its holes shrunk, by Clipper2's offset, its round
    /// corners `maxError` from true (KiCad's Inflate)
    public mutating func inflate(_ amount: Int, _ cornerStrategy: CornerStrategy, maxError: Int, simplify: Bool = false) {
        let segCount = KiMath.arcToSegmentCount(abs(amount), maxError, .a360)
        inflate2(amount, segCount, cornerStrategy, simplify: simplify)
    }

    /// KiCad's inflate2: the arc tolerance worked out from the segments a full circle would have
    private mutating func inflate2(_ amount: Int, _ circleSegCount: Int, _ cornerStrategy: CornerStrategy, simplify: Bool) {
        var joinType = Clipper.JoinType.round
        var miterLimit = 2.0
        switch cornerStrategy {
        case .allowAcuteCorners:
            joinType = .miter
            miterLimit = 10
        case .chamferAcuteCorners, .roundAcuteCorners:
            joinType = .miter
        case .chamferAllCorners:
            joinType = .square
        case .roundAllCorners:
            joinType = .round
        }
        var zValues: [ClipperZValue] = []
        var arcBuffer: [ShapeArc] = []
        let c = Clipper.ClipperOffset()
        for poly in polygons {
            var paths = Clipper.Paths64()
            for (i, chain) in poly.enumerated() { paths.append(chain.convertToClipper2(i == 0, &zValues, &arcBuffer)) }
            c.addPaths(paths, joinType, .polygon)
        }
        let segCount = max(circleSegCount, 6)
        let coeff = 1.0 - Foundation.cos(Double.pi / Double(segCount))
        c.arcTolerance = Double(abs(amount)) * coeff
        c.miterLimit = miterLimit
        let tree = Clipper.PolyTree64()
        if simplify {
            // (KiCad calls SimplifyPaths on the offset's paths and drops what it returns: the paths are united as
            // they are)
            let paths = c.execute(Double(amount))
            let c2 = Clipper.Clipper64()
            c2.preserveCollinear = false
            c2.reverseSolution = false
            c2.addSubject(paths)
            _ = c2.execute(.union, .positive, polytree: tree)
        } else {
            c.execute(Double(amount), polytree: tree)
        }
        importTree(tree, zValues, arcBuffer)
    }

    /// The set made the union, intersection, difference or exclusive or of `a` and `b` under the non-zero rule, by
    /// Clipper2, with the z values KiCad follows its arcs through it with (KiCad's booleanOp)
    private mutating func booleanOp(_ type: Clipper.ClipType, _ a: PolySet, _ b: PolySet) {
        // (KiCad asks for a curved polygon's arcs to be cleared first; the port's chains have none)
        let c = Clipper.Clipper64()
        var zValues: [ClipperZValue] = []
        var arcBuffer: [ShapeArc] = []
        var paths = Clipper.Paths64(), clips = Clipper.Paths64()
        for poly in a.polygons {
            for (i, chain) in poly.enumerated() { paths.append(chain.convertToClipper2(i == 0, &zValues, &arcBuffer)) }
        }
        for poly in b.polygons {
            for (i, chain) in poly.enumerated() { clips.append(chain.convertToClipper2(i == 0, &zValues, &arcBuffer)) }
        }
        c.addSubject(paths)
        c.addClip(clips)
        let solution = Clipper.PolyTree64()
        // each point made where edges cross gets a z value of its own: the arc of the first edge if both its ends
        // are on it, with the second's, else the second's
        c.zCallback = { e1bot, e1top, e2bot, e2top, pt in
            func arcIndex(_ z: Int, _ compare: Int = -1) -> Int {
                var r = zValues[z].secondArcIdx
                if r == -1 || (compare > 0 && r != compare) { r = zValues[z].firstArcIdx }
                return r
            }
            func arcSegment(_ bottom: Int, _ top: Int) -> Int {
                var r = arcIndex(bottom)
                if r != -1 && r != arcIndex(top, r) { r = -1 }
                return r
            }
            let e1 = arcSegment(e1bot.z, e1top.z), e2 = arcSegment(e2bot.z, e2top.z)
            var z = ClipperZValue()
            if e1 != -1 {
                z.firstArcIdx = e1
                z.secondArcIdx = e2
            } else {
                z.firstArcIdx = e2
                z.secondArcIdx = -1
            }
            pt.z = zValues.count
            zValues.append(z)
        }
        c.execute(type, .nonZero, polytree: solution)
        importTree(solution, zValues, arcBuffer)
    }

    /// The set made the tree's outlines, each with its holes, an outline inside a hole before the one round it
    /// (KiCad's importTree)
    private mutating func importTree(_ tree: Clipper.PolyTree64, _ zValues: [ClipperZValue], _ arcBuffer: [ShapeArc]) {
        polygons.removeAll()
        for n in tree.children { importPolyPath(n, zValues, arcBuffer) }
    }

    private mutating func importPolyPath(_ path: Clipper.PolyPath64, _ zValues: [ClipperZValue], _ arcBuffer: [ShapeArc]) {
        guard !path.isHole else { return }
        var paths = [LineChain(clipperPath: path.polygon, zValues, arcBuffer)]
        for child in path.children {
            paths.append(LineChain(clipperPath: child.polygon, zValues, arcBuffer))
            for grandchild in child.children { importPolyPath(grandchild, zValues, arcBuffer) }
        }
        polygons.append(paths)
    }

    /// Overlapping outlines and holes merged and what has no area taken out: outlines that run back along themselves
    /// with nothing either side split there, then the set united with nothing by Clipper2 (KiCad's Simplify)
    public mutating func simplify() {
        splitCollinearOutlines()
        booleanOp(.union, self, PolySet())
    }

    /// Whether two edges along each other have nothing of the set either side, 10 nm off the middle of their
    /// overlap (if it is longer than 25 nm): a waist of no width (KiCad's isExteriorWaist)
    private func isExteriorWaist(_ segA: Seg, _ segB: Seg) -> Bool {
        let da = segA.b - segA.a
        let byX = abs(da.x) >= abs(da.y)
        let pts = [segA.a, segA.b, segB.a, segB.b].sorted { (p: IPoint, q: IPoint) -> Bool in
            if byX { return p.x < q.x || (p.x == q.x && p.y < q.y) }
            return p.y < q.y || (p.y == q.y && p.x < q.x)
        }
        let s = pts[1], e = pts[2]
        let midpoint = (s + e).divided(by: 2)
        let segDir = e - s
        if segDir.norm > 25 {
            let perp = segDir.perpendicular.resized(10)
            if !pointInside(midpoint + perp) && !pointInside(midpoint - perp) { return true }
        }
        return false
    }

    /// Each outline that runs back along itself (two of its edges within 10 nm of each other's line) with nothing either
    /// side split there in two, the second a polygon of its own, until none does (KiCad's splitCollinearOutlines)
    private mutating func splitCollinearOutlines() {
        var polyIdx = 0
        while polyIdx < polygons.count {
            while true {
                let outline = polygons[polyIdx][0]
                let count = outline.pointCount
                // (KiCad's tree of the edges' boxes has 64-bit integer coordinates and volumes)
                let rtree = RTree<Int, Int>()
                func box(_ i: Int) -> IBox {
                    let a = outline.point(i), b = outline.point((i + 1) % count)
                    return IBox(minX: min(a.x, b.x), minY: min(a.y, b.y), maxX: max(a.x, b.x), maxY: max(a.y, b.y))
                }
                for i in 0..<count { rtree.insert(box(i), i) }
                var found = false
                var segA = -1, segB = -1
                var i = 0
                while i < count && !found {
                    let a = outline.point(i), b = outline.point((i + 1) % count)
                    let seg = Seg(a, b)
                    rtree.search(box(i)) { j in
                        if j == i || j == (i + 1) % count || j == (i + count - 1) % count { return true }
                        let oa = outline.point(j), ob = outline.point((j + 1) % count)
                        // (an edge and its pair, as fracturing makes them)
                        if (oa == a && ob == b) || (oa == b && ob == a) { return true }
                        let other = Seg(oa, ob)
                        if seg.approxCollinear(other, threshold: 10) && isExteriorWaist(seg, other) {
                            segA = i
                            segB = j
                            found = true
                            return false
                        }
                        return true
                    }
                    i += 1
                }
                if !found { break }
                let n = outline.pointCount
                let a0 = segA, a1 = (segA + 1) % n, b0 = segB, b1 = (segB + 1) % n
                var lc1 = LineChain()
                var idx = a1
                lc1.append(outline.point(idx))
                while idx != b0 {
                    idx = (idx + 1) % n
                    lc1.append(outline.point(idx))
                }
                lc1.setClosed(true)
                var lc2 = LineChain()
                idx = b1
                lc2.append(outline.point(idx))
                while idx != a0 {
                    idx = (idx + 1) % n
                    lc2.append(outline.point(idx))
                }
                lc2.setClosed(true)
                polygons[polyIdx][0] = lc1
                polygons.append([lc2])
            }
            polyIdx += 1
        }
    }

    /// Each outline that touches itself, one of its points exactly on one of its other edges, split there in two, the
    /// second a polygon of its own, where both parts wind as the whole does (a part that winds the other way is a
    /// fractured hole's way in), until none does (KiCad's splitSelfTouchingOutlines)
    mutating func splitSelfTouchingOutlines() {
        var polyIdx = 0
        while polyIdx < polygons.count {
            while true {
                let outline = polygons[polyIdx][0]
                let count = outline.pointCount
                if count < 4 { break }
                // the trapezoids under the edges summed from the first, to sign a part's area at once (made when first
                // needed)
                var prefix: [Double] = []
                func ringTerm(_ from: Int, _ to: Int) -> Double {
                    if prefix.isEmpty {
                        prefix = [Double](repeating: 0, count: count + 1)
                        for ii in 0..<count {
                            let a = outline.point(ii), b = outline.point((ii + 1) % count)
                            prefix[ii + 1] = prefix[ii] + (Double(a.x) + Double(b.x)) * (Double(a.y) - Double(b.y))
                        }
                    }
                    let term = from <= to ? prefix[to] - prefix[from] : prefix[count] - prefix[from] + prefix[to]
                    let last = outline.point(to), first = outline.point(from)
                    return term + (Double(last.x) + Double(first.x)) * (Double(last.y) - Double(first.y))
                }
                func ringSize(_ from: Int, _ to: Int) -> Int { from <= to ? to - from + 1 : count - from + to + 1 }
                func splittable(_ vertIdx: Int, _ segIdx: Int) -> Bool {
                    let start = (segIdx + 1) % count
                    if ringSize(start, vertIdx) < 3 || ringSize(vertIdx, segIdx) < 3 { return false }
                    let sign = ringTerm(0, count - 1) > 0
                    let term1 = ringTerm(start, vertIdx), term2 = ringTerm(vertIdx, segIdx)
                    return term1 != 0 && term2 != 0 && (term1 > 0) == sign && (term2 > 0) == sign
                }
                // (a point on the edge: its squared distance rounding to nothing, and not one of the edge's ends)
                func touches(_ pt: IPoint, _ segIdx: Int) -> Bool {
                    let a = outline.point(segIdx), b = outline.point((segIdx + 1) % count)
                    return pt != a && pt != b && Seg(a, b).squaredDistance(pt) == 0
                }
                var insertSegIdx = -1, insertVertIdx = -1
                if count < 32 {
                    // (KiCad looks through every edge for a small outline, through a tree of their boxes for a bigger)
                    var vertIdx = 0
                    while vertIdx < count && insertSegIdx < 0 {
                        let pt = outline.point(vertIdx)
                        let prevSeg = (vertIdx + count - 1) % count
                        for segIdx in 0..<count where segIdx != prevSeg && segIdx != vertIdx {
                            if touches(pt, segIdx) && splittable(vertIdx, segIdx) {
                                insertSegIdx = segIdx
                                insertVertIdx = vertIdx
                                break
                            }
                        }
                        vertIdx += 1
                    }
                } else {
                    let rtree = RTree<Int, Double>()
                    for i in 0..<count {
                        let a = outline.point(i), b = outline.point((i + 1) % count)
                        rtree.insert(IBox(minX: min(a.x, b.x), minY: min(a.y, b.y), maxX: max(a.x, b.x), maxY: max(a.y, b.y)), i)
                    }
                    var vertIdx = 0
                    while vertIdx < count && insertSegIdx < 0 {
                        let pt = outline.point(vertIdx)
                        let prevSeg = (vertIdx + count - 1) % count
                        rtree.search(IBox(minX: pt.x, minY: pt.y, maxX: pt.x, maxY: pt.y)) { segIdx in
                            if segIdx == prevSeg || segIdx == vertIdx { return true }
                            if touches(pt, segIdx) && splittable(vertIdx, segIdx) {
                                insertSegIdx = segIdx
                                insertVertIdx = vertIdx
                                return false
                            }
                            return true
                        }
                        vertIdx += 1
                    }
                }
                if insertSegIdx < 0 { break }
                // the part from the edge's end round to the point, and the part from the point round to the edge
                let splitStart1 = (insertSegIdx + 1) % count
                let size1 = ringSize(splitStart1, insertVertIdx), size2 = ringSize(insertVertIdx, insertSegIdx)
                var poly1 = LineChain(), poly2 = LineChain()
                var idx = splitStart1
                for _ in 0..<size1 {
                    poly1.append(outline.point(idx))
                    idx = (idx + 1) % count
                }
                poly1.setClosed(true)
                idx = insertVertIdx
                for _ in 0..<size2 {
                    poly2.append(outline.point(idx))
                    idx = (idx + 1) % count
                }
                poly2.setClosed(true)
                polygons[polyIdx][0] = poly1
                polygons.append([poly2])
            }
            polyIdx += 1
        }
    }

    // MARK: - Fracturing

    /// Each polygon's holes joined into its outline, simplified first unless asked not to (KiCad's Fracture)
    public mutating func fracture(simplify: Bool = true) {
        if simplify { self.simplify() }
        for i in polygons.indices { Self.fractureSingle(&polygons[i]) }
    }

    /// An edge of a polygon being fractured, and the index of the one after it (KiCad's FractureEdge)
    private struct FractureEdge {
        var p1 = IPoint.zero, p2 = IPoint.zero
        var next = 0

        func matches(_ y: Int) -> Bool { (y >= p1.y || y >= p2.y) && (y <= p1.y || y <= p2.y) }
    }

    /// A hole joined at its leftmost point (the edge `edgeIndex` starts there) to the nearest edge on its left among
    /// those before it (from the outline and the holes already joined, `provokingIndex` the hole's first edge), by two
    /// edges along x put in the slots from `bridgeIndex`, the edge met split in two in the third; false if no edge was
    /// met (KiCad's processHole)
    private static func processHole(_ edges: inout [FractureEdge], _ provokingIndex: Int, _ edgeIndex: Int,
                                    _ bridgeIndex: Int) -> Bool {
        let edge = edges[edgeIndex]
        let x = edge.p1.x, y = edge.p1.y
        var minDist = Int(Int32.max), xNearest = 0
        var nearest: Int?
        // (the holes are joined left to right: none after this one can be nearer, or joined yet)
        for i in 0..<provokingIndex {
            let e = edges[i]
            if !e.matches(y) { continue }
            let xIntersect: Int
            if e.p1.y == e.p2.y {
                xIntersect = max(e.p1.x, e.p2.x)
            } else {
                xIntersect = e.p1.x + KiMath.rescale(e.p2.x - e.p1.x, y - e.p1.y, e.p2.y - e.p1.y)
            }
            let dist = x - xIntersect
            if dist >= 0 && dist < minDist {
                minDist = dist
                xNearest = xIntersect
                nearest = i
            }
        }
        guard let n = nearest else { return false }
        let outline2hole = bridgeIndex, hole2outline = bridgeIndex + 1, split = bridgeIndex + 2
        let met = IPoint(xNearest, y)
        edges[outline2hole] = FractureEdge(p1: met, p2: edge.p1, next: edgeIndex)
        edges[hole2outline] = FractureEdge(p1: edge.p1, p2: met, next: split)
        edges[split] = FractureEdge(p1: met, p2: edges[n].p2, next: edges[n].next)
        edges[n].p2 = met
        edges[n].next = outline2hole
        var last = edgeIndex
        while edges[last].next != edgeIndex { last = edges[last].next }
        edges[last].next = hole2outline
        return true
    }

    /// A polygon's holes joined into its outline, left to right by their leftmost points, each to the nearest edge on
    /// its left (KiCad's fractureSingleCacheFriendly, the fracture its advanced setting EnableCacheFriendlyFracture
    /// chooses by default); left as it was where a hole meets nothing on its left
    private static func fractureSingle(_ paths: inout [LineChain]) {
        if paths.count == 1 { return }
        struct PathInfo {
            var pathOrProvokingIndex: Int
            var leftmost: Int
            var x: Int
            var yOrBridge: Int
        }
        var sortedPaths: [PathInfo] = []
        for (pathIndex, path) in paths.enumerated() {
            var xMin = Int(Int32.max), yMin = Int(Int32.max), leftmost = -1
            for (i, p) in path.points.enumerated() {
                if p.x < xMin {
                    xMin = p.x
                    leftmost = i
                }
                if p.y < yMin { yMin = p.y }
            }
            sortedPaths.append(PathInfo(pathOrProvokingIndex: pathIndex, leftmost: leftmost, x: xMin, yOrBridge: yMin))
        }
        // the holes by their leftmost x, then their lowest y (as std::sort leaves those that tie)
        var holes = Array(sortedPaths.dropFirst())
        Clipper.introSort(&holes) { a, b in a.x == b.x ? a.yOrBridge < b.yOrBridge : a.x < b.x }
        sortedPaths.replaceSubrange(1..., with: holes)
        // each path's edges in a ring, each hole's followed by three slots for its bridge
        var edges: [FractureEdge] = []
        var edgeIndex = 0
        for k in sortedPaths.indices {
            let points = paths[sortedPaths[k].pathOrProvokingIndex].points
            let provokingEdge = edgeIndex
            for i in 0..<(points.count - 1) {
                edges.append(FractureEdge(p1: points[i], p2: points[i + 1], next: edgeIndex + 1))
                edgeIndex += 1
            }
            edges.append(FractureEdge(p1: points[points.count - 1], p2: points[0], next: provokingEdge))
            edgeIndex += 1
            if k > 0 {
                sortedPaths[k].pathOrProvokingIndex = provokingEdge
                sortedPaths[k].yOrBridge = edgeIndex
                edgeIndex += 3
                edges.append(contentsOf: repeatElement(FractureEdge(), count: 3))
            }
        }
        for info in sortedPaths.dropFirst() {
            // (KiCad warns of a broken polygon and leaves it be)
            if !processHole(&edges, info.pathOrProvokingIndex, info.pathOrProvokingIndex + info.leftmost, info.yOrBridge) {
                return
            }
        }
        var newPath = LineChain()
        newPath.setClosed(true)
        var e = 0
        while edges[e].next != 0 {
            newPath.append(edges[e].p1)
            e = edges[e].next
        }
        newPath.append(edges[e].p1)
        paths = [newPath]
    }

    // MARK: - Triangulation

    private var pointsKey: [[[IPoint]]] { polygons.map { $0.map(\.points) } }

    /// Whether the triangles are those of the set as it is now (KiCad's IsTriangulationUpToDate): false if they
    /// could not all be cut
    /// Whether a polygon has a hole (HasHoles)
    public var hasHoles: Bool { polygons.contains { $0.count > 1 } }

    /// Whether two sides of a polygon, its outline's or its holes', not one after the other, touch
    /// (IsPolygonSelfIntersecting: the sides in order of their least x, then y, each tried against those after it
    /// that may reach it)
    func isPolygonSelfIntersecting(_ polygon: Int) -> Bool {
        var segments = polygons[polygon].flatMap { c in (0..<c.segmentCount).map(c.segment) }
        Clipper.introSort(&segments) { a, b in
            let minA = min(a.a.x, a.b.x), minB = min(b.a.x, b.b.x)
            return minA < minB || (minA == minB && min(a.a.y, a.b.y) < min(b.a.y, b.b.y))
        }
        for i in segments.indices {
            let first = segments[i]
            let maxX = max(first.a.x, first.b.x), maxY = max(first.a.y, first.b.y)
            for j in (i + 1)..<segments.count {
                let second = segments[j]
                let minX = min(second.a.x, second.b.x), minY = min(second.a.y, second.b.y)
                if maxX < minX || (maxX == minX && maxY < minY) { break }
                let diff = abs(first.index - second.index)
                let adjacent = diff == 1 || diff == segments.count - 1
                var actual: Int?
                if !adjacent && first.collide(second, clearance: 0, actual: &actual) { return true }
            }
        }
        return false
    }

    /// IsSelfIntersecting: whether one of its polygons crosses itself
    public var isSelfIntersecting: Bool { polygons.indices.contains(where: isPolygonSelfIntersecting) }

    /// partitionPolyIntoRegularCellGrid: the set cut by a grid of cells about `size` across over its bounding box,
    /// the pieces in the odd cells, fractured, then those in the even ones; the set itself if nothing is left (or its
    /// box is a line)
    static func partitionIntoRegularCellGrid(_ poly: PolySet, _ size: Int) -> PolySet {
        guard var bb = poly.polygons.first?[0].bbox else { return poly }
        for p in poly.polygons.dropFirst() { bb.merge(p[0].bbox) }
        let w = Double(bb.maxX - bb.minX), h = Double(bb.maxY - bb.minY)
        if w == 0 || h == 0 { return poly }
        let nx: Int, ny: Int
        if w > h {
            nx = Int(w / Double(size))
            ny = Int((h / w * Double(nx)).rounded(.down)) + 1
        } else {
            ny = Int(h / Double(size))
            nx = Int((w / h * Double(ny)).rounded(.down)) + 1
        }
        var ps1 = poly, ps2 = poly
        var odd = PolySet(), even = PolySet()
        for yy in 0..<max(ny, 0) {
            for xx in 0..<max(nx, 0) {
                // (a VECTOR2I's coordinates from doubles, cut towards zero)
                func at(_ o: Int, _ size: Double, _ k: Int, _ n: Int) -> Int { Int(Double(o) + size * Double(k) / Double(n)) }
                let px = at(bb.minX, w, xx, nx), py = at(bb.minY, h, yy, ny)
                let qx = at(bb.minX, w, xx + 1, nx), qy = at(bb.minY, h, yy + 1, ny)
                var mask = LineChain()
                for q in [IPoint(px, py), IPoint(qx, py), IPoint(qx, qy), IPoint(px, qy)] { mask.append(q) }
                mask.setClosed(true)
                if (xx ^ yy) & 1 != 0 { odd.addOutline(mask) } else { even.addOutline(mask) }
            }
        }
        ps1.booleanIntersection(odd)
        ps2.booleanIntersection(even)
        ps1.fracture()
        ps2.fracture()
        for p in ps2.polygons { ps1.addOutline(p[0]) }
        return ps1.outlineCount > 0 ? ps1 : poly
    }

    public var isTriangulationUpToDate: Bool { triangulationValid && triangulatedPoints == pointsKey }

    /// The set cut into triangles as KiCad cuts a zone's outline for its router (CacheTriangulation( false ): the whole
    /// set, not in cells): a copy simplified, its holes fractured into its outlines, and its outlines split where they
    /// touch themselves, then each outline cut in turn. Where one cannot be, every chain left is simplified (points
    /// within 50 nm of the line taken out) and that one tried again; if it still cannot be, or a later one cannot be,
    /// the cutting stops there and the triangulation is not valid
    ///
    /// With `partition` (CacheTriangulation( true ), as a zone's fill is cut): each outline in turn, with its holes,
    /// fractured and split where it touches itself if it has holes or crosses itself, cut by a grid of 1 cm cells
    /// into pieces, and those cut into triangles; valid if any outline's could be
    public mutating func cacheTriangulation(partition: Bool = false) {
        let key = pointsKey
        if triangulationValid && triangulatedPoints == key { return }
        if failedPoints == key { return }
        triangulationValid = false
        triangulatedPoints = nil
        failedPoints = nil
        triangulatedPolygons.removeAll()
        if partition {
            for ii in polygons.indices {
                var flattened = PolySet([polygons[ii]])
                flattened.clearArcs()
                if flattened.hasHoles || flattened.isSelfIntersecting {
                    flattened.fracture()
                    flattened.splitSelfTouchingOutlines()
                }
                var partitions = Self.partitionIntoRegularCellGrid(flattened, 10_000_000)
                if Self.triangulate(&partitions, ii, &triangulatedPolygons) { triangulationValid = true }
            }
        } else {
            var tmpSet = PolySet(polygons)
            tmpSet.clearArcs()
            tmpSet.fracture()
            tmpSet.splitSelfTouchingOutlines()
            if Self.triangulate(&tmpSet, -1, &triangulatedPolygons) { triangulationValid = true }
        }
        if triangulationValid {
            triangulatedPoints = key
        } else {
            failedPoints = key
        }
    }

    /// Each outline of the set cut into triangles and taken out of it, in turn (KiCad's triangulate lambda in
    /// cacheTriangulation): whether the last one cut could be (none: false)
    private static func triangulate(_ polySet: inout PolySet, _ forOutline: Int, _ dest: inout [TriangulatedPolygon]) -> Bool {
        var triangulationValid = false
        var pass = 0
        while polySet.outlineCount > 0 {
            // (one that made no triangles dropped when the next is begun; one that failed kept, with what it made)
            if let last = dest.last, last.triangles.isEmpty { dest.removeLast() }
            let tess = PolygonTriangulation(TriangulatedPolygon(sourceOutline: forOutline))
            let ok = tess.tesselatePolygon(polySet.polygons[0][0])
            dest.append(tess.result)
            if !ok {
                pass += 1
                guard pass == 1 else { break }
                polySet.simplifyOutlines(PolygonTriangulation.simplification)
                triangulationValid = false
                continue
            }
            polySet.polygons.removeFirst()
            triangulationValid = true
        }
        return triangulationValid
    }
}
