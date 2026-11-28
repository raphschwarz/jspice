// Ported from KiCad 10.0.8: common/tool/construction_manager.cpp and include/tool/construction_manager.h
// (CONSTRUCTION_MANAGER: ProposeConstructionItems, acceptConstructionItems, getMaxTemporaryBatches,
// InvolvesAllGivenRealItems, GetConstructionItems, Clear; ACTIVATION_HELPER: ProposeActivation, CancelProposal,
// acceptPendingProposal, the proposals' tags, HashConstructionBatchSources; SNAP_MANAGER::GetConstructionItems and
// Clear: the snap line's construction lines), common/preview_items/construction_geom.cpp and include/preview_items/
// construction_geom.h (CONSTRUCTION_GEOM's drawables: what is shown of them), pcbnew/tools/pcb_grid_helper.cpp
// (PCB_GRID_HELPER::AddConstructionItems: the construction geometry of a line's, an arc's, a circle's or a
// rectangle's; BestSnapAnchor's proposeConstructionForItems and its activation of an item hovered over), the hit tests
// that activation asks (common/eda_shape.cpp's EDA_SHAPE::hitTest, pcbnew/pcb_track.cpp's PCB_TRACK, PCB_ARC and
// PCB_VIA::HitTest, pcbnew/pad.cpp's PAD::HitTest, pcbnew/footprint.cpp's FOOTPRINT::HitTest, pcbnew/zone.cpp's
// ZONE::HitTest, HitTestForCorner and HitTestForEdge, pcbnew/pcb_target.cpp's PCB_TARGET::HitTest),
// libs/kimath/src/geometry/half_line.cpp (HALF_LINE: Contains, Intersect, NearestPoint), line.cpp (LINE::Intersect,
// NearestPoint) and intersection.cpp (INTERSECTION_VISITOR's lines and half lines), and common/advanced_config.cpp
// (EnableExtensionSnaps, ExtensionSnapTimeoutMs, ExtensionSnapActivateOnHover).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

// MARK: - Construction geometry

/// One piece of construction geometry (KIGFX::CONSTRUCTION_GEOM::DRAWABLE): a line through two points (LINE), a ray
/// from a point through another (HALF_LINE), a circle, an arc, a point
public enum ConstructionDrawable: Sendable, Equatable {
    case line(Seg)
    case halfLine(Seg)
    case circle(Circle)
    case arc(ShapeArc)
    case point(IPoint)
}

/// KiCad's CONSTRUCTION_MANAGER: the construction geometry the grid helper snaps to, in batches (each the items one
/// point of interest proposed): one persistent batch (the point editor's item as it was), and up to two temporary
/// batches (the items the pointer was snapped to, or rested on), the oldest pushed out by a new one; a proposal taken
/// at once where there is room for it (a persistent one always), else pending until the pointer has rested (KiCad's
/// timer, ExtensionSnapTimeoutMs, half a second by default: `timerExpired`), forgotten when the pointer goes to nothing
/// (CancelProposal); a proposal the same as the one last taken, or as the one pending, not made again; a temporary
/// batch none of whose items is new to the batches taken not taken
public struct ConstructionManager: Sendable {
    /// Where a construction item comes from (CONSTRUCTION_MANAGER::SOURCE)
    public enum Source: Sendable, Hashable { case items, snapLine }

    /// CONSTRUCTION_ITEM: its source, the item it is of (by the grid helper's item index; none for a snap line), and
    /// its geometry
    public struct Item: Sendable, Equatable {
        public var source: Source
        public var item: Int?
        public var constructions: [ConstructionDrawable]
    }

    public typealias Batch = [Item]

    /// A proposal's tag (HashConstructionBatchSources: whether it is persistent, and the source and item of each of
    /// its items; here the values themselves, where KiCad hashes them)
    struct Tag: Sendable, Equatable {
        var persistent: Bool
        var sources: [Key]
        struct Key: Sendable, Equatable { var source: Source; var item: Int? }
    }

