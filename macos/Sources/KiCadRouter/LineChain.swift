// Ported from KiCad 10.0.7: libs/kimath/include/geometry/shape_line_chain.h and
// libs/kimath/src/geometry/shape_line_chain.cpp (its arcs too, as the router keeps them in its lines).
// Copyright (C) 2013 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// The arcs a point of a chain is on (KiCad's pair of shape indices): -1 for none. A point two arcs share, the end of
/// one and the start of the next, has both, the one it ends first.
public struct ShapeIndices: Hashable, Sendable {
    public var first: Int
    public var second: Int

    public init(_ first: Int, _ second: Int) {
        self.first = first
        self.second = second
    }

    /// A point on no arc (KiCad's SHAPES_ARE_PT)
    public static let point = ShapeIndices(-1, -1)

    /// Whether either is `index` (alg::pair_contains)
    func contains(_ index: Int) -> Bool { first == index || second == index }

    /// Each index that is an arc's changed by `f`
    func mapArcs(_ f: (Int) -> Int) -> ShapeIndices {
        ShapeIndices(first == -1 ? -1 : f(first), second == -1 ? -1 : f(second))
    }
}

/// A polyline, open or closed, of straight segments and arcs (KiCad's SHAPE_LINE_CHAIN): a trace's path, an
/// obstacle's hull. An arc is kept both as points, a polyline a micrometre from it at most, and as the arc itself,
/// which collisions use; each point knows the arcs it is on. Indices wrap as KiCad's do: -1 is the last point.
public struct LineChain: Hashable, Sendable, CustomStringConvertible {
    public internal(set) var points: [IPoint] = []
    /// The arcs each point is on (KiCad's m_shapes), one for each point
    public internal(set) var shapes: [ShapeIndices] = []
    /// The arcs, of no width (KiCad's m_arcs)
    public internal(set) var arcs: [ShapeArc] = []
    public private(set) var isClosed = false

    /// Where two chains cross (KiCad's SHAPE_LINE_CHAIN::INTERSECTION)
    public struct Intersection: Sendable {
        public var p: IPoint
        /// The crossing segment (or corner) of this chain, and of the other
        public var indexOur = -1
        public var indexTheir = -1
        /// Whether the crossing is exactly this chain's corner, or the other's
        public var isCornerOur = false
        public var isCornerTheir = false
        public var valid = false

        public init(p: IPoint) { self.p = p }
    }

    /// How far from an arc the points a chain keeps of it may be (KiCad's getArcPolygonizationMaxError: a fifth of
    /// ARC_HIGH_DEF, for they are drawn)
    public static let arcPolygonizationMaxError = 5000 / 5

    public init() {}

    public init(_ points: [IPoint], closed: Bool = false) {
        self.points = points
        shapes = Array(repeating: .point, count: points.count)
        setClosed(closed)
    }

    /// An arc's points, and the arc (KiCad's SHAPE_LINE_CHAIN( SHAPE_ARC ))
    public init(arc: ShapeArc, closed: Bool = false, maxError: Int = LineChain.arcPolygonizationMaxError) {
        append(arc, maxError: maxError)
        setClosed(closed)
    }

    public var description: String {
        "LineChain(" + points.map(\.description).joined(separator: ", ") + (isClosed ? ", closed)" : ")")
            + (arcs.isEmpty ? "" : " arcs \(arcs)")
    }

    /// The same points, open or closed alike (KiCad compares chains by their points alone)
    public static func == (a: LineChain, b: LineChain) -> Bool { a.points == b.points && a.isClosed == b.isClosed }

    public func hash(into h: inout Hasher) {
        h.combine(points)
        h.combine(isClosed)
    }

    // MARK: - Points and segments

    public var pointCount: Int { points.count }

    public var segmentCount: Int { max(0, points.count - 1 + (isClosed ? 1 : 0)) }

    public func point(_ i: Int) -> IPoint {
        var i = i
        if i < 0 { i += points.count } else if i >= points.count { i -= points.count }
        return points[i]
    }

    public var lastPoint: IPoint { points[points.count - 1] }

    public func segment(_ i: Int) -> Seg {
        let count = segmentCount
        var i = i
        if i < 0 { i += count }
        guard i >= 0 && i < count else { return points.isEmpty ? Seg(.zero, .zero) : Seg(points[points.count - 1], points[points.count - 1]) }
        if i == points.count - 1 && isClosed { return Seg(points[i], points[0], index: i) }
        return Seg(points[i], points[i + 1], index: i)
    }

    public var segments: [Seg] { (0..<segmentCount).map(segment) }

    public mutating func setClosed(_ closed: Bool) {
        isClosed = closed
        mergeFirstLastPointIfNeeded()
    }

    /// A closed chain's last point, the same as its first, merged into it (an arc ending there kept, the chain turned
    /// to start where an arc starts); an open chain's first point, if two arcs share it, made two
    private mutating func mergeFirstLastPointIfNeeded() {
        if isClosed {
            if points.count > 1 && points[0] == points[points.count - 1] {
                if arcIndex(shapes.count - 1) != -1 {
                    shapes[0].second = shapes[0].first
                    shapes[0].first = arcIndex(shapes.count - 1)
                }
                points.removeLast()
                shapes.removeLast()
                fixIndicesRotation()
            }
        } else if points.count > 1 && isSharedPoint(0) {
            // (a duplicate point at the end)
            points.append(points[0])
            shapes.append(ShapeIndices(shapes[0].first, -1))
            shapes[0].first = shapes[0].second
            shapes[0].second = -1
        }
    }

