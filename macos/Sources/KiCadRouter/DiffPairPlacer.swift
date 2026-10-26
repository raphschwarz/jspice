// Ported from KiCad 10.0.7: pcbnew/router/pns_diff_pair_placer.h and pns_diff_pair_placer.cpp (walkaround, shove
// and mark-obstacles modes; without arcs).
// Copyright (C) 2013-2015 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// Places a differential pair, two coupled tracks, as the pointer moves (KiCad's DIFF_PAIR_PLACER): from the pads,
/// vias or track ends of the pair's nets it starts on, through gateways fitted between them and the pointer, walked
/// round or shoving what is in the way, in a branch of the world. Each part fixed is committed to the world at once,
/// and the pair goes on from its ends (or its vias).
public final class DiffPairPlacer: PlacementAlgo {
    unowned let router: Router
    var settings: RoutingSettings { router.settings }

    private var chainedPlacement = false
    private var initialDiagonal = false
    private var startDiagonal = false
    private var fitOk = false
    private var netP: NetHandle?
    private var netN: NetHandle?
    private var start = DPPrimitivePair()
    private var prevPair: DPPrimitivePair?
    private var world: Node?
    private var shove: Shove?
    private var currentNode: Node?
    private var lastNode: Node?
    private var lastFixNode: Node?
    private var sizes = SizesSettings()
    public private(set) var isPlacingVia = false
    public private(set) var currentLayer = 0
    private var orthoMode = false
    private var snapOnTarget = false
    public private(set) var currentEnd = IPoint.zero
    public private(set) var currentStart = IPoint.zero
    /// The pair being placed
    public private(set) var currentTrace = DiffPair()
    private var currentTraceOk = false
    private var currentEndItem: Item?
    private var idle = true
    private var hasFixedAnything = false

    init(router: Router) { self.router = router }

    /// A via of the router's size and type at `p` (KiCad's makeVia)
    private func makeVia(_ p: IPoint, _ net: NetHandle?) -> Via {
        let iface = router.iface!
        // (KiCad's GetLayerTop and GetLayerBottom, with no layer pair, give the board's F_Cu and B_Cu, 0 and 2, as
        // router layers)
        let first = sizes.layerPairs.keys.min()
        let start = sizes.viaType == .through ? 0 : first ?? 0
        let end = sizes.viaType == .through ? iface.copperLayerCount - 1 : first.flatMap { sizes.layerPairs[$0] } ?? 2
        return Via(pos: p, layers: LayerRange(start, end), diameter: sizes.viaDiameter, drill: sizes.viaDrill, net: net, type: sizes.viaType)
    }

    public func setOrthoMode(_ ortho: Bool) {
        orthoMode = ortho
        if !idle { _ = move(currentEnd, nil) }
    }

    public func toggleVia(_ enabled: Bool) -> Bool {
        isPlacingVia = enabled
        if !idle { _ = move(currentEnd, nil) }
        return true
    }

    /// The pair to the pointer, obstacles in its way marked (KiCad's rhMarkObstacles); whether it is clear of them
    private func rhMarkObstacles(_ p: IPoint) -> Bool {
        if !routeHead(p) { return false }
        let collP = currentNode!.checkColliding(currentTrace.pLine()) != nil
        let collN = currentNode!.checkColliding(currentTrace.nLine()) != nil
        fitOk = !(collP || collN)
        return fitOk
    }

