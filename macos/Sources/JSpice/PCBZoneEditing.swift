import AppKit
import SwiftUI
import KiCadKit
import KiCadRouter

/// The zone's handle being dragged with the select tool (a corner, an edge's midpoint, as KiCad's point editor drags
/// it), or the zone moved whole from where the drag began
enum PCBZoneDrag {
    case handle(BoardEditing.ZoneHandle, step: Int)
    case whole(from: KiCadPoint, delta: KiCadPoint)
}

/// Where the select tool's drags of a zone's corners go: onto the 0.05 mm grid, as the zone tool draws them
private func zoneGrid(_ p: KiCadPoint) -> KiCadPoint {
    let grid = 0.05
    return KiCadPoint((p.x / grid).rounded() * grid, (p.y / grid).rounded() * grid)
}

/// A zone's outline (mm) from the session's (nm)
private func millimetres(_ contours: BoardEditing.ZoneContours) -> [[KiCadPoint]] {
    contours.map { $0.map { KiCadPoint(Double($0.x) / 1e6, Double($0.y) / 1e6) } }
}

// MARK: - Zones selected and their outlines edited

extension PCBEditing {
    /// The point editor's handles on an outline (mm): each corner (numbered through the outline and then its holes, as
    /// KiCad numbers them), and each edge's midpoint (the edge from that corner to the next of its contour)
    nonisolated static func zoneHandles(_ outline: [[KiCadPoint]]) -> [(handle: BoardEditing.ZoneHandle, at: KiCadPoint)] {
        var corners: [(BoardEditing.ZoneHandle, KiCadPoint)] = [], edges: [(BoardEditing.ZoneHandle, KiCadPoint)] = []
        var i = 0
        for ring in outline {
            for (k, p) in ring.enumerated() {
                let q = ring[(k + 1) % ring.count]
                corners.append((.corner(i), p))
                edges.append((.edge(i), KiCadPoint((p.x + q.x) / 2, (p.y + q.y) / 2)))
                i += 1
            }
        }
        return (corners + edges).map { (handle: $0.0, at: $0.1) }
    }

    /// The handle of the selected zone at `p` within `slop` (mm), corners first; nil where there is none or the point
    /// editor does not edit the zone (a locked one, one with arcs)
    func zoneHandle(at p: KiCadPoint, slop: Double) -> BoardEditing.ZoneHandle? {
        guard let outline = zoneOutline, zoneSelection != nil else { return nil }
        return Self.zoneHandles(outline).first { hypot($0.at.x - p.x, $0.at.y - p.y) <= slop }?.handle
    }

    /// The zone clicked at `p` with the select tool selected (where nothing else is there to select), as KiCad's
    /// selection picks one: by its outline within `slop` (mm), else by its fill; or none
    func selectZone(at p: KiCadPoint, slop: Double) {
        let order = [layer] + layers.filter { $0 != layer }
        Task {
            let found = await engine.run { $0.zone(at: p, layers: order, slop: slop) }
            zoneSelection = found
            await refreshZoneOutline()
        }
    }

    /// The zone selected no longer (another item selected, or Esc)
    func deselectZone() {
        guard zoneSelection != nil else { return }
        if zoneDrag != nil { cancelZoneDrag() }
        zoneSelection = nil
        zoneOutline = nil
    }

    /// The selected zone's handles as its outline now is: none where it is gone, locked, or has arcs
    func refreshZoneOutline() async {
        guard let uuid = zoneSelection else {
            zoneOutline = nil
            return
        }
        let outline = await engine.run { session -> [[KiCadPoint]]? in
            guard session.canEditZoneOutline(uuid), let contours = session.zoneContours(uuid) else { return nil }
            return millimetres(contours)
        }
        guard zoneSelection == uuid else { return }
        zoneOutline = outline
        if await engine.run({ s in s.board.zones.contains { $0.uuid == uuid } }) != true { zoneSelection = nil }
    }

    /// A drag with the select tool from `start` to `now` (mm) taken by the selected zone: from one of its handles (within
    /// `slop`), the handle moved as KiCad's point editor moves it (`fixedLength`, KiCad's Ctrl: an edge kept its length;
    /// `free`, Shift: a corner not snapped to 45° of its neighbours; `pixel`, mm, sets the snap's stickiness), or, from
    /// within the zone (where `picture` has nothing else to drag), the zone moved (on the grid). Whether the zone took it.
    func zoneDragChanged(from start: KiCadPoint, to now: KiCadPoint, in picture: KiCadBoardPicture, slop: Double, pixel: Double,
                         fixedLength: Bool, free: Bool) -> Bool {
        guard tool == .select, !isRouting, let uuid = zoneSelection else { return false }
        switch zoneDrag {
        case nil:
            if let handle = zoneHandle(at: start, slop: slop) {
                zoneDrag = .handle(handle, step: 0)
                Task {
                    _ = await engine.run { $0.startZoneDrag(uuid, handle: handle) }
                    zoneHandleMoved(to: now, pixel: pixel, fixedLength: fixedLength, free: free)
                }
                return true
            }
            // (from within it, where no part or copper is to drag instead)
            guard let outline = zoneOutline, let ring = outline.first, KiCadPolygon.contains(ring, start),
                  !outline.dropFirst().contains(where: { KiCadPolygon.contains($0, start) }),
                  picture.footprint(at: start) == nil, picture.copper(at: start, layers: picture.copperLayers, slop: 0) == nil else { return false }
            zoneDrag = .whole(from: start, delta: .zero)
            fallthrough
        case .whole?:
            let delta = zoneGrid(KiCadPoint(now.x - start.x, now.y - start.y))
            zoneDrag = .whole(from: start, delta: delta)
            return true
        case .handle?:
            zoneHandleMoved(to: now, pixel: pixel, fixedLength: fixedLength, free: free)
            return true
        }
    }