    /// The points turned so that no arc runs from the end round to the start (KiCad's fixIndicesRotation)
    private mutating func fixIndicesRotation() {
        guard shapes.count == points.count, shapes.count > 1 else { return }
        var rotations = 0
        while arcIndex(0) != -1 && !isArcStart(0) {
            points.insert(points.removeLast(), at: 0)
            shapes.insert(shapes.removeLast(), at: 0)
            // (KiCad's guard against going round for ever)
            if rotations > shapes.count { return }
            rotations += 1
        }
    }

    /// The arc made points only, its references gone (KiCad's convertArc)
    private mutating func convertArc(_ arcIndex: Int) {
        var a = arcIndex
        if a < 0 { a += arcs.count }
        guard a >= 0 && a < arcs.count else { return }
        for i in shapes.indices {
            var sh = shapes[i]
            if sh.first == a { sh.first = -1 }
            if sh.first > a { sh.first -= 1 }
            if sh.second == a { sh.second = -1 }
            if sh.second > a { sh.second -= 1 }
            if sh.second != -1 && sh.first == -1 { swap(&sh.first, &sh.second) }
            shapes[i] = sh
        }
        arcs.remove(at: a)
    }

    /// The arc given new ends, about its centre still (KiCad's amendArc: its width lost, as KiCad's new arc has none)
    private mutating func amendArc(_ arcIndex: Int, _ newStart: IPoint, _ newEnd: IPoint) {
        guard arcIndex >= 0 && arcIndex < arcs.count else { return }
        let a = arcs[arcIndex]
        arcs[arcIndex] = ShapeArc(start: newStart, end: newEnd, center: a.center, clockwise: a.isClockwise)
    }

    /// The arc point `ptIndex` is on split there into two arcs: meeting at it (`coincident`), or with a segment from
    /// the point before it (KiCad's splitArc)
    private mutating func splitArc(_ ptIndex: Int, coincident: Bool = false) {
        var p = ptIndex
        if p < 0 { p += shapes.count }
        if !isSharedPoint(p) && isArcStart(p) { return }
        if !isPointOnArc(p) { return }
        if isSharedPoint(p) || isArcEnd(p) {
            if coincident || p == 0 { return }
            let firstArcIndex = shapes[p].first
            // (its start kept)
            amendArc(firstArcIndex, arcs[firstArcIndex].start, points[p - 1])
            if isSharedPoint(p) {
                shapes[p].first = shapes[p].second
                shapes[p].second = -1
            } else {
                shapes[p] = .point
            }
            return
        }
        let currArcIdx = arcIndex(p)
        let currentArc = arcs[currArcIdx]
        let arc1End = coincident ? points[p] : points[p - 1]
        let arc2Start = points[p]
        let newArc1 = ShapeArc(start: currentArc.start, end: arc1End, center: currentArc.center, clockwise: currentArc.isClockwise)
        let newArc2 = ShapeArc(start: arc2Start, end: currentArc.end, center: currentArc.center, clockwise: currentArc.isClockwise)
        if !coincident && arcIndex(p - 1) != currArcIdx {
            // (the first half would have no points)
            arcs[currArcIdx] = newArc2
        } else {
            arcs[currArcIdx] = newArc1
            arcs.insert(newArc2, at: currArcIdx + 1)
            if coincident {
                shapes[p].second = currArcIdx + 1
                p += 1
            }
            // (the arcs of the points from here on renumbered, whatever their order)
            for i in p..<points.count { shapes[i] = shapes[i].mapArcs { $0 + 1 } }
        }
    }

    /// Moves a point, making points of the arcs it was on (KiCad's SetPoint)
    public mutating func setPoint(_ i: Int, _ p: IPoint) {
        var i = i
        if i < 0 { i += points.count } else if i >= points.count { i -= points.count }
        points[i] = p
        // (the second read once the first is gone, as KiCad's run_on_pair reads it)
        if shapes[i].first != -1 { convertArc(shapes[i].first) }
        if shapes[i].second != -1 { convertArc(shapes[i].second) }
    }

    public mutating func clear() {
        points.removeAll()
        arcs.removeAll()
        shapes.removeAll()
        isClosed = false
    }

    // MARK: - Arcs

    public var arcCount: Int { arcs.count }

    /// Whether two arcs share the point, the end of one and the start of the next (KiCad's IsSharedPt)
    public func isSharedPoint(_ i: Int) -> Bool { i >= 0 && i < shapes.count && shapes[i].first != -1 && shapes[i].second != -1 }

    public func isPointOnArc(_ i: Int) -> Bool { i >= 0 && i < shapes.count && shapes[i] != .point }

    /// The arc the segment from point `i` is on (at a point two arcs share, the one it starts), or -1
    public func arcIndex(_ i: Int) -> Int { isSharedPoint(i) ? shapes[i].second : shapes[i].first }

    /// The arc the segment to point `i` is on (at a point two arcs share, the one it ends)
    func reversedArcIndex(_ i: Int) -> Int { isSharedPoint(i) ? shapes[i].first : shapes[i].second }

    /// Whether the segment from point `i` to the next is a piece of an arc (not the segment between two arcs that
    /// share no point)
    public func isArcSegment(_ i: Int) -> Bool {
        guard i >= 0 else { return false }
        var next = i + 1
        if next > shapes.count - 1 {
            if next == shapes.count && isClosed && isSharedPoint(0) {
                next = 0
            } else {
                return false
            }
        }
        return isPointOnArc(i) && arcIndex(i) == shapes[next].first
    }

    public func isArcStart(_ i: Int) -> Bool {
        guard isArcSegment(i) else { return false }
        if isSharedPoint(i) { return true }
        return arcs[arcIndex(i)].start == points[i]
    }

