// Ported from KiCad 10.0.7: libs/kimath/include/geometry/shape_line_chain.h and
// libs/kimath/src/geometry/shape_line_chain.cpp (without arcs, which the router here does not draw).
// Copyright (C) 2013 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// A polyline, open or closed (KiCad's SHAPE_LINE_CHAIN, straight segments only): a trace's path, an obstacle's
/// hull. Indices wrap as KiCad's do: -1 is the last point.
public struct LineChain: Hashable, Sendable, CustomStringConvertible {
    public internal(set) var points: [IPoint] = []
    public private(set) var isClosed = false

    /// Where two chains cross (KiCad's SHAPE_LINE_CHAIN::INTERSECTION)
    public struct Intersection: Sendable {
        public var p: IPoint
        /// The crossing segment (or corner) of this chain, and of the other
        public var indexOur = -1
        public var indexTheir = -1
        /// Whether the crossing is exactly this chain's corner, or the other's
        public var isCornerOur = false
        public var isCornerTheir = false
        public var valid = false

        public init(p: IPoint) { self.p = p }
    }

    public init() {}

    public init(_ points: [IPoint], closed: Bool = false) {
        self.points = points
        isClosed = closed
        mergeFirstLastPointIfNeeded()
    }

    public var description: String {
        "LineChain(" + points.map(\.description).joined(separator: ", ") + (isClosed ? ", closed)" : ")")
    }

    // MARK: - Points and segments

    public var pointCount: Int { points.count }

    public var segmentCount: Int { max(0, points.count - 1 + (isClosed ? 1 : 0)) }

    public func point(_ i: Int) -> IPoint {
        var i = i
        if i < 0 { i += points.count } else if i >= points.count { i -= points.count }
        return points[i]
    }

    public var lastPoint: IPoint { points[points.count - 1] }

    public func segment(_ i: Int) -> Seg {
        let count = segmentCount
        var i = i
        if i < 0 { i += count }
        guard i >= 0 && i < count else { return points.isEmpty ? Seg(.zero, .zero) : Seg(points[points.count - 1], points[points.count - 1]) }
        if i == points.count - 1 && isClosed { return Seg(points[i], points[0], index: i) }
        return Seg(points[i], points[i + 1], index: i)
    }

    public var segments: [Seg] { (0..<segmentCount).map(segment) }

    public mutating func setClosed(_ closed: Bool) {
        isClosed = closed
        mergeFirstLastPointIfNeeded()
    }

    private mutating func mergeFirstLastPointIfNeeded() {
        if isClosed && points.count > 1 && points.first == points.last { points.removeLast() }
    }

    public mutating func setPoint(_ i: Int, _ p: IPoint) {
        var i = i
        if i < 0 { i += points.count }
        points[i] = p
    }

    public mutating func clear() {
        points.removeAll()
        isClosed = false
    }

    // MARK: - Building

    public mutating func append(_ p: IPoint, allowDuplication: Bool = false) {
        if points.isEmpty || allowDuplication || points[points.count - 1] != p { points.append(p) }
    }

    public mutating func append(_ x: Int, _ y: Int) { append(IPoint(x, y)) }

    public mutating func append(_ other: LineChain) {
        guard !other.points.isEmpty else { return }
        if points.isEmpty || other.points[0] != points[points.count - 1] { points.append(other.points[0]) }
        points.append(contentsOf: other.points.dropFirst())
        mergeFirstLastPointIfNeeded()
    }

    public mutating func insert(_ p: IPoint, at vertex: Int) {
        if vertex == points.count {
            append(p)
            return
        }
        guard vertex >= 0 && vertex < points.count else { return }
        points.insert(p, at: vertex)
    }

    public mutating func remove(_ start: Int, _ end: Int) {
        let closed = isClosed
        isClosed = false
        var (s, e) = (start, end)
        if e < 0 { e += points.count }
        if s < 0 { s += points.count }
        if s >= points.count || e >= points.count || s > e {
            setClosed(closed)
            return
        }
        points.removeSubrange(s...e)
        setClosed(closed)
    }

    public mutating func remove(_ i: Int) { remove(i, i) }

    public mutating func replace(_ start: Int, _ end: Int, with p: IPoint) {
        remove(start, end)
        insert(p, at: start)
    }