    /// m_persistentConstructionBatch, m_temporaryConstructionBatches
    public private(set) var persistentBatch: Batch?
    public private(set) var temporaryBatches: [Batch] = []
    /// m_involvedItems: every item of the batches taken
    public private(set) var involved: Set<Int> = []
    // (ACTIVATION_HELPER: the proposal pending and its tag, the tag of the one last taken)
    private var pending: (batch: Batch, persistent: Bool)?
    private var pendingTag: Tag?
    private var lastAcceptedTag: Tag?

    public init() {}

    /// getMaxTemporaryBatches
    public static let maxTemporaryBatches = 2

    /// Whether a proposal waits for the pointer to rest (ACTIVATION_HELPER's timer running with one pending)
    public var hasPendingProposal: Bool { pendingTag != nil }
    /// How many proposals have waited so far (each started KiCad's timer again: a timer of the app's own restarts
    /// where this changes)
    public private(set) var proposals = 0

    /// ProposeConstructionItems
    mutating func propose(_ batch: Batch, persistent: Bool) {
        // (an empty batch: nothing to propose, nothing cleared)
        guard !batch.isEmpty else { return }
        let immediately = persistent || temporaryBatches.count < Self.maxTemporaryBatches
        let tag = Tag(persistent: persistent, sources: batch.map { Tag.Key(source: $0.source, item: $0.item) })
        // (ProposeActivation: the one last taken, or the one pending, not proposed again)
        if tag == lastAcceptedTag || tag == pendingTag { return }
        pendingTag = tag
        pending = (batch, persistent)
        if immediately { acceptPending() } else { proposals += 1 }
    }

    /// CancelProposal
    mutating func cancelProposal() {
        pendingTag = nil
    }

    /// The pointer rested long enough (ACTIVATION_HELPER's timer expired): the proposal pending, if one is, taken
    public mutating func timerExpired() { acceptPending() }

    /// acceptPendingProposal
    private mutating func acceptPending() {
        guard let tag = pendingTag, let p = pending else { return }
        lastAcceptedTag = tag
        pendingTag = nil
        pending = nil
        accept(p.batch, persistent: p.persistent)
    }

    /// acceptConstructionItems
    private mutating func accept(_ batch: Batch, persistent: Bool) {
        if persistent {
            persistentBatch = batch
        } else {
            // (no item of it not involved already: nothing new to show)
            guard batch.contains(where: { $0.item.map { !involved.contains($0) } ?? true }) else { return }
            while temporaryBatches.count >= Self.maxTemporaryBatches { temporaryBatches.removeFirst() }
            temporaryBatches.append(batch)
        }
        involved = []
        for b in batches {
            for case let i? in b.map(\.item) { involved.insert(i) }
        }
    }

    /// The batches taken: the persistent one, then the temporary ones (GetConstructionItems)
    public var batches: [Batch] { (persistentBatch.map { [$0] } ?? []) + temporaryBatches }

    /// InvolvesAllGivenRealItems: every item of these (none, a snap line's, always) in a batch taken
    public func involvesAll(_ items: [Int?]) -> Bool {
        items.allSatisfy { $0.map(involved.contains) ?? true }
    }

    /// HasActiveConstruction
    public var hasActiveConstruction: Bool { persistentBatch != nil || !temporaryBatches.isEmpty }

    /// Clear: every batch forgotten, the proposal pending too (the tag of the one last taken kept, as KiCad keeps it)
    mutating func clear() {
        persistentBatch = nil
        temporaryBatches = []
        involved = []
        cancelProposal()
    }
}

// MARK: - Lines and half lines

extension PCBGridHelper {
    /// VectorsInSameQuadrant
    static func sameQuadrant(_ a: IPoint, _ b: IPoint) -> Bool {
        (a.x >= 0) == (b.x >= 0) && (a.y >= 0) == (b.y >= 0)
    }