    public func isArcEnd(_ i: Int) -> Bool {
        guard i >= 0 && i <= points.count - 1 else { return false }
        guard isArcSegment(i == 0 ? points.count - 1 : i - 1) else { return false }
        if isSharedPoint(i) { return true }
        return arcs[arcIndex(i)].end == points[i]
    }

    /// The point the next shape (segment or arc) starts at, or -1 after the last (KiCad's NextShape)
    public func nextShape(_ pointIndex: Int) -> Int {
        var p = pointIndex
        if p < 0 { p += points.count }
        if p < 0 { return -1 }
        let lastIndex = points.count - 1
        if p >= lastIndex { return -1 }
        if shapes[p] == .point {
            if p == lastIndex - 1 { return isClosed ? lastIndex : -1 }
            return p + 1
        }
        let arcStart = p
        guard shapes[p].first != -1 else { return -1 }
        let currentArcIdx = arcIndex(p)
        // the rest of the arc skipped
        while p < lastIndex && arcIndex(p) == currentArcIdx { p += 1 }
        let indexStillOnArc = shapes[p].contains(currentArcIdx)
        // (the arc's last point, if it started at its first)
        if p - arcStart > 1 && !indexStillOnArc { p -= 1 }
        if p == lastIndex { return !isClosed || isArcSegment(p) ? -1 : lastIndex }
        return p
    }

    /// How many segments and arcs (an arc counted once)
    public var shapeCount: Int {
        if points.count < 2 { return 0 }
        var n = 1
        var i = nextShape(0)
        while i != -1 {
            n += 1
            i = nextShape(i)
        }
        return n
    }

    /// The arcs made points only (KiCad's ClearArcs)
    public mutating func clearArcs() {
        for a in arcs.indices.reversed() { convertArc(a) }
    }

    // MARK: - Building

    public mutating func append(_ p: IPoint, allowDuplication: Bool = false) {
        if points.isEmpty || allowDuplication || points[points.count - 1] != p {
            points.append(p)
            shapes.append(.point)
        }
    }

    public mutating func append(_ x: Int, _ y: Int) { append(IPoint(x, y)) }

    /// Another chain's points and arcs, its first point left out if it is this one's last
    public mutating func append(_ other: LineChain) {
        guard !other.points.isEmpty else { return }
        let numArcs = arcs.count
        arcs.append(contentsOf: other.arcs)
        func fixed(_ s: ShapeIndices) -> ShapeIndices { s.mapArcs { $0 + numArcs } }
        if points.isEmpty || other.points[0] != points[points.count - 1] {
            points.append(other.points[0])
            shapes.append(fixed(other.shapes[0]))
        } else if other.isArcSegment(0) {
            // (the arc taken on from the last point)
            if shapes[shapes.count - 1] == .point {
                shapes[shapes.count - 1].first = other.shapes[0].first + numArcs
            } else {
                shapes[shapes.count - 1].second = other.shapes[0].first + numArcs
            }
        }
        for i in 1..<other.points.count {
            points.append(other.points[i])
            shapes.append(other.arcIndex(i) != -1 ? fixed(other.shapes[i]) : .point)
        }
        mergeFirstLastPointIfNeeded()
    }

    /// An arc, as its points no more than `maxError` off it (two, a segment, if it is that small)
    public mutating func append(_ arc: ShapeArc, maxError: Int = LineChain.arcPolygonizationMaxError) {
        var chain = arc.convertToPolyline(maxError)
        if chain.pointCount > 2 {
            var a = arc
            a.width = 0
            chain.arcs.append(a)
            for i in chain.shapes.indices { chain.shapes[i].first = 0 }
        }
        append(chain)
    }

    public mutating func insert(_ p: IPoint, at vertex: Int) {
        if vertex == points.count {
            append(p)
            return
        }
        guard vertex >= 0 && vertex < points.count else { return }
        if vertex > 0 && isPointOnArc(vertex) { splitArc(vertex) }
        points.insert(p, at: vertex)
        shapes.insert(.point, at: vertex)
    }

    /// Removes points `start` to `end`, the arcs it cuts into made points (KiCad's Remove, its quirks too)
    public mutating func remove(_ start: Int, _ end: Int) {
        guard shapes.count == points.count else { return }
        // (unwrapped first, for an arc at the end that meets the start)
        let closed = isClosed
        setClosed(false)
        var (s, e) = (start, end)
        if e < 0 { e += points.count }
        if s < 0 { s += points.count }
        if s >= points.count || e >= points.count || s > e {
            setClosed(closed)
            return
        }
        // arcs split where the range cuts them, meeting there
        if !isArcStart(s) && isPointOnArc(s) { splitArc(s, coincident: false) }
        // (a point two arcs share not removed)
        if isSharedPoint(s) { s += 1 }
        if !isArcEnd(e) && isPointOnArc(e) && e < points.count - 1 { splitArc(e + 1, coincident: true) }
        if isSharedPoint(e) { e -= 1 }
        if s > e {
            setClosed(closed)
            return
        }
        // the arcs in the range made points: in order of their numbers, each by its number as it was before any was
        // made points, though making one points renumbers those after it (KiCad's way)
        var extraArcs = Set<Int>()
        for i in s...e {
            if isSharedPoint(i) {
                if i == s {
                    extraArcs.insert(shapes[i].second)
                    continue
                } else if i == e {
                    extraArcs.insert(shapes[i].first)
                    continue
                }
            } else {
                if shapes[i].first != -1 { extraArcs.insert(shapes[i].first) }
                if shapes[i].second != -1 { extraArcs.insert(shapes[i].second) }
            }
        }
        for arc in extraArcs.sorted() { convertArc(arc) }
        shapes.removeSubrange(s...e)
        points.removeSubrange(s...e)
        setClosed(closed)
    }

