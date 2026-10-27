// Ported from KiCad 10.0.7: thirdparty/delaunator (delaunator.cpp and delaunator.hpp), KiCad's copy of delaunator-cpp
// (https://github.com/abellgithub/delaunator-cpp, after Mapbox's Delaunator), under the MIT License (its text in
// KICAD-NOTICE.md).

import Foundation

/// The Delaunay triangulation of points, as KiCad's ratsnest triangulates a net's anchors: the same triangles in the
/// same order, and the same half edges, for the same points (its sorts and its floating point arithmetic as the C++)
struct Delaunator {
    /// The index of no point or half edge (delaunator::INVALID_INDEX)
    static let invalid = -1

    /// Each triangle's three points, three indices into the points a triangle
    private(set) var triangles: [Int] = []
    /// For each half edge (an index into `triangles`), the half edge opposite it in the triangle next to it, or
    /// `invalid` on the hull
    private(set) var halfedges: [Int] = []
    private var hullPrev: [Int] = []
    private var hullNext: [Int] = []
    private var hullTri: [Int] = []
    private var hullStart = 0
    private var hash: [Int] = []
    private var hashSize = 0
    private var center = (x: 0.0, y: 0.0)
    private var edgeStack: [Int] = []
    private let xs: [Double], ys: [Double]

    struct NotTriangulation: Error {}

