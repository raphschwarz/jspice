// Ported from KiCad 10.0.7: pcbnew/router/pns_line_placer.h, pns_line_placer.cpp and pns_placement_algo.h
// (walkaround, shove and mark-obstacles modes; the shove itself is in Shove.swift).
// Copyright (C) 2013-2017 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

extension Line {
    /// Changes the line's path in place (KiCad's `m_line` reached through `Line()`)
    @discardableResult
    func withLine<T>(_ body: (inout LineChain) -> T) -> T {
        var l = cLine
        let r = body(&l)
        setLine(l)
        return r
    }
}

/// The points a track has been fixed at, to go back to (KiCad's FIXED_TAIL)
struct FixedTail {
    struct FixPoint {
        var layer: Int
        var placingVias: Bool
        var p: IPoint
        var direction: Direction45
    }

    struct Stage {
        var commit: Node?
        var pts: [FixPoint] = []
    }

    private(set) var stages: [Stage] = []

    mutating func clear() { stages.removeAll() }

    mutating func addStage(_ start: IPoint, _ layer: Int, _ placingVias: Bool, _ direction: Direction45, _ node: Node?) {
        stages.append(Stage(commit: node, pts: [FixPoint(layer: layer, placingVias: placingVias, p: start, direction: direction)]))
    }

    mutating func popStage() -> Stage? {
        guard let last = stages.last else { return nil }
        if stages.count > 1 { stages.removeLast() }
        return last
    }

    var stageCount: Int { stages.count }
}

/// What places a track, or a pair of them, as the pointer moves (KiCad's PLACEMENT_ALGO)
public protocol PlacementAlgo: AnyObject {
    /// Starts at `p`, from `startItem` (the pad, via or track there); whether it could
    func start(_ p: IPoint, _ startItem: Item?) -> Bool
    /// Routed on to the pointer at `p`, `endItem` what is under it
    func move(_ p: IPoint, _ endItem: Item?) -> Bool
    /// Fixed up to `p`; whether that finished it
    func fixRoute(_ p: IPoint, _ endItem: Item?, forceFinish: Bool) -> Bool
    /// Goes back a fixed stage; where the head started, if it had
    func unfixRoute() -> IPoint?
    func commitPlacement() -> Bool
    func abortPlacement() -> Bool
    var hasPlacedAnything: Bool { get }
    func toggleVia(_ enabled: Bool) -> Bool
    var isPlacingVia: Bool { get }
    func setLayer(_ layer: Int) -> Bool
    /// What is being placed, to draw and to check
    func traces() -> [Item]
    var currentStart: IPoint { get }
    var currentEnd: IPoint { get }
    var currentNets: [NetHandle?] { get }
    var currentLayer: Int { get }
    /// The branch being placed in
    func currentNode(loopsRemoved: Bool) -> Node?
    func flipPosture()
    func updateSizes(_ sizes: SizesSettings)
    func setOrthoMode(_ ortho: Bool)
}

extension PlacementAlgo {
    public func unfixRoute() -> IPoint? { nil }
}

/// Places a single track as the pointer moves (KiCad's LINE_PLACER): the head, the part being routed to the
/// pointer, and the tail, the part already settled, in a branch of the world
public final class LinePlacer: PlacementAlgo {
    unowned let router: Router
    var settings: RoutingSettings { router.settings }

    private var direction = Direction45()
    private var initialDirection = Direction45(.n)
    public private(set) var head = Line()
    public private(set) var tail = Line()
    private var world: Node?
    private var pStart = IPoint.zero
    private var fixStart = IPoint.zero
    private var lastPEnd: IPoint?
    private var shove: Shove?
    private var currentNode: Node?
    private var lastNode: Node?
    private var sizes = SizesSettings()
    public private(set) var isPlacingVia = false
    public private(set) var currentNet: NetHandle?
    public var currentNets: [NetHandle?] { [currentNet] }
    public private(set) var currentLayer = 0
    public private(set) var currentEnd = IPoint.zero
    public private(set) var currentStart = IPoint.zero
    private var currentTrace = Line()
    private var startItem: Item?
    private var endItem: Item?
    private var idle = true
    private var chainedPlacement = false
    private var orthoMode = false
    private var placementCorrect = false
    private var fixedTail = FixedTail()
    private let mouseTrailTracer = MouseTrailTracer()

    init(router: Router) { self.router = router }

    private func makeVia(_ p: IPoint) -> Via {
        let iface = router.iface!
        let layers = sizes.viaType == .through ? LayerRange(0, iface.copperLayerCount - 1)
            : LayerRange(sizes.layerPairs.keys.min() ?? 0, sizes.layerPairs.keys.min().flatMap { sizes.layerPairs[$0] } ?? iface.copperLayerCount - 1)
        return Via(pos: p, layers: layers, diameter: sizes.viaDiameter, drill: sizes.viaDrill, net: nil, type: sizes.viaType)
    }

    public func toggleVia(_ enabled: Bool) -> Bool {
        isPlacingVia = enabled
        if !enabled { head.removeVia() }
        return true
    }

    private func setInitialDirection(_ d: Direction45) {
        initialDirection = d
        if tail.segmentCount == 0 { direction = d }
    }