    public mutating func remove(_ i: Int) { remove(i, i) }

    /// Removes the segment from point `i`, or the whole arc it is on (KiCad's RemoveShape)
    public mutating func removeShape(_ pointIndex: Int) {
        var p = pointIndex
        if p < 0 { p += points.count }
        guard p >= 0 && p < points.count else { return }
        if shapes[p] == .point {
            remove(p)
            return
        }
        var start = p, end = p
        let arcIdx = arcIndex(p)
        if !isArcStart(start) {
            while start > 0 && arcIndex(start - 1) == arcIdx { start -= 1 }
        }
        // (-1 at the end of the chain: its last point)
        if !isArcEnd(end) || start == end { end = nextShape(end) }
        remove(start, end)
    }

    public mutating func replace(_ start: Int, _ end: Int, with p: IPoint) {
        remove(start, end)
        insert(p, at: start)
    }

    /// Points `start` to `end` replaced by `line`'s (its arcs put after this chain's)
    public mutating func replace(_ start: Int, _ end: Int, with line: LineChain) {
        var (s, e) = (start, end)
        if e < 0 { e += points.count }
        if s < 0 { s += points.count }
        var newLine = line
        if newLine.points.isEmpty {
            remove(s, e)
            return
        }
        // (a point the same at either end not put in twice)
        if newLine.points[0] == points[s] {
            s += 1
            newLine.remove(0)
            if newLine.points.isEmpty {
                remove(s, e)
                return
            }
        }
        if newLine.points[newLine.points.count - 1] == points[e] && e > 0 {
            e -= 1
            newLine.remove(-1)
        }
        remove(s, e)
        if newLine.points.isEmpty { return }
        let prevArcCount = arcs.count
        shapes.insert(contentsOf: newLine.shapes.map { $0.mapArcs { $0 + prevArcCount } }, at: s)
        points.insert(contentsOf: newLine.points, at: s)
        arcs.append(contentsOf: newLine.arcs)
    }

    /// Inserts `p` into the segment it lies on (within 2 nm), splitting an arc into two that meet there; its index,
    /// or -1 if it lies on none
    @discardableResult
    public mutating func split(_ p: IPoint, exact: Bool = false) -> Int {
        var ii = -1
        var minDist = 2
        let found = find(p)
        if found >= 0 && exact { return found }
        for s in 0..<segmentCount {
            let seg = segment(s)
            let d = seg.distance(p)
            if d < minDist && seg.a != p && seg.b != p {
                minDist = d
                if found < 0 { ii = s } else if s < found { ii = s }
            }
        }
        if ii < 0 { ii = found }
        if ii >= 0 {
            if point(ii) == p { return ii }
            let newIndex = ii + 1
            if isArcSegment(ii) {
                points.insert(p, at: newIndex)
                shapes.insert(ShapeIndices(arcIndex(ii), -1), at: newIndex)
                splitArc(newIndex, coincident: true)
            } else {
                insert(p, at: newIndex)
            }
            return newIndex
        }
        return -1
    }

    public func find(_ p: IPoint, threshold: Int = 0) -> Int {
        for s in 0..<points.count {
            if threshold == 0 ? points[s] == p : (points[s] - p).norm <= threshold { return s }
        }
        return -1
    }

    public func findSegment(_ p: IPoint, threshold: Int = 1) -> Int {
        for s in 0..<segmentCount where segment(s).distance(p) <= threshold { return s }
        return -1
    }

    /// Points `start` to `end`, inclusive, as an open chain (a point the same as the one before it left out): a whole
    /// arc in the range made points again from the arc, `maxError` off it, an arc the range cuts into kept as the
    /// part of it in the range (KiCad's Slice)
    public func slice(_ start: Int, _ end: Int, maxError: Int = LineChain.arcPolygonizationMaxError) -> LineChain {
        var (s, e) = (start, end)
        if e < 0 { e += points.count }
        if s < 0 { s += points.count }
        guard s >= 0, e >= 0, s < points.count, e < points.count, e >= s else { return LineChain() }
        var rv = LineChain()
        let numPoints = points.count
        if isArcSegment(s) && !isArcStart(s) {
            // starting inside an arc: the rest of it, from here
            let arcToSplitIndex = arcIndex(s)
            let arcToSplit = arcs[arcToSplitIndex]
            var i = s
            while i < points.count && arcToSplitIndex == arcIndex(i) {
                rv.points.append(points[i])
                rv.shapes.append(ShapeIndices(rv.arcs.count, -1))
                i += 1
            }
            rv.arcs.append(ShapeArc(start: points[s], end: arcToSplit.end, center: arcToSplit.center, clockwise: arcToSplit.isClockwise))
            s += rv.pointCount
        }
        var i = s
        while i <= e && i < numPoints {
            // (NextShape past the end)
            if i == -1 { return rv }
            let next = nextShape(i)
            let isLastShape = next < 0
            if isArcStart(i) {
                if (isLastShape && e != numPoints - 1) || next > e {
                    if i == e {
                        // a single point of an arc
                        rv.append(points[i])
                        return rv
                    }
                    // ending inside an arc: it, up to here
                    let arcIdx = arcIndex(i)
                    let currentArc = arcs[arcIdx]
                    while i <= e && i < numPoints {
                        if arcIdx != arcIndex(i) { break }
                        rv.points.append(points[i])
                        rv.shapes.append(ShapeIndices(rv.arcs.count, -1))
                        i += 1
                    }
                    rv.arcs.append(ShapeArc(start: currentArc.start, end: points[e], center: currentArc.center,
                                            clockwise: currentArc.isClockwise))
                    return rv
                }
                // the whole arc
                rv.append(arcs[arcIndex(i)], maxError: maxError)
                if isLastShape { return rv }
            } else {
                if i == s { rv.append(points[i]) }
                let nextPointIsArc = isLastShape ? false : isArcSegment(next)
                if !nextPointIsArc && i < segmentCount && i < e { rv.append(segment(i).b) }
            }
            i = next
        }
        return rv
    }

