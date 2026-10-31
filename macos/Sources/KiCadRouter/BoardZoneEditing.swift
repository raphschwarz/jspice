// A zone's outline edited after it is drawn, as KiCad's point editor edits it (KiCad 10.0.8:
// pcbnew/tools/pcb_point_editor.cpp, PCB_POINT_EDITOR's OnSelectionChange drag, addCorner, removeCorner and
// CanRemoveCorner, its ZONE_POINT_EDIT_BEHAVIOR; common/tool/point_editor_behavior.cpp, POLYGON_POINT_EDIT_BEHAVIOR;
// common/tool/edit_constraints.cpp, EC_CONVERGING and EC_LINE; common/tool/edit_points.cpp, EDIT_POINTS' contours),
// and zones moved whole as its Move moves them (ZONE::Move), locked ones left alone as its selection filter leaves them
// (PCB_SELECTION_TOOL::FilterCollectorForLockedItems). Copyright The KiCad Developers, see KiCad's AUTHORS.txt. GNU
// General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

extension BoardEditing {
    /// A zone's outline as KiCad's point editor has it: its contours (the outline, then its holes), each a closed
    /// ring of corners in nanometres, as KiCad's parser reads them (a corner the same as the one before it left out, and a
    /// last the same as the first)
    public typealias ZoneContours = [[IPoint]]

    /// One of the handles KiCad's point editor puts on a zone: a corner, by its place among all the contours' corners
    /// (the outline's first, then each hole's), or the midpoint of an edge, by the place of the corner it starts at
    /// (it runs to the next corner of its contour, the last back to the first)
    public enum ZoneHandle: Hashable, Sendable {
        case corner(Int)
        case edge(Int)
    }

    /// A zone's outline (its contours in nanometres) as the point editor edits it; nil for a zone of no such id, a
    /// teardrop, or one whose outline has arcs (KiCad's editor gives each arc's polyline points of its own)
    public func zoneContours(_ uuid: String) -> ZoneContours? {
        guard let node = zoneNode(uuid) else { return nil }
        return Self.contours(of: node)
    }

    /// The contours of a zone node, as the parser reads them; nil where its outline has arcs or it is a teardrop
    static func contours(of node: SExpr) -> ZoneContours? {
        guard node["attr"]?["teardrop"] == nil else { return nil }
        var out: ZoneContours = []
        for poly in node.all("polygon") {
            let pts = poly["pts"]?.arguments ?? []
            guard !pts.contains(where: { $0.head == "arc" }) else { return nil }
            var chain: [IPoint] = []
            for q in pts where q.head == "xy" {
                let p = BoardWorld.point(q)
                if chain.last != p { chain.append(p) }
            }
            // (closed, its last corner the same as its first merged into it: SHAPE_LINE_CHAIN::SetClosed)
            if chain.count > 1 && chain.first == chain.last { chain.removeLast() }
            if !chain.isEmpty { out.append(chain) }
        }
        return out.isEmpty ? nil : out
    }

    /// The board's zone (or rule area) of that id, its own (not a footprint's)
    func zoneNode(_ uuid: String) -> SExpr? {
        router.board.root.all("zone").first { $0.value("uuid") == uuid }
    }

    /// Whether an item's node is locked, as BOARD_ITEM::IsLocked has it: its own flag, or a group's or tuning
    /// pattern's it is in
    func isLockedNode(_ node: SExpr) -> Bool {
        if node.value("locked") == "yes" || node.flag("locked") { return true }
        guard let uuid = node.value("uuid") else { return false }
        return (router.board.root.all("group") + router.board.root.all("generated")).contains { g in
            (g.value("locked") == "yes" || g.flag("locked")) && (g["members"]?.arguments.contains { $0.text == uuid } ?? false)
        }
    }

    /// Whether KiCad's point editor edits the zone: there is one, not a teardrop, its outline without arcs, and not
    /// locked (unless overridesLocks: OnSelectionChange edits no locked item)
    public func canEditZoneOutline(_ uuid: String) -> Bool {
        guard !isRouting, let node = zoneNode(uuid), Self.contours(of: node) != nil else { return false }
        return overridesLocks || !isLockedNode(node)
    }

