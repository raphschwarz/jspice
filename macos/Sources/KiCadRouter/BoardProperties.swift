// Zones', footprints' and pads' properties set as KiCad's properties dialogs set them (KiCad 10.0.7: a zone's by
// pcbnew/edit_zone_helpers.cpp, PCB_EDIT_FRAME::Edit_Zone_Params, with pcbnew/dialogs/panel_zone_properties.cpp,
// PANEL_ZONE_PROPERTIES::AcceptOptions, pcbnew/dialogs/dialog_copper_zones.cpp and dialog_rule_area_properties.cpp's
// TransferDataFromWindow, and pcbnew/zone_settings.cpp, ZONE_SETTINGS::operator<< and ExportSetting; a footprint's by
// pcbnew/dialogs/dialog_footprint_properties.cpp, DIALOG_FOOTPRINT_PROPERTIES::Validate and TransferDataFromWindow,
// and pcbnew/pcb_fields_grid_table.cpp; a pad's by pcbnew/dialogs/dialog_pad_properties.cpp,
// DIALOG_PAD_PROPERTIES::initValues, transferDataToPad and TransferDataFromWindow), items locked and unlocked as
// BOARD_EDITOR_CONTROL::modifyLockSelected locks them, and all written as pcbnew/pcb_io/kicad_sexpr/
// pcb_io_kicad_sexpr.cpp writes them. Copyright The KiCad Developers, see KiCad's AUTHORS.txt. GNU General Public
// License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// How copper of a zone meets a pad (ZONE_CONNECTION, its numbers as KiCad writes a footprint's or pad's
/// zone_connect): as its zone, footprint or the board's rules say (inherited, a footprint's or pad's only), not at
/// all, by thermal reliefs, solid, or thermal reliefs for plated holes only (a zone's only)
public enum ZoneConnection: Int, Sendable, CaseIterable {
    case inherited = -1, none = 0, thermal = 1, full = 2, thtThermal = 3
}

// MARK: - Zones

/// A zone's or rule area's properties, as KiCad's ZONE_SETTINGS holds them and its zone properties dialogs show them
/// (lengths in mm, angles in degrees, areas in mm²)
public struct ZoneProperties: Equatable, Sendable {
    /// Which of a zone's islands its fill drops (ISLAND_REMOVAL_MODE)
    public enum IslandRemoval: Int, Sendable, CaseIterable { case always = 0, never = 1, area = 2 }
    /// How its corners are smoothed (ZONE_SETTINGS::CORNER_SMOOTHING)
    public enum Smoothing: Int, Sendable, CaseIterable { case none = 0, chamfer = 1, fillet = 2 }
    /// How its outline is drawn (ZONE_BORDER_DISPLAY_STYLE)
    public enum BorderStyle: String, Sendable, CaseIterable { case none, edge, full }
    /// What a rule area places its footprints by (PLACEMENT_SOURCE_T), as KiCad writes it
    public enum PlacementSource: String, Sendable, CaseIterable {
        case sheetname, componentClass = "component_class", group
    }

    public var name = ""
    /// Its net's name, nil for none (a rule area has none)
    public var net: String?
    public var layers: [String] = ["F.Cu"]
    public var priority = 0
    public var locked = false
    public var clearance = 0.5
    public var minWidth = 0.25
    public var padConnection = ZoneConnection.thermal
    public var thermalGap = 0.5
    public var spokeWidth = 0.5
    /// Filled with a hatch (ZONE_FILL_MODE::HATCH_PATTERN) rather than solid
    public var hatched = false
    public var hatchThickness = 1.0
    public var hatchGap = 1.5
    public var hatchOrientation = 0.0
    public var hatchSmoothingLevel = 0
    public var hatchSmoothingValue = 0.1
    public var hatchHoleMinArea = 0.15
    /// The hatch's border as thick as its lines (hatch_thickness), else as the zone's minimum width
    public var hatchBorderFromHatch = true
    /// The hatch's offsets by layer (ZONE_LAYER_PROPERTIES' hatching_offset), mm
    public var hatchOffsets: [String: KiCadPoint] = [:]
    public var islandRemoval = IslandRemoval.always
    public var minIslandArea = 10.0
    public var smoothing = Smoothing.none
    public var cornerRadius = 0.0
    public var borderStyle = BorderStyle.edge
    public var borderHatchPitch = 0.5
    /// A rule area, and what it keeps out
    public var isRuleArea = false
    public var keepout = KiCadBoard.Keepout()
    public var placementEnabled = false
    public var placementSource = PlacementSource.sheetname
    public var placementSourceName = ""
    /// A teardrop (not editable here)
    public internal(set) var isTeardrop = false