    /// The chain the other way round, its arcs too (each with its ends swapped, its centre kept)
    public func reversed() -> LineChain {
        var r = self
        r.points.reverse()
        r.shapes.reverse()
        r.arcs.reverse()
        let n = r.arcs.count
        for i in r.shapes.indices where r.shapes[i] != .point {
            var sh = r.shapes[i].mapArcs { n - $0 - 1 }
            // (a shared point's two the other way round)
            if sh.second != -1 { swap(&sh.first, &sh.second) }
            r.shapes[i] = sh
        }
        for i in r.arcs.indices { r.arcs[i].reverse() }
        return r
    }

    /// The chain mirrored in the line through `axis`, its points and its arcs (KiCad's Mirror( SEG ))
    public mutating func mirror(_ axis: Seg) {
        for i in points.indices { points[i] = axis.reflectPoint(points[i]) }
        for i in arcs.indices { arcs[i].mirror(axis) }
    }

    /// The chain split at the points of it nearest `start` and `end` (an arc's nearer end, not a point inside it):
    /// what comes before, between and after them (KiCad's Split)
    public func split(_ start: IPoint, _ end: IPoint) -> (pre: LineChain, mid: LineChain, post: LineChain) {
        let n = nearestPoint(end, allowInternalShapePoints: false)
        let m = nearestPoint(start, allowInternalShapePoints: false)
        var l = self
        l.split(n, exact: true)
        l.split(m, exact: true)
        var iStart = l.find(m), iEnd = l.find(n)
        if iStart > iEnd {
            l = l.reversed()
            iStart = l.find(m)
            iEnd = l.find(n)
        }
        return (l.slice(0, iStart), l.slice(iStart, iEnd), l.slice(iEnd, -1))
    }

    // MARK: - Measures

    /// Its length: its segments', its arcs' as arcs (each added as KiCad adds a double to its long long, cut)
    public var length: Int {
        var l = 0
        for i in 0..<segmentCount where !isArcSegment(i) { l += segment(i).length }
        for a in arcs { l = Int(Double(l) + a.length) }
        return l
    }

    public var bbox: IBox { IBox(points: points) ?? IBox(minX: 0, minY: 0, maxX: 0, maxY: 0) }

    public func bbox(_ clearance: Int) -> IBox { clearance == 0 ? bbox : bbox.inflated(clearance) }

    /// The length along the chain to `p`, which is on segment `index` (or the first segment it is on)
    public func pathLength(_ p: IPoint, index: Int = -1) -> Int {
        var sum = 0
        for i in 0..<segmentCount {
            let seg = segment(i)
            var match = true
            if index >= 0 { match = index == segmentCount ? i == segmentCount - 1 : i == index }
            if match { return sum + (p - seg.a).norm }
            sum += seg.length
        }
        return -1
    }

    public func pointAlong(_ length: Int) -> IPoint {
        var total = 0
        if length == 0 { return point(0) }
        for i in 0..<segmentCount {
            let s = segment(i)
            let l = s.length
            if total + l >= length { return s.a + (s.b - s.a).resized(length - total) }
            total += l
        }
        return lastPoint
    }

    public func area(absolute: Bool = true) -> Double {
        guard isClosed else { return 0 }
        var a = 0.0
        var j = points.count - 1
        for i in 0..<points.count {
            a += (Double(points[j].x) + Double(points[i].x)) * (Double(points[j].y) - Double(points[i].y))
            j = i
        }
        return absolute ? abs(a * 0.5) : -a * 0.5
    }

    // MARK: - Inside, on the edge, nearest

    public func pointInside(_ p: IPoint, accuracy: Int = 0) -> Bool {
        guard isClosed && points.count >= 3 else { return false }
        var inside = false
        let n = points.count
        var i = 0
        while i < n {
            let p1 = points[i]
            i += 1
            let p2 = points[i == n ? 0 : i]
            let diff = p2 - p1
            if diff.y == 0 { continue }
            let d = KiMath.rescale(diff.x, p.y - p1.y, diff.y)
            if ((p1.y >= p.y) != (p2.y >= p.y)) && (p.x - p1.x < d) { inside.toggle() }
        }
        return accuracy <= 1 ? inside : inside || pointOnEdge(p, accuracy: accuracy)
    }

    public func pointOnEdge(_ p: IPoint, accuracy: Int = 0) -> Bool { edgeContainingPoint(p, accuracy: accuracy) >= 0 }

    public func edgeContainingPoint(_ p: IPoint, accuracy: Int = 0) -> Int {
        let threshold = accuracy + 1
        let thresholdSq = threshold * threshold
        if points.isEmpty { return -1 }
        if points.count == 1 { return points[0].squaredDistance(p) <= thresholdSq ? 0 : -1 }
        for i in 0..<segmentCount {
            let s = segment(i)
            if s.a == p || s.b == p { return i }
            if s.squaredDistance(p) <= thresholdSq { return i }
        }
        return -1
    }

    public func checkClearance(_ p: IPoint, _ dist: Int) -> Bool {
        if points.isEmpty { return false }
        if points.count == 1 { return points[0] == p }
        for i in 0..<segmentCount {
            let s = segment(i)
            if s.a == p || s.b == p { return true }
            if s.distance(p) <= dist { return true }
        }
        return false
    }

