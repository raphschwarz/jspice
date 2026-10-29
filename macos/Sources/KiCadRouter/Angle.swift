// Ported from KiCad 10.0.7: libs/kimath/include/geometry/eda_angle.h, libs/kimath/include/math/vector2d.h (VECTOR2D),
// libs/kimath/src/trigo.cpp (RotatePoint, CalcArcCenter, CalcArcMid), libs/kimath/src/geometry/circle.cpp and
// libs/kimath/src/geometry/geometry_utils.cpp (GetArcToSegmentCount, CircleToEndSegmentDeltaRadius).
// Copyright (C) 2013-2017 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// An angle in degrees (KiCad's EDA_ANGLE): exact along the axes and the diagonals, where its sine and cosine are too
public struct EDAAngle: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var degrees: Double

    public init(degrees: Double) { self.degrees = degrees }

    public init(radians: Double) { degrees = radians / EDAAngle.degreesToRadians }

    /// The direction of a vector
    public init(_ v: DPoint) {
        let x = v.x, y = v.y
        if x == 0 && y == 0 {
            degrees = 0
        } else if y == 0 {
            degrees = x >= 0 ? 0 : -180
        } else if x == 0 {
            degrees = y >= 0 ? 90 : -90
        } else if x == y {
            degrees = x >= 0 ? 45 : -180 + 45
        } else if x == -y {
            degrees = x >= 0 ? -45 : 180 - 45
        } else {
            degrees = atan2(y, x) / EDAAngle.degreesToRadians
        }
    }

    public init(_ v: IPoint) { self.init(DPoint(v)) }

    public static let degreesToRadians = Double.pi / 180.0

    public static let zero = EDAAngle(degrees: 0)
    public static let a45 = EDAAngle(degrees: 45)
    public static let a90 = EDAAngle(degrees: 90)
    public static let a135 = EDAAngle(degrees: 135)
    public static let a180 = EDAAngle(degrees: 180)
    public static let a270 = EDAAngle(degrees: 270)
    public static let a360 = EDAAngle(degrees: 360)

    public var description: String { "\(degrees)°" }

    public var radians: Double { degrees * EDAAngle.degreesToRadians }

    /// From 0 up to 360
    public var normalized: EDAAngle {
        var d = degrees
        while d < -0.0 { d += 360 }
        while d >= 360 { d -= 360 }
        return EDAAngle(degrees: d)
    }

    /// Above -180, up to 180
    public var normalized180: EDAAngle {
        var d = degrees
        while d <= -180 { d += 360 }
        while d > 180 { d -= 360 }
        return EDAAngle(degrees: d)
    }

    public var normalized90: EDAAngle {
        var d = degrees
        while d < -90 { d += 180 }
        while d > 90 { d -= 180 }
        return EDAAngle(degrees: d)
    }

    /// Above -360, up to 0
    public var normalizedNegative: EDAAngle {
        var d = degrees
        while d <= -360 { d += 360 }
        while d > 0 { d -= 360 }
        return EDAAngle(degrees: d)
    }

    public var normalized720: EDAAngle {
        var d = degrees
        while d < -360 { d += 360 }
        while d >= 360 { d -= 360 }
        return EDAAngle(degrees: d)
    }

    public var sin: Double {
        switch normalized.degrees {
        case 0, 180: return 0
        case 45, 135: return 0.5.squareRoot()
        case 225, 315: return -(0.5.squareRoot())
        case 90: return 1
        case 270: return -1
        default: return Foundation.sin(radians)
        }
    }

    public var cos: Double {
        switch normalized.degrees {
        case 0: return 1
        case 180: return -1
        case 90, 270: return 0
        case 45, 315: return 0.5.squareRoot()
        case 135, 225: return -(0.5.squareRoot())
        default: return Foundation.cos(radians)
        }
    }

    public static func + (a: EDAAngle, b: EDAAngle) -> EDAAngle { EDAAngle(degrees: a.degrees + b.degrees) }
    public static func - (a: EDAAngle, b: EDAAngle) -> EDAAngle { EDAAngle(degrees: a.degrees - b.degrees) }
    public static prefix func - (a: EDAAngle) -> EDAAngle { EDAAngle(degrees: -a.degrees) }
    public static func * (a: EDAAngle, k: Double) -> EDAAngle { EDAAngle(degrees: a.degrees * k) }
    public static func / (a: EDAAngle, k: Double) -> EDAAngle { EDAAngle(degrees: a.degrees / k) }
    public static func / (a: EDAAngle, b: EDAAngle) -> Double { a.degrees / b.degrees }
    public static func += (a: inout EDAAngle, b: EDAAngle) { a = a + b }
    public static func -= (a: inout EDAAngle, b: EDAAngle) { a = a - b }
    public static func < (a: EDAAngle, b: EDAAngle) -> Bool { a.degrees < b.degrees }
    public static func == (a: EDAAngle, b: EDAAngle) -> Bool { a.degrees == b.degrees }
    public func hash(into h: inout Hasher) { h.combine(degrees) }

    public var magnitude: EDAAngle { EDAAngle(degrees: abs(degrees)) }
}