    public init() {}
}

extension BoardEditing {
    /// A zone's properties as KiCad reads them (ZONE_SETTINGS << ZONE: the parser's values, ZONE_SETTINGS' defaults
    /// where the file has none); nil for no zone of that id on the board
    public func zoneProperties(_ uuid: String) -> ZoneProperties? {
        guard let node = zoneNode(uuid) else { return nil }
        return Self.zoneProperties(node, board: router.board)
    }

    static func zoneProperties(_ node: SExpr, board: KiCadBoard) -> ZoneProperties {
        var p = ZoneProperties()
        let zone = board.zone(node)
        p.name = node.value("name") ?? ""
        p.layers = Self.layerNames(node, board: board)
        p.priority = node.value("priority").flatMap(Int.init) ?? 0
        p.locked = node.value("locked") == "yes" || node.flag("locked")
        p.isTeardrop = node["attr"]?["teardrop"] != nil
        p.isRuleArea = node["keepout"] != nil || node["placement"] != nil
        p.net = p.isRuleArea ? nil : zone.net
        let connect = node["connect_pads"]
        let args = connect?.arguments.filter { $0.kind == .symbol }.map(\.text) ?? []
        p.padConnection = args.contains("yes") ? .full : args.contains("no") ? .none : args.contains("thru_hole_only") ? .thtThermal : .thermal
        if let c = connect?["clearance"] { p.clearance = mm(c, 0) }
        if let t = node["min_thickness"] { p.minWidth = mm(t, 0) }
        if let h = node["hatch"] {
            p.borderStyle = ZoneProperties.BorderStyle(rawValue: h.text(at: 0) ?? "edge") ?? .edge
            p.borderHatchPitch = mm(h, 1)
        }
        if let k = node["keepout"] {
            func out(_ name: String) -> Bool { k[name]?.text(at: 0) == "not_allowed" }
            p.keepout = KiCadBoard.Keepout(tracks: out("tracks"), vias: out("vias"), pads: out("pads"), copperPour: out("copperpour"),
                                           footprints: out("footprints"))
        } else if p.isRuleArea {
            // (ZONE_SETTINGS' defaults: tracks, vias and pads kept out)
            p.keepout = KiCadBoard.Keepout(tracks: true, vias: true, pads: true, copperPour: false, footprints: false)
        }
        if let pl = node["placement"] {
            p.placementEnabled = pl["enabled"]?.text(at: 0) == "yes"
            for source in ZoneProperties.PlacementSource.allCases {
                if let s = pl[source.rawValue] { p.placementSource = source; p.placementSourceName = s.text(at: 0) ?? "" }
            }
        }
        if let f = node["fill"] {
            p.hatched = f["mode"]?.text(at: 0) == "hatch"
            if let v = f["thermal_gap"] { p.thermalGap = mm(v, 0) }
            if let v = f["thermal_bridge_width"] { p.spokeWidth = mm(v, 0) }
            if !p.isRuleArea {
                switch f["smoothing"]?.text(at: 0) {
                case "chamfer": p.smoothing = .chamfer
                case "fillet": p.smoothing = .fillet
                default: p.smoothing = .none
                }
                if let v = f["radius"] { p.cornerRadius = mm(v, 0) }
            }
            if let m = f["island_removal_mode"]?.text(at: 0).flatMap(Int.init) { p.islandRemoval = ZoneProperties.IslandRemoval(rawValue: m) ?? .always }
            // (parseBoardUnits of the square millimetres, an int, times IU_PER_MM)
            if let v = f["island_area_min"] { p.minIslandArea = Double(BoardWorld.iu(v, 0)) / 1e6 }
            if let v = f["hatch_thickness"] { p.hatchThickness = mm(v, 0) }
            if let v = f["hatch_gap"] { p.hatchGap = mm(v, 0) }
            if let v = f["hatch_orientation"]?.number(at: 0) { p.hatchOrientation = v }
            if let v = f["hatch_smoothing_level"]?.number(at: 0) { p.hatchSmoothingLevel = Int(v) }
            if let v = f["hatch_smoothing_value"]?.number(at: 0) { p.hatchSmoothingValue = v }
            if let v = f["hatch_border_algorithm"]?.text(at: 0) { p.hatchBorderFromHatch = v == "hatch_thickness" }
            if let v = f["hatch_min_hole_area"]?.number(at: 0) { p.hatchHoleMinArea = v }
        }
        for prop in node.all("property") {
            guard let l = prop.value("layer"), let xy = prop["hatch_position"]?["xy"] else { continue }
            p.hatchOffsets[l] = KiCadPoint(mm(xy, 0), mm(xy, 1))
        }
        return p
    }

