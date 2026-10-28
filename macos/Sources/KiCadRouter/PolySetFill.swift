// Ported from KiCad 10.0.7: libs/kimath/src/geometry/shape_poly_set.cpp (SHAPE_POLY_SET as far as KiCad's zone filler
// uses one besides what PolySet.swift has: Deflate, Area, BBox, DeletePolygon, Contains and containsSingle, Collide of
// a shape, Unfracture with unfractureSingle, InflateWithLinkedHoles, RemoveNullSegments, Chamfer and Fillet) and
// libs/kimath/src/geometry/corner_operations.cpp (chamferFilletPolygon).
// Copyright (C) 2015-2019 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

extension PolySet {
    /// Every outline shrunk by `amount`, its holes grown (KiCad's Deflate)
    public mutating func deflate(_ amount: Int, _ cornerStrategy: CornerStrategy, maxError: Int) {
        inflate(-amount, cornerStrategy, maxError: maxError)
    }

    /// The outlines' areas less their holes' (KiCad's Area)
    public var area: Double {
        var a = 0.0
        for poly in polygons {
            a += poly[0].area()
            for hole in poly.dropFirst() { a -= hole.area() }
        }
        return a
    }

    /// The box round the outlines, grown by `clearance` (KiCad's BBox; an empty set's a box of nothing at the origin)
    public func bbox(_ clearance: Int = 0) -> IBox {
        var bb = IBox(minX: 0, minY: 0, maxX: 0, maxY: 0)
        for (i, poly) in polygons.enumerated() {
            if i == 0 { bb = poly[0].bbox } else { bb.merge(poly[0].bbox) }
        }
        return bb.inflated(clearance)
    }

    /// A polygon taken out (KiCad's DeletePolygon)
    public mutating func deletePolygon(_ i: Int) { polygons.remove(at: i) }

    /// How many points its chains have (KiCad's TotalVertices)
    public var totalVertices: Int { polygons.reduce(0) { $0 + $1.reduce(0) { $0 + $1.pointCount } } }

    /// Whether `p` is in one of the polygons (or in polygon `subpoly`): in its outline, or within `accuracy` of its
    /// edge, and not in one of its holes (KiCad's Contains and containsSingle)
    public func contains(_ p: IPoint, subpoly: Int = -1, accuracy: Int = 0) -> Bool {
        if polygons.isEmpty { return false }
        func single(_ i: Int) -> Bool {
            guard polygons[i][0].pointInside(p, accuracy: accuracy) else { return false }
            // (a hole's edge not counted, whatever the accuracy)
            for hole in polygons[i].dropFirst() where hole.pointInside(p, accuracy: 1) { return false }
            return true
        }
        if subpoly >= 0 { return single(subpoly) }
        return polygons.indices.contains(where: single)
    }

    /// SHAPE_POLY_SET::Collide of a shape (no clearance): a segment's or circle's by distance, anything else (a
    /// compound of shapes, `compound`) against the set's triangles (CacheTriangulation( false ) made first)
    public mutating func collide(_ shapes: [Shape], compound: Bool) -> Bool {
        if !compound && shapes.count == 1 {
            switch shapes[0] {
            case .segment, .circle: return BoardDRC.polySetCollide(self, shapes, compound: false, wantActual: false)
            default: break
            }
        }
        cacheTriangulation()
        return BoardDRC.polySetCollide(self, shapes, compound: true, wantActual: false)
    }

    // MARK: - Unfracturing

    /// Each polygon's outline made again of its edges, as KiCad's unfractureSingle does it: its duplicate points and
    /// points along straight lines taken out (SHAPE_LINE_CHAIN::Simplify), and then its edges paired with those that
    /// run back over them, which KiCad looks for in a hash set whose hash is not the same both ways along an edge, so
    /// that it finds none and leaves the outline whole; then the set simplified (KiCad's Unfracture)
    public mutating func unfracture() {
        for i in polygons.indices {
            var lc = polygons[i][0]
            lc.simplify()
            var outline = LineChain()
            for p in lc.points { outline.append(p) }
            outline.setClosed(true)
            // (KiCad's walk starts the ring at the edge its set of edges iterates first, by address; the union that
            // follows starts it where Clipper2 does, whatever its start)
            polygons[i] = [outline]
        }
        simplify()
    }

    /// The set unfractured, grown and fractured again (KiCad's InflateWithLinkedHoles)
    public mutating func inflateWithLinkedHoles(_ amount: Int, _ cornerStrategy: CornerStrategy, maxError: Int) {
        unfracture()
        inflate(amount, cornerStrategy, maxError: maxError)
        fracture()
    }

    // MARK: - Chamfers and fillets

    /// Each point that is the same as the next taken out, chain by chain (KiCad's RemoveNullSegments)
    @discardableResult
    public mutating func removeNullSegments() -> Int {
        var removed = 0
        for i in polygons.indices {
            for j in polygons[i].indices {
                let chain = polygons[i][j]
                let n = chain.pointCount
                var drop: [Int] = []
                for k in 0..<n where chain.point(k) == chain.point((k + 1) % n) { drop.append(k) }
                for k in drop.reversed() { polygons[i][j].remove(k) }
                removed += drop.count
            }
        }
        return removed
    }

