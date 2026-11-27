// A footprint written as KiCad 10.0.8 writes one (pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr.cpp,
// PCB_IO_KICAD_SEXPR::format( const FOOTPRINT* ): its header, fields, attributes, then its drawings, points, pads,
// zones and groups each in the order of their sets (pcbnew/footprint.cpp, FOOTPRINT::cmp_drawings, cmp_pads and
// cmp_zones; pcbnew/pcb_point.cpp, PCB_POINT::cmp_points; pcbnew/board_item.cpp, BOARD_ITEM::ptr_cmp), with
// CTL_FOR_LIBRARY's omissions in a library (no id, place, library name, pad nets, pin functions); and saved into a
// library as PCB_IO_KICAD_SEXPR::FootprintSave saves it: a copy turned to 0° and onto the front, on no net, its
// mandatory fields given ids of their own (FOOTPRINT's copy constructor), each item without an id given one (the
// parser's new KIID). Copyright The KiCad Developers, see KiCad's AUTHORS.txt. GNU General Public License version 3
// or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// A footprint as KiCad's formatter writes it, on a board or in a library
public enum FootprintFormat {
    /// The fields every footprint has, in the order a footprint keeps them (FIELD_T)
    static let mandatory = ["Reference", "Value", "Datasheet", "Description"]

    /// The heads of a footprint's own properties, in the order format( FOOTPRINT ) writes them (after its fields)
    static let headerOrder = ["component_classes", "path", "sheetname", "sheetfile", "units", "solder_mask_margin",
                              "solder_paste_margin", "solder_paste_margin_ratio", "clearance", "zone_connect", "attr",
                              "stackup", "private_layers", "net_tie_pad_groups", "duplicate_pad_numbers_are_jumpers",
                              "jumper_pad_groups"]

    /// The text of `footprint` as FootprintSave writes it into a library's .kicad_mod (its copy turned to 0° and put on
    /// the front, CTL_FOR_LIBRARY)
    public static func libraryText(_ footprint: SExpr, boardCopper: [String]? = nil) -> String {
        libraryFootprint(footprint, boardCopper: boardCopper).formatted()
    }

    /// The footprint FootprintSave writes: a copy of `footprint` (FOOTPRINT::Clone: its mandatory fields' ids new),
    /// turned to 0° and onto the front (FLIP_DIRECTION::TOP_BOTTOM, the PCB editor's default) where it is not, on no
    /// net, formatted for a library (no id, no place, its name without its library's). `boardCopper`, for a board's
    /// footprint, the board's copper layers: a pad turned over on the board keeps only those of all KiCad's
    /// (PAD::Flip: FlipLayerMask of its layers with the board's copper layer count).
    public static func libraryFootprint(_ footprint: SExpr, boardCopper: [String]? = nil) -> SExpr {
        let fp = footprint.copy()
        let view = KiCadFootprint(fp, board: KiCadBoard(SExpr(list: [SExpr(symbol: "kicad_pcb"), fp])))
        // (FootprintSave: SetOrientation( ANGLE_0 ), then Flip where it is not on F.Cu)
        if view.rotation != 0 {
            BoardItems.rotateFootprint(fp, about: BoardItems.position(fp), degrees: -view.rotation, keepUpright: [])
        }
        if view.layer != "F.Cu" {
            if let boardCopper { expandCopper(fp, boardCopper) }
            view.flip(leftRight: false)
        }
        // (ClearAllNets)
        for item in fp.items where item.head == "pad" || item.head == "zone" || BoardWorld.footprintShapeHeads.contains(item.head ?? "") {
            item.remove("net")
            item.remove("net_name")
        }
        for field in fp.all("property") where mandatory.contains(field.text(at: 0) ?? "") {
            field.remove("uuid")
            ensureUUID(field)
        }
        return formatted(fp, library: true)
    }

