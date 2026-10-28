// Ported from KiCad 10.0.7: pcbnew/router/pns_router.h and pns_router.cpp (routing a track or a differential pair,
// tuning a track's or a pair's length or a pair's skew, and dragging a segment, corner or via; not footprints or
// pairs dragged), and PNS_KICAD_IFACE_BASE::CalculateRoutedPathLength (pcbnew/router/pns_kicad_iface.cpp) with the
// parts of pcbnew/length_delay_calculation/length_delay_calculation.cpp it uses (CalculateLengthDetails, its length).
// Copyright (C) 2013-2014 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// What the router asks of the board it routes on (KiCad's ROUTER_IFACE): its items brought into the router's world,
/// the router's results taken back, and what only the board knows (which layers a pad's copper is on)
public protocol RouterInterface: AnyObject {
    /// Fills `world` with the board's items, and gives it the board's rules
    func syncWorld(_ world: Node)
    func addItem(_ item: Item)
    func updateItem(_ item: Item)
    func removeItem(_ item: Item)
    func commit()
    /// Whether the item has copper on `layer` (-1: any)
    func isFlashed(_ item: Item, onLayer layer: Int) -> Bool
    func isFlashed(_ item: Item, onLayers layers: LayerRange) -> Bool
    func isCopperLayer(_ layer: Int) -> Bool
    /// The sizes to route with from `startItem` (its net's class, the track it starts from)
    func importSizes(_ sizes: inout SizesSettings, startItem: Item?, net: NetHandle?, start: IPoint) -> Bool
    func stackupHeight(_ firstLayer: Int, _ secondLayer: Int) -> Int
    func netCode(_ net: NetHandle?) -> Int
    func netName(_ net: NetHandle?) -> String
    /// The board's handle for "no net"
    var orphanedNetHandle: NetHandle { get }
    var ruleResolver: RuleResolver { get }
    var copperLayerCount: Int { get }
    /// Why routing cannot start from a non-routable item (a hole without plating, a rule area, a text), as its board
    /// item says when ROUTER::isStartingPointRoutable asks it; nil: nothing stops it
    func nonRoutableReason(_ item: Item) -> String?
    /// The length of a path of lines and vias from `startPad` to `endPad`, as the board measures it for a length
    /// tuning (KiCad's CalculateRoutedPathLength)
    func calculateRoutedPathLength(_ path: [Item], startPad: Solid?, endPad: Solid?) -> Int
}

extension RouterInterface {
    public func nonRoutableReason(_ item: Item) -> String? { nil }

    /// The length of a path of lines and vias, as KiCad's LENGTH_DELAY_CALCULATION::CalculateLength works it out for
    /// a length tuning's path (PNS_KICAD_IFACE_BASE::CalculateRoutedPathLength: none of the path's optimisations
    /// asked for): each line's length, and for each via between lines on two layers the board's thickness between
    /// them (StackupHeight; KiCad's "use height for length calculations" on, as boards have it by default). (A pad at
    /// either end would add a via KiCad infers where the line is on a layer the pad is not on, but it asks that of
    /// the pad's board item, which the router's pads here have none of.)
    public func calculateRoutedPathLength(_ path: [Item], startPad: Solid?, endPad: Solid?) -> Int {
        var trackLength = 0
        var viaLength = 0
        for (idx, item) in path.enumerated() {
            if let l = item as? Line {
                trackLength += l.cLine.length
            } else if item.ofKind(.via) && idx > 0 && idx < path.count - 1 {
                let layerPrev = path[idx - 1].layer
                let layerNext = path[idx + 1].layer
                if layerPrev != layerNext { viaLength += stackupHeight(layerPrev, layerNext) }
            }
        }
        return viaLength + trackLength
    }

    /// A track segment's solder mask: whether it has an opening, and its own margin (its board track's)
    public func solderMask(_ item: Item) -> (Bool, Int?) { (false, nil) }

    /// KiCad's PNS_KICAD_IFACE_BASE::IsFlashedOnLayer with no board item behind the item
    public func defaultIsFlashed(_ item: Item, onLayer layer: Int) -> Bool {
        if layer < 0 { return true }
        if let via = item as? Via { return via.connectsLayer(layer) }
        return item.layers.overlaps(layer)
    }

    public func defaultIsFlashed(_ item: Item, onLayers range: LayerRange) -> Bool {
        let test = item.layers.intersection(range)
        if let via = item as? Via {
            guard test.start <= test.end else { return false }
            return (test.start...test.end).contains { via.connectsLayer($0) }
        }
        return test.start <= test.end
    }
}

/// The interactive router: a world of the board's items, and the track being placed in it (KiCad's PNS::ROUTER)
public final class Router {
    public enum State: Sendable { case idle, dragSegment, dragComponent, routeTrack }