    /// HALF_LINE::Contains: on the ray's side of its start, within a nanometre of its line
    static func halfLineContains(_ h: Seg, _ p: IPoint) -> Bool {
        sameQuadrant(h.b - h.a, p - h.a) && h.lineDistance(p) <= 1
    }

    /// HALF_LINE::Intersect( SEG )
    static func halfLineIntersect(_ h: Seg, _ s: Seg) -> IPoint? {
        guard let p = s.intersect(h, lines: true), sameQuadrant(h.b - h.a, p - h.a), s.contains(p) else { return nil }
        return p
    }

    /// HALF_LINE::Intersect( HALF_LINE ), of `h` with `other`
    static func halfLineIntersect(_ h: Seg, halfLine other: Seg) -> IPoint? {
        guard let p = h.intersect(other, lines: true), sameQuadrant(h.b - h.a, p - h.a), sameQuadrant(other.b - other.a, p - other.a)
        else { return nil }
        return p
    }

    /// findIntersections( LINE, HALF_LINE ): as two lines, where the ray has it
    static func lineHalfLineIntersect(_ line: Seg, _ h: Seg) -> IPoint? {
        guard let p = h.intersect(line, lines: true), halfLineContains(h, p) else { return nil }
        return p
    }

    /// HALF_LINE::NearestPoint: the line's, but its start where the point is behind it
    static func halfLineNearest(_ h: Seg, _ p: IPoint) -> IPoint {
        let d = h.b - h.a
        let lsq = d.x * d.x + d.y * d.y
        if lsq == 0 { return h.a }
        let t = d.dot(p - h.a)
        if t < 0 { return h.a }
        return IPoint(h.a.x + KiMath.rescale(t, d.x, lsq), h.a.y + KiMath.rescale(t, d.y, lsq)).wrapped32
    }
}

// MARK: - Activation by hovering over an item

