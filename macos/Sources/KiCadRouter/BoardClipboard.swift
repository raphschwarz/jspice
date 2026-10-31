// Copy, cut, paste and duplicate, as KiCad's PCB editor does them (KiCad 10.0.7: pcbnew/kicad_clipboard.cpp,
// CLIPBOARD_IO::SaveSelection, the clipboard's text: a footprint alone as itself, its pads on no net, else a board of
// the selection, its layers and its items, each unlocked and placed about the reference point; pcbnew/tools/
// edit_tool.cpp, EDIT_TOOL::copyToClipboard, cutToClipboard and Duplicate; pcbnew/tools/pcb_control.cpp,
// PCB_CONTROL::Paste, pruneItemLayers and placeBoardItems: the nets kept by name, new ids, a footprint's link to its
// symbol let go, a zone's name made its own, what is on layers the board has not left out; pcbnew/board.cpp,
// BOARD::MapNets and MakeUniqueZoneName; pcbnew/tools/board_reannotate_tool.cpp, ReannotateDuplicates, with
// common/refdes_utils.cpp and common/string_utils.cpp's StrNumCmp; pcbnew/tools/pcb_grid_helper.cpp,
// PCB_GRID_HELPER::BestDragOrigin, computeAnchors and nearestAnchor: the point a copy or a duplicate is picked up by).
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// The text KiCad's clipboard holds of a selection (CLIPBOARD_IO), so that what JSpice copies pastes in KiCad and what
/// KiCad copies pastes here
public enum BoardClipboard {
    /// What a paste does with the footprints' references (KiCad's Paste Special): keeps them, gives each one a
    /// reference the board does not have yet, or makes them all REF**
    public enum Annotations: Sendable {
        case keep, unique, remove
    }

    /// The clipboard's text of the board's items `uuids` (in the order they were selected), placed about `reference`
    /// (nm: it is at 0, 0 in the text); nil when none of them is on the board
    public static func text(_ board: KiCadBoard, items uuids: [String], reference: IPoint) -> String? {
        let items = uuids.compactMap { BoardItems.item(board, $0) }
        guard !items.isEmpty else { return nil }
        let back = IPoint(-reference.x, -reference.y)
        if items.count == 1, items[0].head == "footprint" {
            // (a footprint alone, safe to take to another board: its pads on no net, unlocked)
            let fp = items[0].copy()
            for pad in fp.all("pad") { pad.remove("net") }
            BoardItems.unlock(fp)
            BoardItems.translate(fp, by: back)
            versioned(fp)
            return fp.formatted(.compactTextProperties)
        }
        // (a board's text, to have KiCad's whole parser read it: its layers, and the items)
        var top: [SExprConvertible] = [SExpr("version", KiCadBoard.formatVersion), SExpr("generator", "pcbnew"),
                                       SExpr("generator_version", "10.0")]
        if let layers = board.root["layers"] { top.append(layers.copy()) }
        for item in items {
            let copy = item.copy()
            BoardItems.unlock(copy)
            if copy.head == "group" || copy.head == "generated" {
                // (a deep copy, its members after it, each unlocked and moved)
                BoardItems.translate(copy, by: back)
                top.append(copy)
                for member in BoardItems.descendants(item, in: board) {
                    let m = member.copy()
                    BoardItems.unlock(m)
                    BoardItems.translate(m, by: back)
                    if m.head == "footprint" { versioned(m) }
                    top.append(m)
                }
                continue
            }
            BoardItems.translate(copy, by: back)
            if copy.head == "footprint" { versioned(copy) }
            top.append(copy)
        }
        return SExpr("kicad_pcb", top).formatted(.compactTextProperties)
    }

    /// The fields every footprint has (PCB_FIELD::IsMandatory)
    static let mandatoryFields: Set<String> = ["Reference", "Value", "Datasheet", "Description"]

    /// A footprint as KiCad writes one on the clipboard: its file format's version after its library link (the
    /// clipboard's formatter leaves out CTL_OMIT_FOOTPRINT_VERSION), and its mandatory fields with ids of their own
    /// (FOOTPRINT's copy is made with its own mandatory fields, given the original's but for their ids)
    static func versioned(_ fp: SExpr) {
        for field in fp.all("property") where mandatoryFields.contains(field.text(at: 0) ?? "") {
            field["uuid"]?.items[1] = SExpr(string: KiCadBoard.newUUID())
        }
        fp.items.removeAll { ["version", "generator", "generator_version"].contains($0.head ?? "") }
        let at = min(2, fp.items.count)
        fp.items.insert(contentsOf: [SExpr("version", KiCadBoard.formatVersion), SExpr("generator", "pcbnew"),
                                     SExpr("generator_version", "10.0")], at: at)
    }