/// A point or vector in fractions of nanometres (KiCad's VECTOR2D)
public struct DPoint: Hashable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public init(_ p: IPoint) { x = Double(p.x); y = Double(p.y) }

    public var description: String { "(\(x), \(y))" }

    public static func + (a: DPoint, b: DPoint) -> DPoint { DPoint(a.x + b.x, a.y + b.y) }
    public static func - (a: DPoint, b: DPoint) -> DPoint { DPoint(a.x - b.x, a.y - b.y) }
    public static prefix func - (a: DPoint) -> DPoint { DPoint(-a.x, -a.y) }
    public static func * (a: DPoint, k: Double) -> DPoint { DPoint(a.x * k, a.y * k) }
    public static func / (a: DPoint, k: Double) -> DPoint { DPoint(a.x / k, a.y / k) }

    /// Each coordinate rounded as KiCad's KiROUND rounds it
    public var rounded: IPoint { IPoint(KiMath.round(x), KiMath.round(y)) }

    /// Each coordinate cut to a whole number, kept inside what an int holds (KiCad's VECTOR2I( VECTOR2D ))
    public var truncated: IPoint {
        func t(_ v: Double) -> Int { v.isNaN ? Int(Int32.min) : Int(min(max(v, Double(Int32.min)), Double(Int32.max))) }
        return IPoint(t(x), t(y))
    }

    public var squaredNorm: Double { x * x + y * y }

    /// The vector turned a quarter turn (KiCad's Perpendicular)
    public var perpendicular: DPoint { DPoint(-y, x) }

    /// KiCad's EuclideanNorm for a VECTOR2D: exact on the axes, the diagonals by √2
    public var norm: Double {
        if abs(x) == abs(y) { return abs(x) * 2.0.squareRoot() }
        if x == 0 { return abs(y) }
        if y == 0 { return abs(x) }
        return hypot(x, y)
    }

    /// KiCad's Resize for a VECTOR2D
    public func resized(_ length: Double) -> DPoint {
        if x == 0 && y == 0 { return DPoint(0, 0) }
        var nx: Double, ny: Double
        if abs(x) == abs(y) {
            nx = abs(length) * 0.5.squareRoot()
            ny = nx
        } else {
            let xsq = x * x, ysq = y * y
            let lsq = xsq + ysq
            let nlsq = length * length
            nx = (nlsq * xsq / lsq).squareRoot()
            ny = (nlsq * ysq / lsq).squareRoot()
        }
        let s = Double(length > 0 ? 1 : length < 0 ? -1 : 0)
        return DPoint((x < 0 ? -nx : nx) * s, (y < 0 ? -ny : ny) * s)
    }

    /// KiCad's VECTOR2D::Distance to a whole point: the norm of the difference, in doubles
    public func distance(_ p: IPoint) -> Double { DPoint(Double(p.x) - x, Double(p.y) - y).norm }
}