    /// Where the pair's head goes for the pointer at `p` (KiCad's propagateDpHeadForces): pushed clear of what is in
    /// its way (pads only, shoving), as a via as wide as the pair (or its vias) would be pushed; nil if it cannot be
    private func propagateDpHeadForces(_ p: IPoint) -> IPoint? {
        let virtHead = makeVia(p, nil)
        if isPlacingVia {
            virtHead.setDiameter(viaGap + 2 * virtHead.diameter)
        } else {
            virtHead.setLayer(currentLayer)
            virtHead.setDiameter(sizes.diffPairGap + 2 * sizes.diffPairWidth)
        }
        var solidsOnly = true
        if settings.mode == .markObstacles {
            return p
        } else if settings.mode == .walkaround {
            solidsOnly = false
        }
        // fixme: I'm too lazy to do it well. Circular approximaton will do for the moment.

        // Note: this code is lifted from VIA::PushoutForce and then optimized for this use case and to check proper
        // clearances to the diff pair line. It can be removed if some specialized pushout for traces / diff pairs is
        // implemented. Just calling VIA::PushoutForce does not work as the via may have different resolved clearance
        // to items than the diff pair should.
        let maxIter = 40
        var iter = 0
        var collided = false
        // (the largest force met so far, never reset: KiCad's moves the head by it each time, and gives it as the
        // head's place, not the forces' sum)
        var force = IPoint.zero, totalForce = IPoint.zero
        var handled = Set<ObjectIdentifier>()
        while iter < maxIter {
            guard let obs = currentNode!.checkColliding(virtHead, kindMask: solidsOnly ? .solid : .any),
                  !handled.contains(ObjectIdentifier(obs.item)) else { break }
            let clearance = currentNode!.clearance(obs.item, currentTrace.pLine(), useEpsilon: false)
            var layerForce = IPoint.zero
            collided = false
            for viaLayer in virtHead.relevantShapeLayers(obs.item) {
                guard let s = obs.item.shape(viaLayer) else { continue }
                if let f = s.pushout(circle: virtHead.pos, radius: virtHead.diameter / 2, clearance: clearance) {
                    collided = true
                    layerForce = f
                }
                if layerForce.squaredNorm > force.squaredNorm { force = layerForce }
            }
            if collided {
                totalForce = totalForce + force
                virtHead.setPos(virtHead.pos + force)
            }
            handled.insert(ObjectIdentifier(obs.item))
            iter += 1
        }
        let succeeded = !collided || iter != maxIter
        return succeeded ? p + force : nil
    }

    /// The pair walked round what is in its way, one line walked round it and the other shoved after it, then the
    /// other way round, up to three times, into `walk` (KiCad's attemptWalk); whether that cleared it
    private func attemptWalk(_ node: Node, _ current: DiffPair, _ walk: DiffPair, pFirst: Bool, windCw: Bool, solidsOnly: Bool) -> Bool {
        let walkaround = Walkaround(world: node, router: router)
        walkaround.setSolidsOnly(solidsOnly)
        walkaround.iterationLimit = settings.walkaroundIterationLimit
        walkaround.setAllowedPolicies([.shortest])
        let shove = Shove(node, router)
        walk.assign(current)
        var iter = 0
        let cur = current.copy()
        var currentIsP = pFirst
        let mask: ItemKind = solidsOnly ? .solid : .any
        repeat {
            let preWalk = currentIsP ? cur.pLine() : cur.nLine()
            let preShove = currentIsP ? cur.nLine() : cur.pLine()
            if node.checkColliding(preWalk, kindMask: mask) == nil {
                currentIsP = !currentIsP
                if node.checkColliding(preShove, kindMask: mask) == nil { break }
                continue
            }
            let wf1 = walkaround.route(preWalk)
            let shortest = Walkaround.Policy.shortest.rawValue
            if wf1.status[shortest] != .done { return false }
            let postWalk = wf1.lines[shortest]
            let postShove = preShove.copy()
            shove.forceClearance(true, cur.gap - 2 * 10) // PNS_HULL_MARGIN
            if !shove.shoveObstacleLine(postWalk, preShove, postShove) { return false }
            postWalk.withLine { $0.simplify() }
            postShove.withLine { $0.simplify() }
            cur.setShape(postWalk.cLine, postShove.cLine, swapLanes: !currentIsP)
            currentIsP = !currentIsP
            if node.checkColliding(postShove, kindMask: mask) == nil { break }
            iter += 1
        } while iter < 3
        if iter == 3 { return false }
        walk.setShape(cur.cp, cur.cn)
        return true
    }

    /// The pair walked round what is in its way (KiCad's tryWalkDp): each line first, the walk scored by how little
    /// the lines stay coupled and how much their lengths differ, the lowest kept and optimized. (KiCad's starting
    /// score is never beaten by none: with no walk that worked, the pair is left with no path at all.)
    private func tryWalkDp(_ node: Node, _ pair: DiffPair, solidsOnly: Bool) -> Bool {
        var best = DiffPair()
        var bestScore = 100_000_000_000_000.0
        for attempt in 0...3 {
            let p = DiffPair()
            let tmp = currentNode!.branch()
            let pFirst = attempt & 1 != 0
            let windCw = attempt & 2 != 0
            if attemptWalk(tmp, pair, p, pFirst: pFirst, windCw: windCw, solidsOnly: solidsOnly) {
                let cl = 1 + p.coupledLength
                let skew = p.skew
                let score = cl + abs(skew) * 3.0
                if score < bestScore {
                    bestScore = score
                    best = p
                }
            }
            currentNode!.release(tmp)
        }
        if bestScore > 0.0 {
            let optimizer = Optimizer(world: currentNode!)
            pair.setShape(best)
            optimizer.optimize(pair)
            return true
        }
        return false
    }

