// Ported from KiCad 10.0.7: libs/kimath/src/geometry/shape_collisions.cpp, libs/kimath/src/geometry/shape_rect.cpp,
// libs/kimath/include/geometry/shape_circle.h and shape_segment.h, and pcbnew/router/pns_utils.cpp (the hulls).
// Copyright (C) 2013-2015 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// The shape of something on the board, as the router knows it: a pad's (a circle, an upright rectangle, a stadium
/// for an oval, else a polygon), a track's (a segment with its width), a via's (a circle), a trace being placed (a
/// polyline, its width given with the clearance)
public enum Shape: Hashable, Sendable {
    case circle(center: IPoint, radius: Int)
    /// An upright rectangle (KiCad's SHAPE_RECT, without rounded corners)
    case rect(IBox)
    /// A segment with round ends, `width` across (KiCad's SHAPE_SEGMENT)
    case segment(Seg, width: Int)
    /// A closed polygon (KiCad's SHAPE_SIMPLE)
    case simple(LineChain)
    /// A polyline of no width (KiCad's SHAPE_LINE_CHAIN, as a trace's path)
    case chain(LineChain)

    public var bbox: IBox {
        switch self {
        case .circle(let c, let r): return IBox(minX: c.x - r, minY: c.y - r, maxX: c.x + r, maxY: c.y + r)
        case .rect(let b): return b
        case .segment(let s, let w): return IBox(s.a, s.b).inflated((w + 1) / 2)
        case .simple(let c), .chain(let c): return c.bbox
        }
    }

    public func bbox(_ clearance: Int) -> IBox { bbox.inflated(clearance) }

    /// The shape moved by `d`
    public func moved(_ d: IPoint) -> Shape {
        switch self {
        case .circle(let c, let r): return .circle(center: c + d, radius: r)
        case .rect(let b): return .rect(IBox(minX: b.minX + d.x, minY: b.minY + d.y, maxX: b.maxX + d.x, maxY: b.maxY + d.y))
        case .segment(let s, let w): return .segment(Seg(s.a + d, s.b + d), width: w)
        case .simple(let c): return .simple(LineChain(c.points.map { $0 + d }, closed: true))
        case .chain(let c): return .chain(LineChain(c.points.map { $0 + d }))
        }
    }

    // MARK: - Collisions

    /// Whether this shape and `other` come closer than `clearance` (KiCad's SHAPE::Collide)
    public func collide(_ other: Shape, clearance: Int) -> Bool {
        var actual: Int?
        return collide(other, clearance: clearance, actual: &actual)
    }

    /// Whether this shape and `other` come closer than `clearance`, and how close they come
    public func collide(_ other: Shape, clearance: Int, actual: inout Int?) -> Bool {
        switch (self, other) {
        case let (.rect(a), .rect(b)):
            return Self.chainChain(Self.rectOutline(a), Self.rectOutline(b), clearance, &actual)
        case let (.rect(a), .circle(c, r)), let (.circle(c, r), .rect(a)):
            return Self.rectCircle(a, c, r, clearance, &actual)
        case let (.rect(a), .chain(l)), let (.rect(a), .simple(l)), let (.chain(l), .rect(a)), let (.simple(l), .rect(a)):
            return Self.rectChain(a, l, clearance, &actual)
        case let (.rect(a), .segment(s, w)), let (.segment(s, w), .rect(a)):
            return Self.withWidth(Self.rectSeg(a, s, clearance + w / 2, &actual), w, &actual)
        case let (.circle(c1, r1), .circle(c2, r2)):
            return Self.circleCircle(c1, r1, c2, r2, clearance, &actual)
        case let (.circle(c, r), .chain(l)), let (.circle(c, r), .simple(l)), let (.chain(l), .circle(c, r)), let (.simple(l), .circle(c, r)):
            return Self.circleChain(c, r, l, clearance, &actual)
        case let (.circle(c, r), .segment(s, w)), let (.segment(s, w), .circle(c, r)):
            return Self.withWidth(Self.circleSeg(c, r, s, clearance + w / 2, &actual), w, &actual)
        case let (.segment(s1, w1), .segment(s2, w2)):
            return Self.withWidth(Self.capsuleSeg(s1, w1, s2, clearance + w2 / 2, &actual), w2, &actual)
        case let (.chain(l), .segment(s, w)), let (.simple(l), .segment(s, w)), let (.segment(s, w), .chain(l)), let (.segment(s, w), .simple(l)):
            var location: IPoint?
            return Self.withWidth(l.collide(s, clearance: clearance + w / 2, actual: &actual, location: &location), w, &actual)
        case let (.chain(a), .chain(b)), let (.chain(a), .simple(b)), let (.simple(a), .chain(b)), let (.simple(a), .simple(b)):
            return Self.chainChain(a, b, clearance, &actual)
        }
    }

