// Ported from KiCad 10.0.7: libs/kimath/include/math/vector2d.h, libs/kimath/src/math/util.cpp (rescale),
// libs/kimath/include/geometry/seg.h and libs/kimath/src/geometry/seg.cpp, libs/kimath/src/trigo.cpp
// (TestSegmentHit), libs/kimath/include/math/box2.h, libs/kimath/include/geometry/direction45.h and
// libs/kimath/src/geometry/direction_45.cpp.
// Copyright (C) 2013-2015 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// The router's geometry is KiCad's: whole nanometres, worked out with KiCad's own rounding (its rescale, isqrt and
/// KiROUND), so that a trace placed here is the trace KiCad's router places, to the nanometre
public enum KiMath {
    /// KiCad's rescale for 64-bit values: a * b / c, rounded to the nearest, the product kept in 128 bits (and a
    /// quotient too big for 64 bits cut to its low 64, as KiCad's conversion from its 128-bit one cuts it)
    public static func rescale(_ a: Int, _ b: Int, _ c: Int) -> Int {
        let product = a.multipliedFullWidth(by: b)
        let negative = (product.high < 0) != (c < 0)
        let r = negative ? -(c / 2) : c / 2
        // the product plus r, in 128 bits
        let rLow = UInt(bitPattern: r)
        let rHigh: Int = r < 0 ? -1 : 0
        let (low, carry) = product.low.addingReportingOverflow(rLow)
        let high = product.high &+ rHigh &+ (carry ? 1 : 0)
        if (high == 0 && low >> 63 == 0) || (high == -1 && low >> 63 == 1) {
            return Int(bitPattern: low).dividedReportingOverflow(by: c).partialValue
        }
        // a 128-bit numerator: its magnitude divided, the quotient's low 64 bits signed
        var (mh, ml) = (UInt(bitPattern: high), low)
        if high < 0 {
            ml = ~ml &+ 1
            mh = ~mh &+ (ml == 0 ? 1 : 0)
        }
        let d = c.magnitude
        let ql = d.dividingFullWidth((high: mh % d, low: ml)).quotient
        let q = Int(bitPattern: ql)
        return (high < 0) != (c < 0) ? 0 &- q : q
    }

    /// KiCad's integer square root (seg.cpp's isqrt): the largest r with r * r <= x
    public static func isqrt(_ x: Int) -> Int {
        let sqrtMax = 3_037_000_499
        if x < 0 { return sqrtMax }
        var r = Int(Double(x).squareRoot())
        while r < sqrtMax && r * r < x { r += 1 }
        while r > sqrtMax || r * r > x { r -= 1 }
        return r
    }

    /// KiCad's KiROUND: to the nearest, halves away from zero (what is not a number, or too big for 64 bits, at the
    /// end of the range an int holds, as KiROUND clamps it)
    @inline(__always)
    public static func round(_ v: Double) -> Int {
        guard v.isFinite && abs(v) < 9.2e18 else { return v > 0 ? Int(Int32.max) : Int(Int32.min) }
        return Int(v.rounded())
    }

    /// A double made an int as C++ makes it on x86-64: cut towards zero, and what an int cannot hold (or not a
    /// number) the smallest int
    @inline(__always)
    public static func cInt(_ v: Double) -> Int {
        guard v.isFinite, v > Double(Int32.min) - 1, v < Double(Int32.max) + 1 else { return Int(Int32.min) }
        return Int(v)
    }

    @inline(__always)
    public static func sign(_ v: Int) -> Int { v > 0 ? 1 : v < 0 ? -1 : 0 }

    /// KiCad's TestSegmentHit: whether `p` is within `dist` of the segment from `start` to `end`
    public static func testSegmentHit(_ p: IPoint, _ start: IPoint, _ end: IPoint, _ dist: Int) -> Bool {
        var (xmin, xmax, ymin, ymax) = (start.x, end.x, start.y, end.y)
        let delta = start - p
        if xmax < xmin { swap(&xmax, &xmin) }
        if ymax < ymin { swap(&ymax, &ymin) }
        if ymin - p.y > dist || p.y - ymax > dist { return false }
        if xmin - p.x > dist || p.x - xmax > dist { return false }
        if start.x == end.x && p.y > ymin && p.y < ymax { return abs(delta.x) <= dist }
        if start.y == end.y && p.x > xmin && p.x < xmax { return abs(delta.y) <= dist }
        return Seg(start, end).squaredDistance(p) < (dist + 1) * (dist + 1)
    }
}