    private func handleSelfIntersections() -> Bool {
        let h = head.cLine, t = tail.cLine
        if t.pointCount < 2 || h.pointCount < 2 { return false }
        if t.point(0) == h.point(0) {
            direction = initialDirection
            tail.withLine { $0.clear() }
            return true
        }
        let ips = t.intersect(h)
        if ips.isEmpty { return false }
        var n = Int(Int32.max)
        var ipoint = IPoint.zero
        for i in ips where i.indexOur < n {
            n = i.indexOur
            ipoint = i.p
        }
        if ipoint == h.point(0) || ipoint == t.lastPoint { return false }
        if n < 2 {
            direction = initialDirection
            tail.withLine { $0.clear() }
            head.withLine { $0.clear() }
            return true
        }
        direction = Direction45(t.segment(n - 1))
        tail.withLine { $0.remove(n, -1) }
        return true
    }

    private func handlePullback() -> Bool {
        let h = head.cLine, t = tail.cLine
        if h.pointCount < 2 { return false }
        let n = t.pointCount
        if n == 0 { return false }
        if n == 1 {
            tail.withLine { $0.clear() }
            return true
        }
        // (an arc's direction is its chord's)
        let firstHead = h.isPointOnArc(0) ? Direction45(h.arcs[h.arcIndex(0)]) : Direction45(h.segment(0))
        let lastSegIdx = t.pointCount - 2
        let lastTail = t.isPointOnArc(lastSegIdx) ? Direction45(t.arcs[t.arcIndex(lastSegIdx)]) : Direction45(t.segment(lastSegIdx))
        let angle = firstHead.angle(lastTail)
        if angle == .right || angle == .acute {
            direction = t.isArcSegment(lastSegIdx) ? Direction45(t.arcs[t.arcIndex(lastSegIdx)]) : Direction45(t.segment(lastSegIdx))
            // (the last segment taken off, or the whole arc it is on)
            if n < 2 {
                tail.withLine { $0.clear() }
            } else {
                tail.withLine { $0.removeShape(-1) }
            }
            if tail.segmentCount == 0 { direction = initialDirection }
            return true
        }
        return false
    }

    @discardableResult
    private func reduceTail(_ end: IPoint) -> Bool {
        let h = head.cLine, t = tail.cLine
        let n = t.segmentCount
        if h.segmentCount < 1 || n < 2 { return false }
        var newDirection = Direction45()
        var reduceIndex = -1
        var i = t.segmentCount - 1
        while i >= 0 {
            let s = t.segment(i)
            let dir = Direction45(s)
            let replacement = dir.buildInitialTrace(s.a, end)
            if replacement.segmentCount >= 1 {
                let tmp = Line(tail, replacement)
                if currentNode!.checkColliding(tmp, kindMask: .any) != nil { break }
                if Direction45(replacement.segment(0)) == dir {
                    newDirection = dir
                    reduceIndex = i
                }
            }
            i -= 1
        }
        if reduceIndex >= 0 {
            direction = newDirection
            tail.withLine { $0.remove(reduceIndex + 1, -1) }
            head.withLine { $0.clear() }
            return true
        }
        if tail.segmentCount == 0 { direction = initialDirection }
        return false
    }

    @discardableResult
    private func mergeHead() -> Bool {
        let forbidden: Direction45.AngleType = [.acute, .halfFull, .undefined]
        head.withLine { $0.simplify() }
        tail.withLine { $0.simplify() }
        let h = head.cLine, t = tail.cLine
        // (an arc counted once)
        let nHead = h.shapeCount, nTail = t.shapeCount
        if nHead < 3 { return false }
        if nTail > 0 && h.point(0) != t.lastPoint { return false }
        if head.countCorners(forbidden) != 0 { return false }
        let dirHead = h.isPointOnArc(0) ? Direction45(h.arcs[h.arcIndex(0)]) : Direction45(h.segment(0))
        if nTail > 0 {
            let lastSegIdx = t.pointCount - 2
            let dirTail = t.isPointOnArc(lastSegIdx) ? Direction45(t.arcs[t.arcIndex(lastSegIdx)]) : Direction45(t.segment(-1))
            if !dirHead.angle(dirTail).intersection(forbidden).isEmpty { return false }
        }
        tail.withLine {
            $0.append(h)
            $0.simplify()
        }
        let lastSegIdx = tail.cLine.pointCount - 2
        let tl = tail.cLine
        direction = tl.isArcSegment(lastSegIdx) ? Direction45(tl.arcs[tl.arcIndex(lastSegIdx)]) : Direction45(tl.segment(-1))
        head.withLine {
            $0.remove(0, -1)
            $0.simplify()
        }
        tail.withLine { $0.simplify() }
        return true
    }

    private func clipAndCheckCollisions(_ p: IPoint, _ l0: LineChain, _ out: inout LineChain, _ thresholdDist: inout Int) -> Bool {
        var l = l0
        let idx = l.split(p)
        if idx < 0 { return false }
        var rv = true
        let l2 = l.slice(0, idx)
        let dist = l2.length
        if dist < thresholdDist { rv = false }
        if currentNode!.checkColliding(Line(head, l2)) != nil { rv = false }
        if rv {
            out = l2
            thresholdDist = dist
        }
        return rv
    }

