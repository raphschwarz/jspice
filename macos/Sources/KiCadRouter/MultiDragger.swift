// Ported from KiCad 10.0.7: pcbnew/router/pns_multi_dragger.h and pns_multi_dragger.cpp (several tracks dragged
// together, their segments or their ends).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// Several tracks dragged together by the pointer (KiCad's PNS::MULTI_DRAGGER, which KiCad calls a very trivial
/// version for demonstration): the line of each segment or arc dragged, the one the pointer is on or nearest it the
/// primary; their ends dragged (the corner mode, where the pointer starts at a line's end, each line's end taken to
/// lie as far off the primary's last segment as it did) or their segments (each moved as far as the primary's, those
/// parallel to it), each line kept only where it runs the way the primary does; then walked round what is in the way
/// (each in turn, nearest first and nearest last, the shorter kept), shoved as one (all heads of one shove) or kept
/// as they are, each clipped short of the lines before it, marking obstacles.
public final class MultiDragger: DragAlgo {
    unowned let router: Router
    var settings: RoutingSettings { router.settings }

    /// A line dragged (KiCad's MDRAG_LINE). KiCad copies these as values; `copy()` is its copy.
    final class MDragLine {
        var leaderItem: Item?
        var originalLeaders: [LinkedItem] = []
        var isStrict = false
        var isMidSeg = false
        var isCorner = false
        var isDraggable = false
        var leaderSegIndex = -1
        var cornerIsLast = false
        /// The whole line to drag, as it was, as it is before the drag (its end taken off, in one posture), as the
        /// drag leaves it, and before the shove
        var originalLine = Line()
        var preDragLine = Line()
        var draggedLine = Line()
        var preShoveLine = Line()
        var dragOK = false
        /// The line the pointer is on (the primary one, the others placed by it)
        var isPrimaryLine = false
        var clipDone = false
        var offset = 0
        var midSeg = Seg(.zero, .zero)
        var dragDist = 0
        var cornerDistance = 0
        var leaderSegDistance = 0
        /// Its index among the lines dragged, which it keeps through copies
        var mdragIndex = -1

        init() {}

        func copy() -> MDragLine {
            let l = MDragLine()
            l.leaderItem = leaderItem
            l.originalLeaders = originalLeaders
            (l.isStrict, l.isMidSeg, l.isCorner, l.isDraggable) = (isStrict, isMidSeg, isCorner, isDraggable)
            (l.leaderSegIndex, l.cornerIsLast) = (leaderSegIndex, cornerIsLast)
            l.originalLine = originalLine.copy()
            l.preDragLine = preDragLine.copy()
            l.draggedLine = draggedLine.copy()
            l.preShoveLine = preShoveLine.copy()
            (l.dragOK, l.isPrimaryLine, l.clipDone, l.offset, l.midSeg) = (dragOK, isPrimaryLine, clipDone, offset, midSeg)
            (l.dragDist, l.cornerDistance, l.leaderSegDistance, l.mdragIndex) = (dragDist, cornerDistance, leaderSegDistance, mdragIndex)
            return l
        }
    }

    private var world: Node
    /// Whether the last move worked (KiCad's m_dragStatus)
    public private(set) var dragStatus = false
    private var dragMode: DragMode = .corner
    private var mdragLines: [MDragLine] = []
    /// The segments and arcs dragged as the drag leaves them, which the router tool selects once it is kept (KiCad's
    /// m_leaderSegments)
    public private(set) var leaderSegments: [Item] = []
    private var lastNode: Node?
    private var preShoveNode: Node?
    private var origDraggedItems: [Item] = []
    /// What the last move dragged (KiCad's m_draggedItems: the other lines than the primary, dragging their ends)
    public private(set) var traces: [Item] = []
    /// Where the drag started (KiCad's m_dragStartPoint)
    public private(set) var dragStartPoint = IPoint.zero
    private var guide = Seg(.zero, .zero)
    private var shove: Shove?

    init(router: Router, world: Node) {
        self.router = router
        self.world = world
    }

    /// KiCad's SetWorld
    func setWorld(_ node: Node) { world = node }

    /// The segment of `items` with an end at `v` (KiCad's ITEM_SET::FindVertex: segments only)
    private static func findVertex(_ items: [Item], _ v: IPoint) -> Item? {
        items.first { ($0 as? Segment).map { $0.seg.a == v || $0.seg.b == v } ?? false }
    }

