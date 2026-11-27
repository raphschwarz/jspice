// The footprint editor's checks, as KiCad 10.0.8's footprint checker runs them (pcbnew/dialogs/
// dialog_footprint_checker.cpp, DIALOG_FOOTPRINT_CHECKER::runChecks: BuildCourtyardCaches' malformed courtyards, a
// missing courtyard, then pcbnew/footprint.cpp's FOOTPRINT::CheckFootprintAttributes with GetLikelyAttribute and
// GetTypeName, CheckPads with pcbnew/pad.cpp's PAD::CheckPad and doCheckPad, CheckShortingPads with GetNetTiePads and
// MapPadNumbersToNetTieGroups, CheckNetTiePadGroups and CheckNetTies). Copyright The KiCad Developers, see KiCad's
// AUTHORS.txt. GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// What the footprint checker finds of a footprint
public enum FootprintChecks {
    /// One of its markers: the check's key (DRC_ITEM's, as KiCad's reports name it), what KiCad says of it (the
    /// error's detail, "" for none), the items it is about (their ids, in KiCad's order)
    public struct Violation: Hashable, Sendable {
        public var type: String
        public var detail: String
        public var items: [String]

        public init(type: String, detail: String = "", items: [String]) {
            (self.type, self.detail, self.items) = (type, detail, items)
        }
    }

    /// The checks' titles (DRC_ITEM's error texts)
    public static let titles: [String: String] = [
        "malformed_courtyard": "Footprint has malformed courtyard", "missing_courtyard": "Footprint has no courtyard defined",
        "footprint_type_mismatch": "Footprint component type doesn't match footprint pads",
        "pad_th_with_no_hole": "Through hole pad has no hole", "padstack": "Pad is not properly defined",
        "padstack_invalid": "Invalid padstack", "holes_co_located": "Drilled holes co-located",
        "hole_to_hole": "Drilled hole too close to other hole", "shorting_items": "Items shorting two nets",
        "footprint": "Footprint is not valid",
    ]

    /// DIALOG_FOOTPRINT_CHECKER::runChecks of the footprint editor's footprint (or of a board's: the first one of
    /// `board`): its markers in the order the checker adds them
    public static func run(_ board: KiCadBoard) -> [Violation] {
        guard let fp = board.root.all("footprint").first else { return [] }
        let drc = BoardDRC(board: board)
        let uuid = fp.value("uuid") ?? ""
        var out: [Violation] = []
        // BuildCourtyardCaches: its complaints, each a malformed courtyard; none at all a missing one
        var messages: [String] = []
        let yards = drc.world.courtyards(fp) { messages.append($0) }
        if yards.malformedFront || yards.malformedBack {
            for m in messages { out.append(Violation(type: "malformed_courtyard", detail: m, items: [uuid])) }
        }
        let attributes = Set(fp["attr"]?.arguments.map(\.text) ?? [])
        if !attributes.contains("allow_missing_courtyard") && yards.front.polygons.isEmpty && yards.back.polygons.isEmpty {
            out.append(Violation(type: "missing_courtyard", items: [uuid]))
        }
        if let msg = attributesProblem(fp) { out.append(Violation(type: "footprint_type_mismatch", detail: msg, items: [uuid])) }
        let pads = drc.footprints.first?.pads ?? []
        for (node, pad) in zip(fp.all("pad"), pads) {
            for (type, msg) in checkPad(node, pad.pad, pad.primitives, drc.world) {
                out.append(Violation(type: type, detail: msg, items: [node.value("uuid") ?? ""]))
            }
        }
        out += shortingPads(fp, drc)
        if isNetTie(fp) {
            for msg in netTiePadGroupsProblems(fp) { out.append(Violation(type: "footprint", detail: msg, items: [uuid])) }
            var report = BoardDRC.Report(settings: drc.settings, limited: false)
            drc.checkNetTies(&report, drc.makeCopper())
            out += report.violations.map { Violation(type: $0.type, detail: "", items: $0.items) }
        }
        return out
    }

    /// FOOTPRINT::IsNetTie: it has net tie pad groups
    static func isNetTie(_ fp: SExpr) -> Bool { !(fp["net_tie_pad_groups"]?.arguments.isEmpty ?? true) }

    // MARK: - Attributes