    // MARK: - Dragging a corner or an edge

    /// A corner or edge being dragged, as the point editor holds it from the button going down: the edit points (the
    /// contours' corners, where the drag has them), which handle, the constraint of an edge (EC_CONVERGING, as made
    /// from the outline when the drag started), and the angle snap's state
    struct ZoneDrag {
        var uuid: String
        var handle: ZoneHandle
        var original: ZoneContours
        /// The edit points, all the contours' corners in a row, and where each contour ends (EDIT_POINTS' m_contours)
        var points: [IPoint]
        var contourEnds: [Int]
        var converging: Converging?
        var angleSnapActive = false
        var angleSnapPos = IPoint.zero
        var moved = false
    }

    /// EC_CONVERGING: an edge dragged parallel to itself, its neighbours keeping their directions
    struct Converging {
        var origin: Int, end: Int
        var prevOrigin: Int, nextEnd: Int
        /// EC_LINE's m_line of each neighbour (the corner less the one it is constrained by, when it was made)
        var originSideLine: IPoint, endSideLine: IPoint
        var draggedVector: IPoint
        var originalCenter: IPoint
        var perpVector: IPoint
        var halfLength: Double
        var originCollinear: Bool, endCollinear: Bool
        /// Whether the edges either side of it end at the same corner (m_contourIsTriangle)
        var contourIsTriangle: Bool
        /// Which side's line the edge follows when both neighbours run on along it (m_colinearConstraint)
        var collinearIsOriginSide: Bool?
        var convergencePoint: IPoint
    }

    /// The edit points of `contours` (BuildForPolyOutline): every corner in a row, and where each contour ends
    static func editPoints(_ contours: ZoneContours) -> (points: [IPoint], ends: [Int]) {
        var points: [IPoint] = [], ends: [Int] = []
        for c in contours {
            points += c
            ends.append(points.count - 1)
        }
        return (points, ends)
    }

    static func contourStart(_ i: Int, _ ends: [Int]) -> Int {
        var last = 0
        for e in ends {
            if e >= i { return last }
            last = e + 1
        }
        return last
    }

    static func contourEnd(_ i: Int, _ ends: [Int], count: Int) -> Int { ends.first { $0 >= i } ?? count - 1 }

    static func isContourStart(_ i: Int, _ ends: [Int]) -> Bool {
        for e in ends {
            if e + 1 == i { return true }
            if e > i { break }
        }
        return i == 0
    }

    static func isContourEnd(_ i: Int, _ ends: [Int], count: Int) -> Bool {
        for e in ends {
            if e == i { return true }
            if e > i { break }
        }
        return i == count - 1
    }

    /// EDIT_POINTS::Previous and Next, not across contours: of the first point at the same place as `i` (EDIT_POINT's
    /// equality is its position's)
    static func previous(_ i: Int, _ points: [IPoint], _ ends: [Int]) -> Int {
        let k = points.firstIndex(of: points[i]) ?? i
        if isContourStart(k, ends) { return contourEnd(k, ends, count: points.count) }
        return k == 0 ? points.count - 1 : k - 1
    }

    static func next(_ i: Int, _ points: [IPoint], _ ends: [Int]) -> Int {
        let k = points.firstIndex(of: points[i]) ?? i
        if isContourEnd(k, ends, count: points.count) { return contourStart(k, ends) }
        return k == points.count - 1 ? 0 : k + 1
    }

    /// The corner an edge runs to (the line's end: the next of its contour, the last back to its first)
    static func lineEnd(_ i: Int, _ ends: [Int], count: Int) -> Int {
        isContourEnd(i, ends, count: count) ? contourStart(i, ends) : i + 1
    }

    /// EDIT_LINE::GetPosition: half of each end, each rounded
    static func midpoint(_ a: IPoint, _ b: IPoint) -> IPoint { a.divided(by: 2) + b.divided(by: 2) }

    /// SEG::Angle: the angle between two segments' directions (A less B), 0 to 180°
    static func segAngle(_ a: Seg, _ b: Seg) -> Double {
        let ta = EDAAngle(a.a - a.b).normalized180, tb = EDAAngle(b.a - b.b).normalized180
        return abs(EDAAngle(degrees: ta.degrees - tb.degrees).normalized180.degrees)
    }

