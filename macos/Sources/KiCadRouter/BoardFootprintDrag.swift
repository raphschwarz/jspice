// Footprints dragged on a KiCad board with the tracks on their pads, as KiCad's router tool drags them
// (ROUTER_TOOL::InlineDrag, pcbnew/router/router_tool.cpp: the footprints' pads, zones and drawings handed to the
// router's COMPONENT_DRAGGER), and the drag kept as KiCad's PNS_KICAD_IFACE::Commit keeps it
// (pcbnew/router/pns_kicad_iface.cpp: each footprint moved by its pads' offset, the tracks as dragged), KiCad 10.0.7.
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt. GNU General Public License version 3 or later, as KiCad
// (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

// MARK: - The router's side (BoardRouter)

extension BoardRouter {
    /// The board's footprint nodes of those ids, in the order given
    func footprintNodes(_ uuids: [String]) -> [SExpr] {
        let all = board.root.all("footprint")
        return uuids.compactMap { uuid in all.first { $0.value("uuid") == uuid } }
    }

    /// What dragging `footprints` drags, as InlineDrag gathers it: for each footprint, the router's solid of each of
    /// its pads (FindItemByParent: the first made of the pad), the triangles of its keepout zones, and the solids of
    /// its drawings on copper, Edge.Cuts and Margin (FindItemsByParent: all of each, which the dragger moves alike).
    /// (A text on copper, which KiCad's router takes too, the world here does not have yet.)
    func footprintDragItems(_ footprints: [SExpr]) -> [Item] {
        var items: [Item] = []
        func made(_ uuid: String?, _ kinds: Set<WorldItem.Kind>, first: Bool) -> [Item] {
            guard let uuid else { return [] }
            var found: [Item] = []
            for (k, w) in iface.items.enumerated() where w.source == uuid && kinds.contains(w.kind) && k < iface.allRouterItems.count {
                if first { return Array(iface.allRouterItems[k].prefix(1)) }
                found += iface.allRouterItems[k]
            }
            return found
        }
        for fp in footprints {
            for pad in fp.all("pad") { items += made(pad.value("uuid"), [.pad], first: true) }
            for zone in fp.all("zone") { items += made(zone.value("uuid"), [.keepout], first: false) }
            for child in fp.items where ["fp_line", "fp_rect", "fp_arc", "fp_circle", "fp_poly", "fp_curve"].contains(child.head ?? "") {
                items += made(child.value("uuid"), [.graphic, .edge], first: false)
            }
        }
        return items
    }

    /// Starts dragging the footprints of those ids with the tracks on their pads, the pointer at `p` and `layer` the
    /// layer chosen, as KiCad's router tool drags them (InlineDrag): from the nearest of what it drags to the pointer
    /// (snapToItem); one footprint from its anchor, where the move warps the pointer to it (`warpsCursor`, KiCad's
    /// "warp mouse to origin of moved object", on by default), else from the pointer on the grid; the drag started at
    /// that point and moved there. Whether it started (a footprint with no pad, zone or drawing on copper does not).
    @discardableResult
    public func startFootprintDrag(_ uuids: [String], at p: IPoint, layer: Int, warpsCursor: Bool = true) -> Bool {
        guard !router.routingInProgress else { return false }
        let footprints = footprintNodes(uuids)
        guard !footprints.isEmpty else { return false }
        let items = footprintDragItems(footprints)
        iface.added.removeAll()
        iface.removedItems.removeAll()
        var q = p
        // (snapped to the item nearest the pointer, on the layer chosen)
        var closest: Item?
        var closestDist = Int.max
        for item in items {
            guard let shape = item.shape(layer) else { continue }
            var actual: Int?
            _ = shape.collide(.circle(center: p, radius: 0), clearance: Int(Int32.max), actual: &actual)
            let d = actual ?? Int.max
            if d < closestDist {
                closestDist = d
                closest = item
            }
        }
        if let closest { q = snapToItem(closest, p) }
        if footprints.count == 1 {
            q = warpsCursor ? BoardWorld.point(footprints[0]["at"]) : align(p)
        }
        guard router.startDragging(q, items) else { return false }
        // (an initial move, to prime the collision detection)
        router.move(q, nil)
        return true
    }

    /// What the footprint drag has moved, as KiCad's router shows it (the dragger's current node): the board's tracks
    /// and vias it takes away (their ids) and the tracks that go in their place (those moved whole with the
    /// footprints, the lines out of their pads reshaped), the offset the footprints are moved by, and whether what
    /// it moved collides with something (where a click keeps the drag only if forced, or violations are allowed)
    public var footprintDragged: (moved: Set<String>, items: [Item], offset: IPoint, collides: Bool)? {
        guard router.state == .dragComponent, let dragger = router.componentDragger else { return nil }
        let (removed, added) = dragger.currentNode.updatedItems()
        let moved = Set(removed.filter { $0.kind != .solid }.compactMap { iface.resolver.info[ObjectIdentifier($0)]?.source })
        let offset = dragger.moved.first.map { $0.copy.pos - $0.original.pos } ?? .zero
        return (moved, added.filter { !$0.isVirtual && ($0.kind == .segment || $0.kind == .arc || $0.kind == .via) }, offset,
                dragger.currentNode.checkColliding(dragger.traces) != nil)
    }

