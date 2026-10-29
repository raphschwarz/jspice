// What a box drawn on a board selects, as KiCad's PCB editor selects it (KiCad 10.0.7: pcbnew/tools/
// pcb_selection_tool.cpp, PCB_SELECTION_TOOL::SelectMultiple with a rectangle): the tracks, arcs, vias and footprints
// whose HitTest( BOX2I, aContained ) is true: wholly in the box when it is drawn left to right, touched by it when
// drawn right to left (KiCad's greedy selection). Ported from pcbnew/pcb_track.cpp (PCB_TRACK, PCB_ARC and PCB_VIA's
// HitTest), pcbnew/footprint.cpp (FOOTPRINT::HitTest, GetBoundingBox), pcbnew/pad.cpp (PAD::HitTest, the box of
// BuildEffectiveShapes), pcbnew/zone.cpp (ZONE::HitTest), common/eda_shape.cpp (EDA_SHAPE::hitTest, getBoundingBox,
// computeArcBBox, CalcArcAngles), libs/kimath/include/math/box2.h (BOX2's Contains, Intersects, IntersectsCircle,
// IntersectsCircleEdge, FarthestPointTo) and libs/kimath/src/trigo.cpp (SegmentIntersectsSegment).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// A board's tracks, vias and footprints as KiCad's box selection tries them, read once from the board
public struct BoxSelection: Sendable {
    struct Track {
        var uuid: String
        var start: IPoint, end: IPoint
        /// An arc's middle (PCB_ARC::GetMid) and width
        var mid: IPoint?
        var width = 0
    }

    struct Via {
        var uuid: String
        var position: IPoint
        /// Its diameter on each of its padstack's layers (Padstack().ForEachUniqueLayer)
        var widths: [Int]
    }

    struct Pad {
        /// The box round its shape on each layer and its hole (BuildEffectiveShapes' m_effectiveBoundingBox)
        var box: IBox
        /// Its polygon's corners, all its outlines' and holes' one after another (GetEffectivePolygon( ERROR_INSIDE ),
        /// TotalVertices and CVertex)
        var vertices: [IPoint]
        /// Its hole (GetEffectiveHoleShape: a point where it has none)
        var hole: Shape
    }

    struct Drawing {
        var shape: BoardWorld.Drawing
        var layer: String
        /// EDA_SHAPE::getBoundingBox, half its width out
        var box: IBox
        /// A rounded rectangle's outline (ROUNDRECT::TransformToPolygon), a curve's points (m_bezierPoints)
        var points: [IPoint] = []
    }

    struct Footprint {
        var uuid: String
        /// GetBoundingBox( false )
        var box: IBox
        var pads: [Pad] = []
        /// Its zones: the box round each one's outline (its first polygon; the others are its holes, ZONE::AddPolygon)
        /// and its corners, its outline's and holes' one after another
        var zones: [(box: IBox, corners: [IPoint])] = []
        var drawings: [Drawing] = []
        /// Its points' boxes (PCB_POINT::GetBoundingBox: its size across, round its position)
        var points: [IBox] = []
        /// Whether it has no pads, zones or drawings (texts are drawings), when it is tried by its box with its texts
        var empty = false
    }

    var tracks: [Track] = []
    var vias: [Via] = []
    var footprints: [Footprint] = []

    static let notes: Set<String> = ["Cmts.User", "Dwgs.User", "Eco1.User", "Eco2.User"]