extension IPoint {
    /// KiCad's VECTOR2I::Distance: the norm of the difference, in doubles
    public func distance(_ p: IPoint) -> Double { DPoint(Double(p.x - x), Double(p.y - y)).norm }
}

extension KiMath {
    /// KiCad's RotatePoint of a whole point about the origin by an angle
    public static func rotate(_ p: IPoint, _ angle: EDAAngle) -> IPoint {
        let a = angle.normalized
        switch a.degrees {
        case 0: return p
        case 90: return IPoint(p.y, -p.x)
        case 180: return IPoint(-p.x, -p.y)
        case 270: return IPoint(-p.y, p.x)
        default:
            let s = a.sin, c = a.cos
            return IPoint(round(Double(p.y) * s + Double(p.x) * c), round(Double(p.y) * c - Double(p.x) * s))
        }
    }

    public static func rotate(_ p: IPoint, around c: IPoint, _ angle: EDAAngle) -> IPoint { rotate(p - c, angle) + c }

    /// KiCad's RotatePoint of a point in doubles
    public static func rotate(_ p: DPoint, _ angle: EDAAngle) -> DPoint {
        let a = angle.normalized
        switch a.degrees {
        case 0: return p
        case 90: return DPoint(p.y, -p.x)
        case 180: return DPoint(-p.x, -p.y)
        case 270: return DPoint(-p.y, p.x)
        default:
            let s = a.sin, c = a.cos
            return DPoint(p.y * s + p.x * c, p.y * c - p.x * s)
        }
    }

    public static func rotate(_ p: DPoint, around c: DPoint, _ angle: EDAAngle) -> DPoint { rotate(p - c, angle) + c }