    /// `footprint` as format( FOOTPRINT ) writes it: on a board (CTL_FOR_BOARD: its id, place and path, no version) or
    /// in a library (CTL_FOR_LIBRARY: its file format's version and generator, no id, place, path or library name, its
    /// pads on no net, no pin functions); each item without an id given a new one, its mandatory fields there (with
    /// KiCad's defaults, where a file left one out), its drawings, points, pads, zones and groups in KiCad's order
    /// `sorted` false keeps each kind of item in the order the footprint holds them, as KiCad's model holds what it
    /// read (FOOTPRINT's lists of drawings, points, pads, zones and groups), for a footprint to edit
    public static func formatted(_ footprint: SExpr, library: Bool, sorted: Bool = true) -> SExpr {
        let fp = footprint
        var head: [SExpr] = [SExpr(symbol: "footprint")]
        let name = fp.text(at: 0) ?? ""
        if library, let colon = name.firstIndex(of: ":") {
            head.append(SExpr(string: String(name[name.index(after: colon)...])))
        } else {
            head.append(SExpr(string: name))
        }
        if library {
            head += [SExpr("version", KiCadBoard.formatVersion), SExpr("generator", "pcbnew"), SExpr("generator_version", "10.0")]
        }
        if fp.flag("locked") || fp.items.contains(where: { $0.kind == .symbol && $0.text == "locked" }) {
            head.append(SExpr("locked", Keyword("yes")))
        }
        if fp.flag("placed") || fp.items.contains(where: { $0.kind == .symbol && $0.text == "placed" }) {
            head.append(SExpr("placed", Keyword("yes")))
        }
        head.append(fp["layer"] ?? SExpr("layer", "F.Cu"))
        if !library {
            head.append(fp["uuid"] ?? SExpr("uuid", KiCadBoard.newUUID()))
            head.append(fp["at"] ?? SExpr("at", 0.0, 0.0))
        }
        for name in ["descr", "tags"] {
            if let item = fp[name], item.text(at: 0)?.isEmpty == false { head.append(item) }
        }
        // its fields: the mandatory ones in their order, then the others as they come
        let fields = fp.all("property").filter { $0.text(at: 0) != "ki_fp_filters" }
        let onBack = (fp.value("layer") ?? "F.Cu") == "B.Cu"
        for name in mandatory {
            if let field = fields.last(where: { $0.text(at: 0) == name }) {
                head.append(field)
            } else if name == "Datasheet" || name == "Description" {
                // (as FOOTPRINT's constructor makes them: hidden on the fab layer)
                head.append(SExpr("property", name, "", SExpr("at", 0.0, 0.0, 0.0), SExpr("layer", onBack ? "B.Fab" : "F.Fab"),
                                  SExpr("hide", Keyword("yes")), SExpr("uuid", KiCadBoard.newUUID()),
                                  SExpr("effects", SExpr("font", SExpr("size", 1.27, 1.27)))))
            }
        }
        var seen = Set(mandatory)
        for field in fields where seen.insert(field.text(at: 0) ?? "").inserted { head.append(field) }
        for field in head where field.head == "property" { ensureUUID(field) }
        if let filters = fp.all("property").first(where: { $0.text(at: 0) == "ki_fp_filters" }) { head.append(filters) }
        for name in headerOrder {
            if library && name == "path" { continue }
            if name == "duplicate_pad_numbers_are_jumpers" {
                head.append(fp[name] ?? SExpr(name, Keyword("no")))
                continue
            }
            if let item = fp[name] { head.append(item) }
        }
        // its items, each set in its order
        let drawings = fp.items.filter { BoardItems.footprintDrawings[$0.head ?? ""] != nil }
        let points = fp.all("point"), pads = fp.all("pad"), zones = fp.all("zone"), groups = fp.all("group")
        for item in drawings + points + pads + zones + groups { ensureUUID(item) }
        if library {
            for pad in pads {
                for name in ["net", "pinfunction", "pintype"] { pad.remove(name) }
                if let layers = pad["layers"] { layers.items = [layers.items[0]] + libraryLayers(pad).map { SExpr(string: $0) } }
                // (its layers' zone connections are a board's: none in a library)
                pad.remove("zone_layer_connections")
            }
            for item in drawings + zones { item.remove("net") }
        }
        for zone in zones { normalizeZone(zone, library: library) }
        // (a text's angle as EDA_TEXT keeps it, from 0 up to 360; a custom pad's shapes each with its fill)
        for text in head.filter({ $0.head == "property" }) + drawings.filter({ $0.head == "fp_text" }) {
            guard let at = text["at"], let angle = at.number(at: 2), angle < 0 || angle >= 360 else { continue }
            at.items[3] = BoardItems.normalize360(angle).sexpr
        }
        for pad in pads {
            for primitive in pad["primitives"]?.arguments ?? [] where ["gr_circle", "gr_rect", "gr_poly"].contains(primitive.head ?? "") {
                if primitive["fill"] == nil { primitive.items.append(SExpr("fill", Keyword("no"))) }
            }
        }
        let placement = BoardWorld.FootprintPlacement(fp)
        let kept = groups.filter { ($0["members"]?.items.count ?? 0) > 1 }
        var body: [SExpr]
        if sorted {
            let set = SExpr(list: [SExpr(symbol: "footprint")] + drawings)
            BoardItems.sortDrawings(set) { placement.apply(BoardWorld.point($0)) }
            body = Array(set.items.dropFirst())
            body += points.sorted(by: pointBefore)
            body += pads.sorted { padBefore($0, $1, placement: placement) }
            body += zones.sorted(by: zoneBefore)
            // (BOARD_ITEM::ptr_cmp: a group's layers, its members' all, then its id)
            func layers(_ group: SExpr) -> [Int] {
                let ids = Set(BoardItems.members(group))
                return Array(Set(fp.items.filter { ids.contains($0.value("uuid") ?? "") }.flatMap(layerSeq))).sorted()
            }
            body += kept.sorted { a, b in lexicographic(layers(a), layers(b)) ?? ((a.value("uuid") ?? "") < (b.value("uuid") ?? "")) }
        } else {
            body = drawings + points + pads + zones + kept
        }
        body += fp.all("variant")
        var tail: [SExpr] = [fp["embedded_fonts"] ?? SExpr("embedded_fonts", Keyword("no"))]
        if let files = fp["embedded_files"] { tail.append(files) }
        tail += fp.all("model").filter { !($0.text(at: 0) ?? "").isEmpty }
        return SExpr(list: head + body + tail)
    }