    /// A segment's own collision, its width's half taken off what is found
    private static func withWidth(_ hit: Bool, _ width: Int, _ actual: inout Int?) -> Bool {
        if hit, let a = actual { actual = max(0, a - width / 2) }
        return hit
    }

    static func rectOutline(_ b: IBox) -> LineChain {
        LineChain([IPoint(b.minX, b.minY), IPoint(b.maxX, b.minY), IPoint(b.maxX, b.maxY), IPoint(b.minX, b.maxY)], closed: true)
    }

    static func circleCircle(_ c1: IPoint, _ r1: Int, _ c2: IPoint, _ r2: Int, _ clearance: Int, _ actual: inout Int?) -> Bool {
        let minDist = clearance + r1 + r2
        let dsq = (c2 - c1).squaredNorm
        if dsq == 0 || dsq < minDist * minDist {
            actual = max(0, Int(Double(dsq).squareRoot()) - r1 - r2)
            return true
        }
        return false
    }

    /// A circle against a segment (KiCad's SHAPE_CIRCLE::Collide(SEG))
    static func circleSeg(_ c: IPoint, _ r: Int, _ s: Seg, _ clearance: Int, _ actual: inout Int?) -> Bool {
        let minDist = clearance + r
        let pn = s.nearestPoint(c)
        let dsq = (pn - c).squaredNorm
        if dsq == 0 || dsq < minDist * minDist {
            actual = max(0, Int(Double(dsq).squareRoot()) - r)
            return true
        }
        return false
    }

    /// A segment of some width against a segment (KiCad's SHAPE_SEGMENT::Collide(SEG))
    static func capsuleSeg(_ s1: Seg, _ w1: Int, _ s2: Seg, _ clearance: Int, _ actual: inout Int?) -> Bool {
        let minDist = (w1 + 1) / 2 + clearance
        if s2.a == s2.b {
            let dsq = s1.squaredDistance(s2.a)
            if dsq == 0 || dsq < minDist * minDist {
                actual = max(0, Int(Double(dsq).squareRoot()) - (w1 + 1) / 2)
                return true
            }
            return false
        }
        let dsq = s1.squaredDistance(s2)
        if dsq == 0 || dsq < minDist * minDist {
            actual = max(0, Int(Double(dsq).squareRoot()) - (w1 + 1) / 2)
            return true
        }
        return false
    }

    /// An upright rectangle against a segment (KiCad's SHAPE_RECT::Collide(SEG))
    static func rectSeg(_ b: IBox, _ s: Seg, _ clearance: Int, _ actual: inout Int?) -> Bool {
        if b.contains(s.a) || b.contains(s.b) {
            actual = 0
            return true
        }
        let c = [IPoint(b.minX, b.minY), IPoint(b.minX, b.maxY), IPoint(b.maxX, b.maxY), IPoint(b.maxX, b.minY), IPoint(b.minX, b.minY)]
        var closest = Int.max
        for i in 0..<4 { closest = min(closest, Seg(c[i], c[i + 1]).squaredDistance(s)) }
        if closest == 0 || closest < clearance * clearance {
            actual = Int(Double(closest).squareRoot())
            return true
        }
        return false
    }

