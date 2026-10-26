// Ported from KiCad 10.0.7: pcbnew/router/pns_drag_algo.h, pns_dragger.h and pns_dragger.cpp (segments, corners,
// arcs and vias dragged; not footprints or several segments at once, KiCad's COMPONENT_DRAGGER and MULTI_DRAGGER).
// Copyright (C) 2013-2014 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// What a drag moves (KiCad's DRAG_MODE): a corner, a segment, a via; any of them, as what is under the pointer
/// says; at free angles rather than on the 45° directions
public struct DragMode: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let corner = DragMode(rawValue: 0x1)
    public static let segment = DragMode(rawValue: 0x2)
    public static let via = DragMode(rawValue: 0x4)
    public static let freeAngle = DragMode(rawValue: 0x8)
    public static let arc = DragMode(rawValue: 0x10)
    public static let any = DragMode(rawValue: 0x17)
    public static let component = DragMode(rawValue: 0x20)
}

/// A track's segment, its corner, an arc or a via dragged by the pointer (KiCad's PNS::DRAGGER): the line the segment
/// or arc is part of reshaped round the dragged segment, corner or arc, the tracks on a via with it; what is in the way walked round,
/// shoved aside or marked, as the router's mode says. Each move is made in a branch of the world from before the drag,
/// and a move that fails keeps the last that did not. A drag whose first move fails marks obstacles from then on.
public final class Dragger {
    unowned let router: Router
    var settings: RoutingSettings { router.settings }

    private var world: Node
    private var initialVia: Via.Handle?
    private var draggedVia: Via.Handle?
    private var lastNode: Node?
    private var preDragNode: Node!
    private var mode: DragMode = .segment
    /// The line dragged, as it was (KiCad's m_draggedLine)
    public private(set) var originalLine = Line()
    /// The line as the last move that worked left it (shoving)
    public private(set) var lastDragSolution = Line()
    private var shove: Shove?
    private var draggedSegmentIndex = 0
    /// Whether the last move worked (or, marking obstacles, collides with nothing)
    public private(set) var dragStatus = false
    private var currentMode: RouterMode = .markObstacles
    private var lastValidPoint = IPoint.zero
    /// What the last move dragged (KiCad's m_draggedItems)
    public private(set) var traces: [Item] = []
    private var freeAngleMode = false
    /// Whether the drag marks obstacles, its first move having failed
    public private(set) var forceMarkObstaclesMode = false
    private let mouseTrailTracer = MouseTrailTracer()

    init(router: Router, world: Node) {
        self.router = router
        self.world = world
    }

    /// KiCad's SetWorld
    func setWorld(_ node: Node) { world = node }

    /// KiCad's SetMode: what to drag, and at what angles
    func setMode(_ m: DragMode) { mode = m }

    /// The length of `v` as KiCad's VECTOR2D measures it (EuclideanNorm on doubles): the dragger takes the pointer as
    /// a VECTOR2D where it asks how near a track's ends it is
    private static func norm(_ v: IPoint) -> Double {
        let x = Double(v.x), y = Double(v.y)
        if abs(x) == abs(y) { return abs(x) * 2.0.squareRoot() }
        if x == 0 { return abs(y) }
        if y == 0 { return abs(x) }
        return hypot(x, y)
    }

    private func releaseLastNode() {
        if let last = lastNode {
            last.parent?.release(last)
            lastNode = nil
        }
    }

    // MARK: - Starting

    /// The via pushed clear of what it collides with, back along the way the pointer came if it gets nowhere
    /// (KiCad's propagateViaForces)
    private func propagateViaForces(_ node: Node, _ via: Via) -> Bool {
        let lead = -mouseTrailTracer.trailLeadVector
        let iterLimit = settings.viaForcePropIterationLimit
        if let force = via.pushoutForce(node, direction: lead, kinds: .any, maxIterations: iterLimit) {
            via.setPos(via.pos + force)
            return true
        }
        return false
    }

    /// The virtual via at the end of `seg` the pointer at `p` is on, if there is one (KiCad's checkVirtualVia): where a
    /// track's width changes, three tracks meet or a locked one ends, a drag there drags the joint as a via
    private func checkVirtualVia(_ p: IPoint, _ seg: Segment) -> Via? {
        let w2 = Double(seg.width / 2)
        let distA = Dragger.norm(p - seg.seg.a), distB = Dragger.norm(p - seg.seg.b)
        let psnap: IPoint
        if distA <= w2 {
            psnap = seg.seg.a
        } else if distB <= w2 {
            psnap = seg.seg.b
        } else {
            return nil
        }
        guard let jt = world.findJoint(psnap, seg) else { return nil }
        for item in jt.links where item.isVirtual && item.ofKind(.via) { return item as? Via }
        return nil
    }