/// A point or vector in whole nanometres (KiCad's VECTOR2I)
public struct IPoint: Hashable, Sendable, CustomStringConvertible {
    public var x: Int
    public var y: Int

    @inline(__always)
    public init(_ x: Int, _ y: Int) { self.x = x; self.y = y }

    public static let zero = IPoint(0, 0)

    public var description: String { "(\(x), \(y))" }

    @inline(__always) public static func + (a: IPoint, b: IPoint) -> IPoint { IPoint(a.x + b.x, a.y + b.y) }
    @inline(__always) public static func - (a: IPoint, b: IPoint) -> IPoint { IPoint(a.x - b.x, a.y - b.y) }
    @inline(__always) public static prefix func - (a: IPoint) -> IPoint { IPoint(-a.x, -a.y) }
    @inline(__always) public static func * (a: IPoint, k: Int) -> IPoint { IPoint(a.x * k, a.y * k) }
    @inline(__always) public static func += (a: inout IPoint, b: IPoint) { a = a + b }
    @inline(__always) public static func -= (a: inout IPoint, b: IPoint) { a = a - b }

    /// Divided, each coordinate rounded as KiCad's VECTOR2I / double rounds it
    public func divided(by k: Double) -> IPoint { IPoint(KiMath.round(Double(x) / k), KiMath.round(Double(y) / k)) }

    @inline(__always) public var squaredNorm: Int { x * x + y * y }

    /// KiCad's EuclideanNorm: exact on the axes and diagonals, else the rounded hypotenuse
    public var norm: Int {
        if abs(x) == abs(y) { return KiMath.round(Double(abs(x)) * 2.0.squareRoot()) }
        if x == 0 { return abs(y) }
        if y == 0 { return abs(x) }
        return KiMath.round(hypot(Double(x), Double(y)))
    }

    @inline(__always) public func dot(_ b: IPoint) -> Int { x * b.x + y * b.y }
    @inline(__always) public func cross(_ b: IPoint) -> Int { x * b.y - y * b.x }
    @inline(__always) public var perpendicular: IPoint { IPoint(-y, x) }
    @inline(__always) public func squaredDistance(_ b: IPoint) -> Int { (self - b).squaredNorm }

    /// The vector of the same direction, `length` long (KiCad's Resize)
    public func resized(_ length: Int) -> IPoint {
        if x == 0 && y == 0 { return .zero }
        var nx: Double, ny: Double
        if abs(x) == abs(y) {
            nx = Double(abs(length)) * 0.5.squareRoot()
            ny = nx
        } else {
            // (64-bit squares, wrapping as KiCad's do where they overflow)
            let xsq = x &* x, ysq = y &* y
            let lsq = xsq &+ ysq
            let nlsq = length &* length
            nx = Double(KiMath.rescale(nlsq, xsq, lsq)).squareRoot()
            ny = Double(KiMath.rescale(nlsq, ysq, lsq)).squareRoot()
        }
        let s = KiMath.sign(length)
        return IPoint((x < 0 ? -KiMath.round(nx) : KiMath.round(nx)) * s, (y < 0 ? -KiMath.round(ny) : KiMath.round(ny)) * s)
    }

    /// KiCad's VECTOR2 ordering: by x, then y
    public static func < (a: IPoint, b: IPoint) -> Bool { a.x != b.x ? a.x < b.x : a.y < b.y }
}

/// A box (KiCad's BOX2I, kept normalized), its edges inclusive
public struct IBox: Hashable, Sendable {
    public var minX, minY, maxX, maxY: Int

    public init(minX: Int, minY: Int, maxX: Int, maxY: Int) {
        (self.minX, self.minY, self.maxX, self.maxY) = (minX, minY, maxX, maxY)
    }