    // MARK: - Layers

    /// A footprint's pads' layers of every copper layer ("*.Cu") made those of a board (`boardCopper`), "F&B.Cu" the
    /// outer two
    public static func expandCopper(_ fp: SExpr, _ boardCopper: [String]) {
        for pad in fp.all("pad") {
            guard let layers = pad["layers"] else { continue }
            var names: [String] = []
            for n in layers.arguments.map(\.text) {
                switch n {
                case "*.Cu": names += boardCopper
                case "F&B.Cu": names += ["F.Cu", "B.Cu"]
                default: names.append(n)
                }
            }
            layers.items = [layers.items[0]] + names.map { SExpr(string: $0) }
        }
    }

    /// A pad's layers as formatLayers writes them with no board (a library's): "*.Cu" for every copper layer of
    /// KiCad's, or for the outer two alone; both sides' adhesive, paste, silkscreen, mask, courtyard and fabrication
    /// layers each as one; then each other layer by name, in the order of their ids
    static func libraryLayers(_ pad: SExpr) -> [String] {
        var ids = Set(layerSeq(pad))
        var out: [String] = []
        let copper = ids.filter { $0 == 0 || $0 == 2 || ($0 >= 4 && $0 % 2 == 0) }
        if copper.count == 32 || copper == [0, 2] {
            out.append("*.Cu")
            ids.subtract(copper)
        }
        for (kind, f, b) in [("Adhes", 9, 11), ("Paste", 13, 15), ("SilkS", 5, 7), ("Mask", 1, 3), ("CrtYd", 31, 29), ("Fab", 35, 33)]
            where ids.contains(f) && ids.contains(b) {
            out.append("*.\(kind)")
            ids.subtract([f, b])
        }
        return out + ids.sorted().compactMap(layerName)
    }

    // MARK: - Ids

