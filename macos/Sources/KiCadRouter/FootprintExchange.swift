// A board's footprint exchanged for another (its library's, or the footprint editor's), as KiCad 10.0.8 exchanges one
// (pcbnew/pcb_edit_frame.cpp, PCB_EDIT_FRAME::ExchangeFootprint, matchItemsBySimilarity and processTextItem), with the
// items matched by the similarity KiCad gives them (pcbnew/pad.cpp and padstack.cpp, PAD::Similarity and
// PADSTACK::Similarity; pcbnew/pcb_shape.cpp and common/eda_shape.cpp, PCB_SHAPE::Similarity and
// EDA_SHAPE::Similarity, with libs/core/include/core/kicad_algo.h, longest_common_subset; pcbnew/pcb_text.cpp,
// pcbnew/pcb_field.cpp and common/eda_text.cpp, PCB_TEXT::Similarity, PCB_FIELD::Similarity, EDA_TEXT::Similarity and
// Levenshtein, with common/font/text_attributes.cpp, TEXT_ATTRIBUTES::Compare; pcbnew/zone.cpp, ZONE::Similarity;
// pcbnew/pcb_point.cpp, PCB_POINT::Similarity; pcbnew/pcb_group.cpp, PCB_GROUP::Similarity); and the board's footprints
// updated from their libraries as Update Footprints from Library updates them (pcbnew/dialogs/
// dialog_exchange_footprints.cpp, DIALOG_EXCHANGE_FOOTPRINTS: processMatchingFootprints, processFootprint, isMatch,
// its update mode's defaults; pcbnew/load_select_footprint.cpp, PCB_BASE_FRAME::loadFootprint and PlaceFootprint).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt. GNU General Public License version 3 or later, as KiCad
// (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// ExchangeFootprint and Update Footprints from Library
public enum FootprintExchange {
    /// What of the board's footprint the exchange resets to the new one's (ExchangeFootprint's flags); each on, as
    /// the footprint editor's Update Footprint on Board has them
    public struct Options: Sendable, Equatable {
        public var deleteExtraTexts = true
        public var resetTextLayers = true
        public var resetTextEffects = true
        public var resetTextPositions = true
        public var resetTextContent = true
        public var resetFabricationAttrs = true
        public var resetClearanceOverrides = true
        public var reset3DModels = true

        public init() {}

        /// The Update Footprints from Library dialog's own (its update mode's first settings): texts and fabrication
        /// attributes kept, clearance overrides and 3D models updated
        public static var updateDialog: Options {
            var o = Options()
            o.deleteExtraTexts = false
            o.resetTextLayers = false
            o.resetTextEffects = false
            o.resetTextPositions = false
            o.resetTextContent = false
            o.resetFabricationAttrs = false
            return o
        }
    }

    // MARK: - Exchanging