    /// A length as KiCad reads it, in mm (parseBoardUnits: whole nanometres)
    static func mm(_ list: SExpr?, _ i: Int) -> Double { Double(BoardWorld.iu(list, i)) / 1e6 }

    /// A length in mm as KiCad keeps it, whole nanometres
    static func iu(_ mm: Double) -> Double { Double(BoardWorld.iu(mm)) / 1e6 }

    /// An item's layers by name, as KiCad reads them ("*.Cu" the board's copper layers, "F&B.Cu" the outer two, "*.X"
    /// both sides' X), in KiCad's order of its layers' ids
    static func layerNames(_ node: SExpr, board: KiCadBoard) -> [String] {
        let names = node["layers"]?.arguments.map(\.text) ?? node.value("layer").map { [$0] } ?? []
        let copper = boardLayers(board).filter { $0.hasSuffix(".Cu") }
        var out = Set<String>()
        for n in names {
            switch n {
            case "*.Cu": out.formUnion(copper)
            case "F&B.Cu": out.formUnion(["F.Cu", "B.Cu"])
            case _ where n.hasPrefix("*."): out.formUnion(["F" + n.dropFirst(), "B" + n.dropFirst()])
            default: out.insert(n)
            }
        }
        return out.sorted { (BoardDRC.layerID($0) ?? 1000, $0) < (BoardDRC.layerID($1) ?? 1000, $1) }
    }

    /// The board's layers by their canonical names, as its layers list has them
    static func boardLayers(_ board: KiCadBoard) -> [String] {
        board.root["layers"]?.arguments.compactMap { $0.text(at: 0) } ?? []
    }

    /// Why KiCad's zone properties dialog would not take `p` for the zone (its message), nil if it would
    public func zonePropertiesProblem(_ uuid: String, _ p: ZoneProperties) -> String? {
        guard let node = zoneNode(uuid) else { return "No such zone." }
        let was = Self.zoneProperties(node, board: router.board)
        if was.isTeardrop { return "Teardrops are not edited here." }
        let layers = Set(p.layers).intersection(Self.boardLayers(router.board))
        if !was.isRuleArea {
            guard was.layers.contains(where: { $0.hasSuffix(".Cu") }) else { return "Zones on no copper layer are not edited here." }
            // (the copper zone dialog lists the copper layers alone)
            if !layers.contains(where: { $0.hasSuffix(".Cu") }) { return "No layer selected." }
            if p.clearance < 0 { return "Clearance must be at least 0 mm." }
            if p.clearance > 100 { return "Clearance must be at most 100 mm." }
            if p.minWidth < 0.025 { return "Minimum width must be at least 0.025 mm." }
            if p.cornerRadius < 0 { return "Corner radius must be at least 0 mm." }
            if p.spokeWidth < 0 { return "Thermal spoke width must be at least 0 mm." }
            // (the hatch's checked as the zone was filled when the dialog opened: m_settings' fill mode, before the
            // dialog's own is taken)
            if was.hatched {
                if Self.iu(p.hatchThickness) < Self.iu(p.minWidth) { return "Hatch width must be at least \(KiCadNumber.format(p.minWidth)) mm." }
                if Self.iu(p.hatchGap) < Self.iu(p.minWidth) { return "Hatch gap must be at least \(KiCadNumber.format(p.minWidth)) mm." }
            }
        } else if layers.isEmpty {
            return "No layers selected."
        }
        if Self.iu(p.borderHatchPitch) < 0.1 { return "Outline hatch pitch must be at least 0.1 mm." }
        if Self.iu(p.borderHatchPitch) > 2 { return "Outline hatch pitch must be at most 2 mm." }
        if !was.isRuleArea {
            if Self.iu(p.spokeWidth) < Self.iu(p.minWidth) { return "Thermal spoke width cannot be smaller than the minimum width." }
            if let net = p.net, !net.isEmpty, !router.board.netNames.contains(net), !router.world.netNames.values.contains(net) {
                return "No net \(net) on the board."
            }
        }
        return nil
    }

