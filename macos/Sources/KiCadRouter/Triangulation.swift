// Ported from KiCad 10.0.7: libs/kimath/include/geometry/polygon_triangulation.h (POLYGON_TRIANGULATION),
// libs/kimath/include/geometry/vertex_set.h and libs/kimath/src/geometry/vertex_set.cpp (VERTEX, VERTEX_SET), and
// SHAPE_POLY_SET::TRIANGULATED_POLYGON's vertices and triangles. KiCad's triangulation is based on Lamot and Žalik's
// uniform plane subdivision and derived from K-3D (Copyright (c) 2005-2006, Romain Behar, GPL-2) and earcut
// (Copyright (c) 2016, Mapbox, ISC licence).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt. GNU General Public License version 3 or later, as KiCad
// (see KICAD-NOTICE.md).

import Foundation

/// A polygon cut into triangles: its points (the outline's, then any the cutting added), and the triangles as indices
/// into them (KiCad's SHAPE_POLY_SET::TRIANGULATED_POLYGON)
public struct TriangulatedPolygon: Sendable {
    public var vertices: [IPoint] = []
    public var triangles: [(Int, Int, Int)] = []
    /// The outline of the polygon set it was made from (-1: the whole set's)
    public var sourceOutline: Int

    public init(sourceOutline: Int = -1) { self.sourceOutline = sourceOutline }

    mutating func clear() {
        vertices = []
        triangles = []
    }

    mutating func addVertex(_ p: IPoint) { vertices.append(p) }
    mutating func addTriangle(_ a: Int, _ b: Int, _ c: Int) { triangles.append((a, b, c)) }

    /// The `i`th triangle's corners
    public func triangle(_ i: Int) -> (IPoint, IPoint, IPoint) {
        let t = triangles[i]
        return (vertices[t.0], vertices[t.1], vertices[t.2])
    }
}

/// A point of the polygon being cut, in its ring and in z-order (KiCad's VERTEX)
final class TriVertex {
    let i: Int
    let x: Double
    let y: Double
    unowned let parent: TriVertexSet
    // (the set keeps every vertex; these only link them)
    unowned(unsafe) var prev: TriVertex?
    unowned(unsafe) var next: TriVertex?
    var z: UInt32 = 0
    unowned(unsafe) var prevZ: TriVertex?
    unowned(unsafe) var nextZ: TriVertex?

    init(_ i: Int, _ x: Double, _ y: Double, _ parent: TriVertexSet) {
        self.i = i
        self.x = x
        self.y = y
        self.parent = parent
    }

    /// The same place
    func same(_ o: TriVertex) -> Bool { x == o.x && y == o.y }

    /// Taken out of its ring and of the z-order
    func remove() {
        next!.prev = prev
        prev!.next = next
        if let prevZ { prevZ.nextZ = nextZ }
        if let nextZ { nextZ.prevZ = prevZ }
        next = nil
        prev = nil
        nextZ = nil
        prevZ = nil
    }

    /// The ring split between this vertex and `b` (in the same ring) into two; the new vertex of the ring that does not
    /// hold this one
    func split(_ b: TriVertex) -> TriVertex {
        // (KiCad makes a vertex here it does not use)
        parent.vertices.append(TriVertex(i, x, y, parent))
        let a2 = parent.insertVertex(i, x, y, nil)
        let b2 = TriVertex(b.i, b.x, b.y, parent)
        parent.vertices.append(b2)
        let an = next!, bp = b.prev!
        next = b
        b.prev = self
        a2.next = an
        an.prev = a2
        b2.next = a2
        a2.prev = b2
        bp.next = b2
        b2.prev = bp
        return b2
    }

    func updateOrder() {
        if z == 0 { z = parent.zOrder(x, y) }
    }

    /// Duplicates taken out, and the z-order made again, after vertices were added or changed
    func updateList() {
        var p = next!
        while p !== self {
            if p.same(p.next!) {
                p = p.prev!
                p.next!.remove()
                if p === p.next { break }
            }
            p.updateOrder()
            p = p.next!
        }
        updateOrder()
        zSort()
    }

