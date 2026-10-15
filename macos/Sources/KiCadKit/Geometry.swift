import Foundation

/// A point on a board in millimetres, x to the right and y down, as KiCad has them
public struct KiCadPoint: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    public static let zero = KiCadPoint(0, 0)

    public static func + (a: KiCadPoint, b: KiCadPoint) -> KiCadPoint { KiCadPoint(a.x + b.x, a.y + b.y) }
    public static func - (a: KiCadPoint, b: KiCadPoint) -> KiCadPoint { KiCadPoint(a.x - b.x, a.y - b.y) }
    public static func * (a: KiCadPoint, k: Double) -> KiCadPoint { KiCadPoint(a.x * k, a.y * k) }

    public var length: Double { (x * x + y * y).squareRoot() }

    public func distance(to p: KiCadPoint) -> Double { (self - p).length }

    /// Turned by `degrees` about the origin as KiCad turns things (RotatePoint): counter-clockwise on the screen, whose
    /// y runs down; quarter turns exactly
    public func rotated(_ degrees: Double) -> KiCadPoint {
        var a = degrees.truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        switch a {
        case 0: return self
        case 90: return KiCadPoint(y, -x)
        case 180: return KiCadPoint(-x, -y)
        case 270: return KiCadPoint(-y, x)
        default:
            let r = a * .pi / 180
            let (s, c) = (sin(r), cos(r))
            return KiCadPoint(y * s + x * c, y * c - x * s)
        }
    }
}

/// A box on the board, edges included
public struct KiCadBox: Hashable, Sendable {
    public var minX, minY, maxX, maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        (self.minX, self.minY, self.maxX, self.maxY) = (minX, minY, maxX, maxY)
    }

    public init?(_ points: [KiCadPoint]) {
        guard let first = points.first else { return nil }
        self.init(minX: first.x, minY: first.y, maxX: first.x, maxY: first.y)
        for p in points.dropFirst() { include(p) }
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var center: KiCadPoint { KiCadPoint((minX + maxX) / 2, (minY + maxY) / 2) }

    public mutating func include(_ p: KiCadPoint) {
        minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y)
    }

    public mutating func include(_ box: KiCadBox) {
        include(KiCadPoint(box.minX, box.minY)); include(KiCadPoint(box.maxX, box.maxY))
    }

    public func inflated(_ d: Double) -> KiCadBox { KiCadBox(minX: minX - d, minY: minY - d, maxX: maxX + d, maxY: maxY + d) }

    public func contains(_ p: KiCadPoint) -> Bool { p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY }

    public func intersects(_ b: KiCadBox) -> Bool { minX <= b.maxX && b.minX <= maxX && minY <= b.maxY && b.minY <= maxY }
}

/// Where a footprint puts its own drawing: its position and its turn (its side is in its items already, KiCad
/// mirroring them as it flips the footprint)
public struct KiCadPlacement: Hashable, Sendable {
    public var position: KiCadPoint
    public var rotation: Double

    public init(position: KiCadPoint, rotation: Double) { self.position = position; self.rotation = rotation }

    public func apply(_ local: KiCadPoint) -> KiCadPoint { position + local.rotated(rotation) }

    public func local(_ board: KiCadPoint) -> KiCadPoint { (board - position).rotated(-rotation) }
}

/// The outline of a shape, as a polygon (arcs and circles in short straight pieces)
public enum KiCadPolygon {
    /// The corners of a `width` × `height` rectangle about `center`, turned by `rotation`, its corners rounded by
    /// `radius` (in `segments` pieces each)
    public static func roundedRect(center: KiCadPoint, width: Double, height: Double, rotation: Double, radius: Double = 0,
                                   segments: Int = 4) -> [KiCadPoint] {
        let (hw, hh) = (width / 2, height / 2)
        let r = min(radius, hw, hh)
        var local: [KiCadPoint] = []
        if r <= 0 {
            local = [KiCadPoint(-hw, -hh), KiCadPoint(hw, -hh), KiCadPoint(hw, hh), KiCadPoint(-hw, hh)]
        } else {
            let corners = [(KiCadPoint(hw - r, hh - r), 0.0), (KiCadPoint(-hw + r, hh - r), 90.0),
                           (KiCadPoint(-hw + r, -hh + r), 180.0), (KiCadPoint(hw - r, -hh + r), 270.0)]
            for (c, start) in corners {
                for k in 0...segments {
                    let a = (start + 90 * Double(k) / Double(segments)) * .pi / 180
                    local.append(KiCadPoint(c.x + r * cos(a), c.y + r * sin(a)))
                }
            }
        }
        return local.map { center + $0.rotated(rotation) }
    }

