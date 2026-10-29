// A board edited here, a track at a time, as KiCad's router tool drives its router (pcbnew/router/router_tool.cpp,
// KiCad 10.0.7): magnetic pads, the start layer taken from a one-sided pad, a click fixing the track, a double click
// finishing it, Escape keeping what is fixed; differential pairs routed as its Route Differential Pair routes them;
// tracks and vias dragged as its drag tools drag them. GNU General Public License version 3 or later, as the router
// (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// A board edited in the PCB view: the router on it, driven as a pointer drives it (start, move, fix, finish, vias,
/// layers, postures, widths), tracks and vias dragged, and tracks and vias taken away. Each change made is handed back
/// as the board before and after it, for the board's file or KiCad's open editor to take; the board here is then the
/// board after it.
public final class BoardEditing {
    /// A change made to the board
    public struct Edit {
        public let before: KiCadBoard
        public let after: KiCadBoard
        /// The tracks and vias made, and those taken away, by id
        public let added: [String]
        public let removed: [String]
        /// The footprints moved, turned or turned over, by id
        public var footprints: [String] = []
        /// The zones added or taken away, by id
        public var zones: [String] = []
        /// The tracks and vias changed in place (their widths, sizes), or placed on their own (a via, the halves of the
        /// track it splits), by id
        public var changed: [String] = []
        /// The board's own texts and drawings added, changed or taken away, by id
        public var drawings: [String] = []
        /// Whether the board's outline changed
        public var outline = false
        /// Whether the board's setup changed: its copper layers, its stackup (setCopperLayerCount)
        public var setup = false
        /// Whether the board's zones were filled again with it (refillsZones)
        public var refilled = false
        /// The board's teardrop settings as the change left them, where it changed them (for its project's board
        /// design settings: TeardropSettings.projectSettings)
        public var teardropSettings: TeardropSettings?
        /// The tuning patterns made, changed or taken away, by id
        public var generators: [String] = []
        /// What it was, for an undo menu (and KiCad's own)
        public let name: String
    }

    /// The track being routed, as it is drawn: its fixed part, the part following the pointer (their arcs as the
    /// polylines a track's chain keeps of them, a micrometre off), its width and layer,
    /// the via at its end if one is to be placed, its net, and where it should go next
    public struct Preview: Sendable, Equatable {
        public var tail: [KiCadPoint]
        public var head: [KiCadPoint]
        public var width: Double
        public var layer: String
        public var via: KiCadPoint?
        public var viaSize: Double
        public var net: String?
        public var target: KiCadPoint?
        /// What the track has shoved aside (shoving): the board's tracks and vias it moved, by id, and where they go now
        public var moved: Set<String> = []
        public var shovedTracks: [Track] = []
        public var shovedVias: [Via] = []

        public struct Track: Sendable, Equatable {
            public var points: [KiCadPoint]
            public var width: Double
            public var layer: String
        }

        public struct Via: Sendable, Equatable {
            public var center: KiCadPoint
            public var size: Double
        }
    }

    /// What is being dragged, as it is drawn: the board's tracks and vias the drag takes away (moved, or shoved aside),
    /// by id, and where they go now, the dragged with the shoved; the net dragged; and whether what is dragged collides
    /// with something (KiCad's "Track violates DRC": the drag could not get past it, and a click keeps it only if
    /// forced)
    public struct DragPreview: Sendable, Equatable {
        public var moved: Set<String> = []
        public var tracks: [Preview.Track] = []
        public var vias: [Preview.Via] = []
        public var net: String?
        public var violates = false

        public init(moved: Set<String> = [], tracks: [Preview.Track] = [], vias: [Preview.Via] = [], net: String? = nil,
                    violates: Bool = false) {
            (self.moved, self.tracks, self.vias, self.net, self.violates) = (moved, tracks, vias, net, violates)
        }
    }

    /// The differential pair being routed, as it is drawn: its positive and negative lines from where they were last
    /// fixed (or started) to the pointer (what is fixed is on the board already, as KiCad commits each part as it is
    /// fixed), their width, gap and layer, the vias they end in if vias are being placed, their nets, whether the
    /// pair got to the pointer clear of everything, and what it has shoved aside (shoving), as a track's preview
    public struct PairPreview: Sendable, Equatable {
        public var positive: [KiCadPoint]
        public var negative: [KiCadPoint]
        public var width: Double
        public var gap: Double
        public var layer: String
        public var positiveVia: KiCadPoint?
        public var negativeVia: KiCadPoint?
        public var viaSize: Double
        public var positiveNet: String
        public var negativeNet: String
        public var clear: Bool
        public var moved: Set<String> = []
        public var shovedTracks: [Preview.Track] = []
        public var shovedVias: [Preview.Via] = []
    }

    /// How a track started here gets past what is in its way: walks round it (KiCad's default), or shoves it aside;
    /// a drag too. Routing every connection walks round.
    public var mode: RouterMode = .walkaround

    /// How a track started here turns its corners (KiCad's track corner modes): mitred at 45° (KiCad's default) or
    /// 90°, or rounded with an arc, which goes into the board as an arc track; a pair and a drag too
    public var cornerMode: Direction45.CornerMode = .mitered45

    /// Whether each change fills the board's zones again, as KiCad's zone filler fills them (ZoneFiller), where the
    /// board has zones and nothing the filler does not fill yet; the router goes on from the board as filled. Off,
    /// the zones keep their fills until they are filled again elsewhere (KiCad's editor fills its own).
    public var refillsZones = false
    /// Whether the last change filled the zones again
    private var lastRefilled = false

    /// The pre-defined track width and via size tracks are routed with, and vias placed with (KiCad's track width
    /// menu): the net class's (0), or the project's (BoardSetup.swift)
    public var sizeChoice = SizeChoice()

    public private(set) var router: BoardRouter {
        didSet { router.patternMemory = patternMemory }
    }
    var project: [String: Any]?
    /// The board as the last change left it (each change is made from it)
    private var base: KiCadBoard

