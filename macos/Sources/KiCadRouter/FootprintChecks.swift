// The footprint editor's checks, as KiCad 10.0.8's footprint checker runs and reports them (pcbnew/dialogs/
// dialog_footprint_checker.cpp, DIALOG_FOOTPRINT_CHECKER::runChecks: BuildCourtyardCaches' malformed courtyards, a
// missing courtyard, then pcbnew/footprint.cpp's FOOTPRINT::CheckFootprintAttributes with GetLikelyAttribute and
// GetTypeName, CheckPads with pcbnew/pad.cpp's PAD::CheckPad and doCheckPad, CheckShortingPads with GetNetTiePads,
// MapPadNumbersToNetTieGroups, pcbnew/pad.cpp's PAD::GetEffectiveShape, FlashLayer and GetBoundingBox and
// pcbnew/padstack.cpp's RelevantShapeLayers, CheckNetTiePadGroups, CheckNetTies and CheckClippedSilk; its markers
// listed as pcbnew/drc/drc_item.cpp's DRC_ITEMS_PROVIDER::SetSeverities lists them, of the severities pcbnew/
// board_design_settings.cpp's BOARD_DESIGN_SETTINGS gives them, worded as common/rc_item.cpp's
// RC_TREE_MODEL::GetValue words them). Copyright The KiCad Developers, see KiCad's AUTHORS.txt. GNU General Public
// License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// What the footprint checker finds of a footprint
public enum FootprintChecks {
    /// One of its markers: the check's key (DRC_ITEM's settings key, as KiCad's reports name it), what KiCad says of
    /// it (the error's detail, "" for none), the items it is about (their ids, in KiCad's order) and where its marker
    /// is put
    public struct Violation: Hashable, Sendable {
        public var type: String
        public var detail: String
        public var items: [String]
        public var position: IPoint

        public init(type: String, detail: String = "", items: [String], position: IPoint = .zero) {
            (self.type, self.detail, self.items, self.position) = (type, detail, items, position)
        }
    }

    /// The checks' titles (DRC_ITEM's error texts)
    public static let titles: [String: String] = [
        "malformed_courtyard": "Footprint has malformed courtyard", "missing_courtyard": "Footprint has no courtyard defined",
        "footprint_type_mismatch": "Footprint component type doesn't match footprint pads",
        "through_hole_pad_without_hole": "Through hole pad has no hole", "padstack": "Padstack is questionable",
        "padstack_invalid": "Padstack is not valid", "holes_co_located": "Drilled holes co-located",
        "hole_to_hole": "Drilled hole too close to other hole", "shorting_items": "Items shorting two nets",
        "footprint": "Footprint is not valid", "silk_over_copper": "Silkscreen clipped by solder mask",
    ]

    /// The severity the footprint editor gives a check (its BOARD_DESIGN_SETTINGS', KiCad's defaults, which the
    /// footprint editor's settings keep none of their own of): "error", "warning" or "ignore"
    public static func severity(_ type: String) -> String {
        switch type {
        case "holes_co_located", "hole_to_hole", "padstack", "silk_over_copper": return "warning"
        case "missing_courtyard", "footprint_type_mismatch": return "ignore"
        default: return "error"
        }
    }

    /// A marker as the checker's dialog lists it: its severity and its line
    public struct Listed: Hashable, Sendable {
        public var violation: Violation
        public var severity: String
        /// "Error: " or "Warning: ", the check's title, then its detail (RC_TREE_MODEL::GetValue of the marker)
        public var text: String
    }

    /// The markers as the dialog lists them with its errors and warnings shown (DRC_ITEMS_PROVIDER::SetSeverities):
    /// the ignored left out, errors before warnings, each kept in the order the checks found them
    public static func reported(_ violations: [Violation], errors: Bool = true, warnings: Bool = true) -> [Listed] {
        let listed = violations.compactMap { v -> Listed? in
            let s = severity(v.type)
            guard (s == "error" && errors) || (s == "warning" && warnings) else { return nil }
            let title = titles[v.type] ?? v.type
            return Listed(violation: v, severity: s,
                          text: (s == "error" ? "Error: " : "Warning: ") + title + (v.detail.isEmpty ? "" : " " + v.detail))
        }
        return listed.filter { $0.severity == "error" } + listed.filter { $0.severity == "warning" }
    }