    /// Starts dragging the lines of `primitives` (segments and arcs) from `p` (KiCad's Start): each line once, the
    /// one the pointer is on (or nearest, a corner or a segment) the primary; their ends dragged, where the pointer is
    /// at one and every line's end is free, else their segments. Whether it could.
    func start(_ p: IPoint, _ primitives: [Item]) -> Bool {
        lastNode = nil
        dragStatus = false
        dragStartPoint = p
        if primitives.isEmpty { return false }
        mdragLines.removeAll()
        // (the lines to drag; segments of a line already among them its leaders too)
        for pitem in primitives {
            // (KiCad takes each for a segment or arc; a via, which it reads as one, is undefined there)
            guard let litem = pitem as? LinkedItem else { continue }
            var redundant = false
            for l in mdragLines where l.originalLine.containsLink(litem) {
                l.originalLeaders.append(litem)
                redundant = true
                break
            }
            if !redundant {
                let l = MDragLine()
                l.originalLine = world.assembleLine(litem)
                l.originalLeaders.append(litem)
                l.isDraggable = true
                l.mdragIndex = mdragLines.count
                mdragLines.append(l)
            }
        }
        var anyStrictCornersFound = false
        var anyStrictMidSegsFound = false
        func contains(_ item: Item) -> Bool { primitives.contains { $0 === item } }
        for l in mdragLines {
            let thr = l.originalLine.width / 2
            let origFirst = l.originalLine.cLine.point(0)
            let distFirst = (origFirst - p).norm
            let origLast = l.originalLine.cLine.lastPoint
            let distLast = (origLast - p).norm
            l.cornerDistance = min(distFirst, distLast)
            var takeFirst = false
            let ilast = Self.findVertex(primitives, origLast)
            let ifirst = Self.findVertex(primitives, origFirst)
            if ilast != nil && ifirst != nil {
                takeFirst = distFirst < distLast
            } else if ilast != nil {
                takeFirst = false
            } else if ifirst != nil {
                takeFirst = true
            }
            if ifirst != nil || ilast != nil {
                if takeFirst {
                    l.cornerIsLast = false
                    l.leaderSegIndex = 0
                    l.cornerDistance = distFirst
                    l.isCorner = true
                    if distFirst <= thr {
                        l.isStrict = true
                        l.cornerDistance = 0
                    }
                } else {
                    l.cornerIsLast = true
                    l.leaderSegIndex = l.originalLine.segmentCount - 1
                    l.cornerDistance = distLast
                    l.isCorner = true
                    if distLast <= thr {
                        l.isStrict = true
                        l.cornerDistance = 0
                    }
                }
            }
            // (the line's segments dragged: the last of them, by its index among the line's links)
            for (lidx, link) in l.originalLine.links.enumerated() {
                guard let lseg = link as? Segment, contains(lseg) else { continue }
                let d = lseg.seg.distance(p)
                l.midSeg = lseg.seg
                l.isMidSeg = true
                l.leaderSegIndex = lidx
                l.leaderSegDistance = d + thr
                if d < thr && !l.isStrict {
                    l.isCorner = false
                    l.isStrict = true
                    l.leaderSegDistance = 0
                }
            }
            if l.isStrict {
                anyStrictCornersFound = anyStrictCornersFound || l.isCorner
                anyStrictMidSegsFound = anyStrictMidSegsFound || !l.isCorner
            }
        }
        if anyStrictCornersFound {
            dragMode = .corner
        } else if anyStrictMidSegsFound {
            dragMode = .segment
        } else {
            var minLeadSegDist = Int.max
            var minCornerDist = Int.max
            var bestSeg: MDragLine?
            var bestCorner: MDragLine?
            for l in mdragLines {
                if l.cornerDistance < minCornerDist {
                    minCornerDist = l.cornerDistance
                    bestCorner = l
                }
                if l.leaderSegDistance < minLeadSegDist {
                    minLeadSegDist = l.leaderSegDistance
                    bestSeg = l
                }
            }
            if let bestCorner, let bestSeg {
                if minCornerDist < minLeadSegDist {
                    dragMode = .corner
                    bestCorner.isPrimaryLine = true
                } else {
                    dragMode = .segment
                    bestSeg.isPrimaryLine = true
                }
            } else if let bestCorner {
                dragMode = .corner
                bestCorner.isPrimaryLine = true
            } else if let bestSeg {
                dragMode = .segment
                bestSeg.isPrimaryLine = true
            } else {
                return false
            }
        }
        if dragMode == .corner {
            for l in mdragLines {
                // (the corner to drag the line's last)
                if !l.cornerIsLast {
                    l.originalLine.reverse()
                    l.cornerIsLast = true
                }
                // (and a line whose end is joined to more than its segment dragged by its segments instead)
                guard let jt = world.findJoint(l.originalLine.cLastPoint, l.originalLine) else {
                    dragMode = .segment
                    break
                }
                if !jt.isTrivialEndpoint { dragMode = .segment }
            }
        }
        for l in mdragLines where (anyStrictCornersFound || anyStrictMidSegsFound) && l.isStrict {
            l.isPrimaryLine = true
            break
        }
        origDraggedItems = primitives
        if settings.mode == .shove {
            let node = world.branch()
            preShoveNode = node
            for l in mdragLines { node.remove(l.originalLine) }
            let shove = Shove(node, router)
            shove.setDefaultShovePolicy([.shove, .dontLockEndpoints])
            self.shove = shove
        }
        return true
    }

