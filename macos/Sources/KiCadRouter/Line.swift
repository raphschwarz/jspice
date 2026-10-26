// Ported from KiCad 10.0.7: pcbnew/router/pns_line.h, pns_line.cpp and pns_link_holder.h.
// Copyright (C) 2013-2017 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// A track as the router thinks of it: a polyline of one width on one layer, perhaps ending in a via, and the
/// segments of the node it is made of (KiCad's PNS::LINE). KiCad's lines are values, copied as they are passed
/// round; here a line is an object, and `copy()` is KiCad's copy.
public final class Line: Item {
    public private(set) var line = LineChain()
    public private(set) var width = 1
    public var snapThreshold = 0
    public private(set) var via: Via?
    public weak var blockingObstacle: Item?
    public private(set) var links: [LinkedItem] = []

    public init() {
        super.init(kind: .line)
    }

    /// KiCad's copy constructor: the same path, links and marks; its own copy of a via it owns
    private init(copying o: Line) {
        super.init(copying: o)
        line = o.line
        width = o.width
        snapThreshold = o.snapThreshold
        net = o.net
        movable = o.movable
        layers = o.layers
        if let v = o.via {
            if v.owner === o {
                let c = v.clone() as! Via
                c.owner = self
                c.net = net
                via = c
            } else {
                via = v
            }
        }
        marker = o.marker
        rank = o.rank
        blockingObstacle = o.blockingObstacle
        links = o.links
    }

    /// A line like `base` (its width, net and layers, and its links), on another path
    public init(_ base: Line, _ path: LineChain) {
        super.init(copying: base)
        line = path
        width = base.width
        snapThreshold = base.snapThreshold
        net = base.net
        layers = base.layers
        links = base.links
        // (KiCad's constructor copies the base's ITEM, not its marks' view through the links)
        marker = base.marker
        rank = base.rank
    }

    /// A line of just a via
    public init(via v: Via) {
        super.init(kind: .line)
        via = v
        width = v.diameter
        net = v.net
        layers = v.layers
        rank = v.rank
        snapThreshold = 0
    }

    public func copy() -> Line { Line(copying: self) }
    public override func clone() -> Item { copy() }

    /// KiCad's assignment operator: this line made a copy of `o`
    public func assign(_ o: Line) {
        parent = o.parent
        sourceItem = o.sourceItem
        line = o.line
        width = o.width
        net = o.net
        movable = o.movable
        layers = o.layers
        via = nil
        if let v = o.via {
            if v.owner === o {
                let c = v.clone() as! Via
                c.owner = self
                c.net = net
                via = c
            } else {
                via = v
            }
        }
        marker = o.marker
        rank = o.rank
        isRoutable = o.isRoutable
        owner = o.owner
        snapThreshold = o.snapThreshold
        blockingObstacle = o.blockingObstacle
        links = o.links
    }

    public var isLinkedChecked: Bool { isLinked && links.count == line.segmentCount }

    public func setShape(_ l: LineChain) { line = l }
    public func setLine(_ l: LineChain) { line = l }
    public override func shape(_ layer: Int) -> Shape? { .chain(line) }
    public var cLine: LineChain { line }
    public var segmentCount: Int { line.segmentCount }
    public var pointCount: Int { line.pointCount }
    public func cPoint(_ i: Int) -> IPoint { line.point(i) }
    public var cLastPoint: IPoint { line.lastPoint }
    public func cSegment(_ i: Int) -> Seg { line.segment(i) }

    public func setWidth(_ w: Int) { width = w }
    // (KiCad's LINE::SetWidth sets its chain's width too, which nothing here reads)
    public override var description: String { "line \(line) width \(width) layer \(layers)" }

    // MARK: - Links (pns_link_holder.h)

    public func link(_ item: LinkedItem) {
        if links.contains(where: { $0 === item }) { return }
        links.append(item)
    }

    public func unlink(_ item: LinkedItem) { links.removeAll { $0 === item } }
    public var isLinked: Bool { !links.isEmpty }
    public func containsLink(_ item: LinkedItem) -> Bool { links.contains { $0 === item } }
    public func getLink(_ i: Int) -> LinkedItem { links[i < 0 ? i + links.count : i] }
    public func clearLinks() { links.removeAll() }
    public var linkCount: Int { links.count }

    // MARK: - Marks and ranks

    public override func mark(_ m: Marker) {
        marker = m
        for s in links { s.mark(m) }
    }

    public override func unmark(_ m: Marker = Marker(rawValue: -1)) {
        for s in links { s.unmark(m) }
        marker = []
    }