    /// What the router places (KiCad's ROUTER_MODE): a single track, or a differential pair; or a track's length
    /// tuned, a differential pair's, or a pair's skew
    public enum Mode: Sendable { case routeSingle, routeDiffPair, tuneSingle, tuneDiffPair, tuneDiffPairSkew }

    /// The router at work (KiCad's ROUTER::GetInstance, which its geometry asks for the board's flashing)
    nonisolated(unsafe) public private(set) static weak var instance: Router?
    /// The board's side of the router at work
    public static var interface: RouterInterface? { instance?.iface }

    /// Where the router's trace goes, KiCad's PNS_DBG messages (nil: nowhere)
    nonisolated(unsafe) public static var trace: ((String) -> Void)?

    static func dbg(_ message: @autoclosure () -> String) {
        if let trace { trace(message()) }
    }

    public var settings = RoutingSettings()
    public var sizes = SizesSettings()
    public private(set) var state: State = .idle
    public var mode: Mode = .routeSingle
    public private(set) var world: Node?
    public private(set) var iface: RouterInterface?
    public var iterLimit = 0
    /// What the user can see of the board, which the shove's optimizer keeps to (KiCad's: all of it, until the
    /// router tool says)
    public var visibleViewArea = IBox.maximum
    public var failureReason = ""

    public init() {
        Router.instance = self
    }

    public func setInterface(_ i: RouterInterface) {
        iface = i
        Router.instance = self
    }

    public var ruleResolver: RuleResolver? { iface?.ruleResolver }

    public private(set) var placer: PlacementAlgo?
    /// The placer, routing a single track
    public var linePlacer: LinePlacer? { placer as? LinePlacer }
    /// The placer, routing a differential pair
    public var diffPairPlacer: DiffPairPlacer? { placer as? DiffPairPlacer }
    /// The placer, tuning a length
    public var meanderPlacer: MeanderPlacerBase? { placer as? MeanderPlacerBase }
    /// What drags a segment, corner or via (KiCad's GetDragger)
    public private(set) var dragger: Dragger?

    public func clearWorld() {
        world?.killChildren()
        world = nil
        placer = nil
    }

    public func syncWorld() {
        clearWorld()
        let w = Node()
        world = w
        iface?.syncWorld(w)
        w.fixupVirtualVias()
    }

    public var routingInProgress: Bool { state != .idle }

    /// What is at `p` (within `slopRadius`), in the placer's node or the world
    public func queryHoverItems(_ p: IPoint, slopRadius: Int = 0) -> [Item] {
        guard let node = placer?.currentNode(loopsRemoved: false) ?? world else { return [] }
        if slopRadius > 0 {
            let test = Segment(Seg(p, p), net: nil)
            test.width = 1
            test.layers = .all
            var opts = CollisionSearchOptions()
            opts.differentNetsOnly = false
            opts.overrideClearance = slopRadius
            return node.queryColliding(test, options: opts).map(\.item)
        }
        return node.hitTest(p)
    }

    private func isStartingPointRoutable(_ at: IPoint, _ startItem: Item?, _ layer: Int) -> Bool {
        if settings.allowDRCViolations { return true }
        if mode == .routeDiffPair && sizes.diffPairGap < sizes.minClearance {
            failureReason = "Diff pair gap is less than board minimum clearance."
            return false
        }
        var failure = ""
        for item in queryHoverItems(at) {
            if let r = world?.ruleResolver, r.isOnEdgeCuts(item) { continue }
            if !item.layers.overlaps(layer) { continue }
            if item.isRoutable {
                failure = ""
                break
            }
            if let reason = iface?.nonRoutableReason(item) { failure = reason }
        }
        if !failure.isEmpty {
            failureReason = failure
            return false
        }
        switch mode {
        case .routeSingle:
            let dummy = Line()
            dummy.setShape(LineChain([at, at]))
            dummy.setLayer(layer)
            dummy.net = startItem?.net
            dummy.setWidth(sizes.trackWidth)
            if world!.checkColliding(dummy, kindMask: .any) != nil {
                dummy.setWidth(sizes.boardMinTrackWidth)
                if world!.checkColliding(dummy, kindMask: .any) != nil {
                    failureReason = "The routing start point violates DRC."
                    return false
                }
            }
        case .routeDiffPair:
            guard let startItem else {
                failureReason = "Cannot start a differential pair in the middle of nowhere."
                return false
            }
            var error = ""
            guard let dpPair = DiffPairPlacer.findDpPrimitivePair(world!, at, startItem, error: &error) else {
                failureReason = error
                return false
            }
            // We intentionally do not reject a start point whose existing gap differs from the configured diff pair
            // gap. Starting inside a neckdown area (e.g. a narrowed gap under a BGA) and widening out to the netclass
            // gap is a legitimate workflow. The placer fits the widening transition starting from the existing anchor
            // pair.
            let dummyA = Line(), dummyB = Line()
            dummyA.setShape(LineChain([dpPair.anchorN, dpPair.anchorN]))
            dummyA.setLayer(layer)
            dummyA.net = dpPair.primN!.net
            dummyA.setWidth(sizes.diffPairWidth)
            dummyB.setShape(LineChain([dpPair.anchorP, dpPair.anchorP]))
            dummyB.setLayer(layer)
            dummyB.net = dpPair.primP!.net
            dummyB.setWidth(sizes.diffPairWidth)
            if world!.checkColliding(dummyA, kindMask: .any) != nil || world!.checkColliding(dummyB, kindMask: .any) != nil {
                // (as for a track: the board's minimum width tried before the start is refused)
                dummyA.setWidth(sizes.boardMinTrackWidth)
                dummyB.setWidth(sizes.boardMinTrackWidth)
                if world!.checkColliding(dummyA, kindMask: .any) != nil || world!.checkColliding(dummyB, kindMask: .any) != nil {
                    failureReason = "The routing start point violates DRC."
                    return false
                }
            }
        case .tuneSingle, .tuneDiffPair, .tuneDiffPairSkew:
            break
        }
        return true
    }