    public mutating func replace(_ start: Int, _ end: Int, with line: LineChain) {
        var (s, e) = (start, end)
        if e < 0 { e += points.count }
        if s < 0 { s += points.count }
        var newLine = line
        if newLine.points.isEmpty {
            remove(s, e)
            return
        }
        if newLine.points[0] == points[s] {
            s += 1
            newLine.remove(0)
            if newLine.points.isEmpty {
                remove(s, e)
                return
            }
        }
        if newLine.points[newLine.points.count - 1] == points[e] && e > 0 {
            e -= 1
            newLine.remove(-1)
        }
        remove(s, e)
        if newLine.points.isEmpty { return }
        points.insert(contentsOf: newLine.points, at: s)
    }

    /// Inserts `p` into the segment it lies on (within 2 nm); its index, or -1 if it lies on none
    @discardableResult
    public mutating func split(_ p: IPoint, exact: Bool = false) -> Int {
        var ii = -1
        var minDist = 2
        let found = find(p)
        if found >= 0 && exact { return found }
        for s in 0..<segmentCount {
            let seg = segment(s)
            let d = seg.distance(p)
            if d < minDist && seg.a != p && seg.b != p {
                minDist = d
                if found < 0 { ii = s } else if s < found { ii = s }
            }
        }
        if ii < 0 { ii = found }
        if ii >= 0 {
            if points[ii] == p { return ii }
            insert(p, at: ii + 1)
            return ii + 1
        }
        return -1
    }

    public func find(_ p: IPoint, threshold: Int = 0) -> Int {
        for s in 0..<points.count {
            if threshold == 0 ? points[s] == p : (points[s] - p).norm <= threshold { return s }
        }
        return -1
    }

    public func findSegment(_ p: IPoint, threshold: Int = 1) -> Int {
        for s in 0..<segmentCount where segment(s).distance(p) <= threshold { return s }
        return -1
    }

    /// Points `start` to `end`, inclusive, as an open chain (a point the same as the one before it left out, as
    /// KiCad's Slice appends them)
    public func slice(_ start: Int, _ end: Int) -> LineChain {
        var (s, e) = (start, end)
        if e < 0 { e += points.count }
        if s < 0 { s += points.count }
        guard s >= 0, e >= 0, s < points.count, e < points.count, e >= s else { return LineChain() }
        var rv = LineChain()
        for i in s...e { rv.append(points[i]) }
        return rv
    }

    public func reversed() -> LineChain {
        var r = self
        r.points.reverse()
        return r
    }

    // MARK: - Measures

    public var length: Int { (0..<segmentCount).reduce(0) { $0 + segment($1).length } }

    public var bbox: IBox { IBox(points: points) ?? IBox(minX: 0, minY: 0, maxX: 0, maxY: 0) }

    public func bbox(_ clearance: Int) -> IBox { clearance == 0 ? bbox : bbox.inflated(clearance) }

    /// The length along the chain to `p`, which is on segment `index` (or the first segment it is on)
    public func pathLength(_ p: IPoint, index: Int = -1) -> Int {
        var sum = 0
        for i in 0..<segmentCount {
            let seg = segment(i)
            var match = true
            if index >= 0 { match = index == segmentCount ? i == segmentCount - 1 : i == index }
            if match { return sum + (p - seg.a).norm }
            sum += seg.length
        }
        return -1
    }

    public func pointAlong(_ length: Int) -> IPoint {
        var total = 0
        if length == 0 { return point(0) }
        for i in 0..<segmentCount {
            let s = segment(i)
            let l = s.length
            if total + l >= length { return s.a + (s.b - s.a).resized(length - total) }
            total += l
        }
        return lastPoint
    }

    public func area(absolute: Bool = true) -> Double {
        guard isClosed else { return 0 }
        var a = 0.0
        var j = points.count - 1
        for i in 0..<points.count {
            a += (Double(points[j].x) + Double(points[i].x)) * (Double(points[j].y) - Double(points[i].y))
            j = i
        }
        return absolute ? abs(a * 0.5) : -a * 0.5
    }

    // MARK: - Inside, on the edge, nearest

