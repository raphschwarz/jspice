// Ported from KiCad 10.0.7: libs/kimath/include/geometry/shape_arc.h, libs/kimath/src/geometry/shape_arc.cpp, the
// arc cases of libs/kimath/src/geometry/shape_collisions.cpp and shape_nearest_points.cpp, and pcbnew/router/
// pns_utils.cpp (ArcHull).
// Copyright (C) 2017 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// An arc through three points, of some width (KiCad's SHAPE_ARC): a board outline's rounded corner, a circle drawn
/// on the edge, an arc track. Its centre, radius and box are worked out once, as KiCad works them out.
public struct ShapeArc: Hashable, Sendable, CustomStringConvertible {
    public private(set) var start: IPoint
    public private(set) var mid: IPoint
    public private(set) var end: IPoint
    public var width: Int
    public private(set) var center = IPoint.zero
    public private(set) var radius = 0.0
    /// Its box, without its width
    private var box = IBox(.zero, .zero)

    public init(start: IPoint, mid: IPoint, end: IPoint, width: Int = 0) {
        self.start = start
        self.mid = mid
        self.end = end
        self.width = width
        update()
    }

    /// The arc about `center` from `start` through `angle` (KiCad's SHAPE_ARC( center, start, angle ))
    public init(center: IPoint, start: IPoint, angle: EDAAngle, width: Int = 0) {
        self.start = start
        let m = KiMath.rotate(DPoint(start), around: DPoint(center), -angle / 2.0)
        let e = KiMath.rotate(DPoint(start), around: DPoint(center), -angle)
        mid = m.rounded
        end = e.rounded
        self.width = width
        update()
    }

    /// The arc from `start` to `end` about `center`, counter-clockwise unless `clockwise` (KiCad's
    /// ConstructFromStartEndCenter, which leaves the width as it was)
    public init(start: IPoint, end: IPoint, center: IPoint, clockwise: Bool = false, width: Int = 0) {
        var angle = EDAAngle(end - center).normalized - EDAAngle(start - center).normalized
        angle = clockwise ? angle.normalized - .a360 : angle.normalized
        self.start = start
        self.end = end
        mid = KiMath.rotate(start, around: center, -angle / 2.0)
        self.width = width
        update()
    }

    /// The arc from `start` to `end` through `angle` (KiCad's ConstructFromStartEndAngle)
    public init(start: IPoint, end: IPoint, angle: EDAAngle, width: Int = 0) {
        self.start = start
        self.end = end
        self.width = width
        // (the centre made whole as KiCad's VECTOR2I( VECTOR2D ) makes it: cut, not rounded)
        let c = KiMath.arcCenter(DPoint(start), DPoint(end), angle: angle).truncated
        mid = KiMath.rotate(start, around: c, -angle / 2.0)
        update()
    }

    public var description: String { "Arc(\(start) \(mid) \(end) w \(width))" }

    public static func == (a: ShapeArc, b: ShapeArc) -> Bool {
        a.start == b.start && a.end == b.end && a.mid == b.mid && a.width == b.width
    }

    public func hash(into h: inout Hasher) { h.combine(start); h.combine(mid); h.combine(end); h.combine(width) }

    private mutating func update() {
        center = KiMath.arcCenter(start, mid, end)
        radius = (DPoint(start) - DPoint(center)).squaredNorm.squareRoot()
        var points = [start, mid, end]
        var sa = startAngle
        var ea = sa + centralAngle
        if sa > ea { swap(&sa, &ea) }
        let quadStart = Int((sa.degrees / 90.0).rounded(.up))
        let quadEnd = Int((ea.degrees / 90.0).rounded(.down))
        // (a radius this big is all but a straight line, its centre too far to work with)
        if radius < Double(Int32.max) / 2.0 && quadStart <= quadEnd {
            let r = KiMath.round(radius)
            for q in quadStart...quadEnd {
                switch q % 4 {
                case 0: points.append(center + IPoint(r, 0))
                case 1, -3: points.append(center + IPoint(0, r))
                case 2, -2: points.append(center + IPoint(-r, 0))
                default: points.append(center + IPoint(0, -r))
                }
            }
        }
        var b = IBox(points[0], points[0])
        for p in points.dropFirst() { b.merge(p) }
        box = b
    }

    public var chord: Seg { Seg(start, end) }

    public var isCCW: Bool { (end - mid).cross(start - mid) > 0 }

    public var isClockwise: Bool { !isCCW }