    public init(board: KiCadBoard, project: [String: Any]? = nil) {
        let world = BoardWorld(board: board, project: project)
        let maxError = world.rules.maxError
        for node in board.root.items {
            let uuid = node.value("uuid") ?? ""
            switch node.head ?? "" {
            case "segment":
                tracks.append(Track(uuid: uuid, start: BoardWorld.point(node["start"]), end: BoardWorld.point(node["end"])))
            case "arc":
                tracks.append(Track(uuid: uuid, start: BoardWorld.point(node["start"]), end: BoardWorld.point(node["end"]),
                                    mid: BoardWorld.point(node["mid"]), width: BoardWorld.iu(node["width"], 0)))
            case "via":
                var widths = [BoardWorld.iu(node["size"], 0)]
                for layer in node["padstack"]?.all("layer") ?? [] where layer["size"] != nil { widths.append(BoardWorld.iu(layer["size"], 0)) }
                vias.append(Via(uuid: uuid, position: BoardWorld.point(node["at"]), widths: widths))
            default:
                break
            }
        }
        for fp in board.root.all("footprint") {
            let placement = BoardWorld.FootprintPlacement(fp)
            let at = placement.position
            var f = Footprint(uuid: fp.value("uuid") ?? "", box: IBox(at, at).inflated(250_000))
            for node in fp.all("pad") {
                let p = world.readPad(node, placement)
                let primitives = (node["primitives"]?.arguments ?? []).filter { $0.head != "gr_bbox" && $0.head != "gr_vector" }
                let hole = world.holeShape(p)
                guard let poly = world.padPolygon(p, primitives: primitives, errorLocation: .inside) else { continue }
                var box = hole.bbox
                if p.kind == .custom {
                    for chain in poly.polygons.flatMap({ $0 }) { for q in chain.points { box.merge(q) } }
                } else {
                    for s in world.effectiveShapes(p) { box.merge(s.bbox) }
                }
                f.pads.append(Pad(box: box, vertices: poly.polygons.flatMap { $0.flatMap(\.points) }, hole: hole))
            }
            for zone in fp.all("zone") {
                let polygons = zone.all("polygon").map { ($0["pts"]?.arguments ?? []).filter { $0.head == "xy" }.map(BoardWorld.point) }
                guard let outline = polygons.first, let box = IBox(points: outline) else { continue }
                f.zones.append((box, polygons.flatMap { $0 }))
            }
            for node in fp.items {
                guard ["fp_line", "fp_rect", "fp_arc", "fp_circle", "fp_poly", "fp_curve"].contains(node.head ?? ""),
                      let d = Self.drawing(node, placement, world, maxError: maxError) else { continue }
                f.drawings.append(d)
            }
            for point in fp.all("point") {
                let at = BoardWorld.point(point["at"]), size = BoardWorld.iu(point["size"], 0)
                let origin = IPoint(at.x - size / 2, at.y - size / 2)
                f.points.append(IBox(minX: origin.x, minY: origin.y, maxX: origin.x + size, maxY: origin.y + size))
            }
            f.empty = f.pads.isEmpty && f.zones.isEmpty && f.drawings.isEmpty && fp.all("fp_text").isEmpty
            for d in f.drawings where !Self.notes.contains(d.layer) { f.box.merge(d.box) }
            for p in f.pads { f.box.merge(p.box) }
            for z in f.zones { f.box.merge(z.box) }
            for b in f.points { f.box.merge(b) }
            if f.empty {
                // (one of nothing but texts, or not even those, goes by its texts too: its reference and value)
                for node in fp.items where node.head == "property" || node.head == "fp_text" {
                    guard let t = BoardWorld.textStrokes(node, footprint: fp) else { continue }
                    let name = node.text(at: 0) ?? ""
                    if node.head == "property" && name != "Reference" && name != "Value" && !t.visible { continue }
                    f.box.merge(t.boundingBox)
                }
            }
            footprints.append(f)
        }
    }