    /// The pair to the pointer, walking round what is in its way (KiCad's rhWalkOnly)
    private func rhWalkOnly(_ p: IPoint) -> Bool {
        if !routeHead(p) { return false }
        fitOk = tryWalkDp(currentNode!, currentTrace, solidsOnly: false)
        return fitOk
    }

    private func route(_ p: IPoint) -> Bool {
        switch settings.mode {
        case .markObstacles: return rhMarkObstacles(p)
        case .walkaround: return rhWalkOnly(p)
        case .shove: return rhShoveOnly(p)
        }
    }

    /// The pair to the pointer, walking round pads and holes and shoving what else is in its way (KiCad's
    /// rhShoveOnly)
    private func rhShoveOnly(_ p: IPoint) -> Bool {
        currentNode = shove!.currentNode
        let ok = routeHead(p)
        fitOk = false
        if !ok { return false }
        if !tryWalkDp(currentNode!, currentTrace, solidsOnly: true) { return false }
        var pLine = currentTrace.pLine()
        var nLine = currentTrace.nLine()
        let shove = shove!
        shove.clearHeads()
        shove.addHeads(pLine)
        shove.addHeads(nLine)
        let status = shove.run()
        currentNode = shove.currentNode
        if status == .ok {
            currentNode = shove.currentNode
            if shove.headsModified(0) { pLine = shove.modifiedHead(0) }
            if shove.headsModified(1) { nLine = shove.modifiedHead(1) }
            // Update m_currentTrace with the shoved shapes so FixRoute() commits correct geometry
            currentTrace.setShape(pLine.cLine, nLine.cLine)
            if currentNode!.checkColliding(pLine) == nil && currentNode!.checkColliding(nLine) == nil { fitOk = true }
        } else {
            // bring back previous state
            currentTrace.setShape(pLine.cLine, nLine.cLine)
        }
        return fitOk
    }

    /// The pair's two lines (KiCad's Traces)
    public func traces() -> [Item] { [currentTrace.pLine(), currentTrace.nLine()] }

    public func flipPosture() {
        startDiagonal = !startDiagonal
        if !idle { _ = move(currentEnd, nil) }
    }

    /// The node the pair is placed in, what it has shoved with it (KiCad's: the same with loops removed or not)
    public func currentNode(loopsRemoved: Bool = false) -> Node? { lastNode ?? currentNode }

    /// The pair gone on from its vias on another layer, if it ends in them (KiCad's SetLayer); idle, the layer to
    /// start on
    public func setLayer(_ layer: Int) -> Bool {
        if idle {
            currentLayer = layer
            return true
        }
        if chainedPlacement { return false }
        guard let prevPair else { return false }
        if prevPair.primP == nil || (prevPair.primP!.ofKind(.via) && prevPair.primP!.layers.overlaps(layer)) {
            currentLayer = layer
            start = prevPair
            initPlacement()
            _ = move(currentEnd, nil)
            return true
        }
        return false
    }

    /// Where a pair from `item` (a track, via or pad) starts on it: a track's end that joins nothing, a pad's or via's
    /// anchor (KiCad's getDanglingAnchor)
    private static func danglingAnchor(_ node: Node, _ item: Item) -> IPoint? {
        switch item {
        case let l as Line:
            return l.pointCount == 0 ? nil : l.cPoint(0)
        case is Via, is Solid:
            return item.anchor(0)
        case let s as Segment:
            // (and an arc's ends alike: the port's lines have no arcs)
            let jA = node.findJoint(item.anchor(0), item), jB = node.findJoint(item.anchor(1), item)
            if let jA, jA.linkCount() == 1 { return s.seg.a }
            if let jB, jB.linkCount() == 1 { return s.seg.b }
            return nil
        default:
            return nil
        }
    }