    public func pointInside(_ p: IPoint, accuracy: Int = 0) -> Bool {
        guard isClosed && points.count >= 3 else { return false }
        var inside = false
        let n = points.count
        var i = 0
        while i < n {
            let p1 = points[i]
            i += 1
            let p2 = points[i == n ? 0 : i]
            let diff = p2 - p1
            if diff.y == 0 { continue }
            let d = KiMath.rescale(diff.x, p.y - p1.y, diff.y)
            if ((p1.y >= p.y) != (p2.y >= p.y)) && (p.x - p1.x < d) { inside.toggle() }
        }
        return accuracy <= 1 ? inside : inside || pointOnEdge(p, accuracy: accuracy)
    }

    public func pointOnEdge(_ p: IPoint, accuracy: Int = 0) -> Bool { edgeContainingPoint(p, accuracy: accuracy) >= 0 }

    public func edgeContainingPoint(_ p: IPoint, accuracy: Int = 0) -> Int {
        let threshold = accuracy + 1
        let thresholdSq = threshold * threshold
        if points.isEmpty { return -1 }
        if points.count == 1 { return points[0].squaredDistance(p) <= thresholdSq ? 0 : -1 }
        for i in 0..<segmentCount {
            let s = segment(i)
            if s.a == p || s.b == p { return i }
            if s.squaredDistance(p) <= thresholdSq { return i }
        }
        return -1
    }

    public func checkClearance(_ p: IPoint, _ dist: Int) -> Bool {
        if points.isEmpty { return false }
        if points.count == 1 { return points[0] == p }
        for i in 0..<segmentCount {
            let s = segment(i)
            if s.a == p || s.b == p { return true }
            if s.distance(p) <= dist { return true }
        }
        return false
    }

    public func nearestPoint(_ p: IPoint) -> IPoint {
        if points.isEmpty { return .zero }
        return segment(nearestSegment(p)).nearestPoint(p)
    }

    /// The chain's point nearest the line through `seg`, and how near
    public func nearestPoint(_ seg: Seg, dist: inout Int) -> IPoint {
        if points.isEmpty { return .zero }
        var nearest = 0
        dist = Int(Int32.max)
        for i in 0..<points.count {
            let d = seg.lineDistance(points[i])
            if d < dist {
                dist = d
                nearest = i
            }
        }
        return points[nearest]
    }

    public func nearestSegment(_ p: IPoint) -> Int {
        var minD = Int.max, nearest = 0
        for i in 0..<segmentCount {
            let d = segment(i).distance(p)
            if d < minD {
                minD = d
                nearest = i
            }
        }
        return nearest
    }

    // MARK: - Collisions and intersections

    /// Whether `p` comes within `clearance` of the chain (or is inside it, closed)
    public func collide(_ p: IPoint, clearance: Int, actual: inout Int?, location: inout IPoint?) -> Bool {
        if isClosed && pointInside(p, accuracy: clearance) {
            location = p
            actual = 0
            return true
        }
        var closest = Int.max
        let clearanceSq = clearance * clearance
        var nearest = IPoint.zero
        for i in 0..<segmentCount {
            let pn = segment(i).nearestPoint(p)
            let d = (pn - p).squaredNorm
            if d < closest {
                nearest = pn
                closest = d
                if closest == 0 { break }
            }
        }
        if closest == 0 || closest < clearanceSq {
            location = nearest
            actual = Int(Double(closest).squareRoot())
            return true
        }
        return false
    }

    /// Whether `s` comes within `clearance` of the chain (or starts inside it, closed)
    public func collide(_ s: Seg, clearance: Int, actual: inout Int?, location: inout IPoint?) -> Bool {
        if isClosed && pointInside(s.a) {
            location = s.a
            actual = 0
            return true
        }
        var closest = Int.max
        let clearanceSq = clearance * clearance
        var nearest = IPoint.zero
        for i in 0..<segmentCount {
            let seg = segment(i)
            let d = seg.squaredDistance(s)
            if d < closest {
                nearest = seg.nearestPoint(s)
                closest = d
                if closest == 0 { break }
            }
        }
        if closest == 0 || closest < clearanceSq {
            location = nearest
            actual = Int(Double(closest).squareRoot())
            return true
        }
        return false
    }

    public func collide(_ s: Seg, clearance: Int) -> Bool {
        var actual: Int?, location: IPoint?
        return collide(s, clearance: clearance, actual: &actual, location: &location)
    }