    /// What the clipboard holds, read as KiCad's paste reads it (PCB_IO_KICAD_SEXPR::Parse): a board's items, or a
    /// footprint; nil for text that is neither (which KiCad pastes as a text of its own)
    static func read(_ text: String) -> (items: [SExpr], layers: SExpr?)? {
        guard let root = try? SExpr.parse(text) else { return nil }
        switch root.head {
        case "kicad_pcb":
            return (root.items.filter { BoardItems.heads.contains($0.head ?? "") }, root["layers"])
        case "footprint", "module":
            return ([root], nil)
        default:
            return nil
        }
    }

    // MARK: - Layers

    /// The layers a board has (its enabled layers), by name
    static func enabledLayers(_ board: KiCadBoard) -> [String] {
        board.root["layers"]?.arguments.compactMap { $0.text(at: 0) } ?? []
    }

    /// An item's layers, by name, its wildcards spelt out to the board's (*.Cu, F&B.Cu, *.Mask...)
    static func layers(of node: SExpr, enabled: [String]) -> [String] {
        let names: [String]
        if let l = node["layers"] { names = l.arguments.compactMap(\.text) } else if let l = node.value("layer") { names = [l] } else { names = [] }
        var out: [String] = []
        for name in names {
            if name.hasPrefix("*.") {
                let suffix = name.dropFirst(1)
                out += enabled.filter { $0.hasSuffix(suffix) }
            } else if name == "F&B.Cu" {
                out += ["F.Cu", "B.Cu"]
            } else {
                out.append(name)
            }
        }
        return out
    }

    // MARK: - Reference designators

    /// UTIL::GetRefDesPrefix: what is left of a reference once the digits and question marks at its end are gone
    static func refDesPrefix(_ ref: String) -> String {
        var chars = Array(ref)
        while let last = chars.last, last == "?" || last.isASCII && last.isNumber { chars.removeLast() }
        return String(chars)
    }

    /// UTIL::GetRefDesNumber: the number from a reference's first digit on (wxString::ToLong of all of it), -1 if it
    /// has none or the rest is not a number
    static func refDesNumber(_ ref: String) -> Int {
        guard let first = ref.firstIndex(where: { $0.isASCII && $0.isNumber }) else { return -1 }
        let rest = String(ref[first...])
        return Int(rest).flatMap { Int32(exactly: $0).map(Int.init) } ?? -1
    }

    /// StrNumCmp: strings compared with their runs of digits as numbers, case ignored if asked
    static func strNumCmp(_ a: String, _ b: String, ignoreCase: Bool) -> Int {
        let s1 = Array(a.unicodeScalars), s2 = Array(b.unicodeScalars)
        var i = 0, j = 0
        func digit(_ c: Unicode.Scalar) -> Bool { c.value >= 48 && c.value <= 57 }
        func upper(_ c: Unicode.Scalar) -> Unicode.Scalar { c.value >= 97 && c.value <= 122 ? Unicode.Scalar(c.value - 32)! : c }
        while i < s1.count && j < s2.count {
            var c1 = s1[i], c2 = s2[j]
            if digit(c1) && digit(c2) {
                var n1 = 0, n2 = 0
                repeat { n1 = n1 &* 10 &+ Int(s1[i].value) - 48; i += 1 } while i < s1.count && digit(s1[i])
                repeat { n2 = n2 &* 10 &+ Int(s2[j].value) - 48; j += 1 } while j < s2.count && digit(s2[j])
                if n1 < n2 { return -1 }
                if n1 > n2 { return 1 }
                c1 = i < s1.count ? s1[i] : Unicode.Scalar(0)
                c2 = j < s2.count ? s2[j] : Unicode.Scalar(0)
            }
            if ignoreCase {
                if c1 != c2 {
                    let u1 = upper(c1), u2 = upper(c2)
                    if u1 != u2 { return u1.value < u2.value ? -1 : 1 }
                }
            } else {
                if c1.value < c2.value { return -1 }
                if c1.value > c2.value { return 1 }
            }
            if i < s1.count { i += 1 }
            if j < s2.count { j += 1 }
        }
        if i == s1.count && j != s2.count { return -1 }
        if i != s1.count && j == s2.count { return 1 }
        return 0
    }