    /// EC_CONVERGING's constructor, for the edge starting at point `i`
    static func converging(_ i: Int, _ points: [IPoint], _ ends: [Int]) -> Converging {
        let end = lineEnd(i, ends, count: points.count)
        let prevOrigin = previous(i, points, ends), nextEnd = next(end, points, ends)
        let o = points[i], e = points[end], po = points[prevOrigin], ne = points[nextEnd]
        let dragged = e - o
        let center = midpoint(o, e)
        let originSide = Seg(o, po), endSide = Seg(e, ne), draggedSeg = Seg(o, e)
        let originCollinear = segAngle(draggedSeg, originSide) < 10
        let endCollinear = segAngle(draggedSeg, endSide) < 10
        let convergence = originSide.intersectLines(endSide) ?? center
        return Converging(origin: i, end: end, prevOrigin: prevOrigin, nextEnd: nextEnd, originSideLine: o - po,
                          endSideLine: e - ne, draggedVector: dragged, originalCenter: center, perpVector: dragged.perpendicular,
                          halfLength: Double(dragged.norm) / 2, originCollinear: originCollinear, endCollinear: endCollinear,
                          contourIsTriangle: prevOrigin == nextEnd, collinearIsOriginSide: originCollinear ? true : endCollinear ? false : nil, convergencePoint: convergence)
    }

    /// EC_LINE::Apply: `p` projected onto the line through `constrainer` along `line` (on a grid of a nanometre, as
    /// the converging constraint's own dummy grid is)
    static func projected(_ p: IPoint, on constrainer: IPoint, along line: IPoint) -> IPoint {
        let main = Seg(constrainer, constrainer + line)
        let projection = Seg(p, p + line.perpendicular)
        return projection.intersectLines(main) ?? p
    }

    /// EC_CONVERGING::Apply, the edge's handle at `handle`: the edge's two corners set
    static func applyConverging(_ c: Converging, handle: IPoint, fixedLength: Bool, points: inout [IPoint]) {
        let perpLine = Seg(c.originalCenter, c.originalCenter + c.perpVector)
        let toHandle = Seg(handle, handle + c.draggedVector)
        var newCenter = perpLine.intersectLines(toHandle) ?? handle
        // (not past the point the neighbours converge at, unless the contour is a triangle, with no corner to fold
        // away there)
        if !fixedLength && !c.contourIsTriangle {
            let centerToConv = c.convergencePoint - c.originalCenter
            let centerToNew = newCenter - c.originalCenter
            if centerToConv.dot(c.perpVector) != 0 {
                let t = Double(centerToNew.dot(c.perpVector)) / Double(centerToConv.dot(c.perpVector))
                if t > 1 { newCenter = c.convergencePoint }
            }
        }
        // (EDIT_LINE::SetPosition: both ends moved by the handle's move)
        let difference = newCenter - midpoint(points[c.origin], points[c.end])
        points[c.origin] += difference
        points[c.end] += difference
        let center = midpoint(points[c.origin], points[c.end])
        if fixedLength {
            // applyFixedLength: the edge as long as it was, about the new centre
            var unit = DPoint(c.draggedVector)
            if unit.norm > 0 { unit = unit / unit.norm }
            let half = (unit * c.halfLength).rounded
            points[c.origin] = center - half
            points[c.end] = center + half
            return
        }
        // applyConverging
        if c.originCollinear && c.endCollinear {
            if let originSide = c.collinearIsOriginSide {
                let (constrainer, line) = originSide ? (points[c.prevOrigin], c.originSideLine) : (points[c.nextEnd], c.endSideLine)
                points[c.origin] = projected(points[c.origin], on: constrainer, along: line)
                points[c.end] = projected(points[c.end], on: constrainer, along: line)
            }
            return
        }
        let half = c.draggedVector.divided(by: 2)
        let dragged = Seg(center - half, center + half)
        let originSide = Seg(points[c.prevOrigin], points[c.prevOrigin] + c.originSideLine)
        let endSide = Seg(points[c.nextEnd], points[c.nextEnd] + c.endSideLine)
        if let p = dragged.intersectLines(originSide) { points[c.origin] = p }
        if let p = dragged.intersectLines(endSide) { points[c.end] = p }
        if c.contourIsTriangle { return }
        // (the neighbours crossing: the polygon would cross itself, the edge made a point where they cross)
        let o = Seg(points[c.origin], points[c.prevOrigin]), e = Seg(points[c.end], points[c.nextEnd])
        if let p = e.intersect(o) {
            points[c.origin] = p
            points[c.end] = p
        }
    }

