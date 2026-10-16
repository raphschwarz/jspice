// Ported from KiCad 10.0.7: pcbnew/router/pns_shove.h and pns_shove.cpp (lines and vias pushed out of a routed
// line's way, and lines walked round what cannot be pushed; not arcs, which the port's lines do not have).
// Copyright (C) 2013-2014 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// The push and shove (KiCad's PNS::SHOVE): what the head being routed comes too close to is pushed out of its way,
/// and what that comes too close to in turn, each line walked round the hulls of what pushes it; vias are pushed
/// along with the tracks that end on them, and what cannot be pushed (a pad, a locked track) is walked round. Each
/// shove is made in a branch of the world, and the branches are kept on a stack: when the head draws back from what
/// it pushed, the branch is let go, and what was pushed springs back.
public final class Shove {
    /// How a shove went (KiCad's SHOVE_STATUS)
    public enum Status: Int, Sendable { case ok = 0, null, incomplete, headModified, tryWalk }

    /// What may be done to a line (KiCad's SHOVE_POLICY; none is SHP_DEFAULT)
    public struct Policy: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shove = Policy(rawValue: 0x1)
        public static let walkForward = Policy(rawValue: 0x2)
        public static let walkBack = Policy(rawValue: 0x4)
        public static let ignore = Policy(rawValue: 0x8)
        public static let dontOptimize = Policy(rawValue: 0x10)
        public static let dontLockEndpoints = Policy(rawValue: 0x20)
        public static let reversed = Policy(rawValue: 0x40)
    }

    /// A line as it was before it was first shoved, and as it is now (KiCad's ROOT_LINE_ENTRY), shared by the
    /// unique ids of all its segments, old and new
    final class RootLineEntry {
        var rootLine: Line?
        var oldVia: Via?
        var newVia: Via?
        var newLine: Line?
        var policy: Policy
        var isHead = false

        init(_ rootLine: Line? = nil, _ policy: Policy = []) {
            self.rootLine = rootLine
            self.policy = policy
        }
    }

    /// What is to be shoved: a line, or a via dragged to a new place (KiCad's HEAD_LINE_ENTRY)
    final class HeadLineEntry {
        var geometryModified = false
        var prevVia: Via.Handle?
        var theVia: Via.Handle?
        var draggedVia: Via?
        var viaNewPos = IPoint.zero
        var origHead: Line?
        var newHead: Line?
        var policy: Policy

        init(_ orig: Line, _ policy: Policy) {
            origHead = orig.copy()
            origHead!.clearLinks()
            self.policy = policy
        }

        init(via: Via.Handle, _ policy: Policy) {
            theVia = via
            self.policy = policy
        }
    }

    /// A shove's branch on the springback stack (KiCad's SPRINGBACK_TAG)
    struct SpringbackTag {
        var length = 0
        var draggedVias: [Via.Handle?] = []
        var p = IPoint.zero
        var node: Node
        var affectedArea: IBox?
        var seq = 0
        var locked = false
    }

    unowned let router: Router
    var settings: RoutingSettings { router.settings }

    private var nodeStack: [SpringbackTag] = []
    private var lineStack: [Line] = []
    private var optimizerQueue: [Line] = []
    private var headLines: [HeadLineEntry] = []
    private var rootLineHistory: [LinkedItem.UniqueID: RootLineEntry] = [:]
    private let root: Node
    private var _currentNode: Node?
    private weak var springbackDoNotTouchNode: Node?
    private var restrictSpringbackTagId = 0
    private var draggedVia: Via?
    private var iter = 0
    private var _headsModified = false
    private var forceClearance = -1
    private var multiLineMode = false
    private var optFlagDisableMask: Optimizer.Effort = []
    private var defaultPolicy: Policy = .shove
    private var affectedArea: IBox?

    init(_ world: Node, _ router: Router) {
        root = world
        _currentNode = world
        self.router = router
    }

    private static func dbg(_ message: @autoclosure () -> String) { Router.dbg(message()) }

    /// The node the shove is at (KiCad's CurrentNode): its last branch, else the one it started from
    public var currentNode: Node { _currentNode ?? root }

    public func forceClearance(_ enabled: Bool, _ clearance: Int) { forceClearance = enabled ? clearance : -1 }

    // MARK: - Replacing what is shoved

    /// KiCad's ChangedArea (pns_utils.cpp) for two items: the vias' or the lines'
    private static func changedArea(_ a: Item, _ b: Item) -> IBox? {
        if let va = a as? Via, let vb = b as? Via { return va.changedArea(vb) }
        if let la = a as? Line, let lb = b as? Line { return la.changedArea(lb) }
        return nil
    }

    private func mergeAffectedArea(_ area: IBox?) {
        guard let area else { return }
        if var a = affectedArea {
            a.merge(area)
            affectedArea = a
        } else {
            affectedArea = area
        }
    }

    /// An item (a via) replaced by another in the current node, its root line kept for the new one
    private func replaceItems(_ old: Item, _ new: Item) {
        mergeAffectedArea(Shove.changedArea(old, new))
        var re: RootLineEntry?
        var newId: LinkedItem.UniqueID = 0
        if old.ofKind(.via), let vold = old as? Via, let vnew = new as? Via {
            re = touchRootLine(vold)
            re!.newVia = vnew
            newId = vnew.uid
            Shove.dbg("replace-via vold [\(vold.pos.x) \(vold.pos.y)]-> vnew [\(vnew.pos.x) \(vnew.pos.y)] nid \(newId)")
        }
        currentNode.replace(old, with: new)
        if let re { rootLineHistory[newId] = re }
    }

    /// A line replaced by another in the current node (or `node`): the old line's root line, the line as it was
    /// before it was first shoved, kept for the new one
    @discardableResult
    private func replaceLine(_ old: Line, _ new: Line, includeInChangedArea: Bool = true, allowRedundantSegments: Bool = true,
                             node: Node? = nil) -> RootLineEntry {
        if includeInChangedArea, let changed = old.changedArea(new) {
            Shove.dbg("shove-changed-area: rect (\(changed.minX),\(changed.minY)) (\(changed.maxX),\(changed.maxY))")
            mergeAffectedArea(changed)
        }
        if old.via != nil, let viaLink = old.links.first(where: { $0.ofKind(.via) }) { old.unlink(viaLink) }
        var foundPredecessor = false
        var rootEntry: RootLineEntry?
        // (the line shoved before, in an earlier iteration or for an earlier pointer position?)
        for link in old.links {
            if let e = rootLineHistory[link.uid] {
                rootEntry = e
                foundPredecessor = true
                break
            }
        }
        // (if not, a new root line)
        if !foundPredecessor {
            if rootEntry == nil { rootEntry = RootLineEntry(old.copy()) }
            for link in old.links { rootLineHistory[link.uid] = rootEntry }
        }
        (node ?? currentNode).replace(old, with: new, allowRedundantSegments: allowRedundantSegments)
        for link in new.links { rootLineHistory[link.uid] = rootEntry }
        rootEntry!.newLine = new.copy()
        return rootEntry!
    }

    /// The clearance between two items, their holes' too (KiCad's getClearance)
    private func getClearance(_ a: Item, _ b: Item) -> Int {
        if forceClearance >= 0 { return forceClearance }
        var clearance = currentNode.clearance(a, b, useEpsilon: false)
        if a.hasHole, let h = a.hole { clearance = max(clearance, currentNode.clearance(h, b, useEpsilon: false)) }
        if b.hasHole, let h = b.hole { clearance = max(clearance, currentNode.clearance(a, h, useEpsilon: false)) }
        return clearance
    }

    /// The line `seg` is part of, stopping at locked joints; cleaned of collinear corners first, if asked
    private func assembleLine(_ seg: LinkedItem, _ index: UnsafeMutablePointer<Int>? = nil, preCleanup: Bool = false) -> Line {
        let cur = currentNode.assembleLine(seg, originSegmentIndex: index, stopAtLockedJoints: true)
        if preCleanup {
            let cleaned = Line()
            if preShoveCleanup(cur, cleaned) { return cleaned }
        }
        return cur
    }

    /// Whether the shoved line went round the line pushing it on the outside (KiCad's checkShoveDirection): there
    /// is no orientation for an open curve, so the heuristic is that a line shoved the wrong way wraps round the
    /// pusher's start
    private func checkShoveDirection(_ curLine: Line, _ obstacleLine: Line, _ shovedLine: Line) -> Bool {
        let root = findRootLine(curLine)
        let loneVia = curLine.pointCount == 0 && curLine.via != nil
        var cp = loneVia ? curLine.via!.pos : (curLine.pointCount > 0 ? curLine.cPoint(0) : .zero)
        // (a reversed head, the pusher its first point: its last point checked instead)
        if let root, root.policy.contains(.reversed), !loneVia { cp = curLine.cPoint(-1) }
        var checker = LineChain.PointInsideTracker(cp)
        checker.addPolyline(obstacleLine.cLine)
        checker.addPolyline(shovedLine.cLine.reversed())
        let inside = checker.isInside()
        Shove.dbg("chkdir \(inside ? 1 : 0): point (\(cp.x),\(cp.y))")
        return !inside
    }

    /// `obstacleLine` walked round the hull of `curLine`'s via, its clearance away (KiCad's shoveLineFromLoneVia),
    /// for a line with nothing but its via on the obstacle's layer
    private func shoveLineFromLoneVia(_ curLine: Line, _ obstacleLine: Line, _ resultLine: Line) -> Bool {
        let obstacleLineWidth = obstacleLine.width
        let via = curLine.via!
        var clearance = getClearance(via, obstacleLine)
        let holeClearance = getClearance(via.hole!, obstacleLine)
        if holeClearance + via.drill / 2 > clearance + via.diameter / 2 {
            clearance = holeClearance + via.drill / 2 - via.diameter / 2
        }
        let hull = via.hull(clearance: clearance, walkaroundThickness: obstacleLineWidth, layer: curLine.layer)
        var pathCw = LineChain(), pathCcw = LineChain()
        if !obstacleLine.walkaround(hull, &pathCw, cw: true) { return false }
        if !obstacleLine.walkaround(hull, &pathCcw, cw: false) { return false }
        resultLine.setShape(pathCw)
        if !checkShoveDirection(curLine, obstacleLine, resultLine) { resultLine.setShape(pathCcw) }
        if resultLine.cLine.pointCount < 2 { return false }
        if obstacleLine.cLastPoint != resultLine.cLine.lastPoint { return false }
        if obstacleLine.cPoint(0) != resultLine.cLine.point(0) { return false }
        if resultLine.collide(curLine, currentNode, layer: resultLine.layer) { return false }
        return true
    }

    /// `obstacleLine` walked round each of `hulls` in turn (KiCad's shoveLineToHullSet): clockwise, then
    /// anticlockwise, then both again with the hulls taken the other way round; its ends moved onto a hull they are
    /// all but on, if allowed. The first walk that ends where the line ends, goes round the outside, does not cross
    /// itself and clears `curLine` is the shoved line.
    private func shoveLineToHullSet(_ curLine: Line, _ obstacleLine: Line, _ resultLine: Line, _ hulls: [LineChain],
                                    permitAdjustingStart: Bool = false, permitAdjustingEnd: Bool = false) -> Bool {
        let endpointOnHullThreshold = 1000
        let permitAdjustingEndpoints = permitAdjustingStart || permitAdjustingEnd
        for attempt in 0..<4 {
            let invertTraversal = attempt >= 2
            let clockwise = attempt % 2 == 1
            var vFirst = -1, vLast = -1
            var obs = obstacleLine.cLine
            let l = obstacleLine.copy()
            var path = l.cLine
            if permitAdjustingEndpoints && l.segmentCount >= 1 {
                func minDistP(_ pref: IPoint, _ mdist: inout Int, _ minhull: inout Int) -> IPoint {
                    var minDist = Int(Int32.max)
                    var nearestP = IPoint.zero
                    for i in 0..<hulls.count {
                        let hull = hulls[invertTraversal ? hulls.count - 1 - i : i]
                        let p = hull.nearestPoint(pref)
                        let dist = hull.pointInside(pref) ? 0 : (p - pref).norm
                        if dist < endpointOnHullThreshold && dist < minDist {
                            minDist = dist
                            nearestP = p
                            minhull = invertTraversal ? hulls.count - 1 - i : i
                        }
                    }
                    mdist = minDist
                    return nearestP
                }
                var minDist0 = 0, minDist1 = 0, minhull0 = -1, minhull1 = -1
                let p0 = minDistP(l.cPoint(0), &minDist0, &minhull0)
                let p1 = minDistP(l.cLastPoint, &minDist1, &minhull1)
                Shove.dbg("mindists : \(minDist0) \(minDist1) hulls \(minhull0) \(minhull1)\n")
                if minDist1 < endpointOnHullThreshold && permitAdjustingEnd {
                    l.withLine { $0.append(p1) }
                    obs = l.cLine
                    path = l.cLine
                }
                if minDist0 < endpointOnHullThreshold && permitAdjustingStart {
                    l.withLine { $0.insert(p0, at: 0) }
                    obs = l.cLine
                    path = l.cLine
                }
            }
            var failWalk = false
            for i in 0..<hulls.count {
                let hull = hulls[invertTraversal ? hulls.count - 1 - i : i]
                if !l.walkaround(hull, &path, cw: clockwise) {
                    Shove.dbg("Fail-Walk \(hull.points) \(l.cLine.points) \(clockwise ? 1 : 0)\n")
                    failWalk = true
                    break
                }
                path.simplify2()
                l.setShape(path)
            }
            if failWalk { continue }
            for i in 0..<min(path.pointCount, obs.pointCount) where path.point(i) != obs.point(i) {
                vFirst = i
                break
            }
            var k = obs.pointCount - 1
            var i = path.pointCount - 1
            while i >= 0 && k >= 0 {
                if path.point(i) != obs.point(k) {
                    vLast = i
                    break
                }
                i -= 1
                k -= 1
            }
            if (vFirst < 0 || vLast < 0) && !path.compareGeometry(obs) {
                Shove.dbg("attempt \(attempt) fail vfirst-last")
                continue
            }
            if path.lastPoint != obs.lastPoint || path.point(0) != obs.point(0) {
                Shove.dbg("attempt \(attempt) fail vend-start\n")
                continue
            }
            if !checkShoveDirection(curLine, obstacleLine, l) {
                Shove.dbg("attempt \(attempt) fail direction-check")
                resultLine.setShape(l.cLine)
                continue
            }
            if path.selfIntersecting() != nil {
                Shove.dbg("attempt \(attempt) fail self-intersect")
                continue
            }
            if l.collide(curLine, currentNode, layer: l.layer) {
                Shove.dbg("attempt \(attempt) fail coll-check")
                continue
            }
            resultLine.setShape(l.cLine)
            return true
        }
        return false
    }

    /// `obstacleLine` pushed away from `curLine` by the clearance between them, into `resultLine` (KiCad's
    /// ShoveObstacleLine): walked round the hulls of `curLine`'s segments and its via, grown a little each time that
    /// fails, the obstacle's ends allowed to move at the last try (unless a via holds them)
    public func shoveObstacleLine(_ curLine: Line, _ obstacleLineIn: Line, _ resultLine: Line) -> Bool {
        let hullFailureExpansionFactor = 1000
        var extraHullExpansion = 0
        var voeStart = false, voeEnd = false
        var jtStart: Joint?, jtEnd: Joint?
        if obstacleLineIn.pointCount >= 2 {
            jtStart = currentNode.findJoint(obstacleLineIn.cPoint(0), obstacleLineIn)
            jtEnd = currentNode.findJoint(obstacleLineIn.cLastPoint, obstacleLineIn)
        }
        if let jtStart { voeStart = jtStart.via != nil }
        if let jtEnd { voeEnd = jtEnd.via != nil }
        resultLine.clearLinks()
        let viaOnEnd = curLine.via != nil
        let obstacleLine = obstacleLineIn.copy()
        var obsVia: Via?
        if obstacleLine.via != nil {
            obsVia = Via(copying: obstacleLineIn.via!)
            obstacleLine.removeVia()
        }
        Shove.dbg("shove process-single: voe-cur \(viaOnEnd ? 1 : 0) voe-obs \(obstacleLineIn.via != nil ? 1 : 0)")
        if viaOnEnd && (!curLine.layersOverlap(obstacleLine) || curLine.segmentCount == 0) {
            // (the obstacle shoved to the hull of curLine's via)
            return shoveLineFromLoneVia(curLine, obstacleLine, resultLine)
        }
        // hulls round curLine's segments, the clearance and half the obstacle's width away, so that the obstacle
        // walked round them is the clearance away
        let obstacleLineWidth = obstacleLine.width
        let clearance = getClearance(curLine, obstacleLine)
        let currentLineSegmentCount = curLine.segmentCount
        for attempt in 0..<3 {
            var hulls: [LineChain] = []
            hulls.reserveCapacity(currentLineSegmentCount + 1)
            for i in 0..<currentLineSegmentCount {
                let seg = Segment(line: curLine, curLine.cSegment(i))
                hulls.append(seg.hull(clearance: clearance + extraHullExpansion, walkaroundThickness: obstacleLineWidth,
                                      layer: obstacleLine.layer))
            }
            if viaOnEnd {
                let via = curLine.via!
                var viaClearance = getClearance(via, obstacleLine)
                let holeClearance = getClearance(via.hole!, obstacleLine)
                let layer = obstacleLineIn.layer
                if holeClearance + via.drill / 2 > viaClearance + via.diameter / 2 {
                    viaClearance = holeClearance + via.drill / 2 - via.diameter / 2
                }
                hulls.append(via.hull(clearance: viaClearance, walkaroundThickness: obstacleLineWidth, layer: layer))
            }
            let permitMovingStart = attempt >= 2 && !voeStart
            let permitMovingEnd = attempt >= 2 && !voeEnd
            if shoveLineToHullSet(curLine, obstacleLine, resultLine, hulls, permitAdjustingStart: permitMovingStart,
                                  permitAdjustingEnd: permitMovingEnd) {
                if let obsVia { resultLine.appendVia(obsVia) }
                return true
            }
            extraHullExpansion += hullFailureExpansionFactor
        }
        return false
    }

    // MARK: - Collisions

    /// The line of a segment `current` collides with shoved out of its way (KiCad's onCollidingSegment); a line
    /// with locked segments is to be walked round instead
    private func onCollidingSegment(_ current: Line, _ obstacleSeg: Segment) -> Status {
        var segIndex = 0
        let obstacleLine = assembleLine(obstacleSeg, &segIndex, preCleanup: true)
        let shovedLine = obstacleLine.copy()
        if obstacleLine.hasLockedSegments {
            Shove.dbg("try walk (locked segments)")
            return .tryWalk
        }
        let shoveOK = shoveObstacleLine(current, obstacleLine, shovedLine)
        if shoveOK {
            let rank = current.lineRank
            shovedLine.setRank(rank - 1)
            shovedLine.withLine { $0.simplify2() }
            unwindLineStack(item: obstacleLine)
            replaceLine(obstacleLine, shovedLine, includeInChangedArea: true, allowRedundantSegments: false)
            if !pushLineStack(shovedLine) { return .incomplete }
            return .ok
        }
        return .incomplete
    }

    /// `obstacle` (a line) shoved out of `current`'s way, given `nextRank` (KiCad's onCollidingLine)
    private func onCollidingLine(_ current: Line, _ obstacle: Line, _ nextRank: Int) -> Status {
        let shovedLine = obstacle.copy()
        let shoveOK = shoveObstacleLine(current, obstacle, shovedLine)
        if shoveOK {
            replaceLine(obstacle, shovedLine, includeInChangedArea: true, allowRedundantSegments: false)
            shovedLine.setRank(nextRank)
            if !pushLineStack(shovedLine) { return .incomplete }
            return .ok
        }
        return .incomplete
    }

    /// `current` walked round what it cannot push, a pad or a hole (KiCad's onCollidingSolid), and the cluster of
    /// what touches it; or, if `current` ends in a via that collides with it, the via pushed away instead
    private func onCollidingSolid(_ current: Line, _ obstacle: Item, _ obstacleInfo: inout Obstacle) -> Status {
        var walkaroundLine = current.copy()
        if let vh = current.via {
            var via: Via?
            guard let jtStart = currentNode.findJoint(vh.pos, current) else { return .incomplete }
            for item in jtStart.links where item.ofKind(.via) {
                via = item as? Via
                break
            }
            if let via, via.collide(obstacle, currentNode, layer: obstacle.layer) {
                return onCollidingVia(obstacle, via, &obstacleInfo, obstacle.rank - 1)
            }
        }
        let topo = Topology(currentNode)
        let cluster = topo.assembleCluster(obstacle, layer: current.layers.start, areaExpansionLimit: 10.0)
        let walkaround = Walkaround(world: currentNode, router: router)
        walkaround.setSolidsOnly(false)
        walkaround.restrictToCluster(true, cluster)
        walkaround.setAllowedPolicies([.shortest])
        walkaround.iterationLimit = settings.walkaroundIterationLimit
        let currentRank = current.lineRank
        var nextRank = 0
        var success = false
        for attempt in 0..<2 {
            if attempt == 1 || settings.jumpOverObstacles {
                nextRank = currentRank - 1
            } else {
                nextRank = currentRank + 10000
            }
            let status = walkaround.route(current)
            if status.status[Walkaround.Policy.shortest.rawValue] != .done { continue }
            walkaroundLine = status.lines[Walkaround.Policy.shortest.rawValue].copy()
            walkaroundLine.clearLinks()
            walkaroundLine.unmark()
            walkaroundLine.withLine { $0.simplify2() }
            if walkaroundLine.hasLoops { continue }
            if let lastLine = lineStack.first?.copy() {
                if lastLine.collide(walkaroundLine, currentNode, layer: lastLine.layer) {
                    let dummy = lastLine.copy()
                    if shoveObstacleLine(walkaroundLine, lastLine, dummy) {
                        success = true
                        break
                    }
                } else {
                    success = true
                    break
                }
            }
        }
        if !success { return .incomplete }
        replaceLine(current, walkaroundLine, includeInChangedArea: true, allowRedundantSegments: false)
        walkaroundLine.setRank(nextRank)
        popLineStack()
        if !pushLineStack(walkaroundLine) { return .incomplete }
        return .ok
    }

    /// Root lines forgotten for what a branch let go of had added (KiCad's pruneRootLines)
    private func pruneRootLines(_ removedNode: Node) {
        Shove.dbg("prune called")
        let (_, added) = removedNode.updatedItems()
        for case let li as LinkedItem in added where li.ofKind(.linkedItems) { rootLineHistory[li.uid] = nil }
    }

    /// The branches on the stack the heads no longer collide with let go, down to a locked one (KiCad's
    /// reduceSpringback); the one now on top (the dragged vias as they were in it)
    private func reduceSpringback(_ headSet: [Item]) -> Node {
        while nodeStack.count > 1 {
            let spTag = nodeStack[nodeStack.count - 1]
            // (not a node the line placer still uses: its end item's)
            if let dnt = springbackDoNotTouchNode, spTag.node === dnt { break }
            let obs = spTag.node.checkColliding(headSet)
            if obs == nil && !spTag.locked {
                Shove.dbg("pop-sp depth=\(spTag.node.depth)")
                pruneRootLines(spTag.node)
                spTag.node.parent?.release(spTag.node)
                nodeStack.removeLast()
            } else {
                break
            }
        }
        guard let spTag = nodeStack.last else { return root }
        for i in 0..<spTag.draggedVias.count {
            if let v = spTag.draggedVias[i] {
                headLines[i].prevVia = v
                headLines[i].theVia = v
                headLines[i].geometryModified = true
                Shove.dbg("restore-springback-via depth=\(spTag.node.depth) \(nodeStack.count) \(v.pos.x) \(v.pos.y) \(v.layers.start) \(v.layers.end) ")
            }
        }
        return spTag.node
    }

    /// `node` pushed onto the springback stack, with the dragged vias as they were before the shove and the area
    /// changed so far (KiCad's pushSpringback)
    @discardableResult
    private func pushSpringback(_ node: Node, _ area: IBox?) -> Bool {
        var prevArea: IBox?
        if let last = nodeStack.last { prevArea = last.affectedArea }
        var st = SpringbackTag(node: node)
        st.draggedVias = Array(repeating: nil, count: headLines.count)
        for (n, head) in headLines.enumerated() {
            if let vhandle = head.theVia {
                Shove.dbg("push-sp via depth=\(node.depth) \(vhandle.pos.x) \(vhandle.pos.y) \(vhandle.layers.start) \(vhandle.layers.end) ")
                st.draggedVias[n] = vhandle
            }
        }
        if let area {
            if var prev = prevArea {
                prev.merge(area)
                st.affectedArea = prev
            } else {
                st.affectedArea = area
            }
        } else {
            st.affectedArea = prevArea
        }
        st.seq = nodeStack.last.map { $0.seq + 1 } ?? 1
        st.locked = false
        nodeStack.append(st)
        Shove.dbg("push-sp depth=\(node.depth)")
        return true
    }

    /// A via pushed by at least `force` (KiCad's pushOrShoveVia), further if that lands it on a joint, and the
    /// tracks ending on it dragged along; a via with nothing on it (a stitching via) is remembered as a line of its
    /// own
    private func pushOrShoveVia(_ via: Via, _ force: IPoint, _ newRank: Int, dontUnwindStack: Bool = false) -> Status {
        var draggedLines: [(Line, Line)] = []
        let p0 = via.pos
        let jt = currentNode.findJoint(p0, via)
        var p0Pushed = p0 + force
        Shove.dbg("via force [\(force.x) \(force.y)]\n")
        // (nothing to do)
        if force.x == 0 && force.y == 0 { return .ok }
        guard let jt else {
            Shove.dbg("weird, can't find the center-of-via joint\n")
            return .incomplete
        }
        if !settings.shoveVias || via.isLocked { return .tryWalk }
        if jt.isJointLocked { return .incomplete }
        // (not onto a joint already there)
        while currentNode.findJoint(p0Pushed, via) != nil { p0Pushed = p0Pushed + force.resized(2) }
        let pushedVia = via.clone() as! Via
        pushedVia.setPos(p0Pushed)
        pushedVia.mark(via.marker)
        for item in jt.links where item.ofKind([.segment, .arc]) {
            let li = item as! LinkedItem
            var segIndex = 0
            let first = assembleLine(li, &segIndex)
            if first.hasLockedSegments { return .tryWalk }
            if segIndex == 0 { first.reverse() }
            let second = first.copy()
            second.clearLinks()
            second.dragCorner(p0Pushed, second.cLine.find(p0))
            second.withLine { $0.simplify2() }
            draggedLines.append((first, second))
        }
        pushedVia.rank = newRank
        Shove.dbg("via rank \(pushedVia.rank), fanout \(draggedLines.count)\n")
        if !dontUnwindStack { unwindLineStack(linked: via) }
        replaceItems(via, pushedVia)
        // (a stitching via? the router must not forget it)
        if draggedLines.isEmpty {
            let tmpLine = Line()
            tmpLine.linkVia(pushedVia)
            if !pushLineStack(tmpLine) { return .incomplete }
        }
        for (n, pair) in draggedLines.enumerated() {
            let first = pair.0.copy(), second = pair.1.copy()
            if !dontUnwindStack { unwindLineStack(item: first) }
            Shove.dbg("fan \(n)/\(draggedLines.count)\n")
            if second.segmentCount > 0 {
                second.clearLinks()
                let rootEntry = replaceLine(first, second, includeInChangedArea: true, allowRedundantSegments: true)
                second.linkVia(pushedVia)
                if !dontUnwindStack { unwindLineStack(item: second) }
                second.setRank(newRank)
                // (KiCad: "it's inelegant")
                rootEntry.newLine = second.copy()
                Shove.dbg("PushViaF \(second.segmentCount) eov \(second.via != nil ? 1 : 0)\n")
                if !pushLineStack(second) { return .incomplete }
            } else {
                currentNode.remove(first)
            }
        }
        return .ok
    }

    /// The minimum translation that clears `obstacleVia` of `current` (a line, its via first, or a pad), and the
    /// via pushed by it (KiCad's onCollidingVia)
    private func onCollidingVia(_ current: Item, _ obstacleVia: Via, _ obstacleInfo: inout Obstacle, _ nextRank: Int) -> Status {
        let clearance = getClearance(current, obstacleVia)
        var mtv = IPoint.zero
        var lineCollision = false, viaCollision = false, solidCollision = false
        var mtvLine = IPoint.zero, mtvVia = IPoint.zero, mtvSolid = IPoint.zero
        Shove.dbg("[push-via-by-line]")
        if let currentLine = current as? Line {
            let vtmp = Via(copying: obstacleVia)
            if obstacleInfo.maxFanoutWidth > 0 && obstacleInfo.maxFanoutWidth > obstacleVia.diameter {
                vtmp.setDiameter(obstacleInfo.maxFanoutWidth)
            }
            // (the obstacle via's circle against the line, as KiCad's Collide( SHAPE_CIRCLE, SHAPE_LINE_CHAIN ) gives
            // it: the circle pushed out)
            if let f = Shape.chain(currentLine.cLine).pushout(circle: vtmp.pos, radius: vtmp.diameter / 2,
                                                               clearance: clearance + currentLine.width / 2) {
                lineCollision = true
                mtvLine = f
            }
            // (the line's via, which goes first)
            if let currentVia = currentLine.via {
                let viaClearance = getClearance(currentVia, vtmp)
                for _ in currentVia.relevantShapeLayers(vtmp) {
                    var layerMtv = IPoint.zero
                    if let f = Shape.circle(center: currentVia.pos, radius: currentVia.diameter / 2)
                        .pushout(circle: vtmp.pos, radius: vtmp.diameter / 2, clearance: viaClearance) {
                        viaCollision = true
                        layerMtv = f
                    }
                    if layerMtv.squaredNorm > mtvVia.squaredNorm { mtvVia = layerMtv }
                }
            }
        } else if current.ofKind(.solid) {
            Shove.dbg("collidee-is-solid")
            if let s = current.shape(-1),
               let f = s.pushout(circle: obstacleVia.pos, radius: obstacleVia.diameter / 2, clearance: clearance) {
                solidCollision = true
                mtvSolid = f
            }
        }
        // (KiCad: "we may have a sign issue in Collide(CIRCLE, LINE_CHAIN)")
        if viaCollision {
            mtv = -mtvVia
        } else if lineCollision {
            mtv = -mtvLine
        } else if solidCollision {
            mtv = -mtvSolid
        } else {
            mtv = .zero
        }
        let st = pushOrShoveVia(obstacleVia, -mtv, nextRank)
        Shove.dbg("push-or-shove-via st \(st.rawValue)")
        return st
    }

    /// `current` (a line ranked below the via it collides with, which has been shoved already) walked round the
    /// via and the tracks on it instead (KiCad's onReverseCollidingVia); if its own via collides with the other,
    /// the other is pushed
    private func onReverseCollidingVia(_ current: Line, _ obstacleVia: Via, _ obstacleInfo: inout Obstacle) -> Status {
        var n = 0
        if let currentVia = current.via {
            let p0 = currentVia.pos, p1 = obstacleVia.pos
            let dist = (p0 - p1).norm - currentVia.diameter / 2 - obstacleVia.diameter / 2
            let clearance = getClearance(currentVia, obstacleVia)
            Shove.dbg("via2via coll check dist \(dist) cl \(clearance) delta \(dist - clearance)\n")
            var viaCollision = false
            for _ in currentVia.relevantShapeLayers(obstacleVia) {
                viaCollision = Shape.circle(center: currentVia.pos, radius: currentVia.diameter / 2)
                    .collide(.circle(center: obstacleVia.pos, radius: obstacleVia.diameter / 2), clearance: clearance) || viaCollision
            }
            if viaCollision { return onCollidingVia(current, obstacleVia, &obstacleInfo, current.lineRank - 1) }
        }
        let cur = current.copy()
        cur.clearLinks()
        let jt = currentNode.findJoint(obstacleVia.pos, obstacleVia)
        let shoved = current.copy()
        shoved.clearLinks()
        cur.removeVia()
        unwindLineStack(item: current)
        for item in jt?.links ?? [] where item.ofKind([.segment, .arc]) && item.layersOverlap(current) {
            let li = item as! LinkedItem
            let head = assembleLine(li)
            head.appendVia(obstacleVia)
            let shoveOK = shoveObstacleLine(head, cur, shoved)
            if !shoveOK {
                Shove.dbg("[on-reverse-via-fail-shove]")
                return .incomplete
            }
            cur.setShape(shoved.cLine)
            n += 1
        }
        if n == 0 {
            Shove.dbg("[on-reverse-via-fail-lonevia]")
            let head = current.copy()
            head.withLine { $0.clear() }
            head.appendVia(obstacleVia)
            head.clearLinks()
            let shoveOK = shoveObstacleLine(head, current, shoved)
            if !shoveOK { return .incomplete }
            cur.setShape(shoved.cLine)
        }
        if let v = current.via { shoved.appendVia(v) }
        let currentRank = current.lineRank
        unwindLineStack(item: current)
        replaceLine(current, shoved, includeInChangedArea: true, allowRedundantSegments: false)
        if !pushLineStack(shoved) { return .incomplete }
        shoved.setRank(currentRank)
        return .ok
    }

    // MARK: - The line stack

    /// The lines on the stack with `seg` in them taken off (a line ending in a via kept as its via alone, unless it
    /// is the via that goes), and out of the optimizer's queue (KiCad's unwindLineStack for a LINKED_ITEM)
    private func unwindLineStack(linked seg: LinkedItem) {
        var i = 0
        while i < lineStack.count {
            let l = lineStack[i]
            if l.containsLink(seg) {
                // (a "tadpole": its via kept even with its line gone, so that it still collides with tracks on
                // other layers)
                if l.via != nil && !seg.ofKind(.via) {
                    var via: Via?
                    for link in l.links where link.ofKind(.via) { via = link as? Via }
                    if let via {
                        l.clearLinks()
                        l.withLine { $0.clear() }
                        l.linkVia(via)
                    }
                    i += 1
                } else {
                    lineStack.remove(at: i)
                }
            } else {
                i += 1
            }
        }
        optimizerQueue.removeAll { $0.containsLink(seg) && !seg.ofKind(.via) }
    }

    /// KiCad's unwindLineStack for an ITEM: a segment's lines, or a line's segments' (nothing for a via or a pad)
    private func unwindLineStack(item: Item) {
        if item.ofKind([.segment, .arc]), let li = item as? LinkedItem {
            unwindLineStack(linked: li)
        } else if let l = item as? Line {
            for seg in l.links { unwindLineStack(linked: seg) }
        }
    }

    /// A line pushed onto the stack and queued for the optimizer (KiCad's pushLineStack); a line that is not in
    /// the node cannot be
    @discardableResult
    private func pushLineStack(_ l: Line, keepCurrentOnTop: Bool = false) -> Bool {
        if !l.isLinked && l.segmentCount != 0 {
            Shove.dbg("push line stack failed")
            return false
        }
        if keepCurrentOnTop && !lineStack.isEmpty {
            lineStack.insert(l.copy(), at: lineStack.count - 1)
        } else {
            lineStack.append(l.copy())
        }
        pruneLineFromOptimizerQueue(l)
        optimizerQueue.append(l.copy())
        return true
    }

    /// The queued lines that share a segment with `line` taken out of the optimizer's queue
    @discardableResult
    private func pruneLineFromOptimizerQueue(_ line: Line) -> Bool {
        var i = 0
        while i < optimizerQueue.count {
            var found = false
            for s in line.links where optimizerQueue[i].containsLink(s) && !s.ofKind(.via) {
                optimizerQueue.remove(at: i)
                found = true
                break
            }
            if !found { i += 1 }
        }
        return true
    }

    private func popLineStack() {
        guard let l = lineStack.last else { return }
        pruneLineFromOptimizerQueue(l)
        lineStack.removeLast()
    }

    /// A via made out to be as wide as the widest track on it, if that is as wide as the via, so that the shove
    /// pushes the via instead of failing on the track; a segment ending on a via no wider than itself that the line
    /// would collide with, swapped for the via (KiCad's fixupViaCollisions)
    @discardableResult
    private func fixupViaCollisions(_ current: Line, _ obs: inout Obstacle) -> Bool {
        let layer = current.layer
        // (a via: the widest track on it)
        if obs.item.ofKind(.via), let v = obs.item as? Via {
            var maxw = 0
            let links = currentNode.findJoint(v.pos, v)?.links ?? []
            for link in links {
                if let seg = link as? Segment {
                    maxw = max(seg.width, maxw)
                } else if link.ofKind(.arc), let arc = link as? LinkedItem {
                    maxw = max(arc.width, maxw)
                }
            }
            obs.maxFanoutWidth = 0
            if maxw > 0 && maxw >= v.diameter {
                obs.maxFanoutWidth = maxw + 1
                Shove.dbg("Fixup via: new-w \(maxw) via-w \(v.diameter)")
                return true
            }
            return false
        }
        // (a segment: a via at either end?)
        guard obs.item.ofKind(.segment), let s = obs.item as? Segment else { return false }
        let ja = currentNode.findJoint(s.seg.a, s), jb = currentNode.findJoint(s.seg.b, s)
        for v in [ja?.via, jb?.via] {
            // (a via wider than the segment: the force propagation deals with it)
            guard let v, v.diameter <= s.width else { continue }
            let vtest = Via(copying: v)
            vtest.setDiameter(s.width)
            // (as wide as the segment: if it collides, the via is pushed instead)
            if vtest.collide(current, currentNode, layer: layer) {
                obs.item = v
                obs.maxFanoutWidth = s.width + 1
                return true
            }
        }
        return false
    }

    /// A line ending on a via it is not linked to that collides with something linked to it (KiCad's
    /// patchTadpoleVia)
    @discardableResult
    private func patchTadpoleVia(_ nearest: Item, _ current: Line) -> Bool {
        if current.cLine.pointCount < 1 { return false }
        guard let jtViaEnd = currentNode.findJoint(current.cLine.lastPoint, current), let viaEnd = jtViaEnd.via else { return false }
        let colliding = currentNode.checkColliding(viaEnd) != nil
        if current.via == nil && colliding { current.linkVia(viaEnd) }
        return false
    }

    // MARK: - Shoving

    /// The next collision of the line on top of the stack resolved (KiCad's shoveIteration): the nearest obstacle,
    /// pads first, then vias, segments and holes; one ranked above the line (shoved already) makes the line go
    /// round it instead, one below is shoved, a pad walked round
    private func shoveIteration(_ iter: Int) -> Status {
        let currentLine = lineStack[lineStack.count - 1].copy()
        var nearest: Obstacle?
        var st = Status.null
        let iface = router.iface
        Shove.dbg("current sc=\(currentLine.segmentCount) net=\(iface?.netName(currentLine.net) ?? "") evia=\(currentLine.via != nil ? 1 : 0): \(currentLine.cLine.points)")
        for searchOrder in [ItemKind.solid, .via, .segment, .hole] {
            var opts = CollisionSearchOptions()
            opts.kindMask = searchOrder
            opts.filter = { [unowned self] item in
                var rv = true
                if item.ofKind([.segment, .arc, .via, .solid, .hole]) {
                    // (KiCad takes a pad's or hole's unique id as a linked item's, which none is: no root line)
                    let ent = (item as? LinkedItem).flatMap { self.findRootLine($0) }
                    if ent == nil && self.defaultPolicy.contains(.ignore) { rv = false }
                    if let ent, ent.policy.contains(.ignore) { rv = false }
                } else if self.defaultPolicy.contains(.ignore) {
                    rv = false
                }
                return rv
            }
            nearest = currentNode.nearestObstacle(currentLine, options: opts)
            if let n = nearest { Shove.dbg("nearest \(n.item.kindName) rank \(n.item.rank)") }
            if nearest != nil { break }
        }
        guard var nearest else {
            lineStack.removeLast()
            Shove.dbg("no-nearest-item ")
            return .ok
        }
        let viaFixup = fixupViaCollisions(currentLine, &nearest)
        Shove.dbg("iter \(iter): via-fixup \(viaFixup ? 1 : 0)")
        let ni = nearest.item
        Shove.dbg("NI: \(ni) \(ni.owningNode?.depth ?? -1)")
        unwindLineStack(item: ni)
        if !ni.ofKind(.solid) && ni.rank >= 0 && ni.rank > currentLine.lineRank {
            // a collision with something ranked higher (shoved already)
            switch ni.kind {
            case .via:
                Shove.dbg("[iter \(iter): reverse-collide-via]")
                patchTadpoleVia(ni, currentLine)
                if let v = currentLine.via, ni.collide(v, currentNode, layer: ni.layer) {
                    st = onCollidingVia(currentLine, ni as! Via, &nearest, ni.rank + 1)
                } else {
                    st = onReverseCollidingVia(currentLine, ni as! Via, &nearest)
                }
            case .segment:
                Shove.dbg("[iter \(iter): reverse-collide-segment]")
                let revLine = assembleLine(ni as! Segment)
                popLineStack()
                unwindLineStack(item: revLine)
                patchTadpoleVia(ni, currentLine)
                if let cv = currentLine.via, cv.collide(ni, currentNode, layer: currentLine.layer) {
                    let vh = Via.Handle(pos: cv.pos, layers: cv.layers, net: cv.net)
                    if let rvia = currentNode.findVia(vh) {
                        st = onCollidingVia(revLine, rvia, &nearest, revLine.lineRank + 1)
                    } else {
                        st = .incomplete
                    }
                } else {
                    st = onCollidingLine(revLine, currentLine, revLine.lineRank + 1)
                }
                if !pushLineStack(revLine) { return .incomplete }
            default:
                // (KiCad asserts; arcs, which it shoves as lines, the port's lines do not have)
                break
            }
        } else {
            // a collision with something ranked lower, or a pad
            switch ni.kind {
            case .segment:
                Shove.dbg("[iter \(iter): collide-segment ]")
                st = onCollidingSegment(currentLine, ni as! Segment)
                if st == .tryWalk { st = onCollidingSolid(currentLine, ni, &nearest) }
            case .via:
                Shove.dbg("[iter \(iter): collide-via (fixup: 0)]")
                st = onCollidingVia(currentLine, ni as! Via, &nearest, currentLine.lineRank - 1)
                if st == .tryWalk { st = onCollidingSolid(currentLine, ni, &nearest) }
            case .hole, .solid:
                Shove.dbg("[iter \(iter): walk-solid ]")
                st = onCollidingSolid(currentLine, ni, &nearest)
            default:
                break
            }
        }
        return st
    }

    /// Collisions resolved one after another while they push more, up to the iteration and time limits (KiCad's
    /// shoveMainLoop)
    private func shoveMainLoop() -> Status {
        var st = Status.ok
        affectedArea = nil
        Shove.dbg("ShoveStart [root: \(root.jointCount) jts, current: \(currentNode.jointCount) jts]")
        let iterLimit = settings.shoveIterationLimit
        let start = DispatchTime.now().uptimeNanoseconds
        let timeLimit = UInt64(max(0, settings.shoveTimeLimit)) * 1_000_000
        iter = 0
        if lineStack.isEmpty, let draggedVia {
            // (a free via shoved: a line of just the via on the stack)
            pushLineStack(Line(via: draggedVia))
        }
        while !lineStack.isEmpty {
            Shove.dbg("iter \(iter): stack \(lineStack.count) ")
            st = shoveIteration(iter)
            iter += 1
            let expired = DispatchTime.now().uptimeNanoseconds - start >= timeLimit
            if st == .incomplete || expired || iter >= iterLimit {
                Shove.dbg("Fail [time limit expired: \(expired ? 1 : 0) iter \(iter) iter limit \(iterLimit)")
                st = .incomplete
                break
            }
        }
        return st
    }

    /// The area the shoves have changed so far, this one's and the stack's
    private func totalAffectedArea() -> IBox? {
        var area = nodeStack.last?.affectedArea
        if var a = area, let mine = affectedArea {
            a.merge(mine)
            area = a
        } else if area == nil {
            area = affectedArea
        }
        return area
    }

    // MARK: - Root lines

    private func findRootLine(_ line: Line) -> RootLineEntry? {
        for link in line.links {
            if let e = rootLineHistory[link.uid] { return e }
        }
        return nil
    }

    private func findRootLine(_ item: LinkedItem) -> RootLineEntry? { rootLineHistory[item.uid] }

    /// The line's root line, made if it has none
    @discardableResult
    private func touchRootLine(_ line: Line) -> RootLineEntry {
        for link in line.links {
            if let e = rootLineHistory[link.uid] {
                Shove.dbg("touch [found] uid=\(link.uid) type=\(link.kindName)")
                return e
            }
        }
        let rootEntry = RootLineEntry(line.copy())
        for link in line.links {
            Shove.dbg("touch [create] uid=\(link.uid) type=\(link.kindName)")
            rootLineHistory[link.uid] = rootEntry
        }
        return rootEntry
    }

    @discardableResult
    private func touchRootLine(_ item: LinkedItem) -> RootLineEntry {
        if let e = rootLineHistory[item.uid] {
            Shove.dbg("touch [create] uid=\(item.uid)")
            return e
        }
        let rootEntry = RootLineEntry(nil)
        Shove.dbg("touch [create] uid=\(item.uid)")
        rootLineHistory[item.uid] = rootEntry
        return rootEntry
    }

    /// The shoved lines optimized (KiCad's runOptimizer): merged within the area the shoves changed, twice over in
    /// reverse order, but for the heads and lines not to be
    private func runOptimizer(_ node: Node) {
        let optimizer = Optimizer(world: node)
        var optFlags: Optimizer.Effort = []
        var nPasses = 0
        var area = totalAffectedArea()
        var maxWidth = 0
        for line in optimizerQueue { maxWidth = max(line.width, maxWidth) }
        if let a = area { area = a.inflated(maxWidth).intersection(router.visibleViewArea) }
        switch settings.optimizerEffort {
        case .low:
            optFlags.insert(.mergeObtuse)
            nPasses = 1
        case .medium, .full:
            optFlags.insert(.mergeSegments)
            nPasses = 2
        }
        optFlags.insert(.limitCornerCount)
        if let area {
            Shove.dbg("opt-area: rect (\(area.minX),\(area.minY)) (\(area.maxX),\(area.maxY))")
            optFlags.insert(.restrictArea)
            optimizer.setRestrictArea(area, strict: false)
        }
        // (smart pads cannot do 90 degree corners yet)
        if settings.smartPads && settings.cornerMode == .mitered45 { optFlags.insert(.smartPads) }
        optimizer.effortLevel = optFlags.subtracting(optFlagDisableMask)
        optimizer.collisionKindMask = .any
        for pass in 0..<nPasses {
            optimizerQueue.reverse()
            Shove.dbg("optimize \(optimizerQueue.count) lines, pass \(pass)")
            for i in 0..<optimizerQueue.count {
                let lineToOpt = optimizerQueue[i]
                var rootLine: Line?
                if let rootEntry = findRootLine(lineToOpt) {
                    rootLine = rootEntry.rootLine
                    if rootEntry.policy.contains(.dontOptimize) { continue }
                    if rootEntry.isHead { continue }
                }
                let optimized = Line()
                if optimizer.optimize(lineToOpt, optimized, root: rootLine) {
                    // (KiCad passes its node where the redundant segments flag goes: they are allowed)
                    replaceLine(lineToOpt, optimized, includeInChangedArea: false, allowRedundantSegments: true)
                    // (the queue's lines kept linked to the node)
                    optimizerQueue[i] = optimized
                }
            }
        }
    }

    // MARK: - Springback

    /// A node the line placer has fixed part of a route in, kept however the heads move (KiCad's
    /// AddLockedSpringbackNode)
    @discardableResult
    public func addLockedSpringbackNode(_ node: Node) -> Bool {
        var sp = SpringbackTag(node: node)
        sp.locked = true
        nodeStack.append(sp)
        Shove.dbg("addLockedSPNode depth=\(node.depth) stack=\(nodeStack.count)\n")
        return true
    }

    /// The stack taken back to below `node`, its branches let go (KiCad's RewindSpringbackTo)
    @discardableResult
    public func rewindSpringbackTo(_ node: Node) -> Bool {
        guard let start = nodeStack.firstIndex(where: { $0.node === node }) else { return false }
        node.killChildren()
        nodeStack.removeSubrange(start...)
        _currentNode = nodeStack.last?.node ?? root
        return true
    }

    /// The stack taken back to its last locked node, which becomes the current one (KiCad's
    /// RewindToLastLockedNode); whether there was one
    @discardableResult
    public func rewindToLastLockedNode() -> Bool {
        guard !nodeStack.isEmpty else { return false }
        while !nodeStack[nodeStack.count - 1].locked && nodeStack.count > 1 { nodeStack.removeLast() }
        _currentNode = nodeStack[nodeStack.count - 1].node
        return nodeStack[nodeStack.count - 1].locked
    }

    public func unlockSpringbackNode(_ node: Node) {
        if let i = nodeStack.firstIndex(where: { $0.node === node }) { nodeStack[i].locked = false }
    }

    /// The nodes on the stack that have been let go of taken off it. KiCad's line placer, taking back a part of a
    /// route fixed while the shove had nothing on its stack, kills the children of the shove's first node with the
    /// fixed part's locked node among them, and keeps shoving from that deleted node: what it does then is
    /// undefined. The port has the shove go on from what is still there. (Nowhere else does KiCad let a node on the
    /// stack go, so this is otherwise nothing.)
    public func forgetReleasedNodes() {
        let world = root.root
        func attached(_ node: Node) -> Bool {
            var n = node
            while let p = n.parent { n = p }
            return n === world
        }
        nodeStack.removeAll { !attached($0.node) }
        if let c = _currentNode, !attached(c) { _currentNode = nodeStack.last?.node ?? root }
    }

    public func disablePostShoveOptimizations(_ mask: Optimizer.Effort) { optFlagDisableMask = mask }

    /// A node the springback must not let go of (the one the line placer's end item is in)
    public func setSpringbackDoNotTouchNode(_ node: Node?) { springbackDoNotTouchNode = node }

    // MARK: - Heads

    public func setDefaultShovePolicy(_ policy: Policy) { defaultPolicy = policy }

    public func setShovePolicy(_ item: LinkedItem, _ policy: Policy) { touchRootLine(item).policy = policy }

    public func setShovePolicy(_ line: Line, _ policy: Policy) { touchRootLine(line).policy = policy }

    public func clearHeads() { headLines.removeAll() }

    /// A line to shove with (KiCad's AddHeads)
    public func addHeads(_ head: Line, _ policy: Policy = []) {
        headLines.append(HeadLineEntry(head, policy))
        setShovePolicy(head, policy)
    }

    /// A via to drag to `newPos`, shoving with it (KiCad's AddHeads for a VIA_HANDLE; the dragger's)
    public func addHeads(_ via: Via.Handle, _ newPos: IPoint, _ policy: Policy = []) {
        let ent = HeadLineEntry(via: via, policy)
        ent.viaNewPos = newPos
        ent.prevVia = via
        ent.theVia = via
        headLines.append(ent)
    }

    /// The heads' own items taken back out of the current node (KiCad's removeHeads)
    private func removeHeads() {
        let (_, added) = currentNode.updatedItems()
        for case let li as LinkedItem in added {
            if let rootEntry = findRootLine(li), rootEntry.isHead { currentNode.remove(li) }
        }
    }

    /// The heads as the shove left them (KiCad's reconstructHeads): a head line's new shape, a dragged via's new
    /// place
    private func reconstructHeads(_ shoveFailed: Bool) {
        Shove.dbg("reconstructing \(headLines.count) heads")
        for headEntry in headLines {
            if let origHead = headEntry.origHead {
                guard let rootEntry = findRootLine(origHead) else { continue }
                if let newLine = rootEntry.newLine {
                    headEntry.newHead = newLine.copy()
                    headEntry.geometryModified = !newLine.cLine.compareGeometry(rootEntry.rootLine?.cLine ?? LineChain())
                    Shove.dbg("head [net \(router.iface?.netName(rootEntry.rootLine?.net) ?? "")]: lc-root \(rootEntry.rootLine?.linkCount ?? 0), lc-new \(newLine.linkCount)\n")
                } else {
                    Shove.dbg("head [net \(router.iface?.netName(origHead.net) ?? "")]: unmodified, lc-orig \(origHead.linkCount)\n")
                }
            } else if let dragged = headEntry.draggedVia, let rootEntry = findRootLine(dragged) {
                if let newVia = rootEntry.newVia {
                    headEntry.geometryModified = true
                    headEntry.theVia = Via.Handle(pos: newVia.pos, layers: newVia.layers, net: newVia.net)
                } else if let oldVia = rootEntry.oldVia {
                    headEntry.theVia = Via.Handle(pos: oldVia.pos, layers: oldVia.layers, net: oldVia.net)
                }
            }
            _headsModified = _headsModified || headEntry.geometryModified
        }
    }

    /// The line's collinear corners taken out before it is shoved, in the node too (KiCad's preShoveCleanup)
    private func preShoveCleanup(_ old: Line, _ new: Line) -> Bool {
        var orig = old.cLine
        let vcPrev = orig.pointCount
        orig.simplify2()
        let vcPost = orig.pointCount
        new.assign(old)
        Shove.dbg("**** PreshoveCleanup \(vcPrev) -> \(vcPost)\n")
        if vcPrev != vcPost {
            new.clearLinks()
            new.setShape(orig)
            replaceLine(old, new)
            return true
        }
        return false
    }

    /// The heads shoved (KiCad's Run): the branches they no longer collide with let go, a new branch from the last
    /// one kept, each head put in it and what it collides with shoved; on success the shoved lines optimized, the
    /// heads as the shove left them worked out and taken back out of the branch, and the branch pushed onto the
    /// stack; on failure the branch let go
    public func run() -> Status {
        var st = Status.ok
        multiLineMode = false
        var currentHeadId = 0
        let totalHeads = headLines.count
        _headsModified = false
        lineStack.removeAll()
        optimizerQueue.removeAll()
        var headSet: [Item] = []
        Shove.dbg("shove run (heads: \(headLines.count), depth=\(currentNode.depth))")
        for l in headLines {
            if let theVia = l.theVia {
                Shove.dbg("process head-via [\(theVia.pos.x) \(theVia.pos.y)]")
                if let realVia = currentNode.findVia(theVia) { headSet.append(realVia.clone()) }
            } else {
                headSet.append(l.origHead!.copy())
            }
        }
        // the branches of shoves no longer needed let go
        let parent = reduceSpringback(headSet)
        _currentNode = parent.branch()
        currentNode.clearRanks()
        for headLineEntry in headLines {
            currentNode.clearRanks()
            if let theVia = headLineEntry.theVia {
                // the via pushed to where it is dragged
                guard let viaToDrag = currentNode.findVia(theVia) else {
                    st = .incomplete
                    break
                }
                let viaRoot = touchRootLine(viaToDrag)
                viaRoot.oldVia = viaToDrag
                headLineEntry.draggedVia = viaToDrag
                st = pushOrShoveVia(viaToDrag, headLineEntry.viaNewPos - viaToDrag.pos, 0, dontUnwindStack: true)
                if st != .ok { break }
            } else {
                // the head put in the branch
                let origHead = headLineEntry.origHead!
                currentNode.add(origHead, allowRedundant: true)
                Shove.dbg("touchRoot ohlc \(origHead.linkCount) roots \(rootLineHistory.count)\n")
                let head = origHead.copy()
                // (nothing to shove with)
                if head.segmentCount == 0 && head.via == nil {
                    st = .incomplete
                    break
                }
                currentHeadId += 1
                if !headLineEntry.policy.contains(.dontLockEndpoints) {
                    if head.pointCount > 0 { currentNode.lockJoint(head.cPoint(0), head, true) }
                    if head.via == nil { currentNode.lockJoint(head.cLastPoint, head, true) }
                }
                setShovePolicy(head, headLineEntry.policy)
                head.setRank(100_000)
                if let hv = head.via {
                    let headVia = hv.clone() as! Via
                    headVia.rank = 100_000
                    origHead.linkVia(headVia)
                    head.linkVia(headVia)
                    currentNode.add(headVia)
                }
                let headRoot = touchRootLine(origHead)
                headRoot.isHead = true
                headRoot.rootLine = origHead.copy()
                headRoot.policy = headLineEntry.policy
                if head.via != nil { rootLineHistory[origHead.via!.uid] = headRoot }
                Shove.dbg("headLC \(head.linkCount), rlLC \(headRoot.rootLine!.linkCount) oolc \(origHead.linkCount) eov \(head.via != nil ? 1 : 0)\n")
                Shove.dbg("Shove heads \(currentHeadId)/\(totalHeads) h-lc=\(head.linkCount) net=\(router.iface?.netName(head.net) ?? "") Line=\(headRoot.newLine != nil ? 1 : 0)")
                if !pushLineStack(head) {
                    st = .incomplete
                    break
                }
            }
            st = shoveMainLoop()
            if st != .ok { break }
        }
        Shove.dbg("Shove status : \(st == .ok || st == .headModified ? "OK" : "FAILURE") after \(iter) iterations, heads: \(headLines.count)")
        if st == .ok {
            runOptimizer(currentNode)
            reconstructHeads(false)
            removeHeads()
            // (after reconstructHeads, which brings the via handles up to date)
            pushSpringback(currentNode, affectedArea)
        } else {
            for headEntry in headLines {
                if let prev = headEntry.prevVia {
                    Shove.dbg("Fail-restore via mod [\(headEntry.theVia?.pos.x ?? 0), \(headEntry.theVia?.pos.y ?? 0)] orig [\(prev.pos.x), \(prev.pos.y)]")
                    headEntry.theVia = prev
                    headEntry.geometryModified = true
                    _headsModified = true
                }
            }
            lineStack.removeAll()
            optimizerQueue.removeAll()
            pruneRootLines(currentNode)
            parent.release(currentNode)
            _currentNode = parent
        }
        return st
    }

    /// Whether the shove changed a head, any (-1) or the `index`th
    public func headsModified(_ index: Int = -1) -> Bool { index < 0 ? _headsModified : headLines[index].geometryModified }

    /// The `index`th head as the shove left it
    public func modifiedHead(_ index: Int) -> Line { headLines[index].newHead!.copy() }

    public func modifiedHeadVia(_ index: Int) -> Via.Handle { headLines[index].theVia! }
}