    /// Its own marks and its segments'
    public var allMarkers: Marker { links.reduce(marker) { $0.union($1.marker) } }

    public func setRank(_ r: Int) {
        rank = r
        for s in links { s.rank = r }
    }

    /// Its segments' lowest rank (its own, unlinked)
    public var lineRank: Int {
        var minRank = Int(Int32.max)
        if isLinked {
            for item in links { minRank = min(minRank, item.rank) }
        } else {
            minRank = rank
        }
        return minRank == Int(Int32.max) ? -1 : minRank
    }

    public override func anchor(_ n: Int) -> IPoint {
        if line.pointCount < 1 { return .zero }
        return n == 0 ? line.point(0) : line.point(-1)
    }

    public override var anchorCount: Int { line.pointCount >= 2 ? 2 : line.pointCount }

    public var hasLockedSegments: Bool { links.contains { $0.marker.contains(.locked) } }

    // MARK: - Shape

    public func compareGeometry(_ o: Line) -> Bool { line.compareGeometry(o.line) }

    public func reverse() {
        line = line.reversed()
        links.reverse()
    }

    public func countCorners(_ angles: Direction45.AngleType) -> Int {
        var count = 0
        let n = line.segmentCount
        if n < 2 { return 0 }
        for i in 0..<(n - 1) where !Direction45(line.segment(i)).angle(Direction45(line.segment(i + 1))).intersection(angles).isEmpty {
            count += 1
        }
        return count
    }

    public var hasLoops: Bool {
        for i in 0..<pointCount {
            var j = i + 2
            while j < pointCount {
                if cPoint(i) == cPoint(j) { return true }
                j += 1
            }
        }
        return false
    }

    public func appendVia(_ v: Via) {
        if line.pointCount > 1 && v.pos == line.point(0) { reverse() }
        let c = v.clone() as! Via
        c.owner = self
        c.net = net
        via = c
    }

    public func linkVia(_ v: Via) {
        if line.pointCount > 1 && v.pos == line.point(0) { reverse() }
        via = v
        link(v)
    }

    public func removeVia() {
        if let v = via, containsLink(v) { unlink(v) }
        via = nil
    }

    public func setViaDiameter(_ d: Int) { via?.setDiameter(d) }
    public func setViaDrill(_ d: Int) { via?.setDrill(d) }

    public func clear() {
        clearLinks()
        removeVia()
        line.clear()
    }

    public func findSegment(_ seg: Segment) -> Int {
        for i in 0..<line.segmentCount where line.segment(i) == seg.seg { return i }
        return -1
    }

    /// Keeps the points from `start` to `end` (and the links of the segments and arcs between them, an arc counted
    /// once, as KiCad's rotation keeps them)
    public func clipVertexRange(_ start: Int, _ end: Int) {
        var firstLink = 0
        var lastLink = max(0, links.count - 1)
        var linkIdx = 0
        var i = 0
        while i >= 0 && i < line.pointCount {
            if i <= start { firstLink = linkIdx }
            if i < 0 || i >= end - 1 || linkIdx >= lastLink {
                lastLink = linkIdx
                break
            }
            linkIdx += 1
            i = line.nextShape(i)
        }
        line = line.slice(start, end)
        if isLinked {
            // std::rotate(begin, begin + firstLink, begin + lastLink), then the first lastLink - firstLink + 1 kept
            var rotated = Array(links[firstLink..<lastLink]) + Array(links[0..<firstLink])
            rotated += links[lastLink...]
            links = Array(rotated.prefix(lastLink - firstLink + 1))
        }
    }

    /// The box round what changed between this line and `o`
    public func changedArea(_ o: Line) -> IBox? {
        var area: IBox?
        func extend(_ p: IPoint) {
            if area == nil { area = IBox(p, p) } else { area!.merge(p) }
        }
        var selfChain = line
        selfChain.simplify()
        var other = o.line
        other.simplify()
        let npSelf = selfChain.pointCount, npOther = other.pointCount
        let n = min(npSelf, npOther)
        var iStart = -1, iEndSelf = -1, iEndOther = -1
        for i in 0..<n {
            let p1 = selfChain.point(i), p2 = other.point(i)
            if p1 != p2 {
                if i != n - 1 {
                    if !selfChain.segment(i).contains(p2) {
                        iStart = i
                        break
                    }
                } else {
                    iStart = i
                    break
                }
            }
        }
        for i in 0..<n {
            let p1 = selfChain.point(npSelf - 1 - i), p2 = other.point(npOther - 1 - i)
            if p1 != p2 {
                iEndSelf = npSelf - 1 - i
                iEndOther = npOther - 1 - i
                break
            }
        }
        if iStart < 0 { iStart = n }
        if iEndSelf < 0 { iEndSelf = npSelf - 1 }
        if iEndOther < 0 { iEndOther = npOther - 1 }
        if iStart <= iEndSelf { for i in iStart...iEndSelf { extend(selfChain.point(i)) } }
        if iStart <= iEndOther { for i in iStart...iEndOther { extend(other.point(i)) } }
        return area?.inflated(max(width, o.width))
    }