    /// snapCorner: of the two circles through `prev` and `next` on which the corner sees them at `degrees`, the
    /// point of the one nearer `guess` nearest it
    static func snapCorner(_ prev: IPoint, _ next: IPoint, _ guess: IPoint, _ degrees: Double) -> IPoint {
        let rad = degrees * Double.pi / 180
        let p = DPoint(prev), n = DPoint(next)
        let chord = (n - p).norm
        let sinA = sin(rad)
        if chord == 0 || abs(sinA) < 1e-9 { return guess }
        let radius = chord / (2 * sinA)
        let mid = (p + n) / 2
        let dir = n - p
        let normal = DPoint(-dir.y, dir.x).resized(1)
        let hsq = radius * radius - chord * chord / 4
        let h = hsq > 0 ? hsq.squareRoot() : 0
        func project(_ center: DPoint) -> IPoint {
            var v = DPoint(guess) - center
            if v.norm == 0 { v = p - center }
            v = v.resized(1)
            return (center + v * radius).rounded
        }
        let p1 = project(mid + normal * h), p2 = project(mid - normal * h)
        let d1 = (DPoint(guess) - DPoint(p1)).norm, d2 = (DPoint(guess) - DPoint(p2)).norm
        return d1 < d2 ? p1 : p2
    }

    /// The zone drag in progress, if one is
    public var isDraggingZonePoint: Bool { zoneDrag != nil }

    /// Starts dragging a corner or an edge of the zone, as the point editor starts when the button goes down on one of
    /// its handles: nil where the point editor would not edit the zone (canEditZoneOutline) or it has no such handle;
    /// else the outline as it is (mm)
    @discardableResult
    public func startZoneDrag(_ uuid: String, handle: ZoneHandle) -> [[KiCadPoint]]? {
        guard canEditZoneOutline(uuid), let contours = zoneContours(uuid) else { return nil }
        let (points, ends) = Self.editPoints(contours)
        switch handle {
        case .corner(let i), .edge(let i):
            guard i >= 0 && i < points.count else { return nil }
        }
        var drag = ZoneDrag(uuid: uuid, handle: handle, original: contours, points: points, contourEnds: ends)
        if case .edge(let i) = handle { drag.converging = Self.converging(i, points, ends) }
        zoneDrag = drag
        return contours.map { $0.map(Self.mm) }
    }