    public init(_ a: IPoint, _ b: IPoint) {
        self.init(minX: min(a.x, b.x), minY: min(a.y, b.y), maxX: max(a.x, b.x), maxY: max(a.y, b.y))
    }

    /// The box round `points` (KiCad's Compute)
    public init?(points: [IPoint]) {
        guard let first = points.first else { return nil }
        self.init(first, first)
        for p in points.dropFirst() { merge(p) }
    }

    public var width: Int { maxX - minX }
    public var height: Int { maxY - minY }
    public var center: IPoint { IPoint(minX + width / 2, minY + height / 2) }

    public mutating func merge(_ p: IPoint) {
        minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y)
    }

    public mutating func merge(_ b: IBox) {
        minX = min(minX, b.minX); minY = min(minY, b.minY); maxX = max(maxX, b.maxX); maxY = max(maxY, b.maxY)
    }

    public func inflated(_ d: Int) -> IBox { IBox(minX: minX - d, minY: minY - d, maxX: maxX + d, maxY: maxY + d) }

    public func contains(_ p: IPoint) -> Bool { p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY }

    public func intersects(_ b: IBox) -> Bool { minX <= b.maxX && b.minX <= maxX && minY <= b.maxY && b.minY <= maxY }

    /// The box both boxes cover (KiCad's BOX2::Intersect): an empty box at the origin when they do not overlap
    /// over some area
    public func intersection(_ b: IBox) -> IBox {
        let left = max(minX, b.minX), right = min(maxX, b.maxX)
        let top = max(minY, b.minY), bottom = min(maxY, b.maxY)
        if left < right && top < bottom { return IBox(minX: left, minY: top, maxX: right, maxY: bottom) }
        return IBox(minX: 0, minY: 0, maxX: 0, maxY: 0)
    }

    /// The largest box there is (KiCad's BOX2::SetMaximum: invertible, so not quite the lowest coordinate)
    public static let maximum = IBox(minX: -Int(Int32.max), minY: -Int(Int32.max), maxX: Int(Int32.max), maxY: Int(Int32.max))

    /// The point of the box nearest `p` (KiCad's BOX2::NearestPoint)
    public func nearestPoint(_ p: IPoint) -> IPoint { IPoint(min(max(p.x, minX), maxX), min(max(p.y, minY), maxY)) }

    /// Its corners, clockwise on screen from the top left (y down)
    public var corners: [IPoint] { [IPoint(minX, minY), IPoint(maxX, minY), IPoint(maxX, maxY), IPoint(minX, maxY)] }
}

/// A segment between two points (KiCad's SEG), with KiCad's exact integer intersection and distance arithmetic
public struct Seg: Hashable, Sendable, CustomStringConvertible {
    public var a: IPoint
    public var b: IPoint
    /// Its index in the line chain it came from (KiCad's m_index), -1 for none
    public var index: Int

    @inline(__always)
    public init(_ a: IPoint, _ b: IPoint, index: Int = -1) { self.a = a; self.b = b; self.index = index }

    public static func == (l: Seg, r: Seg) -> Bool { l.a == r.a && l.b == r.b }
    public func hash(into h: inout Hasher) { h.combine(a); h.combine(b) }

    public var description: String { "[\(a) - \(b)]" }

    public var length: Int { (a - b).norm }
    public var squaredLength: Int { (a - b).squaredNorm }
    public var center: IPoint { a + (b - a).divided(by: 2) }
    public var reversed: Seg { Seg(b, a) }

    /// < 0 when `p` is on the left of the directed line, > 0 on the right, 0 on it
    public func side(_ p: IPoint) -> Int {
        let det = (b - a).cross(p - a)
        return det < 0 ? -1 : det > 0 ? 1 : 0
    }

    @inline(__always) public func tCoef(_ p: IPoint) -> Int { (b - a).dot(p - a) }

    public func canonicalCoefs() -> (qA: Int, qB: Int, qC: Int) {
        let qA = a.y - b.y, qB = b.x - a.x
        return (qA, qB, -qA * a.x - qB * a.y)
    }

