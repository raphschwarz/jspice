// Several tracks dragged together on a KiCad board, as KiCad's router tool drags the tracks selected
// (ROUTER_TOOL::InlineDrag, pcbnew/router/router_tool.cpp: the selection's segments and arcs handed to the router's
// MULTI_DRAGGER, from the point of the nearest of them to the pointer), KiCad 10.0.7.
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt. GNU General Public License version 3 or later, as KiCad
// (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

// MARK: - The router's side (BoardRouter)

extension BoardRouter {
    /// The router's segments and arcs of the board's tracks of those ids, in the order given (InlineDrag's
    /// itemsToDrag of a selection: FindItemByParent of each)
    func trackDragItems(_ uuids: [String]) -> [Item] {
        uuids.compactMap { uuid in
            iface.items.indices.first { iface.items[$0].source == uuid && (iface.items[$0].kind == .track || iface.items[$0].kind == .arc) }
                .flatMap { iface.routerItems[$0] }
        }
    }

    /// Starts dragging the tracks of those ids together, the pointer at `p` and `layer` the layer chosen, as KiCad's
    /// router tool drags the tracks selected: from the point of the nearest of them to the pointer (snapToItem) the
    /// segment the pointer is on, or the nearest, its line the primary one; their ends where the pointer is at one's
    /// end and every line's end is free, else their segments. Whether it started (fewer than two tracks do not drag
    /// together: see `startDrag`).
    @discardableResult
    public func startMultiDrag(_ uuids: [String], at p: IPoint, layer: Int) -> Bool {
        guard !router.routingInProgress else { return false }
        let items = trackDragItems(uuids)
        guard items.count >= 2 else { return false }
        iface.added.removeAll()
        iface.removedItems.removeAll()
        var q = p
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
        guard router.startDragging(q, items) else { return false }
        router.move(q, nil)
        return true
    }

    /// What the drag of several tracks has moved, as KiCad's router shows it (the dragger's current node): the
    /// board's tracks and vias it takes away (their ids), and the tracks and vias that go in their place; and whether
    /// the last move got there (walking round or shoving; a click keeps the drag only then, or where violations are
    /// allowed)
    public var multiDragged: (moved: Set<String>, items: [Item], ok: Bool)? {
        guard router.state == .dragSegment, let dragger = router.multiDragger else { return nil }
        let (removed, added) = dragger.currentNode.updatedItems()
        let moved = Set(removed.compactMap { iface.resolver.info[ObjectIdentifier($0)]?.source })
        return (moved, added.filter { !$0.isVirtual && ($0.kind == .segment || $0.kind == .arc || $0.kind == .via) }, dragger.dragStatus)
    }

    /// A click with the pointer at `p`, dragging several tracks: the drag kept, if the dragger keeps it, written into
    /// the board; whether it was. If not, the drag goes on.
    @discardableResult
    public func fixMultiDrag(at p: IPoint, force: Bool = false) -> Bool {
        guard router.state == .dragSegment, router.multiDragger != nil else { return false }
        let (q, item) = endPoint(at: p)
        guard router.fixRoute(q, item, forceCommit: force) else { return false }
        router.stopRouting()
        apply()
        return true
    }
}

// MARK: - The board edited (BoardEditing)

extension BoardEditing {
    /// Starts dragging the tracks of those ids together (selected, then dragged: KiCad's drag of a selection of
    /// tracks), the pointer at `p` on `layer`: their segments moved together, each as far as the one under the pointer,
    /// those running its way, or their ends. Nil if fewer than two of them are there.
    public func startMultiDrag(_ uuids: [String], at p: KiCadPoint, layer: String = "F.Cu") -> DragPreview? {
        guard !isRouting, let l = router.layer(layer) else { return nil }
        router.mode = mode
        router.cornerMode = cornerMode
        guard router.startMultiDrag(uuids, at: Self.nm(p), layer: l) else { return nil }
        return multiDragPreview
    }

    /// The pointer moved to `p`, dragging several tracks: what is dragged as it now goes
    @discardableResult
    public func multiDrag(to p: KiCadPoint) -> DragPreview? {
        guard router.router.multiDragger != nil else { return nil }
        router.move(to: Self.nm(p))
        return multiDragPreview
    }

    /// A click at `p`, dragging several tracks: the change, if the drag is kept ("Drag Tracks"); nil, the drag going
    /// on, if not
    public func fixMultiDrag(at p: KiCadPoint, force: Bool = false) -> Edit? {
        guard router.router.multiDragger != nil, router.fixMultiDrag(at: Self.nm(p), force: force) else { return nil }
        return change("Drag Tracks")
    }

    /// The drag of several tracks dropped, the board as it was
    public func cancelMultiDrag() { router.cancel() }

    /// What is being dragged, as it is drawn (the nets those of the lines dragged; `violates` where the last move
    /// did not get there)
    public var multiDragPreview: DragPreview? {
        guard let d = router.multiDragged else { return nil }
        var shown = DragPreview(moved: d.moved, net: (router.router.currentNets.first ?? nil).flatMap { router.world.netNames[$0] },
                                violates: !d.ok)
        for item in d.items {
            if let track = track(item) {
                shown.tracks.append(track)
            } else if let v = item as? Via {
                shown.vias.append(.init(center: Self.mm(v.pos), size: Double(v.diameter) / 1e6))
            }
        }
        return shown
    }
}
