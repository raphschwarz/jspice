// Graphics drawn on the board and edited, as KiCad's PCB editor draws and edits them (KiCad 10.0.7): pcbnew/tools/
// drawing_tool.cpp (DRAWING_TOOL::DrawLine, DrawRectangle, DrawCircle and DrawArc, with drawShape and drawArc, and
// DrawZone drawing a polygon), pcbnew/tools/zone_create_helper.cpp (ZONE_CREATE_HELPER::OnComplete and commitZone, the
// polygon made a PCB_SHAPE), include/preview_items/two_point_geom_manager.h, include/preview_items/
// multistep_geom_manager.h, common/preview_items/arc_geom_manager.cpp, common/preview_items/polygon_geom_manager.cpp,
// libs/kimath/include/geometry/geometry_utils.h (GetVectorSnapped45, GetVectorSnapped90), pcbnew/board_design_settings
// .cpp (GetLineThickness, the line widths of the project's defaults), common/eda_shape.cpp (EDA_SHAPE: SetArcGeometry,
// GetArcMid, CalcArcAngles, GetRadius, getCenter, getPosition, getBoundingBox, move, rotate), pcbnew/pcb_shape.cpp
// (Normalize), pcbnew/tools/pcb_point_editor.cpp (PCB_POINT_EDITOR: a drag of an edit point, RECTANGLE_POINT_EDIT_
// BEHAVIOR, snapCorner, addCorner, removeCorner), common/tool/point_editor_behavior.cpp (the segment's, circle's, arc's
// and polygon's edit behaviours, KI_ARC_EDIT), include/tool/edit_points.h (EDIT_LINE), common/tool/edit_constraints.cpp
// (EC_PERPLINE) and pcbnew/tools/edit_tool.cpp (EDIT_TOOL::Rotate's centre). Written as pcbnew/pcb_io/kicad_sexpr/
// pcb_io_kicad_sexpr.cpp writes a PCB_SHAPE, read as its parser reads one. GNU General Public License version 3 or
// later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// How a drawing tool holds its lines to angles (KiCad's LEADER_MODE, the editor's angle snap mode): not at all
/// (KiCad's default), to 45°, or to 90°
public enum LeaderMode: Int, Sendable, CaseIterable {
    case direct, deg45, deg90
}

/// KiCad's GetVectorSnapped45: `v` onto the nearest of 0, 45 and 90 degrees, its length not kept (its coordinates made
/// equal or nought, so that a vector on a square grid stays on it); `only45`, onto the diagonals alone
public func vectorSnapped45(_ v: IPoint, only45: Bool = false) -> IPoint {
    var n = v
    let ax = abs(v.x), ay = abs(v.y)
    // (std::copysign: the sign of the other coordinate, nought taken as positive)
    func copysign(_ magnitude: Int, _ sign: Int) -> Int { sign < 0 ? -abs(magnitude) : abs(magnitude) }
    if !only45 && ax > ay * 2 {
        n.y = 0
    } else if !only45 && ay > ax * 2 {
        n.x = 0
    } else if ax > ay {
        n.y = copysign(v.x, v.y)
    } else {
        n.x = copysign(v.y, v.x)
    }
    return n
}

/// KiCad's GetVectorSnapped90: `v` onto the nearest of the horizontal and the vertical
public func vectorSnapped90(_ v: IPoint) -> IPoint {
    abs(v.x) >= abs(v.y) ? IPoint(v.x, 0) : IPoint(0, v.y)
}

// MARK: - A board's graphic

