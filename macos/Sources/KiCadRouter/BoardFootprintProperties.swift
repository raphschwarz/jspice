// Footprints' and pads' properties set as KiCad's footprint and pad properties dialogs set them (KiCad 10.0.7:
// pcbnew/dialogs/dialog_footprint_properties.cpp, DIALOG_FOOTPRINT_PROPERTIES's TransferDataToWindow, Validate,
// OnAddField and TransferDataFromWindow, with pcbnew/pcb_fields_grid_table.cpp's columns; pcbnew/footprint.cpp,
// FOOTPRINT::Rotate and Flip, pcbnew/pcb_text.cpp, PCB_TEXT::KeepUpright; pcbnew/dialogs/dialog_pad_properties.cpp,
// DIALOG_PAD_PROPERTIES's initValues, updatePadLayersList, transferDataToPad and TransferDataFromWindow, with
// pcbnew/pad.cpp, PAD::Flip), written as pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr.cpp writes a footprint's
// fields and attributes and a pad. Copyright The KiCad Developers, see KiCad's AUTHORS.txt. GNU General Public
// License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

// MARK: - Footprints

/// A footprint's properties as KiCad's footprint properties dialog shows them (lengths in mm, angles in degrees)
public struct FootprintProperties: Equatable, Sendable {
    /// One of its fields (a row of the dialog's grid): its offset from the footprint (on the footprint, before it
    /// turns) and its angle to the footprint's (its own less the footprint's)
    public struct Field: Equatable, Sendable {
        public var name: String
        public var text: String
        public var visible: Bool
        public var offset: KiCadPoint
        public var width: Double
        public var height: Double
        /// Its pen's width; nil for KiCad's automatic one (written without)
        public var thickness: Double?
        public var italic: Bool
        public var layer: String
        public var angle: Double
        public var keepUpright: Bool
        public var knockout: Bool
        public var mirrored: Bool
        /// The field it was read from (its id, which the dialog's copy of it keeps); nil for one the dialog adds
        public internal(set) var uuid: String?

        public init(name: String, text: String, visible: Bool, offset: KiCadPoint, width: Double, height: Double,
                    thickness: Double?, italic: Bool, layer: String, angle: Double, keepUpright: Bool, knockout: Bool,
                    mirrored: Bool) {
            (self.name, self.text, self.visible, self.offset, self.width, self.height) = (name, text, visible, offset, width, height)
            (self.thickness, self.italic, self.layer, self.angle) = (thickness, italic, layer, angle)
            (self.keepUpright, self.knockout, self.mirrored) = (keepUpright, knockout, mirrored)
        }
    }

    /// Its mounting (the dialog's component type)
    public enum Mounting: Sendable, CaseIterable { case throughHole, smd, unspecified }

    public var fields: [Field] = []
    public var position = KiCadPoint.zero
    /// Its angle, as the dialog shows it (in (-180°, 180°])
    public var orientation = 0.0
    public var onBack = false
    public var locked = false
    public var mounting = Mounting.unspecified
    public var boardOnly = false
    public var excludeFromPositionFiles = false
    public var excludeFromBOM = false
    public var doNotPopulate = false
    public var allowSolderMaskBridges = false
    /// Its own clearance and solder mask and paste margins (mm, and the paste's ratio); nil for none (the board's)
    public var clearance: Double?
    public var solderMaskMargin: Double?
    public var solderPasteMargin: Double?
    public var solderPasteRatio: Double?
    public var zoneConnection = ZoneConnection.inherited

    public init() {}
}

extension BoardEditing {
    /// A footprint's properties as KiCad's footprint properties dialog shows them; nil for no footprint of that id
    public func footprintProperties(_ uuid: String) -> FootprintProperties? {
        guard let fp = router.board.footprint(uuid: uuid) else { return nil }
        var p = FootprintProperties()
        let node = fp.node
        let theta = fp.rotation
        p.fields = node.all("property").map { Self.field($0, footprintAngle: theta) }
        p.position = fp.position
        var o = theta.truncatingRemainder(dividingBy: 360)
        if o <= -180 { o += 360 } else if o > 180 { o -= 360 }
        p.orientation = o
        p.onBack = fp.layer == "B.Cu"
        p.locked = node.value("locked") == "yes" || node.flag("locked")
        let attrs = fp.attributes
        p.mounting = attrs.contains("through_hole") ? .throughHole : attrs.contains("smd") ? .smd : .unspecified
        p.boardOnly = attrs.contains("board_only")
        p.excludeFromPositionFiles = attrs.contains("exclude_from_pos_files")
        p.excludeFromBOM = attrs.contains("exclude_from_bom")
        p.doNotPopulate = attrs.contains("dnp")
        p.allowSolderMaskBridges = attrs.contains("allow_soldermask_bridges")
        p.clearance = node["clearance"].map { Self.mm($0, 0) }
        p.solderMaskMargin = node["solder_mask_margin"].map { Self.mm($0, 0) }
        p.solderPasteMargin = node["solder_paste_margin"].map { Self.mm($0, 0) }
        p.solderPasteRatio = node["solder_paste_margin_ratio"]?.number(at: 0)
        p.zoneConnection = node.value("zone_connect").flatMap(Int.init).flatMap(ZoneConnection.init) ?? .inherited
        return p
    }