    public static func circle(center: KiCadPoint, radius: Double, segments: Int = 24) -> [KiCadPoint] {
        (0..<segments).map { k in
            let a = 2 * Double.pi * Double(k) / Double(segments)
            return KiCadPoint(center.x + radius * cos(a), center.y + radius * sin(a))
        }
    }

    /// A stadium: an oval pad, its round ends on the longer side
    public static func oval(center: KiCadPoint, width: Double, height: Double, rotation: Double) -> [KiCadPoint] {
        roundedRect(center: center, width: width, height: height, rotation: rotation, radius: min(width, height) / 2, segments: 8)
    }

    /// The points of the arc through `start`, `mid` and `end`
    public static func arc(start: KiCadPoint, mid: KiCadPoint, end: KiCadPoint, segments: Int = 16) -> [KiCadPoint] {
        guard let c = circleCenter(start, mid, end) else { return [start, end] }
        let r = c.distance(to: start)
        let a0 = atan2(start.y - c.y, start.x - c.x)
        var a1 = atan2(mid.y - c.y, mid.x - c.x)
        var a2 = atan2(end.y - c.y, end.x - c.x)
        // the sweep that passes through the middle point
        func norm(_ a: Double) -> Double { var a = a; while a < a0 { a += 2 * .pi }; while a >= a0 + 2 * .pi { a -= 2 * .pi }; return a }
        a1 = norm(a1); a2 = norm(a2)
        if a1 > a2 { a2 -= 2 * .pi }
        return (0...segments).map { k in
            let a = a0 + (a2 - a0) * Double(k) / Double(segments)
            return KiCadPoint(c.x + r * cos(a), c.y + r * sin(a))
        }
    }

    /// The centre of the circle through three points, unless they are in a line
    public static func circleCenter(_ a: KiCadPoint, _ b: KiCadPoint, _ c: KiCadPoint) -> KiCadPoint? {
        let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
        guard abs(d) > 1e-12 else { return nil }
        let (a2, b2, c2) = (a.x * a.x + a.y * a.y, b.x * b.x + b.y * b.y, c.x * c.x + c.y * c.y)
        return KiCadPoint((a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d,
                          (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d)
    }

    /// Whether `p` is inside `polygon` (even-odd)
    public static func contains(_ polygon: [KiCadPoint], _ p: KiCadPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let (a, b) = (polygon[i], polygon[j])
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// The distance from `p` to the segment from `a` to `b`
    public static func distance(_ p: KiCadPoint, toSegment a: KiCadPoint, _ b: KiCadPoint) -> Double {
        let d = b - a
        let len2 = d.x * d.x + d.y * d.y
        guard len2 > 0 else { return p.distance(to: a) }
        let t = max(0, min(1, ((p.x - a.x) * d.x + (p.y - a.y) * d.y) / len2))
        return p.distance(to: a + d * t)
    }

    /// The distance from `p` to a polygon's edge, 0 inside it
    public static func distance(_ p: KiCadPoint, to polygon: [KiCadPoint]) -> Double {
        if contains(polygon, p) { return 0 }
        var best = Double.infinity
        var j = polygon.count - 1
        for i in polygon.indices {
            best = min(best, distance(p, toSegment: polygon[j], polygon[i]))
            j = i
        }
        return best
    }

    /// The distance between two segments (0 where they cross)
    public static func distance(segment a: KiCadPoint, _ b: KiCadPoint, segment c: KiCadPoint, _ d: KiCadPoint) -> Double {
        func cross(_ o: KiCadPoint, _ p: KiCadPoint, _ q: KiCadPoint) -> Double { (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x) }
        let (d1, d2, d3, d4) = (cross(c, d, a), cross(c, d, b), cross(a, b, c), cross(a, b, d))
        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) { return 0 }
        return min(distance(a, toSegment: c, d), distance(b, toSegment: c, d), distance(c, toSegment: a, b), distance(d, toSegment: a, b))
    }
}