    // MARK: - Walking round an obstacle

    private enum VertexType { case inside, outside, onEdge }

    private struct Vertex {
        var type: VertexType = .outside
        var isHull = false
        var pos = IPoint.zero
        var neighbours: [Int] = []
        var indexp = -1
        var indexh = -1
        var visited = false
    }

    private static func areNeighbours(_ x: Int, _ y: Int, _ max: Int = 0) -> Bool {
        if x > 0 && x - 1 == y { return true }
        if x < max - 1 && x + 1 == y { return true }
        return false
    }

    /// The path round `obstacle` (a hull, clockwise), going `cw` or the other way: KiCad's graph of the path's and
    /// the hull's vertices, walked from the path's start
    public func walkaround(_ obstacle: LineChain, _ path: inout LineChain, cw: Bool) -> Bool {
        let l = line
        if l.segmentCount < 1 { return false }
        let pFirst = l.point(0)
        // (no walking round from inside the hull, but on its edge is outside)
        if obstacle.pointInside(pFirst) && !obstacle.pointOnEdge(pFirst) { return false }

        let ips = Shape.hullIntersection(obstacle, l)
        var pnew = l, hnew = obstacle
        var vts: [Vertex] = []
        func findVertex(_ pos: IPoint) -> Int? { vts.firstIndex { $0.pos == pos } }

        // loopy tracks: their loop's end point put into the path
        if let isect = pnew.selfIntersecting(), isect.p != pnew.lastPoint { pnew.split(isect.p) }
        // the crossings put into the path and the hull
        for ip in ips {
            if pnew.find(ip.p, threshold: 1) < 0 { pnew.split(ip.p) }
            if hnew.find(ip.p, threshold: 1) < 0 { hnew.split(ip.p) }
        }
        for i in 0..<pnew.pointCount {
            let p = pnew.point(i)
            if !hnew.pointOnEdge(p) { continue }
            if hnew.find(p) < 0 { hnew.split(p) }
        }
        // hulls go clockwise: the other way round, reversed
        if !cw { hnew = hnew.reversed() }

        // the path's vertices, inside, on the edge of or outside the hull
        for i in 0..<pnew.pointCount {
            let p = pnew.point(i)
            let onEdge = hnew.pointOnEdge(p), inside = hnew.pointInside(p)
            var v = Vertex()
            v.indexp = i
            v.isHull = false
            v.pos = p
            v.type = inside && !onEdge ? .inside : onEdge ? .onEdge : .outside
            vts.append(v)
        }
        // each path vertex leads to the next and the one before
        if pnew.pointCount > 1 {
            for i in 0..<(pnew.pointCount - 1) { vts[i].neighbours.append(i + 1) }
            for i in 1..<pnew.pointCount { vts[i].neighbours.append(i - 1) }
        }
        // the hull's vertices (a path vertex on the hull marked as the hull's too)
        for i in 0..<hnew.pointCount {
            let hp = hnew.point(i)
            if let vn = findVertex(hp) {
                vts[vn].isHull = true
                vts[vn].indexh = i
            } else {
                var v = Vertex()
                v.pos = hp
                v.type = .onEdge
                v.indexh = i
                v.isHull = true
                vts.append(v)
            }
        }
        // round the hull
        for i in 0..<hnew.pointCount {
            if let vc = findVertex(hnew.point(i)), let vnext = findVertex(hnew.point(i + 1)) { vts[vc].neighbours.append(vnext) }
        }

        // the path ending inside the hull: the walk ends at the point nearest the end
        let inLast = obstacle.pointInside(cLastPoint) && !obstacle.pointOnEdge(cLastPoint)
        var appendV = true
        var lastDst = Int(Int32.max)
        var v = 0
        var vPrev: Int?
        var out = LineChain()
        var iterLimit = 1000
        while vts[v].indexp != pnew.pointCount - 1 {
            iterLimit -= 1
            if iterLimit == 0 { return false }
            // a loop: stop walking
            if vts[v].visited { break }
            out.append(vts[v].pos)
            var vNext: Int?
            if vts[v].type == .outside {
                // outside: on along the path, to a vertex not inside the hull
                out.append(vts[v].pos)
                var fallback: Int?
                for vn in vts[v].neighbours where Line.areNeighbours(vts[vn].indexp, vts[v].indexp, pnew.pointCount) && vts[vn].type != .inside {
                    if !vts[vn].visited {
                        vNext = vn
                        break
                    } else if vn != vPrev {
                        fallback = vn
                    }
                }
                if vNext == nil { vNext = fallback }
                if vNext == nil { return false }
            } else if vts[v].type == .onEdge {
                // on the edge: out of the hull if it can, else on round it
                for vn in vts[v].neighbours where vts[vn].type == .outside && !vts[vn].visited {
                    vNext = vn
                    break
                }
                if vNext == nil {
                    for vn in vts[v].neighbours where vts[vn].type == .onEdge && !vts[vn].isHull
                        && Line.areNeighbours(vts[vn].indexp, vts[v].indexp, pnew.pointCount)
                        && vts[vn].indexh == (vts[v].indexh + 1) % hnew.pointCount {
                        vNext = vn
                        break
                    }
                }
                if vNext == nil {
                    for vn in vts[v].neighbours where vts[vn].type == .onEdge && vts[vn].indexh == (vts[v].indexh + 1) % hnew.pointCount {
                        vNext = vn
                        break
                    }
                    if vNext != nil {
                        for k in vts.indices where vts[k].isHull { vts[k].visited = false }
                    }
                    // the next hull point, with the line's end inside: the end's nearest point on the way, and done
                    if inLast, let vn = vNext {
                        // (KiCad keeps the squared distance in an int: past 46341 nm it wraps, as here)
                        let d = Int(Int32(truncatingIfNeeded: (vts[vn].pos - cLastPoint).squaredNorm))
                        if d < lastDst {
                            lastDst = d
                        } else {
                            out.append(Seg(vts[v].pos, vts[vn].pos).nearestPoint(cLastPoint))
                            appendV = false
                            break
                        }
                    }
                }
            }
            vts[v].visited = true
            vPrev = v
            guard let next = vNext else { return false }
            v = next
        }
        if appendV { out.append(vts[v].pos) }
        // (outside vertices went in twice: gone before the runs of points are matched against the path)
        out.simplify2(removeColinear: false)
        Line.restoreUntouchedArcs(&out, pnew)
        path = out
        return true
    }