    /// The point of the chain nearest `p`; unless `allowInternalShapePoints`, an arc's nearer end rather than a point
    /// inside it
    public func nearestPoint(_ p: IPoint, allowInternalShapePoints: Bool = true) -> IPoint {
        if points.isEmpty { return .zero }
        var nearest = nearestSegment(p)
        if !allowInternalShapePoints && nearest > 0 && nearest < points.count && isArcSegment(nearest) {
            // (an arc's ends snapped to)
            if (segment(nearest).a - p).norm > (segment(nearest).b - p).norm { nearest += 1 }
            // (a closed chain's last point, its next the first: KiCad reads past its points, the port does not)
            if nearest == points.count { return points[0] }
            if isArcStart(nearest) || isArcEnd(nearest) { return points[nearest] }
            let nearestArc = arcs[arcIndex(nearest)]
            return (nearestArc.start - p).norm > (nearestArc.end - p).norm ? nearestArc.end : nearestArc.start
        }
        return segment(nearest).nearestPoint(p)
    }

    /// The chain's point nearest the line through `seg`, and how near
    public func nearestPoint(_ seg: Seg, dist: inout Int) -> IPoint {
        if points.isEmpty { return .zero }
        var nearest = 0
        dist = Int(Int32.max)
        for i in 0..<points.count {
            let d = seg.lineDistance(points[i])
            if d < dist {
                dist = d
                nearest = i
            }
        }
        return points[nearest]
    }

    public func nearestSegment(_ p: IPoint) -> Int {
        var minD = Int.max, nearest = 0
        for i in 0..<segmentCount {
            let d = segment(i).distance(p)
            if d < minD {
                minD = d
                nearest = i
            }
        }
        return nearest
    }

    // MARK: - Collisions and intersections

    /// Whether `p` comes within `clearance` of the chain (or is inside it, closed): its segments, then its arcs as
    /// arcs
    public func collide(_ p: IPoint, clearance: Int, actual: inout Int?, location: inout IPoint?) -> Bool {
        if isClosed && pointInside(p, accuracy: clearance) {
            location = p
            actual = 0
            return true
        }
        var closest = Int.max
        let clearanceSq = clearance * clearance
        var nearest = IPoint.zero
        for i in 0..<segmentCount where !isArcSegment(i) {
            let pn = segment(i).nearestPoint(p)
            let d = (pn - p).squaredNorm
            if d < closest {
                nearest = pn
                closest = d
                if closest == 0 { break }
            }
        }
        if closest == 0 || closest < clearanceSq {
            location = nearest
            actual = Int(Double(closest).squareRoot())
            return true
        }
        for arc in arcs {
            if arc.collide(p, clearance: clearance, actual: &actual, location: &location) { return true }
        }
        return false
    }

    /// Whether `s` comes within `clearance` of the chain (or starts inside it, closed): its segments, then its arcs
    /// as arcs. When `wantActual` (KiCad asked how close), the nearest of the arcs that collide, else the first.
    public func collide(_ s: Seg, clearance: Int, wantActual: Bool = true, actual: inout Int?, location: inout IPoint?) -> Bool {
        if isClosed && pointInside(s.a) {
            location = s.a
            actual = 0
            return true
        }
        var closest = Int.max
        let clearanceSq = clearance * clearance
        var nearest = IPoint.zero
        for i in 0..<segmentCount where !isArcSegment(i) {
            let seg = segment(i)
            let d = seg.squaredDistance(s)
            if d < closest {
                nearest = seg.nearestPoint(s)
                closest = d
                if closest == 0 { break }
                // (not asked how close, any collision will do)
                if closest < clearanceSq && !wantActual { break }
            }
        }
        if closest == 0 || closest < clearanceSq {
            location = nearest
            actual = Int(Double(closest).squareRoot())
            return true
        }
        guard !arcs.isEmpty else { return false }
        var dist: Int? = Int(Int32.max)
        var closestDist = Int(Double(closest).squareRoot())
        for arc in arcs {
            var pos: IPoint?
            if arc.collide(s, clearance: clearance, wantActual: wantActual, actual: &dist, location: &pos) {
                if !wantActual { return true }
                if let d = dist, d < closestDist {
                    closestDist = d
                    nearest = pos ?? nearest
                }
            }
        }
        if closestDist == 0 || closestDist < clearance {
            location = nearest
            actual = closestDist
            return true
        }
        return false
    }

    public func collide(_ s: Seg, clearance: Int) -> Bool {
        var actual: Int?, location: IPoint?
        return collide(s, clearance: clearance, wantActual: false, actual: &actual, location: &location)
    }

    /// Where `s` crosses the chain, nearest its start first
    public func intersect(_ s: Seg) -> [Intersection] {
        var out: [Intersection] = []
        let n = points.count
        let sminX = min(s.a.x, s.b.x), smaxX = max(s.a.x, s.b.x), sminY = min(s.a.y, s.b.y), smaxY = max(s.a.y, s.b.y)
        for i in 0..<segmentCount {
            let pa = points[i], pb = points[i + 1 < n ? i + 1 : 0]
            if max(pa.x, pb.x) < sminX || min(pa.x, pb.x) > smaxX || max(pa.y, pb.y) < sminY || min(pa.y, pb.y) > smaxY { continue }
            if let p = Seg(pa, pb, index: i).intersect(s) {
                var x = Intersection(p: p)
                x.valid = true
                x.indexOur = i
                out.append(x)
            }
        }
        Clipper.introSort(&out) { (s.a - $0.p).norm < (s.a - $1.p).norm }
        return out
    }

    public func intersects(_ s: Seg) -> Bool {
        let n = points.count
        for i in 0..<segmentCount {
            let pa = points[i], pb = points[i + 1 < n ? i + 1 : 0]
            if Seg(pa, pb).intersects(s) { return true }
        }
        return false
    }

