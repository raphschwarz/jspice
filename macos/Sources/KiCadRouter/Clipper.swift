// Ported from Clipper2 2.0.1 (the version KiCad 10.0.7 ships, thirdparty/clipper2), as KiCad compiles it (USINGZ):
// Clipper2Lib/include/clipper2/clipper.core.h, clipper.h (the helpers used here) and clipper.engine.h (the tree).
// Clipper2: Copyright Angus Johnson 2010-2026, https://www.angusj.com.
// Boost Software License 1.0, https://www.boost.org/LICENSE_1_0.txt (see KICAD-NOTICE.md).

import Foundation

/// KiCad's polygon clipper, Clipper2: boolean operations on polygons (and open paths), offsets, and the helpers they
/// share, on 64-bit integer coordinates. Ported so that it answers as KiCad's copy answers, to the point: the same
/// paths, starting at the same point, in the same order, with the same z values (KiCad's points carry one, which it
/// uses to find its arcs again after clipping)
public enum Clipper {
    /// A point: whole units, and a z value that goes with the point through clipping (two points are equal when their
    /// x and y are; z is not compared)
    public struct Point64: Hashable, Sendable, CustomStringConvertible {
        public var x: Int
        public var y: Int
        public var z: Int

        @inline(__always)
        public init(_ x: Int, _ y: Int, _ z: Int = 0) { self.x = x; self.y = y; self.z = z }

        /// From doubles, each rounded to the nearest (halves away from zero), as Clipper2 makes its points
        @inline(__always)
        public init(_ x: Double, _ y: Double, _ z: Int = 0) {
            self.x = Clipper.toInt(x.rounded())
            self.y = Clipper.toInt(y.rounded())
            self.z = z
        }

        @inline(__always)
        init(_ p: PointD) { self.init(p.x, p.y, p.z) }

        public static func == (a: Point64, b: Point64) -> Bool { a.x == b.x && a.y == b.y }
        public func hash(into hasher: inout Hasher) { hasher.combine(x); hasher.combine(y) }
        public var description: String { "(\(x), \(y), \(z))" }
    }

    /// A point in doubles, as the offsetter works some of its points out before they are rounded
    public struct PointD: Sendable {
        public var x: Double
        public var y: Double
        public var z: Int

        @inline(__always)
        public init(_ x: Double, _ y: Double, _ z: Int = 0) { self.x = x; self.y = y; self.z = z }

        @inline(__always)
        init(_ p: Point64) { self.init(Double(p.x), Double(p.y), p.z) }
    }

    public typealias Path64 = [Point64]
    public typealias Paths64 = [Path64]
    public typealias PathD = [PointD]

    /// Which regions count as inside: by the parity of the paths around them, or by their winding number (any, more
    /// than none, less than none)
    public enum FillRule: Int, Sendable { case evenOdd, nonZero, positive, negative }

    public enum PointInPolygonResult: Int, Sendable { case isOn, isInside, isOutside }

    /// Called for each point Clipper2 makes where two edges meet (each edge's bottom and top, then the point, whose
    /// z it may set)
    public typealias ZCallback64 = (_ e1bot: Point64, _ e1top: Point64, _ e2bot: Point64, _ e2top: Point64,
                                    _ pt: inout Point64) -> Void

    /// A box, its edges inclusive (top is the smaller y)
    public struct Rect64: Equatable, Sendable {
        public var left, top, right, bottom: Int

        public init(_ left: Int, _ top: Int, _ right: Int, _ bottom: Int) {
            (self.left, self.top, self.right, self.bottom) = (left, top, right, bottom)
        }

        /// The empty box of nothing yet (all zero), as Clipper2's default Rect64
        public init() { self.init(0, 0, 0, 0) }

        public var isEmpty: Bool { bottom <= top || right <= left }
        public var midPoint: Point64 { Point64((left + right) / 2, (top + bottom) / 2) }

        public var asPath: Path64 { [Point64(left, top), Point64(right, top), Point64(right, bottom), Point64(left, bottom)] }

        public func contains(_ rec: Rect64) -> Bool {
            rec.left >= left && rec.right <= right && rec.top >= top && rec.bottom <= bottom
        }
    }