    /// A footprint's drawing on the board and its box (BoardWorld.readDrawing, EDA_SHAPE::getBoundingBox)
    static func drawing(_ node: SExpr, _ placement: BoardWorld.FootprintPlacement, _ world: BoardWorld, maxError: Int) -> Drawing? {
        guard var d = world.readDrawing(node, placement: placement) else { return nil }
        let layer = node.value("layer") ?? ""
        var box: IBox
        var points: [IPoint] = []
        switch d.kind {
        case .segment:
            box = IBox(d.start, d.end)
        case .rect:
            box = IBox(d.start, d.end)
            if d.cornerRadius > 0 {
                points = BoardWorld.roundRect(start: d.start, width: d.end.x - d.start.x, height: d.end.y - d.start.y,
                                              radius: d.cornerRadius, maxError: maxError / 5).points
            }
        case .circle:
            box = IBox(d.start, d.start).inflated(d.radius)
        case .arc:
            box = arcBox(d)
        case .poly:
            guard let b = IBox(points: d.poly) else { return nil }
            box = b
        case .bezier:
            let pts = (node["pts"]?.arguments ?? []).filter { $0.head == "xy" }.map { placement.apply(BoardWorld.point($0)) }
            guard pts.count == 4 else { return nil }
            (d.start, d.end) = (pts[0], pts[3])
            points = Outlines.bezierPoints(pts[0], pts[1], pts[2], pts[3], maxError: maxError)
            guard let b = IBox(points: points) else { return nil }
            box = b
        }
        return Drawing(shape: d, layer: layer, box: box.inflated(max(0, d.width) / 2), points: points)
    }

    /// EDA_SHAPE::computeArcBBox: its ends, its centre if it is filled, and the points due right, down, left and up of
    /// its centre that it passes on its way from its start round to its end (CalcArcAngles)
    static func arcBox(_ d: BoardWorld.Drawing) -> IBox {
        var box = IBox(d.start, d.start)
        box.merge(d.end)
        if d.filled { box.merge(d.center) }
        var r = d.center.distance(d.start)
        if r > Double(Int32.max) / 2 { r = Double(Int32.max) / 2 }
        let radius = max(1, KiMath.round(r))
        // (in KiCad's int coordinates, which wrap round where an arc's centre is far off: VECTOR2I's arithmetic)
        func wrap(_ v: Int) -> Int { Int(Int32(truncatingIfNeeded: v)) }
        func minus(_ a: IPoint, _ b: IPoint) -> IPoint { IPoint(wrap(a.x - b.x), wrap(a.y - b.y)) }
        var t1 = EDAAngle(DPoint(minus(d.start, d.center))), t2 = EDAAngle(DPoint(minus(d.end, d.center)))
        if t2 == t1 { t2 = t1 + .a360 }
        while t2 < t1 { t2 += .a360 }
        t1 = t1.normalized
        t2 = t2.normalized
        let c = d.center
        let quadrants: [(Double, IPoint)] = [(0, IPoint(wrap(c.x + radius), c.y)), (90, IPoint(c.x, wrap(c.y + radius))),
                                             (180, IPoint(wrap(c.x - radius), c.y)), (270, IPoint(c.x, wrap(c.y - radius)))]
        for (q, p) in quadrants {
            let passes = t2 > t1 ? (t1.degrees < q && t2.degrees > q) : (t1.degrees < q || t2.degrees > q)
            if passes { box.merge(p) }
        }
        return box
    }

    /// The tracks, arcs, vias and footprints the box from `a` to `b` (mm) takes, by their uuids: those wholly in it,
    /// or (`touching`: a box drawn right to left) those it touches
    public func items(from a: KiCadPoint, to b: KiCadPoint, touching: Bool) -> [String] {
        let p = IPoint(BoardWorld.iu(a.x), BoardWorld.iu(a.y)), q = IPoint(BoardWorld.iu(b.x), BoardWorld.iu(b.y))
        return items(in: IBox(p, q), touching: touching)
    }