    /// The pointer dragged to `p` (mm, where it is, before any snapping), as the point editor's drag moves the handle:
    /// an edge kept parallel to itself and its neighbours to their directions (with `ctrl`, KiCad's Ctrl, at its own
    /// length instead), its move across itself on `grid` (mm, the grid's size; nil for none) as KiCad quantizes it; a
    /// corner put where `snap` puts the pointer (the grid's and the items' anchors, KiCad's BestSnapAnchor; as it is
    /// if nil), or, unless `shift`, where it sees its neighbours at a multiple of 45° when within 2° of one (sticky
    /// until the pointer goes `stickyDistance` (mm, KiCad's five pixels) from it). The outline as it now goes (mm).
    @discardableResult
    public func dragZonePoint(to p: KiCadPoint, ctrl: Bool = false, shift: Bool = false, grid: Double? = nil,
                              stickyDistance: Double = 0, snap: ((KiCadPoint) -> KiCadPoint)? = nil) -> [[KiCadPoint]]? {
        guard var d = zoneDrag else { return nil }
        let raw = Self.nm(p)
        var pos = raw
        let snapped = { (q: IPoint) -> IPoint in snap.map { Self.nm($0(Self.mm(q))) } ?? q }
        if case .edge = d.handle, let grid, grid > 0, let c = d.converging {
            // (an edge moves across itself only: its move across quantized on the grid, so that each step is one place)
            let perp = DPoint(c.perpVector)
            let perpLen = perp.norm
            if perpLen > 0 {
                let unit = perp / perpLen
                let g = Double(KiMath.round(grid * 1e6))
                let step = hypot(g * unit.x, g * unit.y)
                if step > 0 {
                    let off = DPoint(pos - c.originalCenter)
                    let offset = off.x * unit.x + off.y * unit.y
                    let along = (offset / step).rounded(.toNearestOrAwayFromZero) * step
                    pos = (DPoint(c.originalCenter) + unit * along).rounded
                }
            }
        }
        if d.angleSnapActive {
            let sticky = raw - d.angleSnapPos
            let limit = KiMath.round(stickyDistance * 1e6)
            if sticky.norm > limit || shift {
                d.angleSnapActive = false
            } else {
                pos = d.angleSnapPos
            }
        }
        if case .corner(let idx) = d.handle, !d.angleSnapActive, d.points.count > 2, !shift {
            // (the corner's neighbours as the point editor finds them: the points before and after it in the row of
            // all the contours' points, whichever contour they are of)
            let prev = d.points[(idx + d.points.count - 1) % d.points.count], next = d.points[(idx + 1) % d.points.count]
            let ang = Self.segAngle(Seg(pos, prev), Seg(pos, next))
            let snapAng = 45 * (ang / 45).rounded(.toNearestOrAwayFromZero)
            if abs(ang - snapAng) < 2 {
                var s = Self.snapCorner(prev, next, pos, snapAng)
                if snap != nil {
                    let gridded = snapped(s)
                    s = abs(Self.segAngle(Seg(gridded, prev), Seg(gridded, next)) - snapAng) < 2 ? gridded : pos
                }
                if s != pos {
                    d.angleSnapPos = s
                    d.angleSnapActive = true
                    pos = s
                }
            }
        }
        switch d.handle {
        case .edge(let i):
            if !d.angleSnapActive, let c = d.converging {
                // (the handle put there, then the constraint applied)
                let mid = Self.midpoint(d.points[i], d.points[c.end])
                d.points[i] += pos - mid
                d.points[c.end] += pos - mid
                Self.applyConverging(c, handle: Self.midpoint(d.points[i], d.points[c.end]), fixedLength: ctrl,
                                     points: &d.points)
                if snap != nil {
                    // (an anchor the edge's line passes near: the edge put through it, if the constraint leaves it
                    // within KiCad's five pixels of it)
                    let constrained = d.points
                    let at = Self.midpoint(d.points[i], d.points[c.end])
                    let anchor = snapped(at)
                    if anchor != at {
                        d.points[i] += anchor - at
                        d.points[c.end] += anchor - at
                        Self.applyConverging(c, handle: Self.midpoint(d.points[i], d.points[c.end]), fixedLength: ctrl,
                                             points: &d.points)
                        let projected = Self.midpoint(d.points[i], d.points[c.end])
                        if (projected - anchor).norm > KiMath.round(stickyDistance * 1e6) { d.points = constrained }
                    }
                }
            } else {
                let mid = Self.midpoint(d.points[i], d.points[Self.lineEnd(i, d.contourEnds, count: d.points.count)])
                let end = Self.lineEnd(i, d.contourEnds, count: d.points.count)
                d.points[i] += pos - mid
                d.points[end] += pos - mid
            }
        case .corner(let i):
            d.points[i] = !d.angleSnapActive && snap != nil ? snapped(pos) : pos
        }
        d.moved = true
        zoneDrag = d
        return Self.contours(d.points, d.contourEnds).map { $0.map(Self.mm) }
    }

    /// The edit points made contours again
    static func contours(_ points: [IPoint], _ ends: [Int]) -> ZoneContours {
        var out: ZoneContours = []
        var start = 0
        for e in ends {
            out.append(Array(points[start...e]))
            start = e + 1
        }
        return out
    }