    /// Its ends swapped, all else as it was, its centre and box too (KiCad's SHAPE_ARC::Reverse; `reversed` is
    /// KiCad's Reversed, which works them out again)
    public mutating func reverse() { swap(&start, &end) }

    public var startAngle: EDAAngle { EDAAngle(start - center).normalized }

    public var endAngle: EDAAngle { EDAAngle(end - center).normalized }

    /// How far round it turns, positive counter-clockwise; a full circle when its ends meet
    public var centralAngle: EDAAngle {
        if start == end { return .a360 }
        var angle = EDAAngle(end - center) - EDAAngle(start - center)
        if isCCW {
            if angle < .zero { angle += .a360 }
        } else if angle > .zero {
            angle -= .a360
        }
        return angle
    }

    public var length: Double { abs(radius * centralAngle.radians) }

    /// Its box, its width's half and a nanometre round it, and `clearance` more
    public func bbox(_ clearance: Int = 0) -> IBox {
        var b = box
        if width != 0 { b = b.inflated(KiMath.round(Double(width) / 2.0) + 1) }
        if clearance != 0 { b = b.inflated(clearance) }
        return b
    }

    public var reversed: ShapeArc { ShapeArc(start: end, mid: mid, end: start, width: width) }

    public func moved(_ d: IPoint) -> ShapeArc { ShapeArc(start: start + d, mid: mid + d, end: end + d, width: width) }

    /// Whether it is as good as straight (its two halves in line and the same way)
    public var isEffectiveLine: Bool {
        let v1 = Seg(start, mid), v2 = Seg(mid, end)
        return v1.approxCollinear(v2) && (v1.b - v1.a).dot(v2.b - v2.a) > 0
    }

    /// Whether the slice of the circle it spans, seen from its centre, takes in `p`
    func sliceContainsPoint(_ p: IPoint) -> Bool {
        let sa = startAngle.normalized
        let ca = centralAngle
        let ea = sa + ca
        var phi = EDAAngle(p - center).normalized
        if ca >= .zero {
            while phi < sa { phi += .a360 }
            return phi >= sa && phi <= ea
        }
        while phi > sa { phi -= .a360 }
        return phi <= sa && phi >= ea
    }

    private var hugeRadius: Bool { radius >= Double(Int32.max) / 2.0 }

    /// Where the line through `line` crosses it (SHAPE_ARC::IntersectLine): none for a line of one point or an arc as
    /// good as straight
    public func intersectLine(_ line: Seg) -> [IPoint] {
        if line.a == line.b || hugeRadius { return [] }
        return Circle(center, KiMath.cInt(radius)).intersectLine(line).filter { sliceContainsPoint($0) }
    }

    /// The point of it nearest `p`
    public func nearestPoint(_ p: IPoint) -> IPoint {
        let epsilon = 8
        let full = Circle(center, KiMath.cInt(radius))
        let n = full.nearestPoint(p)
        if (n - start).squaredNorm <= epsilon { return start }
        if (n - end).squaredNorm <= epsilon { return end }
        if sliceContainsPoint(n) { return n }
        return (p - start).squaredNorm <= (p - end).squaredNorm ? start : end
    }

    // MARK: - Collisions

    /// Whether `p` is within `clearance` of it (its width's half added), and how near: KiCad's
    /// SHAPE_ARC::Collide(VECTOR2I), which, unlike the others, counts exactly `clearance` away as touching
    public func collide(_ p: IPoint, clearance: Int, actual: inout Int?, location: inout IPoint?) -> Bool {
        let minDist = clearance + width / 2
        guard bbox(minDist).contains(p) else { return false }
        let r = (DPoint(center) - DPoint(start)).norm
        if r >= Double(Int32.max) / 2.0 {
            let s1 = Seg(start, mid), s2 = Seg(mid, end)
            let d1 = s1.distance(p), d2 = s2.distance(p)
            let d = min(d1, d2)
            guard d <= minDist else { return false }
            actual = max(0, d - width / 2)
            location = d1 <= d2 ? s1.nearestPoint(p) : s2.nearestPoint(p)
            return true
        }
        let full = Circle(center, KiMath.cInt(r))
        var nearest = full.nearestPoint(DPoint(p))
        var dist = KiMath.round(nearest.distance(p))
        let toPoint = EDAAngle(p - full.center)
        if dist == 0 {
            dist = KiMath.round(r - Double((p - center).squaredNorm).squareRoot())
            nearest = KiMath.rotate(DPoint(center + IPoint(KiMath.cInt(r), 0)), around: DPoint(center), -toPoint)
        }
        if start != end {
            let ccw = centralAngle > .zero
            let rotatedPt = (toPoint.normalized - startAngle).normalized
            let rotatedEnd = (endAngle - startAngle).normalized
            if (ccw && rotatedPt > rotatedEnd) || (!ccw && rotatedPt < rotatedEnd) {
                let ds = (p - start).norm, de = (p - end).norm
                if ds < de {
                    dist = ds
                    nearest = DPoint(start)
                } else {
                    dist = de
                    nearest = DPoint(end)
                }
            }
        }
        guard dist <= minDist else { return false }
        location = nearest.rounded
        actual = max(0, dist - width / 2)
        return true
    }