    /// The nets of the lines dragged, each once, in their order (KiCad's CurrentNets: a set of their handles)
    public var currentNets: [NetHandle?] {
        Array(Set(mdragLines.compactMap { $0.draggedLine.net })).sorted().map { $0 }
    }

    /// The layer of what is dragged (KiCad's CurrentLayer, which asks "should we care?": 0)
    public var currentLayer: Int { 0 }

    /// KiCad's GetForceMarkObstaclesMode: never
    public var forceMarkObstaclesMode: Bool { false }

    /// The drag kept (KiCad's FixRoute): if the last move worked, or violations are allowed (`forceCommit` aside).
    /// Whether it was.
    func fixRoute(forceCommit: Bool) -> Bool {
        let node = currentNode
        if !dragStatus && !settings.allowDRCViolations { return false }
        router.commitRouting(node)
        return true
    }

    /// `orig` walked round what is in its way in `node`, the shorter way, into `walk` (KiCad's tryWalkaround, its
    /// length limited to 3 times the line's); whether it got round
    private func tryWalkaround(_ node: Node, _ orig: Line, _ walk: Line) -> Bool {
        let walkaround = Walkaround(world: node, router: router)
        walkaround.setSolidsOnly(false)
        walkaround.iterationLimit = settings.walkaroundIterationLimit
        walkaround.setLengthLimit(true, 3.0)
        walkaround.setAllowedPolicies([.shortest])
        walk.assign(orig)
        let wr = walkaround.route(walk)
        if wr.status[Walkaround.Policy.shortest.rawValue] == .done {
            walk.assign(wr.lines[Walkaround.Policy.shortest.rawValue])
            return true
        }
        return false
    }

    /// The segment of the dragged line that is the leader now (KiCad's findNewLeaderSegment): the first that the
    /// guide through the pointer crosses, running the leader's way or the opposite; -1 if none
    private func findNewLeaderSegment(_ l: MDragLine) -> Int {
        let origLeader = l.preDragLine.cSegment(l.leaderSegIndex)
        let origLeaderDir = Direction45(origLeader)
        for i in 0..<l.draggedLine.segmentCount {
            let curSeg = l.draggedLine.cSegment(i)
            let curDir = Direction45(curSeg)
            if let ip = curSeg.intersectLines(guide), curSeg.contains(ip), curDir == origLeaderDir || curDir == origLeaderDir.opposite {
                return i
            }
        }
        return -1
    }

    /// The segments and arcs dragged, as the drag leaves them (KiCad's restoreLeaderSegments)
    private func restoreLeaderSegments(_ completed: [MDragLine]) {
        leaderSegments.removeAll()
        for l in completed where l.dragOK {
            if dragMode == .corner {
                if l.draggedLine.linkCount > 0 { leaderSegments.append(l.draggedLine.getLink(-1)) }
            } else {
                let newLeaderIdx = findNewLeaderSegment(l)
                if newLeaderIdx >= 0 && newLeaderIdx < l.draggedLine.linkCount { leaderSegments.append(l.draggedLine.getLink(newLeaderIdx)) }
            }
        }
    }