    static func rectCircle(_ b: IBox, _ c: IPoint, _ r: Int, _ clearance: Int, _ actual: inout Int?) -> Bool {
        let minDist = clearance + r
        let v = [IPoint(b.minX, b.minY), IPoint(b.minX, b.maxY), IPoint(b.maxX, b.maxY), IPoint(b.maxX, b.minY), IPoint(b.minX, b.minY)]
        var nearestSq = Int.max
        let inside = b.contains(c)
        for i in 0..<4 {
            let pn = Seg(v[i], v[i + 1]).nearestPoint(c)
            nearestSq = min(nearestSq, (pn - c).squaredNorm)
        }
        if inside || nearestSq == 0 || nearestSq < minDist * minDist {
            // (inside it, the distance KiCad gives is still the one to its nearest side)
            actual = max(0, Int(Double(nearestSq).squareRoot()) - r)
            return true
        }
        return false
    }

    static func circleChain(_ c: IPoint, _ r: Int, _ l: LineChain, _ clearance: Int, _ actual: inout Int?) -> Bool {
        var closest = Int.max
        if l.isClosed && l.pointInside(c) {
            closest = 0
        } else {
            for s in 0..<l.segmentCount {
                var d: Int?
                if circleSeg(c, r, l.segment(s), clearance, &d) {
                    closest = min(closest, d ?? 0)
                    if closest == 0 { break }
                }
            }
        }
        if closest == 0 || closest < clearance {
            actual = closest
            return true
        }
        return false
    }

    static func rectChain(_ b: IBox, _ l: LineChain, _ clearance: Int, _ actual: inout Int?) -> Bool {
        var closest = Int.max
        if l.isClosed && l.pointInside(b.center) {
            closest = 0
        } else {
            for s in 0..<l.segmentCount {
                var d: Int?
                if rectSeg(b, l.segment(s), clearance, &d) {
                    closest = min(closest, d ?? 0)
                    if closest == 0 { break }
                }
            }
        }
        if closest == 0 || closest < clearance {
            actual = closest
            return true
        }
        return false
    }

    static func chainChain(_ a: LineChain, _ b: LineChain, _ clearance: Int, _ actual: inout Int?) -> Bool {
        var closest = Int.max
        if b.isClosed && a.pointCount > 0 && b.pointInside(a.point(0)) {
            closest = 0
        } else if a.isClosed && b.pointCount > 0 && a.pointInside(b.point(0)) {
            closest = 0
        } else {
            let order: (Seg, Seg) -> Bool = { $0.a.x < $1.a.x || ($0.a.x == $1.a.x && $0.a.y < $1.a.y) }
            let aSegs = a.segments.sorted(by: order), bSegs = b.segments.sorted(by: order)
            outer: for sa in aSegs {
                for sb in bSegs {
                    var d: Int?
                    if sa.collide(sb, clearance: clearance, actual: &d) {
                        closest = min(closest, d ?? 0)
                        if closest == 0 { break outer }
                    }
                }
            }
        }
        if closest == 0 || closest < clearance {
            actual = closest
            return true
        }
        return false
    }

    // MARK: - Hulls (pns_utils.cpp)

    /// The walkaround hull of the shape: its outline grown by `clearance` and half the width of the trace that walks
    /// round it, an octagon (or the like) whose sides run on the 45° directions, clockwise
    public func hull(clearance: Int, walkaroundThickness: Int) -> LineChain {
        let cl = clearance + (walkaroundThickness + 1) / 2
        switch self {
        case .rect(let b):
            return Self.octagonalHull(IPoint(b.minX, b.minY), IPoint(b.width, b.height), cl, 0)
        case .circle(let c, let r):
            return Self.octagonalHull(c - IPoint(r, r), IPoint(2 * r, 2 * r), cl, Int(2.0 * (1.0 - 0.5.squareRoot()) * Double(r + cl)))
        case .segment(let s, let w):
            return Self.segmentHull(s, w, clearance, walkaroundThickness)
        case .simple(let c):
            return Self.convexHull(c, cl)
        case .chain(let c):
            // a polyline's hull: the segments' hulls would be joined; the router hulls lines segment by segment
            return Self.convexHull(LineChain(c.points, closed: true), cl)
        }
    }