    /// KiCad's CalcArcCenter of three points on the arc, in doubles: round numbers (to a hundred or ten
    /// nanometres) taken where they are within what rounding the points could have done
    public static func arcCenter(_ start: DPoint, _ mid: DPoint, _ end: DPoint) -> DPoint {
        let coincident = 5.0
        let minX = Swift.min(start.x, mid.x, end.x), maxX = Swift.max(start.x, mid.x, end.x)
        let minY = Swift.min(start.y, mid.y, end.y), maxY = Swift.max(start.y, mid.y, end.y)
        if maxX - minX < coincident && maxY - minY < coincident {
            return DPoint((start.x + mid.x + end.x) / 3.0, (start.y + mid.y + end.y) / 3.0)
        }
        let yDelta21 = mid.y - start.y
        var xDelta21 = mid.x - start.x
        let yDelta32 = end.y - mid.y
        var xDelta32 = end.x - mid.x
        if (xDelta21 == 0 && yDelta32 == 0) || (yDelta21 == 0 && xDelta32 == 0) {
            return DPoint((start.x + end.x) / 2.0, (start.y + end.y) / 2.0)
        }
        if xDelta21 == 0 { xDelta21 = Double.ulpOfOne }
        if xDelta32 == 0 { xDelta32 = -Double.ulpOfOne }
        var aSlope = yDelta21 / xDelta21
        var bSlope = yDelta32 / xDelta32
        let daSlope = aSlope * DPoint(0.5 / yDelta21, 0.5 / xDelta21).norm
        let dbSlope = bSlope * DPoint(0.5 / yDelta32, 0.5 / xDelta32).norm
        if aSlope == bSlope {
            if start == end {
                // a full circle: the centre is half way to the middle point
                return DPoint((start.x + mid.x) / 2.0, (start.y + mid.y) / 2.0)
            }
            aSlope += Double.ulpOfOne
            bSlope -= Double.ulpOfOne
        }
        if aSlope == 0 { aSlope = 1e-10 }
        if bSlope == 0 { bSlope = 1e-10 }
        let half = 0.5.squareRoot()
        let abSlopeStartEndY = aSlope * bSlope * (start.y - end.y)
        let dabSlopeStartEndY = abSlopeStartEndY * ((daSlope / aSlope * daSlope / aSlope) + (dbSlope / bSlope * dbSlope / bSlope)
            + (half / (start.y - end.y) * half / (start.y - end.y))).squareRoot()
        let bSlopeStartMidX = bSlope * (start.x + mid.x)
        let dbSlopeStartMidX = bSlopeStartMidX * ((dbSlope / bSlope * dbSlope / bSlope)
            + (half / (start.x + mid.x) * half / (start.x + mid.x))).squareRoot()
        let aSlopeMidEndX = aSlope * (mid.x + end.x)
        let daSlopeMidEndX = aSlopeMidEndX * ((daSlope / aSlope * daSlope / aSlope)
            + (half / (mid.x + end.x) * half / (mid.x + end.x))).squareRoot()
        let twiceBASlopeDiff = 2 * (bSlope - aSlope)
        let dtwiceBASlopeDiff = 2 * (dbSlope * dbSlope + daSlope * daSlope).squareRoot()
        let centerNumeratorX = abSlopeStartEndY + bSlopeStartMidX - aSlopeMidEndX
        let dCenterNumeratorX = (dabSlopeStartEndY * dabSlopeStartEndY + dbSlopeStartMidX * dbSlopeStartMidX
            + daSlopeMidEndX * daSlopeMidEndX).squareRoot()
        let centerX = (abSlopeStartEndY + bSlopeStartMidX - aSlopeMidEndX) / twiceBASlopeDiff
        let dCenterX = centerX * ((dCenterNumeratorX / centerNumeratorX * dCenterNumeratorX / centerNumeratorX)
            + (dtwiceBASlopeDiff / twiceBASlopeDiff * dtwiceBASlopeDiff / twiceBASlopeDiff)).squareRoot()
        let centerNumeratorY = (start.x + mid.x) / 2.0 - centerX
        let dCenterNumeratorY = (1.0 / 8.0 + dCenterX * dCenterX).squareRoot()
        let centerFirstTerm = centerNumeratorY / aSlope
        let dcenterFirstTermY = centerFirstTerm * ((dCenterNumeratorY / centerNumeratorY * dCenterNumeratorY / centerNumeratorY)
            + (daSlope / aSlope * daSlope / aSlope)).squareRoot()
        let centerY = centerFirstTerm + (start.y + mid.y) / 2.0
        let dCenterY = (dcenterFirstTermY * dcenterFirstTermY + 1.0 / 8.0).squareRoot()
        let rounded100X = ((centerX + 50.0) / 100.0).rounded(.down) * 100.0
        let rounded100Y = ((centerY + 50.0) / 100.0).rounded(.down) * 100.0
        let rounded10X = ((centerX + 5.0) / 10.0).rounded(.down) * 10.0
        let rounded10Y = ((centerY + 5.0) / 10.0).rounded(.down) * 10.0
        if abs(rounded100X - centerX) < dCenterX && abs(rounded100Y - centerY) < dCenterY {
            return DPoint(rounded100X, rounded100Y)
        }
        if abs(rounded10X - centerX) < dCenterX && abs(rounded10Y - centerY) < dCenterY {
            return DPoint(rounded10X, rounded10Y)
        }
        return DPoint(centerX, centerY)
    }

    /// KiCad's CalcArcCenter of three whole points, rounded (and kept inside what an int holds)
    public static func arcCenter(_ start: IPoint, _ mid: IPoint, _ end: IPoint) -> IPoint {
        let c = arcCenter(DPoint(start), DPoint(mid), DPoint(end))
        let lo = Double(Int32.min) + 100, hi = Double(Int32.max) - 100
        return IPoint(round(Swift.min(Swift.max(c.x, lo), hi)), round(Swift.min(Swift.max(c.y, lo), hi)))
    }

    /// KiCad's CalcArcCenter of an arc's ends and its angle
    public static func arcCenter(_ start: DPoint, _ end: DPoint, angle: EDAAngle) -> DPoint {
        var angle = angle
        var (s, e) = (start, end)
        if angle < .zero {
            swap(&s, &e)
            angle = -angle
        }
        if angle > .a180 {
            swap(&s, &e)
            angle = .a360 - angle
        }
        let chord = (s - e).norm
        let r = (chord / 2.0) / (angle / 2.0).sin
        let dsq = r * r - chord * chord / 4.0
        let d = dsq > 0 ? dsq.squareRoot() : 0
        var vec2 = (e - s).resized(d)
        let vc = (e - s).resized(chord / 2)
        vec2 = rotate(vec2, -EDAAngle.a90)
        return s + vc + vec2
    }