    /// Starts a track at `p`, from `startItem` (the pad or track there), on `layer`; in the differential pair mode, a
    /// pair from it and the nearest item of its coupled net; in the length tuning modes, a tuning of the track
    /// `startItem` (or of its pair) from `p`
    public func startRouting(_ p: IPoint, _ startItem: Item?, layer: Int) -> Bool {
        Router.instance = self
        ruleResolver?.clearCaches()
        if !isStartingPointRoutable(p, startItem, layer) { return false }
        let placer: PlacementAlgo
        switch mode {
        case .routeSingle: placer = LinePlacer(router: self)
        case .routeDiffPair: placer = DiffPairPlacer(router: self)
        case .tuneSingle: placer = MeanderPlacer(router: self)
        case .tuneDiffPair: placer = DPMeanderPlacer(router: self)
        case .tuneDiffPairSkew: placer = MeanderSkewPlacer(router: self)
        }
        self.placer = placer
        placer.updateSizes(sizes)
        _ = placer.setLayer(layer)
        if placer.start(p, startItem) {
            state = .routeTrack
            return true
        }
        state = .idle
        self.placer = nil
        return false
    }

    /// Starts dragging `item` (a track's segment, or a via) from `p` (KiCad's StartDragging): its segment, or its
    /// corner if `p` is at one of its ends, as `mode` allows; whether it could
    public func startDragging(_ p: IPoint, _ item: Item?, mode: DragMode = .any) -> Bool {
        Router.instance = self
        failureReason = ""
        guard let item else { return false }
        ruleResolver?.clearCaches()
        // (footprints' pads, and several segments at once, which KiCad's COMPONENT_DRAGGER and MULTI_DRAGGER drag, are
        // not ported)
        if item.ofKind(.solid) { return false }
        guard let world else { return false }
        let dragger = Dragger(router: self, world: world)
        self.dragger = dragger
        state = .dragSegment
        dragger.setMode(mode)
        dragger.setWorld(world)
        if dragger.start(p, [item]) { return true }
        self.dragger = nil
        state = .idle
        return false
    }

    /// The track routed, or what is dragged, on to `p` (`endItem`: what is there)
    @discardableResult
    public func move(_ p: IPoint, _ endItem: Item?) -> Bool {
        Router.instance = self
        defer { ruleResolver?.clearTemporaryCaches() }
        switch state {
        case .routeTrack: return movePlacing(p, endItem)
        case .dragSegment, .dragComponent: return moveDragging(p, endItem)
        case .idle: return false
        }
    }

    /// KiCad's moveDragging, without the drawing
    private func moveDragging(_ p: IPoint, _ endItem: Item?) -> Bool {
        guard let dragger else { return false }
        let ret = dragger.drag(p)
        markViolations(dragger.currentNode, dragger.traces)
        return ret
    }

    /// KiCad's movePlacing, without the drawing (the violations marked routing, not tuning a length, which by design
    /// makes none, as KiCad's updateView marks them; the traces asked for as KiCad asks for them to draw them)
    private func movePlacing(_ p: IPoint, _ endItem: Item?) -> Bool {
        guard let placer else { return false }
        let ret = placer.move(p, endItem)
        let current = placer.traces()
        if mode == .routeSingle || mode == .routeDiffPair, let node = placer.currentNode(loopsRemoved: true) {
            markViolations(node, current)
        }
        return ret
    }