    private func cursorDistMinimum(_ l: LineChain, _ cursor: IPoint, _ lengthThreshold: Double, _ out: inout LineChain) -> Bool {
        var dists: [Int] = []
        var pts: [IPoint] = []
        if l.pointCount == 0 { return false }
        var lastP = l.lastPoint
        var accumulated = 0
        for i in 0..<l.segmentCount {
            let s = l.segment(i)
            dists.append((cursor - s.a).norm)
            pts.append(s.a)
            let pn = s.nearestPoint(cursor)
            if pn != s.a && pn != s.b {
                dists.append((pn - cursor).norm)
                pts.append(pn)
            }
            accumulated += s.length
            if Double(accumulated) > lengthThreshold {
                lastP = s.b
                break
            }
        }
        dists.append((cursor - lastP).norm)
        pts.append(lastP)
        var minDistGlob = Int(Int32.max), minPGlob = -1
        for (i, d) in dists.enumerated() where d < minDistGlob {
            minDistGlob = d
            minPGlob = i
        }
        // (KiCad works out a local minimum too, and then sets it aside: the global one is used)
        let preferred = minPGlob
        var thresholdDist = 0
        if clipAndCheckCollisions(pts[preferred], l, &out, &thresholdDist) { return true }
        thresholdDist = 0
        var ok = false
        for p in pts { ok = clipAndCheckCollisions(p, l, &out, &thresholdDist) || ok }
        return ok
    }

    private func rhWalkBase(_ p: IPoint, _ walkLine: Line, _ collisionMask: ItemKind, _ mode: RouterMode, _ viaOk: inout Bool) -> Bool {
        let walkFull = head.copy()
        let l1 = head.copy()
        var walkP = p
        let walkaround = Walkaround(world: currentNode!, router: router)
        walkaround.setSolidsOnly(false)
        walkaround.iterationLimit = settings.walkaroundIterationLimit
        walkaround.itemMask = collisionMask
        walkaround.setAllowedPolicies([.ccw, .cw])
        var round = 0
        repeat {
            l1.clear()
            round += 1
            // (KiCad's round == 0 here, after its round++, is never true)
            viaOk = buildInitialLine(walkP, l1, mode, forceNoVia: false)
            let initTrack = tail.copy()
            initTrack.withLine {
                $0.append(l1.cLine)
                $0.simplify()
            }
            let initialLength = Double(initTrack.cLine.length)
            let hugThresholdLength = initialLength * settings.walkaroundHugLengthThreshold
            let hugThresholdLengthComplete = 2.0 * initialLength * settings.walkaroundHugLengthThreshold
            let wr = walkaround.route(initTrack)
            var bestLine: Line?
            let cw = Walkaround.Policy.cw.rawValue, ccw = Walkaround.Policy.ccw.rawValue
            var lenCw = wr.status[cw] != .stuck ? wr.lines[cw].cLine.length : Int(Int32.max)
            var lenCcw = wr.status[ccw] != .stuck ? wr.lines[ccw].cLine.length : Int(Int32.max)
            if wr.status[cw] == .done {
                Router.dbg("wf-result-cw-preopt: \(wr.lines[cw].cLine.points)")
                Optimizer.optimize(wr.lines[cw], effort: .mergeSegments, world: currentNode!)
                Router.dbg("wf-result-cw-opt: \(wr.lines[cw].cLine.points)")
                let tmpHead = Line(), tmpTail = Line()
                if splitHeadTail(wr.lines[cw], tail, tmpHead, tmpTail) {
                    // (KiCad's optimizer.Optimize( &tmpHead ) has no result line to write to, and does nothing)
                    wr.lines[cw].setShape(tmpTail.cLine)
                    wr.lines[cw].withLine { $0.append(tmpHead.cLine) }
                }
                lenCw = wr.lines[cw].cLine.length
                bestLine = wr.lines[cw]
            }
            if wr.status[ccw] == .done {
                Optimizer.optimize(wr.lines[ccw], effort: .mergeSegments, world: currentNode!)
                let tmpHead = Line(), tmpTail = Line()
                if splitHeadTail(wr.lines[ccw], tail, tmpHead, tmpTail) {
                    // (KiCad's optimizer.Optimize( &tmpHead ) has no result line to write to, and does nothing)
                    wr.lines[ccw].setShape(tmpTail.cLine)
                    wr.lines[ccw].withLine { $0.append(tmpHead.cLine) }
                }
                lenCcw = wr.lines[ccw].cLine.length
                if lenCcw < lenCw { bestLine = wr.lines[ccw] }
            }
            let bestLength = lenCw < lenCcw ? lenCw : lenCcw
            if Double(bestLength) < hugThresholdLengthComplete, let bestLine {
                walkFull.setShape(bestLine.cLine)
                walkP = walkFull.cLine.lastPoint
                continue
            }
            var validCw = false, validCcw = false
            var distCcw = Int(Int32.max), distCw = Int(Int32.max)
            var lCw = LineChain(), lCcw = LineChain()
            if wr.status[cw] != .stuck {
                validCw = cursorDistMinimum(wr.lines[cw].cLine, p, hugThresholdLength, &lCw)
                if validCw { distCw = (p - lCw.lastPoint).norm }
            }
            if wr.status[ccw] != .stuck {
                validCcw = cursorDistMinimum(wr.lines[ccw].cLine, p, hugThresholdLength, &lCcw)
                if validCcw { distCcw = (p - lCcw.lastPoint).norm }
            }
            if distCw < distCcw && validCw {
                walkFull.setShape(lCw)
                walkP = lCw.lastPoint
            } else if validCcw {
                walkFull.setShape(lCcw)
                walkP = lCcw.lastPoint
            } else {
                return false
            }
        } while round < 2 && isPlacingVia
        if let via = l1.via {
            let v = via.clone() as! Via
            v.setPos(walkFull.cLine.lastPoint)
            walkFull.appendVia(v)
        }
        walkLine.assign(walkFull)
        return walkFull.via == nil || viaOk
    }