    /// The button let go: the drag kept as one change, "Move Point" as KiCad names it: the outline as dragged, its
    /// corners the same as the ones after them taken out where three corners or more are left
    /// (FinalizeItem's RemoveNullSegmentsIfPolygonSurvives), the zone unfilled and then filled again (refillsZones).
    /// Nil if the drag moved nothing.
    public func finishZoneDrag() -> Edit? {
        guard let d = zoneDrag else { return nil }
        zoneDrag = nil
        guard d.moved, let node = zoneNode(d.uuid) else { return nil }
        let contours = Self.removingNullSegmentsIfPolygonSurvives(Self.contours(d.points, d.contourEnds))
        guard contours != d.original else { return nil }
        Self.setOutline(node, contours)
        router.boardChanged()
        return change("Move Point", zones: [d.uuid])
    }

    /// The drag dropped (KiCad's Escape), the zone as it was
    public func cancelZoneDrag() { zoneDrag = nil }

    /// A corner of the zone moved to `p` (mm) as one drag of it would put it, without snapping
    public func moveZoneCorner(_ uuid: String, index: Int, to p: KiCadPoint) -> Edit? {
        guard startZoneDrag(uuid, handle: .corner(index)) != nil else { return nil }
        dragZonePoint(to: p, shift: true)
        return finishZoneDrag()
    }

    /// An edge of the zone (the one from corner `index`) dragged with its midpoint's handle to `p` (mm), as one drag of
    /// it would put it: parallel to itself, its neighbours keeping their directions (or, `fixedLength`, at its own
    /// length, as with Ctrl), without snapping
    public func moveZoneEdge(_ uuid: String, index: Int, to p: KiCadPoint, fixedLength: Bool = false) -> Edit? {
        guard startZoneDrag(uuid, handle: .edge(index)) != nil else { return nil }
        dragZonePoint(to: p, ctrl: fixedLength, shift: true)
        return finishZoneDrag()
    }

    /// POLYGON_POINT_EDIT_BEHAVIOR::RemoveNullSegmentsIfPolygonSurvives: the outline with its null segments taken
    /// out (RemoveNullSegments), unless that leaves fewer than three corners in all (TotalVertices), when it is kept
    /// as it is
    static func removingNullSegmentsIfPolygonSurvives(_ contours: ZoneContours) -> ZoneContours {
        let cleaned = removingNullSegments(contours)
        return cleaned.reduce(0) { $0 + $1.count } >= 3 ? cleaned : contours
    }

    /// SHAPE_POLY_SET::RemoveNullSegments: each corner the same as the next of its contour (the last's, the first)
    /// taken out
    static func removingNullSegments(_ contours: ZoneContours) -> ZoneContours {
        contours.map { c in
            // (the corners found first, then taken away from the last back, each as RemoveVertex takes one)
            var out = c
            for k in c.indices.reversed() where c[k] == c[(k + 1) % c.count] { out = removing(k, from: out) }
            return out
        }
    }

    /// SHAPE_LINE_CHAIN::Remove of one corner of a closed contour: the corner taken out, then its last corner merged
    /// into its first where they are the same (SetClosed, mergeFirstLastPointIfNeeded)
    static func removing(_ k: Int, from contour: [IPoint]) -> [IPoint] {
        var c = contour
        guard k < c.count else { return c }
        c.remove(at: k)
        if c.count > 1 && c.first == c.last { c.removeLast() }
        return c
    }

    /// The zone's outline made `contours` (the outline, then its holes), as KiCad writes them (each a polygon of its
    /// corners, one of none left out), and the zone unfilled (ZONE::UnFill)
    static func setOutline(_ node: SExpr, _ contours: ZoneContours) {
        let at = node.items.firstIndex { $0.head == "polygon" } ?? node.items.firstIndex { $0.head == "filled_polygon" } ?? node.items.count
        node.items.removeAll { $0.head == "polygon" }
        let polys = contours.filter { !$0.isEmpty }.map { c in
            SExpr("polygon", SExpr("pts", c.map { SExpr("xy", Double($0.x) / 1e6, Double($0.y) / 1e6) as SExprConvertible }))
        }
        node.items.insert(contentsOf: polys, at: min(at, node.items.count))
        unfill(node)
    }

    /// ZONE::UnFill: its fills dropped, no longer filled
    static func unfill(_ node: SExpr) {
        node.remove("filled_polygon")
        node.remove("fill_segments")
        if let fill = node["fill"] { fill.items.removeAll { $0.kind == .symbol && $0.text == "yes" } }
    }

