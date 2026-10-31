// A board's items as KiCad's PCB editor moves, turns, unlocks and gives new ids to them, on the board's own file
// (KiCad 10.0.8: pcbnew/footprint.cpp, FOOTPRINT::Move and Rotate; pcbnew/pcb_track.cpp, PCB_TRACK, PCB_ARC and PCB_VIA's
// Move and Rotate; pcbnew/zone.cpp, ZONE::Move and Rotate; common/eda_shape.cpp, EDA_SHAPE::move and rotate;
// pcbnew/pcb_text.cpp, PCB_TEXT::Move and Rotate; pcbnew/pcb_dimension.cpp, PCB_DIMENSION_BASE::Move;
// pcbnew/pcb_group.cpp and pcb_generator.cpp, PCB_GROUP and PCB_GENERATOR's Move and Rotate, with
// pcbnew/generators/pcb_tuning_pattern.h, PCB_TUNING_PATTERN::Move; pcbnew/pcb_track.cpp, PCB_TRACK::GetBoundingBox and
// PCB_VIA::GetBoundingBox; pcbnew/zone.cpp, ZONE::GetBoundingBox; libs/kimath/src/trigo.cpp, RotatePoint;
// libs/kimath/src/geometry/roundrect.cpp, ROUNDRECT::TransformToPolygon, a rectangle turned off square; pcbnew/
// footprint.cpp, FOOTPRINT::cmp_drawings, the order a footprint's drawings are written in), its coordinates kept to
// the nanometre as KiCad keeps them. GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// A board's items, the lists of its file KiCad reads as BOARD_ITEMs: their kinds, ids, members, and how KiCad moves
/// and turns each
enum BoardItems {
    /// The heads of the lists a board's file keeps its items in (footprints, drawings, texts, dimensions, tracks, vias,
    /// zones, groups, generators...)
    static let heads: Set<String> = ["footprint", "gr_line", "gr_rect", "gr_circle", "gr_arc", "gr_poly", "gr_curve",
                                     "gr_bbox", "gr_text", "gr_text_box", "dimension", "target", "image", "table",
                                     "barcode", "point", "segment", "arc", "via", "zone", "group", "generated"]

    /// The board's item of `uuid`, among its own (not a footprint's)
    static func item(_ board: KiCadBoard, _ uuid: String) -> SExpr? {
        board.root.items.first { heads.contains($0.head ?? "") && $0.value("uuid") == uuid }
    }

    /// The board's groups and generators (tuning patterns), by their ids: their members' ids
    static func members(_ node: SExpr) -> [String] { node["members"]?.arguments.compactMap(\.text) ?? [] }

    /// A group's or generator's members and theirs, all the way down (RunOnChildren, RECURSE)
    static func descendants(_ node: SExpr, in board: KiCadBoard) -> [SExpr] {
        var out: [SExpr] = []
        var seen = Set<String>()
        func visit(_ n: SExpr) {
            for id in members(n) where seen.insert(id).inserted {
                guard let m = item(board, id) else { continue }
                out.append(m)
                if m.head == "group" || m.head == "generated" { visit(m) }
            }
        }
        visit(node)
        return out
    }

    /// The group or generator whose members `uuid` is among, if any
    static func parentGroup(_ board: KiCadBoard, _ uuid: String) -> SExpr? {
        board.root.items.first { ($0.head == "group" || $0.head == "generated") && members($0).contains(uuid) }
    }

    /// Written unlocked (BOARD_ITEM::SetLocked( false ): KiCad writes (locked yes) only of what is locked)
    static func unlock(_ node: SExpr) {
        node.items.removeAll { $0.head == "locked" || ($0.kind == .symbol && $0.text == "locked") }
    }

    static func isLocked(_ node: SExpr) -> Bool { node.flag("locked") }

    // MARK: - Ids