    public func collinear(_ s: Seg) -> Bool {
        let (qa, qb, qc) = canonicalCoefs()
        let d1 = abs(s.a.x * qa + s.a.y * qb + qc), d2 = abs(s.b.x * qa + s.b.y * qb + qc)
        return d1 <= 1 && d2 <= 1
    }

    public func contains(_ p: IPoint) -> Bool { squaredDistance(p) <= 3 }

    public func contains(_ s: Seg) -> Bool {
        if s.a == s.b { return contains(s.a) }
        if !collinear(s) { return false }
        return contains(s.a) && contains(s.b)
    }

    public func overlaps(_ s: Seg) -> Bool {
        if s.a == s.b {
            if a == s.a || b == s.a { return false }
            return contains(s.a)
        }
        if !collinear(s) { return false }
        if contains(s.a) || contains(s.b) { return true }
        if s.contains(a) || s.contains(b) { return true }
        return false
    }

    public func nearestPoint(_ p: IPoint) -> IPoint {
        let d = IPoint(b.x - a.x, b.y - a.y)
        let lsq = d.x * d.x + d.y * d.y
        if lsq == 0 { return a }
        let pa = IPoint(p.x - a.x, p.y - a.y)
        let t = d.dot(pa)
        if t < 0 { return a }
        if t > lsq { return b }
        return IPoint(a.x + KiMath.rescale(t, d.x, lsq), a.y + KiMath.rescale(t, d.y, lsq))
    }

    public func nearestPoint(_ s: Seg) -> IPoint {
        if let p = intersect(s) { return p }
        let origin = [s.nearestPoint(a), s.nearestPoint(b), nearestPoint(s.a), nearestPoint(s.b)]
        let out = [a, b, origin[2], origin[3]]
        let dist = [(origin[0] - a).squaredNorm, (origin[1] - b).squaredNorm, (origin[2] - s.a).squaredNorm, (origin[3] - s.b).squaredNorm]
        var minI = 0
        for i in 0..<4 where dist[i] < dist[minI] { minI = i }
        return out[minI]
    }

    public func lineProject(_ p: IPoint) -> IPoint {
        let d = b - a
        let lsq = d.dot(d)
        if lsq == 0 { return a }
        let t = d.dot(p - a)
        return IPoint(a.x + KiMath.rescale(t, d.x, lsq), a.y + KiMath.rescale(t, d.y, lsq))
    }

    /// The segment from `p` square to this one, as long (KiCad's PerpendicularSeg)
    public func perpendicularSeg(_ p: IPoint) -> Seg { Seg(p, (b - a).perpendicular + p) }

    /// The segment from `p` along this one, as long (KiCad's ParallelSeg)
    public func parallelSeg(_ p: IPoint) -> Seg { Seg(p, (b - a) + p) }

    public func squaredDistance(_ p: IPoint) -> Int {
        let ab = IPoint(b.x - a.x, b.y - a.y), ap = IPoint(p.x - a.x, p.y - a.y)
        let e = ap.dot(ab)
        if e <= 0 { return ap.squaredNorm }
        let f = ab.squaredNorm
        if e >= f {
            let bp = IPoint(p.x - b.x, p.y - b.y)
            return bp.dot(bp)
        }
        let g = Double(ap.squaredNorm) - (Double(e) * Double(e)) / Double(f)
        if g < 0 || g > Double(Int.max) { return 0 }
        return KiMath.round(g)
    }

    public func distance(_ p: IPoint) -> Int { KiMath.isqrt(squaredDistance(p)) }

    public func squaredDistance(_ s: Seg) -> Int {
        if a == b { return s.squaredDistance(a) }
        if s.a == s.b { return squaredDistance(s.a) }
        if intersects(s) { return 0 }
        let pts = [s.nearestPoint(a) - a, s.nearestPoint(b) - b, nearestPoint(s.a) - s.a, nearestPoint(s.b) - s.b]
        return pts.map(\.squaredNorm).min()!
    }

    public func distance(_ s: Seg) -> Int { KiMath.isqrt(squaredDistance(s)) }

