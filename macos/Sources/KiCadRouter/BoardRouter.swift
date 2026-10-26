// Routing on a KiCad board: the router (KiCad's, ported) on the board's world, and what it places written back into
// the board as KiCad writes tracks and vias. The start item and sizes are as KiCad's router tool and
// PNS_KICAD_IFACE_BASE::ImportSizes find them (pcbnew/router/router_tool.cpp, pns_kicad_iface.cpp, KiCad 10.0.7).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt. GNU General Public License version 3 or later, as KiCad
// (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// Interactive routing on a KiCad board: start on a pad, track or via (or anywhere), move the pointer, fix, place
/// vias, switch layers, and commit; what the router places goes into the board's file as KiCad writes it
public final class BoardRouter {
    public let board: KiCadBoard
    public private(set) var world: BoardWorld
    public let router = Router()
    let iface: WorldInterface
    private let project: [String: Any]?

    /// The tracks and vias added to the board (their uuids), and those it took away, by the last commit
    public private(set) var lastAdded: [String] = []
    public private(set) var lastRemoved: [String] = []

    public init(board: KiCadBoard, project: [String: Any]? = nil) {
        self.board = board
        self.project = project
        world = BoardWorld(board: board, project: project)
        iface = WorldInterface(items: world.items, layers: world.copperLayers, rules: world.rules)
        router.setInterface(iface)
        router.settings.mode = .walkaround
        router.syncWorld()
    }

    /// The board changed here other than by routing (a footprint moved): what changed taken in
    public func boardChanged() {
        router.stopRouting()
        lastAdded = []
        lastRemoved = []
        reload()
    }

    /// The board read again after it changed elsewhere (a footprint moved, a track deleted)
    public func reload() {
        world = BoardWorld(board: board, project: project)
        iface.items = world.items
        router.syncWorld()
    }

    /// What the world holds that the router cannot see as KiCad's does yet
    public var unsupported: Set<String> { world.unsupported.union(iface.unsupported) }

    // MARK: - Layers

    /// A board copper layer's name as a router layer
    public func layer(_ name: String) -> Int? { world.layerIndex[name] }

    /// A router layer's board copper layer name
    public func layerName(_ layer: Int) -> String {
        world.layerIndex.first { $0.value == layer }?.key ?? (layer == 0 ? "F.Cu" : "B.Cu")
    }

    // MARK: - Routing

    /// How the router gets past what is in a track's way: walks round it, or shoves it aside (KiCad's router modes)
    public var mode: RouterMode {
        get { router.settings.mode }
        set { router.settings.mode = newValue }
    }

    /// What the track being routed has shoved aside, as KiCad's router shows it (the line placer's current node, its
    /// loops taken out): the board's tracks and vias it moved (their ids), and the tracks and vias where they go now
    public var shoved: (moved: Set<String>, items: [Item]) {
        guard router.routingInProgress, mode == .shove, let node = router.placer?.currentNode(loopsRemoved: true) else { return ([], []) }
        let (removed, added) = node.updatedItems()
        let moved = Set(removed.compactMap { iface.resolver.info[ObjectIdentifier($0)]?.source })
        return (moved, added.filter { !$0.isVirtual && ($0.kind == .segment || $0.kind == .via) })
    }

    /// The routable item at `p` on `layer`: a pad, then a via, then a track (as the router tool picks its start)
    public func item(at p: IPoint, layer: Int) -> Item? {
        let hits = router.queryHoverItems(p).filter { $0.layers.overlaps(layer) && $0.isRoutable }
        return hits.first { $0.kind == .solid } ?? hits.first { $0.kind == .via } ?? hits.first { $0.kind == .segment }
    }

    /// Where a track starting at `p` on `item` starts: a pad's or via's centre, a track's nearer end or the point on it
    public func snap(_ p: IPoint, to item: Item?) -> IPoint {
        switch item {
        case let s as Solid: return s.pos
        case let v as Via: return v.pos
        case let s as Segment:
            let a = s.seg.a, b = s.seg.b
            let near = p.distance(a) < p.distance(b) ? a : b
            return p.distance(near) <= Double(s.width) ? near : s.seg.nearestPoint(p)
        default: return p
        }
    }