    private func rhWalkOnly(_ p: IPoint, _ newHead: Line, _ newTail: Line) -> Bool {
        let walkFull = Line()
        var viaOk = false
        if !rhWalkBase(p, walkFull, .any, .walkaround, &viaOk) { return false }
        var effort: Optimizer.Effort = []
        switch settings.optimizerEffort {
        case .low: effort = []
        case .medium, .full: effort = .mergeSegments
        }
        if settings.smartPads && !settings.cornerMode.isNinety && !mouseTrailTracer.isManuallyForced {
            effort.insert(.smartPads)
        }
        if currentNode!.checkColliding(walkFull) != nil { return false }
        if !splitHeadTail(walkFull, tail, newHead, newTail) { return false }
        if isPlacingVia && viaOk { newHead.appendVia(makeVia(newHead.cLastPoint)) }
        Router.dbg("walk-full: \(walkFull.cLine.points)")
        Optimizer.optimize(newHead, effort: effort, world: currentNode!)
        Router.dbg("walk-new-head: \(newHead.cLine.points)")
        return true
    }

    private func rhMarkObstacles(_ p: IPoint, _ newHead: Line, _ newTail: Line) -> Bool {
        buildInitialLine(p, head, .markObstacles)
        head.blockingObstacle = nil
        if let obs = currentNode!.nearestObstacle(head) {
            let clearance = currentNode!.clearance(obs.item, head, useEpsilon: false)
            let hull = currentNode!.ruleResolver.hullCache(obs.item, clearance: clearance, walkaroundThickness: head.width, layer: head.layer)
            let nearest = settings.cornerMode.isNinety ? hull.bbox.nearestPoint(p) : hull.nearestPoint(p)
            if (nearest - p).norm < head.width / 2 { buildInitialLine(nearest, head, .markObstacles) }
        }
        newHead.assign(head)
        newTail.assign(tail)
        return true
    }

    private func splitHeadTail(_ newLine: Line, _ oldTail: Line, _ newHead: Line, _ newTail: Line) -> Bool {
        let nt = oldTail.copy(), nh = oldTail.copy()
        let l2 = newLine.copy()
        nt.removeVia()
        nh.clear()
        let n = l2.pointCount
        if n > 1 && oldTail.pointCount > 1 {
            if l2.cLine.pointOnEdge(oldTail.cLastPoint) { l2.withLine { $0.split(oldTail.cLastPoint) } }
            var i = 0
            var found = false
            while i < oldTail.pointCount {
                if l2.cLine.find(oldTail.cPoint(i)) < 0 {
                    found = true
                    break
                }
                i += 1
            }
            if !found { i -= 1 }
            if i >= l2.pointCount { i = l2.pointCount - 1 }
            nh.clear()
            if i == 0 { nt.clear() } else { nt.setShape(l2.cLine.slice(0, i)) }
            nh.setShape(l2.cLine.slice(i, -1))
        } else {
            nt.clear()
            nh.assign(l2)
        }
        Router.dbg("head-post-split: \(nh.cLine.points)")
        newHead.assign(nh)
        newTail.assign(nt)
        return true
    }

    /// The head walked round pads and holes only, and what else is in its way shoved (KiCad's rhShoveOnly); if the
    /// shove fails, the head walks round everything instead
    private func rhShoveOnly(_ p: IPoint, _ newHead: Line, _ newTail: Line) -> Bool {
        let walkSolids = Line()
        var viaOk = false
        if !rhWalkBase(p, walkSolids, .solid, .shove, &viaOk) { return false }
        let shove = shove!
        currentNode = shove.currentNode
        // (the springback must not let go of the node the end item is in)
        if let endItem { shove.setSpringbackDoNotTouchNode(endItem.owner as? Node) }
        let head = walkSolids.copy()
        if isPlacingVia && viaOk { head.appendVia(makeVia(head.cLastPoint)) }
        shove.clearHeads()
        shove.addHeads(head, .shove)
        let shoveOk = shove.run() == .ok
        currentNode = shove.currentNode
        var effort: Optimizer.Effort = []
        switch settings.optimizerEffort {
        case .low: effort = []
        case .medium, .full: effort = .mergeSegments
        }
        if settings.smartPads && !settings.cornerMode.isNinety && !mouseTrailTracer.isManuallyForced {
            effort.insert(.smartPads)
        }
        if shoveOk {
            let shoved = shove.headsModified() ? shove.modifiedHead(0) : head
            if !splitHeadTail(shoved, tail, newHead, newTail) { return false }
            if let v = shoved.via { newHead.appendVia(v) }
            Optimizer.optimize(newHead, effort: effort, world: currentNode!)
            Router.dbg("head-sh-postopt: \(newHead.cLine.points)")
            return true
        }
        return rhWalkOnly(p, newHead, newTail)
    }

    private func routeHead(_ p: IPoint, _ newHead: Line, _ newTail: Line) -> Bool {
        switch settings.mode {
        case .markObstacles: return rhMarkObstacles(p, newHead, newTail)
        case .walkaround: return rhWalkOnly(p, newHead, newTail)
        case .shove: return rhShoveOnly(p, newHead, newTail)
        }
    }