    /// KiCad's OctagonalHull: the box at `p0` of `size`, grown by `clearance`, its corners cut by `chamfer`
    public static func octagonalHull(_ p0: IPoint, _ size: IPoint, _ clearance: Int, _ chamfer: Int) -> LineChain {
        var s = LineChain()
        s.setClosed(true)
        s.append(p0.x - clearance, p0.y - clearance + chamfer)
        if chamfer != 0 { s.append(p0.x - clearance + chamfer, p0.y - clearance) }
        s.append(p0.x + size.x + clearance - chamfer, p0.y - clearance)
        if chamfer != 0 { s.append(p0.x + size.x + clearance, p0.y - clearance + chamfer) }
        s.append(p0.x + size.x + clearance, p0.y + size.y + clearance - chamfer)
        if chamfer != 0 { s.append(p0.x + size.x + clearance - chamfer, p0.y + size.y + clearance) }
        s.append(p0.x - clearance + chamfer, p0.y + size.y + clearance)
        if chamfer != 0 { s.append(p0.x - clearance, p0.y + size.y + clearance - chamfer) }
        return s
    }

    private static func isSegment45Degree(_ s: Seg) -> Bool {
        let d = s.b - s.a
        if abs(d.x) <= 1 || abs(d.y) <= 1 { return true }
        let delta = abs(d.x) - abs(d.y)
        return delta >= -1 && delta <= 1
    }

    /// KiCad's SegmentHull: an elongated octagon round a segment of `width`
    public static func segmentHull(_ seg: Seg, _ width: Int, _ clearance: Int, _ walkaroundThickness: Int) -> LineChain {
        let kinkThreshold = clearance / 10
        var cl = clearance + walkaroundThickness / 2
        let d = Double(width) / 2.0 + Double(cl)
        let x = 2.0 / (1.0 + 2.0.squareRoot()) * d
        let dr = KiMath.round(d)
        let xr2 = KiMath.round(x / 2.0)
        let a = seg.a
        var b = seg.b
        let len = seg.length
        var w = b.x - a.x, h = b.y - a.y
        if a != b {
            if !isSegment45Degree(seg) {
                if len <= kinkThreshold && len > 0 {
                    let ll = max(abs(w), abs(h))
                    b = a + IPoint(KiMath.sign(w) * ll, KiMath.sign(h) * ll)
                }
            } else if len <= kinkThreshold {
                let delta45 = abs(abs(w) - abs(h))
                if abs(w) <= 1 {
                    w = 0
                    cl += 1
                } else if abs(h) <= 1 {
                    h = 0
                    cl += 1
                } else if delta45 <= 2 {
                    let m = max(abs(w), abs(h))
                    w = KiMath.sign(w) * m
                    h = KiMath.sign(h) * m
                    cl += 2
                }
                b = IPoint(a.x + w, a.y + h)
            }
        }
        if a == b {
            let xx2 = KiMath.round(2.0 * (1.0 - 0.5.squareRoot()) * d)
            return octagonalHull(a - IPoint(width / 2, width / 2), IPoint(width, width), cl, xx2)
        }
        let dir = b - a
        let p0 = dir.perpendicular.resized(dr)
        let ds = dir.perpendicular.resized(xr2)
        let pd = dir.resized(xr2)
        let dp = dir.resized(dr)
        var s = LineChain()
        s.setClosed(true)
        s.append(b + p0 + pd)
        s.append(b + dp + ds)
        s.append(b + dp - ds)
        s.append(b - p0 + pd)
        s.append(a - p0 - pd)
        s.append(a - dp - ds)
        s.append(a - dp + ds)
        s.append(a + p0 - pd)
        // clockwise, always
        return s.segment(0).side(a) < 0 ? s.reversed() : s
    }