    init(x: [Double], y: [Double]) throws {
        xs = x
        ys = y
        let n = xs.count
        var ids = Array(0..<n)
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        for i in 0..<n {
            minX = min(xs[i], minX)
            minY = min(ys[i], minY)
            maxX = max(xs[i], maxX)
            maxY = max(ys[i], maxY)
        }
        let width = maxX - minX, height = maxY - minY
        let span = width * width + height * height
        let c = ((minX + maxX) / 2, (minY + maxY) / 2)
        var i0 = Self.invalid, i1 = Self.invalid, i2 = Self.invalid
        // a seed point close to the middle
        var minDist = Double.greatestFiniteMagnitude
        for i in 0..<n {
            let d = Self.dist2(c.0, c.1, xs[i], ys[i])
            if d < minDist {
                i0 = i
                minDist = d
            }
        }
        guard i0 != Self.invalid else { throw NotTriangulation() }
        // the point closest to it
        minDist = Double.greatestFiniteMagnitude
        for i in 0..<n where i != i0 {
            let d = Self.dist2(xs[i0], ys[i0], xs[i], ys[i])
            if d < minDist && d > 0 {
                i1 = i
                minDist = d
            }
        }
        guard i1 != Self.invalid else { throw NotTriangulation() }
        // the third making the smallest circle with them
        var minRadius = Double.greatestFiniteMagnitude
        for i in 0..<n where i != i0 && i != i1 {
            let r = Self.circumradius(xs[i0], ys[i0], xs[i1], ys[i1], xs[i], ys[i])
            if r < minRadius {
                i2 = i
                minRadius = r
            }
        }
        guard minRadius < Double.greatestFiniteMagnitude else { throw NotTriangulation() }
        if Self.counterclockwise(xs[i0], ys[i0], xs[i1], ys[i1], xs[i2], ys[i2]) { swap(&i1, &i2) }
        let (i0x, i0y, i1x, i1y, i2x, i2y) = (xs[i0], ys[i0], xs[i1], ys[i1], xs[i2], ys[i2])
        center = Self.circumcenter(i0x, i0y, i1x, i1y, i2x, i2y)
        // the points by their distance from the seed triangle's circumcentre
        var dists: [Double] = []
        dists.reserveCapacity(n)
        for i in 0..<n {
            let dx = xs[i] - center.x, dy = ys[i] - center.y
            dists.append(dx * dx + dy * dy)
        }
        Clipper.introSort(&ids) { dists[$0] < dists[$1] }
        // the hash of the advancing convex hull's edges
        hashSize = Int(Double(n).squareRoot().rounded(.up))
        hash = Array(repeating: Self.invalid, count: hashSize)
        hullPrev = Array(repeating: 0, count: n)
        hullNext = Array(repeating: 0, count: n)
        hullTri = Array(repeating: 0, count: n)
        hullStart = i0
        hullNext[i0] = i1; hullPrev[i2] = i1
        hullNext[i1] = i2; hullPrev[i0] = i2
        hullNext[i2] = i0; hullPrev[i1] = i0
        hullTri[i0] = 0
        hullTri[i1] = 1
        hullTri[i2] = 2
        hash[hashKey(i0x, i0y)] = i0
        hash[hashKey(i1x, i1y)] = i1
        hash[hashKey(i2x, i2y)] = i2
        let maxTriangles = n < 3 ? 1 : 2 * n - 5
        triangles.reserveCapacity(maxTriangles * 3)
        halfedges.reserveCapacity(maxTriangles * 3)
        _ = addTriangle(i0, i1, i2, Self.invalid, Self.invalid, Self.invalid)
        var xp = Double.nan, yp = Double.nan
        for k in 0..<n {
            let i = ids[k]
            let x = xs[i], y = ys[i]
            // (near-duplicate points, and the seed triangle's, skipped)
            if k > 0 && Self.pointsEqual(x, y, xp, yp) { continue }
            xp = x
            yp = y
            if Self.pointsEqual(x, y, i0x, i0y) || Self.pointsEqual(x, y, i1x, i1y) || Self.pointsEqual(x, y, i2x, i2y) { continue }
            // a visible edge of the hull, by the hash
            var start = 0
            let key = hashKey(x, y)
            for j in 0..<hashSize {
                start = hash[Self.fastMod(key + j, hashSize)]
                if start != Self.invalid && start != hullNext[start] { break }
            }
            start = hullPrev[start]
            var e = start
            var q: Int
            while true {
                q = hullNext[e]
                if Self.equal(x, y, xs[e], ys[e], span) || Self.equal(x, y, xs[q], ys[q], span) {
                    e = Self.invalid
                    break
                }
                if Self.counterclockwise(x, y, xs[e], ys[e], xs[q], ys[q]) { break }
                e = q
                if e == start {
                    e = Self.invalid
                    break
                }
            }
            if e == Self.invalid { continue }
            // the first triangle from the point
            var t = addTriangle(e, i, hullNext[e], Self.invalid, Self.invalid, hullTri[e])
            hullTri[i] = legalize(t + 2)
            hullTri[e] = t
            // forward round the hull, adding triangles and flipping
            var next = hullNext[e]
            while true {
                q = hullNext[next]
                if !Self.counterclockwise(x, y, xs[next], ys[next], xs[q], ys[q]) { break }
                t = addTriangle(next, i, q, hullTri[i], Self.invalid, hullTri[next])
                hullTri[i] = legalize(t + 2)
                hullNext[next] = next
                next = q
            }
            // and backward from the other side
            if e == start {
                while true {
                    q = hullPrev[e]
                    if !Self.counterclockwise(x, y, xs[q], ys[q], xs[e], ys[e]) { break }
                    t = addTriangle(q, i, e, Self.invalid, hullTri[e], hullTri[q])
                    _ = legalize(t + 2)
                    hullTri[q] = t
                    hullNext[e] = e
                    e = q
                }
            }
            hullPrev[i] = e
            hullStart = e
            hullPrev[next] = i
            hullNext[e] = i
            hullNext[i] = next
            hash[hashKey(x, y)] = i
            hash[hashKey(xs[e], ys[e])] = e
        }
    }

    private mutating func legalize(_ aIn: Int) -> Int {
        var a = aIn
        var i = 0
        var ar = 0
        edgeStack.removeAll(keepingCapacity: true)
        while true {
            let b = halfedges[a]
            let a0 = 3 * (a / 3)
            ar = a0 + (a + 2) % 3
            if b == Self.invalid {
                if i > 0 {
                    i -= 1
                    a = edgeStack[i]
                    continue
                }
                break
            }
            let b0 = 3 * (b / 3)
            let al = a0 + (a + 1) % 3
            let bl = b0 + (b + 2) % 3
            let p0 = triangles[ar], pr = triangles[a], pl = triangles[al], p1 = triangles[bl]
            if Self.inCircle(xs[p0], ys[p0], xs[pr], ys[pr], xs[pl], ys[pl], xs[p1], ys[p1]) {
                triangles[a] = p1
                triangles[b] = p0
                let hbl = halfedges[bl]
                // (an edge swapped on the hull's other side)
                if hbl == Self.invalid {
                    var e = hullStart
                    repeat {
                        if hullTri[e] == bl {
                            hullTri[e] = a
                            break
                        }
                        e = hullPrev[e]
                    } while e != hullStart
                }
                link(a, hbl)
                link(b, halfedges[ar])
                link(ar, bl)
                let br = b0 + (b + 1) % 3
                if i < edgeStack.count { edgeStack[i] = br } else { edgeStack.append(br) }
                i += 1
            } else {
                if i > 0 {
                    i -= 1
                    a = edgeStack[i]
                    continue
                }
                break
            }
        }
        return ar
    }

