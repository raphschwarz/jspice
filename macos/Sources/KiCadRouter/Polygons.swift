// Ported from KiCad 10.0.7: libs/kimath/src/convert_basic_shapes_to_polygon.cpp (rectangles with rounded or cut
// corners, trapezoids and circles as polygons), libs/kimath/src/geometry/seg.cpp (ReflectPoint) and
// libs/kimath/src/geometry/geometry_utils.cpp (GetCircleToPolyCorrection).
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