    /// The ring's vertices in z-order (their Morton codes)
    func zSort() {
        var queue: [TriVertex] = [self]
        var p = next
        while let q = p, q !== self {
            queue.append(q)
            p = q.next
        }
        queue.sort { a, b in
            if a.z != b.z { return a.z < b.z }
            if a.x != b.x { return a.x < b.x }
            if a.y != b.y { return a.y < b.y }
            return a.i < b.i
        }
        var prevElem: TriVertex?
        for elem in queue {
            prevElem?.nextZ = elem
            elem.prevZ = prevElem
            prevElem = elem
        }
        prevElem?.nextZ = nil
    }

    func inTriangle(_ a: TriVertex, _ b: TriVertex, _ c: TriVertex) -> Bool {
        (c.x - x) * (a.y - y) - (a.x - x) * (c.y - y) >= 0
            && (a.x - x) * (b.y - y) - (b.x - x) * (a.y - y) >= 0
            && (b.x - x) * (c.y - y) - (c.x - x) * (b.y - y) >= 0
    }

    /// The signed area of the ring from this vertex (to `end`, closed back here)
    func area(_ end: TriVertex? = nil) -> Double {
        var p = self
        var a = 0.0
        repeat {
            a += (p.x + p.next!.x) * (p.next!.y - p.y)
            p = p.next!
        } while p !== self && p !== end
        if p !== self { a += (p.x + x) * (y - p.y) }
        return a / 2
    }

    /// Whether this vertex is the tip of an ear: no other vertex inside the triangle it makes with its neighbours
    func isEar() -> Bool {
        let a = prev!, b = self, c = next!
        if parent.area(a, b, c) >= 0 { return false }
        let minTX = min(a.x, min(b.x, c.x)), minTY = min(a.y, min(b.y, c.y))
        let maxTX = max(a.x, max(b.x, c.x)), maxTY = max(a.y, max(b.y, c.y))
        let minZ = parent.zOrder(minTX, minTY), maxZ = parent.zOrder(maxTX, maxTY)
        var p = nextZ
        while let q = p, q.z <= maxZ {
            if q !== a && q !== c && q.inTriangle(a, b, c) && parent.area(q.prev!, q, q.next!) >= 0 { return false }
            p = q.nextZ
        }
        p = prevZ
        while let q = p, q.z >= minZ {
            if q !== a && q !== c && q.inTriangle(a, b, c) && parent.area(q.prev!, q, q.next!) >= 0 { return false }
            p = q.prevZ
        }
        return true
    }
}

/// The vertices of a polygon being cut (KiCad's VERTEX_SET)
class TriVertexSet {
    var bbox = IBox(minX: 0, minY: 0, maxX: 0, maxY: 0)
    var vertices: [TriVertex] = []
    let simplificationLevel: Int

    init(simplificationLevel: Int) { self.simplificationLevel = simplificationLevel * simplificationLevel }

    @discardableResult
    func insertVertex(_ index: Int, _ x: Double, _ y: Double, _ last: TriVertex?) -> TriVertex {
        let p = TriVertex(index, x, y, self)
        vertices.append(p)
        if let last {
            p.next = last.next
            p.prev = last
            last.next!.prev = p
            last.next = p
        } else {
            p.prev = p
            p.next = p
        }
        return p
    }