    /// `board` is the board as it is: the session works on a copy of it, and leaves it as it is
    public init(board: KiCadBoard, project: [String: Any]? = nil) {
        self.project = project
        let memory = TuningPatternMemory()
        base = board.copy()
        memory.read(base)
        patternMemory = memory
        router = BoardRouter(board: base.copy(), project: project)
        router.patternMemory = memory
    }

    /// The board's tuning patterns as KiCad has them once it has read the board (as read, which it writes so when it
    /// next saves the board: lengths cut to the nanometre, patterns of no members dropped), and those the session
    /// makes as KiCad makes them
    private var patternMemory = TuningPatternMemory()

    /// JSpice's own design rules check of the board as the last change left it (BoardDRC: KiCad's checks of copper,
    /// widths, holes, the board's edges and connections), ready to run (on a copy of the board, anywhere)
    public func designRulesCheck() -> BoardDRC { BoardDRC(board: base.copy(), project: project) }

    /// The board read anew (changed elsewhere: in KiCad, or by the schematic's update); a track being routed is
    /// dropped. `project` nil keeps the project's settings as they were.
    public func load(_ board: KiCadBoard, project: [String: Any]? = nil) {
        var rulesChanged = false
        if let project {
            rulesChanged = !NSDictionary(dictionary: project).isEqual(to: self.project ?? [:])
            self.project = project
        }
        let memory = TuningPatternMemory()
        let read = board.copy()
        memory.read(read)
        if read.text == base.text && !rulesChanged && !router.router.routingInProgress { return }
        router.cancel()
        patternSession = nil
        base = read
        patternMemory = memory
        router = BoardRouter(board: base.copy(), project: self.project)
    }

    /// The board as it now is
    public var board: KiCadBoard { router.board }

    public var isRouting: Bool { router.router.routingInProgress }

    /// The board's copper layers, front to back
    public var layers: [String] { router.world.layerIndex.sorted { $0.value < $1.value }.map(\.key) }

    static func nm(_ p: KiCadPoint) -> IPoint { IPoint(Int((p.x * 1e6).rounded()), Int((p.y * 1e6).rounded())) }
    static func mm(_ p: IPoint) -> KiCadPoint { KiCadPoint(Double(p.x) / 1e6, Double(p.y) / 1e6) }

    /// Where the pointer at `p` routes to, as KiCad's router tool snaps it (its magnetic pads and tracks): starting,
    /// the centre of the pad or via under it, or a track's end or the point of the track by the grid; routing, the
    /// same of the track's net; else `p` on a 0.05 mm grid
    public func snap(_ p: KiCadPoint, layer: String) -> IPoint {
        let q = Self.nm(p)
        if isRouting { return router.endPoint(at: q).point }
        return router.startPoint(at: q, layer: router.layer(layer) ?? 0).point
    }

    /// The layer a track started at `p` goes on: `layer`, unless what it starts on is only on another
    public func startLayer(at p: KiCadPoint, preferring layer: String) -> String {
        guard let l = router.layer(layer) else { return layer }
        return router.layerName(router.startLayer(for: router.startPoint(at: Self.nm(p), layer: l).item, layer: l))
    }

    // MARK: - Routing

    /// Starts a track at `p` on `layer` (width in mm, nil for its net class's); whether it could (not on another
    /// net's copper, nor too close to it)
    public func start(at p: KiCadPoint, layer: String, width: Double? = nil) -> Bool {
        start(at: p, layer: layer, width: width, mode: mode)
    }

    private func start(at p: KiCadPoint, layer: String, width: Double?, mode: RouterMode) -> Bool {
        router.mode = mode
        router.cornerMode = cornerMode
        guard let l = router.layer(layer) else { return false }
        // (a pre-defined size chosen, as ImportSizes takes the board's current one)
        return router.start(at: Self.nm(p), layer: l, width: width.map { Int(($0 * 1e6).rounded()) } ?? chosenTrackWidth(),
                            via: chosenViaSize())
    }

    /// The pointer moved to `p`: the track as it now goes
    @discardableResult
    public func move(to p: KiCadPoint) -> Preview? {
        guard isRouting else { return nil }
        router.move(to: Self.nm(p))
        return preview
    }

    /// A click at `p`: the track (or pair) fixed up to there; the change, if that finished it (it reached its net, or
    /// the pair the pads, vias or track ends of its nets there)
    public func fix(at p: KiCadPoint) -> Edit? {
        guard isRouting else { return nil }
        let name = routeName
        return router.fix(at: Self.nm(p)) ? commit(name) : nil
    }

    /// A double click at `p`: the track (or pair) fixed there and finished, whether or not it reached its net
    public func finish(at p: KiCadPoint) -> Edit? {
        guard isRouting else { return nil }
        let name = routeName
        let q = Self.nm(p)
        router.move(to: q)
        _ = router.finish(at: q)
        return commit(name)
    }

    /// The track routed on to the nearest pad or track of its net it is not joined to, and finished there, if it
    /// gets there (KiCad's End)
    public func finishToRatsnest() -> Edit? {
        guard isRouting else { return nil }
        let name = routeName
        guard router.finishToRatsnest() else { return nil }
        return commit(name)
    }

    /// Routing stopped, what is fixed of the track (or pair) kept (KiCad's Escape)
    public func stop() -> Edit? {
        guard isRouting else { return nil }
        return commit(routeName)
    }

    /// The track (or pair) dropped, fixed parts and all
    public func cancel() { router.cancel() }

    /// What routing it is, for the change it makes (KiCad's names for them)
    private var routeName: String { router.isRoutingPair ? "Route Differential Pair" : "Route Track" }

    /// A via at the track's end, to `layer` (the other side if nil), and the track on from it there: placed at the
    /// next click
    @discardableResult
    public func placeVia(to layer: String? = nil) -> Preview? {
        guard isRouting else { return nil }
        router.placeVia(to: layer.flatMap(router.layer))
        return preview
    }