    /// The pad's fabrication property (PAD_PROP), as its file names it
    static func property(_ pad: SExpr) -> String { pad["property"]?.text(at: 0) ?? "" }

    /// FOOTPRINT::CheckFootprintAttributes: the mounting its pads suggest (GetLikelyAttribute: through hole where it
    /// has a plated hole, else SMD where it has an SMD pad on copper; fiducials, heatsinks, castellated and mechanical
    /// pads aside) not the one it is set to
    static func attributesProblem(_ fp: SExpr) -> String? {
        var smd = 0, tht = 0
        for pad in fp.all("pad") {
            if ["pad_prop_fiducial_glob", "pad_prop_fiducial_loc", "pad_prop_heatsink", "pad_prop_castellated",
                "pad_prop_mechanical"].contains(property(pad)) { continue }
            switch pad.text(at: 1) ?? "" {
            case "thru_hole": tht += 1
            case "smd": if FootprintExchange.isOnCopper(pad) { smd += 1 }
            default: break
            }
        }
        let likely = tht > 0 ? "through_hole" : smd > 0 ? "smd" : nil
        let attributes = fp["attr"]?.arguments.map(\.text) ?? []
        let set = attributes.contains("smd") ? "smd" : attributes.contains("through_hole") ? "through_hole" : nil
        guard let likely, let set, likely != set else { return nil }
        let typeName = set == "smd" ? "SMD" : "Through hole"
        return likely == "through_hole" ? "(expected 'Through hole'; actual '\(typeName)')" : "(expected 'SMD'; actual '\(typeName)')"
    }

    // MARK: - Pads