    /// The board's footprint `existing` (a node of `board`) exchanged for `new` (a footprint on no board, at 0, 0,
    /// unturned, on the front), as ExchangeFootprint exchanges them: `new` put where `existing` is, onto its side
    /// (Flip, `flipLeftRight` for the PCB editor's left-right flip direction) and turned as it is (SetOrientation),
    /// locked as it is, its id and its reference's and value's ids; the new pads, drawings, zones, points, groups and
    /// fields matched to the old by similarity and given their ids (the pads their nets and pin functions); the old
    /// texts' text, layers, styles and places kept as `options` say, those with no match kept unless they are to be
    /// deleted; the old attributes, clearance overrides and models kept unless reset; its link to its symbol kept.
    /// `new` takes `existing`'s place among the board's items.
    public static func exchange(_ existing: SExpr, for new: SExpr, on board: KiCadBoard, options: Options = Options(),
                                flipLeftRight: Bool = false) {
        let old = KiCadFootprint(existing, board: board)
        let fp = new
        fp.items[1] = fp.items[1]
        let view = KiCadFootprint(fp, board: board)
        if fp["uuid"] == nil { FootprintFormat.ensureUUID(fp) }
        if fp["at"] == nil { fp.insert(SExpr("at", 0.0, 0.0), after: ["uuid", "layer"]) }
        // (PlaceFootprint: SetPosition, the footprint's zones and points moved with it)
        BoardItems.translate(fp, by: BoardItems.position(existing) - BoardItems.position(fp))
        if view.layer != old.layer { view.flip(leftRight: flipLeftRight) }
        if view.rotation != old.rotation {
            BoardItems.rotateFootprint(fp, about: BoardItems.position(fp), degrees: old.rotation - view.rotation, keepUpright: [])
        }
        fp.items.removeAll { $0.head == "locked" || ($0.kind == .symbol && $0.text == "locked") }
        if old.isLocked { fp.items.insert(SExpr("locked", Keyword("yes")), at: 2) }
        fp.set(SExpr("uuid", old.uuid))
        for name in ["Reference", "Value"] {
            if let id = field(existing, name)?.value("uuid"), let f = field(fp, name) { f.set(SExpr("uuid", id)) }
        }
        // (the board's footprint as KiCad has it once it has read the board: a field of its own read without a pen
        // keeps the one PCB_FIELD::StyleFromSettings gave it before its effects were read)
        for field in existing.all("property") where !FootprintFormat.mandatory.contains(field.text(at: 0) ?? "") {
            guard let font = field["effects"]?["font"], font["thickness"] == nil else { continue }
            let pen = TextDefaults(project: nil).style(field.value("layer") ?? "F.Fab").thickness
            let i = font.items.lastIndex { $0.head == "size" || $0.head == "line_spacing" || $0.head == "face" } ?? 0
            font.items.insert(SExpr("thickness", pen), at: i + 1)
        }
        let oldPlacement = BoardWorld.FootprintPlacement(existing), newPlacement = BoardWorld.FootprintPlacement(fp)
        let a = Context(fp: existing, placement: oldPlacement), b = Context(fp: fp, placement: newPlacement)

        // the pads, matched (a pad of the same number the likelier), given the old ones' ids, nets and pin functions
        let pads = matches(existing.all("pad"), fp.all("pad")) { o, n in
            let s = padSimilarity(o, a, n, b)
            return o.text(at: 0) == n.text(at: 0) ? s + 2 : s
        }
        var matchedPads = Set<ObjectIdentifier>()
        for (o, n) in pads {
            matchedPads.insert(ObjectIdentifier(n))
            n.set(SExpr("uuid", o.value("uuid") ?? KiCadBoard.newUUID()))
            for head in ["net", "pinfunction", "pintype"] { n.remove(head) }
            var extra: [SExpr] = []
            if isOnCopper(n), let net = o["net"] { extra.append(net.copy()) }
            for head in ["pinfunction", "pintype"] { if let x = o[head] { extra.append(x.copy()) } }
            if !extra.isEmpty {
                // (where format( PAD ) writes them: after the pad's shape's corners, before its die length)
                let i = n.items.lastIndex { padNetAfter.contains($0.head ?? "") } ?? n.items.count - 1
                n.items.insert(contentsOf: extra, at: i + 1)
            }
        }
        for n in fp.all("pad") where !matchedPads.contains(ObjectIdentifier(n)) {
            n.set(SExpr("uuid", KiCadBoard.newUUID()))
            n.remove("net")
        }
        // the drawings, zones, points and groups, matched, given the old ones' ids
        let drawingHeads = Set(BoardItems.footprintDrawings.keys)
        let oldDrawings = existing.items.filter { drawingHeads.contains($0.head ?? "") }
        let newDrawings = fp.items.filter { drawingHeads.contains($0.head ?? "") }
        let drawings = matches(oldDrawings, newDrawings) { drawingSimilarity($0, a, $1, b) }
        reassign(drawings, newDrawings)
        reassign(matches(existing.all("zone"), fp.all("zone")) { zoneSimilarity($0, $1) }, fp.all("zone"))
        reassign(matches(existing.all("point"), fp.all("point")) { pointSimilarity($0, $1) }, fp.all("point"))
        let groups = matches(existing.all("group"), fp.all("group")) { groupSimilarity($0, a, $1, b) }
        reassign(groups, fp.all("group"))
        // the fields (the reference and value aside), matched
        let userFields = { (n: SExpr) in n.all("property").filter { !["Reference", "Value"].contains($0.text(at: 0) ?? "") } }
        let fields = matches(userFields(existing), userFields(fp)) { fieldSimilarity($0, a, $1, b) }
        reassign(fields, userFields(fp))

        // the old texts: kept as the options say, or added where they have no match and are not to be deleted
        let textMatches = Dictionary(uniqueKeysWithValues: drawings.filter { $0.0.head == "fp_text" && $0.1.head == "fp_text" }
            .map { (ObjectIdentifier($0.0), $0.1) })
        for o in oldDrawings where o.head == "fp_text" {
            if let n = textMatches[ObjectIdentifier(o)] {
                processText(o, n, newFP: fp, resetText: options.resetTextContent, options)
            } else if !options.deleteExtraTexts {
                let i = fp.items.lastIndex { drawingHeads.contains($0.head ?? "") } ?? fp.items.count - 1
                fp.items.insert(o.copy(), at: i + 1)
            }
        }
        // the reference (its text always the old one's), the value (reset where it stood for the footprint's name)
        if let o = field(existing, "Reference"), let n = field(fp, "Reference") {
            processText(o, n, newFP: fp, resetText: false, options)
        }
        if let o = field(existing, "Value"), let n = field(fp, "Value") {
            let name = KiCadFootprintLibrary.split(old.libID)?.name ?? old.libID
            processText(o, n, newFP: fp, resetText: old.value == name, options)
        }
        let fieldMatches = Dictionary(uniqueKeysWithValues: fields.map { (ObjectIdentifier($0.0), $0.1) })
        for o in userFields(existing) {
            if let n = fieldMatches[ObjectIdentifier(o)] {
                processText(o, n, newFP: fp, resetText: options.resetTextContent, options)
            } else if !options.deleteExtraTexts {
                let i = fp.items.lastIndex { $0.head == "property" } ?? 2
                fp.items.insert(o.copy(), at: i + 1)
            }
        }
        // the fabrication attributes, clearance overrides and models
        if !options.resetFabricationAttrs {
            let flags: Set<String> = ["smd", "through_hole", "board_only", "exclude_from_pos_files", "exclude_from_bom", "dnp"]
            var attributes = view.attributes.subtracting(flags)
            attributes.formUnion(old.attributes.intersection(flags))
            view.attributes = attributes
        }
        if !options.resetClearanceOverrides {
            for head in ["solder_mask_margin", "solder_paste_margin", "solder_paste_margin_ratio", "clearance", "zone_connect"] {
                fp.remove(head)
                if let x = existing[head] { fp.insert(x.copy(), after: ["sheetfile", "sheetname", "path", "property", "units"] + FootprintFormat.headerOrder.prefix { $0 != head }) }
            }
            var attributes = view.attributes
            if old.attributes.contains("allow_soldermask_bridges") { attributes.insert("allow_soldermask_bridges") } else { attributes.remove("allow_soldermask_bridges") }
            view.attributes = attributes
        }
        if !options.reset3DModels {
            fp.remove("model")
            fp.items += existing.all("model").map { $0.copy() }
        }
        // its link to its symbol, its sheet, its filters and its component class
        for head in ["path", "sheetname", "sheetfile", "component_classes"] {
            fp.remove(head)
            if let x = existing[head] { fp.insert(x.copy(), after: ["property", "path", "sheetname"]) }
        }
        fp.items.removeAll { $0.head == "property" && $0.text(at: 0) == "ki_fp_filters" }
        if let filters = field(existing, "ki_fp_filters") { fp.insert(filters.copy(), after: ["property"]) }
        // (BOARD_COMMIT: the new one in the old one's place, written as KiCad writes a footprint)
        let formatted = FootprintFormat.formatted(fp, library: false)
        existing.items = formatted.items
    }