    /// The runs of points at the start and the end of a walk that are the path's own taken back from the path, its
    /// arcs with them (KiCad's restoreUntouchedArcs: the walk keeps points only)
    private static func restoreUntouchedArcs(_ path: inout LineChain, _ original: LineChain) {
        if original.arcCount == 0 { return }
        let origCount = original.pointCount, pathCount = path.pointCount
        var head = 0
        while head < origCount && head < pathCount && original.point(head) == path.point(head) { head += 1 }
        var tail = 0
        while tail < origCount - head && tail < pathCount - head
              && original.point(origCount - 1 - tail) == path.point(pathCount - 1 - tail) {
            tail += 1
        }
        if head == 0 && tail == 0 { return }
        var rebuilt = LineChain()
        if head > 0 { rebuilt = original.slice(0, head - 1) }
        if head + tail < pathCount { rebuilt.append(path.slice(max(head - 1, 0), pathCount - tail - 1)) }
        if tail > 0 { rebuilt.append(original.slice(origCount - tail, origCount - 1)) }
        path = rebuilt
    }

    /// The line cut short where it first meets an obstacle (empty, if five tries do not clear it)
    public func clipToNearestObstacle(_ node: Node) -> Line {
        let iterationLimit = 5
        let l = copy()
        var i = 0
        while i < iterationLimit {
            guard let obs = node.nearestObstacle(l) else { break }
            l.removeVia()
            let collisionPoint = obs.ipFirst
            let segIdx = l.line.nearestSegment(collisionPoint)
            if l.line.isArcSegment(segIdx) {
                // (no cutting an arc: again from nothing)
                l.line.clear()
            } else {
                let nearestPt = l.line.segment(segIdx).nearestPoint(collisionPoint)
                let p = l.line.split(nearestPt)
                l.line.remove(p + 1, -1)
            }
            i += 1
        }
        if i == iterationLimit { l.line.clear() }
        return l
    }

    // MARK: - Dragging