/// A graphic of the board's own as KiCad holds it (a PCB_SHAPE, its EDA_SHAPE): a line, rectangle, arc, circle or
/// polygon, its points in nanometres, as KiCad's parser reads it from the board (a rectangle normalized, an arc's
/// centre worked out from its three points and its ends swapped where they wind the other way) and as its editor
/// changes it
public struct BoardShape: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case segment, rectangle, arc, circle, polygon
    }

    public var kind: Kind
    /// A line's and a rectangle's ends, an arc's ends, a circle's centre (`start`) and a point on it (`end`)
    public var start = IPoint.zero
    public var end = IPoint.zero
    /// An arc's centre (EDA_SHAPE's m_arcCenter)
    public var center = IPoint.zero
    /// A polygon's corners (its one outline, closed)
    public var points: [IPoint] = []
    /// The pen's width (its stroke's), and its line style as KiCad writes it ("default", "solid", "dash"...)
    public var width: Int
    public var lineStyle = "default"
    /// Whether a rectangle, circle or polygon is filled
    public var filled = false
    /// A rectangle's corners' radius (EDA_SHAPE::m_cornerRadius)
    public var cornerRadius = 0
    public var layer: String

    /// The arc as it was last set whole (EDA_SHAPE's m_arcMidData): its middle, kept while its ends and centre are
    /// those it had then (GetArcMid), so that an arc read and written again keeps the middle it was written with
    struct ArcMid: Sendable, Equatable {
        var start: IPoint, end: IPoint, center: IPoint, mid: IPoint
    }
    var arcMid: ArcMid?

    public init(kind: Kind, layer: String, width: Int) {
        self.kind = kind
        self.layer = layer
        self.width = width
    }

    /// The heads KiCad writes a board's graphic under
    static let heads: [Kind: String] = [.segment: "gr_line", .rectangle: "gr_rect", .arc: "gr_arc", .circle: "gr_circle",
                                        .polygon: "gr_poly"]

    // MARK: Arcs

    /// EDA_SHAPE::CalcArcAngles: the angles of the arc's start and end about its centre, the end the start's or more
    func arcAngles() -> (start: EDAAngle, end: EDAAngle) {
        let s = EDAAngle(DPoint(start - center))
        var e = EDAAngle(DPoint(end - center))
        if e == s { e = s + .a360 }
        while e < s { e += .a360 }
        return (s, e)
    }

    /// EDA_SHAPE::GetArcAngle
    public var arcAngle: EDAAngle {
        let (s, e) = arcAngles()
        return e - s
    }

    /// EDA_SHAPE::GetArcMid: the middle the arc was set with, while its ends and centre are those; else its start
    /// turned half its angle about its centre
    public var arcMidPoint: IPoint {
        if let m = arcMid, m.start == start, m.end == end, m.center == center { return m.mid }
        return KiMath.rotate(start, around: center, -arcAngle / 2.0)
    }

    /// EDA_SHAPE::SetArcGeometry: the arc through `start`, `mid` and `end`, its centre worked out from them, its ends
    /// swapped where they wind the other way round from KiCad's (its middle then on the other side)
    public mutating func setArcGeometry(start s: IPoint, mid m: IPoint, end e: IPoint) {
        arcMid = nil
        start = s
        end = e
        center = KiMath.arcCenter(s, m, e)
        let newMid = arcMidPoint
        arcMid = ArcMid(start: s, end: e, center: center, mid: m)
        let dist = DPoint(newMid - m), dist2 = DPoint(newMid - center)
        if dist.squaredNorm > dist2.squaredNorm { swap(&start, &end) }
    }

    /// EDA_SHAPE::GetRadius: of an arc or circle, at least a nanometre
    public var radius: Int {
        var r = kind == .arc ? center.distance(start) : start.distance(end)
        if r > Double(Int32.max) / 2 { r = Double(Int32.max) / 2 }
        return max(1, KiMath.round(r))
    }

    // MARK: Where it is

    /// EDA_SHAPE::getBoundingBox (half its pen out), as its corners
    public var boundingBox: IBox {
        var box: IBox
        switch kind {
        case .rectangle, .segment:
            box = IBox(start, end)
        case .circle:
            let r = radius
            box = IBox(minX: start.x - r, minY: start.y - r, maxX: start.x + r, maxY: start.y + r)
        case .arc:
            box = arcBox()
        case .polygon:
            box = IBox(points: points) ?? IBox(.zero, .zero)
        }
        return box.inflated(max(0, width) / 2)
    }

    /// EDA_SHAPE::computeArcBBox: its ends, and each of the circle's four extremes it passes (its centre where it is
    /// filled)
    private func arcBox() -> IBox {
        var box = IBox(start, end)
        if filled { box = box.union(center) }
        let r = radius
        let (s, e) = arcAngles()
        let t1 = s.normalized, t2 = e.normalized
        let right = IPoint(center.x + r, center.y), down = IPoint(center.x, center.y + r)
        let left = IPoint(center.x - r, center.y), up = IPoint(center.x, center.y - r)
        if t2 > t1 {
            if t1 < .zero && t2 > .zero { box = box.union(right) }
            if t1 < .a90 && t2 > .a90 { box = box.union(down) }
            if t1 < .a180 && t2 > .a180 { box = box.union(left) }
            if t1 < .a270 && t2 > .a270 { box = box.union(up) }
        } else {
            if t1 < .zero || t2 > .zero { box = box.union(right) }
            if t1 < .a90 || t2 > .a90 { box = box.union(down) }
            if t1 < .a180 || t2 > .a180 { box = box.union(left) }
            if t1 < .a270 || t2 > .a270 { box = box.union(up) }
        }
        return box
    }

    /// EDA_SHAPE::getCenter: an arc's centre, a circle's, a line's middle, else the middle of its box
    public var shapeCenter: IPoint {
        switch kind {
        case .arc: return center
        case .circle: return start
        case .segment: return (start + end).divided(by: 2)
        case .rectangle, .polygon:
            // (BOX2I::Centre: its corner and half its size, cut toward nought)
            let b = boundingBox
            return IPoint(b.minX + b.width / 2, b.minY + b.height / 2)
        }
    }

    /// EDA_SHAPE::getPosition: an arc's centre, a polygon's first corner, else its start
    public var position: IPoint {
        switch kind {
        case .arc: return center
        case .polygon: return points.first ?? .zero
        default: return start
        }
    }

    // MARK: Changes

    /// EDA_SHAPE::move
    public mutating func move(_ d: IPoint) {
        switch kind {
        case .arc:
            center += d
            if var m = arcMid {
                m.center += d
                m.start += d
                m.end += d
                m.mid += d
                arcMid = m
            }
            start += d
            end += d
        case .segment, .rectangle, .circle:
            start += d
            end += d
        case .polygon:
            points = points.map { $0 + d }
        }
    }

    /// EDA_SHAPE::rotate about `c` (counterclockwise on the screen for a positive angle); false for a rectangle turned
    /// off square, which KiCad makes a polygon (not made here)
    @discardableResult
    public mutating func rotate(around c: IPoint, by a: EDAAngle) -> Bool {
        func r(_ p: IPoint) -> IPoint { KiMath.rotate(p, around: c, a) }
        switch kind {
        case .segment, .circle:
            start = r(start)
            end = r(end)
        case .arc:
            start = r(start)
            end = r(end)
            center = r(center)
            if let m = arcMid { arcMid = ArcMid(start: r(m.start), end: r(m.end), center: r(m.center), mid: r(m.mid)) }
        case .rectangle:
            guard a.normalized.degrees.truncatingRemainder(dividingBy: 90) == 0 else { return false }
            start = r(start)
            end = r(end)
        case .polygon:
            points = points.map(r)
        }
        return true
    }

    /// PCB_SHAPE::Normalize of a rectangle: its start the top left corner, its end the bottom right
    public mutating func normalize() {
        guard kind == .rectangle else { return }
        let s = start, e = end
        start = IPoint(min(s.x, e.x), min(s.y, e.y))
        end = IPoint(max(s.x, e.x), max(s.y, e.y))
    }

    // MARK: Reading and writing

    /// A board's graphic as KiCad's parser reads it (parsePCB_SHAPE); nil for a curve, a polygon with arcs or of more
    /// than one outline, and what is not a graphic. Not `normalized`: a rectangle's start and end as the node has them,
    /// as KiCad has them in memory between one edit and the next (it normalizes them when it reads a board, not after
    /// a rotation)
    public init?(_ node: SExpr, normalized: Bool = true) {
        guard let head = node.head, let kind = Self.heads.first(where: { $0.value == head })?.key else { return nil }
        self.kind = kind
        layer = node.value("layer") ?? node["layers"]?.text(at: 0) ?? ""
        width = node["stroke"]?["width"].map { BoardWorld.iu($0, 0) } ?? node["width"].map { BoardWorld.iu($0, 0) } ?? 0
        lineStyle = node["stroke"]?.value("type") ?? "default"
        let fill = node["fill"]
        let fillValue = fill?.text(at: 0) ?? fill?["type"]?.text(at: 0)
        filled = ["yes", "solid", "hatch", "reverse_hatch", "cross_hatch"].contains(fillValue ?? "")
        switch kind {
        case .segment:
            start = BoardWorld.point(node["start"])
            end = BoardWorld.point(node["end"])
        case .rectangle:
            start = BoardWorld.point(node["start"])
            end = BoardWorld.point(node["end"])
            if normalized { normalize() }
            if let r = node["radius"] {
                // (SetCornerRadius: no more than half the shorter side)
                cornerRadius = max(0, min(BoardWorld.iu(r, 0), min(abs(end.x - start.x), abs(end.y - start.y)) / 2))
            }
        case .circle:
            start = BoardWorld.point(node["center"])
            end = BoardWorld.point(node["end"])
        case .arc:
            setArcGeometry(start: BoardWorld.point(node["start"]), mid: BoardWorld.point(node["mid"]), end: BoardWorld.point(node["end"]))
        case .polygon:
            let pts = node["pts"]?.arguments ?? []
            guard !pts.contains(where: { $0.head == "arc" }) else { return nil }
            points = pts.filter { $0.head == "xy" }.map(BoardWorld.point)
        }
    }

    static func mm(_ v: Int) -> Double { Double(v) / 1e6 }

    /// The shape's geometry and pen written into `node` as KiCad writes a PCB_SHAPE (PCB_IO_KICAD_SEXPR::format: its
    /// points, its corners' radius, its stroke, whether it is filled), its other items (locked, layer, net, uuid) kept
    public func write(into node: SExpr) {
        func xy(_ head: String, _ p: IPoint) -> SExpr { SExpr(head, Self.mm(p.x), Self.mm(p.y)) }
        var items: [SExpr] = [node.items[0]]
        switch kind {
        case .segment: items += [xy("start", start), xy("end", end)]
        case .rectangle:
            items += [xy("start", start), xy("end", end)]
            if cornerRadius > 0 { items.append(SExpr("radius", Self.mm(cornerRadius))) }
        case .circle: items += [xy("center", start), xy("end", end)]
        case .arc: items += [xy("start", start), xy("mid", arcMidPoint), xy("end", end)]
        case .polygon: items.append(SExpr("pts", points.map { xy("xy", $0) as SExprConvertible }))
        }
        items.append(SExpr("stroke", SExpr("width", Self.mm(width)), SExpr("type", Keyword(lineStyle))))
        if kind == .polygon || kind == .rectangle || kind == .circle {
            items.append(SExpr("fill", Keyword(filled ? "yes" : "no")))
        }
        // (what follows the fill in KiCad's order, kept: locked, layer or layers, solder mask margin, net, uuid)
        let geometry: Set<String> = ["start", "end", "mid", "center", "pts", "radius", "stroke", "width", "fill", "angle"]
        items += node.items.dropFirst().filter { !geometry.contains($0.head ?? "") }
        node.items = items
    }

    /// A new graphic of the board's as KiCad writes one, of id `uuid`
    public func node(uuid: String) -> SExpr {
        let node = SExpr(Self.heads[kind]!, SExpr("layer", layer), SExpr("uuid", uuid))
        write(into: node)
        return node
    }
}

extension IBox {
    func union(_ p: IPoint) -> IBox {
        IBox(minX: Swift.min(minX, p.x), minY: Swift.min(minY, p.y), maxX: Swift.max(maxX, p.x), maxY: Swift.max(maxY, p.y))
    }
}

// MARK: - The design settings' widths