    /// The distance from `p` to the line through the segment (signed by the side, if asked: negative on the left)
    public func lineDistance(_ p: IPoint, determineSide: Bool = false) -> Int {
        let pp = a.y - b.y, q = b.x - a.x
        let r = -pp * a.x - q * a.y
        let l = pp * pp + q * q
        let det = pp * p.x + q * p.y + r
        var distSq = 0
        if l > 0 { distSq = KiMath.rescale(det, det, l) }
        let dist = KiMath.isqrt(distSq)
        return determineSide ? KiMath.sign(det) * dist : abs(dist)
    }

    private func checkCollinearOverlap(_ s: Seg, useXAxis: Bool, ignoreEndpoints: Bool, point: inout IPoint?) -> Bool {
        let (s1s, s1e, s2s, s2e, c1s, c1e) = useXAxis ? (a.x, b.x, s.a.x, s.b.x, a.y, b.y) : (a.y, b.y, s.a.y, s.b.y, a.x, b.x)
        let s1min = min(s1s, s1e), s1max = max(s1s, s1e), s2min = min(s2s, s2e), s2max = max(s2s, s2e)
        guard s1max >= s2min && s2max >= s1min else { return false }
        if ignoreEndpoints {
            let os = max(s1min, s2min), oe = min(s1max, s2max)
            if os == oe && (os == s1min || os == s1max) && (os == s2min || os == s2max) { return false }
        }
        let os = max(s1min, s2min), oe = min(s1max, s2max)
        let proj = (os + oe) / 2
        let other = s1e != s1s ? c1s + KiMath.rescale(proj - s1s, c1e - c1s, s1e - s1s) : c1s
        point = useXAxis ? IPoint(proj, other) : IPoint(other, proj)
        return true
    }

    /// KiCad's SEG::intersects: whether the segments (or their lines) cross, and where
    private func intersects(_ s: Seg, ignoreEndpoints: Bool, lines: Bool, point: inout IPoint?) -> Bool {
        if !lines {
            if max(a.x, b.x) < min(s.a.x, s.b.x) || max(s.a.x, s.b.x) < min(a.x, b.x)
                || max(a.y, b.y) < min(s.a.y, s.b.y) || max(s.a.y, s.b.y) < min(a.y, b.y) {
                return false
            }
        }
        let dir1 = b - a, dir2 = s.b - s.a, offset = s.a - a
        let det = dir2.cross(dir1)
        if det == 0 {
            if dir1.cross(offset) != 0 { return false }
            if lines {
                point = s.a == s.b ? s.a : a == b ? a : (a + s.a).divided(by: 2)
                return true
            }
            return checkCollinearOverlap(s, useXAxis: abs(dir1.x) >= abs(dir1.y), ignoreEndpoints: ignoreEndpoints, point: &point)
        }
        let p2 = dir2.cross(offset), p1 = dir1.cross(offset)
        if !lines {
            if det > 0 {
                if p1 < 0 || p1 > det || p2 < 0 || p2 > det { return false }
            } else {
                if p1 > 0 || p1 < det || p2 > 0 || p2 < det { return false }
            }
            if ignoreEndpoints && (p1 == 0 || p1 == det) && (p2 == 0 || p2 == det) { return false }
        }
        let x = s.a.x + KiMath.rescale(p1, dir2.x, det), y = s.a.y + KiMath.rescale(p1, dir2.y, det)
        // where KiCad's 32-bit coordinates cannot reach, there is no intersection
        guard Int(Int32.min)...Int(Int32.max) ~= x, Int(Int32.min)...Int(Int32.max) ~= y else { return false }
        point = IPoint(x, y)
        return true
    }

    public func intersects(_ s: Seg) -> Bool {
        var p: IPoint?
        return intersects(s, ignoreEndpoints: false, lines: false, point: &p)
    }

    public func intersect(_ s: Seg, ignoreEndpoints: Bool = false, lines: Bool = false) -> IPoint? {
        var p: IPoint?
        return intersects(s, ignoreEndpoints: ignoreEndpoints, lines: lines, point: &p) ? p : nil
    }

    public func intersectLines(_ s: Seg) -> IPoint? { intersect(s, lines: true) }