    private static func dragCornerInternal(_ origin: LineChain, _ p: IPoint, _ preferredEnding: Direction45 = Direction45()) -> LineChain {
        var picked: LineChain?
        if origin.pointCount == 1 { return Direction45().buildInitialTrace(origin.point(0), p) }
        if origin.segmentCount == 1 {
            let dir = Direction45(origin.point(0) - origin.point(1))
            return Direction45().buildInitialTrace(origin.point(0), p, startDiagonal: dir.isDiagonal)
        }
        var i = origin.segmentCount - 1
        while i >= 0 {
            let dStart = Direction45(origin.segment(i))
            let pStart = origin.point(i)
            var paths: [LineChain] = []
            var dirs: [Direction45] = []
            let dPrev = i > 0 ? Direction45(origin.segment(i - 1)) : Direction45()
            for j in 0..<2 {
                let path = dStart.buildInitialTrace(pStart, p, startDiagonal: j == 1)
                paths.append(path)
                if path.segmentCount < 1 { continue }
                dirs.append(Direction45(path.segment(0)))
            }
            // (KiCad's paths[j] and dirs[j] line up only while every path has a segment)
            if preferredEnding.isDefined {
                for j in 0..<dirs.count where Direction45(paths[j].segment(-1)) == preferredEnding {
                    picked = paths[j]
                    break
                }
            }
            if picked == nil {
                for j in 0..<dirs.count where dirs[j] == dStart {
                    picked = paths[j]
                    break
                }
            }
            if picked != nil { break }
            for j in 0..<dirs.count where dirs[j].isObtuse(dPrev) {
                picked = paths[j]
                break
            }
            if picked != nil { break }
            i -= 1
        }
        if let picked {
            var path = origin.slice(0, i)
            path.append(picked)
            return path
        }
        let dir = Direction45(origin.lastPoint - origin.point(origin.pointCount - 2))
        return Direction45().buildInitialTrace(origin.point(0), p, startDiagonal: dir.isDiagonal)
    }

    private func snapDraggedCorner(_ path: LineChain, _ p: IPoint, _ index: Int) -> IPoint {
        let sStart = max(index - 2, 0), sEnd = min(index + 2, path.segmentCount - 1)
        var bestDist = Int.max
        var bestSnap = p
        if snapThreshold <= 0 { return p }
        if sStart > sEnd { return p }
        for i in sStart...sEnd {
            let a = path.segment(i)
            for j in sStart..<i {
                let b = path.segment(j)
                if !Direction45(a).isObtuse(Direction45(b)) { continue }
                if let ip = a.intersectLines(b) {
                    let dist = (ip - p).norm
                    if dist < snapThreshold && dist < bestDist {
                        bestDist = dist
                        bestSnap = ip
                    }
                }
            }
        }
        return bestSnap
    }

    private func snapToNeighbourSegments(_ path: LineChain, _ p: IPoint, _ index: Int) -> IPoint {
        var snapP = [IPoint.zero, IPoint.zero]
        let dragDir = Direction45(path.segment(index))
        var snapD = [-1, -1]
        if snapThreshold == 0 { return p }
        if index >= 2 {
            let s = path.segment(index - 2)
            if Direction45(s) == dragDir { snapD[0] = s.lineDistance(p) }
            snapP[0] = s.a
        }
        if index < path.segmentCount - 2 {
            let s = path.segment(index + 2)
            if Direction45(s) == dragDir { snapD[1] = s.lineDistance(p) }
            snapP[1] = s.a
        }
        var best = p
        var minDist = Int.max
        for i in 0..<2 where snapD[i] >= 0 && snapD[i] < minDist && snapD[i] <= snapThreshold {
            minDist = snapD[i]
            best = snapP[i]
        }
        return best
    }

    private func dragCorner45(_ p: IPoint, _ index: Int, _ preferredEnding: Direction45) {
        var path: LineChain
        let snapped = snapDraggedCorner(line, p, index)
        if index == 0 {
            path = Line.dragCornerInternal(line.reversed(), snapped, preferredEnding).reversed()
        } else if index == line.segmentCount {
            path = Line.dragCornerInternal(line, snapped, preferredEnding)
        } else {
            // (next to an arc: a point put in, so that the slices are right)
            if line.isPointOnArc(index + 1) { line.insert(line.point(index + 1), at: index + 1) }
            path = Line.dragCornerInternal(line.slice(0, index), snapped, preferredEnding)
            let pathRev = Line.dragCornerInternal(line.slice(index, -1).reversed(), snapped, preferredEnding).reversed()
            path.append(pathRev)
        }
        path.simplify()
        line = path
    }