    /// Every id of the item and of what it holds (a footprint's pads, fields, drawings and zones), each made anew
    /// (KiCad's ResetUuid on the item and RunOnChildren( ResetUuid, RECURSE )); the old ids by the new
    @discardableResult
    static func renew(_ node: SExpr, _ ids: inout [String: String]) -> String? {
        var mine: String?
        node.walk { n in
            guard n.head == "uuid", let old = n.text(at: 0) else { return }
            let new = KiCadBoard.newUUID()
            ids[old] = new
            n.items[1] = SExpr(string: new)
            if mine == nil { mine = new }
        }
        return mine
    }

    /// A group's or generator's members, by the ids `ids` gives them now (sorted, as KiCad writes them), those not
    /// among `kept` left out
    static func remapMembers(_ node: SExpr, _ ids: [String: String], kept: Set<String>? = nil) {
        guard let list = node["members"] else { return }
        let now = members(node).compactMap { id -> String? in
            let new = ids[id] ?? id
            if let kept, !kept.contains(new) { return nil }
            return new
        }.sorted()
        list.items = [list.items[0]] + now.map { SExpr(string: $0) }
    }

    // MARK: - Moving

    /// The point list `list` (its first two numbers, mm) moved by `d` (nm)
    static func shift(_ list: SExpr?, _ d: IPoint) {
        guard let list, list.number(at: 0) != nil, list.number(at: 1) != nil else { return }
        let p = BoardWorld.point(list)
        list.items[1] = mm(p.x + d.x).sexpr
        list.items[2] = mm(p.y + d.y).sexpr
    }

    static func mm(_ nm: Int) -> Double { Double(nm) / 1e6 }

    /// A list of points (xy, and an arc's start, mid and end) moved
    static func shiftPoints(_ pts: SExpr?, _ d: IPoint) {
        for p in pts?.items ?? [] {
            if p.head == "xy" { shift(p, d) } else if p.head == "arc" { for name in ["start", "mid", "end"] { shift(p[name], d) } }
        }
    }

    /// A zone's outlines and fills moved (ZONE::Move: its hatching offsets stay where they are)
    static func shiftZone(_ zone: SExpr, _ d: IPoint) {
        for outline in zone.all("polygon") + zone.all("filled_polygon") { shiftPoints(outline["pts"], d) }
    }

    /// The item moved by `d` (nm) as KiCad's Move moves it; a group's or generator's members are moved apart, by
    /// `members` (PCB_GROUP::Move moves each)
    static func translate(_ node: SExpr, by d: IPoint) {
        guard d != .zero else { return }
        switch node.head ?? "" {
        case "footprint":
            shift(node["at"], d)
            // (KiCad 10 keeps a footprint's zones and points where they are on the board)
            for child in node.items {
                if child.head == "zone" { shiftZone(child, d) }
                if child.head == "point" { shift(child["at"], d) }
            }
        case "segment", "arc":
            for name in ["start", "mid", "end"] { shift(node[name], d) }
        case "via", "target", "image", "point", "barcode", "gr_text":
            shift(node["at"], d)
        case "zone":
            shiftZone(node, d)
        case "gr_line", "gr_rect", "gr_circle", "gr_arc", "gr_poly", "gr_curve", "gr_bbox", "gr_text_box":
            for name in ["start", "end", "center", "mid"] { shift(node[name], d) }
            shiftPoints(node["pts"], d)
        case "dimension":
            shiftPoints(node["pts"], d)
            shift(node["gr_text"]?["at"], d)
        case "generated":
            // (PCB_TUNING_PATTERN::Move: its origin, end and base lines)
            shift(node["origin"]?["xy"], d)
            shift(node["end"]?["xy"], d)
            shiftPoints(node["base_line"]?["pts"], d)
            shiftPoints(node["base_line_coupled"]?["pts"], d)
        default:
            break
        }
    }

    /// The item and, for a group or a generator, its members all the way down moved by `d`
    static func translateWithMembers(_ node: SExpr, by d: IPoint, in board: KiCadBoard) {
        translate(node, by: d)
        if node.head == "group" || node.head == "generated" {
            for m in descendants(node, in: board) where m.head != "group" && m.head != "generated" { translate(m, by: d) }
            for m in descendants(node, in: board) where m.head == "generated" { translate(m, by: d) }
        }
    }