extension SnapBoard {
    /// The item's HitTest at `p` with no accuracy (an exact hit, as BestSnapAnchor's activation by hovering asks it): a
    /// graphic's outline (its width's half about it; the inside of a filled one), a track or arc (its width's half), a
    /// via's circle, a pad's shape or hole, a footprint's box, a zone's corners (a fifth of a millimetre) and edges (a
    /// tenth), a target's square. (A rectangle's rounded corners are taken as square, a hatched fill as none, a
    /// Bézier as the line between its ends.)
    public func hitTest(_ i: Int, _ p: IPoint) -> Bool {
        let item = items[i]
        switch item.kind {
        case .shape:
            guard let d = item.drawing else { return false }
            let maxDist = d.width > 0 ? Double(d.width) / 2 : 0
            let segDist = Int(maxDist)
            switch d.kind {
            case .circle:
                let radius = Double(d.radius)
                let dist = DPoint(p - d.start).norm
                return d.filled ? dist <= radius + maxDist : abs(radius - dist) <= maxDist
            case .arc:
                if DPoint(p - d.start).norm <= maxDist || DPoint(p - d.end).norm <= maxDist { return true }
                // (GetRadius: the centre to the start, rounded, at least 1)
                let radius = Double(max(1, KiMath.round(DPoint(d.start - d.center).norm)))
                let rel = DPoint(p) - DPoint(d.center)
                let dist = rel.norm
                if d.filled ? dist > radius + maxDist : abs(radius - dist) > maxDist { return false }
                // (CalcArcAngles, then each normalized)
                let s = EDAAngle(DPoint(d.start - d.center))
                var e = EDAAngle(DPoint(d.end - d.center))
                if e == s { e = s + .a360 }
                while e < s { e += .a360 }
                let start = s.normalized, end = e.normalized, at = EDAAngle(rel).normalized
                return end > start ? at >= start && at <= end : at >= start || at <= end
            case .segment, .bezier:
                return KiMath.testSegmentHit(p, d.start, d.end, segDist)
            case .rect:
                let c = [d.start, IPoint(d.end.x, d.start.y), d.end, IPoint(d.start.x, d.end.y)]
                if d.filled {
                    let chain = LineChain(c, closed: true)
                    if chain.pointInside(p) { return true }
                    return (0..<4).contains { Seg(c[$0], c[($0 + 1) % 4]).squaredDistance(p) <= segDist * segDist }
                }
                return (0..<4).contains { KiMath.testSegmentHit(p, c[$0], c[($0 + 1) % 4], segDist) }
            case .poly:
                let pts = d.chain?.points ?? d.poly
                guard pts.count >= 2 else { return false }
                let n = pts.count
                let onEdge = (0..<n).contains { Seg(pts[$0], pts[($0 + 1) % n]).squaredDistance(p) <= segDist * segDist }
                if d.filled { return onEdge || LineChain(pts, closed: true).pointInside(p) }
                return onEdge
            }
        case .track:
            return KiMath.testSegmentHit(p, item.start, item.end, item.width / 2)
        case .arc:
            let maxDist = Double(item.width) / 2
            if DPoint(p - item.start).norm <= maxDist || DPoint(p - item.end).norm <= maxDist { return true }
            let arc = ShapeArc(start: item.start, mid: item.mid, end: item.end)
            let dist = Double(KiMath.round64(DPoint(p - item.center).norm))
            if abs(dist - arc.radius) > maxDist { return false }
            return arc.sliceContainsPoint(p)
        case .via:
            let maxDist = item.width / 2
            let r = DPoint(p - item.start)
            return r.x * r.x + r.y * r.y <= Double(maxDist) * Double(maxDist)
        case .pad:
            guard let pad = item.pad else { return false }
            if item.hitPolygon?.contains(p) ?? false { return true }
            // (GetEffectiveHoleShape()->Collide( aPosition, 0 ))
            if pad.drill.x > 0, case .segment(let s, let w)? = item.hole {
                let d = s.squaredDistance(p)
                return d == 0 || d < (w / 2) * (w / 2)
            }
            return false
        case .footprint:
            return item.ownBox?.contains(p) ?? false
        case .zone:
            // (a floor of a tenth of a millimetre for an exact hit: twice that about a corner)
            let accuracy = 100_000
            for ring in item.rings {
                for q in ring where DPoint(q - p).norm <= Double(2 * accuracy) { return true }
            }
            for ring in item.rings where ring.count >= 2 {
                for k in ring.indices where Seg(ring[k], ring[(k + 1) % ring.count]).squaredDistance(p) <= accuracy * accuracy {
                    return true
                }
            }
            return false
        case .target:
            let radius = item.width / 2
            return abs(p.x - item.start.x) <= radius && abs(p.y - item.start.y) <= radius
        case .point:
            return false
        }
    }
}

// MARK: - The grid helper's construction geometry

extension PCBGridHelper {
    /// The board item a construction item's index names (a negative index: a copy of that item, the point editor's,
    /// `-1 - i`)
    func boardItem(_ ref: Int) -> SnapBoard.Item { board.items[ref >= 0 ? ref : -1 - ref] }