    /// KiCad's CalcArcMid: the middle of the arc from `start` to `end` about `center`, the shorter way round or not
    public static func arcMid(_ start: IPoint, _ end: IPoint, _ center: IPoint, minArcAngle: Bool = true) -> IPoint {
        var rot = (EDAAngle(start - center) - EDAAngle(end - center)).normalized180 / 2
        if !minArcAngle { rot += .a180 }
        return rotate(start, around: center, rot)
    }

    /// KiCad's GetArcToSegmentCount: how many segments an arc of `radius` through `angle` is made of so that none
    /// is further than `maxError` from it (at least two; a full circle at least eight)
    public static func arcToSegmentCount(_ radius: Int, _ maxError: Int, _ angle: EDAAngle) -> Int {
        let r = Swift.max(1, radius), e = Swift.max(1, maxError)
        let relError = Double(e) / Double(r)
        var increment = 180 / Double.pi * acos(1.0 - relError) * 2
        increment = Swift.min(360.0 / 8, increment)
        let count = round(abs(angle.degrees) / increment)
        return Swift.max(count, 2)
    }

    /// KiCad's CircleToEndSegmentDeltaRadius: how much further out than `radius` the ends of a circle's
    /// `segCount` segments are when their middles touch it
    public static func circleToEndSegmentDeltaRadius(_ radius: Int, _ segCount: Int) -> Int {
        let n = segCount <= 2 ? 3 : segCount
        let alpha = Double.pi / Double(n)
        return round(abs(Double(radius) * (1 - 1 / Foundation.cos(alpha))))
    }
}

/// A full circle (KiCad's CIRCLE), its radius whole
public struct Circle: Hashable, Sendable {
    public var center: IPoint
    public var radius: Int

    public init(_ center: IPoint, _ radius: Int) { self.center = center; self.radius = radius }

    /// How near a point must be to the circle to be on it (KiCad's SHAPE::MIN_PRECISION_IU)
    public static let minPrecision = 4

    public func nearestPoint(_ p: IPoint) -> IPoint {
        var v = p - center
        if v.x == 0 && v.y == 0 { v.x = 1 }
        return v.resized(radius) + center
    }

    public func nearestPoint(_ p: DPoint) -> DPoint {
        var v = p - DPoint(center)
        if v.x == 0 && v.y == 0 { v.x = 1 }
        return v.resized(Double(radius)) + DPoint(center)
    }

    public func furthestPoint(_ p: IPoint) -> IPoint {
        var v = center - p
        if v.x == 0 && v.y == 0 { v.x = 1 }
        return v.resized(radius) + center
    }

    /// Whether `p` is on the circle, to within its precision
    public func contains(_ p: IPoint) -> Bool {
        let d = (p - center).norm
        return d <= radius + Circle.minPrecision && d >= radius - Circle.minPrecision
    }

    /// Where it crosses another circle
    public func intersect(_ o: Circle) -> [IPoint] {
        let cc = o.center - center
        let d = cc.norm
        let r1 = radius, r2 = o.radius
        if d > r1 + r2 || d < abs(r1 - r2) { return [] }
        if d == 0 { return [] }
        let x = (d * d + r1 * r1 - r2 * r2) / (2 * d)
        let r1sqMinusXsq = r1 * r1 - x * x
        if r1sqMinusXsq < 0 { return [] }
        let y = KiMath.round(Double(r1sqMinusXsq).squareRoot())
        let rot = EDAAngle(cc)
        var out = [KiMath.rotate(IPoint(x, y), -rot) + center]
        if y != 0 { out.append(KiMath.rotate(IPoint(x, -y), -rot) + center) }
        return out
    }

    /// Where it crosses a segment
    public func intersect(_ s: Seg) -> [IPoint] { intersectLine(s).filter { s.contains($0) } }