    /// The lines in the order of how far they are dragged (KiCad's std::sort of them, as libstdc++ sorts)
    private static func sortByDragDist(_ lines: inout [MDragLine]) {
        Clipper.introSort(&lines) { $0.dragDist < $1.dragDist }
    }

    private func releaseLastNode() {
        if let last = lastNode {
            last.parent?.release(last)
            lastNode = nil
        }
    }

    /// The lines walked round what is in their way, one after the other, nearest first and then nearest last, the
    /// way with less added kept (KiCad's multidragWalkaround); whether any way got round
    private func multidragWalkaround(_ completed: inout [MDragLine]) -> Bool {
        releaseLastNode()
        Self.sortByDragDist(&completed)
        let preWalkNode = world.branch()
        for l in completed { preWalkNode.remove(l.originalLine) }
        struct WalkState {
            var node: Node
            var totalLength = 0
            var postWalkLines: [Line] = []
            var fail = false
        }
        var walkState: [WalkState] = []
        for attempt in 0..<2 {
            var state = WalkState(node: preWalkNode.branch())
            state.postWalkLines = completed.map { _ in Line() }
            for lidx in 0..<completed.count {
                let l = completed[attempt != 0 ? completed.count - 1 - lidx : lidx]
                let walk = l.draggedLine.copy()
                let result = tryWalkaround(state.node, l.draggedLine, walk)
                if result {
                    state.node.add(walk)
                    state.totalLength += walk.cLine.length - l.draggedLine.cLine.length
                    // (by its place in the walk, not the line's: the second walk's lines go to the lines the other
                    // way round, as KiCad has it)
                    state.postWalkLines[lidx] = walk.copy()
                } else {
                    state.fail = true
                    break
                }
            }
            walkState.append(state)
        }
        var bestAttempt: Int?
        if !walkState[0].fail && !walkState[1].fail {
            bestAttempt = walkState[0].totalLength < walkState[1].totalLength ? 0 : 1
        } else if !walkState[0].fail {
            bestAttempt = 0
        } else if !walkState[1].fail {
            bestAttempt = 1
        }
        guard let best = bestAttempt else {
            preWalkNode.release(walkState[0].node)
            preWalkNode.release(walkState[1].node)
            return false
        }
        for lidx in 0..<completed.count { completed[lidx].draggedLine = walkState[best].postWalkLines[lidx].copy() }
        lastNode = walkState[best].node
        preWalkNode.release(walkState[1 - best].node)
        restoreLeaderSegments(completed)
        return true
    }

    /// `clipped` cut short where it would collide with `ref`, as far along as it can go clear of it, halving the
    /// step (KiCad's clipToOtherLine); whether it was cut. (Where the loop never runs, the line is left with no
    /// points, which the caller then leaves alone.)
    private static func clipToOtherLine(_ node: Node, _ ref: Line, _ clipped: Line) -> Bool {
        let ctx = CollisionSearchContext(options: CollisionSearchOptions())
        let clipLengthThreshold = 100
        let l = clipped.copy()
        var tightest = LineChain()
        var didClip = false
        var curL = l.cLine.length
        var step = curL / 2 - 1
        while step > clipLengthThreshold {
            var slTmp = clipped.cLine
            let pclip = slTmp.pointAlong(curL)
            let idx = slTmp.split(pclip)
            slTmp = slTmp.slice(0, idx)
            l.setShape(slTmp)
            if l.collide(ref, node, layer: l.layer, context: ctx) {
                didClip = true
                curL -= step
                step /= 2
            } else {
                tightest = slTmp
                if didClip {
                    curL += step
                    step /= 2
                } else {
                    break
                }
            }
        }
        clipped.setShape(tightest)
        return didClip
    }

    /// The lines kept as dragged, whatever is in their way, each cut short of the lines before it
    /// (KiCad's multidragMarkObstacles); always true
    private func multidragMarkObstacles(_ completed: inout [MDragLine]) -> Bool {
        releaseLastNode()
        let node = world.branch()
        lastNode = node
        for l1 in 0..<completed.count {
            for l2 in (l1 + 1)..<max(l1 + 1, completed.count) {
                let l1l = completed[l1].draggedLine
                let l2l = completed[l2].draggedLine.copy()
                if Self.clipToOtherLine(node, l1l, l2l) { completed[l2].draggedLine = l2l }
            }
        }
        for l in completed {
            node.remove(l.originalLine)
            node.add(l.draggedLine)
        }
        restoreLeaderSegments(completed)
        return true
    }