    // MARK: - Corners added and taken away

    /// A corner added to the zone at the edge nearest `p` (mm, where the pointer is, on the grid), as the point
    /// editor's Add Corner adds one: the nearest point of the edge (of the outline or a hole) nearest `p`, or the
    /// edge's midpoint where that is one of its corners, put before the edge's end; "Add Zone Corner", the zone
    /// unfilled and filled again
    public func addZoneCorner(_ uuid: String, at p: KiCadPoint) -> Edit? {
        guard canEditZoneOutline(uuid), let node = zoneNode(uuid), var contours = Self.contours(of: node) else { return nil }
        let cursor = Self.nm(p)
        let (points, ends) = Self.editPoints(contours)
        var nearestIdx = 0, nextNearestIdx = 0
        var nearestDist = UInt32(Int32.max)
        var firstPointInContour = 0
        for curr in 0..<points.count {
            var jj = curr + 1
            if Self.isContourEnd(curr, ends, count: points.count) {
                jj = firstPointInContour
                firstPointInContour = curr + 1
            }
            // (SEG::Distance, held as an unsigned int)
            let distance = UInt32(truncatingIfNeeded: Seg(points[curr], points[jj]).distance(cursor))
            if distance < nearestDist {
                nearestDist = distance
                nearestIdx = curr
                nextNearestIdx = jj
            }
        }
        let sideOrigin = points[nearestIdx], sideEnd = points[nextNearestIdx]
        var nearest = Seg(sideOrigin, sideEnd).nearestPoint(cursor)
        if nearest == sideOrigin || nearest == sideEnd { nearest = (sideOrigin + sideEnd).divided(by: 2) }
        // (SHAPE_POLY_SET::InsertVertex at the edge's end's global index: before it in its contour)
        var k = nextNearestIdx
        for c in contours.indices {
            if k < contours[c].count {
                contours[c].insert(nearest, at: k)
                break
            }
            k -= contours[c].count
        }
        Self.setOutline(node, contours)
        router.boardChanged()
        return change("Add Zone Corner", zones: [uuid])
    }

    /// Whether the corner can be taken away, as CanRemoveCorner says: the zone editable, and the corner (the first of
    /// the outline's at its place) not one of an outline of three; a hole's may be, which takes the hole away
    public func canRemoveZoneCorner(_ uuid: String, index: Int) -> Bool {
        guard canEditZoneOutline(uuid), let contours = zoneContours(uuid), let (c, _) = Self.findVertex(contours, index) else { return false }
        return !(c == 0 && contours[0].count <= 3)
    }

    /// findVertex: the contour and place in it of the first corner at the same place as corner `index`
    static func findVertex(_ contours: ZoneContours, _ index: Int) -> (contour: Int, vertex: Int)? {
        let (points, _) = editPoints(contours)
        guard index >= 0 && index < points.count else { return nil }
        let target = points[index]
        for (c, contour) in contours.enumerated() {
            if let v = contour.firstIndex(of: target) { return (c, v) }
        }
        return nil
    }

    /// A corner taken away, as the point editor's Remove Corner takes it: the first corner at its place; a hole of
    /// three corners taken away with it; "Remove Zone Corner", the zone unfilled and filled again. Nil where
    /// canRemoveZoneCorner says no (the menu has no Remove Corner then).
    public func removeZoneCorner(_ uuid: String, index: Int) -> Edit? {
        guard canRemoveZoneCorner(uuid, index: index), let node = zoneNode(uuid), var contours = Self.contours(of: node),
              let (c, v) = Self.findVertex(contours, index) else { return nil }
        if contours[c].count > 3 {
            contours[c] = Self.removing(v, from: contours[c])
        } else {
            contours.remove(at: c)
        }
        Self.setOutline(node, contours)
        router.boardChanged()
        return change("Remove Zone Corner", zones: [uuid])
    }

    // MARK: - Zones moved