    private func optimizeTailHeadTransition() -> Bool {
        let linetmp = trace
        if !mouseTrailTracer.isManuallyForced && Optimizer.optimize(linetmp, effort: .fanoutCleanup, world: currentNode!) {
            if linetmp.segmentCount < 1 { return false }
            head.assign(linetmp)
            direction = Direction45(linetmp.cSegment(0))
            tail.withLine { $0.clear() }
            return true
        }
        let h = head.cLine, t = tail.cLine
        let tailLookbackSegments = 3
        let threshold = min(t.pointCount, tailLookbackSegments + 1)
        if t.segmentCount < 3 { return false }
        var optLine = t.slice(-threshold, -1)
        let end = min(2, h.pointCount - 1)
        if end >= 0 { optLine.append(h.slice(0, end)) }
        let newHead = Line(tail, optLine)
        if Optimizer.optimize(newHead, effort: .mergeSegments, world: currentNode!) {
            head.withLine { $0.clear() }
            tail.withLine {
                $0.replace(-threshold, -1, with: newHead.cLine)
                $0.simplify()
            }
            direction = Direction45(newHead.cSegment(-1))
            return true
        }
        return false
    }

    private func updatePStart(_ t: Line) {
        pStart = t.cLine.pointCount > 0 ? t.cLine.lastPoint : currentStart
    }

    private func routeStep(_ p: IPoint) {
        var fail = false
        var goBack = false
        var nIter = 1
        var i = 0
        while i < nIter {
            let prevTail = tail.copy(), prevHead = head.copy()
            let newHead = Line(), newTail = Line()
            if !goBack && settings.followMouse { reduceTail(p) }
            goBack = false
            updatePStart(tail)
            if !routeHead(p, newHead, newTail) {
                tail.assign(prevTail)
                head.assign(prevHead)
                if tail.pointCount == 0 {
                    tail.withLine {
                        $0.append(pStart)
                        $0.append(pStart, allowDuplication: true)
                    }
                }
                fail = true
            }
            updatePStart(tail)
            if fail { break }
            head.assign(newHead)
            tail.assign(newTail)
            if handleSelfIntersections() {
                nIter += 1
                goBack = true
            }
            if !goBack && handlePullback() {
                nIter += 1
                // (KiCad's LINE::Clear: the head's via goes too)
                head.clear()
                goBack = true
            }
            i += 1
        }
        if !fail && settings.followMouse {
            if !optimizeTailHeadTransition() { mergeHead() }
        }
        lastPEnd = p
    }

    private func route(_ p: IPoint) -> Bool {
        routeStep(p)
        if head.pointCount == 0 { return false }
        return head.cLastPoint == p
    }

    /// The tail and the head as one line
    public var trace: Line {
        var l = tail.cLine
        l.append(head.cLine)
        if l.pointCount > 2 { l.simplify() }
        let tmp = head.copy()
        tmp.setShape(l)
        return tmp
    }

    public func traces() -> [Item] {
        currentTrace = trace
        return [currentTrace]
    }

    public func flipPosture() {
        if !mouseTrailTracer.isManuallyForced && currentTrace.segmentCount > 0 {
            mouseTrailTracer.setDefaultDirections(Direction45(currentTrace.cSegment(0)), Direction45())
        }
        mouseTrailTracer.flipPosture()
    }

    public func currentNode(loopsRemoved: Bool = false) -> Node? {
        if loopsRemoved, let lastNode { return lastNode }
        return currentNode
    }

    /// The segment under `p` split in two there (if nothing else is at `p`)
    @discardableResult
    func splitAdjacentSegments(_ node: Node, _ item: Item?, _ p: IPoint) -> Bool {
        guard let sOld = item as? Segment else { return false }
        if let jt = node.findJoint(p, sOld), jt.linkCount() >= 1 { return false }
        let s0 = sOld.clone() as! Segment, s1 = sOld.clone() as! Segment
        s0.setEnds(sOld.seg.a, p)
        s1.setEnds(p, sOld.seg.b)
        node.remove(sOld)
        node.add(s0, allowRedundant: true)
        node.add(s1, allowRedundant: true)
        return true
    }

    public func setLayer(_ layer: Int) -> Bool {
        if idle {
            currentLayer = layer
            return true
        }
        if chainedPlacement { return false }
        if startItem == nil || (startItem!.ofKind(.via) && startItem!.layers.overlaps(layer))
            || (startItem!.ofKind(.solid) && startItem!.layers.overlaps(layer)) {
            currentLayer = layer
            pStart = currentStart
            direction = initialDirection
            mouseTrailTracer.clear()
            head.withLine { $0.clear() }
            tail.withLine { $0.clear() }
            head.removeVia()
            tail.removeVia()
            head.setLayer(currentLayer)
            tail.setLayer(currentLayer)
            _ = move(currentEnd, nil, isCurrentEnd: true)
            return true
        }
        return false
    }