    /// DIALOG_FOOTPRINT_CHECKER::runChecks of the footprint editor's footprint (or of a board's: the first one of
    /// `board`): its markers in the order the checker adds them
    public static func run(_ board: KiCadBoard) -> [Violation] {
        guard let fp = board.root.all("footprint").first else { return [] }
        let drc = BoardDRC(board: board)
        let uuid = fp.value("uuid") ?? ""
        var out: [Violation] = []
        // BuildCourtyardCaches: each of its complaints a malformed courtyard, about the drawings it names (the one
        // first, where it names one alone); none at all a missing one
        let yards = drc.world.courtyards(fp) { message, a, b, at in
            out.append(Violation(type: "malformed_courtyard", detail: message, items: [a ?? b, a == nil ? nil : b].compactMap { $0 },
                                 position: at))
        }
        let attributes = Set(fp["attr"]?.arguments.map(\.text) ?? [])
        if !attributes.contains("allow_missing_courtyard") && yards.front.polygons.isEmpty && yards.back.polygons.isEmpty {
            out.append(Violation(type: "missing_courtyard", items: [uuid]))
        }
        if let msg = attributesProblem(fp) { out.append(Violation(type: "footprint_type_mismatch", detail: msg, items: [uuid])) }
        let pads = drc.footprints.first?.pads ?? []
        for (node, pad) in zip(fp.all("pad"), pads) {
            for (type, msg) in checkPad(node, pad.pad, pad.primitives, drc.world) {
                out.append(Violation(type: type, detail: msg, items: [node.value("uuid") ?? ""], position: pad.pad.pos))
            }
        }
        let copper = drc.makeCopper()
        out += shortingPads(fp, drc, copper)
        if isNetTie(fp) {
            for msg in netTiePadGroupsProblems(fp) { out.append(Violation(type: "footprint", detail: msg, items: [uuid])) }
            for short in drc.netTieShorts(0, copper) { out.append(Violation(type: "shorting_items", items: short.items, position: short.at)) }
        }
        out += clippedSilk(drc, copper)
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
            if drill.x <= 0 || (drill.y <= 0 && p.oblong) { error("through_hole_pad_without_hole", "") }
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
    /// commas (a backslash escaping the next character), trimmed of white space (wxString::Trim's, ASCII's alone)
    static func netTieGroups(_ fp: SExpr) -> [String: Int] {
        var map: [String: Int] = [:]
        for pad in fp.all("pad") { map[pad.text(at: 0) ?? ""] = -1 }
        let space = CharacterSet(charactersIn: " \t\n\r\u{0B}\u{0C}")
        for (i, group) in (fp["net_tie_pad_groups"]?.arguments ?? []).enumerated() {
            var esc = false, pad = ""
            func process() {
                let t = pad.trimmingCharacters(in: space)
                if !t.isEmpty { map[t] = i }
            }
            // (character by character as wxString holds them, code points)
            for ch in group.text.unicodeScalars {
                if esc { esc = false; pad.unicodeScalars.append(ch); continue }
                switch ch {
                case "\\": esc = true
                case ",": process(); pad = ""
                default: pad.unicodeScalars.append(ch)
                }
            }
            process()
        }
        return map
    }

    /// FOOTPRINT::CheckNetTiePadGroups: a pad number a group names that no pad has, or one in more than one group
    /// (which no number can be: each is once in the map), in the order of the map's numbers (std::map's, by code
    /// points)
    static func netTiePadGroupsProblems(_ fp: SExpr) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        let numbers = Set(fp.all("pad").compactMap { $0.text(at: 0) })
        let sorted = netTieGroups(fp).keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
        for number in sorted {
            if !numbers.contains(number) {
                out.append("(net-tie pad group contains unknown pad number \(number))")
            } else if !seen.insert(number).inserted {
                out.append("(pad \(number) appears in more than one net-tie pad group)")
            }
        }
        return out
    }

    /// A pad's copper layers as its LSET has them (PAD::GetLayerSet & LSET::AllCuMask: every copper layer KiCad has,
    /// whether the board has it or not), by name
    static func copperLayers(_ pad: SExpr) -> Set<String> {
        let inner = (1...30).map { "In\($0).Cu" }
        var out = Set<String>()
        for name in pad["layers"]?.arguments.map(\.text) ?? [] {
            switch name {
            case "*.Cu": out.formUnion(["F.Cu", "B.Cu"] + inner)
            case "*In.Cu": out.formUnion(inner)
            case "F&B.Cu": out.formUnion(["F.Cu", "B.Cu"])
            case _ where name.hasSuffix(".Cu") && !name.hasPrefix("*"): out.insert(name)
            default: break
            }
        }
        return out
    }

    /// PAD::GetEffectiveShape( F_Cu ), the one layer CheckShortingPads asks of two padstacks of one shape on every
    /// layer (RelevantShapeLayers: ALL_LAYERS): a plated pad not flashed there (FlashLayer: not on F.Cu, or its
    /// unconnected layers removed but its ends') its hole, else its shape. (KiCad frees that hole's compound before it
    /// asks what it collides with, reading freed memory, footprint-checker.py's footprints have no such pad where it is
    /// asked; the port takes the hole, as KiCad means to.)
    static func frontShapes(_ item: BoardDRC.CopperItem, _ node: SExpr) -> [Shape] {
        guard let p = item.pad, p.pad.attribute == .pth else { return item.outline }
        let flashed = copperLayers(node).contains("F.Cu") && p.unconnectedLayers != .removeAll
        if !flashed, let hole = item.hole { return [hole] }
        return item.outline
    }