    /// BOARD_REANNOTATE_TOOL::ReannotateDuplicates: the footprints among `selected` (and those of the groups among
    /// them, whose members `members` finds) given references `existing`'s footprints do not have: the same prefix,
    /// the next free number
    static func reannotateDuplicates(_ selected: [SExpr], existing: [SExpr], board: KiCadBoard, members: (SExpr) -> [SExpr]) {
        func footprints(_ items: [SExpr]) -> [KiCadFootprint] {
            var out: [KiCadFootprint] = []
            for item in items {
                if item.head == "footprint" { out.append(KiCadFootprint(item, board: board)) }
                if item.head == "group" {
                    for m in members(item) where m.head == "footprint" { out.append(KiCadFootprint(m, board: board)) }
                }
            }
            return out
        }
        var used: [String: [String]] = [:]
        for fp in footprints(existing) { used[fp.reference, default: []].append(fp.uuid) }
        let sorted = footprints(selected).sorted { a, b in
            let c = strNumCmp(a.reference, b.reference, ignoreCase: true)
            if c != 0 { return c < 0 }
            let pa = BoardWorld.point(a.node["at"]), pb = BoardWorld.point(b.node["at"])
            if pa.y == pb.y { return pa.x == pb.x ? a.uuid < b.uuid : pa.x < pb.x }
            return pa.y > pb.y
        }
        for fp in sorted {
            let stem = refDesPrefix(fp.reference)
            var value = refDesNumber(fp.reference)
            var duplicate = false
            while let owners = used[fp.reference] {
                if owners.contains(where: { $0 != fp.uuid }) { duplicate = true }
                if !duplicate { break }
                value = value < 0 ? 1 : value + 1
                fp.setProperty("Reference", stem + String(value))
            }
            if duplicate { used[fp.reference, default: []].append(fp.uuid) }
        }
    }

    // MARK: - Zone names

    /// BOARD::MakeUniqueZoneName: a zone's name, or, if the board has it already, its root (a trailing _N taken off)
    /// with the first _1, _2... it does not have
    static func uniqueZoneName(_ name: String, inUse: (String) -> Bool) -> String {
        guard !name.isEmpty, inUse(name) else { return name }
        var root = name
        if let underscore = name.lastIndex(of: "_") {
            let suffix = name[name.index(after: underscore)...]
            if !suffix.isEmpty && suffix.allSatisfy({ $0.isNumber }) { root = String(name[..<underscore]) }
        }
        var i = 1
        while inUse("\(root)_\(i)") { i += 1 }
        return "\(root)_\(i)"
    }
}

// MARK: - The point a selection is picked up by

extension BoardClipboard {
    /// What an anchor is (PCB_GRID_HELPER's ANCHOR_FLAGS)
    struct AnchorFlags: OptionSet {
        let rawValue: Int
        static let corner = AnchorFlags(rawValue: 1), outline = AnchorFlags(rawValue: 2), origin = AnchorFlags(rawValue: 8)
    }