    /// Where KiCad has the item (BOARD_ITEM::GetPosition): a footprint's, via's or text's position, a track's start
    /// (an arc track's centre), a shape's (its centre for a circle or an arc, its first corner for a polygon, its
    /// start for the others, a rectangle's as KiCad reads it), a zone's first corner, a dimension's start
    static func position(_ node: SExpr) -> IPoint {
        switch node.head ?? "" {
        case "footprint", "via", "gr_text", "target", "image", "point", "barcode":
            return BoardWorld.point(node["at"])
        case "segment", "gr_line", "gr_bbox", "gr_curve", "gr_text_box":
            return BoardWorld.point(node["start"] ?? node["pts"]?["xy"])
        case "gr_rect":
            let a = BoardWorld.point(node["start"]), b = BoardWorld.point(node["end"])
            return IPoint(min(a.x, b.x), min(a.y, b.y))
        case "gr_circle":
            return BoardWorld.point(node["center"])
        case "arc", "gr_arc":
            return arcCenter(node) ?? BoardWorld.point(node["start"])
        case "gr_poly":
            return BoardWorld.point(node["pts"]?["xy"])
        case "zone":
            return BoardWorld.point(node["polygon"]?["pts"]?["xy"])
        case "dimension":
            return BoardWorld.point(node["pts"]?["xy"])
        case "generated":
            return BoardWorld.point(node["origin"]?["xy"])
        default:
            return .zero
        }
    }

    /// A drawn arc's centre, from its three points as KiCad's parser makes it (EDA_SHAPE::SetArcGeometry, CalcArcCenter)
    static func arcCenter(_ node: SExpr) -> IPoint? {
        guard let s = node["start"], let m = node["mid"], let e = node["end"] else { return nil }
        return KiMath.arcCenter(BoardWorld.point(s), BoardWorld.point(m), BoardWorld.point(e))
    }

    // MARK: - Turning

    /// The point list `list` turned about `c` by `angle` (RotatePoint, to the nanometre)
    static func turn(_ list: SExpr?, about c: IPoint, _ angle: EDAAngle) {
        guard let list, list.number(at: 0) != nil, list.number(at: 1) != nil else { return }
        let p = KiMath.rotate(BoardWorld.point(list), around: c, angle)
        list.items[1] = mm(p.x).sexpr
        list.items[2] = mm(p.y).sexpr
    }

    static func turnPoints(_ pts: SExpr?, about c: IPoint, _ angle: EDAAngle) {
        for p in pts?.items ?? [] {
            if p.head == "xy" {
                turn(p, about: c, angle)
            } else if p.head == "arc" {
                for name in ["start", "mid", "end"] { turn(p[name], about: c, angle) }
            }
        }
    }

    /// A text's (at x y angle) given `delta` degrees more, kept in [0, 360) (EDA_ANGLE::Normalize)
    static func addAngle(_ at: SExpr?, _ delta: Double) {
        guard let at, let x = at.number(at: 0), let y = at.number(at: 1) else { return }
        let rest = at.items.dropFirst(4)
        let list = SExpr("at", x, y, BoardEditing.normalizedAngle((at.number(at: 2) ?? 0) + delta))
        list.items += rest
        at.items = list.items
    }

    /// Whether the port turns the item as KiCad does at any angle (`rotate`): not a table, an image, a dimension, a
    /// barcode or a text box, nor a rectangle of rounded corners (which KiCad makes a polygon of arcs' points off
    /// square), nor a footprint with one of those
    static func rotatable(_ node: SExpr) -> Bool {
        let rounded = { (n: SExpr) in (n.head == "gr_rect" || n.head == "fp_rect") && (n["radius"]?.number(at: 0) ?? 0) > 0 }
        switch node.head ?? "" {
        case "footprint":
            return !node.items.contains { rounded($0) || ["fp_text_box", "dimension", "table", "image", "barcode"].contains($0.head ?? "") }
        case "segment", "arc", "via", "target", "point", "gr_text", "zone", "gr_line", "gr_circle", "gr_arc", "gr_poly",
             "gr_curve", "group", "generated":
            return true
        case "gr_rect":
            return !rounded(node)
        default:
            return false
        }
    }