    /// The heads a pad's net follows in format( PAD )
    static let padNetAfter: Set<String> = ["at", "size", "rect_delta", "drill", "backdrill", "tertiary_drill",
                                           "front_post_machining", "back_post_machining", "property", "layers",
                                           "remove_unused_layers", "keep_end_layers", "zone_layer_connections",
                                           "roundrect_rratio", "chamfer_ratio", "chamfer"]

    static func field(_ fp: SExpr, _ name: String) -> SExpr? { fp.all("property").first { $0.text(at: 0) == name } }

    static func isOnCopper(_ pad: SExpr) -> Bool {
        (pad["layers"]?.arguments ?? []).contains { $0.text.hasSuffix(".Cu") }
    }

    /// Each new item matched given the id of the old item it was matched to; the others new ids (ResetUuid)
    static func reassign(_ pairs: [(SExpr, SExpr)], _ all: [SExpr]) {
        var matched = Set<ObjectIdentifier>()
        for (o, n) in pairs {
            matched.insert(ObjectIdentifier(n))
            if let id = o.value("uuid") { n.set(SExpr("uuid", id)) }
        }
        for n in all where !matched.contains(ObjectIdentifier(n)) { n.set(SExpr("uuid", KiCadBoard.newUUID())) }
    }

    /// matchItemsBySimilarity: every pair of old and new items of the same kind whose similarity is above 0, the most
    /// similar first (ties: by the old item, then the new, in the order the footprints hold them, which stands for
    /// the order of their addresses KiCad goes by), each item matched once
    static func matches(_ old: [SExpr], _ new: [SExpr], _ similarity: (SExpr, SExpr) -> Double) -> [(SExpr, SExpr)] {
        var candidates: [(i: Int, j: Int, score: Double)] = []
        for (i, o) in old.enumerated() {
            for (j, n) in new.enumerated() where kind(o) == kind(n) {
                let s = similarity(o, n)
                if s > 0 { candidates.append((i, j, s)) }
            }
        }
        candidates.sort { $0.score != $1.score ? $0.score > $1.score : $0.i != $1.i ? $0.i < $1.i : $0.j < $1.j }
        var usedOld = Set<Int>(), usedNew = Set<Int>()
        var out: [(SExpr, SExpr)] = []
        for c in candidates where !usedOld.contains(c.i) && !usedNew.contains(c.j) {
            usedOld.insert(c.i)
            usedNew.insert(c.j)
            out.append((old[c.i], new[c.j]))
        }
        return out
    }