    /// A click with the pointer at `p`, dragging footprints: the drag kept if the dragger keeps it (what it moved
    /// clear of everything, or `force`d, as with Ctrl, or violations allowed), and written into the board as KiCad's
    /// commit writes it (PNS_KICAD_IFACE::Commit): each footprint of a pad moved, once, by the offset of the first of
    /// its pads the commit hands over (all of them the drag's), its pads, drawings, texts and zones with it; the tracks
    /// as dragged. The ids of the footprints moved, nil if the drag was not kept (it goes on).
    public func fixFootprintDrag(at p: IPoint, force: Bool = false) -> [String]? {
        guard router.state == .dragComponent, let dragger = router.componentDragger else { return nil }
        let (q, item) = endPoint(at: p)
        guard router.fixRoute(q, item, forceCommit: force) else { return nil }
        let moved = dragger.moved
        router.stopRouting()
        var footprints: [String] = []
        let all = board.root.all("footprint")
        for (original, copy) in moved {
            guard let w = iface.worldItem(original), w.kind == .pad, let pad = w.source,
                  let node = all.first(where: { $0.all("pad").contains { $0.value("uuid") == pad } }),
                  let uuid = node.value("uuid"), !footprints.contains(uuid), let footprint = board.footprint(uuid: uuid) else { continue }
            footprints.append(uuid)
            let d = copy.pos - original.pos
            guard d != .zero else { continue }
            let at = BoardWorld.point(node["at"]) + d
            footprint.move(to: KiCadPoint(Double(at.x) / 1e6, Double(at.y) / 1e6), rotation: footprint.rotation)
        }
        apply()
        return footprints
    }
}

// MARK: - The board edited (BoardEditing)

extension BoardEditing {
    /// The footprints being dragged, as they are drawn: the offset they are moved by (mm), the board's tracks and
    /// vias the drag takes away, by id, and the tracks that go in their place; and whether what is dragged collides
    /// with something, which a click keeps only if forced (KiCad's Ctrl-click)
    public struct FootprintDragPreview: Sendable, Equatable {
        public var footprints: [String]
        public var offset: KiCadPoint
        public var moved: Set<String> = []
        public var tracks: [Preview.Track] = []
        public var collides = false
    }

    /// Starts dragging the footprints of those ids with the tracks on their pads, as KiCad's router tool drags a
    /// footprint (its drag, D, on a footprint): the pointer at `p`, `layer` the one chosen; one footprint from its
    /// origin, where the move warps the pointer there (`warpsCursor`, KiCad's default), else from the pointer. The
    /// tracks from one of its pads to another move whole with it; the lines out of its pads have their ends dragged
    /// with them, on the 45° directions. Nil if there is nothing of them to drag.
    public func startFootprintDrag(_ uuids: [String], at p: KiCadPoint, layer: String = "F.Cu",
                                   warpsCursor: Bool = true) -> FootprintDragPreview? {
        guard !isRouting else { return nil }
        router.mode = mode
        router.cornerMode = cornerMode
        guard router.startFootprintDrag(uuids, at: Self.nm(p), layer: router.layer(layer) ?? 0, warpsCursor: warpsCursor) else { return nil }
        return footprintDragPreview(uuids)
    }

    /// The pointer moved to `p`, dragging footprints: what is dragged as it now goes
    @discardableResult
    public func dragFootprint(to p: KiCadPoint) -> FootprintDragPreview? {
        guard router.router.state == .dragComponent else { return nil }
        router.move(to: Self.nm(p))
        return footprintDragPreview(draggedFootprints)
    }

    /// A click at `p`, dragging footprints: the change, if the drag is kept ("Drag" and the footprint's reference):
    /// the footprints moved in the board's file by the offset, as KiCad's commit moves them, and the tracks as
    /// dragged; kept only where what it moved collides with nothing, unless `force`d (KiCad's Ctrl-click) or
    /// violations are allowed. Nil, the drag going on, if not.
    public func fixFootprintDrag(at p: KiCadPoint, force: Bool = false) -> Edit? {
        guard router.router.state == .dragComponent else { return nil }
        guard let moved = router.fixFootprintDrag(at: Self.nm(p), force: force) else { return nil }
        let names = moved.compactMap { router.board.footprint(uuid: $0)?.reference }
        return change(names.count == 1 ? "Drag \(names[0])" : "Drag \(names.count) Parts", footprints: moved)
    }

    /// The footprint drag dropped, the board as it was
    public func cancelFootprintDrag() { router.cancel() }

    /// The footprints the drag in progress drags (those whose pads it moves)
    private var draggedFootprints: [String] {
        guard let dragger = router.router.componentDragger else { return [] }
        var uuids: [String] = []
        let all = router.board.root.all("footprint")
        for (original, _) in dragger.moved {
            guard let pad = router.iface.worldItem(original)?.source,
                  let uuid = all.first(where: { $0.all("pad").contains { $0.value("uuid") == pad } })?.value("uuid"),
                  !uuids.contains(uuid) else { continue }
            uuids.append(uuid)
        }
        return uuids
    }

    private func footprintDragPreview(_ uuids: [String]) -> FootprintDragPreview? {
        guard let d = router.footprintDragged else { return nil }
        var shown = FootprintDragPreview(footprints: uuids, offset: Self.mm(d.offset), moved: d.moved, collides: d.collides)
        for item in d.items {
            if let track = track(item) { shown.tracks.append(track) }
        }
        return shown
    }
}