    private func hashKey(_ x: Double, _ y: Double) -> Int {
        let v = (Self.pseudoAngle(x - center.x, y - center.y) * Double(hashSize)).rounded(.down)
        // (std::llround, as x86 has it of what it cannot round: the least long; and that as a size_t)
        let r: UInt = v.isNaN || v >= 0x1p63 || v < -0x1p63 ? UInt(bitPattern: Int.min) : UInt(bitPattern: Int(v.rounded()))
        let size = UInt(hashSize)
        return Int(r >= size ? r % size : r)
    }

    private mutating func addTriangle(_ i0: Int, _ i1: Int, _ i2: Int, _ a: Int, _ b: Int, _ c: Int) -> Int {
        let t = triangles.count
        triangles += [i0, i1, i2]
        link(t, a)
        link(t + 1, b)
        link(t + 2, c)
        return t
    }

    private mutating func link(_ a: Int, _ b: Int) {
        if a == halfedges.count { halfedges.append(b) } else { halfedges[a] = b }
        if b != Self.invalid {
            if b == halfedges.count { halfedges.append(a) } else { halfedges[b] = a }
        }
    }

    // MARK: - Its arithmetic

    private static func fastMod(_ i: Int, _ c: Int) -> Int { i >= c ? i % c : i }

    private static func dist2(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double {
        let dx = bx - ax, dy = by - ay
        return dx * dx + dy * dy
    }

    /// (Point::equal)
    private static func equal(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ span: Double) -> Bool {
        dist2(ax, ay, bx, by) / span < 1e-20
    }

    /// (circumradius of three Points)
    private static func circumradius(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ cx: Double, _ cy: Double) -> Double {
        let dx = bx - ax, dy = by - ay, ex = cx - ax, ey = cy - ay
        let bl = dx * dx + dy * dy, cl = ex * ex + ey * ey
        let det = dx * ey - dy * ex
        let rx = (ey * bl - dy * cl) * 0.5 / det, ry = (dx * cl - ex * bl) * 0.5 / det
        if bl != 0 && cl != 0 && det != 0 { return rx * rx + ry * ry }
        return Double.greatestFiniteMagnitude
    }

    private static func counterclockwise(_ px: Double, _ py: Double, _ qx: Double, _ qy: Double, _ rx: Double, _ ry: Double) -> Bool {
        let v0x = qx - px, v0y = qy - py, v1x = rx - px, v1y = ry - py
        let det = v0x * v1y - v0y * v1x
        let dist = (v0x * v0x + v0y * v0y) + (v1x * v1x + v1y * v1y)
        if det == 0 { return false }
        if abs(dist / det) > 1e14 { return false }
        return det > 0
    }

    private static func circumcenter(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ cx: Double, _ cy: Double) -> (x: Double, y: Double) {
        let dx = bx - ax, dy = by - ay, ex = cx - ax, ey = cy - ay
        let bl = dx * dx + dy * dy, cl = ex * ex + ey * ey
        let d = dx * ey - dy * ex
        return (ax + (ey * bl - dy * cl) * 0.5 / d, ay + (dx * cl - ex * bl) * 0.5 / d)
    }

    private static func inCircle(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ cx: Double, _ cy: Double,
                                 _ px: Double, _ py: Double) -> Bool {
        let dx = ax - px, dy = ay - py, ex = bx - px, ey = by - py, fx = cx - px, fy = cy - py
        let ap = dx * dx + dy * dy, bp = ex * ex + ey * ey, cp = fx * fx + fy * fy
        return (dx * (ey * cp - bp * fy) - dy * (ex * cp - bp * fx) + ap * (ex * fy - ey * fx)) < 0
    }

    private static func pointsEqual(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Bool {
        abs(x1 - x2) <= Double.ulpOfOne && abs(y1 - y2) <= Double.ulpOfOne
    }

    private static func pseudoAngle(_ dx: Double, _ dy: Double) -> Double {
        let p = dx / (abs(dx) + abs(dy))
        return (dy > 0 ? 3 - p : 1 + p) / 4
    }
}