    /// The item turned about `c` by `degrees` counterclockwise, as KiCad's Rotate turns it; nil where the port does not
    /// turn its kind (a table, an image, a dimension, a barcode)
    @discardableResult
    static func rotate(_ node: SExpr, about c: IPoint, degrees: Double, in board: KiCadBoard) -> Bool {
        let angle = EDAAngle(degrees: degrees)
        if angle.normalized.degrees == 0 { return true }
        switch node.head ?? "" {
        case "footprint":
            rotateFootprint(node, about: c, degrees: degrees)
        case "segment", "arc":
            for name in ["start", "mid", "end"] { turn(node[name], about: c, angle) }
        case "via", "target", "point":
            turn(node["at"], about: c, angle)
        case "gr_text":
            turn(node["at"], about: c, angle)
            addAngle(node["at"], degrees)
        case "zone":
            for outline in node.all("polygon") + node.all("filled_polygon") { turnPoints(outline["pts"], about: c, angle) }
        case "gr_line", "gr_circle", "gr_arc", "gr_poly", "gr_curve":
            for name in ["start", "end", "center", "mid"] { turn(node[name], about: c, angle) }
            turnPoints(node["pts"], about: c, angle)
        case "gr_rect":
            // (EDA_SHAPE::rotate: a rectangle turned by a right angle stays one; turned otherwise, a polygon)
            guard let s = node["start"], let e = node["end"] else { return false }
            let a = BoardWorld.point(s), b = BoardWorld.point(e)
            if (angle.degrees / 90).rounded() == angle.degrees / 90 {
                let p = KiMath.rotate(a, around: c, angle), q = KiMath.rotate(b, around: c, angle)
                node.set(SExpr("start", mm(p.x), mm(p.y)))
                node.set(SExpr("end", mm(q.x), mm(q.y)))
            } else {
                // (ROUNDRECT::TransformToPolygon's corners: from the top left, clockwise, of the rectangle normalized)
                let (x0, x1, y0, y1) = (min(a.x, b.x), max(a.x, b.x), min(a.y, b.y), max(a.y, b.y))
                let corners = [IPoint(x0, y0), IPoint(x1, y0), IPoint(x1, y1), IPoint(x0, y1)].map { KiMath.rotate($0, around: c, angle) }
                node.items[0] = SExpr(symbol: "gr_poly")
                node.items.removeAll { $0.head == "start" || $0.head == "end" || $0.head == "radius" }
                node.items.insert(SExpr("pts", corners.map { SExpr("xy", mm($0.x), mm($0.y)) }), at: 1)
            }
        case "group", "generated":
            for m in descendants(node, in: board) where m.head != "group" {
                if m.head == "generated" { continue }
                rotate(m, about: c, degrees: degrees, in: board)
            }
            if node.head == "generated" {
                turn(node["origin"]?["xy"], about: c, angle)
                turn(node["end"]?["xy"], about: c, angle)
                turnPoints(node["base_line"]?["pts"], about: c, angle)
                turnPoints(node["base_line_coupled"]?["pts"], about: c, angle)
            }
        default:
            return false
        }
        return true
    }