/// The pens new graphics take on each class of layer (BOARD_DESIGN_SETTINGS' m_LineThickness, from the project's
/// board.design_settings.defaults, KiCad's own where it has none or one out of range), in nanometres
public struct LineWidths: Sendable, Equatable {
    public var silk = 100_000, copper = 200_000, edges = 50_000, courtyard = 50_000, fab = 100_000, other = 100_000

    public init() {}

    public init(project: [String: Any]?) {
        let defaults = ((project?["board"] as? [String: Any])?["design_settings"] as? [String: Any])?["defaults"] as? [String: Any] ?? [:]
        // (PARAM_SCALED: the millimetres over a millionth, rounded, KiCad's own outside a nanometre to 100 mm)
        func width(_ key: String, _ fallback: Int) -> Int {
            guard let mm = (defaults[key] as? NSNumber)?.doubleValue else { return fallback }
            let v = KiMath.round(mm * (1.0 / 1e-6))
            return v < 1 || v > 100_000_000 ? fallback : v
        }
        silk = width("silk_line_width", silk)
        copper = width("copper_line_width", copper)
        edges = width("board_outline_line_width", edges)
        courtyard = width("courtyard_line_width", courtyard)
        fab = width("fab_line_width", fab)
        other = width("other_line_width", other)
    }

    /// BOARD_DESIGN_SETTINGS::GetLineThickness: the width for `layer`'s class (GetLayerClass)
    public func width(_ layer: String) -> Int {
        switch BoardEditing.textClass(layer) {
        case "silk": return silk
        case "copper": return copper
        case "edges": return edges
        case "courtyard": return courtyard
        case "fab": return fab
        default: return other
        }
    }
}

// MARK: - The drawing tools

/// KiCad's TWO_POINT_GEOMETRY_MANAGER: an origin and an end, the end held to angles as its snap mode says when it is
/// set
struct TwoPointGeometry: Sendable, Equatable {
    var origin = IPoint.zero
    var end = IPoint.zero
    var angleSnap = LeaderMode.direct
    var originSet = false

    mutating func setOrigin(_ p: IPoint) {
        origin = p
        originSet = true
    }

    mutating func setEnd(_ p: IPoint) {
        switch angleSnap {
        case .deg45: end = vectorSnapped45(p - origin) + origin
        case .deg90: end = vectorSnapped90(p - origin) + origin
        case .direct: end = p
        }
    }

    var isEmpty: Bool { !originSet || origin == end }
}

/// KiCad's ARC_GEOM_MANAGER: an arc made by its centre, its start (its radius) and its end's angle, each a step
struct ArcGeometry: Sendable, Equatable {
    enum Step: Int { case setOrigin, setStart, setAngle, complete }
    var step = Step.setOrigin
    var origin = IPoint.zero
    var radius = 0.0
    var startAngle = EDAAngle.zero
    var endAngle = EDAAngle.zero
    var clockwise = false
    var directionLocked = false
    var angleSnap = false
    var lastPoint = IPoint.zero
    /// Whether the geometry has changed since it was made (HasGeometryChanged: KiCad's drawArc never clears it)
    var changed = false

    /// AddPoint: the point taken for the step it is at, and the step moved on (or back, if it is not accepted)
    /// where `lockIn`
    mutating func addPoint(_ p: IPoint, lockIn: Bool) {
        lastPoint = p
        let accepted = acceptPoint(p)
        if lockIn { performStep(accepted) }
        changed = true
    }

    mutating func removeLastPoint() {
        performStep(false)
        _ = acceptPoint(lastPoint)
        changed = true
    }

    private mutating func performStep(_ forward: Bool) {
        step = Step(rawValue: min(max(step.rawValue + (forward ? 1 : -1), 0), Step.complete.rawValue))!
    }

    var isComplete: Bool { step == .complete }

    mutating func toggleClockwise() {
        clockwise.toggle()
        directionLocked = true
        changed = true
    }

    private mutating func acceptPoint(_ p: IPoint) -> Bool {
        switch step {
        case .setOrigin:
            origin = p
            startAngle = .zero
            endAngle = .zero
            return true
        case .setStart: return setStart(p)
        case .setAngle: return setEnd(p)
        case .complete: return false
        }
    }

    /// snapAngle: to the nearest 45 degrees
    private static func snapped(_ a: EDAAngle) -> EDAAngle { .a45 * Double(KiMath.round(a / .a45)) }

    private mutating func setStart(_ p: IPoint) -> Bool {
        let v = p - origin
        radius = Double(v.norm)
        startAngle = EDAAngle(DPoint(v))
        if angleSnap { startAngle = Self.snapped(startAngle) }
        while startAngle < .zero { startAngle += .a360 }
        endAngle = startAngle
        return radius != 0
    }

    private mutating func setEnd(_ p: IPoint) -> Bool {
        endAngle = EDAAngle(DPoint(p - origin))
        if angleSnap { endAngle = Self.snapped(endAngle) }
        while endAngle < .zero { endAngle += .a360 }
        if !directionLocked {
            var ccw = endAngle - startAngle
            if endAngle <= startAngle { ccw += .a360 }
            let cw = EDAAngle(degrees: abs((ccw - .a360).degrees))
            if min(ccw, cw) >= .a90 {
                directionLocked = true
            } else {
                clockwise = cw < ccw
            }
        } else if abs(subtended.degrees) < 90 {
            directionLocked = false
        }
        return endAngle != startAngle
    }

    var subtended: EDAAngle {
        var a = endAngle - startAngle
        if endAngle <= startAngle { a += .a360 }
        if clockwise { a -= .a360 }
        return -a
    }

    /// GetStartRadiusEnd, GetEndRadiusEnd: the radius (cut to a whole number) turned to each angle
    private func radiusEnd(_ angle: EDAAngle) -> IPoint { origin + KiMath.rotate(IPoint(Int(radius), 0), -angle) }
    var startRadiusEnd: IPoint { radiusEnd(startAngle) }
    var endRadiusEnd: IPoint { radiusEnd(endAngle) }

    /// updateArcFromConstructionMgr: the arc's centre the origin, its ends the radius's ends, its start the one KiCad's
    /// counterclockwise arc starts at
    func update(_ arc: inout BoardShape) {
        arc.center = origin
        if subtended < .zero {
            arc.start = startRadiusEnd
            arc.end = endRadiusEnd
        } else {
            arc.start = endRadiusEnd
            arc.end = startRadiusEnd
        }
    }
}

/// KiCad's POLYGON_GEOM_MANAGER: a polygon's corners locked in by clicks, the leader from the last to the pointer (two
/// lines at 45° or 90° where the leader mode says so) and the loop back to the first
struct PolygonGeometry: Sendable, Equatable {
    var leaderMode = LeaderMode.direct
    var locked = LineChain()
    var leader = LineChain()
    var loop = LineChain()

    var inProgress: Bool { locked.pointCount > 0 }

    mutating func addPoint(_ p: IPoint) {
        if leader.pointCount > 1 {
            locked.append(leader.points[leader.pointCount - 2])
            locked.append(leader.lastPoint)
        } else {
            locked.append(p)
        }
        // (intersections allowed, as the polygon tool leaves them)
        if locked.pointCount > 0 { updateTemporaryLines(p) }
    }

    mutating func setCursor(_ p: IPoint) {
        if locked.pointCount > 0 { updateTemporaryLines(p) }
    }

    func closesOutline(_ p: IPoint) -> Bool { locked.pointCount > 0 && locked.points[0] == p }

    mutating func deleteLastCorner() -> IPoint? {
        var last: IPoint?
        if locked.pointCount > 0 {
            last = locked.lastPoint
            locked.remove(locked.pointCount - 1)
        }
        if locked.pointCount > 0 { updateTemporaryLines(leader.lastPoint) }
        return last
    }

    mutating func reset() {
        locked = LineChain()
        leader = LineChain()
        loop = LineChain()
    }

