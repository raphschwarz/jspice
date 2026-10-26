// Ported from KiCad 10.0.7: libs/kimath/src/convert_basic_shapes_to_polygon.cpp (rectangles with rounded or cut
// corners, trapezoids, circles, rings, segments with round ends and arcs of some width as polygons, and arcs as
// polylines), libs/kimath/src/geometry/arc_chord_params.cpp and include/geometry/arc_chord_params.h, libs/kimath/src/
// geometry/seg.cpp (ReflectPoint) and libs/kimath/src/geometry/geometry_utils.cpp (GetCircleToPolyCorrection).
// Copyright (C) 2018 Jean-Pierre Charras; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// Which side of a curve the error of its polygon falls: inside it (the polygon no bigger), or outside (no smaller)
public enum ErrorLocation: Sendable {
    case inside
    case outside
}

extension Seg {
    /// The point mirrored in the line through the segment (KiCad's SEG::ReflectPoint)
    public func reflectPoint(_ p: IPoint) -> IPoint {
        let d = b - a
        let lsq = d.dot(d)
        let t = d.dot(p - a)
        let c = lsq == 0 ? p : IPoint(a.x + KiMath.rescale(t, d.x, lsq), a.y + KiMath.rescale(t, d.y, lsq))
        return IPoint(2 * c.x - p.x, 2 * c.y - p.y)
    }
}

/// KiCad's polygons for a pad's shapes, as its router and its zone filler see them
public enum PadPolygon {
    /// A corner of a convex outline, rounded to `radius` (KiCad's ROUNDED_CORNER)
    struct Corner {
        var position: IPoint
        var radius: Int
        init(_ x: Int, _ y: Int, _ radius: Int = 0) { position = IPoint(x, y); self.radius = radius }
    }

    /// Bits of the corners to cut (KiCad's RECT_CHAMFER_POSITIONS)
    public static let chamferTopLeft = 1, chamferTopRight = 2, chamferBottomLeft = 4, chamferBottomRight = 8

    /// A convex outline's corners (clockwise, none twice) as a polygon, each rounded to its radius and the whole
    /// grown by `inflate`, its arcs made of segments no further than `maxError` from them (KiCad's
    /// CornerListToPolygon)
    static func cornerList(_ corners: [Corner], inflate: Int, maxError: Int, errorLocation: ErrorLocation) -> LineChain {
        var outline = LineChain()
        outline.setClosed(true)
        var incoming = corners[0].position - corners[corners.count - 1].position
        for n in 0..<corners.count {
            let cur = corners[n], next = corners[(n + 1) % corners.count]
            let outgoing = next.position - cur.position
            if inflate == 0 && cur.radius == 0 {
                outline.append(cur.position)
            } else {
                var cornerPosition = cur.position
                var radius = cur.radius
                var endAngle: EDAAngle
                let tanAngle2: Double
                if (incoming.x == 0 && outgoing.y == 0) || (incoming.y == 0 && outgoing.x == 0) {
                    endAngle = .a90
                    tanAngle2 = 1.0
                } else {
                    let cosNum = Double(incoming.x) * Double(outgoing.x) + Double(incoming.y) * Double(outgoing.y)
                    let cosDen = Double(incoming.norm) * Double(outgoing.norm)
                    let angle = acos(cosNum / cosDen)
                    tanAngle2 = tan((Double.pi - angle) / 2)
                    endAngle = EDAAngle(radians: angle)
                }
                if inflate != 0 && tanAngle2 != 0 {
                    radius += inflate
                    cornerPosition += incoming.resized(KiMath.cInt(Double(inflate) / tanAngle2)) + incoming.perpendicular.resized(-inflate)
                }
                // at least sixteen segments to a circle, the first and last the same size
                let numSegs = max(16, KiMath.arcToSegmentCount(radius, maxError, .a360))
                let angDelta = EDAAngle.a360 / Double(numSegs)
                var lastSeg = endAngle
                if lastSeg > .zero {
                    while lastSeg > angDelta { lastSeg -= angDelta }
                } else {
                    while lastSeg < -angDelta { lastSeg += angDelta }
                }
                var angPos = lastSeg.degrees == 0 ? angDelta : (angDelta + lastSeg) / 2
                let transition = tanAngle2 > 0 ? Double(radius) / tanAngle2 : 0
                var arcStart = cornerPosition - incoming.resized(KiMath.cInt(transition))
                let arcCenter = arcStart + incoming.perpendicular.resized(radius)
                var arcEnd: IPoint
                let arcStartOrigin: IPoint
                if errorLocation == .inside {
                    arcEnd = Seg(cornerPosition, arcCenter).reflectPoint(arcStart)
                    arcStartOrigin = arcStart - arcCenter
                    outline.append(arcStart)
                } else {
                    // the outer radius radius + the error, worked out again as the count is at least sixteen
                    let actualDelta = KiMath.circleToEndSegmentDeltaRadius(radius, numSegs)
                    arcStart += incoming.perpendicular.resized(-actualDelta)
                    arcStartOrigin = arcStart - arcCenter
                    // (no "ears": only the segments crossing or within the outline without its rounding)
                    let outlineIn = Seg(cornerPosition - incoming, cornerPosition)
                    var prev = arcStart
                    arcEnd = cornerPosition
                    while angPos < endAngle {
                        let pt = KiMath.rotate(arcStartOrigin, -angPos) + arcCenter
                        angPos += angDelta
                        if outlineIn.side(pt) > 0 {
                            // (KiCad gives up on the outline if these lines do not cross; they always do)
                            guard let x = outlineIn.intersectLines(Seg(prev, pt)) else { return outline }
                            outline.append(x)
                            outline.append(pt)
                            arcEnd = Seg(cornerPosition, arcCenter).reflectPoint(x)
                            break
                        }
                        endAngle -= angDelta
                        prev = pt
                    }
                }
                while angPos < endAngle {
                    outline.append(KiMath.rotate(arcStartOrigin, -angPos) + arcCenter)
                    angPos += angDelta
                }
                outline.append(arcEnd)
            }
            incoming = outgoing
        }
        return outline
    }

