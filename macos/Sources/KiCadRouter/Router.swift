// Ported from KiCad 10.0.7: pcbnew/router/pns_router.h and pns_router.cpp.
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
}

extension RouterInterface {
    /// Why routing cannot start from a non-routable item (a hole without plating, a rule area, a text)
    public func nonRoutableReason(_ item: Item) -> String? { nil }

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
    public private(set) var world: Node?
    public private(set) var iface: RouterInterface?
    public var iterLimit = 0
    public var visibleViewArea = IBox(minX: 0, minY: 0, maxX: 0, maxY: 0)
    public var failureReason = ""

    public init() {
        Router.instance = self
    }

    public func setInterface(_ i: RouterInterface) {
        iface = i
        Router.instance = self
    }

    public var ruleResolver: RuleResolver? { iface?.ruleResolver }

    public private(set) var placer: LinePlacer?

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
        guard let node = placer?.currentNode() ?? world else { return [] }
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
        return true
    }

    /// Starts a track at `p`, from `startItem` (the pad or track there), on `layer`
    public func startRouting(_ p: IPoint, _ startItem: Item?, layer: Int) -> Bool {
        Router.instance = self
        ruleResolver?.clearCaches()
        if !isStartingPointRoutable(p, startItem, layer) { return false }
        let placer = LinePlacer(router: self)
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

    /// The track routed on to `p` (`endItem`: what is there)
    @discardableResult
    public func move(_ p: IPoint, _ endItem: Item?) -> Bool {
        Router.instance = self
        defer { ruleResolver?.clearTemporaryCaches() }
        guard state == .routeTrack, let placer else { return false }
        let ret = placer.move(p, endItem)
        if let node = placer.currentNode(loopsRemoved: true) { markViolations(node, placer.traces()) }
        return ret
    }

    /// The obstacles of what is being routed marked (KiCad's markViolations, without the drawing)
    private func markViolations(_ node: Node, _ current: [Item]) {
        for item in current {
            var obstacles = node.queryColliding(item)
            if let l = item as? Line, let via = l.via { obstacles += node.queryColliding(via.clone() as! Via) }
            for obs in obstacles { obs.item.mark(obs.item.marker.union(.violation)) }
        }
    }

    /// Fixes the track routed so far at `p`; whether it is finished (it reached its net's `endItem`, or was told to
    /// finish)
    public func fixRoute(_ p: IPoint, _ endItem: Item?, forceFinish: Bool = false) -> Bool {
        Router.instance = self
        guard state == .routeTrack, let placer else { return false }
        return placer.fixRoute(p, endItem, forceFinish: forceFinish)
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

    public var currentNets: [NetHandle?] { placer.map { [$0.currentNet] } ?? [] }
    public var currentLayer: Int { placer?.currentLayer ?? -1 }
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