    /// Where this chain and `chain` cross (and, unless excluded, where they run together or touch)
    public func intersect(_ chain: LineChain, excludeColinearAndTouching: Bool = false) -> [Intersection] {
        let ours = segmentCount, theirs = chain.segmentCount
        if ours == 0 || theirs == 0 { return [] }
        let other = chain.bbox
        let theirSegs = (0..<theirs).map(chain.segment)
        // their segments by their leftmost x, as std::sort sorts them (segments with the same leftmost x end up in the
        // order its introsort leaves them in, which on longer chains is not the order they came in)
        var sorted = theirSegs.indices.map { i -> (minX: Int, maxX: Int, minY: Int, maxY: Int, i: Int) in
            let s = theirSegs[i]
            return (min(s.a.x, s.b.x), max(s.a.x, s.b.x), min(s.a.y, s.b.y), max(s.a.y, s.b.y), i)
        }
        Clipper.introSort(&sorted) { $0.minX < $1.minX }
        var out: [Intersection] = []
        let n = points.count
        for s1 in 0..<ours {
            let a1 = points[s1], b1 = points[s1 + 1 < n ? s1 + 1 : 0]
            let ominX = min(a1.x, b1.x), omaxX = max(a1.x, b1.x), ominY = min(a1.y, b1.y), omaxY = max(a1.y, b1.y)
            if omaxX < other.minX || ominX > other.maxX || omaxY < other.minY || ominY > other.maxY { continue }
            let a = Seg(a1, b1, index: s1)
            for e in sorted {
                if e.minX > omaxX { break }
                if e.maxX < ominX || e.maxY < ominY || e.minY > omaxY { continue }
                let b = theirSegs[e.i]
                var x = Intersection(p: .zero)
                x.indexOur = s1
                x.indexTheir = e.i
                x.valid = true
                let p = a.intersect(b)
                if !excludeColinearAndTouching && a.collinear(b) {
                    // (one record, as KiCad's: what one end sets stays set for the next)
                    if a.contains(b.a) {
                        x.p = b.a
                        x.isCornerTheir = true
                        out.append(x)
                    }
                    if a.contains(b.b) {
                        x.p = b.b
                        x.indexTheir += 1
                        x.isCornerTheir = true
                        out.append(x)
                    }
                    if b.contains(a.a) {
                        x.p = a.a
                        x.isCornerOur = true
                        out.append(x)
                    }
                    if b.contains(a.b) {
                        x.p = a.b
                        x.indexOur += 1
                        x.isCornerOur = true
                        out.append(x)
                    }
                } else if let p {
                    x.p = p
                    if p == a.a { x.isCornerOur = true }
                    if p == a.b {
                        x.isCornerOur = true
                        x.indexOur += 1
                    }
                    if p == b.a { x.isCornerTheir = true }
                    if p == b.b {
                        x.isCornerTheir = true
                        x.indexTheir += 1
                    }
                    out.append(x)
                }
            }
        }
        return out
    }

    public func intersects(_ chain: LineChain) -> Bool { !intersect(chain).isEmpty }

    /// Where the chain first crosses itself (its points only, its arcs as their segments)
    public func selfIntersecting() -> Intersection? {
        let segs = segmentCount, n = points.count
        if segs < 2 { return nil }
        func end(_ i: Int) -> Int { i + 1 < n ? i + 1 : 0 }
        for s1 in 0..<segs {
            let a1 = points[s1], b1 = points[end(s1)]
            let minX1 = min(a1.x, b1.x) - 2, maxX1 = max(a1.x, b1.x) + 2, minY1 = min(a1.y, b1.y) - 2, maxY1 = max(a1.y, b1.y) + 2
            for s2 in (s1 + 1)..<max(s1 + 1, segs) {
                let a2 = points[s2], b2 = points[end(s2)]
                if maxX1 < min(a2.x, b2.x) || max(a2.x, b2.x) < minX1 { continue }
                if maxY1 < min(a2.y, b2.y) || max(a2.y, b2.y) < minY1 { continue }
                let seg1 = Seg(a1, b1, index: s1)
                var x = Intersection(p: .zero)
                x.indexOur = s1
                x.indexTheir = s2
                if s1 + 1 != s2 && seg1.contains(a2) {
                    x.p = a2
                    return x
                } else if seg1.contains(b2) && !(isClosed && s1 == 0 && s2 == segs - 1) {
                    x.p = b2
                    return x
                } else if let p = seg1.intersect(Seg(a2, b2, index: s2), ignoreEndpoints: true) {
                    x.p = p
                    return x
                }
            }
        }
        return nil
    }

    // MARK: - Simplifying

    /// KiCad's Simplify: removes points that lie within `tolerance` of the line through their neighbours (none of
    /// them on an arc; the arcs themselves kept, whether their points are or not)
    public mutating func simplify(_ tolerance: Int = 0) {
        let n = points.count
        if n < 3 { return }
        var out: [IPoint] = []
        var outShapes: [ShapeIndices] = []
        var start = 0
        while start < n {
            out.append(points[start])
            outShapes.append(shapes[start])
            if !isClosed && start == n - 2 { break }
            var end = (start + 2) % n
            var canSimplify = true
            while canSimplify && end != start && (end > start || isClosed) {
                var test = (start + 1) % n
                while test != end {
                    if shapes[start].first != -1 || shapes[test].first != -1 || shapes[end].first != -1 {
                        canSimplify = false
                        break
                    }
                    if !KiMath.testSegmentHit(points[test], points[start], points[end], tolerance) {
                        canSimplify = false
                        break
                    }
                    test = (test + 1) % n
                }
                if canSimplify { end = (end + 1) % n }
            }
            if end == (start + 2) % n {
                start += 1
            } else {
                let newStart = (end + n - 1) % n
                if newStart <= start { break }
                start = newStart
            }
        }
        if out.count == 1 {
            out.append(points[n - 1])
            outShapes.append(shapes[n - 1])
        }
        if !isClosed && points[n - 1] != out[out.count - 1] {
            out.append(points[n - 1])
            outShapes.append(shapes[n - 1])
        }
        points = out
        shapes = outShapes
    }