    private static func moveDiagonal(_ diagonal: inout Seg, _ vertices: LineChain, _ clearance: Int) {
        var dist = 0
        _ = vertices.nearestPoint(diagonal, dist: &dist)
        let moveBy = (diagonal.a - diagonal.b).perpendicular.resized(dist - clearance)
        diagonal.a += moveBy
        diagonal.b += moveBy
    }

    /// KiCad's ConvexHull: the octagon round a convex polygon, `clearance` from it
    public static func convexHull(_ convex: LineChain, _ clearance: Int) -> LineChain {
        let box = convex.bbox(clearance)
        let (x, y, w, h) = (box.minX, box.minY, box.width, box.height)
        let origin = IPoint(x, y)
        let topline = Seg(IPoint(x, y + h), IPoint(x + w, y + h))
        let rightline = Seg(IPoint(x + w, y + h), IPoint(x + w, y))
        let bottomline = Seg(IPoint(x + w, y), origin)
        let leftline = Seg(origin, IPoint(x, y + h))
        var corner = origin + IPoint(w, h)
        var toprightline = Seg(corner, corner + IPoint(h, -h))
        moveDiagonal(&toprightline, convex, clearance)
        corner = origin + IPoint(w, 0)
        var bottomrightline = Seg(corner + IPoint(h, h), corner)
        moveDiagonal(&bottomrightline, convex, clearance)
        corner = origin
        var bottomleftline = Seg(corner, corner + IPoint(-h, h))
        moveDiagonal(&bottomleftline, convex, clearance)
        corner = origin + IPoint(0, h)
        var topleftline = Seg(corner + IPoint(-h, -h), corner)
        moveDiagonal(&topleftline, convex, clearance)
        var octagon = LineChain()
        octagon.setClosed(true)
        for (l1, l2) in [(leftline, bottomleftline), (bottomline, bottomleftline), (bottomline, bottomrightline),
                         (rightline, bottomrightline), (rightline, toprightline), (topline, toprightline),
                         (topline, topleftline), (leftline, topleftline)] {
            if let p = l1.intersectLines(l2) { octagon.append(p) }
        }
        return octagon
    }

    /// KiCad's HullIntersection: where a path crosses a hull, leaving out the touches that do not cross it
    public static func hullIntersection(_ hull: LineChain, _ line: LineChain) -> [LineChain.Intersection] {
        var out: [LineChain.Intersection] = []
        if line.pointCount < 2 { return out }
        for var p in hull.intersect(line) {
            var ipp = p
            ipp.valid = false
            if !p.isCornerOur && !p.isCornerTheir {
                ipp.valid = true
                out.append(ipp)
                continue
            }
            if p.indexOur >= hull.segmentCount { p.indexOur -= hull.segmentCount }
            var d1: [Seg] = []
            var d2: [IPoint] = []
            if p.isCornerOur {
                d1 = [hull.segment(p.indexOur), hull.segment(p.indexOur - 1)]
            } else {
                d1 = [hull.segment(p.indexOur)]
            }
            if p.isCornerTheir {
                if p.indexTheir > 0 { d2.append(line.segment(p.indexTheir - 1).a) }
                if p.indexTheir < line.pointCount - 1 { d2.append(line.segment(p.indexTheir).b) }
            } else {
                d2 = [line.segment(p.indexTheir).a, line.segment(p.indexTheir).b]
            }
            for s in d1 { for q in d2 where s.side(q) > 0 { ipp.valid = true } }
            if ipp.valid { out.append(ipp) }
        }
        return out
    }
}