    func items(in rect: IBox, touching: Bool) -> [String] {
        var out: [String] = []
        for t in tracks {
            let hit: Bool
            if let mid = t.mid {
                // (PCB_ARC::HitTest)
                var box = IBox(t.start, t.start)
                box.merge(mid)
                box.merge(t.end)
                box = box.inflated(t.width / 2)
                hit = touching ? rect.intersects(box) : rect.contains(box)
            } else {
                // (PCB_TRACK::HitTest)
                hit = touching ? Self.intersects(rect, t.start, t.end) : rect.contains(t.start) && rect.contains(t.end)
            }
            if hit { out.append(t.uuid) }
        }
        for v in vias {
            // (PCB_VIA::HitTest)
            let hit = v.widths.contains { w in
                touching ? Self.intersectsCircle(rect, v.position, w / 2) : rect.contains(IBox(v.position, v.position).inflated(w / 2))
            }
            if hit { out.append(v.uuid) }
        }
        for f in footprints where Self.hits(f, rect, touching: touching) { out.append(f.uuid) }
        return out
    }

    /// FOOTPRINT::HitTest( aRect, aContained )
    static func hits(_ f: Footprint, _ rect: IBox, touching: Bool) -> Bool {
        if !touching { return rect.contains(f.box) }
        guard rect.intersects(f.box) else { return false }
        if f.empty { return true }
        for pad in f.pads where padTouches(pad, rect) { return true }
        for zone in f.zones {
            // (ZONE::HitTest: the box round its corners, then a corner in the box or a side across it, going round
            // all its corners as one)
            guard rect.intersects(zone.box) else { continue }
            let c = zone.corners
            for (i, v) in c.enumerated() where rect.contains(v) || intersects(rect, v, c[(i + 1) % c.count]) { return true }
        }
        // (PCB_POINT::HitTest)
        for b in f.points where rect.intersects(b) { return true }
        for d in f.drawings where drawingTouches(d, rect) { return true }
        return false
    }

    /// PAD::HitTest( aRect, aContained = false )
    static func padTouches(_ pad: Pad, _ rect: IBox) -> Bool {
        guard rect.intersects(pad.box) else { return false }
        let v = pad.vertices
        for (i, p) in v.enumerated() where rect.contains(p) || intersects(rect, p, v[(i + 1) % v.count]) { return true }
        return BoardDRC.collide([pad.hole], [.rect(rect)], 0) != nil
    }

    /// EDA_SHAPE::hitTest( aRect, aContained = false )
    static func drawingTouches(_ d: Drawing, _ rect: IBox) -> Bool {
        let s = d.shape
        let w = s.width
        func checkOutline(_ r: IBox, _ points: [IPoint], closed: Bool) -> Bool {
            for (i, p) in points.enumerated() {
                if r.contains(p) { return true }
                if i + 1 < points.count {
                    if intersects(r, p, points[i + 1]) { return true }
                } else if closed, intersects(r, p, points[0]) {
                    return true
                }
            }
            return false
        }
        switch s.kind {
        case .circle:
            return rect.intersects(d.box) && intersectsCircleEdge(rect, s.start, s.radius, w)
        case .arc:
            guard rect.intersects(d.box) else { return false }
            var r = s.center.distance(s.start)
            if r > Double(Int32.max) / 2 { r = Double(Int32.max) / 2 }
            let radius = max(1, KiMath.round(r))
            if s.filled {
                return intersects(rect, s.center, s.start) || intersects(rect, s.center, s.end) || intersectsCircleEdge(rect, s.center, radius, w)
            }
            return intersectsCircleEdge(rect, s.center, radius, w)
        case .rect:
            let r = rect.inflated(w / 2)
            if s.cornerRadius > 0 { return checkOutline(r, d.points, closed: true) }
            let c = [s.start, IPoint(s.end.x, s.start.y), s.end, IPoint(s.start.x, s.end.y)]
            return intersects(r, c[0], c[1]) || intersects(r, c[1], c[2]) || intersects(r, c[2], c[3]) || intersects(r, c[3], c[0])
        case .segment:
            return intersects(rect.inflated(w / 2), s.start, s.end)
        case .poly:
            guard rect.intersects(d.box) else { return false }
            return checkOutline(rect.inflated(w / 2), s.poly, closed: true)
        case .bezier:
            guard rect.intersects(d.box) else { return false }
            let r = rect.inflated(w / 2)
            for i in d.points.indices.dropFirst() where r.contains(d.points[i - 1]) || intersects(r, d.points[i - 1], d.points[i]) { return true }
            return false
        }
    }