    /// Whether a segment comes within `clearance` of it (KiCad's SHAPE_ARC::Collide(SEG)): the points where the
    /// collision could be tried in turn. When `wantActual`, how near is the last of them that collides (KiCad's
    /// quirk), unless one touches.
    public func collide(_ s: Seg, clearance: Int, wantActual: Bool, actual: inout Int?, location: inout IPoint?) -> Bool {
        let r = (DPoint(center) - DPoint(start)).norm
        var candidates: [IPoint]
        if r >= Double(Int32.max) / 2.0 {
            let s1 = Seg(start, mid), s2 = Seg(mid, end)
            candidates = [s.nearestPoint(start), s.nearestPoint(mid), s.nearestPoint(end), s1.nearestPoint(s.a),
                          s1.nearestPoint(s.b), s2.nearestPoint(s.a), s2.nearestPoint(s.b), s.a, s.b]
        } else {
            let circle = Circle(center, KiMath.cInt(r))
            if centralAngle.degrees > 180.0 && (start - end).squaredNorm < clearance * clearance {
                // all but a full circle: a segment inside it, away from it, does not touch it
                let aSq = (s.a - center).squaredNorm, bSq = (s.b - center).squaredNorm
                let inner = KiMath.cInt(r - Double(clearance))
                if aSq < inner * inner && bSq < inner * inner { return false }
                var d: Int?
                guard Shape.circleSeg(center, circle.radius, s, clearance, &d) else { return false }
                actual = d
                location = s.nearestPoint(center)
                return true
            }
            candidates = circle.intersect(s)
            candidates += [s.nearestPoint(center), s.nearestPoint(start), s.nearestPoint(end), s.a, s.b]
        }
        var any = false
        for c in candidates {
            var a: Int?, l: IPoint?
            if collide(c, clearance: clearance, actual: &a, location: &l) {
                any = true
                actual = a
                location = l
                if !wantActual || a == 0 { return true }
            }
        }
        return any
    }

    /// The nearest points of it and a disc's rim, and the square of the distance between them, its width's half
    /// taken off (KiCad's SHAPE_ARC::NearestPoints(SHAPE_CIRCLE))
    func nearestPoints(circle c: IPoint, _ cr: Int) -> (IPoint, IPoint, Int) {
        if center == c && radius == Double(cr) { return (start, start, 0) }
        var distSq = Int.max
        var ptA = IPoint.zero, ptB = IPoint.zero
        let c1 = Circle(center, KiMath.cInt(radius)), c2 = Circle(c, cr)
        for p in c1.intersect(c2) where sliceContainsPoint(p) { return (p, p, 0) }
        for p in [start, end, c1.nearestPoint(c)] where sliceContainsPoint(p) {
            let n = c2.nearestPoint(p)
            let d = p.squaredDistance(n)
            if d < distSq {
                distSq = d
                ptA = p
                ptB = n
            }
        }
        return widthAdjusted(ptA, ptB, distSq)
    }

    /// Point A moved half its width towards B, and the distance squared again (none if within that half)
    private func widthAdjusted(_ a: IPoint, _ b: IPoint, _ distSq: Int) -> (IPoint, IPoint, Int) {
        let ptA = a + (b - a).resized(width / 2)
        let half = width / 2
        return (ptA, b, distSq < half * half ? 0 : ptA.squaredDistance(b))
    }