    /// The obstacles of what is being routed marked (KiCad's markViolations, without the drawing), not what is being
    /// dragged
    private func markViolations(_ node: Node, _ current: [Item]) {
        let dragged = dragger?.traces ?? []
        for item in current {
            var obstacles = node.queryColliding(item)
            if let l = item as? Line, let via = l.via { obstacles += node.queryColliding(via.clone() as! Via) }
            for obs in obstacles where !dragged.contains(where: { $0 === obs.item }) {
                obs.item.mark(obs.item.marker.union(.violation))
            }
        }
    }

    /// Fixes the track routed so far at `p`; whether it is finished (it reached its net's `endItem`, or was told to
    /// finish). Dragging, the drag kept if it may be (`forceCommit`: even where it collides, marking obstacles);
    /// whether it was.
    public func fixRoute(_ p: IPoint, _ endItem: Item?, forceFinish: Bool = false, forceCommit: Bool = false) -> Bool {
        Router.instance = self
        switch state {
        case .routeTrack: return placer?.fixRoute(p, endItem, forceFinish: forceFinish) ?? false
        case .dragSegment, .dragComponent: return dragger?.fixRoute(forceCommit: forceCommit) ?? false
        case .idle: return false
        }
    }

    public func undoLastSegment() -> IPoint? {
        guard routingInProgress else { return nil }
        return placer?.unfixRoute()
    }

    /// The board's side told what a branch changed, and the world brought up to date with it
    public func commitRouting(_ node: Node) {
        if state == .routeTrack, let placer, !placer.hasPlacedAnything { return }
        var (removed, added) = node.updatedItems()
        var changed: [Item] = []
        for item in removed {
            var isChanged = false
            if let parent = item.parent, let i = added.firstIndex(where: { $0.parent === parent }) {
                changed.append(added.remove(at: i))
                isChanged = true
            }
            if !isChanged && !item.isVirtual { iface?.removeItem(item) }
        }
        for item in added where !item.isVirtual { iface?.addItem(item) }
        for item in changed where !item.isVirtual { iface?.updateItem(item) }
        iface?.commit()
        world?.commit(node)
    }

    /// The track routed so far kept
    public func commitRouting() {
        if state == .routeTrack { _ = placer?.commitPlacement() }
        stopRouting()
    }

    public func stopRouting() {
        if !routingInProgress { return }
        placer = nil
        dragger = nil
        state = .idle
        world?.killChildren()
        world?.clearRanks()
    }

    public func updateSizes(_ s: SizesSettings) {
        sizes = s
        if state == .routeTrack { placer?.updateSizes(s) }
    }

    public func flipPosture() {
        if state == .routeTrack { placer?.flipPosture() }
    }

    public func switchLayer(_ layer: Int) -> Bool {
        state == .routeTrack ? (placer?.setLayer(layer) ?? false) : false
    }

    public func toggleViaPlacement() {
        if state == .routeTrack, let placer { _ = placer.toggleVia(!placer.isPlacingVia) }
    }

    public var currentNets: [NetHandle?] { placer?.currentNets ?? dragger?.currentNets ?? [] }
    public var currentLayer: Int { placer?.currentLayer ?? dragger?.currentLayer ?? -1 }
    public var isPlacingVia: Bool { placer?.isPlacingVia ?? false }

    /// Where the track being routed should go next, and what is there (KiCad's GetNearestRatnestAnchor)
    public func nearestRatnestAnchor() -> (point: IPoint, layers: LayerRange, item: Item)? {
        guard let placer, let net = currentNets.first, net != nil, let trace = placer.traces().first as? Line,
              let lastNode = placer.currentNode(loopsRemoved: true) else { return nil }
        let topo = Topology(lastNode)
        if trace.segmentCount > 0 { return topo.nearestUnconnectedAnchorPoint(trace) }
        guard let jt = lastNode.findJoint(placer.currentStart, layer: placer.currentLayer, net: net),
              let (it, anchor) = topo.nearestUnconnectedItem(jt) else { return nil }
        return (it.anchor(anchor), it.layers, it)
    }

    /// The track routed to where the ratsnest says it should go, and fixed there (KiCad's Finish)
    public func finish() -> Bool {
        guard state == .routeTrack, let placer, !placer.traces().isEmpty else { return false }
        guard let (otherEnd, otherEndLayers, otherEndItem) = nearestRatnestAnchor() else { return false }
        var triesLeft = 5
        var moveResultPoint: IPoint
        repeat {
            moveResultPoint = placer.currentEnd
            move(otherEnd, otherEndItem)
            triesLeft -= 1
        } while placer.currentEnd != moveResultPoint && triesLeft > 0
        if moveResultPoint == otherEnd && otherEndLayers.overlaps(currentLayer) {
            return fixRoute(otherEnd, otherEndItem, forceFinish: false)
        }
        return false
    }
}