    /// The sizes a track from `item` takes: its net class's track width (or the width of the track it starts on) and
    /// via, no less than the board's minimums (KiCad's ImportSizes)
    public func sizes(for item: Item?, net name: String? = nil) -> SizesSettings {
        var s = SizesSettings()
        let net = name ?? item?.net.flatMap { world.netNames[$0] } ?? ""
        let nc = world.netClasses.effective(net)
        s.clearance = world.rules.clearance
        if let seg = item as? Segment {
            s.trackWidth = seg.width
        } else {
            s.trackWidth = max(world.minTrackWidth, nc.trackWidth ?? 200_000)
        }
        s.boardMinTrackWidth = world.minTrackWidth
        s.viaDiameter = max(world.minViaDiameter, nc.viaDiameter ?? 600_000)
        s.viaDrill = max(world.minViaDrill, nc.viaDrill ?? 300_000)
        return s
    }

    /// Starts a track at `p` on `layer`, from what is there; whether the router could start it (a start on another
    /// net's copper, or too close to it, cannot)
    @discardableResult
    public func start(at p: IPoint, layer: Int, width: Int? = nil) -> Bool {
        let item = item(at: p, layer: layer)
        var s = sizes(for: item)
        if let width { s.trackWidth = width }
        router.updateSizes(s)
        iface.added.removeAll()
        iface.removedItems.removeAll()
        return router.startRouting(snap(p, to: item), item, layer: layer)
    }

    /// The pointer moved to `p`
    @discardableResult
    public func move(to p: IPoint) -> Bool {
        router.move(p, endItem(at: p))
    }

    /// What the track would end on at `p`: an item of its net there
    private func endItem(at p: IPoint) -> Item? {
        guard let net = router.currentNets.first ?? nil else { return nil }
        let layer = router.currentLayer
        let hits = router.queryHoverItems(p).filter { $0.net == net && $0.layers.overlaps(layer) && $0.isRoutable }
        return hits.first { $0.kind == .solid } ?? hits.first { $0.kind == .via } ?? hits.first { $0.kind == .segment }
    }

    /// A click at `p`: the track fixed up to there; whether it is finished (it reached its net)
    @discardableResult
    public func fix(at p: IPoint) -> Bool {
        let placingVia = router.isPlacingVia
        let done = router.fixRoute(p, endItem(at: p))
        // (a via placed: on to its other layer, as the router tool goes)
        if !done && placingVia {
            let current = router.currentLayer
            _ = router.switchLayer(router.sizes.pairedLayer(current) ?? (current == 0 ? world.copperLayers - 1 : 0))
        }
        return done
    }

    /// The track fixed at `p` and finished there, whether or not it reached its net (a double click)
    @discardableResult
    public func finish(at p: IPoint) -> Bool {
        router.fixRoute(p, endItem(at: p), forceFinish: true)
    }

    /// The track routed on to the nearest pad or track of its net still to join, and fixed there (KiCad's End);
    /// whether it got there
    @discardableResult
    public func finishToRatsnest() -> Bool { router.finish() }

    /// Where the track being routed should go next: the nearest pad or track of its net it is not joined to
    public var target: IPoint? { router.nearestRatnestAnchor()?.point }

    /// The net of the track being routed, by name
    public var routedNet: String? { (router.currentNets.first ?? nil).flatMap { world.netNames[$0] } }

    /// The track's width from here on (nil: its net class's)
    public func setWidth(_ width: Int?) {
        guard router.routingInProgress else { return }
        var s = router.sizes
        s.trackWidth = width ?? sizes(for: nil, net: routedNet).trackWidth
        router.updateSizes(s)
    }

    /// A via at the end of the track, to `layer` (the other outer layer if none given): the next click places it
    public func placeVia(to layer: Int? = nil) {
        let current = router.currentLayer
        let target = layer ?? (current == 0 ? world.copperLayers - 1 : 0)
        guard target != current else { return }
        var s = router.sizes
        s.clearLayerPairs()
        s.addLayerPair(current, target)
        router.updateSizes(s)
        if !router.isPlacingVia { router.toggleViaPlacement() }
    }

    /// The track continued on another layer from its start (before anything is fixed)
    @discardableResult
    public func switchLayer(_ layer: Int) -> Bool { router.switchLayer(layer) }

    public func flipPosture() { router.flipPosture() }

    /// The last fixed part taken back
    @discardableResult
    public func undo() -> IPoint? { router.undoLastSegment() }