    /// Corners at the same place taken out, but for the first (KiCad's CornerListRemoveDuplicates)
    private static func removeDuplicates(_ corners: inout [Corner]) {
        var prev = corners[0].position
        var pos = corners.count - 1
        while pos >= 0 {
            if corners[pos].position == prev {
                corners.remove(at: pos)
            } else {
                prev = corners[pos].position
            }
            pos -= 1
        }
    }

    /// A rectangle at `position` of `size` turned by `rotation`, its corners rounded to `cornerRadius` and those of
    /// `chamferCorners` cut by `chamferRatio` of its shorter side, grown by `inflate` (KiCad's
    /// TransformRoundChamferedRectToPolygon)
    public static func roundChamferedRect(position: IPoint, size: IPoint, rotation: EDAAngle, cornerRadius: Int,
                                          chamferRatio: Double, chamferCorners: Int, inflate: Int, maxError: Int,
                                          errorLocation: ErrorLocation) -> LineChain {
        // (a VECTOR2I halved as KiCad halves it: rounded, not cut)
        var half = size.divided(by: 2)
        let chamferCount = chamferCorners.nonzeroBitCount
        var chamferDeduct = 0.0
        var radius = cornerRadius, inflate = inflate
        if inflate < 0 {
            half.x = max(1, half.x + inflate)
            half.y = max(1, half.y + inflate)
            chamferDeduct = Double(inflate) * (2.0 - 2.0.squareRoot())
            radius = max(0, radius + inflate)
            inflate = 0
        }
        var corners = [Corner(-half.x, -half.y, radius), Corner(half.x, -half.y, radius), Corner(half.x, half.y, radius),
                       Corner(-half.x, half.y, radius)]
        if chamferCorners != 0 {
            let shorter = min(size.x, size.y)
            let chamfer = max(0, KiMath.round(chamferRatio * Double(shorter) + chamferDeduct))
            let ids = [chamferTopLeft, chamferTopRight, chamferBottomRight, chamferBottomLeft]
            let sign = [0, 1, -1, 0, 0, -1, 1, 0]
            var pos = 0
            for cc in 0..<4 {
                defer { pos += 1 }
                guard chamferCorners & ids[cc] != 0 else { continue }
                corners[pos].radius = 0
                if chamfer == 0 { continue }
                corners.insert(corners[pos], at: pos + 1)
                corners[pos].position.x += sign[(2 * cc) & 7] * chamfer
                corners[pos].position.y += sign[(2 * cc - 2) & 7] * chamfer
                corners[pos + 1].position.x += sign[(2 * cc + 1) & 7] * chamfer
                corners[pos + 1].position.y += sign[(2 * cc - 1) & 7] * chamfer
                pos += 1
            }
            if chamferCount > 1 && 2 * chamfer >= shorter { removeDuplicates(&corners) }
        }
        var outline = cornerList(corners, inflate: inflate, maxError: maxError, errorLocation: errorLocation)
        if rotation.degrees != 0 { outline = outline.rotated(rotation) }
        return outline.moved(position)
    }