    /// PCB_GRID_HELPER::AddConstructionItems: the construction geometry of the items (by index; `-1 - i` for a copy of
    /// item `i`), proposed as one batch: a line's, the line through it (`extensionOnly`: the two rays on from its ends)
    /// and, persistent, its ends as points the snap line goes through but the pointer does not snap to; an arc's, its
    /// circle (`extensionOnly`: the rest of it) and its centre, and persistent, its ends so too; a circle's or a
    /// rectangle's, its centre; anything else, none (but it is proposed all the same, and taken counts as involved).
    /// Nothing where extension snaps are off (ADVANCED_CFG's EnableExtensionSnaps).
    public mutating func addConstructionItems(_ indices: [Int], extensionOnly: Bool, persistent: Bool, view: SnapView) {
        guard view.extensionSnaps else { return }
        var batch: ConstructionManager.Batch = []
        var referenceOnly: [IPoint] = []
        for i in indices {
            var drawables: [ConstructionDrawable] = []
            let item = boardItem(i)
            if item.kind == .shape, let d = item.drawing {
                switch d.kind {
                case .segment:
                    if !extensionOnly {
                        drawables.append(.line(Seg(d.start, d.end)))
                    } else {
                        let v = d.end - d.start
                        drawables.append(.halfLine(Seg(d.start, d.start - v)))
                        drawables.append(.halfLine(Seg(d.end, d.end + v)))
                    }
                    if persistent {
                        drawables += [.point(d.start), .point(d.end)]
                        referenceOnly += [d.start, d.end]
                    }
                case .arc:
                    if !extensionOnly {
                        // (EDA_SHAPE::GetRadius: the centre to the start, rounded, at least 1)
                        drawables.append(.circle(Circle(d.center, max(1, KiMath.round(DPoint(d.start - d.center).norm)))))
                    } else {
                        // (the rest of the circle: the arc through the point opposite its middle)
                        let opposite = d.center + (d.center - item.mid)
                        drawables.append(.arc(ShapeArc(start: d.start, mid: opposite, end: d.end)))
                    }
                    drawables.append(.point(d.center))
                    if persistent {
                        drawables += [.point(d.start), .point(d.end)]
                        referenceOnly += [d.start, d.end]
                    }
                case .circle:
                    drawables.append(.point(d.start))
                case .rect:
                    // (EDA_SHAPE::getCenter of a rectangle: its corners' middle)
                    drawables.append(.point(d.start + (d.end - d.start).divided(by: 2)))
                default:
                    break
                }
            }
            batch.append(ConstructionManager.Item(source: .items, item: i, constructions: drawables))
        }
        if !referenceOnly.isEmpty { referenceOnlyPoints = referenceOnly }
        construction.propose(batch, persistent: persistent)
    }

    /// proposeConstructionForItems: the items an anchor snapped to is of (or the item hovered over), those on the
    /// layers snapped to (or on any, with the Magnetic Points' all layers), proposed as a temporary batch of their
    /// extensions
    mutating func proposeConstruction(for items: [Int?], layers: Set<Int>, view: SnapView) {
        var chosen: [Int] = []
        for case let i? in items {
            if magnetic.allLayers || !Set(boardItem(i).layers).isDisjoint(with: layers) { chosen.append(i) }
        }
        addConstructionItems(chosen, extensionOnly: true, persistent: false, view: view)
    }

    /// The pointer rested where it is long enough for KiCad's timer to take what it proposed (ExtensionSnapTimeoutMs,
    /// half a second by default): the construction geometry pending, if any, taken, for the next pointer event to snap
    /// to
    public mutating func rested() {
        construction.timerExpired()
    }

    /// Whether the grid helper waits for the pointer to rest to take what it proposed
    public var hasPendingConstruction: Bool { construction.hasPendingProposal }

    /// SNAP_MANAGER::GetConstructionItems: the batches taken, then the snap line's (a line through its origin in each
    /// of its directions, of no item)
    func constructionItems() -> [ConstructionManager.Batch] {
        var out = construction.batches
        if let o = snapLineOrigin {
            let lines = directions.map { ConstructionDrawable.line(Seg(o, o + IPoint($0.x * 100_000, $0.y * 100_000))) }
            if !lines.isEmpty { out.append([ConstructionManager.Item(source: .snapLine, item: nil, constructions: lines)]) }
        }
        return out
    }

    /// The construction geometry KiCad shows (CONSTRUCTION_GEOM's drawables: the batches taken, the persistent one
    /// first), each with whether it is the persistent batch's
    public var shownConstruction: [(drawable: ConstructionDrawable, persistent: Bool)] {
        var out: [(ConstructionDrawable, Bool)] = []
        if let p = construction.persistentBatch { for item in p { for d in item.constructions { out.append((d, true)) } } }
        for b in construction.temporaryBatches { for item in b { for d in item.constructions { out.append((d, false)) } } }
        return out
    }
}