    /// A footprint turned about `c` by `degrees` as KiCad turns it, to the nanometre (FOOTPRINT::Rotate: its position
    /// turned about the centre, the footprint moved there, then SetOrientation turning each of its items about its
    /// position by the change, as KiCad holds them, on the board: a pad's, text's or drawing's place made a board
    /// point as the parser makes it, RotatePoint( relative, orientation ) and the position added, turned, and written
    /// back relative to the footprint as the formatter writes it, RotatePoint( point - position, -orientation ), so
    /// that each can come back a nanometre off; its texts then kept upright, PCB_TEXT::KeepUpright: one turned to
    /// 180° or more turned half round, its justification the other way round, unless it is not kept upright)
    static func rotateFootprint(_ node: SExpr, about c: IPoint, degrees: Double) {
        let at = node["at"]
        let p0 = BoardWorld.point(at)
        let theta0 = at?.number(at: 2) ?? 0
        let p1 = KiMath.rotate(p0, around: c, EDAAngle(degrees: degrees))
        let change = EDAAngle(degrees: (theta0 + degrees) - theta0)
        let theta1 = BoardItems.normalize180(theta0 + degrees)
        let d = p1 - p0
        /// A point of the footprint, relative to it in the file, as the board has it once moved and turned
        func board(_ rel: IPoint) -> IPoint {
            let abs = KiMath.rotate(rel, EDAAngle(degrees: theta0)) + p0 + d
            return KiMath.rotate(abs, around: p1, change)
        }
        func relative(_ abs: IPoint) -> IPoint { KiMath.rotate(abs - p1, EDAAngle(degrees: -theta1)) }
        // (the drawings' points as the board holds them, which KiCad sorts them by when it writes the footprint)
        var held: [ObjectIdentifier: IPoint] = [:]
        func turnRelative(_ list: SExpr?) {
            guard let list, list.number(at: 0) != nil, list.number(at: 1) != nil else { return }
            let b = board(BoardWorld.point(list))
            held[ObjectIdentifier(list)] = b
            let q = relative(b)
            list.items[1] = mm(q.x).sexpr
            list.items[2] = mm(q.y).sexpr
        }
        func turnAbsolute(_ list: SExpr?) {
            guard let list, list.number(at: 0) != nil, list.number(at: 1) != nil else { return }
            let q = KiMath.rotate(BoardWorld.point(list) + d, around: p1, change)
            list.items[1] = mm(q.x).sexpr
            list.items[2] = mm(q.y).sexpr
        }
        let cardinal = (change.normalized.degrees / 90).rounded() == change.normalized.degrees / 90
        for child in node.items {
            switch child.head ?? "" {
            case "pad":
                guard let a = child["at"] else { continue }
                let angle = BoardItems.normalize360((a.number(at: 2) ?? 0) + change.degrees)
                turnRelative(a)
                var values = Array(a.items.prefix(3))
                if angle != 0 { values.append(angle.sexpr) }
                a.items = values
            case "property", "fp_text":
                guard let a = child["at"] else { continue }
                var angle = BoardItems.normalize360((a.number(at: 2) ?? 0) + change.degrees)
                turnRelative(a)
                if !child.flag("unlocked") && angle >= 180 {
                    angle = BoardItems.normalize360(angle + 180)
                    flipJustification(child)
                }
                let rest = a.items.dropFirst(4)
                a.items = Array(a.items.prefix(3)) + [angle.sexpr] + rest
            case "fp_rect" where !cardinal:
                // (EDA_SHAPE::rotate: a rectangle turned off square becomes the polygon ROUNDRECT::TransformToPolygon
                // makes of it, its corners from the top left on the board, clockwise, then turned)
                guard let s = child["start"], let e = child["end"] else { continue }
                let a = KiMath.rotate(BoardWorld.point(s), EDAAngle(degrees: theta0)) + p0 + d
                let b = KiMath.rotate(BoardWorld.point(e), EDAAngle(degrees: theta0)) + p0 + d
                let (x0, x1, y0, y1) = (min(a.x, b.x), max(a.x, b.x), min(a.y, b.y), max(a.y, b.y))
                let points = [IPoint(x0, y0), IPoint(x1, y0), IPoint(x1, y1), IPoint(x0, y1)].map {
                    KiMath.rotate($0, around: p1, change)
                }
                child.items[0] = SExpr(symbol: "fp_poly")
                child.items.removeAll { $0.head == "start" || $0.head == "end" || $0.head == "radius" }
                let pts = SExpr("pts", points.map { q in let r = relative(q); return SExpr("xy", mm(r.x), mm(r.y)) })
                for (q, xy) in zip(points, pts.items.dropFirst()) { held[ObjectIdentifier(xy)] = q }
                child.items.insert(pts, at: 1)
            case "fp_line", "fp_rect", "fp_circle", "fp_arc", "fp_poly", "fp_curve":
                for name in ["start", "end", "center", "mid"] { turnRelative(child[name]) }
                for q in child["pts"]?.items ?? [] where q.head == "xy" { turnRelative(q) }
            case "zone":
                for outline in child.all("polygon") + child.all("filled_polygon") {
                    for q in outline["pts"]?.items ?? [] {
                        if q.head == "xy" { turnAbsolute(q) } else { for name in ["start", "mid", "end"] { turnAbsolute(q[name]) } }
                    }
                }
            case "point":
                turnAbsolute(child["at"])
            default:
                continue
            }
        }
        var values: [SExprConvertible] = [mm(p1.x), mm(p1.y)]
        if theta1 != 0 { values.append(theta1) }
        node.set(SExpr("at", values))
        sortDrawings(node) { list in
            held[ObjectIdentifier(list)]
                ?? KiMath.rotate(BoardWorld.point(list), EDAAngle(degrees: theta1)) + p1
        }
    }