    /// An item's KICAD_T as Similarity tells kinds apart (a footprint's shapes all PCB_SHAPE_T)
    static func kind(_ node: SExpr) -> String {
        let head = node.head ?? ""
        return BoardWorld.footprintShapeHeads.contains(head) ? "shape" : head
    }

    // MARK: - Similarity

    /// Where the items of a footprint are on the board
    struct Context {
        let fp: SExpr
        let placement: BoardWorld.FootprintPlacement
        func board(_ list: SExpr?) -> IPoint { placement.apply(BoardWorld.point(list)) }
    }

    static func text(_ node: SExpr?) -> String { node?.compact ?? "" }

    /// PAD::Similarity: 0.9 for each of its place, its attribute, then PADSTACK::Similarity's (its mode, layers,
    /// angle, mask and paste margins, unconnected layers, custom shape's zone mode, holes and back drills) different;
    /// then its copper's (COPPER_LAYER_PROPS::Similarity): 0.5 for a different shape, 0.9 for each of its zone
    /// connection, spokes and gap, clearance, 0.5 for custom shapes (which KiCad compares by address: never the same)
    static func padSimilarity(_ o: SExpr, _ a: Context, _ n: SExpr, _ b: Context) -> Double {
        var s = 1.0
        if a.board(o["at"]) != b.board(n["at"]) { s *= 0.9 }
        if o.text(at: 1) != n.text(at: 1) { s *= 0.9 }
        // (PADSTACK::Similarity)
        if (o["padstack"]?["mode"]?.text(at: 0) ?? "") != (n["padstack"]?["mode"]?.text(at: 0) ?? "") { s *= 0.9 }
        if text(o["layers"]) != text(n["layers"]) { s *= 0.9 }
        if (o["at"]?.number(at: 2) ?? 0) != (n["at"]?.number(at: 2) ?? 0) { s *= 0.9 }
        let mask = ["solder_mask_margin", "solder_paste_margin", "solder_paste_margin_ratio", "tenting"]
        if mask.map({ text(o[$0]) }) != mask.map({ text(n[$0]) }) { s *= 0.9 }
        if [text(o["remove_unused_layers"]), text(o["keep_end_layers"])] != [text(n["remove_unused_layers"]), text(n["keep_end_layers"])] { s *= 0.9 }
        if text(o["options"]?["clearance"]) != text(n["options"]?["clearance"]) { s *= 0.9 }
        func drill(_ p: SExpr) -> String { p["drill"].map { d in d.items.filter { $0.head != "offset" }.map(\.compact).joined(separator: " ") } ?? "" }
        if drill(o) != drill(n) { s *= 0.9 }
        for head in ["backdrill", "tertiary_drill", "front_post_machining", "back_post_machining"] where text(o[head]) != text(n[head]) { s *= 0.9 }
        // (the copper's, on its one layer)
        let shape = [o.text(at: 2), text(o["options"]?["anchor"]), text(o["size"]), text(o["drill"]?["offset"]),
                     text(o["roundrect_rratio"]), text(o["chamfer_ratio"]), text(o["chamfer"]), text(o["rect_delta"])]
        let other = [n.text(at: 2), text(n["options"]?["anchor"]), text(n["size"]), text(n["drill"]?["offset"]),
                     text(n["roundrect_rratio"]), text(n["chamfer_ratio"]), text(n["chamfer"]), text(n["rect_delta"])]
        if shape != other { s *= 0.5 }
        for head in ["zone_connect", "thermal_bridge_width", "thermal_bridge_angle", "thermal_gap", "clearance"] where text(o[head]) != text(n[head]) {
            s *= 0.9
        }
        if o["primitives"] != nil || n["primitives"] != nil { s *= 0.5 }
        return s
    }