    /// A field of a footprint turned to `footprintAngle`, as the dialog's grid shows it
    static func field(_ node: SExpr, footprintAngle: Double) -> FootprintProperties.Field {
        let at = node["at"]
        let font = node["effects"]?["font"]
        let size = font?["size"]
        let layer = node["layer"]
        var f = FootprintProperties.Field(
            name: node.text(at: 0) ?? "", text: node.text(at: 1) ?? "", visible: !(node.value("hide") == "yes" || node.flag("hide")),
            offset: KiCadPoint(mm(at, 0), mm(at, 1)), width: mm(size, 1), height: mm(size, 0),
            thickness: font?["thickness"].map { mm($0, 0) }, italic: font?.value("italic") == "yes" || font?.flag("italic") == true,
            layer: layer?.text(at: 0) ?? "F.SilkS", angle: (at?.number(at: 2) ?? 0) - footprintAngle,
            keepUpright: !(node.value("unlocked") == "yes" || node.flag("unlocked") || at?.arguments.contains { $0.kind == .symbol && $0.text == "unlocked" } == true),
            knockout: layer?.arguments.contains { $0.kind == .symbol && $0.text == "knockout" } ?? false,
            mirrored: node["effects"]?["justify"]?.arguments.contains { $0.kind == .symbol && $0.text == "mirror" } ?? false)
        f.uuid = node.value("uuid")
        return f
    }

    /// A field as the dialog adds one (OnAddField): "Field N" (N the rows before it), hidden, on the fabrication layer
    /// of the footprint's side, at its origin, of the board's style for that layer (StyleFromSettings), mirrored on
    /// the back
    public func newFootprintField(_ uuid: String, row: Int) -> FootprintProperties.Field? {
        guard let fp = router.board.footprint(uuid: uuid) else { return nil }
        let layer = fp.layer == "F.Cu" ? "F.Fab" : "B.Fab"
        let style = textStyle(layer: layer)
        return FootprintProperties.Field(name: "Field\(row)", text: "", visible: false, offset: .zero, width: style.width,
                                         height: style.height, thickness: style.thickness, italic: style.italic, layer: layer,
                                         angle: -fp.rotation, keepUpright: style.upright, knockout: false, mirrored: layer.hasPrefix("B."))
    }

    /// Why KiCad's footprint properties dialog would not take `p` (its message, Validate's), nil if it would
    public func footprintPropertiesProblem(_ uuid: String, _ p: FootprintProperties) -> String? {
        guard let fp = router.board.footprint(uuid: uuid) else { return "No such footprint." }
        let mandatory = fp.node.all("property").prefix { ["Reference", "Value", "Datasheet", "Description", "Footprint"].contains($0.text(at: 0) ?? "") }
            .compactMap { $0.text(at: 0) }
        guard Array(p.fields.prefix(mandatory.count).map(\.name)) == mandatory else {
            return "The first \(mandatory.count) fields are mandatory."
        }
        for f in p.fields {
            if f.name.isEmpty { return "Fields must have a name." }
            if Self.iu(f.width) < 0.001 { return "Text width must be at least 0.001 mm." }
            if Self.iu(f.width) > 250 { return "Text width must be at most 250 mm." }
            if Self.iu(f.height) < 0.001 { return "Text height must be at least 0.001 mm." }
            if Self.iu(f.height) > 250 { return "Text height must be at most 250 mm." }
            // (ClampTextPenSize: a quarter of the smaller of its height and width at most)
            if let t = f.thickness {
                let size = min(BoardWorld.iu(f.width), BoardWorld.iu(f.height))
                let most = KiMath.round(Double(size) * 0.25)
                if BoardWorld.iu(t) > most { return "Text thickness is too large for the text size.\nIt will be clamped at \(KiCadNumber.format(Double(most) / 1e6)) mm." }
            }
        }
        if let c = p.clearance, c < 0 { return "Clearance must be at least 0 mm." }
        return nil
    }