    /// The pair `item` and the nearest item of its coupled net of the same kind (on the same layers, a pad or via)
    /// make, to start or end a pair on (KiCad's FindDpPrimitivePair); nil, with why in `error`, if there is none
    public static func findDpPrimitivePair(_ world: Node, _ p: IPoint, _ item: Item?, error: inout String) -> DPPrimitivePair? {
        guard let item, let (netP, netN) = world.ruleResolver.dpNetPair(item) else {
            error = "Unable to find complementary differential pair nets. Make sure the names of the nets belonging to a "
                + "differential pair end with either N/P or +/-."
            return nil
        }
        let refNet = item.net
        let coupledNet = refNet == netP ? netN : netP
        guard let refAnchor = danglingAnchor(world, item) else {
            error = "Can't find a suitable starting point.  If starting from an existing differential pair make sure you "
                + "are at the end."
            return nil
        }
        // (KiCad's set of the coupled net's items goes by address; tools/kicad-reference has it go by the order they
        // were made in, as here)
        let coupledItems = world.allItems(inNet: coupledNet).sorted { $0.serial < $1.serial }
        var bestDist = Double.greatestFiniteMagnitude
        var found: DPPrimitivePair?
        for candidate in coupledItems where candidate.kind == item.kind {
            guard let anchor = danglingAnchor(world, candidate) else { continue }
            let dist = Double((anchor - refAnchor).norm)
            var shapeMatches = true
            if candidate.ofKind([.solid, .via]) && candidate.layers != item.layers { shapeMatches = false }
            if dist < bestDist && shapeMatches {
                bestDist = dist
                var pair: DPPrimitivePair
                if refNet != netP {
                    pair = DPPrimitivePair(candidate, item)
                    pair.setAnchors(anchor, refAnchor)
                } else {
                    pair = DPPrimitivePair(item, candidate)
                    pair.setAnchors(refAnchor, anchor)
                }
                found = pair
            }
        }
        guard let found else {
            error = "Can't find a suitable starting point for coupled net \"\(world.ruleResolver.netName(coupledNet))\"."
            return nil
        }
        return found
    }

    private var viaGap: Int { sizes.effectiveDiffPairViaGap }

    /// The pair's lines' pitch: its gap and width
    private var gap: Int { sizes.diffPairGap + sizes.diffPairWidth }

    public func start(_ p: IPoint, _ startItem: Item?) -> Bool {
        world = router.world
        currentNode = world
        var error = ""
        guard let s = Self.findDpPrimitivePair(currentNode!, p, startItem, error: &error) else {
            router.failureReason = error
            return false
        }
        start = s
        netP = start.primP!.net
        netN = start.primN!.net
        currentStart = p
        currentEnd = p
        isPlacingVia = false
        chainedPlacement = false
        hasFixedAnything = false
        currentTraceOk = false
        currentTrace = DiffPair()
        currentTrace.setNets(netP, netN)
        lastFixNode = nil
        initPlacement()
        return true
    }

    private func initPlacement() {
        idle = false
        orthoMode = false
        currentEndItem = nil
        startDiagonal = initialDiagonal
        let w = router.world!
        w.killChildren()
        let rootNode = w.branch()
        world = rootNode
        lastNode = nil
        currentNode = rootNode
        shove = Shove(currentNode!, router)
    }

    /// The pair from where it last ended (or started) to the pointer at `p`, or to the pair of pads, vias or track
    /// ends of its nets under it (KiCad's routeHead), through the best fitting pair of gateways; whether there is a
    /// pair to show (this one, or one before it)
    private func routeHead(_ p: IPoint) -> Bool {
        fitOk = false
        var gwsEntry = DPGateways(gap: gap)
        var gwsTarget = DPGateways(gap: gap)
        if prevPair == nil { prevPair = start }
        gwsEntry.buildFromPrimitivePair(prevPair!, preferDiagonal: startDiagonal)
        var error = ""
        if let target = Self.findDpPrimitivePair(currentNode!, p, currentEndItem, error: &error) {
            gwsTarget.buildFromPrimitivePair(target, preferDiagonal: startDiagonal)
            snapOnTarget = true
        } else {
            guard let fp = propagateDpHeadForces(p) else { return false }
            let (midp, dirV) = prevPair!.cursorOrientation(fp)
            let fpProj = Seg(midp, midp + dirV).lineProject(fp)
            // compute 'leader point' distance from the cursor (project cursor position on the extension of the
            // starting segment pair of the DP)
            let leadDist = (fpProj - fp).norm
            gwsTarget.setFitVias(isPlacingVia, diameter: sizes.viaDiameter, viaGap: viaGap)
            if leadDist > (sizes.diffPairGap + sizes.diffPairWidth) / 2 {
                // far from the initial segment extension line -> allow a 45-degree obtuse turn
                gwsTarget.buildForCursor(fp)
            } else {
                // close to the initial segment extension line -> keep straight part only, project as close as
                // possible to the cursor.
                gwsTarget.buildForCursor(fpProj)
                gwsTarget.filterByOrientation([.straight, .halfFull], Direction45(dirV))
            }
            snapOnTarget = false
        }
        currentTrace.setGap(gap)
        currentTrace.setLayer(currentLayer)
        if gwsEntry.fitGateways(gwsEntry, gwsTarget, prefDiagonal: startDiagonal, currentTrace) {
            currentTraceOk = true
            currentTrace.setNets(netP, netN)
            currentTrace.setWidth(sizes.diffPairWidth)
            currentTrace.setGap(sizes.diffPairGap)
            if isPlacingVia {
                currentTrace.appendVias(makeVia(currentTrace.cp.lastPoint, netP), makeVia(currentTrace.cn.lastPoint, netN))
            } else {
                currentTrace.removeVias()
            }
            return true
        }
        return currentTraceOk
    }