    /// The heads of a footprint's drawings (FOOTPRINT::GraphicalItems), by the order of their kinds (KICAD_T)
    static let footprintDrawings: [String: Int] = ["fp_line": 0, "fp_rect": 0, "fp_arc": 0, "fp_circle": 0, "fp_poly": 0,
                                                   "fp_curve": 0, "image": 1, "fp_text": 2, "fp_text_box": 3,
                                                   "table": 4, "barcode": 5, "dimension": 6]

    /// A footprint's drawings put in the order KiCad writes them (the formatter's set of them by
    /// FOOTPRINT::cmp_drawings: by kind, layer, then a shape's kind, start, end, centre or polygon, and width, a text's
    /// place, angle, size, thickness, style, line spacing and text, then id), on the board's points, `board`
    static func sortDrawings(_ fp: SExpr, board: (SExpr) -> IPoint) {
        let slots = fp.items.indices.filter { footprintDrawings[fp.items[$0].head ?? ""] != nil }
        guard slots.count > 1 else { return }
        let shapes = ["fp_line": 0, "fp_rect": 1, "fp_arc": 2, "fp_circle": 3, "fp_poly": 4, "fp_curve": 5]
        func points(_ n: SExpr, _ names: [String]) -> [IPoint] { names.compactMap { n[$0] }.map(board) }
        /// (a comparison's verdict, nil when it ties)
        func order<T: Comparable>(_ a: T, _ b: T) -> Bool? { a == b ? nil : a < b }
        func order(_ a: [IPoint], _ b: [IPoint]) -> Bool? {
            for (p, q) in zip(a, b) {
                if let o = order(p.x, q.x) ?? order(p.y, q.y) { return o }
            }
            return nil
        }
        func before(_ a: SExpr, _ b: SExpr) -> Bool {
            let ha = a.head ?? "", hb = b.head ?? ""
            if let o = order(footprintDrawings[ha] ?? 0, footprintDrawings[hb] ?? 0) { return o }
            let la = BoardDRC.layerID(a.value("layer") ?? "") ?? -1, lb = BoardDRC.layerID(b.value("layer") ?? "") ?? -1
            if let o = order(la, lb) { return o }
            if let sa = shapes[ha], let sb = shapes[hb] {
                if let o = order(sa, sb) { return o }
                if ha == "fp_poly" || ha == "fp_curve" {
                    let pa = a["pts"]?.items.filter { $0.head == "xy" } ?? [], pb = b["pts"]?.items.filter { $0.head == "xy" } ?? []
                    if ha == "fp_poly", let o = order(pa.count, pb.count) { return o }
                    if ha == "fp_curve" {
                        // (a bezier's start and end, then its controls)
                        let ka = [pa.first, pa.last, pa.dropFirst().first, pa.dropFirst(2).first].compactMap { $0 }.map(board)
                        let kb = [pb.first, pb.last, pb.dropFirst().first, pb.dropFirst(2).first].compactMap { $0 }.map(board)
                        if let o = order(ka, kb) { return o }
                    } else if let o = order(pa.map(board), pb.map(board)) {
                        return o
                    }
                } else {
                    let names = ha == "fp_circle" ? ["center", "end"] : ["start", "end"]
                    if let o = order(points(a, names), points(b, names)) { return o }
                    if ha == "fp_arc", let ca = arcCenter(a, board), let cb = arcCenter(b, board), let o = order([ca], [cb]) {
                        return o
                    }
                }
                if let o = order(a["stroke"]?["width"]?.number(at: 0) ?? 0, b["stroke"]?["width"]?.number(at: 0) ?? 0) {
                    return o
                }
            } else if ha == "fp_text" {
                if let o = order(points(a, ["at"]), points(b, ["at"])) { return o }
                if let o = order(a["at"]?.number(at: 2) ?? 0, b["at"]?.number(at: 2) ?? 0) { return o }
                let fa = a["effects"]?["font"], fb = b["effects"]?["font"]
                // (the size written height first, compared width first)
                let za = fa?["size"], zb = fb?["size"]
                if let o = order([IPoint(nm(za?.number(at: 1)), nm(za?.number(at: 0)))],
                                 [IPoint(nm(zb?.number(at: 1)), nm(zb?.number(at: 0)))]) {
                    return o
                }
                if let o = order(fa?["thickness"]?.number(at: 0) ?? 0, fb?["thickness"]?.number(at: 0) ?? 0) { return o }
                for flag in ["bold", "italic"] {
                    if let o = order(fa?.flag(flag) == true ? 1 : 0, fb?.flag(flag) == true ? 1 : 0) { return o }
                }
                let ma = a["effects"]?["justify"]?.arguments.contains { $0.text == "mirror" } == true
                let mb = b["effects"]?["justify"]?.arguments.contains { $0.text == "mirror" } == true
                if let o = order(ma ? 1 : 0, mb ? 1 : 0) { return o }
                if let o = order(fa?["line_spacing"]?.number(at: 0) ?? 1, fb?["line_spacing"]?.number(at: 0) ?? 1) { return o }
                if let o = order(a.text(at: 1) ?? "", b.text(at: 1) ?? "") { return o }
            }
            return (a.value("uuid") ?? "") < (b.value("uuid") ?? "")
        }
        let sorted = slots.map { fp.items[$0] }.sorted(by: before)
        for (slot, item) in zip(slots, sorted) { fp.items[slot] = item }
    }