    @discardableResult
    public func flipPosture() -> Preview? {
        guard isRouting else { return nil }
        router.flipPosture()
        return preview
    }

    /// The last fixed part of the track taken back
    @discardableResult
    public func undoSegment() -> Preview? {
        guard isRouting else { return nil }
        _ = router.undo()
        return preview
    }

    /// The track's width from here on, in mm (nil: its net class's)
    @discardableResult
    public func setWidth(_ width: Double?) -> Preview? {
        guard isRouting else { return nil }
        router.setWidth(width.map { Int(($0 * 1e6).rounded()) })
        return preview
    }

    /// The net of the track being routed
    public var routedNet: String? { router.routedNet }

    public var preview: Preview? {
        guard let p = router.preview else { return nil }
        var shown = Preview(tail: p.tail.points.map(Self.mm), head: p.head.points.map(Self.mm), width: Double(p.width) / 1e6,
                            layer: router.layerName(p.layer), via: p.via.map(Self.mm),
                            viaSize: Double(router.router.sizes.viaDiameter) / 1e6, net: router.routedNet,
                            target: router.target.map(Self.mm))
        let shoved = router.shoved
        shown.moved = shoved.moved
        for item in shoved.items {
            if let track = track(item) {
                shown.shovedTracks.append(track)
            } else if let v = item as? Via {
                shown.shovedVias.append(.init(center: Self.mm(v.pos), size: Double(v.diameter) / 1e6))
            }
        }
        return shown
    }

    /// A segment or arc of what the router has moved, as it is drawn: a segment's two ends, an arc's points as a
    /// track's chain keeps them (a polyline a micrometre off it)
    func track(_ item: Item) -> Preview.Track? {
        let points: [IPoint]
        guard let li = item as? LinkedItem else { return nil }
        if let s = item as? Segment {
            points = [s.seg.a, s.seg.b]
        } else if let a = item as? Arc {
            points = a.cLine.points
        } else {
            return nil
        }
        return .init(points: points.map(Self.mm), width: Double(li.width) / 1e6, layer: router.layerName(item.layers.start))
    }

    // MARK: - Differential pairs

    /// Starts a differential pair at `p` on `layer` (KiCad's Route Differential Pair): from the pad, via or track end
    /// there and the nearest of its coupled net's, its net class's diff pair width and gap. Nil if the router will not
    /// start it, `failureReason` saying why as KiCad says it (no coupled net, nothing of it to start from...).
    /// `fix`, `finish`, `stop`, `placeVia`, `flipPosture` and `cancel` go on with it as with a track, each part fixed
    /// committed at once as KiCad commits it ("Route Differential Pair").
    public func startPair(at p: KiCadPoint, layer: String) -> PairPreview? {
        guard !isRouting, let l = router.layer(layer) else { return nil }
        router.mode = mode
        router.cornerMode = cornerMode
        guard router.startPair(at: Self.nm(p), layer: l) else { return nil }
        return pairPreview(clear: true)
    }

    /// Why the router would not start the last track or pair, as KiCad's says it
    public var failureReason: String { router.failureReason }

    /// Whether a differential pair is being routed
    public var isRoutingPair: Bool { router.isRoutingPair }

    /// The pair as it now goes (after a fix, a via or a posture flip), as clear of everything
    public var currentPairPreview: PairPreview? { isRoutingPair ? pairPreview(clear: true) : nil }

    /// The pointer moved to `p`: the pair as it now goes
    @discardableResult
    public func movePair(to p: KiCadPoint) -> PairPreview? {
        guard isRoutingPair else { return nil }
        let clear = router.move(to: Self.nm(p))
        return pairPreview(clear: clear)
    }

    /// Vias at the pair's ends, to `layer` (the other side if nil), the pair on from them there: placed at the next
    /// click
    @discardableResult
    public func placePairVias(to layer: String? = nil) -> PairPreview? {
        guard isRoutingPair else { return nil }
        router.placeVia(to: layer.flatMap(router.layer))
        return pairPreview(clear: true)
    }

    private func pairPreview(clear: Bool) -> PairPreview? {
        guard let p = router.pairPreview, let nets = router.pairNets else { return nil }
        var shown = PairPreview(positive: p.positive.points.map(Self.mm), negative: p.negative.points.map(Self.mm),
                                width: Double(p.width) / 1e6, gap: Double(p.gap) / 1e6, layer: router.layerName(p.layer),
                                positiveVia: p.viaP.map(Self.mm), negativeVia: p.viaN.map(Self.mm),
                                viaSize: Double(router.router.sizes.viaDiameter) / 1e6, positiveNet: nets.positive,
                                negativeNet: nets.negative, clear: clear)
        let shoved = router.shoved
        shown.moved = shoved.moved
        // (the shove's branch holds the pair's own lines too, which the preview has)
        let own = router.router.currentNets
        for item in shoved.items where !own.contains(item.net) {
            if let track = track(item) {
                shown.shovedTracks.append(track)
            } else if let v = item as? Via {
                shown.shovedVias.append(.init(center: Self.mm(v.pos), size: Double(v.diameter) / 1e6))
            }
        }
        return shown
    }

    // MARK: - Dragging

    /// Starts dragging the track or via at `p` on `layer` (the one a track is on is taken first), as KiCad's drag (D)
    /// drags it, or its free angle drag (G) with `freeAngle`: a track's segment, its two neighbours stretched to
    /// follow on the 45° directions, or its corner if `p` is at one of its ends, or a via with the tracks on it.
    /// Nil if there is nothing there to drag.
    public func startDrag(at p: KiCadPoint, layer: String, freeAngle: Bool = false) -> DragPreview? {
        guard !isRouting, let l = router.layer(layer) else { return nil }
        router.mode = mode
        router.cornerMode = cornerMode
        guard router.startDrag(at: Self.nm(p), layer: l, freeAngle: freeAngle) else { return nil }
        return dragPreview
    }