    /// The lines as one shove's heads, nearest first, shoving what is in their way (KiCad's multidragShove); the lines
    /// not dragged put back; whether the shove got them through
    private func multidragShove(_ completed: inout [MDragLine]) -> Bool {
        releaseLastNode()
        guard let shove else { return false }
        Self.sortByDragDist(&completed)
        for l in mdragLines {
            Router.dbg("net \(router.iface?.netName(l.draggedLine.net) ?? ""): isCorner \(l.isCorner ? 1 : 0) isStrict \(l.isStrict ? 1 : 0) c-Dist \(l.cornerDistance) l-dist \(l.leaderSegDistance) leadIndex \(l.leaderSegIndex) CisLast \(l.cornerIsLast ? 1 : 0) dragDist \(l.dragDist)")
        }
        shove.setDefaultShovePolicy(.shove)
        shove.clearHeads()
        for l in completed { shove.addHeads(l.draggedLine, [.shove, .dontOptimize]) }
        let status = shove.run()
        let node = shove.currentNode.branch()
        lastNode = node
        // (the lines taken out of the shove's world that did not get dragged put back, as they were)
        let completedIndices = Set(completed.map(\.mdragIndex))
        for ml in mdragLines where !completedIndices.contains(ml.mdragIndex) {
            let preserved = ml.originalLine.copy()
            preserved.clearLinks()
            node.add(preserved)
        }
        guard status == .ok else { return false }
        for (i, l) in completed.enumerated() {
            if shove.headsModified(i) { l.draggedLine = shove.modifiedHead(i) }
            l.draggedLine.clearLinks()
            node.add(l.draggedLine)
        }
        restoreLeaderSegments(completed)
        return true
    }