    /// PAD::CheckPad (not for the pad properties dialog): its one shape's checks (doCheckPad), then its layers', its
    /// fabrication property's and its attribute's: each problem's key and what KiCad says of it
    static func checkPad(_ node: SExpr, _ p: BoardWorld.Pad, _ primitives: [SExpr], _ world: BoardWorld) -> [(String, String)] {
        var out: [(String, String)] = []
        func error(_ type: String, _ msg: String) { out.append((type, msg)) }
        let layers = Set(BoardEditing.padLayers(node))
        let onCopper = !world.copper(p.layers).isEmpty && world.isOnCopper(p, world.copper(p.layers))
        // (doCheckPad, on its one layer)
        var size = p.size
        if p.kind == .custom {
            if let poly = world.padPolygon(p, primitives: primitives, errorLocation: .inside) {
                var box: IBox?
                for polygon in poly.polygons {
                    for q in polygon.first?.points ?? [] {
                        if box == nil { box = IBox(minX: q.x, minY: q.y, maxX: q.x, maxY: q.y) } else { box?.merge(q) }
                    }
                }
                if let box { size = IPoint(box.maxX - box.minX, box.maxY - box.minY) }
            }
        } else if p.size.x <= 0 || (p.size.y <= 0 && p.kind != .circle) {
            error("padstack_invalid", "(Pad must have a positive size)")
        }
        if onCopper && p.drill.x > 0 {
            if p.drill.x <= 4 || p.drill.y <= 4 {
                error("padstack_invalid", "(PTH pad hole size must be larger than \(BoardDRC.stringFromValue(4)))")
            }
            let outline = world.padPolygon(p, primitives: primitives, errorLocation: .inside) ?? PolySet()
            if p.attribute == .pth {
                guard case let .segment(seg, width) = world.holeShape(p) else { return out }
                var copper = outline
                copper.booleanSubtract(PadPolygon.oval(start: seg.a, end: seg.b, width: width, maxError: world.rules.maxError, errorLocation: .outside))
                if copper.polygons.isEmpty { error("padstack", "(PTH pad hole leaves no copper)") }
            } else if !outline.pointInside(p.pos) {
                error("padstack", "(pad hole not inside pad shape)")
            }
        }
        func iu(_ head: String) -> Int? { node[head].map { BoardWorld.iu($0, 0) } }
        if (iu("clearance") ?? 0) < 0 { error("padstack", "(negative local clearance values have no effect)") }
        if let margin = iu("solder_mask_margin"), margin < 0 {
            let absMargin = abs(margin)
            if p.kind == .custom {
                for prim in primitives {
                    guard let d = world.readDrawing(prim, placement: nil), let shapes = world.effectiveShapes(d), var box = shapes.first?.bbox else { continue }
                    for s in shapes { box.merge(s.bbox) }
                    if absMargin > box.maxX - box.minX || absMargin > box.maxY - box.minY {
                        error("padstack", "(negative solder mask clearance is larger than some shape primitives; results may be surprising)")
                        break
                    }
                }
            } else if absMargin > size.x || absMargin > size.y {
                error("padstack", "(negative solder mask clearance is larger than pad; no solder mask will be generated)")
            }
        }
        let pasteMargin = iu("solder_paste_margin") ?? 0
        let ratio = node["solder_paste_margin_ratio"]?.number(at: 0) ?? 0
        let paste = IPoint(size.x + pasteMargin + KiMath.round(Double(size.x) * ratio), size.y + pasteMargin + KiMath.round(Double(size.y) * ratio))
        if paste.x <= 0 || paste.y <= 0 {
            error("padstack", "(negative solder paste margin is larger than pad; no solder paste mask will be generated)")
        }
        switch p.kind {
        case .roundrect:
            if p.roundRatio < 0 { error("padstack_invalid", "(negative corner radius is not allowed)") }
            else if p.roundRatio > 50 { error("padstack", "(corner size will make pad circular)") }
        case .chamferedRect:
            if p.chamferRatio < 0 { error("padstack_invalid", "(negative corner chamfer is not allowed)") }
            else if p.chamferRatio > 50 { error("padstack_invalid", "(corner chamfer is too large)") }
        case .trapezoid:
            let d = p.delta, s = p.size
            if (d.x < 0 && d.x < -s.y) || (d.x > 0 && d.x > s.y) || (d.y < 0 && d.y < -s.x) || (d.y > 0 && d.y > s.x) {
                error("padstack_invalid", "(trapezoid delta is too large)")
            }
        case .custom:
            if let poly = world.padPolygon(p, primitives: primitives, errorLocation: .inside), poly.outlineCount > 1 {
                error("padstack_invalid", "(custom pad shape must resolve to a single polygon)")
            }
        default:
            break
        }
        // (CheckPad: its layers, its fabrication property, its attribute)
        let drill = p.drill
        if !layers.contains("F.Cu") && !layers.contains("B.Cu") && !layers.contains("*.Cu") {
            if (drill.x != 0 || drill.y != 0) && p.attribute != .npth {
                error("padstack", "(plated through holes normally have a copper pad on at least one outer layer)")
            }
        }
        let prop = property(node)
        if (prop == "pad_prop_fiducial_glob" || prop == "pad_prop_fiducial_loc") && p.attribute == .npth {
            error("padstack", "('fiducial' pads are normally plated)")
        }
        if prop == "pad_prop_testpoint" && p.attribute == .npth { error("padstack", "('testpoint' pads are normally plated)") }
        if prop == "pad_prop_heatsink" && p.attribute == .npth { error("padstack", "('heatsink' pads are normally plated)") }
        if prop == "pad_prop_castellated" && p.attribute != .pth { error("padstack", "('castellated' pads are normally PTH)") }
        if prop == "pad_prop_bga" && p.attribute != .smd { error("padstack", "('BGA' property is for SMD pads)") }
        if prop == "pad_prop_mechanical" && p.attribute != .pth { error("padstack", "('mechanical' pads are normally PTH)") }
        if prop == "pad_prop_pressfit" && (p.attribute != .pth || !(drill.x > 0 && drill.y > 0 && drill.x == drill.y)) {
            error("padstack", "('press-fit' pads are normally PTH with round holes)")
        }
        let on = { (l: String) in layers.contains(l) || (l.hasSuffix(".Cu") && layers.contains("*.Cu")) }
        switch p.attribute {
        case .npth, .pth:
            if drill.x <= 0 || (drill.y <= 0 && p.oblong) { error("pad_th_with_no_hole", "") }
        case .conn, .smd:
            if p.attribute == .conn && (on("F.Paste") || on("B.Paste")) {
                error("padstack", "(connector pads normally have no solder paste; use a SMD pad instead)")
            }
            if drill.x > 0 || drill.y > 0 { error("padstack_invalid", "(SMD pad has a hole)") }
            let inner = layers.contains { $0.hasPrefix("In") && $0.hasSuffix(".Cu") }
            if on("F.Cu") && on("B.Cu") {
                error("padstack", "(SMD pad has copper on both sides of the board)")
            } else if on("F.Cu") {
                if on("B.Mask") { error("padstack", "(SMD pad has copper and mask layers on different sides of the board)") }
                else if on("B.Paste") { error("padstack", "(SMD pad has copper and paste layers on different sides of the board)") }
            } else if on("B.Cu") {
                if on("F.Mask") { error("padstack", "(SMD pad has copper and mask layers on different sides of the board)") }
                else if on("F.Paste") { error("padstack", "(SMD pad has copper and paste layers on different sides of the board)") }
            } else if inner {
                error("padstack", "(SMD pad has no outer layers)")
            }
        }
        return out
    }