    /// BOX2::Intersects( aPoint1, aPoint2 ): an end in the box, or the segment across its top, right or bottom side
    static func intersects(_ r: IBox, _ a: IPoint, _ b: IPoint) -> Bool {
        if r.contains(a) || r.contains(b) { return true }
        let origin = IPoint(r.minX, r.minY), end = IPoint(r.maxX, r.maxY)
        let p2 = IPoint(end.x, origin.y), p4 = IPoint(origin.x, end.y)
        return segmentsIntersect(a, b, origin, p2) || segmentsIntersect(a, b, p2, end) || segmentsIntersect(a, b, end, p4)
    }

    /// SegmentIntersectsSegment (parallel segments never)
    static func segmentsIntersect(_ a1: IPoint, _ a2: IPoint, _ b1: IPoint, _ b2: IPoint) -> Bool {
        let dXa = Int64(a2.x) - Int64(a1.x), dYa = Int64(a2.y) - Int64(a1.y)
        let dXb = Int64(b2.x) - Int64(b1.x), dYb = Int64(b2.y) - Int64(b1.y)
        let dXab = Int64(b1.x) - Int64(a1.x), dYab = Int64(b1.y) - Int64(a1.y)
        var den = dYa * dXb - dYb * dXa
        if den == 0 { return false }
        var numA = dYab * dXb - dYb * dXab
        var numB = dYab * dXa - dYa * dXab
        if den < 0 {
            den = -den
            numA = -numA
            numB = -numB
        }
        return numA >= 0 && numB >= 0 && numA <= den && numB <= den
    }

    /// BOX2::IntersectsCircle: the box's point nearest the centre within the radius
    static func intersectsCircle(_ r: IBox, _ c: IPoint, _ radius: Int) -> Bool {
        let x = max(r.minX, min(r.maxX, c.x)), y = max(r.minY, min(r.maxY, c.y))
        let dx = Double(c.x) - Double(x), dy = Double(c.y) - Double(y)
        return dx * dx + dy * dy <= Double(radius) * Double(radius)
    }

    /// BOX2::IntersectsCircleEdge: the circle out to its line's outer side touching the box, and the box's corner
    /// farthest from the centre (FarthestPointTo) beyond the line's inner side
    static func intersectsCircleEdge(_ r: IBox, _ c: IPoint, _ radius: Int, _ width: Int) -> Bool {
        guard intersectsCircle(r, c, radius + width / 2) else { return false }
        let center = r.center
        let fx = c.x < center.x ? r.maxX : r.minX, fy = c.y < center.y ? r.maxY : r.minY
        let dx = Double(fx) - Double(c.x), dy = Double(fy) - Double(c.y)
        let inner = Double(radius) - Double(width) / 2
        return dx * dx + dy * dy > inner * inner
    }
}

extension BoardEditing {
    /// What a box drawn from `a` to `b` (mm) takes on the board as it now is (KiCad's box selection): the tracks,
    /// arcs and vias, and the footprints, wholly in it, or (`touching`) those it touches, by their uuids
    public func itemsInBox(from a: KiCadPoint, to b: KiCadPoint, touching: Bool) -> (copper: [String], footprints: [String]) {
        let selection = BoxSelection(board: router.board, project: project)
        let footprints = Set(selection.footprints.map(\.uuid))
        let taken = selection.items(from: a, to: b, touching: touching)
        return (taken.filter { !footprints.contains($0) }, taken.filter(footprints.contains))
    }
}