    /// A chain's points linked into a ring, wound the same way whichever way the chain goes, points nearer than the
    /// simplification level to the last left out
    func createList(_ points: LineChain) -> TriVertex? {
        var tail: TriVertex?
        var sum = 0.0
        let n = points.pointCount
        for i in 0..<n {
            let p1 = points.point(i), p2 = points.point((i + 1) % n)
            sum += Double(p2.x - p1.x) * Double(p2.y + p1.y)
        }
        var last = IPoint.zero
        var first = true
        func add(_ i: Int) {
            let pt = points.point(i)
            let dx = pt.x - last.x, dy = pt.y - last.y
            if first || dx * dx + dy * dy > simplificationLevel {
                tail = insertVertex(i, Double(pt.x), Double(pt.y), tail)
                last = pt
                first = false
            }
        }
        if sum > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) { add(i) }
        } else {
            for i in 0..<n { add(i) }
        }
        if let t = tail, t.same(t.next!) { t.next!.remove() }
        return tail
    }

    /// A point's Morton code, on the box scaled to 15 bits a side
    func zOrder(_ x: Double, _ y: Double) -> UInt32 {
        let limitX = min(max((x - Double(bbox.minX)) / Double(bbox.width), 0), 1)
        let limitY = min(max((y - Double(bbox.minY)) / Double(bbox.height), 0), 1)
        var ux = UInt32(limitX * 32767.0), uy = UInt32(limitY * 32767.0)
        ux = (ux | (ux << 8)) & 0x00FF00FF
        ux = (ux | (ux << 4)) & 0x0F0F0F0F
        ux = (ux | (ux << 2)) & 0x33333333
        ux = (ux | (ux << 1)) & 0x55555555
        uy = (uy | (uy << 8)) & 0x00FF00FF
        uy = (uy | (uy << 4)) & 0x0F0F0F0F
        uy = (uy | (uy << 2)) & 0x33333333
        uy = (uy | (uy << 1)) & 0x55555555
        return ux | (uy << 1)
    }

    /// Twice the signed area of the triangle p, q, r
    func area(_ p: TriVertex, _ q: TriVertex, _ r: TriVertex) -> Double {
        (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y)
    }

    func samePoint(_ a: TriVertex?, _ b: TriVertex?) -> Bool {
        guard let a, let b else { return false }
        return a.x == b.x && a.y == b.y
    }

    func nextOutlineVertex(_ pt: TriVertex) -> TriVertex {
        let nz = pt.nextZ, pz = pt.prevZ
        // (at a fracture, on round the edge being worked on rather than over to its pair)
        if samePoint(pt, nz) && samePoint(pt.next, nz!.prev) && pt.y == pt.next!.y { return nz!.next! }
        if samePoint(pt, pz) && samePoint(pt.next, pz!.prev) && pt.y == pt.next!.y { return pz!.next! }
        return pt.next!
    }

    func prevOutlineVertex(_ pt: TriVertex) -> TriVertex {
        let nz = pt.nextZ, pz = pt.prevZ
        if samePoint(pt, nz) && pt.y == pt.prev!.y { return nz!.prev! }
        if samePoint(pt, pz) && pt.y == pt.prev!.y { return pz!.prev! }
        return pt.prev!
    }

    /// Whether the segment from a to b goes into a's polygon right by a
    func locallyInside(_ a: TriVertex, _ b: TriVertex) -> Bool {
        let an = nextOutlineVertex(a), ap = prevOutlineVertex(a)
        if area(ap, a, an) < 0 {
            return area(a, b, an) >= 0 && area(a, ap, b) >= 0
        } else {
            return area(a, b, ap) < 0 || area(a, an, b) < 0
        }
    }

    /// Whether the middle of the segment from a to b is inside the polygon
    func middleInside(_ a: TriVertex, _ b: TriVertex) -> Bool {
        var p = a
        var inside = false
        let px = (a.x + b.x) / 2, py = (a.y + b.y) / 2
        repeat {
            let n = p.next!
            if (p.y > py) != (n.y > py) && px < (n.x - p.x) * (py - p.y) / (n.y - p.y) + p.x { inside.toggle() }
            p = n
        } while p !== a
        return inside
    }
}

/// A simple polygon cut into triangles by ear clipping on its z-ordered vertices, as KiCad cuts its zones, keepouts
/// and pads (KiCad's POLYGON_TRIANGULATION; its simplification level 50 nm and smallest area 1000 nm², KiCad's
/// defaults)
final class PolygonTriangulation: TriVertexSet {
    static let simplification = 50
    static let minimumArea = 1000.0