    /// EDA_SHAPE's kind of a footprint's shape
    static let shapeKinds = ["fp_line": 1, "fp_rect": 2, "fp_arc": 3, "fp_circle": 4, "fp_poly": 5, "fp_curve": 6]

    /// A drawing's similarity: a shape's (PCB_SHAPE::Similarity), a text's (PCB_TEXT::Similarity, EDA_TEXT's), a text
    /// box's, a dimension's or another's (the same or not: the port does not weigh their differences as KiCad does)
    static func drawingSimilarity(_ o: SExpr, _ a: Context, _ n: SExpr, _ b: Context) -> Double {
        let ho = o.head ?? "", hn = n.head ?? ""
        if shapeKinds[ho] != nil, shapeKinds[hn] != nil { return shapeSimilarity(o, a, n, b) }
        guard ho == hn else { return 0 }
        if ho == "fp_text" { return textSimilarity(o, a, n, b) }
        let strip = { (x: SExpr) -> String in let c = x.copy(); c.remove("uuid"); return c.compact }
        return strip(o) == strip(n) ? 1 : 0.5
    }

    /// PCB_SHAPE::Similarity: 0.9 for each of its layer, knockout, lock, net, solder mask and its margin different;
    /// then EDA_SHAPE::Similarity: none of another kind; 0.9 for each of its fill, width, line style, start, end, arc
    /// centre and Bézier controls different (on the board), and 0.9 for each corner of the longest run its polygon's
    /// steps from corner to corner do not share
    static func shapeSimilarity(_ o: SExpr, _ a: Context, _ n: SExpr, _ b: Context) -> Double {
        let ko = shapeKinds[o.head ?? ""], kn = shapeKinds[n.head ?? ""]
        var s = 1.0
        func layers(_ x: SExpr) -> String { x["layers"].map(text) ?? x.value("layer") ?? "" }
        if layers(o) != layers(n) { s *= 0.9 }
        func knockout(_ x: SExpr) -> Bool { x["layer"]?.arguments.contains { $0.kind == .symbol && $0.text == "knockout" } == true }
        if knockout(o) != knockout(n) { s *= 0.9 }
        if o.flag("locked") != n.flag("locked") { s *= 0.9 }
        if (o.value("net") ?? "") != (n.value("net") ?? "") { s *= 0.9 }
        func mask(_ x: SExpr) -> Bool { x["layers"]?.arguments.contains { $0.text.hasSuffix(".Mask") } == true }
        if mask(o) != mask(n) { s *= 0.9 }
        if text(o["solder_mask_margin"]) != text(n["solder_mask_margin"]) { s *= 0.9 }
        guard ko == kn else { return 0 }
        if text(o["fill"]) != text(n["fill"]) { s *= 0.9 }
        if text(o["stroke"]?["width"]) != text(n["stroke"]?["width"]) { s *= 0.9 }
        if text(o["stroke"]?["type"]) != text(n["stroke"]?["type"]) { s *= 0.9 }
        // (m_start, m_end, m_arcCenter, m_bezierC1, m_bezierC2, on the board: a circle's start its centre)
        func points(_ x: SExpr, _ c: Context) -> [IPoint?] {
            switch x.head ?? "" {
            case "fp_line", "fp_rect": return [c.board(x["start"]), c.board(x["end"]), nil, nil, nil]
            case "fp_circle": return [c.board(x["center"]), c.board(x["end"]), nil, nil, nil]
            case "fp_arc":
                let (st, md, en) = (c.board(x["start"]), c.board(x["mid"]), c.board(x["end"]))
                return [st, en, KiMath.arcCenter(st, md, en), nil, nil]
            case "fp_curve":
                let pts = x["pts"]?.items.filter { $0.head == "xy" }.map { c.board($0) } ?? []
                return pts.count == 4 ? [pts[0], pts[3], nil, pts[1], pts[2]] : [nil, nil, nil, nil, nil]
            default: return [nil, nil, nil, nil, nil]
            }
        }
        for (p, q) in zip(points(o, a), points(n, b)) where p != q { s *= 0.9 }
        // (the polygon's corners, each as the step from the one before)
        func steps(_ x: SExpr, _ c: Context) -> [IPoint] {
            guard x.head == "fp_poly" else { return [] }
            var last = IPoint(0, 0)
            return (x["pts"]?.items.filter { $0.head == "xy" } ?? []).map { xy in
                let p = c.board(xy)
                defer { last = p }
                return last - p
            }
        }
        let so = steps(o, a), sn = steps(n, b)
        s *= pow(0.9, Double(so.count + sn.count - 2 * longestCommonRun(so, sn)))
        return s
    }