    /// PCB_GRID_HELPER::BestDragOrigin: the point of `items` (the board's, by id) nearest `cursor` to pick them up by:
    /// the nearest of their origins (footprints' positions and centres, pads' centres under the cursor, vias, texts,
    /// tracks' middles), or of their corners (track ends, shapes' corners) if nearer, or, farther than
    /// `lineSnapMinCornerDistance` (KiCad's 50 pixels, nm) from both, the nearest point of their outlines (a zone's, a
    /// polygon's, a circle's quarters) if nearer; the cursor itself if they have none. `grid` (nm) is the grid's size:
    /// a footprint's centre counts only farther from its position than a grid square's diagonal. `moving`: as KiCad's
    /// move picks them up (EDIT_TOOL::doMoveSelection, after a duplicate too), which takes each footprint's pads as
    /// items of their own, every pad's centre an origin
    public static func bestDragOrigin(_ board: KiCadBoard, items uuids: [String], cursor: IPoint, lineSnapMinCornerDistance: Double,
                                      grid: IPoint = IPoint(1_000, 1_000), moving: Bool = false) -> IPoint {
        var anchors: [(p: IPoint, flags: AnchorFlags)] = []
        func add(_ p: IPoint, _ f: AnchorFlags) { anchors.append((p, f)) }
        let world = BoardWorld(board: board)
        let boxes = BoxSelection(board: board)
        func anchorsOf(_ node: SExpr) {
            switch node.head ?? "" {
            case "footprint":
                let placement = BoardWorld.FootprintPlacement(node)
                // (the pads under the cursor: their centres)
                if let f = boxes.footprints.first(where: { $0.uuid == node.value("uuid") }) {
                    for pad in f.pads where pad.box.minX <= cursor.x && cursor.x <= pad.box.maxX
                        && pad.box.minY <= cursor.y && cursor.y <= pad.box.maxY {
                        add(pad.position, .origin)
                    }
                    for point in node.all("point") { add(BoardWorld.point(point["at"]), .origin) }
                    let position = placement.position
                    add(position, .origin)
                    let center = f.box.center
                    let dx = center.x - position.x, dy = center.y - position.y
                    if dx * dx + dy * dy > grid.x * grid.x + grid.y * grid.y { add(center, .origin) }
                }
            case "segment":
                let a = BoardWorld.point(node["start"]), b = BoardWorld.point(node["end"])
                add(a, .corner)
                add(b, .corner)
                // (BOARD_ITEM::GetCenter: its box's)
                if let box = BoardItems.boundingBox(node, footprintBoxes: [:], board: board) { add(box.center, .origin) }
            case "arc":
                add(BoardWorld.point(node["start"]), .corner)
                add(BoardWorld.point(node["end"]), .corner)
                add(BoardWorld.point(node["mid"]), .corner)
            case "via", "target":
                add(BoardWorld.point(node["at"]), [.origin, .corner])
            case "gr_text":
                add(BoardWorld.point(node["at"]), .origin)
            case "zone":
                let polygons = BoardWorld.zoneOutline(node).polygons
                let corners = polygons.flatMap { $0.flatMap(\.points) }
                for p in corners { add(p, .corner) }
                if let near = nearestOnClosedChain(corners, cursor) { add(near, .outline) }
            case "gr_line", "gr_rect", "gr_circle", "gr_arc", "gr_poly", "gr_curve":
                guard let d = world.readDrawing(node, placement: nil) else { return }
                switch d.kind {
                case .circle:
                    let r = KiMath.round(DPoint(IPoint(d.start.x - d.end.x, d.start.y - d.end.y)).norm)
                    add(d.start, .origin)
                    for q in [IPoint(-r, 0), IPoint(r, 0), IPoint(0, -r), IPoint(0, r)] { add(d.start + q, .outline) }
                case .arc:
                    add(d.start, .corner)
                    add(d.end, .corner)
                    add(BoardWorld.point(node["mid"]), .corner)
                    add(d.center, .origin)
                case .rect:
                    let box = IBox(d.start, d.end)
                    let tl = IPoint(box.minX, box.minY), tr = IPoint(box.maxX, box.minY), br = IPoint(box.maxX, box.maxY),
                        bl = IPoint(box.minX, box.maxY)
                    add(box.center, .corner)
                    for (a, b) in [(tl, tr), (tr, br), (br, bl), (bl, tl)] {
                        add(a, .corner)
                        add(IPoint(a.x + (b.x - a.x) / 2, a.y + (b.y - a.y) / 2), .corner)
                    }
                case .segment:
                    add(d.start, .corner)
                    add(d.end, .corner)
                    add(IPoint((d.start.x + d.end.x) / 2, (d.start.y + d.end.y) / 2), .corner)
                case .poly:
                    for p in d.poly { add(p, .corner) }
                    if let near = nearestOnClosedChain(d.poly, cursor) { add(near, .outline) }
                case .bezier:
                    let pts = (node["pts"]?.arguments ?? []).filter { $0.head == "xy" }.map(BoardWorld.point)
                    if let first = pts.first, let last = pts.last {
                        add(first, .corner)
                        add(last, .corner)
                        add(first, .origin)
                    }
                }
            case "group":
                for m in BoardItems.descendants(node, in: board) where m.head != "group" { anchorsOf(m) }
            default:
                break
            }
        }
        for id in uuids {
            guard let node = BoardItems.item(board, id) else { continue }
            anchorsOf(node)
            if moving, node.head == "footprint", let f = boxes.footprints.first(where: { $0.uuid == id }) {
                for pad in f.pads { add(pad.position, .origin) }
            }
        }
        func nearest(_ flags: AnchorFlags) -> IPoint? {
            var best: IPoint?
            var min = Int.max
            for a in anchors where a.flags.isSuperset(of: flags) {
                let dx = a.p.x - cursor.x, dy = a.p.y - cursor.y
                let d = dx * dx + dy * dy
                if d < min { (min, best) = (d, a.p) }
            }
            return best
        }
        var best: IPoint?
        var minDist = Double.greatestFiniteMagnitude
        if let o = nearest(.origin) { (best, minDist) = (o, o.distance(cursor)) }
        if let c = nearest(.corner), c.distance(cursor) < minDist { (best, minDist) = (c, c.distance(cursor)) }
        if let l = nearest(.outline), minDist > lineSnapMinCornerDistance && l.distance(cursor) < minDist { best = l }
        return best ?? cursor
    }

    /// SHAPE_LINE_CHAIN::NearestPoint of a closed chain of `points`: the nearest point of its sides to `p`
    static func nearestOnClosedChain(_ points: [IPoint], _ p: IPoint) -> IPoint? {
        guard !points.isEmpty else { return nil }
        return LineChain(points, closed: true).nearestPoint(p)
    }
}
