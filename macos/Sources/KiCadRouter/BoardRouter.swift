// Routing on a KiCad board: the router (KiCad's, ported) on the board's world, and what it places written back into
// the board as KiCad writes tracks, arc tracks and vias. The start item and sizes are as KiCad's router tool and
// PNS_KICAD_IFACE_BASE::ImportSizes find them (a differential pair's too, routed as its Route Differential Pair
// routes one), and tracks and vias are dragged as its drag tools drag them
// (pcbnew/router/router_tool.cpp, pns_tool_base.cpp, pns_kicad_iface.cpp, pcbnew/tools/pcb_grid_helper.cpp,
// pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr.cpp, pcbnew/pcb_track.cpp, KiCad 10.0.7).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt. GNU General Public License version 3 or later, as KiCad
// (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// Interactive routing on a KiCad board: start on a pad, track or via (or anywhere), move the pointer, fix, place
/// vias, switch layers, and commit; or drag a track or via; what the router places goes into the board's file as
/// KiCad writes it
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

    /// How a track routed turns its corners: on the 45° directions or on 90° ones only, mitred, or rounded with an arc
    /// (KiCad's router's track corner modes); arcs go into the board as arc tracks
    public var cornerMode: Direction45.CornerMode {
        get { router.settings.cornerMode }
        set { router.settings.cornerMode = newValue }
    }

    /// What the track being routed has shoved aside, as KiCad's router shows it (the line placer's current node, its
    /// loops taken out): the board's tracks and vias it moved (their ids), and the tracks and vias where they go now
    public var shoved: (moved: Set<String>, items: [Item]) {
        guard router.routingInProgress, mode == .shove, let node = router.placer?.currentNode(loopsRemoved: true) else { return ([], []) }
        let (removed, added) = node.updatedItems()
        let moved = Set(removed.compactMap { iface.resolver.info[ObjectIdentifier($0)]?.source })
        return (moved, added.filter { !$0.isVirtual && ($0.kind == .segment || $0.kind == .arc || $0.kind == .via) })
    }

    // MARK: - The pointer, as KiCad's router tool takes it (pcbnew/router/pns_tool_base.cpp and router_tool.cpp,
    // pcbnew/tools/pcb_grid_helper.cpp, common/tool/grid_helper.cpp)

    /// The grid the pointer goes to where there is nothing to snap to, in nm (the editor's grid, its origin at 0)
    public var grid = 50_000
    /// What the track being routed started on (which it does not end on), or what is being dragged
    private var startItem: Item?
    /// The layer chosen when the drag started (the view's top layer, for KiCad's router tool), and whether what it
    /// drags was locked
    private var dragLayer = 0
    private var draggedLocked = false

    /// What a track started at the pointer `p` starts on, `layer` the layer chosen (TOOL_BASE::updateStartItem): the
    /// item there of any net, picked as pickSingleItem picks it; and where the track starts, on it (snapToItem)
    public func startPoint(at p: IPoint, layer: Int) -> (point: IPoint, item: Item?) {
        let item = pickSingleItem(p, net: nil, layer: -1, topLayer: layer)
        return (snapToItem(item, p), item)
    }

    /// The layer a track started on `item` goes on, `layer` the layer chosen: that one if the item is on it, else
    /// the item's first (ROUTER_TOOL::getStartLayer)
    public func startLayer(for item: Item?, layer: Int) -> Int {
        guard let item, !item.layers.overlaps(layer) else { return layer }
        return item.layers.start
    }

    /// What the track being routed ends on with the pointer at `p` (TOOL_BASE::updateEndItem): an item of its net
    /// there other than the one it started on, and where the track goes, on it; else nothing, and the grid point.
    /// Dragging, the same of the dragged net, but for the line dragged.
    public func endPoint(at p: IPoint) -> (point: IPoint, item: Item?) {
        guard router.settings.mode == .markObstacles || (router.currentNets.first ?? nil) != nil else { return (align(p), nil) }
        let layer = router.isPlacingVia ? -1 : router.currentLayer
        // (routing, the layer routed on is the top one; dragging, the one chosen)
        let top = router.state == .dragSegment ? dragLayer : router.currentLayer
        var item: Item?
        for net in router.currentNets {
            item = pickSingleItem(p, net: net, layer: layer, topLayer: top, avoid: startItem.map { [$0] } ?? [])
            if item != nil { break }
        }
        guard let item, checkSnap(item) else { return (align(p), nil) }
        return (snapToItem(item, p), item)
    }

    /// Whether the pointer snaps to `item` (TOOL_BASE::checkSnap): pads and tracks both, as KiCad's magnetic items
    /// are by default in the router tool; not, dragging, a segment of the line dragged
    private func checkSnap(_ item: Item) -> Bool {
        if startItem != nil, router.state == .dragSegment, let dragger = router.dragger, let li = item as? LinkedItem,
           dragger.originalLine.containsLink(li) {
            return false
        }
        return true
    }

    /// The item under the pointer to start or end a track on (TOOL_BASE::pickSingleItem): pads and vias first, then
    /// tracks and arcs, those on `topLayer` before those on other layers, each the nearest; of net `net` (nil: any); none
    /// that is not on `layer` (-1: any)
    func pickSingleItem(_ p: IPoint, net: NetHandle?, layer: Int, topLayer: Int, ignorePads: Bool = false,
                        avoid: [Item] = []) -> Item? {
        let tl = layer > 0 ? layer : topLayer
        let maxSlopRadius = grid
        var prioritized = [Item?](repeating: nil, count: 5)
        var dist = [Int](repeating: Int.max, count: 5)
        for slopRadius in [0, maxSlopRadius] {
            for item in router.queryHoverItems(p, slopRadius: slopRadius) {
                if !item.isRoutable || avoid.contains(where: { $0 === item }) { continue }
                if item.kind == .solid && ignorePads {
                    continue
                } else if iface.netCode(net) <= 0 || item.net == net {
                    if item.kind == .via || item.kind == .solid {
                        let d = ((item.shape(layer)?.bbox.center ?? p) - p).squaredNorm
                        if d < dist[2] {
                            prioritized[2] = item
                            dist[2] = d
                        }
                        if item.layers.overlaps(tl) && d < dist[0] {
                            prioritized[0] = item
                            dist[0] = d
                        }
                    } else if item.kind == .segment || item.kind == .arc, let li = item as? LinkedItem {
                        let d = min((li.anchor(0) - p).squaredNorm, (li.anchor(1) - p).squaredNorm)
                        if d < dist[3] {
                            prioritized[3] = item
                            dist[3] = d
                        }
                        if item.layers.overlaps(tl) && d < dist[1] {
                            prioritized[1] = item
                            dist[1] = d
                        }
                    }
                } else if item.kind == .solid && item.isFreePad {
                    // (free pads only when the pointer is inside one)
                    if item.shape(-1)?.collide(.circle(center: p, radius: 0), clearance: 0) ?? false {
                        prioritized[0] = item
                        dist[0] = 0
                    }
                } else if item.net == nil && router.settings.mode == .markObstacles {
                    // (unconnected items as a last resort, marking obstacles)
                    if item.layers.overlaps(tl) { prioritized[4] = item }
                }
            }
            if prioritized.contains(where: { $0 != nil }) { break }
        }
        for case let item? in prioritized where layer < 0 || item.layers.overlaps(layer) { return item }
        return nil
    }

    /// Where the pointer at `p` goes on `item` (TOOL_BASE::snapToItem): a pad's or via's centre (a pad's nearest
    /// anchor); a track's (or arc's) end if within half its width of the pointer, else the point of the track by the
    /// grid point nearest the pointer (AlignToSegment, AlignToArc); with no item, the grid point
    public func snapToItem(_ item: Item?, _ p: IPoint) -> IPoint {
        switch item {
        case let solid as Solid:
            guard !solid.anchorPoints.isEmpty else { return solid.anchor(0) }
            var anchor = IPoint.zero, minDist = Int.max
            for candidate in solid.anchorPoints {
                let d = (p - candidate).squaredNorm
                if d < minDist {
                    minDist = d
                    anchor = candidate
                }
            }
            return anchor
        case let via as Via:
            return via.pos
        case let seg as Segment:
            let a = seg.anchor(0), b = seg.anchor(1)
            let wSq = (seg.width / 2) * (seg.width / 2)
            let distA = (p - a).squaredNorm, distB = (p - b).squaredNorm
            if distA < wSq || distB < wSq { return distA < distB ? a : b }
            return alignToSegment(p, seg.seg)
        case let arc as Arc:
            let a = arc.anchor(0), b = arc.anchor(1)
            let wSq = (arc.width / 2) * (arc.width / 2)
            let distA = (p - a).squaredNorm, distB = (p - b).squaredNorm
            if distA < wSq || distB < wSq { return distA < distB ? a : b }
            return alignToArc(p, arc.arc)
        default:
            return align(p)
        }
    }

    /// The grid point nearest `p` (GRID_HELPER::Align, KiROUND's rounding)
    public func align(_ p: IPoint) -> IPoint {
        IPoint(Int((Double(p.x) / Double(grid)).rounded()) * grid, Int((Double(p.y) / Double(grid)).rounded()) * grid)
    }

    /// Where on `seg` the pointer at `p` goes (PCB_GRID_HELPER::AlignToSegment): its nearer end to the pointer, or
    /// where it crosses the lines across, down and diagonally through the grid point nearest the pointer, whichever
    /// is nearest
    func alignToSegment(_ p: IPoint, _ seg: Seg) -> IPoint {
        let gridSnapEpsilonSq = 4
        let aligned = align(p)
        var points: [IPoint] = []
        for d in [IPoint(1, 0), IPoint(0, 1), IPoint(1, 1), IPoint(1, -1)] {
            if let v = seg.intersectLines(Seg(aligned, aligned + d)), seg.squaredDistance(v) <= gridSnapEpsilonSq {
                points.append(v)
            }
        }
        var nearest = aligned, minDist = Int.max
        for pt in [seg.a, seg.b] {
            let d = (pt - p).squaredNorm
            if d < minDist {
                minDist = d
                nearest = pt
            }
        }
        for pt in points {
            let d = (pt - aligned).squaredNorm
            if d < minDist {
                minDist = d
                nearest = pt
            }
        }
        return nearest
    }

    /// Where on `arc` the pointer at `p` goes (PCB_GRID_HELPER::AlignToArc): its nearer end to the pointer, or where
    /// it crosses the lines across, down and diagonally through the grid point nearest the pointer, whichever is
    /// nearest
    func alignToArc(_ p: IPoint, _ arc: ShapeArc) -> IPoint {
        let aligned = align(p)
        var points: [IPoint] = []
        for d in [IPoint(1, 0), IPoint(0, 1), IPoint(1, 1), IPoint(1, -1)] {
            points += arc.intersectLine(Seg(aligned, aligned + d))
        }
        var nearest = aligned, minDist = Int.max
        for pt in [arc.start, arc.end] {
            let d = (pt - p).squaredNorm
            if d < minDist {
                minDist = d
                nearest = pt
            }
        }
        for pt in points {
            let d = (pt - aligned).squaredNorm
            if d < minDist {
                minDist = d
                nearest = pt
            }
        }
        return nearest
    }

    /// The sizes a track from `item` takes: its net class's track width (or the width of the track or arc it starts on) and
    /// via, no less than the board's minimums; a differential pair's, its net class's diff pair width and gap, the
    /// gap between its vias the same as its gap (as ImportSizes takes it from the net class's gap rule), and its vias'
    /// holes kept the board's hole to hole and hole clearances from each other (KiCad's ImportSizes)
    public func sizes(for item: Item?, net name: String? = nil) -> SizesSettings {
        var s = SizesSettings()
        let net = name ?? item?.net.flatMap { world.netNames[$0] } ?? ""
        let nc = world.netClasses.effective(net)
        s.clearance = world.rules.clearance
        s.minClearance = world.rules.clearance
        if let track = item as? LinkedItem, item?.kind == .segment || item?.kind == .arc {
            s.trackWidth = track.width
        } else {
            s.trackWidth = max(world.minTrackWidth, nc.trackWidth ?? 200_000)
        }
        s.boardMinTrackWidth = world.minTrackWidth
        s.viaDiameter = max(world.minViaDiameter, nc.viaDiameter ?? 600_000)
        s.viaDrill = max(world.minViaDrill, nc.viaDrill ?? 300_000)
        s.diffPairWidth = max(world.minTrackWidth, nc.diffPairWidth ?? 200_000)
        s.diffPairGap = max(world.rules.clearance, nc.diffPairGap ?? 250_000)
        s.diffPairViaGap = s.diffPairGap
        s.diffPairViaGapSameAsTraceGap = false
        s.holeToHole = world.rules.holeToHole
        s.diffPairHoleToHole = world.rules.holeToHole
        s.diffPairCopperToHole = world.rules.holeClearance
        return s
    }

    /// Starts a track with the pointer at `p`, `layer` the layer chosen, from what is there, as KiCad's router tool
    /// starts one (on the item's layer if it is not on that one); whether the router could start it (a start on
    /// another net's copper, or too close to it, cannot)
    @discardableResult
    public func start(at p: IPoint, layer: Int, width: Int? = nil) -> Bool {
        let (q, item) = startPoint(at: p, layer: layer)
        var s = sizes(for: item)
        if let width { s.trackWidth = width }
        router.updateSizes(s)
        iface.added.removeAll()
        iface.removedItems.removeAll()
        startItem = item
        router.mode = .routeSingle
        return router.startRouting(q, item, layer: startLayer(for: item, layer: layer))
    }

    // MARK: - Differential pairs (the router tool's Route Differential Pair)

    /// Starts a differential pair with the pointer at `p`, `layer` the layer chosen, as KiCad's router tool starts
    /// one: from the pad, via or track end there (picked as a track's start is) and the nearest of the same kind of
    /// its coupled net's (the net named as its pair's, its last P, N, + or - the other); its net class's diff pair
    /// width and gap. Whether the router could start it; if not, `failureReason` says why, as KiCad says it (no
    /// coupled net, nothing of it to start from, not at a track's end, nothing under the pointer, the gap under the
    /// board's minimum clearance, the start too close to something).
    @discardableResult
    public func startPair(at p: IPoint, layer: Int) -> Bool {
        let (q, item) = startPoint(at: p, layer: layer)
        router.updateSizes(sizes(for: item))
        iface.added.removeAll()
        iface.removedItems.removeAll()
        startItem = item
        router.mode = .routeDiffPair
        router.failureReason = ""
        return router.startRouting(q, item, layer: startLayer(for: item, layer: layer))
    }

    /// Why the router would not start the last track or pair, as KiCad's says it
    public var failureReason: String { router.failureReason }

    /// Whether what is being routed is a differential pair
    public var isRoutingPair: Bool { router.state == .routeTrack && router.mode == .routeDiffPair }

    /// The nets of the pair being routed, by name: its positive and its negative net
    public var pairNets: (positive: String, negative: String)? {
        guard isRoutingPair, router.currentNets.count == 2 else { return nil }
        let names = router.currentNets.map { $0.flatMap { world.netNames[$0] } ?? "" }
        return (names[0], names[1])
    }

    /// The pair as placed so far, for drawing: its positive and negative lines from where they were last fixed (or
    /// started) to the pointer, their width and layer, and the vias they end in if vias are being placed. (What is
    /// fixed of a pair is in the world already: KiCad commits each part as it is fixed.)
    public var pairPreview: (positive: LineChain, negative: LineChain, width: Int, gap: Int, layer: Int, viaP: IPoint?, viaN: IPoint?)? {
        guard isRoutingPair, let placer = router.diffPairPlacer else { return nil }
        let trace = placer.currentTrace
        let p = trace.pLine(), n = trace.nLine()
        // (the pair's width its sizes', until it has been routed)
        return (p.cLine, n.cLine, trace.width > 0 ? trace.width : router.sizes.diffPairWidth, router.sizes.diffPairGap,
                placer.currentLayer, p.via?.pos, n.via?.pos)
    }

    /// The pointer moved to `p`
    @discardableResult
    public func move(to p: IPoint) -> Bool {
        let (q, item) = endPoint(at: p)
        return router.move(q, item)
    }

    /// A click with the pointer at `p`: the track fixed up to there; whether it is finished (it reached its net)
    @discardableResult
    public func fix(at p: IPoint) -> Bool {
        let placingVia = router.isPlacingVia
        let (q, item) = endPoint(at: p)
        let done = router.fixRoute(q, item)
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
        let (q, item) = endPoint(at: p)
        return router.fixRoute(q, item, forceFinish: true)
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
        guard router.routingInProgress, let p = router.linePlacer else { return nil }
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

    // MARK: - Dragging (ROUTER_TOOL::performDragging)

    /// What a drag started with the pointer at `p` drags, `layer` the layer chosen (TOOL_BASE::updateStartItem, pads
    /// left out): the track or via there, picked as pickSingleItem picks it; and where the drag starts, on it
    /// (snapToItem)
    public func dragStartPoint(at p: IPoint, layer: Int) -> (point: IPoint, item: Item?) {
        let item = pickSingleItem(p, net: nil, layer: -1, topLayer: layer, ignorePads: true)
        return (snapToItem(item, p), item)
    }

    /// Starts dragging the track or via at the pointer at `p`, `layer` the layer chosen, as KiCad's router tool
    /// starts its drag (D), or its free angle drag (G) with `freeAngle`: a track's segment, or its corner where the
    /// pointer is at one of its ends; whether there was one to drag. (A locked one is dragged, as KiCad's "Drag
    /// Anyway" drags it.)
    @discardableResult
    public func startDrag(at p: IPoint, layer: Int, freeAngle: Bool = false) -> Bool {
        let (q, item) = dragStartPoint(at: p, layer: layer)
        iface.added.removeAll()
        iface.removedItems.removeAll()
        startItem = item
        dragLayer = layer
        draggedLocked = item?.isLocked ?? false
        return router.startDragging(q, item, mode: freeAngle ? [.any, .freeAngle] : .any)
    }

    /// What was dragged: a via (not a track's corner where its width changes, which drags as one)
    public var isDraggingVia: Bool { (startItem as? Via).map { !$0.isVirtual } ?? false }

    /// What the drag has moved, as KiCad's router shows it (the dragger's current node): the board's tracks and vias
    /// it takes away (their ids), the tracks and vias that go in their place, the dragged and the shoved; and whether
    /// what is dragged collides with something, the drag marking obstacles since it could not get past them (KiCad's
    /// "Track violates DRC", which a click keeps only if forced)
    public var dragged: (moved: Set<String>, items: [Item], violates: Bool)? {
        guard router.state == .dragSegment, let dragger = router.dragger else { return nil }
        let (removed, added) = dragger.currentNode.updatedItems()
        let moved = Set(removed.compactMap { iface.resolver.info[ObjectIdentifier($0)]?.source })
        return (moved, added.filter { !$0.isVirtual && ($0.kind == .segment || $0.kind == .arc || $0.kind == .via) },
                dragger.forceMarkObstaclesMode && !dragger.dragStatus)
    }

    /// A click with the pointer at `p`, dragging: the drag kept, if the dragger keeps it (where it last got past what
    /// was in its way; marking obstacles, only if clear of them, or if `force`d, as with Ctrl), written into the
    /// board; whether it was. If not, the drag goes on.
    @discardableResult
    public func fixDrag(at p: IPoint, force: Bool = false) -> Bool {
        guard router.state == .dragSegment else { return false }
        let (q, item) = endPoint(at: p)
        guard router.fixRoute(q, item, forceCommit: force) else { return false }
        router.stopRouting()
        apply()
        return true
    }

    /// The drag dropped; what it unlocked to drag locked again (the world read again)
    public func cancelDrag() {
        cancel()
        if draggedLocked { reload() }
        draggedLocked = false
    }

    /// The track dropped. A pair dropped with what was fixed of it, which the router has in its world already (KiCad
    /// keeps it, as `commit` does): the world read again from the board, which has none of it.
    public func cancel() {
        let fixedPair = isRoutingPair && (!iface.added.isEmpty || !iface.removedItems.isEmpty)
        router.stopRouting()
        iface.added.removeAll()
        iface.removedItems.removeAll()
        if fixedPair { reload() }
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
            } else if let a = item as? Arc {
                lastAdded.append(insert(arc: a))
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

    /// An arc track as KiCad writes one (PCB_IO_KICAD_SEXPR::format of a PCB_ARC): its start, the middle of the arc
    /// and its end, as PNS_KICAD_IFACE::createBoardItem makes the PCB_ARC of the router's arc (SHAPE_ARC::GetArcMid)
    private func insert(arc a: Arc) -> String {
        let uuid = KiCadBoard.newUUID()
        let start = a.arc.start, mid = a.arc.mid, end = a.arc.end
        let node = SExpr("arc", SExpr("start", Self.mm(start.x), Self.mm(start.y)), SExpr("mid", Self.mm(mid.x), Self.mm(mid.y)),
                         SExpr("end", Self.mm(end.x), Self.mm(end.y)), SExpr("width", Self.mm(a.width)), SExpr("layer", layerName(a.layer)),
                         netList(a.net), SExpr("uuid", uuid))
        insertTrack(node)
        return uuid
    }

    private func insert(via v: Via, free: Bool = false) -> String {
        let uuid = KiCadBoard.newUUID()
        let node = SExpr("via", SExpr("at", Self.mm(v.pos.x), Self.mm(v.pos.y)), SExpr("size", Self.mm(v.diameter)), SExpr("drill", Self.mm(v.drill)),
                         SExpr("layers", layerName(v.layers.start), layerName(v.layers.end)), netList(v.net), SExpr("uuid", uuid))
        // (KiCad writes a free via's flag after its layers, and a via's type, but a through via's, after "via")
        if free { node.items.insert(SExpr("free", Keyword("yes")), at: 5) }
        switch v.viaType {
        case .blind: node.items.insert(SExpr(symbol: "blind"), at: 1)
        case .buried: node.items.insert(SExpr(symbol: "buried"), at: 1)
        case .microVia: node.items.insert(SExpr(symbol: "micro"), at: 1)
        case .through: break
        }
        insertTrack(node)
        return uuid
    }

    /// A track or via put after the board's others, as KiCad keeps them
    private func insertTrack(_ node: SExpr) { board.addCopper(node) }
}