    private(set) var result: TriangulatedPolygon
    private var originalSize = 0

    init(_ result: TriangulatedPolygon) {
        self.result = result
        super.init(simplificationLevel: Self.simplification)
    }

    /// The polygon `poly` cut into triangles; whether it could be (the triangles in `result`)
    func tesselatePolygon(_ poly: LineChain) -> Bool {
        bbox = poly.bbox
        result.clear()
        if bbox.width == 0 || bbox.height == 0 { return true }
        let firstVertex = createList(poly)
        for p in poly.points { result.addVertex(p) }
        guard let first = firstVertex, first.prev !== first.next else { return true }
        originalSize = vertices.count
        first.updateList()
        let ok = earcutList(first)
        vertices.removeAll()
        return ok
    }

    /// Points nearer each other than the simplification level taken out; the vertex to go on from, nil if none was
    private func simplifyList(_ start: TriVertex?) -> TriVertex? {
        guard let start, start.next !== start.prev else { return start }
        var p = start
        var next = p.next
        var retval = start
        var count = 0
        let sqDist = Double(Self.simplification) * Double(Self.simplification)
        repeat {
            guard let n = next else { break }
            let dx = n.x - p.x, dy = n.y - p.y
            if dx * dx + dy * dy < sqDist {
                if n === start {
                    retval = p
                    start.remove()
                    count += 1
                    break
                }
                next = n.next
                p.next!.remove()
                count += 1
                retval = p
            } else {
                p = n
                next = n.next
            }
        } while p !== start && next != nil
        return count > 0 ? retval : nil
    }

    /// Triangles of no area (and points nearer than the simplification level) taken out, a last resort
    private func removeNullTriangles(_ startIn: TriVertex) -> TriVertex? {
        // (the start can be taken out on the way, and KiCad's then follows a null pointer, which ends the loop)
        var start: TriVertex? = startIn
        var retval: TriVertex?
        if let r = simplifyList(startIn) {
            start = r
            retval = r
        }
        var p = start!.next!
        while p !== start, p.next != nil, p.prev != nil {
            let tmp = TriVertex(0, 0.5 * (p.prev!.x + p.next!.x), 0.5 * (p.prev!.y + p.next!.y), self)
            let nullArea = 4.0 * abs(area(p.prev!, tmp, p.next!))
            if p.same(p.next!) || abs(area(p.prev!, p, p.next!)) <= nullArea {
                // a spike: one point of it left
                if p.next!.same(p.prev!) { p.next!.remove() }
                p = p.prev!
                p.next!.remove()
                retval = p
                if p === p.next { break }
                if start?.next == nil { start = p.prev }
                continue
            }
            p = p.next!
        }
        guard let pn = p.next, pn !== p, pn !== p.prev else { return p }
        let tmp = TriVertex(0, 0.5 * (p.prev!.x + p.next!.x), 0.5 * (p.prev!.y + p.next!.y), self)
        let nullArea = 4.0 * abs(area(p.prev!, tmp, p.next!))
        if abs(area(p.prev!, p, p.next!)) <= nullArea {
            retval = p.next
            p.remove()
        }
        return retval
    }

    /// The ring cut ear by ear; subdivided, cleared of empty triangles or split in two where no ear is left
    private func earcutList(_ pointIn: TriVertex?, _ pass: Int = 0) -> Bool {
        guard var point = pointIn else { return true }
        var stop = point
        var internalPass = 1
        while point.prev !== point.next {
            let prev = point.prev!, next = point.next!
            if point.isEar() {
                if !isTooSmall(point) { result.addTriangle(prev.i, point.i, next.i) }
                point.remove()
                point = next.next!
                stop = next.next!
                continue
            }
            let nextNext = next.next!
            if !prev.same(nextNext) && intersects(prev, point, next, nextNext) && locallyInside(prev, nextNext)
                && locallyInside(nextNext, prev) {
                result.addTriangle(prev.i, point.i, nextNext.i)
                next.remove()
                point.remove()
                point = nextNext
                stop = nextNext
                continue
            }
            point = next
            // round the whole ring with no ear found
            if point === stop && point.prev !== point.next {
                if internalPass == 2, let newPoint = removeNullTriangles(point) {
                    if newPoint.next === newPoint.prev { break }
                    point = newPoint
                    stop = newPoint
                    continue
                }
                internalPass += 1
                if internalPass < 4 {
                    subdividePolygon(point, internalPass)
                    continue
                }
                if !splitPolygon(point) { return false }
                break
            }
        }
        // three points left that turn the wrong way: from crossing edges, dropped
        if let n = point.next, point.prev === n.next {
            if area(point.prev!, point, n) >= 0 { return true }
        }
        if point.prev !== point.next { return abs(point.area()) > Self.minimumArea }
        return true
    }