    private func dragCornerFree(_ p: IPoint, _ index: Int) {
        var idx = index
        let numpts = line.pointCount
        // an arc's end: a point put in to drag instead
        if line.isPointOnArc(idx) {
            if idx == 0 || (idx > 0 && !line.isPointOnArc(idx - 1)) {
                line.insert(line.point(idx), at: idx)
            } else if idx == numpts - 1 || (idx < numpts - 1 && !line.isArcSegment(idx)) {
                idx += 1
                line.insert(line.point(idx), at: idx)
            }
            // (else the middle of an arc, which KiCad asserts is never dragged)
        }
        line.setPoint(idx, p)
        line.simplify()
    }

    /// The line with its `index`th corner moved to `p`, on the 45° directions unless `freeAngle`
    public func dragCorner(_ p: IPoint, _ index: Int, freeAngle: Bool = false, preferredEnding: Direction45 = Direction45()) {
        guard index >= 0 else { return }
        if freeAngle { dragCornerFree(p, index) } else { dragCorner45(p, index, preferredEnding) }
    }

    /// The line with its `index`th segment moved to pass through `p`, its neighbours stretched to meet it
    public func dragSegment(_ p: IPoint, _ index: Int) {
        var path = line
        var index = index
        let aIndex = index
        let target = snapToNeighbourSegments(path, p, aIndex)
        // a segment before and after it, of no length at the ends, and next to an arc (whose points cannot be dragged
        // away)
        if index == 0 || path.isPointOnArc(index) {
            path.insert(path.point(index), at: index > 0 ? index + 1 : 0)
            index += 1
        }
        if index == path.segmentCount - 1 {
            path.insert(path.lastPoint, at: path.pointCount - 1)
        } else if path.isPointOnArc(index + 1) {
            path.insert(path.point(index + 1), at: index + 1)
        }
        var dragged = path.segment(index)
        let dragDir = Direction45(dragged)
        var sPrev = path.segment(index - 1), sNext = path.segment(index + 1)
        var dirPrev = Direction45(sPrev), dirNext = Direction45(sNext)
        if dirPrev == dragDir {
            dirPrev = dirPrev.left
            path.insert(path.point(index), at: index)
            index += 1
        } else if !dirPrev.isDefined {
            dirPrev = dragDir.left
        }
        if dirNext == dragDir {
            dirNext = dirNext.right
            path.insert(path.point(index + 1), at: index + 1)
        } else if !dirNext.isDefined {
            dirNext = dragDir.right
        }
        sPrev = path.segment(index - 1)
        sNext = path.segment(index + 1)
        dragged = path.segment(index)
        var guideA = [Seg(.zero, .zero), Seg(.zero, .zero)], guideB = guideA
        if aIndex == 0 {
            guideA[0] = Seg(dragged.a, dragged.a + dragDir.right.vector)
            guideA[1] = Seg(dragged.a, dragged.a + dragDir.left.vector)
        } else if !dirPrev.angle(dragDir).intersection([.obtuse, .halfFull]).isEmpty {
            guideA[0] = Seg(sPrev.a, sPrev.a + dragDir.left.vector)
            guideA[1] = Seg(sPrev.a, sPrev.a + dragDir.right.vector)
        } else {
            guideA[0] = Seg(dragged.a, dragged.a + dirPrev.vector)
            guideA[1] = guideA[0]
        }
        if aIndex == line.segmentCount - 1 {
            guideB[0] = Seg(dragged.b, dragged.b + dragDir.right.vector)
            guideB[1] = Seg(dragged.b, dragged.b + dragDir.left.vector)
        } else if !dirNext.angle(dragDir).intersection([.obtuse, .halfFull]).isEmpty {
            guideB[0] = Seg(sNext.b, sNext.b + dragDir.left.vector)
            guideB[1] = Seg(sNext.b, sNext.b + dragDir.right.vector)
        } else {
            guideB[0] = Seg(dragged.b, dragged.b + dirNext.vector)
            guideB[1] = guideB[0]
        }
        let sCurrent = Seg(target, target + dragDir.vector)
        var bestLen = Int.max
        var best = LineChain()
        for i in 0..<2 {
            for j in 0..<2 {
                guard let ip1 = sCurrent.intersectLines(guideA[i]), let ip2 = sCurrent.intersectLines(guideB[j]) else { continue }
                var np = LineChain()
                let s1 = Seg(sPrev.a, ip1), s3 = Seg(ip2, sNext.b)
                if let ip = s1.intersect(sNext) {
                    np.append(s1.a)
                    np.append(ip)
                    np.append(sNext.b)
                } else if let ip = s3.intersect(sPrev) {
                    np.append(sPrev.a)
                    np.append(ip)
                    np.append(s3.b)
                } else if let ip = s1.intersect(s3) {
                    np.append(sPrev.a)
                    np.append(ip)
                    np.append(sNext.b)
                } else {
                    np.append(sPrev.a)
                    np.append(ip1)
                    np.append(ip2)
                    np.append(sNext.b)
                }
                if np.length < bestLen {
                    bestLen = np.length
                    best = np
                }
            }
        }
        if line.pointCount == 1 {
            line = best
        } else if aIndex == 0 {
            line.replace(0, 1, with: best)
        } else if aIndex == line.segmentCount - 1 {
            line.replace(-2, -1, with: best)
        } else {
            line.replace(aIndex, aIndex + 1, with: best)
        }
        line.simplify()
    }