    static let maxDouble = Double.greatestFiniteMagnitude

    // MARK: - Numbers as C++ makes them

    /// A double made an int as C++ makes it on x86-64: cut towards zero, and what an int cannot hold (or not a number)
    /// the smallest int
    @inline(__always)
    static func toInt(_ v: Double) -> Int {
        v >= -9.223372036854775808e18 && v < 9.223372036854775808e18 ? Int(v) : Int.min
    }

    /// The same for a 32-bit int (what it cannot hold the smallest 32-bit int)
    @inline(__always)
    static func toInt32(_ v: Double) -> Int { v > -2147483649.0 && v < 2147483648.0 ? Int(v) : Int(Int32.min) }

    /// nearbyint: to the nearest, halves to even
    @inline(__always)
    static func nearbyInt(_ v: Double) -> Int { toInt(v.rounded(.toNearestOrEven)) }

    @inline(__always)
    static func sqr(_ v: Double) -> Double { v * v }

    // MARK: - Products and turns

    /// Which way the path pt1, pt2, pt3 turns: 1, -1, or 0 when straight (worked out in 128 bits, exactly)
    static func crossProductSign(_ pt1: Point64, _ pt2: Point64, _ pt3: Point64) -> Int {
        let a = pt2.x - pt1.x, b = pt3.y - pt2.y, c = pt2.y - pt1.y, d = pt3.x - pt2.x
        let ab = a.multipliedFullWidth(by: b), cd = c.multipliedFullWidth(by: d)
        if ab.high != cd.high { return ab.high > cd.high ? 1 : -1 }
        if ab.low != cd.low { return ab.low > cd.low ? 1 : -1 }
        return 0
    }