    private static func build45DegLeader(_ endPoint: IPoint, _ last: LineChain) -> LineChain {
        guard last.pointCount >= 1 else { return LineChain() }
        let lastPt = last.lastPoint
        let endD = DPoint(endPoint)
        let lineVec = endD - DPoint(lastPt)
        if last.segmentCount < 1 {
            return LineChain([lastPt, lastPt + vectorSnapped45(IPoint(Int(lineVec.x), Int(lineVec.y)))])
        }
        let lineA = EDAAngle(lineVec)
        let prevA = EDAAngle(DPoint(vectorSnapped45(lastPt - last.points[last.pointCount - 2])))
        let vertical = abs(lineVec.y) > abs(lineVec.x)
        let horizontal = abs(lineVec.y) < abs(lineVec.x)
        let angDiff = abs((lineA - prevA).normalized180.degrees)
        var bendEnd = angDiff < 45 || (angDiff > 90 && angDiff < 135)
        if prevA.normalized90 == .a45 || prevA.normalized90 == -EDAAngle.a45 { bendEnd.toggle() }
        var mid = endD
        let last = DPoint(lastPt)
        if bendEnd {
            if vertical {
                mid = lineVec.y > 0 ? DPoint(last.x, endD.y - abs(lineVec.x)) : DPoint(last.x, endD.y + abs(lineVec.x))
            } else if horizontal {
                mid = lineVec.x > 0 ? DPoint(endD.x - abs(lineVec.y), last.y) : DPoint(endD.x + abs(lineVec.y), last.y)
            }
        } else {
            if vertical {
                mid = lineVec.y > 0 ? DPoint(endD.x, last.y + abs(lineVec.x)) : DPoint(endD.x, last.y - abs(lineVec.x))
            } else if horizontal {
                mid = lineVec.x > 0 ? DPoint(last.x + abs(lineVec.y), endD.y) : DPoint(last.x - abs(lineVec.y), endD.y)
            }
        }
        return LineChain([lastPt, mid.rounded, endPoint])
    }

    private static func build90DegLeader(_ endPoint: IPoint, _ last: LineChain) -> LineChain {
        guard last.pointCount >= 1 else { return LineChain() }
        let lastPt = last.lastPoint
        if lastPt.x == endPoint.x || lastPt.y == endPoint.y { return LineChain([lastPt, endPoint]) }
        return LineChain([lastPt, IPoint(endPoint.x, lastPt.y), endPoint])
    }

    private mutating func updateTemporaryLines(_ endPoint: IPoint) {
        guard locked.pointCount > 0 else { return }
        switch leaderMode {
        case .deg45:
            leader = Self.build45DegLeader(endPoint, locked)
            loop = Self.build45DegLeader(endPoint, locked.reversed()).reversed()
        case .deg90:
            leader = Self.build90DegLeader(endPoint, locked)
            loop = Self.build90DegLeader(endPoint, locked.reversed()).reversed()
        case .direct:
            leader = LineChain([locked.lastPoint, endPoint])
            loop = LineChain()
        }
    }

    /// ZONE_CREATE_HELPER::OnComplete: the corners locked in, and in 45° and 90° modes the leader's and the loop's
    /// that the preview shows, as a closed outline, simplified (points within a nanometre of the line through their
    /// neighbours taken out), its first point too if it is so; nil for fewer than three corners
    func completed() -> [IPoint]? {
        guard locked.pointCount >= 3 else { return nil }
        var chain = LineChain()
        for p in locked.points { chain.append(p) }
        if leaderMode == .deg45 || leaderMode == .deg90 {
            for i in stride(from: 1, to: leader.pointCount, by: 1) { chain.append(leader.points[i]) }
            for i in stride(from: 1, to: loop.pointCount - 1, by: 1) { chain.append(loop.points[i]) }
        }
        chain.setClosed(true)
        chain.simplify(1)
        if chain.pointCount >= 3 {
            let seg = Seg(chain.lastPoint, chain.points[1])
            if seg.lineDistance(chain.points[0]) <= 1 { chain.remove(0) }
        }
        return chain.points
    }
}