    /// The footprint given properties `p`, as KiCad's footprint properties dialog gives them: its fields made the
    /// dialog's rows (each kept by its id, or new), its own clearance, margins and zone connection, put where `p` says
    /// and locked or not, its attributes, then turned to its angle (FOOTPRINT::Rotate: by the difference to it in
    /// [0°, 360°), a whole turn where the footprint is turned below 0°; its texts kept upright) and turned over to the
    /// side it says (FOOTPRINT::Flip, top to bottom, the board editor's default); written as KiCad writes them, as
    /// one change ("Edit Footprint Properties"). Nil where the dialog would refuse it (footprintPropertiesProblem) or
    /// it changes nothing.
    public func setFootprintProperties(_ uuid: String, _ p: FootprintProperties) -> Edit? {
        guard !isRouting, footprintPropertiesProblem(uuid, p) == nil, let fp = router.board.footprint(uuid: uuid) else { return nil }
        let node = fp.node
        let was = node.compact
        let theta = fp.rotation
        // the fields, as the dialog's rows
        let old = Dictionary(node.all("property").compactMap { f in f.value("uuid").map { ($0, f) } }, uniquingKeysWith: { a, _ in a })
        let at = node.items.firstIndex { $0.head == "property" }
        node.items.removeAll { $0.head == "property" }
        let fields = p.fields.map { Self.fieldNode($0, old: $0.uuid.flatMap { old[$0] }, footprintAngle: theta) }
        let index = at ?? ((node.items.lastIndex { ["tags", "descr", "at", "uuid", "layer"].contains($0.head ?? "") }).map { $0 + 1 } ?? node.items.count)
        node.items.insert(contentsOf: fields, at: min(index, node.items.count))
        // its own clearance, margins and zone connection
        let order = ["version", "generator", "generator_version", "locked", "placed", "layer", "uuid", "at", "descr", "tags", "property",
                     "component_classes", "path", "sheetname", "sheetfile", "units", "solder_mask_margin", "solder_paste_margin",
                     "solder_paste_margin_ratio", "clearance", "zone_connect", "attr"]
        func put(_ head: String, _ value: SExpr?) {
            node.remove(head)
            guard let value, let i = order.firstIndex(of: head) else { return }
            node.insert(value, after: Array(order[..<i]))
        }
        put("solder_mask_margin", p.solderMaskMargin.map { SExpr("solder_mask_margin", Self.iu($0)) })
        put("solder_paste_margin", p.solderPasteMargin.map { SExpr("solder_paste_margin", Self.iu($0)) })
        put("solder_paste_margin_ratio", p.solderPasteRatio.map { SExpr("solder_paste_margin_ratio", $0) })
        put("clearance", p.clearance.map { SExpr("clearance", Self.iu($0)) })
        put("zone_connect", p.zoneConnection == .inherited ? nil : SExpr("zone_connect", p.zoneConnection.rawValue))
        // where it is, locked or not
        let position = KiCadPoint(Self.iu(p.position.x), Self.iu(p.position.y))
        if position != fp.position { fp.move(to: position, rotation: theta) }
        node.items.removeAll { ($0.head == "locked") || ($0.kind == .symbol && $0.text == "locked") }
        if p.locked { node.items.insert(SExpr("locked", Keyword("yes")), at: min(2, node.items.count)) }
        // its attributes (the mounting, board only, excluded, DNP; a courtyard allowed missing as it was)
        var attrs = fp.attributes.intersection(["allow_missing_courtyard"])
        switch p.mounting {
        case .throughHole: attrs.insert("through_hole")
        case .smd: attrs.insert("smd")
        case .unspecified: break
        }
        if p.boardOnly { attrs.insert("board_only") }
        if p.excludeFromPositionFiles { attrs.insert("exclude_from_pos_files") }
        if p.excludeFromBOM { attrs.insert("exclude_from_bom") }
        if p.doNotPopulate { attrs.insert("dnp") }
        if p.allowSolderMaskBridges { attrs.insert("allow_soldermask_bridges") }
        fp.attributes = attrs
        if let a = node["attr"] {
            node.remove(a)
            node.insert(a, after: Array(order.dropLast()))
        }
        // turned (orientation.Normalize(), against the footprint's angle as it keeps it)
        var turn = p.orientation.truncatingRemainder(dividingBy: 360)
        if turn < 0 { turn += 360 }
        if turn != theta {
            fp.move(to: fp.position, rotation: turn)
            Self.keepUpright(node)
        }
        // and turned over
        if p.onBack != (fp.layer == "B.Cu") { fp.flip(leftRight: false) }
        guard node.compact != was else { return nil }
        router.boardChanged()
        return change("Edit Footprint Properties", footprints: [uuid])
    }