    public func start(_ p: IPoint, _ startItem: Item?) -> Bool {
        placementCorrect = false
        currentStart = p
        fixStart = p
        currentEnd = p
        currentNet = startItem?.net ?? router.iface?.orphanedNetHandle
        self.startItem = startItem
        isPlacingVia = false
        chainedPlacement = false
        fixedTail.clear()
        endItem = nil
        setInitialDirection(settings.initialDirection)
        initPlacement()
        mouseTrailTracer.clear()
        mouseTrailTracer.addTrailPoint(p)
        mouseTrailTracer.tolerance = head.width
        mouseTrailTracer.setDefaultDirections(initialDirection, Direction45())
        mouseTrailTracer.mouseDisabled = !settings.autoPosture
        let n = settings.mode == .shove ? shove?.currentNode : currentNode
        fixedTail.addStage(fixStart, currentLayer, isPlacingVia, direction, n)
        return true
    }

    private func initPlacement() {
        idle = false
        head.withLine { $0.clear() }
        tail.withLine { $0.clear() }
        head.net = currentNet
        tail.net = currentNet
        head.setLayer(currentLayer)
        tail.setLayer(currentLayer)
        head.setWidth(sizes.trackWidth)
        tail.setWidth(sizes.trackWidth)
        head.removeVia()
        tail.removeVia()
        lastPEnd = nil
        pStart = currentStart
        direction = initialDirection
        let w = router.world!
        w.killChildren()
        let rootNode = w.branch()
        splitAdjacentSegments(rootNode, startItem, currentStart)
        world = rootNode
        lastNode = nil
        currentNode = world
        shove = Shove(rootNode.branch(), router)
    }

    public func move(_ p: IPoint, _ endItem: Item?) -> Bool { move(p, endItem, isCurrentEnd: false) }

    /// (isCurrentEnd: `p` is currentEnd itself, which KiCad's SetLayer hands its Move by reference, so the trail
    /// takes the end the move leaves there, not `p`)
    private func move(_ p: IPoint, _ endItem: Item?, isCurrentEnd: Bool) -> Bool {
        var eiDepth = -1
        if let owner = endItem?.owner as? Node { eiDepth = owner.depth }
        if let last = lastNode {
            last.parent?.release(last)
            lastNode = nil
        }
        self.endItem = endItem
        let reachesEnd = route(p)
        if isPlacingVia && p == pStart && head.via == nil {
            let fallback = makeVia(p)
            fallback.net = currentNet
            head.appendVia(fallback)
        }
        let current = trace
        var splitPoint = current.pointCount > 0 ? current.cLine.lastPoint : pStart
        if reachesEnd, let endSeg = endItem as? Segment, current.segmentCount > 0 {
            let lastSeg = current.cLine.segment(current.segmentCount - 1)
            let targetSeg = endSeg.seg
            if lastSeg.collinear(targetSeg) && targetSeg.overlaps(lastSeg) {
                splitPoint = targetSeg.nearestPoint(lastSeg.a)
                current.withLine { $0.setPoint(current.pointCount - 1, splitPoint) }
                head.withLine { $0.setPoint(head.pointCount - 1, splitPoint) }
            }
        }
        currentEnd = current.pointCount == 0 ? pStart : splitPoint
        let latestNode = currentNode!
        lastNode = latestNode.branch()
        if reachesEnd && eiDepth >= 0, let endItem, latestNode.depth >= eiDepth, current.segmentCount > 0 {
            if endItem.net == currentNet { splitAdjacentSegments(lastNode!, endItem, splitPoint) }
            if settings.removeLoops { removeLoops(lastNode!, current) }
        }
        mouseTrailTracer.addTrailPoint(isCurrentEnd ? currentEnd : p)
        return true
    }