    /// An arc's centre (CalcArcCenter of its start, mid and end), of its points on the board, `board`
    static func arcCenter(_ node: SExpr, _ board: (SExpr) -> IPoint) -> IPoint? {
        guard let s = node["start"], let m = node["mid"], let e = node["end"] else { return nil }
        return KiMath.arcCenter(board(s), board(m), board(e))
    }

    /// Millimetres as nanometres, rounded as KiCad's parser rounds them (nil as 0)
    static func nm(_ v: Double?) -> Int { KiMath.round((v ?? 0) * 1e6) }

    /// A footprint's text (a field, or an fp_text) moved by `d` on the board, as PCB_TEXT::Move moves it: its place
    /// on the board as the parser makes it, moved, written back relative to the footprint
    static func moveFootprintText(_ text: SExpr, of fp: SExpr, by d: IPoint) {
        guard let a = text["at"], a.number(at: 0) != nil, a.number(at: 1) != nil else { return }
        let p = BoardWorld.point(fp["at"]), theta = fp["at"]?.number(at: 2) ?? 0
        let abs = KiMath.rotate(BoardWorld.point(a), EDAAngle(degrees: theta)) + p + d
        let rel = KiMath.rotate(abs - p, EDAAngle(degrees: -theta))
        a.items[1] = mm(rel.x).sexpr
        a.items[2] = mm(rel.y).sexpr
    }