    /// The pointer moved to `p`, dragging: what is dragged as it now goes
    @discardableResult
    public func drag(to p: KiCadPoint) -> DragPreview? {
        guard router.router.state == .dragSegment else { return nil }
        router.move(to: Self.nm(p))
        return dragPreview
    }

    /// A click at `p`, dragging: the change, if the drag is kept ("Drag Track", "Drag Via"); kept where it last got
    /// past what was in its way, or, where it could not get past it, only if `force`d (KiCad's Ctrl-click). Nil, the
    /// drag going on, if not.
    public func fixDrag(at p: KiCadPoint, force: Bool = false) -> Edit? {
        guard router.router.state == .dragSegment else { return nil }
        let name = router.isDraggingVia ? "Drag Via" : "Drag Track"
        guard router.fixDrag(at: Self.nm(p), force: force) else { return nil }
        return change(name)
    }

    /// The drag dropped, the board as it was
    public func cancelDrag() { router.cancelDrag() }

    public var dragPreview: DragPreview? {
        guard let d = router.dragged else { return nil }
        var shown = DragPreview(moved: d.moved, net: (router.router.currentNets.first ?? nil).flatMap { router.world.netNames[$0] },
                                violates: d.violates)
        for item in d.items {
            if let track = track(item) {
                shown.tracks.append(track)
            } else if let v = item as? Via {
                shown.vias.append(.init(center: Self.mm(v.pos), size: Double(v.diameter) / 1e6))
            }
        }
        return shown
    }

    // MARK: - Length tuning (TuningPatternEditing.swift)

    /// The tuning pattern being placed or edited, as KiCad's Tune Length tool and point editor hold it
    var patternSession: PatternSession?

    // MARK: - Routing every connection

    /// What routing the connections left
    public struct Routed {
        /// The connections routed, and those the router could not get through ("net: R1.1 to C2.2")
        public var routed: [String] = []
        public var failed: [String] = []
        /// The connections still to route after
        public var left = 0
        /// The change, all the tracks as one
        public var edit: Edit?
    }

    /// The connections still to route, each routed as a person would route it: started on one end, the pointer taken
    /// to the other, clicked there; on `layer` (or the side a one-sided pad is on), then on the other side if the
    /// router cannot get through. `nets` limits them to those nets (nil: every net), `skip` leaves those out (a net
    /// for a pour). One change.
    public func routeConnections(nets: Set<String>? = nil, skip: Set<String> = [], layer: String = "F.Cu", width: Double? = nil,
                                 most: Int = 500) -> Routed {
        var out = Routed()
        guard !isRouting else { return out }
        let start = base
        var added: [String] = [], removed: [String] = []
        var tried = Set<KiCadConnectivity.Airwire>()
        // (the zones filled again once, after the last connection, not after each)
        let refills = refillsZones
        refillsZones = false
        defer { refillsZones = refills }
        var wires = KiCadConnectivity(router.board).ratsnest()
        func wanted(_ w: KiCadConnectivity.Airwire) -> Bool { (nets?.contains(w.net) ?? true) && !skip.contains(w.net) }
        while out.routed.count + out.failed.count < most, let wire = wires.first(where: { wanted($0) && !tried.contains($0) }) {
            tried.insert(wire)
            let name = "\(wire.net): \(wire.ends.isEmpty ? "tracks" : wire.ends.joined(separator: " to "))"
            if let (a, r) = route(wire, layer: layer, width: width) {
                added += a
                removed += r
                out.routed.append(name)
            } else {
                out.failed.append(name)
            }
            wires = KiCadConnectivity(router.board).ratsnest()
        }
        out.left = wires.count
        if !added.isEmpty || !removed.isEmpty {
            let n = out.routed.count
            let filled = refills ? refilled(base) : nil
            if let filled {
                base = filled
                router = BoardRouter(board: base.copy(), project: project)
            }
            out.edit = Edit(before: start, after: base, added: added, removed: removed,
                            name: n == 1 ? "Route 1 Connection" : "Route \(n) Connections")
            out.edit?.refilled = filled != nil
        }
        return out
    }

    /// One connection still to route (a line of the ratsnest) routed, as routeConnections routes each, as one change;
    /// nil if the router cannot get it through on either side
    public func routeConnection(_ wire: KiCadConnectivity.Airwire, layer: String = "F.Cu", width: Double? = nil) -> Edit? {
        guard !isRouting else { return nil }
        let start = base
        guard let (added, removed) = route(wire, layer: layer, width: width) else { return nil }
        var edit = Edit(before: start, after: base, added: added, removed: removed, name: "Route Connection")
        edit.refilled = lastRefilled
        return edit
    }

    /// A track from one end of `wire` to the other, on `layer` (the side a one-sided pad is on), else on the other
    /// side: what it added and took away
    private func route(_ wire: KiCadConnectivity.Airwire, layer: String, width: Double?) -> (added: [String], removed: [String])? {
        let other = layers.first { $0 != layer } ?? layer
        for l in (layer == other ? [layer] : [layer, other]) {
            guard start(at: wire.from, layer: startLayer(at: wire.from, preferring: l), width: width, mode: .walkaround) else { continue }
            move(to: wire.to)
            if let edit = fix(at: wire.to) { return (edit.added, edit.removed) }
            cancel()
        }
        return nil
    }

    // MARK: - Changes