    public func fixRoute(_ p: IPoint, _ endItem: Item?, forceFinish: Bool) -> Bool {
        var fixAll = settings.fixAllSegments
        var realEnd = false
        let pl = trace
        if settings.mode == .markObstacles, let endItem, let iface = router.iface {
            if iface.netCode(currentNet) <= 0 {
                currentNet = endItem.net
                pl.net = currentNet
            } else if iface.netCode(endItem.net) <= 0 {
                endItem.net = currentNet
            }
        }
        if !settings.allowDRCViolations {
            let checkNode = settings.mode == .shove ? (shove?.currentNode ?? world!) : world!
            if let obs = checkNode.checkColliding(pl) {
                if settings.mode != .shove || obs.item.ofKind(.solid) { return false }
            }
        }
        let l = pl.cLine
        if l.segmentCount == 0 {
            if let lastNode {
                let (_, added) = lastNode.updatedItems()
                if let last = added.last as? Segment { simplifyNewLine(lastNode, last) }
            }
            guard let via = pl.via else { return false }
            if let lastNode {
                let newVia = via.clone() as! Via
                newVia.resetUid()
                lastNode.add(newVia)
                shove?.addLockedSpringbackNode(lastNode)
            }
            currentNode = nil
            idle = true
            placementCorrect = true
            return true
        }
        var pPreLast = l.lastPoint
        let pLast = l.lastPoint
        if l.pointCount > 2 { pPreLast = l.point(l.pointCount - 2) }
        if let endItem, let cn = currentNet, cn == endItem.net { realEnd = true }
        if forceFinish { realEnd = true }
        // (KiCad's undo of a part fixed short is wrong with arcs, so with arcs it fixes it all)
        if !fixAll && l.arcCount > 0 { fixAll = true }
        // (worked out wrongly, as KiCad says, if the line ends on an arc)
        let lastDirSeg = (!fixAll && l.segmentCount > 1) ? l.segment(-2) : l.segment(-1)
        let dLast = Direction45(lastDirSeg)
        let lastV = (realEnd || isPlacingVia || fixAll) ? l.segmentCount : max(1, l.segmentCount - 1)
        var lastItem: LinkedItem?
        var lastArc = -1
        for i in 0..<lastV {
            let arcIndex = l.arcIndex(i)
            if arcIndex < 0 || (lastArc >= 0 && i == lastV - 1 && !l.isPointOnArc(lastV)) {
                let seg = Segment(pl.cSegment(i), net: currentNet)
                seg.width = pl.width
                seg.setLayer(currentLayer)
                lastItem = seg
                if !lastNode!.add(seg) { lastItem = nil }
            } else {
                // an arc, once (and the segment from an arc's end to the next arc's start with it: KiCad's quirk, which
                // leaves it out)
                if arcIndex == lastArc { continue }
                let arc = Arc(l.arcs[arcIndex], net: currentNet)
                arc.width = pl.width
                arc.setLayer(currentLayer)
                lastItem = arc
                if !lastNode!.add(arc) { lastItem = nil }
                lastArc = arcIndex
            }
        }
        if let via = pl.via {
            let newVia = via.clone() as! Via
            newVia.resetUid()
            lastNode!.add(newVia)
        }
        if let lastItem { simplifyNewLine(lastNode!, lastItem) }
        if !realEnd {
            setInitialDirection(dLast)
            currentStart = (isPlacingVia || fixAll) ? pLast : pPreLast
            fixedTail.addStage(fixStart, currentLayer, isPlacingVia, direction, currentNode)
            fixStart = currentStart
            startItem = nil
            isPlacingVia = false
            chainedPlacement = pl.via == nil
            pStart = currentStart
            direction = initialDirection
            head.withLine { $0.clear() }
            tail.withLine { $0.clear() }
            head.removeVia()
            tail.removeVia()
            currentNode = lastNode
            lastNode = lastNode!.branch()
            shove?.addLockedSpringbackNode(currentNode!)
            let lastSegDir = pl.via != nil ? Direction45() : dLast
            mouseTrailTracer.clear()
            mouseTrailTracer.tolerance = head.width
            mouseTrailTracer.addTrailPoint(currentStart)
            mouseTrailTracer.setDefaultDirections(lastSegDir, lastSegDir)
            placementCorrect = true
        } else {
            shove?.addLockedSpringbackNode(lastNode!)
            placementCorrect = true
            idle = true
        }
        return realEnd
    }

    /// Goes back a fixed stage; where the head started, if it had
    public func unfixRoute() -> IPoint? {
        guard let st = fixedTail.popStage() else { return nil }
        let ret: IPoint? = head.pointCount > 0 ? head.cPoint(0) : nil
        head.withLine { $0.clear() }
        tail.withLine { $0.clear() }
        startItem = nil
        pStart = st.pts[0].p
        fixStart = pStart
        direction = st.pts[0].direction
        isPlacingVia = st.pts[0].placingVias
        currentNode = st.commit
        currentLayer = st.pts[0].layer
        currentStart = pStart
        head.setLayer(currentLayer)
        tail.setLayer(currentLayer)
        head.removeVia()
        tail.removeVia()
        mouseTrailTracer.clear()
        mouseTrailTracer.setDefaultDirections(initialDirection, direction)
        mouseTrailTracer.addTrailPoint(pStart)
        if let currentNode {
            shove?.rewindSpringbackTo(currentNode)
            shove?.unlockSpringbackNode(currentNode)
        }
        if settings.mode == .shove, let shove {
            let n = shove.currentNode
            currentNode = n
            n.killChildren()
            // (where KiCad goes on from a node it has just deleted, the port goes on from what is left)
            shove.forgetReleasedNodes()
        }
        lastNode = currentNode?.branch()
        return ret
    }

    public var hasPlacedAnything: Bool { placementCorrect || fixedTail.stageCount > 1 }

    public func commitPlacement() -> Bool {
        // (shoving: what is committed is the last node a part of the route was fixed in, with what it shoved)
        if settings.mode == .shove, let shove {
            shove.rewindToLastLockedNode()
            lastNode = shove.currentNode
            lastNode!.killChildren()
        }
        if let lastNode { router.commitRouting(lastNode) }
        lastNode = nil
        currentNode = nil
        return true
    }

    public func abortPlacement() -> Bool {
        world?.killChildren()
        lastNode = nil
        return true
    }

    private func removeLoops(_ node: Node, _ latest: Line) {
        if latest.segmentCount == 0 { return }
        if latest.cLine.point(0) == latest.cLine.lastPoint { return }
        var toErase: [LinkedItem] = []
        var erasing = Set<ObjectIdentifier>()
        latest.clearLinks()
        node.add(latest, allowRedundant: true)
        for s in 0..<latest.linkCount {
            let seg = latest.getLink(s)
            let ourLine = node.assembleLine(seg)
            var (a, b) = node.findLineEnds(ourLine)
            if let ja = a, let jb = b, ja.tag == jb.tag {
                (a, b) = node.findLineEnds(latest)
            }
            guard let a, let b else { continue }
            for line in node.findLinesBetweenJoints(a, b) where !line.containsLink(seg) && line.segmentCount > 0 {
                if line.links.contains(where: { $0.isLocked }) { continue }
                for ss in line.links where erasing.insert(ObjectIdentifier(ss)).inserted { toErase.append(ss) }
            }
        }
        // (KiCad's set goes by address; here by the order the items were made)
        for s in toErase.sorted(by: { $0.serial < $1.serial }) { node.remove(s) }
        node.remove(latest)
    }