    /// A trapezoid (a rectangle whose opposite sides are made `deltaX` or `deltaY` longer and shorter), turned and
    /// grown (KiCad's TransformTrapezoidToPolygon)
    public static func trapezoid(position: IPoint, size: IPoint, rotation: EDAAngle, deltaX: Int, deltaY: Int, inflate: Int,
                                 maxError: Int, errorLocation: ErrorLocation) -> LineChain {
        // (a VECTOR2I halved as KiCad halves it: rounded, not cut)
        var half = size.divided(by: 2)
        var corners: [Corner] = []
        var dx = deltaX, dy = deltaY, inflate = inflate
        if inflate < 0 {
            if dx == 0 && dy == 0 {
                half.x = max(1, half.x + inflate)
                half.y = max(1, half.y + inflate)
            } else if dx != 0 {
                let slope = Double(dx) / Double(half.x)
                let yShrink = KiMath.round(hypot(Double(half.x), Double(dx)) * Double(inflate) / Double(half.x))
                half.y = max(1, half.y + yShrink)
                half.x = max(1, half.x + inflate)
                dx = KiMath.round(Double(half.x) * slope)
                if dx > half.y {
                    corners = [Corner(-half.x, -half.y - dx), Corner(KiMath.round(Double(half.y) / slope), 0), Corner(-half.x, half.y + dx)]
                }
            } else {
                let slope = Double(dy) / Double(half.y)
                let xShrink = KiMath.round(hypot(Double(half.y), Double(dy)) * Double(inflate) / Double(half.y))
                half.x = max(1, half.x + xShrink)
                half.y = max(1, half.y + inflate)
                dy = KiMath.round(Double(half.y) * slope)
                if dy > half.x {
                    corners = [Corner(0, -KiMath.round(Double(half.x) / slope)), Corner(half.x + dy, half.y), Corner(-half.x - dy, half.y)]
                }
            }
            inflate = 0
        }
        if corners.isEmpty {
            corners = [Corner(-half.x + dy, -half.y - dx), Corner(half.x - dy, -half.y + dx), Corner(half.x + dy, half.y - dx),
                       Corner(-half.x - dy, half.y + dx)]
            if abs(dy) == abs(half.x) || abs(dx) == abs(half.y) { removeDuplicates(&corners) }
        }
        var outline = cornerList(corners, inflate: inflate, maxError: maxError, errorLocation: errorLocation)
        if rotation.degrees != 0 { outline = outline.rotated(rotation) }
        return outline.moved(position)
    }

    /// A circle as a polygon, its segment count a multiple of eight (KiCad's TransformCircleToPolygon, into a
    /// SHAPE_POLY_SET: the first point repeated at the end)
    public static func circle(center: IPoint, radius: Int, maxError: Int, errorLocation: ErrorLocation, minSegCount: Int = 0) -> LineChain {
        var numSegs = max(minSegCount, KiMath.arcToSegmentCount(radius, maxError, .a360))
        numSegs = (numSegs + 7) / 8 * 8
        let delta = EDAAngle.a360 / Double(numSegs)
        var r = radius
        if errorLocation == .outside { r += KiMath.circleToEndSegmentDeltaRadius(r, numSegs) }
        var out = LineChain()
        out.setClosed(true)
        var angle = delta / 2
        while angle < .a360 {
            out.append(KiMath.rotate(IPoint(r, 0), angle) + center)
            angle += delta
        }
        out.append(KiMath.rotate(IPoint(r, 0), delta / 2) + center)
        return out
    }
    /// A circle as a closed chain, its segment count a multiple of eight (KiCad's TransformCircleToPolygon, into a
    /// SHAPE_LINE_CHAIN: the first point not repeated)
    public static func circleChain(center: IPoint, radius: Int, maxError: Int, errorLocation: ErrorLocation, minSegCount: Int = 0) -> LineChain {
        var numSegs = max(minSegCount, KiMath.arcToSegmentCount(radius, maxError, .a360))
        numSegs = (numSegs + 7) / 8 * 8
        let delta = EDAAngle.a360 / Double(numSegs)
        var r = radius
        if errorLocation == .outside { r += KiMath.circleToEndSegmentDeltaRadius(r, numSegs) }
        var out = LineChain()
        var angle = delta / 2
        while angle < .a360 {
            out.append(KiMath.rotate(IPoint(r, 0), angle) + center)
            angle += delta
        }
        out.setClosed(true)
        return out
    }