    /// FOOTPRINT::CheckShortingPads: each pair of its pads once, in the order the footprint holds them, the first's
    /// position the marker's for its holes: two drilled holes of one diameter (HasDrilledHole) at the same place, or
    /// the first's hole touching the second's middle line (SHAPE_SEGMENT::Collide of its SEG); then, but for two pads
    /// of one number or of one net tie group (the first's), two pads on a copper layer both are on (of all KiCad's
    /// copper layers, the board's or not) whose boxes meet and whose shapes on F.Cu touch, where they touch
    static func shortingPads(_ fp: SExpr, _ drc: BoardDRC, _ copper: BoardDRC.Copper) -> [Violation] {
        let items = copper.footprintPads.first ?? []
        let nodes = fp.all("pad")
        let groups = netTieGroups(fp)
        let layers = nodes.map(copperLayers)
        var out: [Violation] = []
        func drilled(_ p: BoardWorld.Pad) -> Bool { p.drill.x > 0 && p.drill.y > 0 && p.drill.x == p.drill.y }
        for i in items.indices {
            for j in items.indices where j > i {
                let a = items[i], b = items[j]
                guard let pa = a.pad?.pad, let pb = b.pad?.pad else { continue }
                let ida = nodes[i].value("uuid") ?? "", idb = nodes[j].value("uuid") ?? ""
                if drilled(pa) && drilled(pb) {
                    if pa.pos == pb.pos {
                        out.append(Violation(type: "holes_co_located", items: [ida, idb], position: pa.pos))
                    } else if case let .segment(sa, wa)? = a.hole, case let .segment(sb, _)? = b.hole {
                        let minDist = (wa + 1) / 2
                        let d = sb.a == sb.b ? sa.squaredDistance(sb.a) : sa.squaredDistance(sb)
                        if d == 0 || d < minDist * minDist {
                            out.append(Violation(type: "hole_to_hole", items: [ida, idb], position: pa.pos))
                        }
                    }
                }
                let na = nodes[i].text(at: 0) ?? "", nb = nodes[j].text(at: 0) ?? ""
                if !na.isEmpty && na == nb { continue }
                if let g = groups[na], g >= 0, groups[nb] == g { continue }
                guard !layers[i].isDisjoint(with: layers[j]) else { continue }
                guard a.bbox.intersects(b.bbox) else { continue }
                if let at = firstCollision(frontShapes(a, nodes[i]), frontShapes(b, nodes[j])) {
                    out.append(Violation(type: "shorting_items", items: [ida, idb], position: at))
                }
            }
        }
        return out
    }

    /// SHAPE_COMPOUND::Collide of two compounds at no clearance asked where but not how close (collideShapes: its
    /// canExit, which goes on past the first pieces that collide only to find how close): where the first pieces
    /// that collide do (each pair asked how close and where)
    static func firstCollision(_ a: [Shape], _ b: [Shape]) -> IPoint? {
        for sa in a {
            for sb in b {
                var actual: Int?, location: IPoint?
                if sa.collide(sb, clearance: 0, actual: &actual, location: &location) { return location ?? .zero }
            }
        }
        return nil
    }

    // MARK: - Silk clipped by the solder mask

    /// FOOTPRINT::CheckClippedSilk: each of its drawings and texts (m_drawings, in the order it holds them) against
    /// each of its other drawings and texts, then each of its pads: on the front and then the back, one on the silk
    /// whose shape there touches the other's on that side's mask (GetEffectiveShape: a pad's shape, no margin), where
    /// they touch
    static func clippedSilk(_ drc: BoardDRC, _ copper: BoardDRC.Copper) -> [Violation] {
        let items = drc.boardItems(copper).filter { $0.footprint == 0 }
        let drawings = items.filter { $0.kind == .shape || $0.kind == .text }
        let pads = items.filter { $0.kind == .pad }
        var out: [Violation] = []
        func check(_ item: BoardDRC.BoardItem, _ other: BoardDRC.BoardItem) {
            for (silk, mask) in [("F.SilkS", "F.Mask"), ("B.SilkS", "B.Mask")] {
                guard item.isOnLayer(silk), other.isOnLayer(mask) else { continue }
                if let hit = BoardDRC.collideAt(item.shapes(on: silk), other.shapes(on: mask), 0) {
                    out.append(Violation(type: "silk_over_copper", items: [item.uuid, other.uuid], position: hit.location))
                }
            }
        }
        for item in drawings {
            for other in drawings where other !== item { check(item, other) }
            for pad in pads { check(item, pad) }
        }
        return out
    }
}