    /// The pair routed to the pointer at `p`, `endItem` what is under it; whether it got there clear of everything
    public func move(_ p: IPoint, _ endItem: Item?) -> Bool {
        // (finished, KiCad's reads a node it has not got)
        guard currentNode != nil else { return false }
        currentEndItem = endItem
        fitOk = false
        if let last = lastNode {
            last.parent?.release(last)
            lastNode = nil
        }
        let retval = route(p)
        let latestNode = currentNode!
        lastNode = latestNode.branch()
        currentEnd = p
        // (KiCad's updateLeadingRatLine draws the ratsnest lines from the pair's ends, which are not drawn here)
        return retval
    }

    public func updateSizes(_ s: SizesSettings) {
        let prevDiffPairWidth = sizes.diffPairWidth
        sizes = s
        if !idle {
            // When continuing from an existing track in connected-track-width mode, preserve the inherited diff pair
            // width rather than reverting to the netclass default. This matches the guard in
            // LINE_PLACER::UpdateSizes() for single tracks.
            if !sizes.trackWidthIsExplicit && hasFixedAnything { sizes.diffPairWidth = prevDiffPairWidth }
            currentTrace.setWidth(sizes.diffPairWidth)
            currentTrace.setGap(sizes.diffPairGap)
            if currentTrace.endsWithVias {
                currentTrace.setViaDiameter(sizes.viaDiameter)
                currentTrace.setViaDrill(sizes.viaDrill)
            }
        }
    }

    /// The pair fixed where it is, and committed to the world at once (with its vias, if it ends in them); whether it
    /// is finished (it reached the pair of pads, vias or tracks it was routed to, or was told to finish). If not, it
    /// goes on from its ends.
    public func fixRoute(_ p: IPoint, _ endItem: Item?, forceFinish: Bool) -> Bool {
        if !fitOk && !settings.allowDRCViolations { return false }
        if currentTrace.cp.segmentCount < 1 || currentTrace.cn.segmentCount < 1 { return false }
        if currentTrace.cp.segmentCount > 1 { initialDiagonal = !Direction45(currentTrace.cp.segment(-2)).isDiagonal }
        // (fixed again with no move since, KiCad's reads a node it has not got)
        guard let lastNode else { return false }
        let topo = Topology(lastNode)
        if !snapOnTarget && !currentTrace.endsWithVias && !forceFinish && !settings.fixAllSegments {
            var newP = currentTrace.cp, newN = currentTrace.cn
            if newP.segmentCount > 1 && newN.segmentCount > 1 {
                newP.remove(-1, -1)
                newN.remove(-1, -1)
            }
            currentTrace.setShape(newP, newN)
        }
        if currentTrace.endsWithVias {
            lastNode.add(currentTrace.pLine().via!.clone() as! Via)
            lastNode.add(currentTrace.nLine().via!.clone() as! Via)
            chainedPlacement = false
        } else {
            chainedPlacement = !snapOnTarget && !forceFinish
        }
        let lineP = currentTrace.pLine().copy()
        let lineN = currentTrace.nLine().copy()
        lastNode.add(lineP)
        lastNode.add(lineN)
        topo.simplifyLine(lineP)
        topo.simplifyLine(lineN)
        prevPair = currentTrace.endingPrimitives()
        lastFixNode = lastNode
        // avoid an use-after-free error (CommitPlacement calls NODE::Commit which will invalidate the shove heads
        // state. Need to rethink the memory management).
        if settings.mode == .shove { shove = Shove(world!, router) }
        _ = commitPlacement()
        isPlacingVia = false
        lastFixNode = nil
        if snapOnTarget || forceFinish {
            idle = true
            return true
        }
        hasFixedAnything = true
        initPlacement()
        return false
    }

    public func abortPlacement() -> Bool {
        world?.killChildren()
        lastNode = nil
        return true
    }

    public var hasPlacedAnything: Bool { currentTrace.cp.segmentCount > 0 || currentTrace.cn.segmentCount > 0 }

    public func commitPlacement() -> Bool {
        if let lastFixNode { router.commitRouting(lastFixNode) }
        lastFixNode = nil
        lastNode = nil
        currentNode = nil
        return true
    }

    public var currentNets: [NetHandle?] { [netP, netN] }
}