    /// Zones (and rule areas) moved by `delta` (mm), as KiCad's Move moves them (ZONE::Move: the outline and the fills
    /// with it), the locked ones left where they are as KiCad's selection for a move leaves them (unless
    /// overridesLocks), as one change, the zones then filled again (refillsZones); nil if none is moved
    public func moveZones(_ uuids: [String], by delta: KiCadPoint) -> Edit? {
        guard !isRouting, delta != .zero else { return nil }
        let wanted = Set(uuids)
        let d = Self.nm(delta)
        var moved: [String] = []
        for node in router.board.root.all("zone") where wanted.contains(node.value("uuid") ?? "") {
            guard overridesLocks || !isLockedNode(node), let uuid = node.value("uuid") else { continue }
            // (its outline as KiCad read it, moved; one with arcs, moved in place)
            let contours = Self.contours(of: node)
            if let contours {
                let fill = node["fill"]?.copy()
                let fills = node.all("filled_polygon")
                Self.setOutline(node, contours.map { $0.map { $0 + d } })
                if let fill, let at = node.items.firstIndex(where: { $0.head == "fill" }) { node.items[at] = fill }
                node.items += fills
            }
            for poly in (contours == nil ? node.all("polygon") : []) + node.all("filled_polygon") {
                for q in poly["pts"]?.arguments ?? [] {
                    let lists = q.head == "xy" ? [q] : ["start", "mid", "end"].compactMap { q[$0] }
                    for list in lists {
                        let p = BoardWorld.point(list) + d
                        list.items[1] = (Double(p.x) / 1e6).sexpr
                        list.items[2] = (Double(p.y) / 1e6).sexpr
                    }
                }
            }
            moved.append(uuid)
        }
        guard !moved.isEmpty else { return nil }
        router.boardChanged()
        return change("Move", zones: moved)
    }

    // MARK: - Zones picked

    /// The zone (or rule area) clicked at `p` (mm), as KiCad's selection picks one: by a corner within twice `slop`
    /// (mm, the pointer's reach, at least 0.1 mm) or an edge within it (ZONE::HitTest); else by its fill on one of
    /// `layers`, the first that has one (a rule area by its inside, as HitTestFilledArea treats it). Of several, the
    /// smallest (as the selection's guess takes the smallest of items overlapping). Nil where there is none.
    public func zone(at p: KiCadPoint, layers: [String], slop: Double) -> String? {
        let reach = max(slop, 0.1)
        var hits: [(uuid: String, area: Double)] = []
        var inside: [(uuid: String, area: Double, layer: Int)] = []
        for zone in router.board.zones where zone.node["attr"]?["teardrop"] == nil {
            let rings = zoneContours(zone.uuid).map { $0.map { $0.map(Self.mm) } } ?? [zone.outline]
            guard let outline = rings.first, outline.count > 2 else { continue }
            let area = Self.ringArea(outline)
            let corner = rings.contains { $0.contains { hypot($0.x - p.x, $0.y - p.y) <= 2 * reach } }
            let edge = rings.contains { r in r.indices.contains { Self.segmentDistance(p, r[$0], r[($0 + 1) % r.count]) <= reach } }
            if corner || edge {
                hits.append((zone.uuid, area))
                continue
            }
            for (i, layer) in layers.enumerated() where zone.layers.contains(layer) || zone.layers.contains("*.Cu") {
                let holds = zone.isRuleArea
                    ? KiCadPolygon.contains(outline, p) && !rings.dropFirst().contains { KiCadPolygon.contains($0, p) }
                    : zone.fills.filter { $0.layer == layer }.reduce(false) { $0 != KiCadPolygon.contains($1.points, p) }
                if holds {
                    inside.append((zone.uuid, area, i))
                    break
                }
            }
        }
        if let best = hits.min(by: { $0.area < $1.area }) { return best.uuid }
        return inside.min { ($0.layer, $0.area) < ($1.layer, $1.area) }?.uuid
    }

    /// How far `p` is from the segment from `a` to `b` (mm)
    static func segmentDistance(_ p: KiCadPoint, _ a: KiCadPoint, _ b: KiCadPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y, l = dx * dx + dy * dy
        let t = l == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l))
        return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
    }

    /// The area a ring holds (mm²)
    static func ringArea(_ ring: [KiCadPoint]) -> Double {
        abs(ring.indices.reduce(0.0) { s, i in
            let a = ring[i], b = ring[(i + 1) % ring.count]
            return s + a.x * b.y - b.x * a.y
        }) / 2
    }
}