    private func isTooSmall(_ p: TriVertex) -> Bool {
        let prevSq = (p.prev!.x - p.x) * (p.prev!.x - p.x) + (p.prev!.y - p.y) * (p.prev!.y - p.y)
        let nextSq = (p.next!.x - p.x) * (p.next!.x - p.x) + (p.next!.y - p.y) * (p.next!.y - p.y)
        let oppSq = (p.next!.x - p.prev!.x) * (p.next!.x - p.prev!.x) + (p.next!.y - p.prev!.y) * (p.next!.y - p.prev!.y)
        return prevSq < Self.minimumArea || nextSq < Self.minimumArea || oppSq < Self.minimumArea
    }

    /// Points put along the longer edges (as KiCad does it: the new points join the triangles' points, but not the
    /// ring)
    private func subdividePolygon(_ start: TriVertex, _ pass: Int = 0) {
        var p = start
        // (KiCad keeps the edges in a set ordered by length, longest first, one edge to a length)
        var longest: [(TriVertex, Double)] = []
        var avg = 0.0
        repeat {
            let len = (p.x - p.next!.x) * (p.x - p.next!.x) + (p.y - p.next!.y) * (p.y - p.next!.y)
            if !longest.contains(where: { $0.1 == len }) {
                let at = longest.firstIndex { $0.1 < len } ?? longest.count
                longest.insert((p, len), at: at)
            }
            avg += len
            p = p.next!
        } while p !== start
        avg /= Double(longest.count)
        for (a, length) in longest {
            guard length > avg else { break }
            let b = a.next!
            let divisions = Int(avg / length + 2 + Double(pass))
            let step = 1.0 / Double(divisions)
            for i in 1..<max(divisions, 1) {
                let x = a.x * (1.0 - step * Double(i)) + b.x * (step * Double(i))
                let y = a.y * (1.0 - step * Double(i)) + b.y * (step * Double(i))
                insertTriVertex(IPoint(Int(x), Int(y)))
            }
        }
        start.updateList()
    }

    /// The ring split in two where it cannot be cut further: at a point it passes twice, else along a diagonal inside
    private func splitPolygon(_ start: TriVertex?) -> Bool {
        guard let start, let sn = start.next, sn !== start.prev, sn.next !== start.prev else { return true }
        var origPoly = start
        repeat {
            var overlap: [TriVertex] = []
            var zpt = origPoly
            while let pz = zpt.prevZ, pz.same(origPoly) { zpt = pz }
            overlap.append(zpt)
            while let nz = zpt.nextZ, nz.same(origPoly) {
                zpt = nz
                overlap.append(zpt)
            }
            if overlap.count != 2 || overlap[0].next === overlap[1] || overlap[0].prev === overlap[1] {
                origPoly = origPoly.next!
                continue
            }
            if overlap[0].area(overlap[1]) < 0 || overlap[1].area(overlap[0]) < 0 {
                origPoly = origPoly.next!
                continue
            }
            let n0 = overlap[0].next, n1 = overlap[1].next
            overlap[0].next = n1
            overlap[1].next = n0
            overlap[0].next!.prev = overlap[0]
            overlap[1].next!.prev = overlap[1]
            overlap[0].updateList()
            overlap[1].updateList()
            return earcutList(overlap[0]) && earcutList(overlap[1])
        } while origPoly !== start
        repeat {
            var marker = origPoly.next!.next!
            while marker !== origPoly.prev {
                if origPoly.next != nil && origPoly.i != marker.i && goodSplit(origPoly, marker) {
                    let newPoly = origPoly.split(marker)
                    origPoly.updateList()
                    newPoly.updateList()
                    return earcutList(origPoly) && earcutList(newPoly)
                }
                marker = marker.next!
            }
            origPoly = origPoly.next!
        } while origPoly !== start
        return false
    }

