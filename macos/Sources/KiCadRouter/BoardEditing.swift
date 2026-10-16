// A board edited here, a track at a time, as KiCad's router tool drives its router (pcbnew/router/router_tool.cpp,
// KiCad 10.0.7): magnetic pads, the start layer taken from a one-sided pad, a click fixing the track, a double click
// finishing it, Escape keeping what is fixed. GNU General Public License version 3 or later, as the router (see
// KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// A board edited in the PCB view: the router on it, driven as a pointer drives it (start, move, fix, finish, vias,
/// layers, postures, widths), and tracks and vias taken away. Each change made is handed back as the board before and
/// after it, for the board's file or KiCad's open editor to take; the board here is then the board after it.
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
        /// What it was, for an undo menu (and KiCad's own)
        public let name: String
    }

    /// The track being routed, as it is drawn: its fixed part, the part following the pointer, its width and layer,
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
    }

    public private(set) var router: BoardRouter
    private var project: [String: Any]?
    /// The board as the last change left it (each change is made from it)
    private var base: KiCadBoard

    /// `board` is the board as it is: the session works on a copy of it, and leaves it as it is
    public init(board: KiCadBoard, project: [String: Any]? = nil) {
        self.project = project
        base = board.copy()
        router = BoardRouter(board: base.copy(), project: project)
    }

    /// The board read anew (changed elsewhere: in KiCad, or by the schematic's update); a track being routed is
    /// dropped. `project` nil keeps the project's settings as they were.
    public func load(_ board: KiCadBoard, project: [String: Any]? = nil) {
        if let project { self.project = project }
        let text = board.text
        if text == base.text && !router.router.routingInProgress { return }
        router.cancel()
        base = board.copy()
        router = BoardRouter(board: base.copy(), project: self.project)
    }

    /// The board as it now is
    public var board: KiCadBoard { router.board }

    public var isRouting: Bool { router.router.routingInProgress }

    /// The board's copper layers, front to back
    public var layers: [String] { router.world.layerIndex.sorted { $0.value < $1.value }.map(\.key) }

    static func nm(_ p: KiCadPoint) -> IPoint { IPoint(Int((p.x * 1e6).rounded()), Int((p.y * 1e6).rounded())) }
    static func mm(_ p: IPoint) -> KiCadPoint { KiCadPoint(Double(p.x) / 1e6, Double(p.y) / 1e6) }

    /// Where the pointer at `p` routes to: the centre of a pad of the track's net under it, as KiCad's magnetic
    /// pads have it, else `p` on a 0.05 mm grid
    public func snap(_ p: KiCadPoint, layer: String) -> IPoint {
        let q = Self.nm(p)
        let l = router.layer(layer) ?? 0
        let net = isRouting ? router.router.currentNets.first ?? nil : nil
        let pads = router.router.queryHoverItems(q).compactMap { $0 as? Solid }.filter {
            $0.layers.overlaps(l) && $0.isRoutable && (!isRouting || $0.net == net)
        }
        if let pad = pads.first { return pad.pos }
        let grid = 50_000
        return IPoint(Int((Double(q.x) / Double(grid)).rounded()) * grid, Int((Double(q.y) / Double(grid)).rounded()) * grid)
    }

    /// The layer a track started at `p` goes on: `layer`, unless the pad there is only on another
    public func startLayer(at p: KiCadPoint, preferring layer: String) -> String {
        let q = Self.nm(p)
        guard let l = router.layer(layer) else { return layer }
        let pads = router.router.queryHoverItems(q).compactMap { $0 as? Solid }.filter(\.isRoutable)
        if pads.isEmpty || pads.contains(where: { $0.layers.overlaps(l) }) { return layer }
        return router.layerName(pads[0].layers.start)
    }

    // MARK: - Routing

    /// Starts a track at `p` on `layer` (width in mm, nil for its net class's); whether it could (not on another
    /// net's copper, nor too close to it)
    public func start(at p: KiCadPoint, layer: String, width: Double? = nil) -> Bool {
        let layerName = startLayer(at: p, preferring: layer)
        guard let l = router.layer(layerName) else { return false }
        return router.start(at: snap(p, layer: layerName), layer: l, width: width.map { Int(($0 * 1e6).rounded()) })
    }

    /// The pointer moved to `p`: the track as it now goes
    @discardableResult
    public func move(to p: KiCadPoint) -> Preview? {
        guard isRouting else { return nil }
        router.move(to: snap(p, layer: router.layerName(router.router.currentLayer)))
        return preview
    }

    /// A click at `p`: the track fixed up to there; the change, if that finished it (it reached its net)
    public func fix(at p: KiCadPoint) -> Edit? {
        guard isRouting else { return nil }
        let q = snap(p, layer: router.layerName(router.router.currentLayer))
        return router.fix(at: q) ? commit("Route Track") : nil
    }

    /// A double click at `p`: the track fixed there and finished, whether or not it reached its net
    public func finish(at p: KiCadPoint) -> Edit? {
        guard isRouting else { return nil }
        let q = snap(p, layer: router.layerName(router.router.currentLayer))
        router.move(to: q)
        _ = router.finish(at: q)
        return commit("Route Track")
    }

    /// The track routed on to the nearest pad or track of its net it is not joined to, and finished there, if it
    /// gets there (KiCad's End)
    public func finishToRatsnest() -> Edit? {
        guard isRouting, router.finishToRatsnest() else { return nil }
        return commit("Route Track")
    }

    /// Routing stopped, what is fixed of the track kept (KiCad's Escape)
    public func stop() -> Edit? {
        guard isRouting else { return nil }
        return commit("Route Track")
    }

    /// The track dropped, fixed parts and all
    public func cancel() { router.cancel() }

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
        return Preview(tail: p.tail.points.map(Self.mm), head: p.head.points.map(Self.mm), width: Double(p.width) / 1e6,
                       layer: router.layerName(p.layer), via: p.via.map(Self.mm),
                       viaSize: Double(router.router.sizes.viaDiameter) / 1e6, net: router.routedNet,
                       target: router.target.map(Self.mm))
    }

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
        var wires = KiCadConnectivity(router.board).ratsnest()
        func wanted(_ w: KiCadConnectivity.Airwire) -> Bool { (nets?.contains(w.net) ?? true) && !skip.contains(w.net) }
        let other = layers.first { $0 != layer } ?? layer
        while out.routed.count + out.failed.count < most, let wire = wires.first(where: { wanted($0) && !tried.contains($0) }) {
            tried.insert(wire)
            let name = "\(wire.net): \(wire.ends.isEmpty ? "tracks" : wire.ends.joined(separator: " to "))"
            var done = false
            for l in (layer == other ? [layer] : [layer, other]) where !done {
                guard self.start(at: wire.from, layer: startLayer(at: wire.from, preferring: l), width: width) else { continue }
                move(to: wire.to)
                if let edit = fix(at: wire.to) {
                    added += edit.added
                    removed += edit.removed
                    done = true
                } else {
                    cancel()
                }
            }
            if done { out.routed.append(name) } else { out.failed.append(name) }
            wires = KiCadConnectivity(router.board).ratsnest()
        }
        out.left = wires.count
        if !added.isEmpty || !removed.isEmpty {
            let n = out.routed.count
            out.edit = Edit(before: start, after: base, added: added, removed: removed,
                            name: n == 1 ? "Route 1 Connection" : "Route \(n) Connections")
        }
        return out
    }

    // MARK: - Changes

    /// Tracks and vias taken away, by id
    public func remove(_ uuids: Set<String>) -> Edit? {
        router.remove(uuids)
        return change(uuids.count == 1 ? "Delete Track" : "Delete Tracks")
    }

    private func commit(_ name: String) -> Edit? {
        router.commit()
        return change(name)
    }

    private func change(_ name: String, footprints: [String] = [], zones: [String] = []) -> Edit? {
        guard !router.lastAdded.isEmpty || !router.lastRemoved.isEmpty || !footprints.isEmpty || !zones.isEmpty else { return nil }
        let after = router.board.copy()
        var edit = Edit(before: base, after: after, added: router.lastAdded, removed: router.lastRemoved, name: name)
        edit.footprints = footprints
        edit.zones = zones
        base = after
        return edit
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

    /// Zones taken away, by id
    public func removeZones(_ uuids: Set<String>) -> Edit? {
        let gone = router.board.zones.filter { uuids.contains($0.uuid) }
        guard !isRouting, !gone.isEmpty else { return nil }
        for zone in gone { router.board.root.remove(zone.node) }
        router.boardChanged()
        return change(gone.count == 1 ? "Delete Pour" : "Delete Pours", zones: gone.map(\.uuid))
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