    /// Where `s` crosses the chain, nearest its start first
    public func intersect(_ s: Seg) -> [Intersection] {
        var out: [Intersection] = []
        let n = points.count
        let sminX = min(s.a.x, s.b.x), smaxX = max(s.a.x, s.b.x), sminY = min(s.a.y, s.b.y), smaxY = max(s.a.y, s.b.y)
        for i in 0..<segmentCount {
            let pa = points[i], pb = points[i + 1 < n ? i + 1 : 0]
            if max(pa.x, pb.x) < sminX || min(pa.x, pb.x) > smaxX || max(pa.y, pb.y) < sminY || min(pa.y, pb.y) > smaxY { continue }
            if let p = Seg(pa, pb, index: i).intersect(s) {
                var x = Intersection(p: p)
                x.valid = true
                x.indexOur = i
                out.append(x)
            }
        }
        return out.sorted { (s.a - $0.p).norm < (s.a - $1.p).norm }
    }

    public func intersects(_ s: Seg) -> Bool {
        let n = points.count
        for i in 0..<segmentCount {
            let pa = points[i], pb = points[i + 1 < n ? i + 1 : 0]
            if Seg(pa, pb).intersects(s) { return true }
        }
        return false
    }

    /// Where this chain and `chain` cross (and, unless excluded, where they run together or touch)
    public func intersect(_ chain: LineChain, excludeColinearAndTouching: Bool = false) -> [Intersection] {
        let ours = segmentCount, theirs = chain.segmentCount
        if ours == 0 || theirs == 0 { return [] }
        let other = chain.bbox
        let theirSegs = (0..<theirs).map(chain.segment)
        // their segments by their leftmost x (stable, where KiCad's sort leaves ties as they fall)
        let sorted = theirSegs.indices.map { i -> (minX: Int, maxX: Int, minY: Int, maxY: Int, i: Int) in
            let s = theirSegs[i]
            return (min(s.a.x, s.b.x), max(s.a.x, s.b.x), min(s.a.y, s.b.y), max(s.a.y, s.b.y), i)
        }.enumerated().sorted { $0.element.minX != $1.element.minX ? $0.element.minX < $1.element.minX : $0.offset < $1.offset }.map(\.element)
        var out: [Intersection] = []
        let n = points.count
        for s1 in 0..<ours {
            let a1 = points[s1], b1 = points[s1 + 1 < n ? s1 + 1 : 0]
            let ominX = min(a1.x, b1.x), omaxX = max(a1.x, b1.x), ominY = min(a1.y, b1.y), omaxY = max(a1.y, b1.y)
            if omaxX < other.minX || ominX > other.maxX || omaxY < other.minY || ominY > other.maxY { continue }
            let a = Seg(a1, b1, index: s1)
            for e in sorted {
                if e.minX > omaxX { break }
                if e.maxX < ominX || e.maxY < ominY || e.minY > omaxY { continue }
                let b = theirSegs[e.i]
                var x = Intersection(p: .zero)
                x.indexOur = s1
                x.indexTheir = e.i
                x.valid = true
                let p = a.intersect(b)
                if !excludeColinearAndTouching && a.collinear(b) {
                    // (one record, as KiCad's: what one end sets stays set for the next)
                    if a.contains(b.a) {
                        x.p = b.a
                        x.isCornerTheir = true
                        out.append(x)
                    }
                    if a.contains(b.b) {
                        x.p = b.b
                        x.indexTheir += 1
                        x.isCornerTheir = true
                        out.append(x)
                    }
                    if b.contains(a.a) {
                        x.p = a.a
                        x.isCornerOur = true
                        out.append(x)
                    }
                    if b.contains(a.b) {
                        x.p = a.b
                        x.indexOur += 1
                        x.isCornerOur = true
                        out.append(x)
                    }
                } else if let p {
                    x.p = p
                    if p == a.a { x.isCornerOur = true }
                    if p == a.b {
                        x.isCornerOur = true
                        x.indexOur += 1
                    }
                    if p == b.a { x.isCornerTheir = true }
                    if p == b.b {
                        x.isCornerTheir = true
                        x.indexTheir += 1
                    }
                    out.append(x)
                }
            }
        }
        return out
    }

    public func intersects(_ chain: LineChain) -> Bool { !intersect(chain).isEmpty }