    /// A field's node as KiCad writes it (a property: its name and text, where it is on the footprint, its angle, kept
    /// upright or not, its layer, hidden or not, its id, its effects), from the row `f` and the node it was read from
    static func fieldNode(_ f: FootprintProperties.Field, old: SExpr?, footprintAngle: Double) -> SExpr {
        let was = old.map { field($0, footprintAngle: footprintAngle) }
        // (what the dialog's row left as it was stays as it was: its angle as read, not that less and plus the
        // footprint's; KiCad's reading keeps an angle in [0°, 360°), and the dialog's adds the footprint's to the
        // row's, which KiCad reads again so)
        let oldAt = old?["at"]
        let x = was?.offset.x == f.offset.x ? (oldAt?.number(at: 0) ?? 0) : iu(f.offset.x)
        let y = was?.offset.y == f.offset.y ? (oldAt?.number(at: 1) ?? 0) : iu(f.offset.y)
        let angle = KiCadFootprint.normalize360(was?.angle == f.angle ? (oldAt?.number(at: 2) ?? 0) : f.angle + footprintAngle)
        var items: [SExprConvertible] = [f.name, f.text, SExpr("at", x, y, angle)]
        if !f.keepUpright { items.append(SExpr("unlocked", Keyword("yes"))) }
        items.append(f.knockout ? SExpr("layer", f.layer, Keyword("knockout")) : SExpr("layer", f.layer))
        if !f.visible { items.append(SExpr("hide", Keyword("yes"))) }
        items.append(SExpr("uuid", old?.value("uuid") ?? KiCadBoard.newUUID()))
        let oldFont = old?["effects"]?["font"]
        var font: [SExprConvertible] = []
        if let face = oldFont?["face"] { font.append(face.copy()) }
        font.append(SExpr("size", iu(f.height), iu(f.width)))
        if let spacing = oldFont?["line_spacing"] { font.append(spacing.copy()) }
        if let t = f.thickness { font.append(SExpr("thickness", iu(t))) }
        if oldFont?.value("bold") == "yes" || oldFont?.flag("bold") == true { font.append(SExpr("bold", Keyword("yes"))) }
        if f.italic { font.append(SExpr("italic", Keyword("yes"))) }
        var effects: [SExprConvertible] = [SExpr("font", font)]
        var justify = (old?["effects"]?["justify"]?.arguments.filter { $0.kind == .symbol && $0.text != "mirror" }.map { Keyword($0.text) as SExprConvertible }) ?? []
        if f.mirrored { justify.append(Keyword("mirror")) }
        if !justify.isEmpty { effects.append(SExpr("justify", justify)) }
        items.append(SExpr("effects", effects))
        if let cache = old?["render_cache"] { items.append(cache.copy()) }
        return SExpr("property", items)
    }

    /// PCB_TEXT::KeepUpright of each of the footprint's fields and texts kept upright: one at 180° or more turned a
    /// half turn back, its justification reversed
    static func keepUpright(_ node: SExpr) {
        for child in node.items where child.head == "property" || child.head == "fp_text" {
            guard let at = child["at"], !(child.value("unlocked") == "yes" || child.flag("unlocked")),
                  !at.arguments.contains(where: { $0.kind == .symbol && $0.text == "unlocked" }) else { continue }
            var angle = KiCadFootprint.normalize360(at.number(at: 2) ?? 0)
            guard angle >= 180 else { continue }
            angle = KiCadFootprint.normalize360(angle + 180)
            at.items = Array(at.items.prefix(3)) + [angle.sexpr] + at.items.dropFirst(4).filter { $0.kind == .symbol }
            if let justify = child["effects"]?["justify"] {
                let opposite = ["left": "right", "right": "left", "top": "bottom", "bottom": "top"]
                for i in 1..<justify.items.count { justify.items[i] = SExpr(symbol: opposite[justify.items[i].text] ?? justify.items[i].text) }
            }
        }
    }
}