    /// The tracks' and arcs' width, and the vias' diameter and drill, of those given set (mm; nil leaves it as it
    /// is), as KiCad's Edit Track & Via Properties sets them: one change, nil if none of them changes. A via with a
    /// padstack of its own (its sizes by layer) is left as it is.
    public func setSizes(_ uuids: Set<String>, width: Double? = nil, viaDiameter: Double? = nil, viaDrill: Double? = nil) -> Edit? {
        guard !isRouting else { return nil }
        if let width, width <= 0 { return nil }
        if let d = viaDiameter, d <= 0 { return nil }
        if let d = viaDrill, d <= 0 { return nil }
        var changed: [String] = []
        for node in router.board.copperItems {
            guard let uuid = node.value("uuid"), uuids.contains(uuid) else { continue }
            let was = node.compact
            switch node.head {
            case "segment", "arc":
                if let width { node.set(SExpr("width", width), after: ["end", "mid"]) }
            case "via":
                guard node["padstack"] == nil else { continue }
                if let d = viaDiameter { node.set(SExpr("size", d), after: ["at"]) }
                if let d = viaDrill { node.set(SExpr("drill", d), after: ["size", "at"]) }
            default:
                continue
            }
            if node.compact != was { changed.append(uuid) }
        }
        guard !changed.isEmpty else { return nil }
        router.boardChanged()
        let vias = router.board.copperItems.filter { $0.head == "via" && changed.contains($0.value("uuid") ?? "") }.count
        let name = vias == 0 ? (changed.count == 1 ? "Change Track Width" : "Change Track Widths")
            : vias == changed.count ? (vias == 1 ? "Change Via Size" : "Change Via Sizes") : "Change Track and Via Sizes"
        return change(name, changed: changed)
    }

    /// Tracks and vias taken away, by id (and the board's own texts and drawings of those ids)
    public func remove(_ uuids: Set<String>) -> Edit? {
        let drawings = router.board.boardDrawings.filter { uuids.contains($0.value("uuid") ?? "") }
        if !drawings.isEmpty {
            for node in drawings { router.board.root.remove(node) }
            router.boardChanged()
        }
        let copper = uuids.subtracting(drawings.compactMap { $0.value("uuid") })
        if !copper.isEmpty { router.remove(copper) }
        let name = drawings.isEmpty ? (uuids.count == 1 ? "Delete Track" : "Delete Tracks") : uuids.count == 1 ? "Delete" : "Delete Items"
        return change(name, drawings: drawings.compactMap { $0.value("uuid") })
    }

    private func commit(_ name: String) -> Edit? {
        router.commit()
        return change(name)
    }

    func change(_ name: String, footprints: [String] = [], zones: [String] = [], outline: Bool = false,
                        changed: [String] = [], drawings: [String] = [], setup: Bool = false) -> Edit? {
        let generators = Self.generatorsChanged(base, router.board)
        guard !router.lastAdded.isEmpty || !router.lastRemoved.isEmpty || !footprints.isEmpty || !zones.isEmpty || outline
                || !changed.isEmpty || !drawings.isEmpty || setup || !generators.isEmpty else { return nil }
        var after = router.board.copy()
        let (added, removed) = (router.lastAdded, router.lastRemoved)
        // (not while a track or pair is still being routed, which goes on in the router as it is)
        let filled = refillsZones && !router.router.routingInProgress ? refilled(after) : nil
        if let filled {
            after = filled
            router = BoardRouter(board: after.copy(), project: project)
        }
        var edit = Edit(before: base, after: after, added: added, removed: removed, name: name)
        edit.footprints = footprints
        edit.zones = zones
        edit.outline = outline
        edit.changed = changed
        edit.drawings = drawings
        edit.setup = setup
        edit.generators = generators
        edit.refilled = filled != nil
        lastRefilled = edit.refilled
        base = after
        return edit
    }

    /// `board` with its zones filled again as KiCad's zone filler fills them; nil where it has no zones, or has what
    /// the filler does not fill yet
    private func refilled(_ board: KiCadBoard) -> KiCadBoard? {
        guard board.zones.contains(where: { !$0.isRuleArea }) else { return nil }
        let filler = ZoneFiller(board: board, project: project)
        guard filler.unsupported.isEmpty else { return nil }
        return filler.refilledBoard(board)
    }

    /// Stitching vias for `net`'s pours: a via every `pitch` (mm, on whole multiples of it) where the net's pours
    /// are filled on both the top and the bottom with room round the via, and where the router finds it clear of
    /// everything else, as one change (KiCad then fills the pours again round them); none within half a pitch of one
    /// of the net's vias there already. nil when there is nowhere to put one (the pours unfilled: KiCad fills them).
    public func stitchVias(net: String, pitch: Double = 5) -> Edit? {
        guard !isRouting, pitch > 0, let top = layers.first, let bottom = layers.last, top != bottom,
              let box = router.board.edgeBounds else { return nil }
        let board = router.board
        var fills: [String: [[KiCadPoint]]] = [:]
        for zone in board.zones where zone.net == net && !zone.isRuleArea {
            for fill in zone.fills { fills[fill.layer, default: []].append(fill.points) }
        }
        let size = router.sizes(for: nil, net: net)
        let reach = Double(size.viaDiameter) / 2e6
        func inside(_ p: KiCadPoint, _ layer: String) -> Bool {
            (fills[layer] ?? []).contains { poly in
                KiCadPolygon.contains(poly, p) && zip(poly, poly.dropFirst() + poly.prefix(1)).allSatisfy { Self.distance(p, $0, $1) >= reach }
            }
        }
        let vias = board.vias.filter { $0.net == net }.map(\.position)
        var points: [IPoint] = []
        var y = (box.minY / pitch).rounded(.up) * pitch
        while y <= box.maxY {
            var x = (box.minX / pitch).rounded(.up) * pitch
            while x <= box.maxX {
                let p = KiCadPoint(x, y)
                if inside(p, top) && inside(p, bottom) && !vias.contains(where: { $0.distance(to: p) < pitch / 2 }) {
                    points.append(IPoint(Int((x * 1e6).rounded()), Int((y * 1e6).rounded())))
                }
                x += pitch
            }
            y += pitch
        }
        guard !router.placeVias(net: net, at: points).isEmpty else { return nil }
        return change("Stitch \(net) Pours")
    }