    /// A segment's line to drag (KiCad's startDragSegment): its corner if the pointer is within half the track's width
    /// of one of its ends (or always, at free angles: the nearer end's), else the segment
    private func startDragSegment(_ p: IPoint, _ seg: Segment) -> Bool {
        let w2 = Double(seg.width / 2)
        var index = 0
        originalLine = world.assembleLine(seg, originSegmentIndex: &index)
        draggedSegmentIndex = index
        lastDragSolution = originalLine.copy()
        let distA = Dragger.norm(p - seg.seg.a), distB = Dragger.norm(p - seg.seg.b)
        if distA < w2 || distB < w2 {
            mode = .corner
            if distB <= distA { draggedSegmentIndex += 1 }
        } else if freeAngleMode {
            // (not onto an arc's point)
            if distB < distA && draggedSegmentIndex < originalLine.pointCount - 2
                && !originalLine.cLine.isPointOnArc(draggedSegmentIndex + 1) {
                draggedSegmentIndex += 1
            }
            mode = .corner
        } else {
            mode = .segment
        }
        return true
    }

    /// An arc's line to drag (KiCad's startDragArc), unless the arc turns too far (179° or more) to keep tangent: a
    /// line with the arc at an end gets a stub of track there (in the branch the drag starts from), going on from the
    /// arc's tangent, for the arc to stay tangent to. (KiCad keeps no last solution for an arc's drag.)
    private func startDragArc(_ p: IPoint, _ arc: Arc) -> Bool {
        let maxDeviation = EDAAngle(degrees: Line.maxTangentAngleDeviation)
        let centralAngle = EDAAngle(degrees: abs(arc.arc.centralAngle.degrees))
        if centralAngle + maxDeviation >= .a180 {
            let limit = EDAAngle.a180 - maxDeviation
            router.failureReason = "Unable to drag arc tracks of \(String(format: "%.1f", limit.degrees)) degrees or greater."
            return false
        }
        var probeIdx = 0
        let probe = world.assembleLine(arc, originSegmentIndex: &probeIdx)
        var arcIdx = -1, firstArcPt = -1, lastArcPt = -1
        for i in 0..<probe.pointCount {
            let a = probe.cLine.arcIndex(i)
            if a < 0 { continue }
            if arcIdx < 0 { arcIdx = a }
            if a == arcIdx {
                if firstArcPt < 0 { firstArcPt = i }
                lastArcPt = i
            }
        }
        let isolatedStart = firstArcPt == 0
        let isolatedEnd = lastArcPt == probe.pointCount - 1
        var index = 0
        if isolatedStart || isolatedEnd {
            let maxStubIU = Line.maxTrackLengthToKeep
            let stubLen = max(1, maxStubIU / 2)
            let sharc = arc.arc
            let center = sharc.center, mid = sharc.mid
            func outwardTangent(_ endpoint: IPoint) -> IPoint {
                let radial = endpoint - center
                var perp = IPoint(-radial.y, radial.x)
                let toMid = mid - endpoint
                // (KiCad takes the dot product in ints, which overflow for any arc of more than some 46 µm radius:
                // its result is what KiCad's builds make of it, the products and their sum wrapped round in 32 bits,
                // so the stub can go back along the arc)
                let dot = Int32(truncatingIfNeeded: perp.x) &* Int32(truncatingIfNeeded: toMid.x)
                    &+ Int32(truncatingIfNeeded: perp.y) &* Int32(truncatingIfNeeded: toMid.y)
                if dot > 0 { perp = IPoint(radial.y, -radial.x) }
                let mag = hypot(Double(perp.x), Double(perp.y))
                if mag <= 0 { return IPoint(stubLen, 0) }
                return IPoint(KiMath.round(Double(perp.x) * Double(stubLen) / mag), KiMath.round(Double(perp.y) * Double(stubLen) / mag))
            }
            if isolatedStart {
                let p0 = sharc.start
                let stub = Segment(Seg(p0 + outwardTangent(p0), p0), net: arc.net)
                stub.width = arc.width
                stub.layers = arc.layers
                preDragNode.add(stub)
            }
            if isolatedEnd {
                let p1 = sharc.end
                let stub = Segment(Seg(p1, p1 + outwardTangent(p1)), net: arc.net)
                stub.width = arc.width
                stub.layers = arc.layers
                preDragNode.add(stub)
            }
            originalLine = preDragNode.assembleLine(arc, originSegmentIndex: &index)
        } else {
            originalLine = world.assembleLine(arc, originSegmentIndex: &index)
        }
        draggedSegmentIndex = index
        mode = .arc
        return true
    }