    /// A text's justification the other way round (left for right, top for bottom), as KeepUpright turns it
    static func flipJustification(_ text: SExpr) {
        let swap = ["left": "right", "right": "left", "top": "bottom", "bottom": "top"]
        guard let justify = text["effects"]?["justify"] else { return }
        for (i, item) in justify.items.enumerated() where i > 0 && item.kind == .symbol {
            if let s = swap[item.text] { justify.items[i] = SExpr(symbol: s) }
        }
    }

    /// An angle in (-180, 180] (EDA_ANGLE::Normalize180, a footprint's orientation)
    static func normalize180(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d <= -180 { d += 360 } else if d > 180 { d -= 360 }
        return d == 0 ? 0 : d
    }

    /// An angle in [0, 360) (EDA_ANGLE::Normalize)
    static func normalize360(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d == 360 || d == 0 ? 0 : d
    }

    // MARK: - Boxes

    /// KiCad's bounding box of a board item (BOARD_ITEM::GetBoundingBox; a footprint's without its texts,
    /// GetBoundingBox( false ), as `footprintBoxes` has them), whose right and bottom are KiCad's GetRight and
    /// GetBottom; nil for what the port does not box
    static func boundingBox(_ node: SExpr, footprintBoxes: [String: IBox], board: KiCadBoard) -> IBox? {
        switch node.head ?? "" {
        case "footprint":
            return footprintBoxes[node.value("uuid") ?? ""]
        case "segment":
            // (PCB_TRACK::GetBoundingBox: half its width, rounded up, round its ends, and one more for [pos, end))
            let a = BoardWorld.point(node["start"]), b = BoardWorld.point(node["end"])
            let r = (BoardWorld.iu(node["width"], 0) + 1) / 2
            return IBox(minX: min(a.x, b.x) - r, minY: min(a.y, b.y) - r, maxX: max(a.x, b.x) + r + 1, maxY: max(a.y, b.y) + r + 1)
        case "arc":
            // (the box of its effective shape, SHAPE_ARC::BBox, half its width round it, then as a track's)
            let a = BoardWorld.point(node["start"]), m = BoardWorld.point(node["mid"]), e = BoardWorld.point(node["end"])
            let width = BoardWorld.iu(node["width"], 0)
            let box = ShapeArc(start: a, mid: m, end: e, width: width).bbox()
            let r = (width + 1) / 2
            return IBox(minX: box.minX - r, minY: box.minY - r, maxX: box.maxX + r + 1, maxY: box.maxY + r + 1)
        case "via":
            var width = BoardWorld.iu(node["size"], 0)
            for layer in node["padstack"]?.all("layer") ?? [] where layer["size"] != nil { width = max(width, BoardWorld.iu(layer["size"], 0)) }
            let p = BoardWorld.point(node["at"]), r = (width + 1) / 2
            return IBox(minX: p.x - r, minY: p.y - r, maxX: p.x + r + 1, maxY: p.y + r + 1)
        case "zone":
            // (ZONE::GetBoundingBox: its outline's, SHAPE_POLY_SET::BBox)
            let points = BoardWorld.zoneOutline(node).polygons.flatMap { $0.flatMap(\.points) }
            return IBox(points: points)
        case "gr_text":
            return BoardWorld.textStrokes(node, footprint: nil)?.boundingBox
        case "gr_line", "gr_rect", "gr_circle", "gr_arc", "gr_poly", "gr_curve":
            let world = BoardWorld(board: board)
            return BoxSelection.drawing(node, nil, world, maxError: world.rules.maxError)?.box
        default:
            return nil
        }
    }
}