    private enum CornerMode { case chamfered, filleted }

    /// Each polygon with its corners cut `distance` back along their sides (KiCad's Chamfer)
    public mutating func chamfer(_ distance: Int) -> PolySet {
        var out = PolySet()
        for i in polygons.indices { out.polygons.append(chamferFillet(.chamfered, distance, i, 0)) }
        return out
    }

    /// Each polygon with its corners rounded to `radius`, the arcs `maxError` from true (KiCad's Fillet)
    public mutating func fillet(_ radius: Int, maxError: Int) -> PolySet {
        var out = PolySet()
        for i in polygons.indices { out.polygons.append(chamferFillet(.filleted, radius, i, maxError)) }
        return out
    }

    /// KiCad's chamferFilletPolygon: its null segments taken out of the whole set first
    private mutating func chamferFillet(_ mode: CornerMode, _ distanceIn: Int, _ index: Int, _ errorMax: Int) -> [LineChain] {
        removeNullSegments()
        let current = polygons[index]
        if distanceIn == 0 { return current }
        var newPoly: [LineChain] = []
        for contour in current {
            var newContour = LineChain()
            let n = contour.pointCount
            for v in 0..<n {
                let x1 = contour.point(v).x, y1 = contour.point(v).y
                let prev = v == 0 ? n - 1 : v - 1, next = v == n - 1 ? 0 : v + 1
                let xa = Double(contour.point(prev).x - x1), ya = Double(contour.point(prev).y - y1)
                let xb = Double(contour.point(next).x - x1), yb = Double(contour.point(next).y - y1)
                if abs(xa + xb) < Double.ulpOfOne && abs(ya + yb) < Double.ulpOfOne { continue }
                let lena = Foundation.hypot(xa, ya), lenb = Foundation.hypot(xb, yb)
                switch mode {
                case .chamfered:
                    var distance = Double(distanceIn)
                    if 0.5 * lena < distance { distance = 0.5 * lena }
                    if 0.5 * lenb < distance { distance = 0.5 * lenb }
                    newContour.append(IPoint(x1 + KiMath.round(distance * xa / lena), y1 + KiMath.round(distance * ya / lena)))
                    newContour.append(IPoint(x1 + KiMath.round(distance * xb / lenb), y1 + KiMath.round(distance * yb / lenb)))
                case .filleted:
                    let cosine = (xa * xb + ya * yb) / (lena * lenb)
                    var radius = Double(distanceIn)
                    let denom = (2.0 / (1 + cosine) - 1).squareRoot()
                    if denom.isInfinite { continue }
                    if 0.5 * lena * denom < radius { radius = 0.5 * lena * denom }
                    if 0.5 * lenb * denom < radius { radius = 0.5 * lenb * denom }
                    var k = radius / (0.5 * (1 - cosine)).squareRoot()
                    let ux = xa / lena + xb / lenb, uy = ya / lena + yb / lenb
                    let lenab = (ux * ux + uy * uy).squareRoot()
                    let xc = Double(x1) + k * ux / lenab, yc = Double(y1) + k * uy / lenab
                    k = radius / (2 / (1 + cosine) - 1).squareRoot()
                    let xs = Double(x1) + k * xa / lena - xc, ys = Double(y1) + k * ya / lena - yc
                    let xe = Double(x1) + k * xb / lenb - xc, ye = Double(y1) + k * yb / lenb - yc
                    var argument = (xs * xe + ys * ye) / (radius * radius)
                    argument = min(max(argument, -1), 1)
                    let arcAngle = Foundation.acos(argument)
                    // (GetArcToSegmentCount of the radius as an int, as KiCad passes the double)
                    let segments = KiMath.arcToSegmentCount(Int(radius), errorMax, EDAAngle(radians: arcAngle))
                    var deltaAngle = arcAngle / Double(segments)
                    let startAngle = Foundation.atan2(-ys, xs)
                    if xa * yb - ya * xb <= 0 { deltaAngle *= -1 }
                    var nx = xc + xs, ny = yc + ys
                    if nx.isNaN || ny.isNaN { continue }
                    newContour.append(IPoint(KiMath.round(nx), KiMath.round(ny)))
                    var prevX = KiMath.round(nx), prevY = KiMath.round(ny)
                    for j in 0..<segments {
                        nx = xc + Foundation.cos(startAngle + Double(j + 1) * deltaAngle) * radius
                        ny = yc - Foundation.sin(startAngle + Double(j + 1) * deltaAngle) * radius
                        if nx.isNaN || ny.isNaN { continue }
                        if KiMath.round(nx) != prevX || KiMath.round(ny) != prevY {
                            newContour.append(IPoint(KiMath.round(nx), KiMath.round(ny)))
                            prevX = KiMath.round(nx)
                            prevY = KiMath.round(ny)
                        }
                    }
                }
            }
            newContour.setClosed(true)
            newPoly.append(newContour)
        }
        return newPoly
    }
}