    /// A segment `width` wide with round ends as a polygon (KiCad's TransformOvalToPolygon): its ends' half circles
    /// cut to the segment's width, in case the error outside made them wider
    public static func oval(start: IPoint, end: IPoint, width: Int, maxError: Int, errorLocation: ErrorLocation,
                            minSegCount: Int = 0) -> PolySet {
        var radius = width / 2
        var numSegs = max(minSegCount, KiMath.arcToSegmentCount(radius, maxError, .a360))
        numSegs = (numSegs + 7) / 8 * 8
        let delta = EDAAngle.a360 / Double(numSegs)
        if errorLocation == .outside { radius += KiMath.circleToEndSegmentDeltaRadius(radius, numSegs) }
        // (the segment from the origin along x, its end to the right)
        var endp = end - start, startp = start
        if endp.x < 0 {
            endp = start - end
            startp = end
        }
        let deltaAngle = EDAAngle(endp)
        let segLen = endp.norm
        var shape = PolySet()
        shape.newOutline()
        shape.append(IPoint(segLen, radius))
        var angle = delta / 2
        while angle < .a180 {
            shape.append(KiMath.rotate(IPoint(0, radius), angle) + IPoint(segLen, 0))
            angle += delta
        }
        shape.append(IPoint(segLen, -radius))
        shape.append(IPoint(0, -radius))
        angle = delta / 2
        while angle < .a180 {
            shape.append(KiMath.rotate(IPoint(0, -radius), angle))
            angle += delta
        }
        shape.append(IPoint(0, radius))
        let halfWidth = width / 2
        var box = PolySet()
        box.newOutline()
        for c in [IPoint(-radius - 2, halfWidth), IPoint(-radius - 2, -halfWidth), IPoint(radius + segLen + 2, -halfWidth),
                  IPoint(radius + segLen + 2, halfWidth)] { box.append(c) }
        shape.booleanIntersection(box)
        shape.rotate(-deltaAngle)
        shape.move(startp)
        return shape
    }

    /// A ring as a polygon, its hole fractured into it; a circle if it has no hole (KiCad's TransformRingToPolygon)
    public static func ring(center: IPoint, radius: Int, width: Int, maxError: Int, errorLocation: ErrorLocation) -> PolySet {
        let inner = radius - width / 2, outer = inner + width
        if inner <= 0 {
            return PolySet([[circle(center: center, radius: radius + width / 2, maxError: maxError, errorLocation: errorLocation)]])
        }
        var buffer = PolySet([[circle(center: center, radius: outer, maxError: maxError, errorLocation: errorLocation)]])
        // (the hole's error on the other side)
        buffer.addHole(circleChain(center: center, radius: inner, maxError: maxError,
                                   errorLocation: errorLocation == .outside ? .inside : .outside))
        buffer.fracture()
        return buffer
    }