    /// How far, in degrees, a segment may turn from an arc's tangent and still count as running on from it (KiCad's
    /// ADVANCED_CFG m_MaxTangentAngleDeviation)
    static let maxTangentAngleDeviation = 1.0

    /// The shortest piece of track KiCad keeps, 0.0005 mm (ADVANCED_CFG m_MaxTrackLengthToKeep), in nanometres
    static let maxTrackLengthToKeep = KiMath.round(0.0005 * 1e6)

    /// The line with the arc point `index` is on dragged to pass through `p`: another arc tangent to what it runs on
    /// from at either end (the segment there, if it runs on from the arc, else the arc's own tangent), its ends where
    /// it touches them, and the line rebuilt round it; an arc too small to keep dropped (KiCad's LINE::DragArc)
    public func dragArc(_ p: IPoint, _ index: Int) {
        guard index >= 0 && index < line.pointCount else { return }
        let arcIdx = line.arcIndex(index)
        if arcIdx < 0 { return }
        var firstArcPt = -1, lastArcPt = -1
        for i in 0..<line.pointCount where line.arcIndex(i) == arcIdx {
            if firstArcPt < 0 { firstArcPt = i }
            lastArcPt = i
        }
        if firstArcPt < 0 || lastArcPt < 0 { return }
        let oldArc = line.arcs[arcIdx]
        let width = oldArc.width
        func tangentLineAtArcEndpoint(_ endpoint: IPoint) -> Seg {
            let radial = endpoint - oldArc.center
            let perp = IPoint(-radial.y, radial.x)
            return Seg(endpoint - perp, endpoint + perp)
        }
        func isCollinearTo(_ a: Seg, _ b: Seg, _ maxDeviationDeg: Double) -> Bool {
            let dirA = DPoint(a.b - a.a), dirB = DPoint(b.b - b.a)
            let magA = dirA.norm, magB = dirB.norm
            if magA <= 0 || magB <= 0 { return false }
            let crossMag = abs(dirA.x * dirB.y - dirA.y * dirB.x)
            let sinAngle = crossMag / (magA * magB)
            let angleDeg = asin(min(max(sinAngle, 0.0), 1.0)) * 180.0 / Double.pi
            return angleDeg <= maxDeviationDeg
        }
        let maxDeviation = Line.maxTangentAngleDeviation
        let arcLineStart = tangentLineAtArcEndpoint(oldArc.start)
        let arcLineEnd = tangentLineAtArcEndpoint(oldArc.end)
        // the segments either side, if they run on from the arc
        var useChainStart = false, useChainEnd = false
        if firstArcPt > 0 && isCollinearTo(Seg(line.point(firstArcPt - 1), line.point(firstArcPt)), arcLineStart, maxDeviation) {
            useChainStart = true
        }
        if lastArcPt < line.pointCount - 1 && isCollinearTo(Seg(line.point(lastArcPt), line.point(lastArcPt + 1)), arcLineEnd, maxDeviation) {
            useChainEnd = true
        }
        let arcOwnTanIntersect = arcLineStart.intersectLines(arcLineEnd)
        let tanStartSeg: Seg, tanEndSeg: Seg
        if useChainStart {
            tanStartSeg = Seg(line.point(firstArcPt - 1), line.point(firstArcPt))
        } else {
            guard let x = arcOwnTanIntersect else { return }
            tanStartSeg = Seg(x, oldArc.start)
        }
        if useChainEnd {
            tanEndSeg = Seg(line.point(lastArcPt), line.point(lastArcPt + 1))
        } else {
            guard let x = arcOwnTanIntersect else { return }
            tanEndSeg = Seg(x, oldArc.end)
        }
        // (parallel tangents: no circle tangent to both)
        guard let tanIntersect = tanStartSeg.intersectLines(tanEndSeg) else { return }
        // the tangents from their intersection to the arc's ends
        let tanStartFromIntersect = Seg(tanIntersect, oldArc.start)
        let tanEndFromIntersect = Seg(tanIntersect, oldArc.end)
        func furthestFromIntersect(_ a: IPoint, _ b: IPoint) -> IPoint { (a - tanIntersect).norm > (b - tanIntersect).norm ? a : b }
        let tanStartFar = furthestFromIntersect(tanStartSeg.a, tanStartSeg.b)
        let tanEndFar = furthestFromIntersect(tanEndSeg.a, tanEndSeg.b)
        let tempTangentPoint = furthestFromIntersect(tanStartFar, tanEndFar) == tanEndFar ? tanStartFar : tanEndFar
        // the biggest arc there is room for, and the pointer kept inside the triangle it makes with the tangents
        var maxTanCircle = Circle(.zero, 0)
        maxTanCircle.constructFromTanTanPt(tanStartFromIntersect, tanEndFromIntersect, tempTangentPoint)
        let maxTanPtStart = tanStartFromIntersect.lineProject(maxTanCircle.center)
        let maxTanPtEnd = tanEndFromIntersect.lineProject(maxTanCircle.center)
        let cSegTanStart = Seg(maxTanPtStart, tanIntersect)
        let cSegTanEnd = Seg(maxTanPtEnd, tanIntersect)
        let cSegChord = Seg(maxTanPtStart, maxTanPtEnd)
        let oldMid = oldArc.mid
        var cursor = p
        if cSegTanStart.side(oldMid) != cSegTanStart.side(cursor) || cSegTanEnd.side(oldMid) != cSegTanEnd.side(cursor)
            || cSegChord.side(oldMid) != cSegChord.side(cursor) {
            var best = cSegTanStart.nearestPoint(cursor)
            for candidate in [cSegTanEnd.nearestPoint(cursor), cSegChord.nearestPoint(cursor)]
            where (candidate - cursor).squaredNorm < (best - cursor).squaredNorm {
                best = candidate
            }
            cursor = best
        }
        if (cursor - maxTanCircle.center).norm < maxTanCircle.radius { cursor = maxTanCircle.nearestPoint(cursor) }
        var c = Circle(.zero, 0)
        c.constructFromTanTanPt(tanStartSeg, tanEndSeg, cursor)
        if c.radius <= 0 { return }
        let newCenter = c.center
        var newStart = tanStartSeg.lineProject(newCenter)
        var newEnd = tanEndSeg.lineProject(newCenter)
        // a side not running on from the arc keeps the arc's end, a new stub growing out of it to the new arc
        let maxStubIU = Line.maxTrackLengthToKeep
        var prefixCutoff = useChainStart ? firstArcPt - 1 : firstArcPt
        var suffixCutoff = useChainEnd ? lastArcPt + 1 : lastArcPt
        if (newEnd - newStart).norm <= maxStubIU {
            // (an arc too small to keep: dropped)
            var rebuilt = LineChain()
            if prefixCutoff >= 0 { rebuilt.append(line.slice(0, prefixCutoff)) }
            if suffixCutoff <= line.pointCount - 1 { rebuilt.append(line.slice(suffixCutoff, line.pointCount - 1)) }
            line = rebuilt
            return
        }
        if firstArcPt > 0 {
            let anchor = useChainStart ? line.point(firstArcPt - 1) : line.point(firstArcPt)
            if (anchor - newStart).norm <= maxStubIU {
                newStart = anchor
                prefixCutoff = useChainStart ? firstArcPt - 2 : firstArcPt - 1
            }
        }
        if lastArcPt < line.pointCount - 1 {
            let anchor = useChainEnd ? line.point(lastArcPt + 1) : line.point(lastArcPt)
            if (anchor - newEnd).norm <= maxStubIU {
                newEnd = anchor
                suffixCutoff = useChainEnd ? lastArcPt + 2 : lastArcPt + 1
            }
        }
        let newMid = KiMath.arcMid(newStart, newEnd, newCenter)
        var rebuilt = LineChain()
        if prefixCutoff >= 0 { rebuilt.append(line.slice(0, prefixCutoff)) }
        rebuilt.append(ShapeArc(start: newStart, mid: newMid, end: newEnd, width: width))
        if suffixCutoff <= line.pointCount - 1 { rebuilt.append(line.slice(suffixCutoff, line.pointCount - 1)) }
        line = rebuilt
    }
}