    /// The zone given properties `p`, as KiCad's zone properties dialog gives them (ZONE_SETTINGS::ExportSetting after
    /// the dialog's AcceptOptions): its name made unique among the board's zones' (a rule area's only where it
    /// changed), the hatch's orientation in (-180°, 180°], a radius only where it is smoothed, a rule area's priority
    /// 0 and its net none, the zone unfilled where its layers changed (ZONE::SetLayerSet); written as KiCad writes a
    /// zone, as one change ("Edit Zone Properties"), the zones filled again (refillsZones). Nil where the dialog would
    /// refuse it (zonePropertiesProblem) or it changes nothing.
    public func setZoneProperties(_ uuid: String, _ p: ZoneProperties) -> Edit? {
        guard !isRouting, zonePropertiesProblem(uuid, p) == nil, let node = zoneNode(uuid) else { return nil }
        let board = router.board
        let was = Self.zoneProperties(node, board: board)
        var s = p
        s.isRuleArea = was.isRuleArea
        s.isTeardrop = false
        let enabled = Set(Self.boardLayers(board))
        s.layers = Self.layerNames(SExpr("layers", p.layers.filter { enabled.contains($0) && (s.isRuleArea || $0.hasSuffix(".Cu")) }), board: board)
        // (AcceptOptions: the hatch turned to (-180°, 180°]; no radius without smoothing)
        var orientation = s.hatchOrientation.truncatingRemainder(dividingBy: 360)
        if orientation <= -180 { orientation += 360 } else if orientation > 180 { orientation -= 360 }
        s.hatchOrientation = orientation
        if s.smoothing == .none { s.cornerRadius = 0 }
        let others = board.root.all("zone").filter { $0 !== node }.map { $0.value("name") ?? "" }
        if s.isRuleArea {
            s.priority = 0
            s.net = nil
            if s.name != was.name { s.name = Self.uniqueZoneName(s.name, inUse: others) }
        } else {
            s.name = Self.uniqueZoneName(s.name, inUse: others)
        }
        if s.isRuleArea {
            // (the placement source the dialog keeps: none named, an empty one)
            if !s.placementEnabled && s.placementSourceName.isEmpty { s.placementSource = was.placementSource }
        }
        // (the hatch's offsets only on the zone's layers: SetLayerSet drops the others')
        s.hatchOffsets = s.hatchOffsets.filter { s.layers.contains($0.key) }
        let layersChanged = Set(s.layers) != Set(was.layers)
        let fresh = Self.zoneNode(s, from: node, board: board, unfilled: layersChanged)
        guard fresh.compact != node.compact else { return nil }
        node.items = fresh.items
        router.boardChanged()
        return change("Edit Zone Properties", zones: [uuid])
    }

    /// BOARD::MakeUniqueZoneName: `base` if no other zone has it (or it is empty), else its root (less a last "_N")
    /// with the first "_N" none has
    static func uniqueZoneName(_ base: String, inUse names: [String]) -> String {
        let used = Set(names)
        if base.isEmpty || !used.contains(base) { return base }
        var root = base
        if let i = base.lastIndex(of: "_") {
            let suffix = base[base.index(after: i)...]
            if !suffix.isEmpty && suffix.allSatisfy({ $0.isNumber }) { root = String(base[..<i]) }
        }
        var n = 1
        while used.contains("\(root)_\(n)") { n += 1 }
        return "\(root)_\(n)"
    }