    /// Points repeated one after the other made one, where they are on the same arc or one of them on none
    private func uniquePoints() -> ([IPoint], [ShapeIndices]) {
        var unique: [IPoint] = []
        var uniqueShapes: [ShapeIndices] = []
        var i = 0
        let n = points.count
        while i < n {
            var j = i + 1
            while j < n && points[i] == points[j] && (shapes[i] == shapes[j] || shapes[i] == .point || shapes[j] == .point) {
                j += 1
            }
            unique.append(points[i])
            uniqueShapes.append(shapes[i] == .point ? shapes[j - 1] : shapes[i])
            i = j
        }
        return (unique, uniqueShapes)
    }

    /// KiCad's Simplify2, the router's: duplicate points removed, and (unless asked not to) points along a straight
    /// line, from a point on no arc followed by another
    @discardableResult
    public mutating func simplify2(removeColinear: Bool = true) -> LineChain {
        if points.count < 3 { return self }
        if points.count == 3 {
            if points[0] == points[1] { remove(1) }
            return self
        }
        let (unique, uniqueShapes) = uniquePoints()
        let np = unique.count
        var out: [IPoint] = []
        var outShapes: [ShapeIndices] = []
        var i = 0
        while i < np - 2 {
            let p0 = unique[i]
            var n = i
            if removeColinear && uniqueShapes[i] == .point && uniqueShapes[i + 1] == .point {
                while n < np - 2 && (Seg(p0, unique[n + 2]).lineDistance(unique[n + 1]) <= 1
                                     || Seg(p0, unique[n + 2]).collinear(Seg(p0, unique[n + 1]))) {
                    n += 1
                }
            }
            out.append(p0)
            outShapes.append(uniqueShapes[i])
            if n > i { i = n }
            if n == np - 2 {
                out.append(unique[np - 1])
                outShapes.append(uniqueShapes[np - 1])
                points = out
                shapes = outShapes
                return self
            }
            i += 1
        }
        if np > 1 {
            out.append(unique[np - 2])
            outShapes.append(uniqueShapes[np - 2])
        }
        out.append(unique[np - 1])
        outShapes.append(uniqueShapes[np - 1])
        points = out
        shapes = outShapes
        return self
    }

    /// KiCad's RemoveDuplicatePoints: points repeated one after the other made one (but two points always kept)
    public mutating func removeDuplicatePoints() {
        if points.count < 3 { return }
        if points.count == 3 {
            if points[0] == points[1] { remove(1) }
            return
        }
        (points, shapes) = uniquePoints()
    }

    /// Whether the chain's points make the same path as `other`'s, both simplified (KiCad's CompareGeometry, not
    /// cyclical, exactly)
    public func compareGeometry(_ other: LineChain) -> Bool {
        var a = self, b = other
        a.simplify()
        b.simplify()
        if a.points.count != b.points.count { return false }
        return a.points == b.points
    }

    /// Whether a point is inside the polygon that polylines added one after the other make, closed from the last
    /// point back to the first (KiCad's POINT_INSIDE_TRACKER). On an edge counts as outside; past an edge KiCad
    /// keeps counting the crossings on from there, as here.
    public struct PointInsideTracker {
        private let point: IPoint
        private var lastPoint = IPoint.zero
        private var firstPoint = IPoint.zero
        private var finished = false
        private var state = 0
        private var count = 0

        public init(_ point: IPoint) { self.point = point }

        private mutating func processVertex(_ ip: IPoint, _ ipNext: IPoint) -> Bool {
            if ipNext.y == point.y {
                if ipNext.x == point.x || (ip.y == point.y && ((ipNext.x > point.x) == (ip.x < point.x))) {
                    finished = true
                    state = -1
                    return false
                }
            }
            if (ip.y < point.y) != (ipNext.y < point.y) {
                if ip.x >= point.x {
                    if ipNext.x > point.x {
                        state = 1 - state
                    } else {
                        let d = Double(ip.x - point.x) * Double(ipNext.y - point.y) - Double(ipNext.x - point.x) * Double(ip.y - point.y)
                        if d == 0 {
                            finished = true
                            state = -1
                            return false
                        }
                        if (d > 0) == (ipNext.y > ip.y) { state = 1 - state }
                    }
                } else if ipNext.x > point.x {
                    let d = Double(ip.x - point.x) * Double(ipNext.y - point.y) - Double(ipNext.x - point.x) * Double(ip.y - point.y)
                    if d == 0 {
                        finished = true
                        state = -1
                        return false
                    }
                    if (d > 0) == (ipNext.y > ip.y) { state = 1 - state }
                }
            }
            return true
        }

        public mutating func addPolyline(_ polyline: LineChain) {
            if count == 0, polyline.pointCount > 0 {
                lastPoint = polyline.point(0)
                firstPoint = polyline.point(0)
            }
            count += polyline.pointCount
            var i = 1
            while i < polyline.pointCount {
                let p = polyline.point(i)
                if !processVertex(lastPoint, p) { return }
                lastPoint = p
                i += 1
            }
        }

        public mutating func isInside() -> Bool {
            _ = processVertex(lastPoint, firstPoint)
            return state > 0
        }
    }
}