    /// The nearest points of it and a segment (KiCad's SHAPE_ARC::NearestPoints(SEG))
    func nearestPoints(_ s: Seg) -> (IPoint, IPoint, Int) {
        var distSq = Int.max
        var ptA = IPoint.zero, ptB = IPoint.zero
        let circle = Circle(center, KiMath.cInt(radius))
        for p in circle.intersect(s) where sliceContainsPoint(p) { return (p, p, 0) }
        for p in [s.a, s.b] where sliceContainsPoint(p) {
            let n = circle.nearestPoint(p)
            let d = p.squaredDistance(n)
            if d < distSq {
                distSq = d
                ptA = n
                ptB = p
            }
        }
        for p in [start, end] {
            let n = s.nearestPoint(p)
            let d = p.squaredDistance(n)
            if d < distSq {
                distSq = d
                ptA = p
                ptB = n
            }
        }
        let sn = s.nearestPoint(center)
        if sliceContainsPoint(sn) {
            let cn = circle.nearestPoint(sn)
            let d = sn.squaredDistance(cn)
            if d < distSq {
                distSq = d
                ptA = sn
                ptB = cn
            }
        }
        return widthAdjusted(ptA, ptB, distSq)
    }

    /// The nearest points of it and an upright rectangle's outline (KiCad's SHAPE_ARC::NearestPoints(SHAPE_RECT))
    func nearestPoints(rect b: IBox) -> (IPoint, IPoint, Int) {
        let outline = Shape.rectOutline(b)
        var minDistSq = Int.max
        var ptA = IPoint.zero, ptB = IPoint.zero
        for i in 0..<outline.segmentCount {
            let (onArc, onSeg, d) = nearestPoints(outline.segment(i))
            if d < minDistSq {
                minDistSq = d
                ptA = onArc
                ptB = onSeg
            }
        }
        return (ptA, ptB, ptA.squaredDistance(ptB))
    }

    /// The nearest points of two arcs (KiCad's SHAPE_ARC::NearestPoints(SHAPE_ARC))
    func nearestPoints(_ o: ShapeArc) -> (IPoint, IPoint, Int) {
        var distSq = Int.max
        var ptA = IPoint.zero, ptB = IPoint.zero
        func adjusted() -> (IPoint, IPoint, Int) {
            let a = ptA + (ptB - ptA).resized(width / 2)
            let b = ptB + (a - ptB).resized(o.width / 2)
            let half = width / 2 + o.width / 2
            return (a, b, distSq < half * half ? 0 : a.squaredDistance(b))
        }
        let c1 = center, c2 = o.center
        let centerDistSq = c1.squaredDistance(c2)
        let eps = KiMath.round(min(radius, o.radius) / 1000)
        let colocated = centerDistSq < eps * eps
        for p1 in [start, end] {
            for p2 in [o.start, o.end] {
                let d = p1.squaredDistance(p2)
                if d < distSq {
                    distSq = d
                    ptA = p1
                    ptB = p2
                    if distSq == 0 { return (ptA, ptB, 0) }
                }
            }
        }
        for p in [start, end] where o.sliceContainsPoint(p) {
            ptA = p
            ptB = Circle(c2, KiMath.cInt(o.radius)).nearestPoint(p)
            distSq = ptA.squaredDistance(ptB)
            if colocated || distSq == 0 { return distSq != 0 ? adjusted() : (ptA, ptB, distSq) }
        }
        for p in [o.start, o.end] where sliceContainsPoint(p) {
            ptA = Circle(c1, KiMath.cInt(radius)).nearestPoint(p)
            ptB = p
            distSq = ptA.squaredDistance(ptB)
            if colocated || distSq == 0 { return distSq != 0 ? adjusted() : (ptA, ptB, distSq) }
        }
        if colocated { return (ptA, ptB, distSq) }
        let circle1 = Circle(c1, KiMath.cInt(radius)), circle2 = Circle(c2, KiMath.cInt(o.radius))
        for p in circle1.intersect(circle2) where sliceContainsPoint(p) && o.sliceContainsPoint(p) { return (p, p, 0) }
        let r1 = radius, r2 = o.radius
        let contained = Double(centerDistSq) < (r1 - r2) * (r1 - r2)
        let pt1: IPoint, pt2: IPoint
        if contained && r1 > r2 {
            pt1 = circle1.nearestPoint(c2)
            pt2 = circle2.furthestPoint(c1)
        } else if contained {
            pt1 = circle1.furthestPoint(c2)
            pt2 = circle2.nearestPoint(c1)
        } else {
            pt1 = circle1.nearestPoint(c2)
            pt2 = circle2.nearestPoint(c1)
        }
        let in1 = sliceContainsPoint(pt1), in2 = o.sliceContainsPoint(pt2)
        if in1 && in2 {
            let d = pt1.squaredDistance(pt2)
            if d < distSq {
                distSq = d
                ptA = pt1
                ptB = pt2
            }
            return adjusted()
        }
        if in2 {
            for p in [start, end] {
                let d = p.squaredDistance(pt2)
                if d < distSq {
                    distSq = d
                    ptA = p
                    ptB = pt2
                }
            }
        }
        if in1 {
            for p in [o.start, o.end] {
                let d = p.squaredDistance(pt1)
                if d < distSq {
                    distSq = d
                    ptA = pt1
                    ptB = p
                }
            }
        }
        return adjusted()
    }