/// One of KiCad's tools that draw a graphic on the board (DRAWING_TOOL's Draw Line, Draw Rectangle, Draw Circle,
/// Draw Arc and Draw Polygon), driven as the pointer drives it: the pointer's moves and clicks (at the points its
/// grid and snapping make of them), Ctrl, the double click, ⌫ and Esc. It hands back each graphic finished, as KiCad
/// commits it: a line each segment (its chain of lines going on from where the last ended until it is finished), the
/// others one by one. The pen is the layer's (GetLineThickness), W and Shift-W making it 0.1 mm wider or narrower.
public struct GraphicTool: Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case line, rectangle, circle, arc, polygon
    }

    public let kind: Kind
    public private(set) var layer: String
    /// The pen new graphics are drawn with (DRAWING_TOOL's m_stroke)
    public private(set) var width: Int
    /// The editor's angle snap mode (KiCad's default: none); Ctrl lets a line or polygon go free, and holds a
    /// rectangle square and a circle's radius to 45°
    public var angleSnap: LeaderMode
    let widths: LineWidths

    // the line, rectangle and circle tools
    var twoPoint = TwoPointGeometry()
    var started = false
    /// Where the next line of a chain starts (the end of the last)
    var startingPoint: IPoint?
    /// The lines of the chain committed so far (DrawLine's committedLines), the last last
    public private(set) var committedLines: [BoardShape] = []
    // the arc tool
    var arcGeometry = ArcGeometry()
    var arc: BoardShape
    // the polygon tool
    var polygon = PolygonGeometry()

    public init(_ kind: Kind, layer: String, widths: LineWidths = LineWidths(), angleSnap: LeaderMode = .direct) {
        self.kind = kind
        self.layer = layer
        self.widths = widths
        self.angleSnap = angleSnap
        width = widths.width(layer)
        arc = BoardShape(kind: .arc, layer: layer, width: width)
    }

    /// DRAWING_TOOL::WIDTH_STEP
    public static let widthStep = 100_000

    /// Whether a graphic is being drawn
    public var isDrawing: Bool {
        switch kind {
        case .line, .rectangle, .circle: return started
        case .arc: return arcGeometry.step != .setOrigin
        case .polygon: return polygon.inProgress
        }
    }

    /// The graphic being drawn, as it now goes (a polygon's: its corners so far and the leader to the pointer, as the
    /// preview shows them, closed by the loop back to the first)
    public var drawing: BoardShape? {
        switch kind {
        case .line, .rectangle, .circle:
            guard started else { return nil }
            var s = BoardShape(kind: kind == .line ? .segment : kind == .rectangle ? .rectangle : .circle, layer: layer, width: width)
            s.start = twoPoint.origin
            s.end = twoPoint.end
            return s
        case .arc:
            guard arcGeometry.step.rawValue >= ArcGeometry.Step.setAngle.rawValue else { return nil }
            return arc
        case .polygon:
            guard polygon.inProgress else { return nil }
            var s = BoardShape(kind: .polygon, layer: layer, width: widths.width(layer))
            var pts = polygon.locked.points
            for p in polygon.leader.points.dropFirst() { pts.append(p) }
            for p in polygon.loop.points.dropFirst().dropLast() { pts.append(p) }
            s.points = pts
            return s
        }
    }

    /// The arc tool's centre and radius while its start is being set (its assistant), for showing
    public var arcCircle: (center: IPoint, radius: Int)? {
        guard kind == .arc, arcGeometry.step == .setStart else { return nil }
        return (arcGeometry.origin, Int(arcGeometry.radius))
    }

    /// The layer the next graphic goes on (KiCad's active layer changed): the pen the new layer's
    public mutating func setLayer(_ l: String) {
        guard l != layer else { return }
        layer = l
        width = widths.width(l)
        arc.layer = l
        arc.width = width
    }

    /// W (incWidth) and Shift-W (decWidth): the pen 0.1 mm wider, or narrower while it is wider than that
    public mutating func stepWidth(_ up: Bool) {
        if up {
            width += Self.widthStep
        } else if width > Self.widthStep {
            width -= Self.widthStep
        }
        if kind == .arc { arc.width = width }
    }

    /// The angle snap a pointer event gets: a rectangle and a circle are free unless Ctrl holds them to 45°; the
    /// others take the editor's, Ctrl letting them go free
    private func angleSnap(ctrl: Bool) -> LeaderMode {
        switch kind {
        case .rectangle, .circle: return ctrl ? .deg45 : .direct
        default: return ctrl ? .direct : angleSnap
        }
    }

    /// The pointer moved to `p`
    public mutating func move(to p: IPoint, ctrl: Bool = false) {
        let snap = angleSnap(ctrl: ctrl)
        switch kind {
        case .line, .rectangle, .circle:
            if started && snap != .direct {
                let v = p - twoPoint.origin
                let newEnd = snap == .deg90 ? vectorSnapped90(v) : vectorSnapped45(v, only45: kind == .rectangle)
                twoPoint.setEnd(twoPoint.origin + newEnd)
                twoPoint.angleSnap = snap
            } else {
                twoPoint.setEnd(p)
                twoPoint.angleSnap = .direct
            }
        case .arc:
            arcGeometry.angleSnap = snap != .direct
            arcGeometry.addPoint(p, lockIn: false)
            updateArc()
        case .polygon:
            polygon.leaderMode = snap
            if polygon.inProgress { polygon.setCursor(p) }
        }
    }

    /// The arc shown as the manager has it (drawArc's update after each event but the one that completes it)
    private mutating func updateArc() {
        if !arcGeometry.isComplete && arcGeometry.changed { arcGeometry.update(&arc) }
    }

    /// A click at `p` (`double`: the second of a double click; `onGraphicEnd`: the pointer snapped to a graphic of the
    /// board's, as KiCad's grid helper snaps to a line's end): the graphics it finishes, to commit each as one change
    public mutating func click(at p: IPoint, double: Bool = false, ctrl: Bool = false, onGraphicEnd: Bool = false) -> [BoardShape] {
        switch kind {
        case .line, .rectangle, .circle:
            if !started {
                let origin = startingPoint ?? p
                startingPoint = nil
                twoPoint.setOrigin(origin)
                twoPoint.setEnd(origin)
                started = true
                return []
            }
            let shape = drawing!
            started = false
            twoPoint = TwoPointGeometry(angleSnap: twoPoint.angleSnap)
            if kind == .line && onGraphicEnd && Double(shape.start.distance(shape.end)) > 0 {
                // a click on the end of a graphic: the path closed, the chain done
                committedLines = []
                return [shape]
            }
            if shape.start == shape.end || double {
                // (the same place clicked twice, or a double click: done, the last line not made)
                committedLines = []
                return []
            }
            if kind == .line {
                committedLines.append(shape)
                // the next line of the chain, from the end of this one (PrimeTool clicking there)
                startingPoint = shape.end
                _ = click(at: shape.end)
                return [shape]
            }
            var made = shape
            made.normalize()
            return [made]
        case .arc:
            if arcGeometry.step == .setOrigin {
                arc = BoardShape(kind: .arc, layer: layer, width: width)
            }
            arcGeometry.addPoint(p, lockIn: true)
            if arcGeometry.isComplete {
                let made = arc
                arcGeometry = ArcGeometry(clockwise: false)
                return [made]
            }
            updateArc()
            return []
        case .polygon:
            polygon.leaderMode = angleSnap(ctrl: ctrl)
            if double || polygon.closesOutline(p) {
                return finishPolygon()
            }
            polygon.addPoint(p)
            return []
        }
    }

    /// The polygon closed (KiCad's Close Outline, a double click, a click on its first corner): the polygon, if it
    /// has three corners or more
    public mutating func finishPolygon() -> [BoardShape] {
        defer { polygon.reset() }
        guard kind == .polygon, let points = polygon.completed() else { return [] }
        var s = BoardShape(kind: .polygon, layer: layer, width: widths.width(layer))
        s.points = points
        s.lineStyle = "solid"
        s.filled = layer != "Edge.Cuts" && layer != "F.CrtYd" && layer != "B.CrtYd"
        return [s]
    }

    /// What ⌫ did (deleteLastPoint)
    public enum Back: Sendable, Equatable {
        /// nothing was being drawn
        case nothing
        /// a point taken back
        case point
        /// the line before taken back to be drawn again: its change undone
        case undoLine
        /// the graphic being drawn dropped
        case dropped
    }

    /// ⌫: a line's last line taken back (its change to be undone, the line drawn again from its start), an arc's last
    /// point, a polygon's last corner
    public mutating func deleteLastPoint() -> Back {
        switch kind {
        case .line, .rectangle, .circle:
            guard started else { return .nothing }
            if kind == .line, let last = committedLines.popLast() {
                twoPoint.setOrigin(last.start)
                twoPoint.setEnd(last.end)
                return .undoLine
            }
            cancel()
            return .dropped
        case .arc:
            guard isDrawing else { return .nothing }
            arcGeometry.removeLastPoint()
            updateArc()
            return .point
        case .polygon:
            guard polygon.inProgress else { return .nothing }
            _ = polygon.deleteLastCorner()
            if !polygon.inProgress { polygon.reset(); return .dropped }
            return .point
        }
    }

    /// Esc: what is being drawn dropped; false if nothing was (Esc then leaves the tool)
    @discardableResult
    public mutating func cancel() -> Bool {
        let was = isDrawing
        started = false
        startingPoint = nil
        committedLines = []
        twoPoint = TwoPointGeometry()
        arcGeometry = ArcGeometry()
        polygon.reset()
        return was
    }
}

// MARK: - The point editor

/// KiCad's grid as its grid helper aligns a point to it (GRID_HELPER::Align): the nearest of its points, or where a
/// point is being dragged, the axes through where the drag began, where they are nearer (its auxiliary axes)
public struct PointGrid: Sendable, Equatable {
    public var size: IPoint
    public var origin: IPoint
    public var aux: IPoint?

    public init(size: IPoint, origin: IPoint = .zero, aux: IPoint? = nil) {
        self.size = size
        self.origin = origin
        self.aux = aux
    }

    /// computeNearest, then the auxiliary axes
    public func align(_ p: IPoint) -> IPoint {
        var n = IPoint(KiMath.round(Double(p.x - origin.x) / Double(size.x)) * size.x + origin.x,
                       KiMath.round(Double(p.y - origin.y) / Double(size.y)) * size.y + origin.y)
        if let aux {
            if abs(aux.x - p.x) < abs(n.x - p.x) { n.x = aux.x }
            if abs(aux.y - p.y) < abs(n.y - p.y) { n.y = aux.y }
        }
        return n
    }
}


/// KiCad's point editor on a graphic of the board's (PCB_POINT_EDITOR with the shape's edit behaviour): its edit
/// points (a line's ends; an arc's start, middle, end and centre; a rectangle's corners, centre and corner radius, its
/// sides' middles; a circle's centre and a point on it; a polygon's corners), each dragged as KiCad drags it, a drag
/// event at a time, the graphic changing with each
public struct ShapePointEditor: Sendable {
    /// What the edited arc's ends and middle keep (KiCad's arc edit mode; its default keeps the centre)
    public enum ArcEditMode: Int, Sendable {
        case keepCenterAdjustAngleRadius, keepEndpointsOrStartDirection, keepCenterEndsAdjustAngle
    }

    /// An edit point: a point of its own, or a line between two (EDIT_LINE: its middle, a rectangle's side)
    public enum Handle: Hashable, Sendable {
        case point(Int)
        case line(Int)
    }

    public private(set) var shape: BoardShape
    public var arcEditMode = ArcEditMode.keepCenterAdjustAngleRadius
    /// The edit points' places
    public private(set) var points: [IPoint] = []
    /// The edit lines, each between two of the points
    public private(set) var lines: [(Int, Int)] = []
    /// Each line's EC_PERPLINE constraint (a rectangle's): its middle and the direction it may move in
    var perpLines: [(mid: IPoint, line: IPoint)] = []
    var swapX = false, swapY = false
    /// Where KiCad's view controls hold the cursor while a point is dragged (ForceCursorPosition: the edited point as
    /// the event before left it), which an arc's middle follows; before the first event, the pointer itself
    var forcedCursor: IPoint?
    var rawPointer: IPoint?
    /// The polygon's angle snap (m_angleSnapActive, m_angleSnapPos)
    var angleSnapPos: IPoint?
    /// The editor's angle snap mode: at 45° or 90°, a dragged point (or a rectangle's side) held to that angle from
    /// its constrainer (setAltConstraint, EC_45DEGREE, EC_90DEGREE); Ctrl lets it go free
    public var angleSnap = LeaderMode.direct
    /// The point it is held from while it is (m_altConstrainer: Get45DegreeConstrainer's, else where the point began)
    var altConstrainer: IPoint?