    /// Whether the diagonal from a to b lies inside the polygon and splits it into two of positive area
    private func goodSplit(_ a: TriVertex, _ b: TriVertex) -> Bool {
        let aOnEdge = (a.nextZ.map { a.same($0) } ?? false) || (a.prevZ.map { a.same($0) } ?? false)
        let bOnEdge = (b.nextZ.map { b.same($0) } ?? false) || (b.prevZ.map { b.same($0) } ?? false)
        let noIntersect = a.next!.i != b.i && a.prev!.i != b.i && !intersectsPolygon(a, b)
        let localSplit = locallyInside(a, b) && locallyInside(b, a) && middleInside(a, b)
        let sameDir = area(a.prev!, a, b.prev!) != 0 || area(a, b.prev!, b) != 0
        let hasLen = a.same(b) && area(a.prev!, a, a.next!) > 0 && area(b.prev!, b, b.next!) > 0
        let posArea = a.area(b) > 0 && b.area(a) > 0
        return noIntersect && localSplit && (sameDir || hasLen) && !aOnEdge && !bOnEdge && posArea
    }

    private func sign(_ v: Double) -> Int { (v > 0 ? 1 : 0) - (v < 0 ? 1 : 0) }

    /// Whether q lies between p and r, the three in line
    private func overlapping(_ p: TriVertex, _ q: TriVertex, _ r: TriVertex) -> Bool {
        q.x <= max(p.x, r.x) && q.x >= min(p.x, r.x) && q.y <= max(p.y, r.y) && q.y >= min(p.y, r.y)
    }

    /// Whether p1-q1 meets p2-q2, ends included
    private func intersects(_ p1: TriVertex, _ q1: TriVertex, _ p2: TriVertex, _ q2: TriVertex) -> Bool {
        let s1 = sign(area(p1, q1, p2)), s2 = sign(area(p1, q1, q2))
        let s3 = sign(area(p2, q2, p1)), s4 = sign(area(p2, q2, q1))
        if s1 != s2 && s3 != s4 { return true }
        if s1 == 0 && overlapping(p1, p2, q1) { return true }
        if s2 == 0 && overlapping(p1, q2, q1) { return true }
        if s3 == 0 && overlapping(p2, p1, q2) { return true }
        if s4 == 0 && overlapping(p2, q1, q2) { return true }
        return false
    }

    /// Whether the segment from a to b crosses the polygon's edges (the original ring's)
    private func intersectsPolygon(_ a: TriVertex, _ b: TriVertex) -> Bool {
        for ii in 0..<originalSize {
            let p = vertices[ii], q = vertices[(ii + 1) % originalSize]
            if p.i == a.i || p.i == b.i || q.i == a.i || q.i == b.i { continue }
            if intersects(p, q, a, b) { return true }
        }
        return false
    }

    @discardableResult
    private func insertTriVertex(_ pt: IPoint) -> TriVertex {
        result.addVertex(pt)
        return insertVertex(result.vertices.count - 1, Double(pt.x), Double(pt.y), nil)
    }
}

extension LineChain {
    /// The closed polygon cut into triangles as KiCad cuts one (POLYGON_TRIANGULATION::TesselatePolygon); nil if it
    /// could not be
    public func triangulated() -> TriangulatedPolygon? {
        let tess = PolygonTriangulation(TriangulatedPolygon())
        guard tess.tesselatePolygon(self) else { return nil }
        return tess.result
    }
}