    /// Whether the segments come closer than `clearance`, and how close
    public func collide(_ s: Seg, clearance: Int, actual: inout Int?) -> Bool {
        if clearance < 0 { actual = 0; return false }
        if a == b {
            let d = s.distance(a)
            actual = d
            return d == 0 || d < clearance
        }
        if s.a == s.b {
            let d = distance(s.a)
            actual = d
            return d == 0 || d < clearance
        }
        if intersects(s) { actual = 0; return true }
        let ds = [squaredDistance(s.a), squaredDistance(s.b), s.squaredDistance(a), s.squaredDistance(b)]
        if ds.contains(0) { actual = 0; return true }
        let m = ds.min()!
        actual = KiMath.isqrt(m)
        return m < clearance * clearance
    }

    public func collide(_ s: Seg, clearance: Int) -> Bool {
        var actual: Int?
        return collide(s, clearance: clearance, actual: &actual)
    }

    private func mutualDistanceSquared(_ s: Seg) -> (Int, Int)? {
        var (x, y) = (self, s)
        if x.squaredLength < y.squaredLength { swap(&x, &y) }
        let p = x.a.y - x.b.y, q = x.b.x - x.a.x
        let r = -p * x.a.x - q * x.a.y
        let l = p * p + q * q
        if l == 0 { return nil }
        let det1 = p * y.a.x + q * y.a.y + r, det2 = p * y.b.x + q * y.b.y + r
        return (KiMath.sign(det1) * KiMath.rescale(det1, det1, l), KiMath.sign(det2) * KiMath.rescale(det2, det2, l))
    }

    public func approxCollinear(_ s: Seg, threshold: Int = 1) -> Bool {
        guard let (d1, d2) = mutualDistanceSquared(s) else { return false }
        return abs(d1) <= threshold * threshold && abs(d2) <= threshold * threshold
    }

    public func approxParallel(_ s: Seg, threshold: Int = 1) -> Bool {
        guard let (d1, d2) = mutualDistanceSquared(s) else { return false }
        return abs(d1 - d2) <= threshold * threshold
    }
}

/// The eight directions of 45° routing, and the angles they make (KiCad's DIRECTION_45). North is up on the screen,
/// which is y negative.
public struct Direction45: Hashable, Sendable, CustomStringConvertible {
    public enum Dir: Int, Sendable { case n = 0, ne, e, se, s, sw, w, nw, undefined = -1 }

    /// The corners a trace turns (KiCad's CORNER_MODE, the router's "Track corner mode"): mitered or rounded, on the
    /// 45° directions or on 90° ones only
    public enum CornerMode: Int, Sendable {
        case mitered45 = 0, rounded45, mitered90, rounded90

        /// Horizontal and vertical only (MITERED_90 or ROUNDED_90)
        public var isNinety: Bool { self == .mitered90 || self == .rounded90 }
    }