    /// An arc `width` wide with round ends as a polygon (KiCad's TransformArcToPolygon): a segment if its middle is
    /// within a nanometre of its chord; worked round counter-clockwise
    public static func arc(start: IPoint, mid: IPoint, end: IPoint, width: Int, maxError: Int, errorLocation: ErrorLocation) -> PolySet {
        let distanceToMid = Seg(start, end).distance(mid)
        if distanceToMid <= 1 {
            return oval(start: start, end: end, width: width + distanceToMid, maxError: maxError, errorLocation: errorLocation)
        }
        let startToMid = mid - start, startToEnd = end - start
        let cross = startToMid.x * startToEnd.y - startToMid.y * startToEnd.x
        var p0 = start, p1 = end
        if cross < 0 { swap(&p0, &p1) }
        guard let params = ArcChordParams(p0, mid, p1) else {
            return oval(start: start, end: end, width: width, maxError: maxError, errorLocation: errorLocation)
        }
        let startAngle = params.startAngle, endAngle = params.endAngle
        let radialOffset = width / 2
        let innerRadius = params.radius - Double(radialOffset)
        let innerError: ErrorLocation = errorLocation == .inside ? .outside : .inside
        let outerError: ErrorLocation = errorLocation == .inside ? .inside : .outside
        var outline = LineChain()
        outline.setClosed(true)
        // the starting end's half circle, the outside, the ending end's half circle, the inside back
        arcToPolyline(&outline, center: p0, radius: radialOffset, startAngle: startAngle - .a180, arcAngle: .a180,
                      accuracy: Double(maxError), errorLocation: errorLocation)
        arcToPolyline(&outline, start: p0, mid: mid, end: p1, accuracy: Double(maxError), errorLocation: outerError,
                      radialOffset: Double(radialOffset))
        arcToPolyline(&outline, center: p1, radius: radialOffset, startAngle: endAngle, arcAngle: .a180,
                      accuracy: Double(maxError), errorLocation: errorLocation)
        if innerRadius > 0 {
            arcToPolyline(&outline, start: p1, mid: mid, end: p0, accuracy: Double(maxError), errorLocation: innerError,
                          radialOffset: -Double(radialOffset))
        }
        return PolySet([[outline]])
    }

    /// An arc through three points, `radialOffset` out from it, as a polyline added to `chain`, its points `accuracy`
    /// from true on the side asked (KiCad's ConvertArcToPolyline by its points, working along its chord); the number
    /// of segments
    @discardableResult
    static func arcToPolyline(_ chain: inout LineChain, start: IPoint, mid: IPoint, end: IPoint, accuracy: Double,
                              errorLocation: ErrorLocation, radialOffset: Double) -> Int {
        guard let params = ArcChordParams(start, mid, end) else {
            chain.append(start)
            if end != start { chain.append(end) }
            return 0
        }
        let arcAngle = params.arcAngle
        if arcAngle <= 0 {
            chain.append(start)
            chain.append(end)
            return 0
        }
        let maxCoord = Double(Int32.max)
        var points: [IPoint] = []
        func point(_ alpha: Double, _ effectiveRadius: Double) -> Bool {
            let uOffset = effectiveRadius * Foundation.sin(alpha)
            let nOffset = params.centerOffset - effectiveRadius * Foundation.cos(alpha)
            let x = params.midX + params.ux * uOffset + params.nx * nOffset
            let y = params.midY + params.uy * uOffset + params.ny * nOffset
            // (an approximation that would overflow: a straight segment instead)
            if !x.isFinite || !y.isFinite || abs(x) > maxCoord || abs(y) > maxCoord { return false }
            points.append(IPoint(KiMath.round(x), KiMath.round(y)))
            return true
        }
        func straight() -> Int {
            chain.clear()
            chain.append(start)
            chain.append(end)
            return 0
        }
        let effectiveRadius = params.radius + radialOffset
        let arcAngleEDA = EDAAngle(radians: arcAngle)
        var n = 2
        let radiusForSeg = KiMath.round(min(abs(effectiveRadius), maxCoord))
        if Double(radiusForSeg) >= accuracy { n = KiMath.arcToSegmentCount(radiusForSeg, Int(accuracy), arcAngleEDA) + 1 }
        let halfAngle = arcAngle / 2, delta = arcAngle / Double(n)
        if errorLocation == .inside {
            for i in 0...n where !point(-halfAngle + delta * Double(i), effectiveRadius) { return straight() }
        } else {
            let seg360 = abs(KiMath.round(Double(n) * 360.0 / arcAngleEDA.degrees))
            if seg360 <= 0 {
                for i in 0...n where !point(-halfAngle + delta * Double(i), effectiveRadius) { return straight() }
                for p in points { chain.append(p) }
                return n
            }
            let deltaRadius = KiMath.circleToEndSegmentDeltaRadius(radiusForSeg, seg360)
            let errorRadius = effectiveRadius + Double(deltaRadius)
            if !point(-halfAngle, effectiveRadius) { return straight() }
            for i in 0..<n where !point(-halfAngle + delta * (Double(i) + 0.5), errorRadius) { return straight() }
            if !point(halfAngle, effectiveRadius) { return straight() }
        }
        for p in points { chain.append(p) }
        return n
    }