    /// How far `p` is from the segment from `a` to `b` (mm)
    private static func distance(_ p: KiCadPoint, _ a: KiCadPoint, _ b: KiCadPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        let t = length == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: - Pours

    /// The board's ground nets, those whose names say so (GND, AGND, GND_1…)
    public var groundNets: [String] { Set(router.world.netNames.values).filter { $0.uppercased().contains("GND") }.sorted() }

    /// A copper pour of `net` over the whole board on `layers` (the box round its outline: KiCad keeps the copper
    /// inside the edge, at the edge clearance), as one change; empty until KiCad fills it
    public func addPour(net: String, layers: [String]) -> Edit? {
        guard !isRouting, !layers.isEmpty, let box = router.board.edgeBounds ?? router.board.itemBounds else { return nil }
        let outline = [KiCadPoint(box.minX, box.minY), KiCadPoint(box.maxX, box.minY), KiCadPoint(box.maxX, box.maxY),
                       KiCadPoint(box.minX, box.maxY)]
        let uuid = router.board.addPour(net: net, layers: layers, outline: outline)
        router.boardChanged()
        return change("Add \(net) Pour", zones: [uuid])
    }

    /// A zone of `net` drawn by hand on `layers`, its corners `outline` (mm, three or more), as KiCad's Add Filled
    /// Zone draws one: kept clear of other nets' copper and joined to the net's pads by thermal reliefs as a pour is,
    /// filled over those of lower `priority` (KiCad's zone priority)
    public func addZone(net: String, layers: [String], outline: [KiCadPoint], priority: Int = 0) -> Edit? {
        guard !isRouting, !layers.isEmpty, outline.count >= 3 else { return nil }
        let uuid = router.board.addPour(net: net, layers: layers, outline: outline, priority: priority)
        router.boardChanged()
        return change("Add \(net) Zone", zones: [uuid])
    }

    /// A rule area drawn by hand on `layers`, its corners `outline` (mm, three or more), as KiCad's Add Rule Area
    /// draws one: what it keeps out (tracks, vias, pads, pours, footprints) the router, the pours and the board's
    /// check keep out of it
    public func addRuleArea(layers: [String], outline: [KiCadPoint], keepout: KiCadBoard.Keepout = .init()) -> Edit? {
        guard !isRouting, !layers.isEmpty, outline.count >= 3 else { return nil }
        let uuid = router.board.addRuleArea(layers: layers, outline: outline, keepout: keepout)
        router.boardChanged()
        return change("Add Rule Area", zones: [uuid])
    }

    /// Zones taken away, by id
    public func removeZones(_ uuids: Set<String>) -> Edit? {
        let gone = router.board.zones.filter { uuids.contains($0.uuid) }
        guard !isRouting, !gone.isEmpty else { return nil }
        for zone in gone { router.board.root.remove(zone.node) }
        router.boardChanged()
        return change(gone.count == 1 ? "Delete Pour" : "Delete Pours", zones: gone.map(\.uuid))
    }

    // MARK: - Teardrops

    /// The board's teardrop settings, as its project keeps them (KiCad's defaults where it has none)
    public var teardropSettings: TeardropSettings { TeardropSettings(project: project) }

    /// Teardrops added as one change, as KiCad's Set Teardrops dialog adds them with the default values for each
    /// shape: `settings` (the board's for round shapes, other shapes and track ends, and what they go on) put on the
    /// vias and pads they are asked for, and the board's teardrops all made again from them as KiCad's teardrop
    /// manager makes them (Teardrops), its zones then filled again if refillsZones; nil when that changes nothing,
    /// or the board has what the port does not make teardrops round yet. The project's settings change with it
    /// (the edit's teardropSettings); the edit's zones are the teardrops made and taken away, by the keys the zone
    /// filler keeps them by ("zone #N": KiCad writes teardrops without uuids).
    public func addTeardrops(settings: TeardropSettings) -> Edit? {
        guard !isRouting else { return nil }
        let board = router.board.copy()
        let kept = Teardrops.applySettings(settings, to: board)
        let made = Teardrops(board: board, project: project, settings: kept)
        guard made.unsupported.isEmpty else { return nil }
        return replaceTeardrops(made.board(board), kept, "Add Teardrops")
    }

    /// Every teardrop taken away as one change, as the Set Teardrops dialog's "remove all teardrops": the pads' and
    /// vias' teardrops turned off and the track ends', and the board's teardrops gone; nil when it has none and none
    /// are on
    public func removeTeardrops() -> Edit? {
        guard !isRouting else { return nil }
        let board = router.board.copy()
        let kept = Teardrops.disableAll(on: board, settings: teardropSettings)
        return replaceTeardrops(Teardrops.withoutTeardrops(board), kept, "Remove Teardrops")
    }

    /// The board made `board` (its teardrops changed, and its pads' and vias' settings), and the project's teardrop
    /// settings `settings`: the vias whose settings changed among the edit's changed, the footprints whose pads' did
    /// among its footprints
    private func replaceTeardrops(_ board: KiCadBoard, _ settings: TeardropSettings, _ name: String) -> Edit? {
        func keys(_ b: KiCadBoard) -> [String] {
            b.root.all("zone").enumerated().filter { $0.element["attr"]?["teardrop"] != nil }.map { ZoneFiller.zoneKey($0.element, $0.offset) }
        }
        func vias(_ b: KiCadBoard) -> [String: String] {
            Dictionary(b.root.all("via").map { ($0.value("uuid") ?? "", $0["teardrops"]?.formatted() ?? "") }, uniquingKeysWith: { a, _ in a })
        }
        func footprints(_ b: KiCadBoard) -> [String: String] {
            Dictionary(b.root.all("footprint").map { fp in
                (fp.value("uuid") ?? "", fp.all("pad").map { $0["teardrops"]?.formatted() ?? "" }.joined(separator: "|"))
            }, uniquingKeysWith: { a, _ in a })
        }
        let changedSettings = settings != teardropSettings
        guard board.text != router.board.text || changedSettings else { return nil }
        let zones = Array(Set(keys(router.board)).union(keys(board))).sorted()
        let (oldVias, newVias) = (vias(router.board), vias(board))
        let (oldFootprints, newFootprints) = (footprints(router.board), footprints(board))
        let changedVias = newVias.keys.filter { newVias[$0] != oldVias[$0] }.sorted()
        let changedFootprints = newFootprints.keys.filter { newFootprints[$0] != oldFootprints[$0] }.sorted()
        if changedSettings {
            var p = project ?? [:]
            var b = p["board"] as? [String: Any] ?? [:]
            var ds = b["design_settings"] as? [String: Any] ?? [:]
            for (k, v) in settings.projectSettings { ds[k] = v }
            b["design_settings"] = ds
            p["board"] = b
            project = p
        }
        if board.text == router.board.text {
            // (the project's settings alone changed: the board as it was)
            var edit = Edit(before: base, after: base, added: [], removed: [], name: name)
            edit.teardropSettings = settings
            return edit
        }
        router.board.root.items = board.root.items
        router.boardChanged()
        guard var edit = change(name, footprints: changedFootprints, zones: zones, changed: changedVias) else {
            // (the board's legacy teardrops no longer so, and nothing else)
            var edit = Edit(before: base, after: router.board.copy(), added: [], removed: [], name: name)
            edit.teardropSettings = changedSettings ? settings : nil
            base = edit.after
            return edit
        }
        if changedSettings { edit.teardropSettings = settings }
        return edit
    }

    // MARK: - The outline

    /// The board's outline made the rectangle round its parts, `margin` (mm) away, its corners on whole millimetres
    /// (as a new board's is; rounded as they were), and the pours drawn to the old outline drawn to the new; nil when
    /// the outline is not one rectangle (or the board has none, when one is drawn) or is already so
    public func fitOutline(margin: Double = 5) -> Edit? {
        guard !isRouting, let parts = Self.partsBox(router.board) else { return nil }
        let box = KiCadBox(minX: (parts.minX - margin).rounded(.down), minY: (parts.minY - margin).rounded(.down),
                           maxX: (parts.maxX + margin).rounded(.up), maxY: (parts.maxY + margin).rounded(.up))
        return reshapeOutline(to: box, radius: nil, name: "Fit Outline to Parts")
    }

    /// The board's outline made a rectangle `width` by `height` (mm), its corners rounded to `radius` (mm; 0 square),
    /// its top left corner where it was (if the board has no outline yet, a whole millimetre or more from the parts'),
    /// and the pours drawn to the old outline drawn to the new; nil when the outline is not one rectangle, or is
    /// already so
    public func setOutline(width: Double, height: Double, radius: Double) -> Edit? {
        guard !isRouting, width > 0, height > 0, radius >= 0 else { return nil }
        let board = router.board
        let origin: KiCadPoint
        if let rect = Self.outlineRectangle(board) {
            origin = KiCadPoint(rect.box.minX, rect.box.minY)
        } else if board.outline.isEmpty, let parts = Self.partsBox(board) {
            origin = KiCadPoint((parts.minX - 5).rounded(.down), (parts.minY - 5).rounded(.down))
        } else {
            return nil
        }
        let box = KiCadBox(minX: origin.x, minY: origin.y, maxX: origin.x + width, maxY: origin.y + height)
        return reshapeOutline(to: box, radius: radius, name: "Change Board Outline")
    }

    /// The mounting holes of KiCad's library by screw size, and how far in from the board's sides each goes
    public static let mountingHoles: [(screw: String, libID: String, inset: Double)] = [
        ("M2", "MountingHole:MountingHole_2.2mm_M2", 3), ("M2.5", "MountingHole:MountingHole_2.7mm_M2.5", 3.5),
        ("M3", "MountingHole:MountingHole_3.2mm_M3", 4), ("M4", "MountingHole:MountingHole_4.3mm_M4", 5),
    ]

    /// Mounting holes in the corners of a rectangular outline, `inset` (mm) in from both sides, made from `footprint`
    /// (the library's `libID`): parts of the board alone (board only: no symbol in the schematic, and kept by its
    /// updates), H1, H2… after any holes already numbered so, as one change; a corner where the hole would come too
    /// near copper already there (as the router finds it, by the board's rules) left without. nil when the outline is
    /// not one rectangle, or no corner can take a hole
    public func addMountingHoles(_ footprint: SExpr, libID: String, inset: Double) -> Edit? {
        guard !isRouting, inset > 0, let (box, _) = router.board.outlineRectangle,
              box.width > 2 * inset, box.height > 2 * inset else { return nil }
        let board = router.board
        let corners = [KiCadPoint(box.minX + inset, box.minY + inset), KiCadPoint(box.maxX - inset, box.minY + inset),
                       KiCadPoint(box.maxX - inset, box.maxY - inset), KiCadPoint(box.minX + inset, box.maxY - inset)]
        let holes = board.footprints.filter { $0.libID.hasPrefix("MountingHole:") }
        var numbers = Set(board.footprints.compactMap { $0.reference.hasPrefix("H") ? Int($0.reference.dropFirst()) : nil })
        let value = KiCadFootprintLibrary.split(libID)?.name ?? libID
        var made: [String] = []
        for corner in corners where !holes.contains(where: { $0.position.distance(to: corner) < inset }) {
            var n = 1
            while numbers.contains(n) { n += 1 }
            numbers.insert(n)
            let node = KiCadFootprintLibrary.placeable(footprint.copy(), libID: libID, reference: "H\(n)", value: value, at: corner)
            board.add(node)
            guard let uuid = node.value("uuid"), let placed = board.footprint(uuid: uuid) else { continue }
            placed.attributes.insert("board_only")
            // (its pads, holes and all, clear of everything else, or the hole is not made)
            router.boardChanged()
            let reference = "H\(n)"
            let clear = zip(router.world.items, router.iface.routerItems).allSatisfy { w, item in
                guard w.kind == .pad, w.footprint == reference, let item, let world = router.router.world else { return true }
                return world.checkColliding(item) == nil
            }
            guard clear else {
                board.root.remove(node)
                router.boardChanged()
                continue
            }
            made.append(uuid)
        }
        guard !made.isEmpty else { return nil }
        router.boardChanged()
        return change(made.count == 1 ? "Add Mounting Hole" : "Add Mounting Holes", footprints: made)
    }

    /// The board's outline when it is one rectangle (round cut-outs and polygons aside): its corners and its corners'
    /// radius (mm)
    public static func outlineRectangle(_ board: KiCadBoard) -> (box: KiCadBox, radius: Double)? { board.outlineRectangle }

    /// The box round the board's parts
    private static func partsBox(_ board: KiCadBoard) -> KiCadBox? {
        board.footprints.compactMap(\.bounds).reduce(nil) { (u: KiCadBox?, b: KiCadBox) -> KiCadBox? in
            guard var u else { return b }
            u.include(KiCadPoint(b.minX, b.minY))
            u.include(KiCadPoint(b.maxX, b.maxY))
            return u
        }
    }

    /// The outline made the rectangle `box`, its corners rounded to `radius` (nil: as they were), as one change
    private func reshapeOutline(to box: KiCadBox, radius: Double?, name: String) -> Edit? {
        let board = router.board
        let edges = board.root.items.filter { KiCadDrawing.heads.contains($0.head ?? "") && $0.value("layer") == "Edge.Cuts" }
        let old: KiCadBox?
        if edges.isEmpty {
            old = nil
            KiCadProject.addOutline(board, box)
        } else {
            guard let (was, r) = Self.outlineRectangle(board) else { return nil }
            guard was.minX != box.minX || was.minY != box.minY || was.maxX != box.maxX || was.maxY != box.maxY
                    || (radius.map { $0 != r } ?? false) else { return nil }
            old = was
        }
        guard let rect = board.root.items.first(where: { $0.head == "gr_rect" && $0.value("layer") == "Edge.Cuts" }) else { return nil }
        rect.set(SExpr("start", box.minX, box.minY))
        rect.set(SExpr("end", box.maxX, box.maxY))
        if let radius {
            rect.remove("radius")
            if radius > 0 { rect.insert(SExpr("radius", radius), after: ["end"]) }
        }
        // pours drawn to the old outline follow it
        if let old {
            for zone in board.zones where !zone.isRuleArea {
                let pts = zone.outline
                guard pts.count == 4, let poly = zone.node["polygon"]?["pts"],
                      pts.allSatisfy({ ($0.x == old.minX || $0.x == old.maxX) && ($0.y == old.minY || $0.y == old.maxY) }) else { continue }
                let corners = [KiCadPoint(box.minX, box.minY), KiCadPoint(box.maxX, box.minY), KiCadPoint(box.maxX, box.maxY),
                               KiCadPoint(box.minX, box.maxY)]
                poly.items = [poly.items[0]] + corners.map { SExpr("xy", $0.x, $0.y) }
                zone.node.remove("filled_polygon")
            }
        }
        router.boardChanged()
        return change(name, outline: true)
    }

    // MARK: - Placing

    /// A footprint moved to `point` (its origin, in mm) and turned to `rotation` degrees (nil: as it is turned), as
    /// KiCad moves one: its pads, drawings and texts with it, the tracks left where they are
    public func moveFootprint(_ uuid: String, to point: KiCadPoint, rotation: Double? = nil) -> Edit? {
        guard !isRouting, let footprint = router.board.footprint(uuid: uuid) else { return nil }
        let turn = rotation ?? footprint.rotation
        guard point != footprint.position || turn != footprint.rotation else { return nil }
        footprint.move(to: point, rotation: turn)
        return placed([footprint], "Move")
    }

    /// Footprints moved by `delta` (mm), together
    public func moveFootprints(_ uuids: [String], by delta: KiCadPoint) -> Edit? {
        let footprints = uuids.compactMap { router.board.footprint(uuid: $0) }
        guard !isRouting, !footprints.isEmpty, delta != .zero else { return nil }
        for f in footprints { f.move(to: KiCadPoint(f.position.x + delta.x, f.position.y + delta.y), rotation: f.rotation) }
        return placed(footprints, "Move")
    }

    /// Footprints turned, each about its origin, by `degrees` (KiCad's R: 90° counterclockwise)
    public func rotateFootprints(_ uuids: [String], by degrees: Double = 90) -> Edit? {
        let footprints = uuids.compactMap { router.board.footprint(uuid: $0) }
        guard !isRouting, !footprints.isEmpty else { return nil }
        for f in footprints {
            var turn = (f.rotation + degrees).truncatingRemainder(dividingBy: 360)
            if turn > 180 { turn -= 360 } else if turn <= -180 { turn += 360 }
            f.move(to: f.position, rotation: turn)
        }
        return placed(footprints, "Rotate")
    }

    /// Footprints turned over to the other side of the board (KiCad's F)
    public func flipFootprints(_ uuids: [String]) -> Edit? {
        let footprints = uuids.compactMap { router.board.footprint(uuid: $0) }
        guard !isRouting, !footprints.isEmpty else { return nil }
        for f in footprints { f.flip() }
        return placed(footprints, "Flip")
    }

    public func rotateFootprint(_ uuid: String, by degrees: Double = 90) -> Edit? { rotateFootprints([uuid], by: degrees) }
    public func flipFootprint(_ uuid: String) -> Edit? { flipFootprints([uuid]) }

    private func placed(_ footprints: [KiCadFootprint], _ action: String) -> Edit? {
        router.boardChanged()
        let what = footprints.count == 1 ? footprints[0].reference : "\(footprints.count) Parts"
        return change("\(action) \(what)", footprints: footprints.map(\.uuid))
    }
}