    private func startDragVia(_ via: Via) -> Bool {
        initialVia = via.handle
        draggedVia = initialVia
        mode = .via
        return true
    }

    /// The lines on the via `handle` names in `node`, each turned to end on it, and the via (KiCad's
    /// findViaFanoutByHandle)
    private func findViaFanoutByHandle(_ node: Node, _ handle: Via.Handle) -> [Item] {
        var rv: [Item] = []
        guard let jt = node.findJoint(handle.pos, layer: handle.layers.start, net: handle.net) else { return rv }
        var foundVia = false
        for item in jt.links {
            if item.ofKind([.segment, .arc]) {
                var segIndex = 0
                let l = node.assembleLine(item as! LinkedItem, originSegmentIndex: &segIndex)
                if segIndex != 0 { l.reverse() }
                rv.append(l)
            } else if item.ofKind(.via) {
                if !foundVia {
                    rv.append(item)
                    foundVia = true
                }
            }
        }
        return rv
    }

    /// Starts dragging the first of `primitives` from `p` (KiCad's Start): a segment (or the virtual via at its end)
    /// or a via; whether it could
    func start(_ p: IPoint, _ primitives: [Item]) -> Bool {
        guard let startItem = primitives.first else { return false }
        lastNode = nil
        traces.removeAll()
        currentMode = settings.mode
        freeAngleMode = mode.contains(.freeAngle)
        forceMarkObstaclesMode = false
        lastValidPoint = p
        mouseTrailTracer.clear()
        mouseTrailTracer.addTrailPoint(p)
        preDragNode = world.branch()
        if currentMode == .shove && !freeAngleMode {
            let shove = Shove(preDragNode, router)
            shove.setDefaultShovePolicy(.shove)
            self.shove = shove
        }
        startItem.unmark(.locked)
        Router.dbg("StartDragging: item [kind \(startItem.kind.rawValue)]")
        switch startItem {
        case let seg as Segment:
            if let vvia = checkVirtualVia(p, seg) { return startDragVia(vvia) }
            return startDragSegment(p, seg)
        case let via as Via:
            return startDragVia(via)
        case let arc as Arc:
            return startDragArc(p, arc)
        default:
            return false
        }
    }

    /// The net of what is dragged (KiCad's CurrentNets)
    public var currentNets: [NetHandle?] { mode == .via ? [draggedVia?.net] : [originalLine.net] }

    /// The layer of what is dragged (KiCad's CurrentLayer: the line's; none for a via)
    public var currentLayer: Int { originalLine.layer }

    // MARK: - Marking obstacles

    /// The line or via dragged to `p` whatever is in the way, which is marked (KiCad's dragMarkObstacles)
    private func dragMarkObstacles(_ p: IPoint) -> Bool {
        releaseLastNode()
        let lastNode = preDragNode.branch()
        self.lastNode = lastNode
        switch mode {
        case .segment, .corner:
            let thresh = settings.smoothDraggedSegments ? originalLine.width / 4 : 0
            let origLine = originalLine.copy()
            let dragged = originalLine.copy()
            dragged.snapThreshold = thresh
            dragged.clearLinks()
            if mode == .segment {
                dragged.dragSegment(p, draggedSegmentIndex)
            } else {
                dragged.dragCorner(p, draggedSegmentIndex, freeAngle: freeAngleMode)
            }
            lastNode.remove(origLine)
            lastNode.add(dragged)
            traces = [dragged.copy()]
        case .arc:
            let origLine = originalLine.copy()
            let dragged = originalLine.copy()
            dragged.clearLinks()
            dragged.dragArc(p, draggedSegmentIndex)
            // (an arc that collapses leaves no line: it is dropped from the route, as KiCad means it to be)
            lastNode.remove(origLine)
            lastNode.add(dragged)
            traces = [dragged.copy()]
        case .via:
            _ = dragViaMarkObstacles(initialVia!, lastNode, p)
        default:
            break
        }
        if settings.allowDRCViolations {
            dragStatus = true
        } else {
            dragStatus = lastNode.checkColliding(traces) == nil
        }
        return true
    }