    /// The circle tangent to the lines through `lineA` and `lineB` that passes through `p`, the one that fillets the
    /// two (KiCad's CIRCLE::ConstructFromTanTanPt, by homothety; between parallel lines, the one whose centre is
    /// nearer `lineA`'s start). Where KiCad finds no solution it leaves the circle as far as it got.
    public mutating func constructFromTanTanPt(_ lineA: Seg, _ lineB: Seg, _ p: IPoint) {
        var intersectPoint = IPoint.zero
        func furthestFromIntersect(_ a: IPoint, _ b: IPoint) -> IPoint {
            (a - intersectPoint).norm > (b - intersectPoint).norm ? a : b
        }
        func closestToIntersect(_ a: IPoint, _ b: IPoint) -> IPoint {
            (a - intersectPoint).norm <= (b - intersectPoint).norm ? a : b
        }
        if lineA.approxParallel(lineB) {
            // no intersection: the centre on the line halfway between them, the radius half the distance between
            let perpendicularAtoB = Seg(lineA.a, lineB.lineProject(lineA.a))
            let midPt = perpendicularAtoB.center
            radius = (midPt - lineA.a).norm
            let anglebisector = lineA.parallelSeg(midPt)
            // (this circle about the point, to find the centres where it crosses that line)
            center = p
            let possibleCenters = intersectLine(anglebisector)
            guard let first = possibleCenters.first, let last = possibleCenters.last else { return }
            intersectPoint = lineA.a
            center = closestToIntersect(first, last)
            return
        }
        // all circles in the angle are homothetic about the lines' intersection
        guard let ip = lineA.intersectLines(lineB) else { return }
        intersectPoint = ip
        if p == intersectPoint {
            center = p
            radius = 0
            return
        }
        let lineApt = furthestFromIntersect(lineA.a, lineA.b)
        let lineBpt = furthestFromIntersect(lineB.a, lineB.b)
        let anglebisector = Seg(intersectPoint, KiMath.arcMid(lineApt, lineBpt, intersectPoint, minArcAngle: true))
        // a circle tangent to both, and the image of the point on it
        var hSolution = Circle(anglebisector.lineProject(p), 0)
        hSolution.radius = lineA.lineDistance(hSolution.center)
        let hProjections = hSolution.intersectLine(Seg(intersectPoint, p))
        guard let hFirst = hProjections.first, let hLast = hProjections.last else { return }
        // (the one nearer the intersection, for a fillet)
        let hSelected = closestToIntersect(hFirst, hLast)
        let hTanLineA = lineA.lineProject(hSolution.center)
        let hTanLineB = lineB.lineProject(hSolution.center)
        // the tangent point taken back from the image, on the line whose tangent is further from the point
        if (hTanLineA - p).squaredNorm > (hTanLineB - p).squaredNorm {
            guard let actTanA = Seg(hTanLineA, hSelected).parallelSeg(p).intersectLines(lineA),
                  let actCenter = lineA.perpendicularSeg(actTanA).intersectLines(anglebisector) else { return }
            center = actCenter
            radius = lineA.lineDistance(center)
        } else {
            guard let actTanB = Seg(hTanLineB, hSelected).parallelSeg(p).intersectLines(lineB),
                  let actCenter = lineB.perpendicularSeg(actTanB).intersectLines(anglebisector) else { return }
            center = actCenter
            radius = lineB.lineDistance(center)
        }
    }

    /// Where it crosses the line through a segment
    public func intersectLine(_ line: Seg) -> [IPoint] {
        let m = line.lineProject(center)
        let om = (m - center).norm
        if om > radius + Circle.minPrecision { return [] }
        if om >= radius - Circle.minPrecision { return [m] }
        let mTo1 = KiMath.cInt((Double(radius * radius - om * om)).squareRoot())
        let v = (line.b - line.a).resized(mTo1)
        // (VECTOR2I sums, wrapping round as KiCad's do where they leave 32 bits)
        return [(v + m).wrapped32, (-v + m).wrapped32]
    }
}