    // MARK: - Shorting pads

    /// FOOTPRINT::MapPadNumbersToNetTieGroups: each pad number's group (-1 for none), its groups' numbers split at
    /// commas (a backslash escaping the next character), trimmed
    static func netTieGroups(_ fp: SExpr) -> [String: Int] {
        var map: [String: Int] = [:]
        for pad in fp.all("pad") { map[pad.text(at: 0) ?? ""] = -1 }
        for (i, group) in (fp["net_tie_pad_groups"]?.arguments ?? []).enumerated() {
            var esc = false, pad = ""
            func process() {
                let t = pad.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { map[t] = i }
            }
            for ch in group.text {
                if esc { esc = false; pad.append(ch); continue }
                switch ch {
                case "\\": esc = true
                case ",": process(); pad = ""
                default: pad.append(ch)
                }
            }
            process()
        }
        return map
    }

    /// FOOTPRINT::CheckNetTiePadGroups: a pad number a group names that no pad has, or one in more than one group
    static func netTiePadGroupsProblems(_ fp: SExpr) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        let numbers = Set(fp.all("pad").compactMap { $0.text(at: 0) })
        for (number, _) in netTieGroups(fp).sorted(by: { $0.key < $1.key }) {
            if !numbers.contains(number) {
                out.append("(net-tie pad group contains unknown pad number \(number))")
            } else if !seen.insert(number).inserted {
                out.append("(pad \(number) appears in more than one net-tie pad group)")
            }
        }
        return out
    }

    /// FOOTPRINT::CheckShortingPads: each pair of its pads once, in the order the footprint holds them: two drilled
    /// round holes at the same place, or touching; then, but for two pads of one number or of one net tie group, two
    /// pads on a copper layer both are on whose boxes meet and whose shapes touch
    static func shortingPads(_ fp: SExpr, _ drc: BoardDRC) -> [Violation] {
        let copper = drc.makeCopper()
        let items = copper.footprintPads.first ?? []
        let nodes = fp.all("pad")
        let groups = netTieGroups(fp)
        var out: [Violation] = []
        func drilled(_ p: BoardWorld.Pad) -> Bool { p.drill.x > 0 && p.drill.y > 0 && p.drill.x == p.drill.y }
        for i in items.indices {
            for j in items.indices where j > i {
                let a = items[i], b = items[j]
                guard let pa = a.pad?.pad, let pb = b.pad?.pad else { continue }
                let ida = nodes[i].value("uuid") ?? "", idb = nodes[j].value("uuid") ?? ""
                if drilled(pa) && drilled(pb) {
                    if pa.pos == pb.pos {
                        out.append(Violation(type: "holes_co_located", items: [ida, idb]))
                    } else if let ha = a.hole, let hb = b.hole, case let .segment(seg, _) = hb, ha.collide(.segment(seg, width: 0), clearance: 0) {
                        out.append(Violation(type: "hole_to_hole", items: [ida, idb]))
                    }
                }
                let na = nodes[i].text(at: 0) ?? "", nb = nodes[j].text(at: 0) ?? ""
                if !na.isEmpty && na == nb { continue }
                if let g = groups[na], g >= 0, groups[nb] == g { continue }
                let la = Set(drc.world.copper(pa.layers)), lb = Set(drc.world.copper(pb.layers))
                guard !la.isDisjoint(with: lb) else { continue }
                guard a.bbox.intersects(b.bbox) else { continue }
                let shapesA = a.outline, shapesB = b.outline
                if shapesA.contains(where: { s in shapesB.contains { s.collide($0, clearance: 0) } }) {
                    out.append(Violation(type: "shorting_items", items: [ida, idb]))
                }
            }
        }
        return out
    }
}