    /// Where the chain first crosses itself
    public func selfIntersecting() -> Intersection? {
        let segs = segmentCount, n = points.count
        if segs < 2 { return nil }
        func end(_ i: Int) -> Int { i + 1 < n ? i + 1 : 0 }
        for s1 in 0..<segs {
            let a1 = points[s1], b1 = points[end(s1)]
            let minX1 = min(a1.x, b1.x) - 2, maxX1 = max(a1.x, b1.x) + 2, minY1 = min(a1.y, b1.y) - 2, maxY1 = max(a1.y, b1.y) + 2
            for s2 in (s1 + 1)..<max(s1 + 1, segs) {
                let a2 = points[s2], b2 = points[end(s2)]
                if maxX1 < min(a2.x, b2.x) || max(a2.x, b2.x) < minX1 { continue }
                if maxY1 < min(a2.y, b2.y) || max(a2.y, b2.y) < minY1 { continue }
                let seg1 = Seg(a1, b1, index: s1)
                var x = Intersection(p: .zero)
                x.indexOur = s1
                x.indexTheir = s2
                if s1 + 1 != s2 && seg1.contains(a2) {
                    x.p = a2
                    return x
                } else if seg1.contains(b2) && !(isClosed && s1 == 0 && s2 == segs - 1) {
                    x.p = b2
                    return x
                } else if let p = seg1.intersect(Seg(a2, b2, index: s2), ignoreEndpoints: true) {
                    x.p = p
                    return x
                }
            }
        }
        return nil
    }

    // MARK: - Simplifying

    /// KiCad's Simplify: removes points that lie within `tolerance` of the line through their neighbours
    public mutating func simplify(_ tolerance: Int = 0) {
        let n = points.count
        if n < 3 { return }
        var out: [IPoint] = []
        var start = 0
        while start < n {
            out.append(points[start])
            if !isClosed && start == n - 2 { break }
            var end = (start + 2) % n
            var canSimplify = true
            while canSimplify && end != start && (end > start || isClosed) {
                var test = (start + 1) % n
                while test != end {
                    if !KiMath.testSegmentHit(points[test], points[start], points[end], tolerance) {
                        canSimplify = false
                        break
                    }
                    test = (test + 1) % n
                }
                if canSimplify { end = (end + 1) % n }
            }
            if end == (start + 2) % n {
                start += 1
            } else {
                let newStart = (end + n - 1) % n
                if newStart <= start { break }
                start = newStart
            }
        }
        if out.count == 1 { out.append(points[n - 1]) }
        if !isClosed && points[n - 1] != out[out.count - 1] { out.append(points[n - 1]) }
        points = out
    }

    /// KiCad's Simplify2, the router's: duplicate points removed, and (unless asked not to) points along a straight
    /// line
    @discardableResult
    public mutating func simplify2(removeColinear: Bool = true) -> LineChain {
        if points.count < 3 { return self }
        if points.count == 3 {
            if points[0] == points[1] { remove(1) }
            return self
        }
        var unique: [IPoint] = []
        var i = 0
        let n0 = points.count
        while i < n0 {
            var j = i + 1
            while j < n0 && points[i] == points[j] { j += 1 }
            unique.append(points[i])
            i = j
        }
        let np = unique.count
        var out: [IPoint] = []
        i = 0
        while i < np - 2 {
            let p0 = unique[i]
            var n = i
            if removeColinear {
                while n < np - 2 && (Seg(p0, unique[n + 2]).lineDistance(unique[n + 1]) <= 1
                                     || Seg(p0, unique[n + 2]).collinear(Seg(p0, unique[n + 1]))) {
                    n += 1
                }
            }
            out.append(p0)
            if n > i { i = n }
            if n == np - 2 {
                out.append(unique[np - 1])
                points = out
                return self
            }
            i += 1
        }
        if np > 1 { out.append(unique[np - 2]) }
        out.append(unique[np - 1])
        points = out
        return self
    }

    /// KiCad's RemoveDuplicatePoints: points repeated one after the other made one (but two points always kept)
    public mutating func removeDuplicatePoints() {
        if points.count < 3 { return }
        if points.count == 3 {
            if points[0] == points[1] { remove(1) }
            return
        }
        var unique: [IPoint] = []
        var i = 0
        while i < points.count {
            var j = i + 1
            while j < points.count && points[i] == points[j] { j += 1 }
            unique.append(points[i])
            i = j
        }
        points = unique
    }

    /// Whether the chain's points make the same path as `other`'s
    public func compareGeometry(_ other: LineChain) -> Bool {
        if points.count != other.points.count { return false }
        return points == other.points
    }
}