    /// An arc about `center`, from `startAngle` round `arcAngle`, as a polyline added to `chain`, its points
    /// `accuracy` from true on the side asked (KiCad's ConvertArcToPolyline by its centre); the number of segments
    @discardableResult
    static func arcToPolyline(_ chain: inout LineChain, center: IPoint, radius: Int, startAngle: EDAAngle, arcAngle: EDAAngle,
                              accuracy: Double, errorLocation: ErrorLocation) -> Int {
        var n = 2
        if Double(radius) >= accuracy { n = KiMath.arcToSegmentCount(radius, Int(accuracy), arcAngle) + 1 }
        let delta = arcAngle / Double(n)
        func at(_ r: Int, _ a: EDAAngle) -> IPoint {
            IPoint(KiMath.round(Double(center.x) + Double(r) * a.cos), KiMath.round(Double(center.y) + Double(r) * a.sin))
        }
        if errorLocation == .inside {
            // (the segments' ends on the arc)
            var rot = startAngle
            for _ in 0...n {
                chain.append(at(radius, rot))
                rot += delta
            }
        } else {
            // (the segments' middles on the arc: half a segment more at each end)
            let seg360 = abs(KiMath.round(Double(n) * 360.0 / arcAngle.degrees))
            let errorRadius = radius + KiMath.circleToEndSegmentDeltaRadius(radius, seg360)
            chain.append(at(radius, startAngle))
            var rot = startAngle + delta / 2
            for _ in 0..<n {
                chain.append(at(errorRadius, rot))
                rot += delta
            }
            chain.append(at(radius, startAngle + arcAngle))
        }
        return n
    }
}

/// An arc worked out along its chord, from its start to its end, and the normal to it toward the arc's centre, which
/// keeps shallow arcs exact (KiCad's ARC_CHORD_PARAMS); nil if the points are in line or two the same
struct ArcChordParams {
    var chordLength: Double, halfChord: Double
    var ux: Double, uy: Double, nx: Double, ny: Double
    var sagitta: Double, radius: Double, centerOffset: Double
    var midX: Double, midY: Double

    init?(_ start: IPoint, _ mid: IPoint, _ end: IPoint) {
        let dx = Double(end.x) - Double(start.x), dy = Double(end.y) - Double(start.y)
        chordLength = (dx * dx + dy * dy).squareRoot()
        if chordLength <= 0 { return nil }
        let mx = Double(mid.x) - Double(start.x), my = Double(mid.y) - Double(start.y)
        let cross = mx * dy - my * dx
        if cross == 0 { return nil }
        sagitta = abs(cross) / chordLength
        if sagitta <= 0 { return nil }
        halfChord = chordLength / 2
        radius = (halfChord * halfChord + sagitta * sagitta) / (2 * sagitta)
        if radius <= 0 { return nil }
        ux = dx / chordLength
        uy = dy / chordLength
        nx = -uy
        ny = ux
        if cross < 0 {
            nx = -nx
            ny = -ny
        }
        centerOffset = radius - sagitta
        midX = (Double(start.x) + Double(end.x)) * 0.5
        midY = (Double(start.y) + Double(end.y)) * 0.5
    }

    /// The direction from the centre to the start
    var startAngle: EDAAngle {
        let sinHalf = halfChord / radius, cosHalf = centerOffset / radius
        return EDAAngle(DPoint(-sinHalf * ux - cosHalf * nx, -sinHalf * uy - cosHalf * ny))
    }

    /// The direction from the centre to the end
    var endAngle: EDAAngle {
        let sinHalf = halfChord / radius, cosHalf = centerOffset / radius
        return EDAAngle(DPoint(sinHalf * ux - cosHalf * nx, sinHalf * uy - cosHalf * ny))
    }

    /// The angle the arc sweeps, in radians
    var arcAngle: Double {
        let base = 2 * asin(min(max(halfChord / radius, 0), 1))
        return sagitta > radius ? 2 * Double.pi - base : base
    }
}


extension LineChain {
    /// Every point turned about the origin (KiCad's SHAPE_LINE_CHAIN::Rotate)
    public func rotated(_ angle: EDAAngle, around c: IPoint = .zero) -> LineChain {
        var out = self
        out.points = points.map { KiMath.rotate($0, around: c, angle) }
        return out
    }

    /// Every point moved by `d`
    public func moved(_ d: IPoint) -> LineChain {
        var out = self
        out.points = points.map { $0 + d }
        return out
    }
}