    /// Whether a * b == c * d, exactly
    @inline(__always)
    static func productsAreEqual(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> Bool {
        let ab = a.multipliedFullWidth(by: b), cd = c.multipliedFullWidth(by: d)
        return ab.high == cd.high && ab.low == cd.low
    }

    @inline(__always)
    static func isCollinear(_ pt1: Point64, _ sharedPt: Point64, _ pt2: Point64) -> Bool {
        productsAreEqual(sharedPt.x - pt1.x, pt2.y - sharedPt.y, sharedPt.y - pt1.y, pt2.x - sharedPt.x)
    }

    @inline(__always)
    static func crossProduct(_ vec1: PointD, _ vec2: PointD) -> Double { vec1.y * vec2.x - vec2.y * vec1.x }

    @inline(__always)
    static func dotProduct(_ pt1: Point64, _ pt2: Point64, _ pt3: Point64) -> Double {
        Double(pt2.x - pt1.x) * Double(pt3.x - pt2.x) + Double(pt2.y - pt1.y) * Double(pt3.y - pt2.y)
    }

    @inline(__always)
    static func dotProduct(_ vec1: PointD, _ vec2: PointD) -> Double { vec1.x * vec2.x + vec1.y * vec2.y }

    /// The square of pt's distance from the line through line1 and line2 (none if they are the same point)
    static func perpendicDistFromLineSqrd(_ pt: Point64, _ line1: Point64, _ line2: Point64) -> Double {
        let a = Double(pt.x - line1.x), b = Double(pt.y - line1.y)
        let c = Double(line2.x - line1.x), d = Double(line2.y - line1.y)
        if c == 0 && d == 0 { return 0 }
        return sqr(a * d - c * b) / (c * c + d * d)
    }

    // MARK: - Areas and orientation

    /// A closed path's area, positive when it goes round counter-clockwise (y up), its terms summed in Clipper2's
    /// order
    public static func area(_ path: Path64) -> Double {
        let cnt = path.count
        if cnt < 3 { return 0 }
        var a = 0.0
        var it2 = cnt - 1
        let stop = cnt & 1 == 0 ? cnt : cnt - 1
        var it1 = 0
        while it1 != stop {
            a += Double(path[it2].y + path[it1].y) * Double(path[it2].x - path[it1].x)
            it2 = it1 + 1
            a += Double(path[it1].y + path[it2].y) * Double(path[it1].x - path[it2].x)
            it1 += 2
        }
        if cnt & 1 != 0 { a += Double(path[it2].y + path[it1].y) * Double(path[it2].x - path[it1].x) }
        return a * 0.5
    }

    public static func area(_ paths: Paths64) -> Double { paths.reduce(0.0) { $0 + area($1) } }

    public static func isPositive(_ poly: Path64) -> Bool { area(poly) >= 0 }

    // MARK: - Intersections

    /// Where the lines through two segments cross, held to the first segment (false when they are parallel)
    static func getLineIntersectPt(_ ln1a: Point64, _ ln1b: Point64, _ ln2a: Point64, _ ln2b: Point64,
                                   _ ip: inout Point64) -> Bool {
        let dx1 = Double(ln1b.x - ln1a.x), dy1 = Double(ln1b.y - ln1a.y)
        let dx2 = Double(ln2b.x - ln2a.x), dy2 = Double(ln2b.y - ln2a.y)
        let det = dy1 * dx2 - dy2 * dx1
        if det == 0 { return false }
        let t = (Double(ln1a.x - ln2a.x) * dy2 - Double(ln1a.y - ln2a.y) * dx2) / det
        if t <= 0 {
            ip = ln1a
        } else if t >= 1 {
            ip = ln1b
        } else {
            ip.x = toInt(Double(ln1a.x) + t * dx1)
            ip.y = toInt(Double(ln1a.y) + t * dy1)
            ip.z = 0
        }
        return true
    }

    /// The same in doubles
    static func getLineIntersectPt(_ ln1a: PointD, _ ln1b: PointD, _ ln2a: PointD, _ ln2b: PointD,
                                   _ ip: inout PointD) -> Bool {
        let dx1 = ln1b.x - ln1a.x, dy1 = ln1b.y - ln1a.y
        let dx2 = ln2b.x - ln2a.x, dy2 = ln2b.y - ln2a.y
        let det = dy1 * dx2 - dy2 * dx1
        if det == 0 { return false }
        let t = ((ln1a.x - ln2a.x) * dy2 - (ln1a.y - ln2a.y) * dx2) / det
        if t <= 0 {
            ip = ln1a
        } else if t >= 1 {
            ip = ln1b
        } else {
            ip.x = ln1a.x + t * dx1
            ip.y = ln1a.y + t * dy1
            ip.z = 0
        }
        return true
    }

    /// Whether two segments cross (touching at an end not counted)
    static func segmentsIntersect(_ seg1a: Point64, _ seg1b: Point64, _ seg2a: Point64, _ seg2b: Point64) -> Bool {
        let dy1 = Double(seg1b.y - seg1a.y), dx1 = Double(seg1b.x - seg1a.x)
        let dy2 = Double(seg2b.y - seg2a.y), dx2 = Double(seg2b.x - seg2a.x)
        let cp = dy1 * dx2 - dy2 * dx1
        if cp == 0 { return false }  // parallel
        var t = Double(seg1a.x - seg2a.x) * dy2 - Double(seg1a.y - seg2a.y) * dx2
        if t == 0 { return false }
        if t > 0 {
            if cp < 0 || t >= cp { return false }
        } else if cp > 0 || t <= cp {
            return false
        }
        t = Double(seg1a.x - seg2a.x) * dy1 - Double(seg1a.y - seg2a.y) * dx1
        if t == 0 { return false }
        return t > 0 ? cp > 0 && t < cp : cp < 0 && t > cp
    }

    static func getClosestPointOnSegment(_ offPt: Point64, _ seg1: Point64, _ seg2: Point64) -> Point64 {
        if seg1.x == seg2.x && seg1.y == seg2.y { return seg1 }
        let dx = Double(seg2.x - seg1.x), dy = Double(seg2.y - seg1.y)
        var q = (Double(offPt.x - seg1.x) * dx + Double(offPt.y - seg1.y) * dy) / (sqr(dx) + sqr(dy))
        if q < 0 { q = 0 } else if q > 1 { q = 1 }
        return Point64(seg1.x + nearbyInt(q * dx), seg1.y + nearbyInt(q * dy))
    }

    // MARK: - Point in polygon

    /// Whether a point is inside a polygon, outside it, or on its edge
    public static func pointInPolygon(_ pt: Point64, _ polygon: Path64) -> PointInPolygonResult {
        if polygon.count < 3 { return .isOutside }
        var val = 0
        let cbegin = 0
        var cend = polygon.count, first = 0
        while first != cend && polygon[first].y == pt.y { first += 1 }
        if first == cend { return .isOutside }  // not a proper polygon

        var isAbove = polygon[first].y < pt.y
        let startingAbove = isAbove
        var curr = first + 1, prev = 0
        while true {
            if curr == cend {
                if cend == first || first == cbegin { break }
                cend = first
                curr = cbegin
            }
            if isAbove {
                while curr != cend && polygon[curr].y < pt.y { curr += 1 }
                if curr == cend { continue }
            } else {
                while curr != cend && polygon[curr].y > pt.y { curr += 1 }
                if curr == cend { continue }
            }
            prev = curr == cbegin ? polygon.count - 1 : curr - 1
            let c = polygon[curr], p = polygon[prev]
            if c.y == pt.y {
                if c.x == pt.x || (c.y == p.y && ((pt.x < p.x) != (pt.x < c.x))) { return .isOn }
                curr += 1
                if curr == first { break }
                continue
            }
            if pt.x < c.x && pt.x < p.x {
                // only edges crossing on the left count
            } else if pt.x > p.x && pt.x > c.x {
                val = 1 - val
            } else {
                let d = crossProductSign(p, c, pt)
                if d == 0 { return .isOn }
                if (d < 0) == isAbove { val = 1 - val }
            }
            isAbove = !isAbove
            curr += 1
        }

        if isAbove != startingAbove {
            cend = polygon.count
            if curr == cend { curr = cbegin }
            prev = curr == cbegin ? cend - 1 : curr - 1
            let d = crossProductSign(polygon[prev], polygon[curr], pt)
            if d == 0 { return .isOn }
            if (d < 0) == isAbove { val = 1 - val }
        }
        return val == 0 ? .isOutside : .isInside
    }

    /// Whether path2 holds path1 (the two not crossing, but for the small crossings rounding makes)
    public static func path2ContainsPath1(_ path1: Path64, _ path2: Path64) -> Bool {
        var pip = PointInPolygonResult.isOn
        for pt in path1 {
            switch pointInPolygon(pt, path2) {
            case .isOutside:
                if pip == .isOutside { return false }
                pip = .isOutside
            case .isInside:
                if pip == .isInside { return true }
                pip = .isInside
            case .isOn:
                break
            }
        }
        if pip != .isInside { return false }
        // most likely inside, but its box's middle is asked too
        return pointInPolygon(bounds(path1).midPoint, path2) == .isInside
    }

    static func bounds(_ path: Path64) -> Rect64 {
        var r = Rect64(Int.max, Int.max, Int.min, Int.min)
        for p in path {
            if p.x < r.left { r.left = p.x }
            if p.x > r.right { r.right = p.x }
            if p.y < r.top { r.top = p.y }
            if p.y > r.bottom { r.bottom = p.y }
        }
        return r
    }

    // MARK: - Paths

    /// Repeated points dropped (and, for a closed path, last points that are the first again)
    static func stripDuplicates(_ path: inout Path64, isClosedPath: Bool) {
        if !path.isEmpty {
            var kept = 1
            for i in 1..<path.count where path[i] != path[kept - 1] {
                path[kept] = path[i]
                kept += 1
            }
            path.removeSubrange(kept...)
        }
        if isClosedPath {
            while path.count > 1 && path[path.count - 1] == path[0] { path.removeLast() }
        }
    }

    /// A path's points that stand out from the line of their neighbours by more than `epsilon`: the others removed,
    /// the least out of line first
    public static func simplifyPath(_ path: Path64, _ epsilon: Double, isClosedPath: Bool = true) -> Path64 {
        let len = path.count, high = len - 1
        let epsSqr = sqr(epsilon)
        if len < 4 { return path }

        var flags = [Bool](repeating: false, count: len)
        var distSqr = [Double](repeating: 0, count: len)
        var prior = high, curr = 0, start = 0, next = 0, prior2 = 0
        if isClosedPath {
            distSqr[0] = perpendicDistFromLineSqrd(path[0], path[high], path[1])
            distSqr[high] = perpendicDistFromLineSqrd(path[high], path[0], path[high - 1])
        } else {
            distSqr[0] = maxDouble
            distSqr[high] = maxDouble
        }
        for i in 1..<high { distSqr[i] = perpendicDistFromLineSqrd(path[i], path[i - 1], path[i + 1]) }

        while true {
            if distSqr[curr] > epsSqr {
                start = curr
                repeat {
                    curr = nextUnflagged(curr, high, flags)
                } while curr != start && distSqr[curr] > epsSqr
                if curr == start { break }
            }

            prior = priorUnflagged(curr, high, flags)
            next = nextUnflagged(curr, high, flags)
            if next == prior { break }

            // the smaller of neighbouring distances goes
            if distSqr[next] < distSqr[curr] {
                prior2 = prior
                prior = curr
                curr = next
                next = nextUnflagged(next, high, flags)
            } else {
                prior2 = priorUnflagged(prior, high, flags)
            }

            flags[curr] = true
            curr = next
            next = nextUnflagged(next, high, flags)

            if isClosedPath || (curr != high && curr != 0) {
                distSqr[curr] = perpendicDistFromLineSqrd(path[curr], path[prior], path[next])
            }
            if isClosedPath || (prior != 0 && prior != high) {
                distSqr[prior] = perpendicDistFromLineSqrd(path[prior], path[prior2], path[curr])
            }
        }
        var result = Path64()
        result.reserveCapacity(len)
        for i in 0..<len where !flags[i] { result.append(path[i]) }
        return result
    }

    public static func simplifyPaths(_ paths: Paths64, _ epsilon: Double, isClosedPath: Bool = true) -> Paths64 {
        paths.map { simplifyPath($0, epsilon, isClosedPath: isClosedPath) }
    }

    private static func nextUnflagged(_ current: Int, _ high: Int, _ flags: [Bool]) -> Int {
        var current = current + 1
        while current <= high && flags[current] { current += 1 }
        if current <= high { return current }
        current = 0
        while flags[current] { current += 1 }
        return current
    }

    private static func priorUnflagged(_ current: Int, _ high: Int, _ flags: [Bool]) -> Int {
        var current = current == 0 ? high : current - 1
        while current > 0 && flags[current] { current -= 1 }
        if !flags[current] { return current }
        current = high
        while flags[current] { current -= 1 }
        return current
    }

    /// A path simplified by Ramer, Douglas and Peucker's method: the points within `epsilon` of the line between the
    /// ones kept removed
    public static func ramerDouglasPeucker(_ path: Path64, _ epsilon: Double) -> Path64 {
        let len = path.count
        if len < 5 { return path }
        var flags = [Bool](repeating: false, count: len)
        flags[0] = true
        flags[len - 1] = true
        rdp(path, 0, len - 1, sqr(epsilon), &flags)
        var result = Path64()
        result.reserveCapacity(len)
        for i in 0..<len where flags[i] { result.append(path[i]) }
        return result
    }

    private static func rdp(_ path: Path64, _ begin: Int, _ end: Int, _ epsSqrd: Double, _ flags: inout [Bool]) {
        var end = end
        var idx = 0
        var maxD = 0.0
        while end > begin && path[begin] == path[end] {
            flags[end] = false
            end -= 1
        }
        var i = begin + 1
        while i < end {
            let d = perpendicDistFromLineSqrd(path[i], path[begin], path[end])
            if d > maxD {
                maxD = d
                idx = i
            }
            i += 1
        }
        if maxD <= epsSqrd { return }
        flags[idx] = true
        if idx > begin + 1 { rdp(path, begin, idx, epsSqrd, &flags) }
        if idx < end - 1 { rdp(path, idx, end, epsSqrd, &flags) }
    }

    /// A circle or an ellipse round `center`, as Clipper2 draws one (a point's offset with round joins)
    static func ellipse(_ center: Point64, _ radiusX: Double, _ radiusY: Double = 0, _ steps: Int = 0) -> Path64 {
        if radiusX <= 0 { return [] }
        let radiusY = radiusY <= 0 ? radiusX : radiusY
        var steps = steps
        if steps <= 2 { steps = toInt(Double.pi * ((radiusX + radiusY) / 2).squareRoot()) }
        let si = sin(2 * Double.pi / Double(steps)), co = cos(2 * Double.pi / Double(steps))
        var dx = co, dy = si
        var result = Path64()
        result.reserveCapacity(steps)
        result.append(Point64(Double(center.x) + radiusX, Double(center.y)))
        for _ in stride(from: 1, to: steps, by: 1) {
            result.append(Point64(Double(center.x) + radiusX * dx, Double(center.y) + radiusY * dy))
            let x = dx * co - dy * si
            dy = dy * co + dx * si
            dx = x
        }
        return result
    }

    // MARK: - Sorting as libstdc++ sorts

    /// std::sort as libstdc++ does it (an introsort, finished by insertion sorts), so that elements that compare equal
    /// end up in the order KiCad's (built with GCC) leaves them in
    static func introSort<T>(_ a: inout [T], _ less: (T, T) -> Bool) {
        let n = a.count
        if n == 0 { return }
        introsortLoop(&a, 0, n, 2 * (Int.bitWidth - 1 - n.leadingZeroBitCount), less)
        if n > 16 {
            insertionSort(&a, 0, 16, less)
            for i in 16..<n { unguardedLinearInsert(&a, i, less) }
        } else {
            insertionSort(&a, 0, n, less)
        }
    }

    private static func introsortLoop<T>(_ a: inout [T], _ first: Int, _ last: Int, _ depthLimit: Int,
                                         _ less: (T, T) -> Bool) {
        var last = last, depthLimit = depthLimit
        while last - first > 16 {
            if depthLimit == 0 {
                heapSort(&a, first, last, less)
                return
            }
            depthLimit -= 1
            // the median of the second, middle and last moved to the first, and the rest partitioned round it
            let mid = first + (last - first) / 2
            moveMedianToFirst(&a, first, first + 1, mid, last - 1, less)
            var lo = first + 1, hi = last
            while true {
                while less(a[lo], a[first]) { lo += 1 }
                hi -= 1
                while less(a[first], a[hi]) { hi -= 1 }
                if !(lo < hi) { break }
                a.swapAt(lo, hi)
                lo += 1
            }
            introsortLoop(&a, lo, last, depthLimit, less)
            last = lo
        }
    }

    private static func moveMedianToFirst<T>(_ a: inout [T], _ result: Int, _ x: Int, _ y: Int, _ z: Int,
                                             _ less: (T, T) -> Bool) {
        if less(a[x], a[y]) {
            if less(a[y], a[z]) { a.swapAt(result, y) }
            else if less(a[x], a[z]) { a.swapAt(result, z) }
            else { a.swapAt(result, x) }
        } else if less(a[x], a[z]) {
            a.swapAt(result, x)
        } else if less(a[y], a[z]) {
            a.swapAt(result, z)
        } else {
            a.swapAt(result, y)
        }
    }

    private static func insertionSort<T>(_ a: inout [T], _ first: Int, _ last: Int, _ less: (T, T) -> Bool) {
        if first == last { return }
        var i = first + 1
        while i != last {
            if less(a[i], a[first]) {
                let v = a[i]
                var j = i
                while j > first {
                    a[j] = a[j - 1]
                    j -= 1
                }
                a[first] = v
            } else {
                unguardedLinearInsert(&a, i, less)
            }
            i += 1
        }
    }

    private static func unguardedLinearInsert<T>(_ a: inout [T], _ last: Int, _ less: (T, T) -> Bool) {
        let v = a[last]
        var last = last, next = last - 1
        while less(v, a[next]) {
            a[last] = a[next]
            last = next
            next -= 1
        }
        a[last] = v
    }

    /// std::partial_sort over the whole range as libstdc++ does it (the heap sort its std::sort falls back on)
    static func heapSort<T>(_ a: inout [T], _ first: Int, _ last: Int, _ less: (T, T) -> Bool) {
        let len = last - first
        if len >= 2 {
            var parent = (len - 2) / 2
            while true {
                adjustHeap(&a, first, parent, len, a[first + parent], less)
                if parent == 0 { break }
                parent -= 1
            }
        }
        var end = last
        while end - first > 1 {
            end -= 1
            let v = a[end]
            a[end] = a[first]
            adjustHeap(&a, first, 0, end - first, v, less)
        }
    }

    private static func adjustHeap<T>(_ a: inout [T], _ first: Int, _ holeIndex: Int, _ len: Int, _ value: T,
                                      _ less: (T, T) -> Bool) {
        let topIndex = holeIndex
        var holeIndex = holeIndex, secondChild = holeIndex
        while secondChild < (len - 1) / 2 {
            secondChild = 2 * (secondChild + 1)
            if less(a[first + secondChild], a[first + secondChild - 1]) { secondChild -= 1 }
            a[first + holeIndex] = a[first + secondChild]
            holeIndex = secondChild
        }
        if len & 1 == 0 && secondChild == (len - 2) / 2 {
            secondChild = 2 * (secondChild + 1)
            a[first + holeIndex] = a[first + secondChild - 1]
            holeIndex = secondChild - 1
        }
        var parent = (holeIndex - 1) / 2
        while holeIndex > topIndex && less(a[first + parent], value) {
            a[first + holeIndex] = a[first + parent]
            holeIndex = parent
            parent = (holeIndex - 1) / 2
        }
        a[first + holeIndex] = value
    }

    /// A stable sort (a merge sort): equal elements keep their order, as with std::stable_sort
    static func stableSort<T>(_ a: inout [T], _ less: (T, T) -> Bool) {
        if a.count < 2 { return }
        var buffer = a
        mergeSort(&a, &buffer, 0, a.count, less)
    }

    private static func mergeSort<T>(_ a: inout [T], _ buffer: inout [T], _ lo: Int, _ hi: Int, _ less: (T, T) -> Bool) {
        if hi - lo < 2 { return }
        let mid = (lo + hi) / 2
        mergeSort(&a, &buffer, lo, mid, less)
        mergeSort(&a, &buffer, mid, hi, less)
        var i = lo, j = mid, k = lo
        while i < mid && j < hi {
            // (one from the right goes first only when it is less, so that equal elements keep their order)
            if less(a[j], a[i]) {
                buffer[k] = a[j]
                j += 1
            } else {
                buffer[k] = a[i]
                i += 1
            }
            k += 1
        }
        while i < mid { buffer[k] = a[i]; i += 1; k += 1 }
        while j < hi { buffer[k] = a[j]; j += 1; k += 1 }
        for m in lo..<hi { a[m] = buffer[m] }
    }

    // MARK: - Trees

    /// A tree of the closed paths a clipping makes: outlines, the holes in them, the outlines in the holes and so on,
    /// in the order Clipper2 finds them. The tree itself (its root) has no polygon of its own
    public final class PolyPath64 {
        public private(set) weak var parent: PolyPath64?
        public private(set) var children: [PolyPath64] = []
        public let polygon: Path64

        public init() { polygon = [] }

        init(parent: PolyPath64, polygon: Path64) {
            self.parent = parent
            self.polygon = polygon
        }

        /// How deep in the tree: its root 0, outlines 1, holes 2, ...
        public var level: Int {
            var result = 0
            var p = parent
            while let q = p {
                result += 1
                p = q.parent
            }
            return result
        }

        public var isHole: Bool {
            let lvl = level
            return lvl != 0 && lvl & 1 == 0
        }

        public var count: Int { children.count }

        @discardableResult
        func addChild(_ path: Path64) -> PolyPath64 {
            let child = PolyPath64(parent: self, polygon: path)
            children.append(child)
            return child
        }

        public func clear() { children.removeAll() }

        /// Its polygon's area and all its children's (holes' negative)
        public var area: Double { children.reduce(Clipper.area(polygon)) { $0 + $1.area } }
    }

    public typealias PolyTree64 = PolyPath64
}