    public struct AngleType: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let obtuse = AngleType(rawValue: 0x01)
        public static let right = AngleType(rawValue: 0x02)
        public static let acute = AngleType(rawValue: 0x04)
        public static let straight = AngleType(rawValue: 0x08)
        public static let halfFull = AngleType(rawValue: 0x10)
        public static let undefined = AngleType(rawValue: 0x20)
    }

    public var dir: Dir
    public var ninety: Bool

    public init(_ dir: Dir = .undefined, ninety: Bool = false) { self.dir = dir; self.ninety = ninety }

    public init(_ v: IPoint, ninety: Bool = false) {
        self.ninety = ninety
        self.dir = Self.construct(IPoint(v.x, -v.y))
    }

    public init(_ s: Seg, ninety: Bool = false) { self.init(s.b - s.a, ninety: ninety) }

    /// The direction of an arc's chord, from its start to its end
    public init(_ a: ShapeArc, ninety: Bool = false) { self.init(a.end - a.start, ninety: ninety) }

    public static func == (l: Direction45, r: Direction45) -> Bool { l.dir == r.dir }
    public func hash(into h: inout Hasher) { h.combine(dir) }

    public var description: String {
        ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"][safe: dir.rawValue] ?? "undefined"
    }

    private static func construct(_ v: IPoint) -> Dir {
        if v.x == 0 && v.y == 0 { return .undefined }
        var mag = 360.0 - (180.0 / Double.pi * atan2(Double(v.y), Double(v.x))) + 90.0
        if mag >= 360.0 { mag -= 360.0 }
        if mag < 0.0 { mag += 360.0 }
        var d = Int((mag + 22.5) / 45.0)
        if d >= 8 { d -= 8 }
        if d < 0 { d += 8 }
        return Dir(rawValue: d)!
    }

    public var isDefined: Bool { dir != .undefined }
    public var isDiagonal: Bool { dir != .undefined && dir.rawValue % 2 == 1 }

    public var opposite: Direction45 {
        guard dir != .undefined else { return Direction45() }
        return Direction45(Dir(rawValue: (dir.rawValue + 4) % 8)!)
    }

    public func angle(_ o: Direction45) -> AngleType {
        if dir == .undefined || o.dir == .undefined { return .undefined }
        switch abs(dir.rawValue - o.dir.rawValue) {
        case 1, 7: return .obtuse
        case 2, 6: return .right
        case 3, 5: return .acute
        case 4: return .halfFull
        default: return .straight
        }
    }

    public func isObtuse(_ o: Direction45) -> Bool { angle(o) == .obtuse }

    public var right: Direction45 {
        guard dir != .undefined else { return Direction45() }
        return Direction45(Dir(rawValue: (dir.rawValue + (ninety ? 2 : 1)) % 8)!, ninety: ninety)
    }

    public var left: Direction45 {
        guard dir != .undefined else { return Direction45() }
        return Direction45(Dir(rawValue: (dir.rawValue + 8 - (ninety ? 2 : 1)) % 8)!, ninety: ninety)
    }

    public var vector: IPoint {
        switch dir {
        case .n: return IPoint(0, -1)
        case .s: return IPoint(0, 1)
        case .e: return IPoint(1, 0)
        case .w: return IPoint(-1, 0)
        case .ne: return IPoint(1, -1)
        case .nw: return IPoint(-1, -1)
        case .se: return IPoint(1, 1)
        case .sw: return IPoint(-1, 1)
        case .undefined: return .zero
        }
    }

    public var mask: Int { 1 << dir.rawValue }

    /// KiCad's BuildInitialTrace: from `p0` to `p1` on 45° (or 90°) directions, a straight piece and a diagonal one
    /// (or a horizontal and a vertical), the corner between them mitered or rounded (an arc in its place), starting
    /// diagonally if this direction is diagonal (or, undefined, if `startDiagonal`)
    public func buildInitialTrace(_ p0: IPoint, _ p1: IPoint, startDiagonal: Bool = false, mode: CornerMode = .mitered45) -> LineChain {
        let diagonal = dir == .undefined ? startDiagonal : isDiagonal
        let w = abs(p1.x - p0.x), h = abs(p1.y - p0.y)
        let sw = KiMath.sign(p1.x - p0.x), sh = KiMath.sign(p1.y - p0.y)
        let ninetyMode = mode == .rounded90 || mode == .mitered90
        var pl = LineChain()
        // (one segment will do)
        if w == 0 || h == 0 || (!ninetyMode && h == w) {
            pl.append(p0)
            pl.append(p1)
            return pl
        }
        var mp0 = IPoint.zero, mp1 = IPoint.zero
        var tangentLength = 0
        if ninetyMode {
            mp0 = diagonal == (h >= w) ? IPoint(w * sw, 0) : IPoint(0, sh * h)
        } else if w > h {
            mp0 = IPoint((w - h) * sw, 0)
            mp1 = IPoint(h * sw, h * sh)
            tangentLength = (w - h) - mp1.norm
        } else {
            mp0 = IPoint(0, sh * (h - w))
            mp1 = IPoint(sw * w, sh * w)
            tangentLength = (h - w) - mp1.norm
        }
        switch mode {
        case .mitered45:
            pl.append(p0)
            pl.append(diagonal ? p0 + mp1 : p0 + mp0)
            pl.append(p1)
        case .rounded45:
            // the arc where the corner would be, a straight piece before it (starting straight) or after it, its
            // length the straight one's less the diagonal's (negative: the arc at the other end)
            if w == h {
                pl.append(p0)
                pl.append(p1)
                break
            }
            let diag2 = Double(tangentLength >= 0 ? mp1.squaredNorm : mp0.squaredNorm)
            let diagLength = (2 * diag2 - 2 * diag2 * cos(3 * Double.pi / 4)).squareRoot()
            let arcRadius = KiMath.round(diagLength / (2.0 * cos(67.5 * Double.pi / 180.0)))
            let rotationSign = Double(w > h ? sw * sh * -1 : sw * sh)
            if diagonal {
                if tangentLength >= 0 {
                    // the arc at the start
                    let arc = ShapeArc(start: p0, end: p1 - mp0.resized(tangentLength), angle: .a45 * rotationSign)
                    if arc.start == arc.end { pl.append(p0) } else { pl.append(arc) }
                    pl.append(p1)
                } else {
                    // the arc at the end
                    let arc = ShapeArc(start: p0 + mp1.resized(abs(tangentLength)), end: p1, angle: .a45 * rotationSign)
                    pl.append(p0)
                    if arc.start == arc.end { pl.append(p1) } else { pl.append(arc) }
                }
            } else {
                let centerDir = KiMath.rotate(DPoint(mp0), .a90 * rotationSign)
                if tangentLength >= 0 {
                    // the arc at the end
                    let arc = ShapeArc(start: p0 + mp0.resized(tangentLength), end: p1, angle: -.a45 * rotationSign)
                    pl.append(p0)
                    if arc.start == arc.end { pl.append(p1) } else { pl.append(arc) }
                } else {
                    // the arc at the start, about a centre, its end then put square to the end (an end made from a
                    // centre is not quite on it)
                    let arcCenter = (DPoint(p0) + centerDir.resized(Double(arcRadius))).truncated
                    var ca = ShapeArc(center: arcCenter, start: p0, angle: -.a45 * rotationSign)
                    let endpoint = ca.end
                    if abs(endpoint.y - p1.y) < Circle.minPrecision {
                        ca = ShapeArc(start: ca.start, end: IPoint(endpoint.x, p1.y), angle: .a45 * rotationSign)
                    } else if abs(endpoint.x - p1.x) < Circle.minPrecision {
                        ca = ShapeArc(start: ca.start, end: IPoint(p1.x, endpoint.y), angle: .a45 * rotationSign)
                    }
                    if ca.start == ca.end { pl.append(p0) } else { pl.append(ca) }
                    pl.append(p1)
                }
            }
        case .mitered90:
            pl.append(p0)
            pl.append(p0 + mp0)
            pl.append(p1)
        case .rounded90:
            // the arc where the corner would be, its radius the shorter of the two distances, a straight piece
            // before it or after it
            if w == h {
                // (one arc and nothing else, not simplified)
                pl.append(ShapeArc(start: p0, end: p1, center: p1 - mp0, clockwise: (sh == sw) != diagonal))
                return pl
            }
            if diagonal {
                // the arc first
                if h > w {
                    // then a vertical line
                    let y = p0.y + w * sh
                    pl.append(ShapeArc(start: p0, end: IPoint(p1.x, y), center: IPoint(p0.x, y), clockwise: sh != sw))
                    pl.append(p1)
                } else {
                    // then a horizontal one
                    let x = p0.x + h * sw
                    pl.append(ShapeArc(start: p0, end: IPoint(x, p1.y), center: IPoint(x, p0.y), clockwise: sh == sw))
                    pl.append(p1)
                }
            } else if w > h {
                // a horizontal line, then the arc
                let x = p1.x - h * sw
                pl.append(p0)
                pl.append(ShapeArc(start: IPoint(x, p0.y), end: p1, center: IPoint(x, p1.y), clockwise: sh != sw))
            } else {
                // a vertical one, then the arc
                let y = p1.y - w * sh
                pl.append(p0)
                pl.append(ShapeArc(start: IPoint(p0.x, y), end: p1, center: IPoint(p1.x, y), clockwise: sh == sw))
            }
        }
        pl.simplify()
        return pl
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}