    /// An item given an id where its file has none (the parser's KIID, new), where KiCad writes one: a field's and a
    /// text's after its layer (and hide), a pad's before its padstack's layers, a zone's after its layers, a group's
    /// after its name, every other item's last
    static func ensureUUID(_ item: SExpr) {
        guard item["uuid"] == nil else { return }
        let id = SExpr("uuid", KiCadBoard.newUUID())
        switch item.head {
        case "property", "fp_text":
            let i = item.items.firstIndex { $0.head == "effects" } ?? item.items.count
            item.items.insert(id, at: i)
        case "pad":
            let i = item.items.firstIndex { $0.head == "padstack" } ?? item.items.count
            item.items.insert(id, at: i)
        case "zone":
            let i = item.items.lastIndex { $0.head == "layer" || $0.head == "layers" }.map { $0 + 1 } ?? item.items.count
            item.items.insert(id, at: i)
        case "group":
            item.items.insert(id, at: min(2, item.items.count))
        default:
            item.items.append(id)
        }
    }

    /// A footprint's zone as the parser reads it and format( ZONE ) writes it again: on no net where its file gave it
    /// net 0 (or an empty name), no longer its filled areas' thickness (which KiCad 10 reads no more), on one layer
    /// written as one (formatLayer), its id after its layers, and its fill's island removal mode written
    static func normalizeZone(_ zone: SExpr, library: Bool) {
        zone.items.removeAll { ($0.head == "net" && ($0.text(at: 0) == "0" || $0.text(at: 0) == "")) || ($0.head == "net_name" && $0.text(at: 0) == "") }
        zone.remove("filled_areas_thickness")
        zone.items.removeAll { $0.head == "name" && $0.text(at: 0) == "" }
        if let layers = zone["layers"], let i = zone.items.firstIndex(where: { $0 === layers }) {
            // (its layers as an LSET: one written alone; a copper zone's every layer by name, in their ids' order, all
            // of KiCad's where no board limits them; another's as formatLayers writes them)
            let ids = layerSeq(zone)
            let names = ids.compactMap(layerName)
            if names.count == 1 {
                zone.items[i] = SExpr("layer", names[0])
            } else if library, ids.contains(where: { $0 == 0 || $0 == 2 || ($0 >= 4 && $0 <= 62 && $0 % 2 == 0) }) {
                zone.items[i] = SExpr("layers", names.map { $0 as SExprConvertible })
            }
        }
        ensureUUID(zone)
        if let fill = zone["fill"], fill["island_removal_mode"] == nil {
            let i = fill.items.lastIndex { ["thermal_gap", "thermal_bridge_width", "smoothing", "radius"].contains($0.head ?? "") }
            fill.items.insert(SExpr("island_removal_mode", 0), at: (i ?? fill.items.count - 1) + 1)
        }
    }

    // MARK: - Orders

    /// A list of layers' ids, as LSET::Seq gives them (in order), "*.Cu" all of KiCad's copper layers
    static func layerSeq(_ item: SExpr) -> [Int] {
        var ids = Set<Int>()
        let names = item["layers"]?.arguments.map(\.text) ?? item.value("layer").map { [$0] } ?? []
        for n in names {
            switch n {
            case "*.Cu": ids.formUnion([0, 2] + (1...30).map { 2 + 2 * $0 })
            case "F&B.Cu": ids.formUnion([0, 2])
            case _ where n.hasPrefix("*."):
                if let f = BoardDRC.layerID("F" + n.dropFirst()), let b = BoardDRC.layerID("B" + n.dropFirst()) { ids.formUnion([f, b]) }
            default:
                if let id = BoardDRC.layerID(n) { ids.insert(id) }
            }
        }
        return ids.sorted()
    }

    /// A layer's name by its id (LSET::Name)
    static func layerName(_ id: Int) -> String? {
        let fixed = [0: "F.Cu", 2: "B.Cu", 1: "F.Mask", 3: "B.Mask", 5: "F.SilkS", 7: "B.SilkS", 9: "F.Adhes", 11: "B.Adhes",
                     13: "F.Paste", 15: "B.Paste", 17: "Dwgs.User", 19: "Cmts.User", 21: "Eco1.User", 23: "Eco2.User",
                     25: "Edge.Cuts", 27: "Margin", 29: "B.CrtYd", 31: "F.CrtYd", 33: "B.Fab", 35: "F.Fab"]
        if let name = fixed[id] { return name }
        if id >= 4 && id % 2 == 0 { return "In\((id - 2) / 2).Cu" }
        if id >= 39 && id % 2 == 1 { return "User.\((id - 37) / 2)" }
        return nil
    }