    /// The via moved to `p` and the tracks on it dragged along (KiCad's dragViaMarkObstacles)
    private func dragViaMarkObstacles(_ handle: Via.Handle, _ node: Node, _ p: IPoint) -> Bool {
        traces.removeAll()
        let fanout = findViaFanoutByHandle(node, handle)
        if fanout.isEmpty { return true }
        for item in fanout {
            if let l = item as? Line {
                let origLine = l.copy()
                let draggedLine = l.copy()
                draggedLine.dragCorner(p, origLine.cLine.find(handle.pos), freeAngle: freeAngleMode)
                draggedLine.clearLinks()
                traces.append(draggedLine.copy())
                lastNode!.remove(origLine)
                lastNode!.add(draggedLine)
            } else if let via = item as? Via {
                let nvia = via.clone() as! Via
                nvia.setPos(p)
                traces.append(nvia)
                lastNode!.remove(via)
                lastNode!.add(nvia)
            }
        }
        return true
    }

    // MARK: - Walking round

    /// The via dragged to `p`, pushed clear of what is there, and the tracks on it dragged after it, each walked round
    /// what it then collides with (KiCad's dragViaWalkaround); whether it worked
    private func dragViaWalkaround(_ handle: Via.Handle, _ node: Node, _ p: IPoint) -> Bool {
        traces.removeAll()
        let fanout = findViaFanoutByHandle(node, handle)
        if fanout.isEmpty { return true }
        var viaPropOk = false
        var viaTargetPos = IPoint.zero
        for case let via as Via in fanout {
            let draggedVia = via.clone() as! Via
            draggedVia.setPos(p)
            traces.append(draggedVia)
            lastNode!.remove(via)
            let ok = propagateViaForces(lastNode!, draggedVia)
            if ok {
                viaTargetPos = draggedVia.pos
                viaPropOk = true
                lastNode!.add(draggedVia)
            }
        }
        // (the via cannot be pushed clear)
        if !viaPropOk { return false }
        for case let l as Line in fanout {
            let origLine = l.copy()
            let draggedLine = l.copy()
            let walkLine = l.copy()
            draggedLine.dragCorner(viaTargetPos, origLine.cLine.find(handle.pos), freeAngle: freeAngleMode)
            draggedLine.clearLinks()
            if world.checkColliding(draggedLine) != nil {
                let ok = tryWalkaround(lastNode!, draggedLine, walkLine)
                if !ok { return false }
                lastNode!.remove(origLine)
                optimizeAndUpdateDraggedLine(walkLine, origLine, p)
            } else {
                traces.append(draggedLine.copy())
                lastNode!.remove(origLine)
                lastNode!.add(draggedLine)
            }
        }
        return true
    }

    /// The dragged line's corners merged where they can be, round the point dragged (and, unless the whole track is to
    /// be optimized, only within the area the drag changed), and put in the last node (KiCad's
    /// optimizeAndUpdateDraggedLine)
    private func optimizeAndUpdateDraggedLine(_ dragged: Line, _ orig: Line, _ p: IPoint) {
        let draggedPostOpt = Line(), origLine = orig.copy()
        dragged.clearLinks()
        dragged.unmark()
        let optimizer = Optimizer(world: lastNode!)
        var effort = Optimizer.Effort.mergeSegments
        if settings.smoothDraggedSegments { effort.insert(.mergeColinear) }
        optimizer.effortLevel = effort
        var anchor = p
        if dragged.cLine.find(p) < 0 { anchor = dragged.cLine.nearestPoint(p) }
        optimizer.setPreserveVertex(anchor)
        dragged.withLine { _ = $0.split(anchor) }
        Router.dbg("drag-anchor: point (\(anchor.x),\(anchor.y))")
        if !settings.optimizeEntireDraggedTrack {
            // (no area yet: one of no size, which stops the optimizer)
            let affectedArea = dragged.changedArea(orig) ?? IBox(p, p)
            Router.dbg("drag-affected-area: rect (\(affectedArea.minX),\(affectedArea.minY)) "
                       + "(\(affectedArea.maxX),\(affectedArea.maxY))")
            optimizer.setRestrictArea(affectedArea)
        }
        Router.dbg("drag-preopt: line\(Dragger.trace(dragged.cLine))")
        optimizer.optimize(dragged, draggedPostOpt, root: origLine)
        dragged.assign(draggedPostOpt)
        Router.dbg("drag-postopt: line\(Dragger.trace(dragged.cLine))")
        lastNode!.add(draggedPostOpt)
        traces = [draggedPostOpt.copy()]
    }