    /// Corner indices of RECTANGLE_POINT_EDIT_BEHAVIOR
    static let rectTopLeft = 0, rectTopRight = 1, rectBotRight = 2, rectBotLeft = 3, rectCenter = 4, rectRadius = 5
    static let rectTop = 0, rectRight = 1, rectBot = 2, rectLeft = 3
    /// Of EDA_ARC_POINT_EDIT_BEHAVIOR
    static let arcStart = 0, arcMid = 1, arcEnd = 2, arcCenter = 3

    /// KiCad's Mils2IU( 1 ): the narrowest a rectangle is let be, and the smallest radius of an arc edited
    static let oneMil = 25_400

    public init(_ shape: BoardShape) {
        self.shape = shape
        makePoints()
    }

    /// MakePoints
    private mutating func makePoints() {
        points = []
        lines = []
        perpLines = []
        switch shape.kind {
        case .segment: points = [shape.start, shape.end]
        case .circle: points = [shape.start, shape.end]
        case .arc: points = [shape.start, shape.arcMidPoint, shape.end, shape.center]
        case .polygon: points = shape.points
        case .rectangle:
            var topLeft = shape.start, botRight = shape.end
            swapX = topLeft.x > botRight.x
            swapY = topLeft.y > botRight.y
            if swapX { swap(&topLeft.x, &botRight.x) }
            if swapY { swap(&topLeft.y, &botRight.y) }
            points = [topLeft, IPoint(botRight.x, topLeft.y), botRight, IPoint(topLeft.x, botRight.y), shape.shapeCenter,
                      IPoint(botRight.x - shape.cornerRadius, topLeft.y)]
            lines = [(0, 1), (1, 2), (2, 3), (3, 0)]
            perpLines = lines.indices.map(perpLine)
        }
    }

    /// EC_PERPLINE made for line `i`: its middle, and its direction turned a quarter
    private func perpLine(_ i: Int) -> (mid: IPoint, line: IPoint) {
        (linePosition(i), (points[lines[i].1] - points[lines[i].0]).perpendicular)
    }

    /// EDIT_LINE::GetPosition: half of each end (VECTOR2I / 2, rounded), added
    func linePosition(_ i: Int) -> IPoint {
        let a = points[lines[i].0], b = points[lines[i].1]
        return a.divided(by: 2) + b.divided(by: 2)
    }

    /// Where a handle is
    public func position(_ h: Handle) -> IPoint {
        switch h {
        case .point(let i): return points[i]
        case .line(let i): return linePosition(i)
        }
    }

    /// The handles a graphic has, for showing and for finding the one under the pointer
    public var handles: [Handle] { points.indices.map { .point($0) } + lines.indices.map { .line($0) } }

    /// EDIT_POINTS::FindPoint: the first of the points, then of the lines, whose square of half side `size` (KiCad's
    /// eight pixels at the view's scale) has `p` inside; the one a drag from `p` takes, though another be nearer
    public func handle(at p: IPoint, size: Int) -> Handle? {
        handles.first { h in
            let q = position(h)
            return p.x > q.x - size && p.y > q.y - size && p.x < q.x + size && p.y < q.y + size
        }
    }

    /// A drag of `handle` begun: the point it starts from (m_original, the grid's auxiliary axes through it), the
    /// cursor no longer held anywhere
    public mutating func beginDrag(_ handle: Handle) {
        dragOrigin = position(handle)
        forcedCursor = nil
        angleSnapPos = nil
        altConstrainer = nil
    }

    /// get45DegConstrainer: a line's other end, an arc's or circle's centre, else where the dragged point began
    private func constrainer(_ handle: Handle) -> IPoint {
        switch (shape.kind, handle) {
        case (.segment, .point(let i)): return points[(i + 1) % points.count]
        case (.circle, _): return points[0]
        case (.arc, _): return points[Self.arcCenter]
        default: return dragOrigin ?? position(handle)
        }
    }

    /// EC_45DEGREE or EC_90DEGREE applied to a handle at `p`, held from `c`; one snapped to the grid (a point, not a
    /// line) put on it along an axis (GRID_HELPER::AlignGrid: no auxiliary axes)
    private func heldToAngle(_ p: IPoint, from c: IPoint, grid: PointGrid?, toGrid: Bool) -> IPoint {
        let v = angleSnap == .deg90 ? vectorSnapped90(p - c) : vectorSnapped45(p - c)
        guard toGrid, angleSnap == .deg90 || v.x == 0 || v.y == 0 else { return c + v }
        var g = grid
        g?.aux = nil
        let snap = g?.align(c + v) ?? c + v
        return v.x == 0 ? IPoint(c.x, snap.y) : IPoint(snap.x, c.y)
    }

    /// The handle at `p` held to the angle, then to the grid's point nearest that (BestSnapAnchor, `grid` with the
    /// auxiliary axes it has) held to the angle again, where that is within `tolerance` of the grid's point
    private func heldAndSnapped(_ p: IPoint, from c: IPoint, grid: PointGrid?, toGrid: Bool, tolerance: Int) -> IPoint {
        let held = heldToAngle(p, from: c, grid: grid, toGrid: toGrid)
        guard let grid else { return held }
        let snap = grid.align(held)
        guard snap != held else { return held }
        let again = heldToAngle(snap, from: c, grid: grid, toGrid: toGrid)
        return (again - snap).norm > tolerance ? held : again
    }

    /// Where the drag began
    var dragOrigin: IPoint?

    /// A drag event: `handle` dragged with the pointer at `pointer`, as PCB_POINT_EDITOR moves the edited point (a
    /// point to the grid, a line by whole grid steps; KiCad's magnetic snapping to other items is not made here) and
    /// then the graphic (UpdateItem) and the points again (UpdatePoints). `grid` nil: no grid. `stickyLimit` is how
    /// far (nm) the pointer may go from a polygon's corner held at a multiple of 45° before it lets go, and how far a
    /// point held to the angle snap mode's angles may be from the grid's point it is taken to (five pixels at the
    /// view's scale); `free` (Shift) lets it go, and holds none; `ctrl` lets a point off the angle snap mode's angles.
    public mutating func drag(_ handle: Handle, to pointer: IPoint, grid: PointGrid? = nil, stickyLimit: Int = 0, free: Bool = false,
                              ctrl: Bool = false) {
        if dragOrigin == nil { beginDrag(handle) }
        rawPointer = pointer
        var pos = pointer
        // (held to the angle snap mode's angles, but with Ctrl)
        let toAngle = angleSnap != .direct && !ctrl
        if toAngle != (altConstrainer != nil) { altConstrainer = toAngle ? constrainer(handle) : nil }
        switch handle {
        case .line(let i):
            if let grid {
                // (SNAP_BY_GRID: the line moves by whole grid steps from where it is)
                let last = linePosition(i)
                let delta = pos - last
                let deltaGrid = grid.align(pos) - grid.align(last)
                pos = IPoint(abs(delta.x) > grid.size.x / 2 ? last.x + deltaGrid.x : last.x,
                             abs(delta.y) > grid.size.y / 2 ? last.y + deltaGrid.y : last.y)
            }
            if let c = altConstrainer {
                // (held to the angle from where it began instead of to its perpendicular)
                setLine(i, heldAndSnapped(pos, from: c, grid: grid, toGrid: false, tolerance: stickyLimit))
                break
            }
            // the line moved, then held to the perpendicular through its middle (EC_PERPLINE)
            setLine(i, pos)
            let (mid, dir) = perpLines[i]
            let here = linePosition(i)
            if let x = Seg(here, here + dir.perpendicular).intersectLines(Seg(mid, mid + dir)) { setLine(i, x) }
        case .point(let i):
            var aligned = grid
            aligned?.aux = dragOrigin
            var held = false
            if let h = angleSnapPos {
                if (pointer - h).norm > stickyLimit || free {
                    angleSnapPos = nil
                } else {
                    pos = h
                    held = true
                }
            }
            if shape.kind == .polygon && !held && points.count > 2 && !free {
                // a corner whose sides come within 2° of a multiple of 45° held there (snapCorner)
                let prev = points[(i + points.count - 1) % points.count], next = points[(i + 1) % points.count]
                let ang = Self.angle(Seg(pos, prev), Seg(pos, next)).degrees
                let snapAng = 45.0 * (ang / 45.0).rounded()
                if abs(ang - snapAng) < 2.0 {
                    var s = Self.snapCorner(prev, next, pos, snapAng)
                    if let aligned {
                        let gridded = aligned.align(s)
                        s = abs(Self.angle(Seg(gridded, prev), Seg(gridded, next)).degrees - snapAng) < 2.0 ? gridded : pos
                    }
                    if s != pos {
                        angleSnapPos = s
                        pos = s
                        held = true
                    }
                }
            }
            if !held, let c = altConstrainer {
                points[i] = heldAndSnapped(pos, from: c, grid: aligned, toGrid: true, tolerance: stickyLimit)
            } else {
                points[i] = held ? pos : aligned?.align(pos) ?? pos
            }
        }
        updateItem(handle)
        forcedCursor = position(handle)
        updatePoints()
    }