    /// The track as placed so far, for drawing: its fixed part, the part following the pointer, and where a via goes
    public var preview: (tail: LineChain, head: LineChain, width: Int, layer: Int, via: IPoint?)? {
        guard router.routingInProgress, let p = router.placer else { return nil }
        return (p.tail.cLine, p.head.cLine, p.head.width, p.currentLayer, p.head.via?.pos)
    }

    /// The track kept: what the router placed written into the board, what it replaced taken out
    public func commit() {
        router.commitRouting()
        apply()
    }

    /// Tracks and vias taken off the board, by their ids
    public func remove(_ uuids: Set<String>) {
        router.stopRouting()
        lastAdded = []
        lastRemoved = []
        for node in board.copperItems {
            guard let uuid = node.value("uuid"), uuids.contains(uuid) else { continue }
            board.root.remove(node)
            lastRemoved.append(uuid)
        }
        reload()
    }

    /// The track dropped
    public func cancel() {
        router.stopRouting()
        iface.added.removeAll()
        iface.removedItems.removeAll()
    }

    // MARK: - Stitching

    /// Through vias of net `name` at `points`, its net class's size, each where the router finds it clear of
    /// everything else on the board (its clearances, holes and edge, as the router keeps a via it places clear) and of
    /// those placed before it; free vias, as KiCad's via tool places them. The ids of those placed.
    @discardableResult
    public func placeVias(net name: String, at points: [IPoint]) -> [String] {
        router.stopRouting()
        lastAdded = []
        lastRemoved = []
        guard let net = world.netNames.first(where: { $0.value == name })?.key, let node = router.world else { return [] }
        let s = sizes(for: nil, net: name)
        for p in points {
            let via = Via(pos: p, layers: LayerRange(0, world.copperLayers - 1), diameter: s.viaDiameter, drill: s.viaDrill, net: net)
            guard node.checkColliding(via) == nil else { continue }
            node.add(via)
            lastAdded.append(insert(via: via, free: true))
        }
        reload()
        return lastAdded
    }

    // MARK: - Writing the board

    private func apply() {
        lastAdded = []
        lastRemoved = []
        for item in iface.removedItems {
            guard let uuid = iface.resolver.info[ObjectIdentifier(item)]?.source else { continue }
            if let node = board.root.items.first(where: { ($0.head == "segment" || $0.head == "via" || $0.head == "arc") && $0.value("uuid") == uuid }) {
                board.root.remove(node)
                lastRemoved.append(uuid)
            }
        }
        for item in iface.added {
            if let s = item as? Segment {
                lastAdded.append(insert(segment: s))
            } else if let v = item as? Via {
                lastAdded.append(insert(via: v))
            }
        }
        iface.added.removeAll()
        iface.removedItems.removeAll()
        reload()
    }

    private static func mm(_ v: Int) -> Double { Double(v) / 1_000_000 }

    private func netList(_ net: NetHandle?) -> SExpr {
        board.netList(net.flatMap { world.netNames[$0] } ?? "", pad: false)
    }

    private func insert(segment s: Segment) -> String {
        let uuid = KiCadBoard.newUUID()
        let node = SExpr("segment", SExpr("start", Self.mm(s.seg.a.x), Self.mm(s.seg.a.y)), SExpr("end", Self.mm(s.seg.b.x), Self.mm(s.seg.b.y)),
                         SExpr("width", Self.mm(s.width)), SExpr("layer", layerName(s.layer)), netList(s.net), SExpr("uuid", uuid))
        insertTrack(node)
        return uuid
    }

    private func insert(via v: Via, free: Bool = false) -> String {
        let uuid = KiCadBoard.newUUID()
        let node = SExpr("via", SExpr("at", Self.mm(v.pos.x), Self.mm(v.pos.y)), SExpr("size", Self.mm(v.diameter)), SExpr("drill", Self.mm(v.drill)),
                         SExpr("layers", layerName(v.layers.start), layerName(v.layers.end)), netList(v.net), SExpr("uuid", uuid))
        // (KiCad writes a free via's flag after its layers)
        if free { node.items.insert(SExpr("free", Keyword("yes")), at: 5) }
        insertTrack(node)
        return uuid
    }

    /// A track or via put after the board's others, as KiCad keeps them
    private func insertTrack(_ node: SExpr) { board.addCopper(node) }
}