    static func lexicographic(_ a: [Int], _ b: [Int]) -> Bool? {
        a == b ? nil : a.lexicographicallyPrecedes(b)
    }

    static func uuidBefore(_ a: SExpr, _ b: SExpr) -> Bool { (a.value("uuid") ?? "") < (b.value("uuid") ?? "") }

    /// PCB_POINT::cmp_points: by layer, place, size, then id
    static func pointBefore(_ a: SExpr, _ b: SExpr) -> Bool {
        let la = BoardDRC.layerID(a.value("layer") ?? "") ?? -1, lb = BoardDRC.layerID(b.value("layer") ?? "") ?? -1
        if la != lb { return la < lb }
        let pa = BoardWorld.point(a["at"]), pb = BoardWorld.point(b["at"])
        if pa.x != pb.x { return pa.x < pb.x }
        if pa.y != pb.y { return pa.y < pb.y }
        let sa = BoardWorld.iu(a["size"], 0), sb = BoardWorld.iu(b["size"], 0)
        if sa != sb { return sa < sb }
        return uuidBefore(a, b)
    }

    /// A pad's shape as PAD_SHAPE numbers it (a rounded rectangle with chamfers a chamfered one)
    static func padShape(_ pad: SExpr) -> Int {
        switch pad.text(at: 2) ?? "" {
        case "circle": return 0
        case "rect": return 1
        case "oval": return 2
        case "trapezoid": return 3
        case "roundrect":
            let chamfered = (pad["chamfer_ratio"]?.number(at: 0) ?? 0) > 0 && !(pad["chamfer"]?.arguments.isEmpty ?? true)
            return chamfered ? 5 : 4
        case "custom": return 6
        default: return 0
        }
    }

    /// FOOTPRINT::cmp_pads: by number (StrNumCmp), place on the footprint, size and shape, layers, then id
    static func padBefore(_ a: SExpr, _ b: SExpr, placement: BoardWorld.FootprintPlacement) -> Bool {
        let na = a.text(at: 0) ?? "", nb = b.text(at: 0) ?? ""
        if na != nb { return BoardClipboard.strNumCmp(na, nb, ignoreCase: false) < 0 }
        let pa = BoardWorld.point(a["at"]), pb = BoardWorld.point(b["at"])
        if pa.x != pb.x { return pa.x < pb.x }
        if pa.y != pb.y { return pa.y < pb.y }
        // (a padstack of the same pads' shape on every layer: its one layer's)
        let sa = BoardWorld.point(a["size"]), sb = BoardWorld.point(b["size"])
        if sa.x != sb.x { return sa.x < sb.x }
        if sa.y != sb.y { return sa.y < sb.y }
        if padShape(a) != padShape(b) { return padShape(a) < padShape(b) }
        if let o = lexicographic(layerSeq(a), layerSeq(b)) { return o }
        return uuidBefore(a, b)
    }

    /// FOOTPRINT::cmp_zones: by priority, layers, how many corners, the corners, then id
    static func zoneBefore(_ a: SExpr, _ b: SExpr) -> Bool {
        let pa = Int(a.value("priority") ?? "") ?? 0, pb = Int(b.value("priority") ?? "") ?? 0
        if pa != pb { return pa < pb }
        if let o = lexicographic(layerSeq(a), layerSeq(b)) { return o }
        func corners(_ z: SExpr) -> [IPoint] {
            z.all("polygon").flatMap { $0["pts"]?.items.filter { $0.head == "xy" }.map(BoardWorld.point) ?? [] }
        }
        let ca = corners(a), cb = corners(b)
        if ca.count != cb.count { return ca.count < cb.count }
        for (p, q) in zip(ca, cb) where p != q { return p.x != q.x ? p.x < q.x : p.y < q.y }
        return uuidBefore(a, b)
    }
}