    /// A chain's points as router.cpp's trace writes them
    private static func trace(_ c: LineChain) -> String { c.points.map { " (\($0.x),\($0.y))" }.joined() }

    /// `orig` walked round what is in its way in `node`, the shorter way, into `walk` (KiCad's tryWalkaround);
    /// whether it got round
    private func tryWalkaround(_ node: Node, _ orig: Line, _ walk: Line) -> Bool {
        let walkaround = Walkaround(world: node, router: router)
        walkaround.setSolidsOnly(false)
        walkaround.iterationLimit = settings.walkaroundIterationLimit
        walkaround.setLengthLimit(true, 30.0)
        walkaround.setAllowedPolicies([.shortest])
        walk.assign(orig)
        let wr = walkaround.route(walk)
        if wr.status[Walkaround.Policy.shortest.rawValue] == .done {
            walk.assign(wr.lines[Walkaround.Policy.shortest.rawValue])
            return true
        }
        return false
    }

    /// The line or via dragged to `p`, walking round what it then collides with (KiCad's dragWalkaround); whether it
    /// got round
    private func dragWalkaround(_ p: IPoint) -> Bool {
        var ok = false
        releaseLastNode()
        lastNode = preDragNode.branch()
        switch mode {
        case .segment, .corner:
            let thresh = settings.smoothDraggedSegments ? originalLine.width / 4 : 0
            let dragged = originalLine.copy()
            let draggedWalk = originalLine.copy()
            let origLine = originalLine.copy()
            dragged.snapThreshold = thresh
            if mode == .segment {
                dragged.dragSegment(p, draggedSegmentIndex)
            } else {
                dragged.dragCorner(p, draggedSegmentIndex)
            }
            if world.checkColliding(dragged) != nil {
                ok = tryWalkaround(lastNode!, dragged, draggedWalk)
            } else {
                draggedWalk.assign(dragged)
                ok = true
            }
            if draggedWalk.cLine.pointCount < 2 { ok = false }
            if ok {
                Router.dbg("drag-orig-line:\(Dragger.trace(origLine.cLine))")
                Router.dbg("drag-walk:\(Dragger.trace(draggedWalk.cLine))")
                lastNode!.remove(origLine)
                optimizeAndUpdateDraggedLine(draggedWalk, origLine, p)
            }
        case .arc:
            let dragged = originalLine.copy()
            let draggedWalk = originalLine.copy()
            let origLine = originalLine.copy()
            dragged.dragArc(p, draggedSegmentIndex)
            if world.checkColliding(dragged) != nil {
                ok = tryWalkaround(lastNode!, dragged, draggedWalk)
            } else {
                draggedWalk.assign(dragged)
                ok = true
            }
            if draggedWalk.cLine.pointCount < 2 { ok = false }
            if ok {
                lastNode!.remove(origLine)
                optimizeAndUpdateDraggedLine(draggedWalk, origLine, p)
            }
        case .via:
            ok = dragViaWalkaround(initialVia!, lastNode!, p)
        default:
            break
        }
        dragStatus = ok
        return ok
    }

    // MARK: - Shoving