    /// The handle dragged on to `p`: the outline shown as the session's point editor makes it (a later move's outline
    /// not overtaken by an earlier's)
    private func zoneHandleMoved(to p: KiCadPoint, pixel: Double, fixedLength: Bool, free: Bool) {
        guard case .handle(let handle, let step)? = zoneDrag else { return }
        zoneDrag = .handle(handle, step: step + 1)
        Task {
            let shown = await engine.run {
                $0.dragZonePoint(to: p, ctrl: fixedLength, shift: free, grid: 0.05, stickyDistance: 5 * pixel, snap: zoneGrid)
            }
            guard case .handle(_, let now)? = zoneDrag, now == step + 1, let shown else { return }
            zoneOutline = shown
        }
    }

    /// The zone's drag let go at `p`: the point editor's "Move Point" kept (the zone filled again), or the zone moved
    /// ("Move"); whether there was a drag of the zone
    func zoneDragEnded(at p: KiCadPoint) -> Bool {
        guard let drag = zoneDrag, let uuid = zoneSelection else { return false }
        zoneDrag = nil
        Task {
            switch drag {
            case .handle:
                await place { $0.finishZoneDrag() }
                _ = await engine.run { session -> Bool? in
                    session.cancelZoneDrag()
                    return true
                }
            case .whole(_, let delta):
                if delta != .zero, await place({ $0.moveZones([uuid], by: delta) }) == false { NSSound.beep() }
            }
            await refreshZoneOutline()
        }
        return true
    }

    /// The zone's drag dropped (Esc), the zone as it was
    func cancelZoneDrag() {
        zoneDrag = nil
        Task {
            _ = await engine.run { session -> Bool? in
                session.cancelZoneDrag()
                return true
            }
            await refreshZoneOutline()
        }
    }

    /// The selected zone's outline as the drag shows it: moved whole by the drag's offset
    var zoneOutlineShown: [[KiCadPoint]]? {
        guard let outline = zoneOutline else { return nil }
        guard case .whole(_, let d)? = zoneDrag else { return outline }
        return outline.map { $0.map { KiCadPoint($0.x + d.x, $0.y + d.y) } }
    }

    /// A corner created on the selected zone's edge nearest the pointer, as the point editor's Create Corner (F1, or
    /// Insert) creates one ("Add Zone Corner")
    func addZoneCorner() {
        guard let uuid = zoneSelection, let at = pointer.map(zoneGrid) else { return }
        Task {
            if await place({ $0.addZoneCorner(uuid, at: at) }) == false { NSSound.beep() }
            await refreshZoneOutline()
        }
    }

    /// The selected zone's corner under the pointer (within `slop`, mm) taken away as the point editor's Remove Corner
    /// takes it ("Remove Zone Corner"), where it can be; else the zone deleted. Whether a zone was selected.
    func deleteZoneSelection(slop: Double) -> Bool {
        guard let uuid = zoneSelection, zoneDrag == nil else { return false }
        if let p = pointer, case .corner(let index)? = zoneHandle(at: p, slop: slop) {
            Task {
                if await place({ $0.removeZoneCorner(uuid, index: index) }) == false { NSSound.beep() }
                await refreshZoneOutline()
            }
            return true
        }
        Task {
            if await place({ $0.removeZones([uuid]) }) == false { NSSound.beep() }
            await refreshZoneOutline()
        }
        return true
    }
}

/// The selected zone drawn: its outline, and the point editor's handles on its corners (squares) and edges' midpoints
/// (circles), as KiCad shows them
struct PCBZoneHandles {
    let outline: [[KiCadPoint]]
    let view: PCBTransform

    func draw(_ context: GraphicsContext) {
        var path = Path()
        for ring in outline where !ring.isEmpty {
            path.addLines(ring.map(view.point))
            path.closeSubpath()
        }
        context.stroke(path, with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
        let size: CGFloat = 8
        for (handle, at) in PCBEditing.zoneHandles(outline) {
            let c = view.point(at)
            let rect = CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size)
            let shape = { () -> Path in
                if case .corner = handle { return Path(rect) }
                return Path(ellipseIn: rect.insetBy(dx: 1, dy: 1))
            }()
            context.fill(shape, with: .color(Color.accentColor))
            context.stroke(shape, with: .color(.white), lineWidth: 1)
        }
    }
}