    /// longest_common_subset: the length of the longest run the two share
    static func longestCommonRun<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        var longest = 0
        for i in 1...a.count {
            for j in 1...b.count where a[i - 1] == b[j - 1] {
                table[i][j] = table[i - 1][j - 1] + 1
                longest = max(longest, table[i][j])
            }
        }
        return longest
    }

    /// A text's attributes as TEXT_ATTRIBUTES::Compare compares them: its font, size, pen, style and justification
    /// (its effects as KiCad writes them), its angle and whether it is kept upright
    static func attributes(_ x: SExpr) -> [String] {
        let effects = x["effects"]?.copy()
        effects?.remove("hide")
        let upright = !(x.flag("unlocked") || x["at"]?.arguments.contains { $0.kind == .symbol && $0.text == "unlocked" } == true)
        return [effects?.compact ?? "", KiCadNumber.format(BoardItems.normalize360(x["at"]?.number(at: 2) ?? 0)), upright ? "1" : "0"]
    }

    /// The text of a field or a text
    static func textOf(_ x: SExpr) -> String { x.text(at: 1) ?? "" }

    /// EDA_TEXT::Similarity: 0.9 for different attributes, 0.9 for a different place (on the board), times the texts'
    /// Levenshtein similarity
    static func textSimilarity(_ o: SExpr, _ a: Context, _ n: SExpr, _ b: Context) -> Double {
        var s = 1.0
        if attributes(o) != attributes(n) { s *= 0.9 }
        if a.board(o["at"]) != b.board(n["at"]) { s *= 0.9 }
        return s * levenshtein(textOf(o), textOf(n))
    }

    /// EDA_TEXT::Levenshtein: 1 less the edit distance over the longer's length; none where either is empty
    static func levenshtein(_ a: String, _ b: String) -> Double {
        let s = Array(a.unicodeScalars), t = Array(b.unicodeScalars)
        guard !s.isEmpty, !t.isEmpty else { return 0 }
        var d = Array(repeating: Array(repeating: 0, count: t.count + 1), count: s.count + 1)
        for i in 0...s.count { d[i][0] = i }
        for j in 0...t.count { d[0][j] = j }
        for i in 1...s.count {
            for j in 1...t.count {
                d[i][j] = s[i - 1] == t[j - 1] ? d[i - 1][j - 1] : min(d[i - 1][j], d[i][j - 1], d[i - 1][j - 1]) + 1
            }
        }
        return 1 - Double(d[s.count][t.count]) / Double(max(s.count, t.count))
    }

    /// PCB_FIELD::Similarity: 1 for the same id; for a mandatory field, 1 for the same field else none; 1 for the
    /// same name; else EDA_TEXT's
    static func fieldSimilarity(_ o: SExpr, _ a: Context, _ n: SExpr, _ b: Context) -> Double {
        if let id = o.value("uuid"), id == n.value("uuid") { return 1 }
        let no = o.text(at: 0) ?? "", nn = n.text(at: 0) ?? ""
        if FootprintFormat.mandatory.contains(no) || FootprintFormat.mandatory.contains(nn) { return no == nn ? 1 : 0 }
        if no == nn { return 1 }
        return textSimilarity(o, a, n, b)
    }

    /// ZONE::Similarity: none between a rule area and a zone; 0.9 for each of its layers, net, and (a zone's)
    /// priority, minimum width, smoothing and radius, teardrop, or (a rule area's) each keepout different; then 0.9
    /// for each corner of the longest run its corners' steps do not share
    static func zoneSimilarity(_ o: SExpr, _ n: SExpr) -> Double {
        let ro = o["keepout"] != nil, rn = n["keepout"] != nil
        guard ro == rn else { return 0 }
        var s = 1.0
        func layers(_ x: SExpr) -> String { x["layers"].map(text) ?? x.value("layer") ?? "" }
        if layers(o) != layers(n) { s *= 0.9 }
        if (o.value("net") ?? "") != (n.value("net") ?? "") { s *= 0.9 }
        if !ro {
            for head in ["priority", "min_thickness"] where text(o[head]) != text(n[head]) { s *= 0.9 }
            if text(o["fill"]?["smoothing"]) != text(n["fill"]?["smoothing"]) { s *= 0.9 }
            if text(o["fill"]?["radius"]) != text(n["fill"]?["radius"]) { s *= 0.9 }
            if text(o["attr"]) != text(n["attr"]) { s *= 0.9 }
        } else {
            for head in ["copperpour", "tracks", "vias", "footprints", "pads"] where text(o["keepout"]?[head]) != text(n["keepout"]?[head]) {
                s *= 0.9
            }
        }
        func steps(_ x: SExpr) -> [IPoint] {
            var last = IPoint(0, 0)
            return x.all("polygon").flatMap { $0["pts"].map(FootprintFormat.outlinePoints) ?? [] }.map { p in
                defer { last = p }
                return last - p
            }
        }
        let so = steps(o), sn = steps(n)
        s *= pow(0.9, Double(so.count + sn.count - 2 * longestCommonRun(so, sn)))
        return s
    }

    /// PCB_POINT::Similarity: 0.9 for each of its place, size and layer different
    static func pointSimilarity(_ o: SExpr, _ n: SExpr) -> Double {
        var s = 1.0
        for head in ["at", "size", "layer"] where text(o[head]) != text(n[head]) { s *= 0.9 }
        return s
    }

    /// PCB_GROUP::Similarity: its members' similarities to the other's, every pair, over how many it has
    static func groupSimilarity(_ o: SExpr, _ a: Context, _ n: SExpr, _ b: Context) -> Double {
        func members(_ g: SExpr, _ c: Context) -> [SExpr] {
            let ids = Set(BoardItems.members(g))
            return c.fp.items.filter { ids.contains($0.value("uuid") ?? "") }
        }
        let mo = members(o, a), mn = members(n, b)
        guard !mo.isEmpty else { return 0 }
        var total = 0.0
        for x in mo {
            for y in mn {
                switch (kind(x), kind(y)) {
                case ("pad", "pad"): total += padSimilarity(x, a, y, b)
                case ("zone", "zone"): total += zoneSimilarity(x, y)
                case ("point", "point"): total += pointSimilarity(x, y)
                case ("group", "group"): total += groupSimilarity(x, a, y, b)
                case ("property", "property"): total += fieldSimilarity(x, a, y, b)
                default: total += drawingSimilarity(x, a, y, b)
                }
            }
        }
        return total / Double(mo.count)
    }

    // MARK: - Texts

    /// processTextItem: the new text `n` given the old one's `o` text (unless reset), layer and visibility (unless
    /// reset), style (unless reset: else kept upright), place on the footprint (unless reset), lock and id
    static func processText(_ o: SExpr, _ n: SExpr, newFP: SExpr, resetText: Bool, _ options: Options) {
        if !resetText { n.items[2] = SExpr(string: textOf(o)) }
        if !options.resetTextLayers {
            if let layer = o["layer"] { n.set(layer.copy()) }
            if n.head == "property" {
                n.remove("hide")
                if o.flag("hide") {
                    let i = n.items.lastIndex { $0.head == "layer" } ?? n.items.count - 1
                    n.items.insert(SExpr("hide", Keyword("yes")), at: i + 1)
                }
            }
        }
        var origin: [Double] = [0, 0]
        if let at = n["at"] { origin = [at.number(at: 0) ?? 0, at.number(at: 1) ?? 0] }
        if options.resetTextEffects {
            BoardEditing.keepUpright(SExpr(list: [SExpr(symbol: "footprint"), n]))
        } else {
            // (SetAttributes: its effects, angle and whether it is kept upright; SetIsKnockout)
            if let effects = o["effects"] { n.set(effects.copy()) }
            let angle = o["at"]?.number(at: 2) ?? 0
            if let at = n["at"] { at.items = Array(at.items.prefix(3)) + [angle.sexpr] }
            n.remove("unlocked")
            let unlocked = o.flag("unlocked")
            if unlocked, let i = n.items.firstIndex(where: { $0.head == "at" }) { n.items.insert(SExpr("unlocked", Keyword("yes")), at: i + 1) }
            let knockout = o["layer"]?.arguments.contains { $0.kind == .symbol && $0.text == "knockout" } == true
            if let layer = n["layer"] {
                layer.items.removeAll { $0.kind == .symbol && $0.text == "knockout" }
                if knockout { layer.items.append(SExpr(symbol: "knockout")) }
            }
        }
        var place: [Double] = origin
        if !options.resetTextPositions, let at = o["at"] { place = [at.number(at: 0) ?? 0, at.number(at: 1) ?? 0] }
        if let at = n["at"] { at.items[1] = place[0].sexpr; at.items[2] = place[1].sexpr }
        n.remove("locked")
        if o.flag("locked"), n.head == "fp_text" { n.items.insert(SExpr("locked", Keyword("yes")), at: 3) }
        if let id = o.value("uuid") { n.set(SExpr("uuid", id)) }
    }

    /// Every item of the footprint (and the footprint) given a new id, its groups' members following theirs; the old
    /// ids by the new
    @discardableResult
    static func renewIDs(_ fp: SExpr) -> [String: String] {
        var ids: [String: String] = [:], renamed: [String: String] = [:]
        for item in [fp] + fp.items where item.kind == .list && item["uuid"] != nil {
            let old = item.value("uuid") ?? ""
            let new = KiCadBoard.newUUID()
            item.set(SExpr("uuid", new))
            ids[new] = old
            renamed[old] = new
        }
        for group in fp.all("group") {
            guard let members = group["members"] else { continue }
            for i in 1..<members.items.count { members.items[i] = SExpr(string: renamed[members.items[i].text] ?? members.items[i].text) }
        }
        return ids
    }

    // MARK: - Updating from the library

    /// What Update Footprints from Library did to each footprint, as its dialog reports it
    public struct Report: Sendable, Equatable {
        public var lines: [String] = []
    }

    /// The board's footprints that `match` picks updated from their libraries, as DIALOG_EXCHANGE_FOOTPRINTS' update
    /// mode updates them (processMatchingFootprints: from the last footprint to the first): each loaded from its
    /// library as the PCB editor loads one (a copy of new ids, on no net: loadFootprint) and exchanged for the
    /// board's (ExchangeFootprint with `options`); one whose library footprint is not found reported and left
    public static func updateFromLibrary(_ board: KiCadBoard, library: KiCadFootprintSource, options: Options = .updateDialog,
                                         flipLeftRight: Bool = false, match: (KiCadFootprint) -> Bool = { _ in true }) -> Report {
        var report = Report()
        for node in board.root.all("footprint").reversed() {
            let fp = KiCadFootprint(node, board: board)
            guard match(fp) else { continue }
            var msg = "Updated footprint \(fp.reference) (\(fp.libID)): "
            guard let lib = try? library.footprint(fp.libID) else {
                msg += "*** library footprint not found ***"
                report.lines.append(msg)
                continue
            }
            // ("no changes" where the exchange left the footprint as it was, its new items' ids aside: the port's
            // stand-in for FOOTPRINT::FootprintNeedsUpdate, which it does not weigh as KiCad does)
            let before = withoutIDs(node)
            exchange(node, for: loaded(lib, libID: fp.libID), on: board, options: options, flipLeftRight: flipLeftRight)
            report.lines.append(msg + (withoutIDs(node) == before ? ": (no changes)" : ": OK"))
        }
        return report
    }

    /// A footprint's text without its items' ids
    static func withoutIDs(_ node: SExpr) -> String {
        let copy = node.copy()
        copy.walk { $0.items.removeAll { $0.head == "uuid" } }
        return copy.compact
    }

    /// PCB_BASE_FRAME::loadFootprint in the PCB editor: the library's footprint, a copy of it every item of which
    /// has a new id (FOOTPRINT::Duplicate), named by its library and name, on no net
    public static func loaded(_ node: SExpr, libID: String) -> SExpr {
        let fp = node.copy()
        fp.items[1] = SExpr(string: libID)
        renewIDs(fp)
        let out = FootprintFormat.formatted(fp, library: false, sorted: false)
        FootprintEditor.clearNets(out)
        return out
    }
}