    private func simplifyNewLine(_ node: Node, _ latest: LinkedItem) {
        let (_, added) = node.updatedItems()
        var cleanup: [Item] = []
        var cleanupIDs = Set<ObjectIdentifier>()
        func addCleanup(_ i: Item) {
            if cleanupIDs.insert(ObjectIdentifier(i)).inserted { cleanup.append(i) }
        }
        func processJoint(_ joint: Joint?, _ item: Item) {
            guard let joint, !joint.isLineCorner(), let itemSeg = item as? Segment else { return }
            let refSeg = itemSeg.seg
            for neighbor in joint.links {
                guard neighbor !== item, neighbor.ofKind([.segment, .arc]), neighbor.layersOverlap(item) else { continue }
                // (an arc of the same width there KiCad reads as a segment, which is undefined; the port passes it by)
                guard let nSeg = neighbor as? Segment else { continue }
                if nSeg.width != itemSeg.width { continue }
                let testSeg = nSeg.seg
                if refSeg.contains(testSeg) {
                    let nA = node.findJoint(neighbor.anchor(0), neighbor), nB = node.findJoint(neighbor.anchor(1), neighbor)
                    if (nA === joint && nB?.linkCount() == 1) || (nB === joint && nA?.linkCount() == 1) { addCleanup(neighbor) }
                } else if testSeg.contains(refSeg) {
                    let aA = node.findJoint(item.anchor(0), item), aB = node.findJoint(item.anchor(1), item)
                    if (aA === joint && aB?.linkCount() == 1) || (aB === joint && aA?.linkCount() == 1) {
                        addCleanup(item)
                        return
                    }
                }
            }
        }
        for item in added where item.ofKind(.segment) && !cleanupIDs.contains(ObjectIdentifier(item)) {
            processJoint(node.findJoint(item.anchor(0), item), item)
            processJoint(node.findJoint(item.anchor(1), item), item)
        }
        for seg in cleanup.sorted(by: { $0.serial < $1.serial }) { node.remove(seg) }
        let lOrig = node.assembleLine(latest, stopAtLockedJoints: false, followLockedSegments: false, allowSegmentSizeMismatch: false)
        let l = lOrig.copy()
        let optimized = Optimizer.optimize(l, effort: .mergeColinear, world: node)
        var simplified = l.cLine
        simplified.simplify()
        if optimized || simplified.pointCount != l.pointCount {
            node.remove(lOrig)
            l.setShape(simplified)
            node.add(l)
        }
    }

    public func updateSizes(_ s: SizesSettings) {
        sizes = s
        if !idle {
            if sizes.trackWidthIsExplicit || (!hasPlacedAnything && !(startItem?.kind == .segment)) {
                head.setWidth(sizes.trackWidth)
                tail.setWidth(sizes.trackWidth)
                currentTrace.setWidth(sizes.trackWidth)
            }
            if head.via != nil {
                head.setViaDiameter(sizes.viaDiameter)
                head.setViaDrill(sizes.viaDrill)
            }
        }
    }

    public func setOrthoMode(_ ortho: Bool) { orthoMode = ortho }

    /// The line from the start to `p` as the posture says, with a via at its end if one is being placed (pushed
    /// clear of what is there); whether the via could be placed
    @discardableResult
    private func buildInitialLine(_ p: IPoint, _ aHead: Line, _ mode: RouterMode, forceNoVia: Bool = false) -> Bool {
        var l = LineChain()
        let guessedDir = mouseTrailTracer.posture(p)
        var cornerMode = settings.cornerMode
        if orthoMode { cornerMode = .mitered45 }
        if pStart == p {
            l.clear()
        } else {
            if settings.freeAngleMode && settings.mode == .markObstacles {
                l = LineChain([pStart, p])
            } else if tail.pointCount == 0 {
                l = guessedDir.buildInitialTrace(pStart, p, startDiagonal: false, mode: cornerMode)
            } else {
                l = direction.buildInitialTrace(pStart, p, startDiagonal: false, mode: cornerMode)
            }
            if l.segmentCount > 1 && orthoMode {
                let newLast = l.segment(0).lineProject(l.lastPoint)
                l.remove(-1, -1)
                l.setPoint(1, newLast)
            }
        }
        aHead.setLayer(currentLayer)
        aHead.setShape(l)
        Router.dbg("buildInitialLine: m_direction \(direction), guessedDir \(guessedDir), tail points \(tail.pointCount)")
        Router.dbg("initial-trace: \(l.points)")
        if !isPlacingVia || forceNoVia { return true }
        let v = makeVia(p)
        v.net = aHead.net
        if mode == .markObstacles {
            aHead.appendVia(v)
            return true
        }
        let collMask: ItemKind = mode == .walkaround ? .any : .solid
        let iterLimit = settings.viaForcePropIterationLimit
        for attempt in 0..<2 {
            var lead = p - pStart
            if attempt == 1, let lastPEnd { lead = p - lastPEnd }
            if let force = v.pushoutForce(currentNode!, direction: lead, kinds: collMask, maxIterations: iterLimit) {
                let line = guessedDir.buildInitialTrace(pStart, p + force, startDiagonal: false, mode: cornerMode)
                aHead.assign(Line(aHead, line))
                v.setPos(v.pos + force)
                aHead.appendVia(v)
                return true
            }
        }
        return false
    }
}