    /// A zone node as KiCad writes a zone of properties `p` (PCB_IO_KICAD_SEXPR::format( ZONE )): its id, outline
    /// and, unless `unfilled`, fills those of `node`
    static func zoneNode(_ p: ZoneProperties, from node: SExpr, board: KiCadBoard, unfilled: Bool) -> SExpr {
        func n(_ v: Double) -> Double { iu(v) }
        var items: [SExprConvertible] = []
        if p.locked { items.append(SExpr("locked", Keyword("yes"))) }
        let copper = p.layers.contains { $0.hasSuffix(".Cu") }
        if p.layers.count > 1 {
            items.append(SExpr("layers", (copper ? p.layers : wildcardLayers(p.layers)).map { $0 as SExprConvertible }))
        } else {
            items.append(SExpr("layer", p.layers.first ?? "F.Cu"))
        }
        if let uuid = node.value("uuid") { items.append(SExpr("uuid", uuid)) }
        if !p.name.isEmpty { items.append(SExpr("name", p.name)) }
        items.append(SExpr("hatch", Keyword(p.borderStyle.rawValue), n(min(max(p.borderHatchPitch, 0.1), 2))))
        if p.priority > 0 { items.append(SExpr("priority", p.priority)) }
        if let attr = node["attr"] { items.append(attr.copy()) }
        var connect: [SExprConvertible] = []
        switch p.padConnection {
        case .thtThermal: connect.append(Keyword("thru_hole_only"))
        case .full: connect.append(Keyword("yes"))
        case .none: connect.append(Keyword("no"))
        default: break
        }
        connect.append(SExpr("clearance", n(p.clearance)))
        items.append(SExpr("connect_pads", connect))
        items.append(SExpr("min_thickness", n(p.minWidth)))
        if p.isRuleArea {
            func rule(_ name: String, _ out: Bool) -> SExpr { SExpr(name, Keyword(out ? "not_allowed" : "allowed")) }
            items.append(SExpr("keepout", rule("tracks", p.keepout.tracks), rule("vias", p.keepout.vias), rule("pads", p.keepout.pads),
                               rule("copperpour", p.keepout.copperPour), rule("footprints", p.keepout.footprints)))
            items.append(SExpr("placement", SExpr("enabled", Keyword(p.placementEnabled ? "yes" : "no")),
                               SExpr(p.placementSource.rawValue, p.placementSourceName)))
        }
        var fill: [SExprConvertible] = []
        let filled = !unfilled && node["fill"]?.arguments.contains { $0.kind == .symbol && $0.text == "yes" } == true
        if filled { fill.append(Keyword("yes")) }
        if p.hatched { fill.append(SExpr("mode", Keyword("hatch"))) }
        fill += [SExpr("thermal_gap", n(p.thermalGap)), SExpr("thermal_bridge_width", n(p.spokeWidth))]
        if p.smoothing != .none {
            fill.append(SExpr("smoothing", Keyword(p.smoothing == .chamfer ? "chamfer" : "fillet")))
            if n(p.cornerRadius) != 0 { fill.append(SExpr("radius", n(p.cornerRadius))) }
        }
        fill.append(SExpr("island_removal_mode", p.islandRemoval.rawValue))
        if p.islandRemoval == .area {
            // (the area in square millimetres, cut to whole square nanometres-by-millimetres as KiCad writes it)
            let area = (Double(BoardWorld.iu(p.minIslandArea)) / 1e6)
            fill.append(SExpr("island_area_min", area))
        }
        if p.hatched {
            fill += [SExpr("hatch_thickness", n(p.hatchThickness)), SExpr("hatch_gap", n(p.hatchGap)),
                     SExpr("hatch_orientation", p.hatchOrientation)]
            if p.hatchSmoothingLevel > 0 {
                fill += [SExpr("hatch_smoothing_level", p.hatchSmoothingLevel), SExpr("hatch_smoothing_value", p.hatchSmoothingValue)]
            }
            fill += [SExpr("hatch_border_algorithm", Keyword(p.hatchBorderFromHatch ? "hatch_thickness" : "min_thickness")),
                     SExpr("hatch_min_hole_area", p.hatchHoleMinArea)]
        }
        items.append(SExpr("fill", fill))
        for (layer, offset) in p.hatchOffsets.sorted(by: { (BoardDRC.layerID($0.key) ?? 1000) < (BoardDRC.layerID($1.key) ?? 1000) }) {
            items.append(SExpr("property", SExpr("layer", layer), SExpr("hatch_position", SExpr("xy", n(offset.x), n(offset.y)))))
        }
        for poly in node.all("polygon") { items.append(poly.copy()) }
        if !unfilled {
            for f in node.all("filled_polygon") where p.layers.contains(f.value("layer") ?? "") { items.append(f.copy()) }
        }
        let out = SExpr("zone", items)
        // (its net first, as this board names nets)
        if copper && !p.isRuleArea, let net = p.net, !net.isEmpty {
            board.zone(out).setNet(net)
            if board.numbersNets {
                // (KiCad 9's (net N) (net_name "X"), first)
                let lists = out.items.filter { $0.head == "net" || $0.head == "net_name" }
                out.items.removeAll { $0.head == "net" || $0.head == "net_name" }
                out.items.insert(contentsOf: lists, at: 1)
            }
        } else if board.numbersNets {
            out.items.insert(contentsOf: [SExpr("net", 0), SExpr("net_name", "")], at: 1)
        }
        return out
    }

    /// formatLayers' wildcards for an item's layers of no copper (both sides' adhesive, paste, silkscreen, mask,
    /// courtyard and fabrication each as one), the rest by name in KiCad's order
    static func wildcardLayers(_ layers: [String]) -> [String] {
        var left = Set(layers)
        var out: [String] = []
        for kind in ["Adhes", "Paste", "SilkS", "Mask", "CrtYd", "Fab"] where left.contains("F.\(kind)") && left.contains("B.\(kind)") {
            out.append("*.\(kind)")
            left.subtract(["F.\(kind)", "B.\(kind)"])
        }
        return out + left.sorted { (BoardDRC.layerID($0) ?? 1000) < (BoardDRC.layerID($1) ?? 1000) }
    }
}