    /// Drags the lines to `p` (KiCad's Drag): the primary's end or segment to the pointer, each other line's as far
    /// off it as it was, in the first of three postures where every line runs the primary's way (as it is; its
    /// last point taken off; the primary's last segment's way as it was), then walked round, shoved or marked as the
    /// router's mode says. Whether it worked.
    @discardableResult
    func drag(_ p: IPoint) -> Bool {
        var primaryPreDrag: Line?
        var primaryDragged: Line?
        var lastPreDrag = Seg(.zero, .zero)
        var primaryDir = Direction45()
        var perp = IPoint.zero
        var primaryLastSegDir = Direction45()
        var completed: [MDragLine] = []

        func tryPosture(_ variant: Int) -> Bool {
            var primaryLine: MDragLine?
            for l in mdragLines {
                l.dragOK = false
                l.preDragLine.assign(l.originalLine)
                if l.isPrimaryLine {
                    // (a copy of the primary line before the drag and one to drag; the one before keeps its links,
                    // for NODE::Remove to find its segments by)
                    if let d = primaryDragged { d.assign(l.originalLine) } else { primaryDragged = l.originalLine.copy() }
                    primaryDragged!.clearLinks()
                    if let pre = primaryPreDrag { pre.assign(l.originalLine) } else { primaryPreDrag = l.originalLine.copy() }
                    primaryLine = l
                }
            }
            guard let primaryPreDrag, let primaryDragged, let primaryLine else { return false }
            if variant == 1 && primaryPreDrag.pointCount > 2 {
                func removeLast(_ line: Line) {
                    var c = line.cLine
                    c.remove(-1)
                    line.setLine(c)
                }
                removeLast(primaryPreDrag)
                removeLast(primaryDragged)
                for l in mdragLines { removeLast(l.preDragLine) }
            }
            completed.removeAll()
            let snapThreshold = settings.smoothDraggedSegments ? primaryDragged.width / 4 : 0
            if dragMode == .corner {
                // (the primary line's end dragged first)
                lastPreDrag = primaryPreDrag.cSegment(-1)
                primaryDir = Direction45(lastPreDrag)
                primaryDragged.snapThreshold = snapThreshold
                primaryDragged.dragCorner(p, primaryDragged.pointCount - 1, freeAngle: false)
                guard primaryDragged.segmentCount > 0 else { return false }
                var lastPrimDrag = primaryDragged.cSegment(-1)
                if variant == 2 { lastPrimDrag = lastPreDrag }
                let lastSeg = primaryDragged.cSegment(-1)
                if Direction45(lastSeg) != primaryDir && lastSeg.length < primaryDragged.width { lastPrimDrag = lastPreDrag }
                perp = (lastPrimDrag.b - lastPrimDrag.a).perpendicular
                primaryLastSegDir = Direction45(lastPrimDrag)
            } else {
                lastPreDrag = primaryDragged.cSegment(primaryLine.leaderSegIndex)
                primaryDragged.snapThreshold = snapThreshold
                primaryDragged.dragSegment(p, primaryLine.leaderSegIndex)
                perp = (primaryLine.midSeg.b - primaryLine.midSeg.a).perpendicular
                guide = Seg(p, p + perp)
            }
            leaderSegments = origDraggedItems
            traces.removeAll()
            // (the other lines dragged by the primary)
            for l in mdragLines {
                if l.isDraggable {
                    l.dragOK = false
                    if l.preDragLine.segmentCount >= 1 {
                        // (a line dragged only where its last segment runs the primary's way, or near it)
                        if dragMode == .corner {
                            let parallelDir = Direction45(l.preDragLine.cSegment(-1))
                            let leadAngle = primaryDir.angle(parallelDir)
                            if leadAngle == .obtuse || leadAngle == .right || leadAngle == .straight {
                                // (as far off the primary's last segment as its end was, on the line across it)
                                let dist = lastPreDrag.lineDistance(l.preDragLine.cLastPoint, determineSide: true)
                                let projected = p + perp.resized(dist)
                                let parallelDragged = l.preDragLine.copy()
                                parallelDragged.clearLinks()
                                parallelDragged.dragCorner(projected, parallelDragged.pointCount - 1, freeAngle: false,
                                                           preferredEnding: primaryLastSegDir)
                                // (a short line dragged to a point is left out)
                                if parallelDragged.segmentCount < 1 { continue }
                                l.dragOK = true
                                if !l.isPrimaryLine {
                                    l.draggedLine = parallelDragged
                                    completed.append(l.copy())
                                    traces.append(parallelDragged.copy())
                                }
                            }
                        } else if dragMode == .segment {
                            let sdrag = l.midSeg
                            let refDir = Direction45(lastPreDrag)
                            let curDir = Direction45(sdrag)
                            let ang = refDir.angle(curDir)
                            if !ang.intersection([.halfFull, .straight]).isEmpty {
                                let dist = lastPreDrag.lineDistance(l.preDragLine.cPoint(l.leaderSegIndex), determineSide: true)
                                let projected = p + perp.resized(dist)
                                let sperp = Seg(p, p + perp.resized(10_000_000))
                                let startProj = sperp.lineProject(dragStartPoint)
                                let v = projected - startProj
                                let dot = v.dot(perp)
                                l.dragDist = v.norm * (dot > 0 ? 1 : dot < 0 ? -1 : 0)
                                l.dragOK = true
                                if !l.isPrimaryLine {
                                    l.draggedLine = l.preDragLine.copy()
                                    l.draggedLine.clearLinks()
                                    l.draggedLine.snapThreshold = snapThreshold
                                    l.draggedLine.dragSegment(projected, l.leaderSegIndex)
                                    completed.append(l.copy())
                                }
                            }
                        }
                    }
                }
                if l.isPrimaryLine {
                    l.draggedLine = primaryDragged.copy()
                    l.dragOK = true
                    completed.append(l.copy())
                }
            }
            if dragMode == .segment { return true }
            for l in completed {
                if !l.dragOK && variant < 2 { return false }
                if l.isPrimaryLine { continue }
                // (a line with no last segment to run the primary's way: this posture refused)
                if l.draggedLine.segmentCount < 1 { return false }
                if Direction45(l.draggedLine.cSegment(-1)) != primaryLastSegDir { return false }
            }
            return true
        }

        for variant in 0..<3 where tryPosture(variant) { break }
        switch settings.mode {
        case .walkaround: dragStatus = multidragWalkaround(&completed)
        case .shove: dragStatus = multidragShove(&completed)
        case .markObstacles: dragStatus = multidragMarkObstacles(&completed)
        }
        return dragStatus
    }

    /// The world as the drag leaves it (KiCad's CurrentNode)
    public var currentNode: Node { lastNode ?? world }
}