    /// EDIT_LINE::SetPosition: both its ends moved by how far its middle moves
    private mutating func setLine(_ i: Int, _ p: IPoint) {
        let d = p - linePosition(i)
        points[lines[i].0] += d
        points[lines[i].1] += d
    }

    /// SEG::Angle: the angle between two segments, of their directions from B to A, 0 to 180
    static func angle(_ a: Seg, _ b: Seg) -> EDAAngle {
        let t = EDAAngle(DPoint(a.a - a.b)).normalized180, o = EDAAngle(DPoint(b.a - b.b)).normalized180
        return EDAAngle(degrees: abs((t - o).normalized180.degrees))
    }

    /// snapCorner: the point near `guess` from which `prev` and `next` are `angle` apart (on the circle through them
    /// on which the chord subtends it)
    static func snapCorner(_ prev: IPoint, _ next: IPoint, _ guess: IPoint, _ angleDeg: Double) -> IPoint {
        let angleRad = angleDeg * Double.pi / 180.0
        let p = DPoint(prev), n = DPoint(next)
        let chord = (n - p).norm
        let sinA = Foundation.sin(angleRad)
        if chord == 0 || abs(sinA) < 1e-9 { return guess }
        let radius = chord / (2.0 * sinA)
        let mid = (p + n) / 2.0
        let dir = n - p
        let normal = DPoint(-dir.y, dir.x).resized(1)
        let hSq = radius * radius - (chord * chord) / 4.0
        let h = hSq > 0 ? hSq.squareRoot() : 0
        func project(_ c: DPoint) -> IPoint {
            var v = DPoint(guess) - c
            if v.norm == 0 { v = p - c }
            v = v.resized(1)
            return (c + v * radius).rounded
        }
        let p1 = project(mid + normal * h), p2 = project(mid - normal * h)
        let d1 = (DPoint(guess) - DPoint(p1)).norm, d2 = (DPoint(guess) - DPoint(p2)).norm
        return d1 < d2 ? p1 : p2
    }

    /// The edit behaviour's UpdateItem
    private mutating func updateItem(_ handle: Handle) {
        switch shape.kind {
        case .segment:
            if handle == .point(0) { shape.start = points[0] } else if handle == .point(1) { shape.end = points[1] }
        case .circle:
            if handle == .point(0) { shape.start = points[0] } else { shape.end = points[1] }
        case .polygon:
            shape.points = points
        case .arc:
            updateArc(handle)
        case .rectangle:
            updateRectangle(handle)
        }
    }

    private mutating func updateArc(_ handle: Handle) {
        let center = points[Self.arcCenter], mid = points[Self.arcMid], start = points[Self.arcStart], end = points[Self.arcEnd]
        switch handle {
        case .point(Self.arcCenter):
            switch arcEditMode {
            case .keepEndpointsOrStartDirection:
                editArcCenterKeepEndpoints(center, start, end)
            case .keepCenterAdjustAngleRadius, .keepCenterEndsAdjustAngle:
                let move = center - shape.center
                shape.setArcGeometry(start: shape.start + move, mid: shape.arcMidPoint + move, end: shape.end + move)
            }
        case .point(Self.arcMid):
            let cursor = forcedCursor ?? rawPointer ?? mid
            switch arcEditMode {
            case .keepEndpointsOrStartDirection:
                editArcMidKeepEndpoints(start, end, cursor)
            case .keepCenterEndsAdjustAngle, .keepCenterAdjustAngleRadius:
                // KI_ARC_EDIT::EditArcMidKeepCenter
                var radius = DPoint(cursor - center).norm
                if radius < Double(Self.oneMil) { radius = Double(Self.oneMil) }
                shape.start = (start - center).resized(KiMath.round(radius)) + center
                shape.end = (end - center).resized(KiMath.round(radius)) + center
            }
        case .point(Self.arcStart), .point(Self.arcEnd):
            switch arcEditMode {
            case .keepCenterAdjustAngleRadius:
                editArcEndpointKeepCenter(center, start, end)
            case .keepCenterEndsAdjustAngle:
                var p1: IPoint, movingStart: Bool
                if start != shape.start { p1 = start; movingStart = true } else { p1 = end; movingStart = false }
                p1 = center + (p1 - center).resized(shape.radius)
                if movingStart { shape.start = p1 } else { shape.end = p1 }
            case .keepEndpointsOrStartDirection:
                editArcEndpointKeepTangent(center, start, mid, end)
            }
        default:
            break
        }
    }

    /// KI_ARC_EDIT::EditArcEndpointKeepCenter: the end moved, the other moved to its radius
    private mutating func editArcEndpointKeepCenter(_ center: IPoint, _ start: IPoint, _ end: IPoint) {
        var p1: IPoint, p2: IPoint, prevP1: IPoint
        let movingStart: Bool
        if start != shape.start {
            prevP1 = shape.start
            p1 = start
            p2 = end
            movingStart = true
        } else {
            prevP1 = shape.end
            p1 = end
            p2 = start
            movingStart = false
        }
        p1 = p1 - center
        p2 = p2 - center
        if p1 == .zero { p1 = prevP1 - center }
        if p2 == .zero { p2 = IPoint(1, 0) }
        var radius = DPoint(p1).norm
        if radius < Double(Self.oneMil) { radius = Double(Self.oneMil) }
        p1 = center + p1.resized(KiMath.round(radius))
        p2 = center + p2.resized(KiMath.round(radius))
        shape.center = center
        if movingStart {
            shape.start = p1
            shape.end = p2
        } else {
            shape.start = p2
            shape.end = p1
        }
    }