    /// The line or via dragged to `p`, shoving what is in its way (KiCad's dragShove): the line a head of the shove,
    /// its ends free to move; the via dragged by the shove, and walked round if the shove cannot clear it. Whether it
    /// worked.
    private func dragShove(_ p: IPoint) -> Bool {
        releaseLastNode()
        let shove = self.shove!
        switch mode {
        case .segment, .corner:
            var ok = false
            let thresh = settings.smoothDraggedSegments ? originalLine.width / 2 : 0
            let draggedPreShove = originalLine.copy()
            draggedPreShove.snapThreshold = thresh
            if mode == .segment {
                draggedPreShove.dragSegment(p, draggedSegmentIndex)
            } else {
                draggedPreShove.dragCorner(p, draggedSegmentIndex)
            }
            shove.currentNode.remove(draggedPreShove)
            var policy: Shove.Policy = [.shove, .dontLockEndpoints]
            Router.dbg("drag seg index \(draggedSegmentIndex)")
            if mode == .corner && draggedSegmentIndex == 0 { policy.insert(.reversed) }
            shove.clearHeads()
            shove.addHeads(draggedPreShove, policy)
            ok = shove.run() == .ok
            let draggedPostShove = draggedPreShove.copy()
            if ok && shove.headsModified() { draggedPostShove.assign(shove.modifiedHead(0)) }
            lastNode = shove.currentNode.branch()
            if ok {
                draggedPostShove.clearLinks()
                draggedPostShove.unmark()
                optimizeAndUpdateDraggedLine(draggedPostShove, originalLine, p)
                lastDragSolution = draggedPostShove
            }
            dragStatus = ok
        case .arc:
            var ok = false
            let draggedPreShove = originalLine.copy()
            draggedPreShove.dragArc(p, draggedSegmentIndex)
            // (an arc that collapses to fewer than two points is no head for the shove: the shove fails)
            if draggedPreShove.cLine.pointCount >= 2 {
                shove.currentNode.remove(draggedPreShove)
                shove.clearHeads()
                shove.addHeads(draggedPreShove, [.shove, .dontLockEndpoints])
                ok = shove.run() == .ok
            }
            let draggedPostShove = draggedPreShove.copy()
            if ok && shove.headsModified() { draggedPostShove.assign(shove.modifiedHead(0)) }
            lastNode = shove.currentNode.branch()
            if ok {
                draggedPostShove.clearLinks()
                draggedPostShove.unmark()
                optimizeAndUpdateDraggedLine(draggedPostShove, originalLine, p)
                lastDragSolution = draggedPostShove
            }
            dragStatus = ok
        case .via:
            // (KiCad: the corner count limiter "produces mediocre results for via shoving", and is disabled)
            shove.disablePostShoveOptimizations(.limitCornerCount)
            shove.clearHeads()
            shove.addHeads(draggedVia!, p, .shove)
            let st = shove.run()
            Router.dbg("head-mod \(shove.headsModified() ? 1 : 0)")
            if shove.headsModified() {
                let newVia = shove.modifiedHeadVia(0)
                Router.dbg("newvia \(newVia.pos.x) \(newVia.pos.y) \(newVia.layers.start) \(newVia.layers.end)")
                draggedVia = newVia
            }
            lastNode = shove.currentNode.branch()
            traces.removeAll()
            // (the via shoved onto something it cannot push: walked round instead)
            if st != .ok {
                dragStatus = dragViaWalkaround(draggedVia!, lastNode!, p)
            } else {
                dragStatus = true
            }
        default:
            break
        }
        return dragStatus
    }

    // MARK: - Dragging

    /// What is dragged taken to `p` (KiCad's Drag), as the router's mode says (marking obstacles at free angles, or
    /// once the first move has failed); whether it worked. A failed move keeps the line as the last that worked left
    /// it.
    @discardableResult
    func drag(_ p: IPoint) -> Bool {
        mouseTrailTracer.addTrailPoint(p)
        let firstDrag = lastNode == nil
        var ret = false
        if freeAngleMode || forceMarkObstaclesMode {
            ret = dragMarkObstacles(p)
        } else {
            switch currentMode {
            case .markObstacles: ret = dragMarkObstacles(p)
            case .shove: ret = dragShove(p)
            case .walkaround: ret = dragWalkaround(p)
            }
        }
        if ret {
            lastValidPoint = p
        } else if firstDrag {
            // (the first move failed: obstacles marked from here on)
            forceMarkObstaclesMode = true
            ret = dragMarkObstacles(p)
            if ret { lastValidPoint = p }
        } else if let last = lastNode {
            // (the last solution back)
            let parent = last.parent!.branch()
            last.parent?.release(last)
            lastNode = parent
            traces.removeAll()
            lastDragSolution.clearLinks()
            parent.add(lastDragSolution)
        }
        return ret
    }

    /// The drag kept, if it may be (KiCad's FixRoute): if the last move worked; marking obstacles, only if forced;
    /// else dragged back to where it last worked, and kept if that works. Whether it was kept.
    func fixRoute(forceCommit: Bool) -> Bool {
        if dragStatus {
            router.commitRouting(currentNode)
            return true
        } else if forceMarkObstaclesMode {
            if forceCommit {
                router.commitRouting(currentNode)
                return true
            }
            return false
        } else {
            // (shoving or walking round, what is in the last place that worked is clear of everything)
            drag(lastValidPoint)
            if dragStatus {
                router.commitRouting(currentNode)
                return true
            }
        }
        return false
    }

    /// The world as the drag leaves it (KiCad's CurrentNode)
    public var currentNode: Node { lastNode ?? world }
}