    // MARK: - As segments

    /// The arc as a polyline no further than `maxError` from it, its ends on it (KiCad's ConvertToPolyline)
    public func convertToPolyline(_ maxError: Int = 5000) -> LineChain {
        var r = radius
        let sa = startAngle
        let c = center
        let ca = centralAngle
        let halfMaxError = max(1.0, Double(maxError) / 2.0)
        let external = r + Double(width) / 2.0
        var n: Int
        let effectiveError: Double
        if external < halfMaxError || Double(chord.distance(mid)) < halfMaxError {
            n = 0
            effectiveError = external
        } else {
            n = KiMath.arcToSegmentCount(KiMath.cInt(external), maxError, ca)
            let seg360 = KiMath.cInt(Double(n) * 360.0 / abs(ca.degrees))
            effectiveError = Double(KiMath.circleToEndSegmentDeltaRadius(KiMath.cInt(external), seg360))
        }
        r += effectiveError / 2
        n *= 2
        var out = LineChain()
        out.append(start)
        var i = 1
        while i < n {
            var a = sa
            if n != 0 { a += (ca * Double(i)) / Double(n) }
            out.append(KiMath.round(Double(c.x) + r * a.cos), KiMath.round(Double(c.y) + r * a.sin))
            i += 2
        }
        out.append(end)
        return out
    }

    /// KiCad's ArcHull: the walkaround hull round an arc, its outline followed out and back at `clearance` and half
    /// the walking trace's width (a circle's, for an arc nearly closed)
    public func hull(clearance: Int, walkaroundThickness: Int) -> LineChain {
        let cl = clearance + (walkaroundThickness + 1) / 2
        if centralAngle.degrees > 180.0 && chord.length < cl {
            let r = KiMath.cInt(radius)
            return Shape.octagonalHull(center - IPoint(r, r), IPoint(2 * r, 2 * r), cl,
                                       KiMath.cInt(2.0 * (1.0 - 0.5.squareRoot()) * Double(r + cl)))
        }
        let d = width / 2 + cl + 5000
        let x = KiMath.cInt(2.0 / (1.0 + 2.0.squareRoot()) * Double(d)) / 2
        let line = convertToPolyline(20000)
        var s = LineChain()
        s.setClosed(true)
        var reverseLine: [IPoint] = []
        var seg = line.segment(0)
        var dir = seg.b - seg.a
        var p0 = -dir.perpendicular.resized(d)
        var ds = -dir.perpendicular.resized(x)
        var pd = dir.resized(x)
        var dp = dir.resized(d)
        s.append(seg.a + p0 - pd)
        s.append(seg.a - dp + ds)
        s.append(seg.a - dp - ds)
        s.append(seg.a - p0 - pd)
        if line.segmentCount > 1 {
            for i in 1..<line.segmentCount {
                let pp = (line.segment(i - 1).b - line.segment(i - 1).a).perpendicular.resized(d)
                let pp2 = (line.segment(i).b - line.segment(i).a).perpendicular.resized(d)
                let saOut = Seg(line.segment(i - 1).a + pp, line.segment(i - 1).b + pp)
                let saIn = Seg(line.segment(i - 1).a - pp, line.segment(i - 1).b - pp)
                let sbOut = Seg(line.segment(i).a + pp2, line.segment(i).b + pp2)
                let sbIn = Seg(line.segment(i).a - pp2, line.segment(i).b - pp2)
                // (KiCad takes these as there: the segments of an arc's polyline always turn)
                s.append(saOut.intersectLines(sbOut) ?? saOut.b)
                reverseLine.append(saIn.intersectLines(sbIn) ?? saIn.b)
            }
        }
        seg = line.segment(-1)
        dir = seg.b - seg.a
        p0 = -dir.perpendicular.resized(d)
        ds = -dir.perpendicular.resized(x)
        pd = dir.resized(x)
        dp = dir.resized(d)
        s.append(seg.b - p0 + pd)
        s.append(seg.b + dp - ds)
        s.append(seg.b + dp + ds)
        s.append(seg.b + p0 + pd)
        for p in reverseLine.reversed() { s.append(p) }
        return s.segment(0).side(line.segment(0).a) < 0 ? s.reversed() : s
    }
}