    /// editArcEndpointKeepTangent: the end moved, the tangent at the other kept
    private mutating func editArcEndpointKeepTangent(_ aCenter: IPoint, _ aStart: IPoint, _ aMid: IPoint, _ aEnd: IPoint) {
        var p1: IPoint, p2: IPoint, p3: IPoint
        let movingStart: Bool
        if aStart != shape.start {
            p1 = aEnd; p2 = aStart; p3 = aMid; movingStart = true
        } else if aEnd != shape.end {
            p1 = aStart; p2 = aEnd; p3 = aMid; movingStart = false
        } else {
            return
        }
        var v1 = DPoint(p1 - aCenter), v2 = DPoint(p2 - aCenter)
        let v3 = DPoint(p3 - aCenter)
        if v1.norm == 0 || v2.norm == 0 { return }
        let u1 = v1 / v1.norm
        var u2 = v3 - u1 * (u1.x * v3.x + u1.y * v3.y)
        u2 = u2 / u2.norm
        let det = u1.x * u2.y - u2.x * u1.y
        if det == 0 { return }
        var tmpx = v1.x * u2.y - v1.y * u2.x
        var tmpy = -v1.x * u1.y + v1.y * u1.x
        v1 = DPoint(tmpx, tmpy) / det
        tmpx = v2.x * u2.y - v2.y * u2.x
        tmpy = -v2.x * u1.y + v2.y * u1.x
        v2 = DPoint(tmpx, tmpy) / det
        let r = v1.norm
        var arcValid = true
        guard v2.x != r else { return }
        var transform = false
        if v2.x > r {
            transform = true
            v2.x = 2 * r - v2.x
        }
        let delta = (r * r - v2.x * v2.x - v2.y * v2.y) / (2 * v2.x - 2 * r)
        // (ADVANCED_CFG's m_DrawArcCenterMaxAngle, 50)
        if abs(v2.y / (r - v2.x)) > 50 { arcValid = false }
        if !delta.isFinite { arcValid = false }
        var v4 = transform ? DPoint(2 * r + delta, 0) : DPoint(-delta, 0)
        tmpx = v4.x * u1.x + v4.y * u2.x
        tmpy = v4.x * u1.y + v4.y * u2.y
        v4 = DPoint(tmpx, tmpy)
        let c = v4 + DPoint(aCenter)
        if arcValid {
            shape.center = c.truncated
            if movingStart { shape.start = aStart } else { shape.end = aEnd }
        }
    }

    /// editArcCenterKeepEndpoints: the centre moved along the perpendicular of the chord
    private mutating func editArcCenterKeepEndpoints(_ center: IPoint, _ start: IPoint, _ end: IPoint) {
        let snapEpsilonSq = 4
        let m = start.divided(by: 2) + end.divided(by: 2)
        let perp = (end - start).perpendicular.resized(Int(Int32.max) / 2)
        let legal = Seg(m - perp, m + perp)
        var candidates = [legal.a, legal.b]
        for test in [Seg(center, center + IPoint(1, 0)), Seg(center, center + IPoint(0, 1))] {
            if let v = legal.intersectLines(test), legal.squaredDistance(v) <= snapEpsilonSq { candidates.append(v) }
        }
        var nearest: IPoint?
        var minD = Int.max
        for p in candidates {
            let d = (p - center).squaredNorm
            if d < minD - snapEpsilonSq {
                minD = d
                nearest = p
            }
        }
        if let nearest { shape.center = nearest }
    }

    /// editArcMidKeepEndpoints: the middle moved along the line from the chord's middle through it
    private mutating func editArcMidKeepEndpoints(_ start: IPoint, _ end: IPoint, _ cursor: IPoint) {
        let m = (start + end).divided(by: 2)
        let justOff = (start - end).norm / 100
        let v = shape.arcMidPoint - m
        let legal = Seg(m + v.resized(justOff), m + v.resized(Int(Int32.max) / 2))
        shape.setArcGeometry(start: start, mid: legal.nearestPoint(cursor), end: end)
    }

    private mutating func updateRectangle(_ handle: Handle) {
        var topLeft = points[Self.rectTopLeft], topRight = points[Self.rectTopRight]
        var botLeft = points[Self.rectBotLeft], botRight = points[Self.rectBotRight]
        pinEditedCorner(handle, &topLeft, &topRight, &botLeft, &botRight)
        func setLeft(_ v: Int) { if swapX { shape.end.x = v } else { shape.start.x = v } }
        func setRight(_ v: Int) { if swapX { shape.start.x = v } else { shape.end.x = v } }
        func setTop(_ v: Int) { if swapY { shape.end.y = v } else { shape.start.y = v } }
        func setBottom(_ v: Int) { if swapY { shape.start.y = v } else { shape.end.y = v } }
        switch handle {
        case .point(Self.rectTopLeft), .point(Self.rectTopRight), .point(Self.rectBotRight), .point(Self.rectBotLeft):
            setTop(topLeft.y)
            setLeft(topLeft.x)
            setRight(botRight.x)
            setBottom(botRight.y)
        case .point(Self.rectCenter):
            shape.move(points[Self.rectCenter] - shape.shapeCenter)
        case .point(Self.rectRadius):
            let w = abs(botRight.x - topLeft.x), h = abs(botRight.y - topLeft.y)
            let maxRadius = min(w, h) / 2
            let x = min(max(points[Self.rectRadius].x, botRight.x - maxRadius), botRight.x)
            points[Self.rectRadius] = IPoint(x, topLeft.y)
            shape.cornerRadius = max(0, min(botRight.x - x, min(abs(shape.end.x - shape.start.x), abs(shape.end.y - shape.start.y)) / 2))
        case .line(Self.rectTop): setTop(topLeft.y)
        case .line(Self.rectLeft): setLeft(topLeft.x)
        case .line(Self.rectBot): setBottom(botRight.y)
        case .line(Self.rectRight): setRight(botRight.x)
        default: break
        }
        for i in lines.indices where handle != .line(i) { perpLines[i] = perpLine(i) }
    }

    /// PinEditedCorner: the edited corner kept a mil inside the opposite one, the sides next to it moved with it
    private func pinEditedCorner(_ handle: Handle, _ topLeft: inout IPoint, _ topRight: inout IPoint, _ botLeft: inout IPoint,
                                 _ botRight: inout IPoint) {
        let minWidth = Self.oneMil, minHeight = Self.oneMil
        switch handle {
        case .point(Self.rectTopLeft):
            topLeft.x = min(topLeft.x, botRight.x - minWidth)
            topLeft.y = min(topLeft.y, botRight.y - minHeight)
            topRight.y = topLeft.y
            botLeft.x = topLeft.x
        case .point(Self.rectTopRight):
            topRight.x = max(topRight.x, botLeft.x + minWidth)
            topRight.y = min(topRight.y, botLeft.y - minHeight)
            topLeft.y = topRight.y
            botRight.x = topRight.x
        case .point(Self.rectBotLeft):
            botLeft.x = min(botLeft.x, topRight.x - minWidth)
            botLeft.y = max(botLeft.y, topRight.y + minHeight)
            botRight.y = botLeft.y
            topLeft.x = botLeft.x
        case .point(Self.rectBotRight):
            botRight.x = max(botRight.x, topLeft.x + minWidth)
            botRight.y = max(botRight.y, topLeft.y + minHeight)
            botLeft.y = botRight.y
            topRight.x = botRight.x
        case .line(Self.rectTop): topLeft.y = min(topLeft.y, botRight.y - minHeight)
        case .line(Self.rectLeft): topLeft.x = min(topLeft.x, botRight.x - minWidth)
        case .line(Self.rectBot): botRight.y = max(botRight.y, topLeft.y + minHeight)
        case .line(Self.rectRight): botRight.x = max(botRight.x, topLeft.x + minWidth)
        default: break
        }
    }

    /// The edit behaviour's UpdatePoints: the points put where the graphic now has them
    private mutating func updatePoints() {
        switch shape.kind {
        case .segment, .circle: points = [shape.start, shape.end]
        case .arc: points = [shape.start, shape.arcMidPoint, shape.end, shape.center]
        case .polygon: points = shape.points
        case .rectangle:
            var topLeft = shape.start, botRight = shape.end
            swapX = topLeft.x > botRight.x
            swapY = topLeft.y > botRight.y
            if swapX { swap(&topLeft.x, &botRight.x) }
            if swapY { swap(&topLeft.y, &botRight.y) }
            points = [topLeft, IPoint(botRight.x, topLeft.y), botRight, IPoint(topLeft.x, botRight.y), shape.shapeCenter,
                      IPoint(botRight.x - shape.cornerRadius, topLeft.y)]
        }
    }

    /// The drag finished (FinalizeItem: a polygon's corners in the same place one after another made one)
    public mutating func endDrag() {
        dragOrigin = nil
        forcedCursor = nil
        angleSnapPos = nil
        altConstrainer = nil
        if shape.kind == .polygon {
            var out: [IPoint] = []
            for p in shape.points where out.last != p { out.append(p) }
            if out.count > 1 && out.first == out.last { out.removeLast() }
            shape.points = out
            points = out
        }
    }
}
