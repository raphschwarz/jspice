// Ported from KiCad 10.0.7: pcbnew/drc/drc_engine.cpp (InitEngine: the rules file beside the board's project; the
// checks' constraints by EvalRules), pcbnew/drc/drc_test_provider_track_width.cpp, drc_test_provider_via_diameter.cpp,
// drc_test_provider_hole_size.cpp, drc_test_provider_annular_width.cpp, drc_test_provider_hole_to_hole.cpp,
// pcbnew/drc/drc_test_provider.cpp (formatMsg), pcbnew/drc/drc_item.cpp (the checks' keys and titles),
// pcbnew/board_design_settings.cpp (the rules' defaults and severities) and common/eda_units.cpp
// (MessageTextFromValue, StringFromValue).
// Copyright (C) 2004-2024 Jean-Pierre Charras; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// Something on a board against its design rules, as KiCad's DRC reports it
public struct DRCViolation: Hashable, Sendable {
    /// KiCad's key for the check ("track_width", "clearance"…)
    public var type: String
    /// "error" or "warning"
    public var severity: String
    /// What KiCad says of it: the check's title, and what it found against what the rule asks
    public var description: String
    /// The board items it is about (their uuids), in KiCad's order
    public var items: [String]

    public init(type: String, severity: String, description: String, items: [String]) {
        (self.type, self.severity, self.description, self.items) = (type, severity, description, items)
    }
}

/// KiCad's design rules check of a board (its DRC_ENGINE), on the rules KiCad makes of the board's design settings
/// and net classes and those of its rules file (a .kicad_dru: DesignRuleEngine): the checks of its copper, outline,
/// courtyards, solder mask and silkscreen (checksMade). What of the user's rules its checks do not follow as KiCad's
/// do (a constraint of a check it does not make, a condition it cannot evaluate) is named in `unsupported`.
public struct BoardDRC {
    /// The board's design settings the checks go by (BOARD_DESIGN_SETTINGS), KiCad's defaults where its project
    /// has none
    public struct Settings: Sendable {
        public var minClearance = 0
        public var minTrackWidth = 200_000
        /// (KiCad's default where the project has none is the minimum via diameter's, 0.5 mm, as its parameter is
        /// declared)
        public var minViaAnnularWidth = 500_000
        public var minViaDiameter = 500_000
        public var minThroughDrill = 300_000
        public var minMicroViaDiameter = 200_000
        public var minMicroViaDrill = 100_000
        public var holeToHole = 250_000
        public var holeClearance = 250_000
        public var edgeClearance = 500_000
        /// The silkscreen's least distance to silkscreen and to the board's edges (min_silk_clearance)
        public var silkClearance = 0
        public var maxError = 5000
        /// GetDRCEpsilon: half a micron
        public var epsilon = 500
        /// The solder mask's least distance to copper (solder_mask_to_copper_clearance)
        public var solderMaskToCopperClearance = 0
        /// How many spokes a thermal relief needs at least (min_resolved_spokes)
        public var minResolvedSpokes = 2
        /// Each check's severity by its key ("error", "warning" or "ignore")
        public var severities: [String: String] = BoardDRC.defaultSeverities

        public init() {}

        public init(project: [String: Any]?) {
            let ds = (project?["board"] as? [String: Any])?["design_settings"] as? [String: Any] ?? [:]
            let rules = ds["rules"] as? [String: Any] ?? [:]
            func mm(_ key: String, _ value: inout Int) {
                if let v = (rules[key] as? NSNumber)?.doubleValue { value = BoardWorld.iuScaled(v) }
            }
            mm("min_clearance", &minClearance)
            mm("solder_mask_to_copper_clearance", &solderMaskToCopperClearance)
            mm("min_track_width", &minTrackWidth)
            mm("min_via_annular_width", &minViaAnnularWidth)
            mm("min_via_diameter", &minViaDiameter)
            mm("min_through_hole_diameter", &minThroughDrill)
            mm("min_microvia_diameter", &minMicroViaDiameter)
            mm("min_microvia_drill", &minMicroViaDrill)
            mm("min_hole_to_hole", &holeToHole)
            mm("min_hole_clearance", &holeClearance)
            mm("min_copper_edge_clearance", &edgeClearance)
            mm("min_silk_clearance", &silkClearance)
            mm("max_error", &maxError)
            if let v = (rules["min_resolved_spokes"] as? NSNumber)?.intValue { minResolvedSpokes = v }
            for (key, value) in ds["rule_severities"] as? [String: Any] ?? [:] {
                if let s = value as? String { severities[key] = s }
            }
            // (KiCad 5's name for it)
            if let s = (ds["rule_severities"] as? [String: Any])?["hole_near_hole"] as? String { severities["hole_to_hole"] = s }
        }

        func severity(_ type: String) -> String { severities[type] ?? "error" }
    }

    /// The checks' severities as KiCad sets them where a project does not (each an error but these)
    public static let defaultSeverities: [String: String] = [
        "holes_co_located": "warning", "hole_to_hole": "warning", "missing_courtyard": "ignore",
        "track_dangling": "warning", "via_dangling": "warning", "copper_sliver": "warning", "isolated_copper": "warning",
        "padstack": "warning", "connection_width": "warning", "track_not_centered_on_via": "ignore",
        "silk_overlap": "warning", "silk_over_copper": "warning", "silk_edge_clearance": "warning",
    ]

    /// The checks' titles (DRC_ITEM's error texts)
    static let titles: [String: String] = [
        "track_width": "Track width", "via_diameter": "Via diameter", "annular_width": "Annular width",
        "drill_out_of_range": "Hole size out of range", "microvia_drill_out_of_range": "Micro via hole size out of range",
        "hole_to_hole": "Drilled hole too close to other hole", "holes_co_located": "Drilled holes co-located",
        "clearance": "Clearance violation", "hole_clearance": "Hole clearance violation", "shorting_items": "Items shorting two nets",
        "tracks_crossing": "Tracks crossing", "copper_edge_clearance": "Board edge clearance violation",
        "track_dangling": "Track has unconnected end", "via_dangling": "Via is not connected or connected on only one layer",
        "unconnected_items": "Missing connection between items", "items_not_allowed": "Items not allowed",
        "courtyards_overlap": "Courtyards overlap", "missing_courtyard": "Footprint has no courtyard defined",
        "malformed_courtyard": "Footprint has malformed courtyard", "pth_inside_courtyard": "PTH inside courtyard",
        "npth_inside_courtyard": "NPTH inside courtyard", "invalid_outline": "Board has malformed outline", "zones_intersect": "Copper zones intersect", "copper_sliver": "Copper sliver",
        "solder_mask_bridge": "Front solder mask aperture bridges items with different nets",
        "isolated_copper": "Isolated copper fill", "starved_thermal": "Thermal relief connection to zone incomplete",
        "silk_overlap": "Silkscreen clearance", "silk_over_copper": "Silkscreen clipped by solder mask",
        "silk_edge_clearance": "Silkscreen clipped by board edge", "assertion_failure": "Assertion failure",
    ]

    /// How many of each check KiCad reports at most (DRC_ENGINE's ERROR_LIMIT; its EXTENDED_ERROR_LIMIT for
    /// clearances and missing connections)
    public static func errorLimit(_ type: String) -> Int { type == "clearance" || type == "unconnected_items" ? 499 : 199 }

    public let settings: Settings
    let board: KiCadBoard
    private(set) var world: BoardWorld
    let netClasses: NetClasses
    var tracks: [Track] = []
    var footprints: [Footprint] = []
    /// The board's design rules engine (its implicit rules, and the user's of `designRules`)
    private(set) var ruleState: RuleState!

    /// What of the user's design rules the port's checks do not follow as KiCad's do, by name (the checks then may
    /// not find what KiCad's find)
    public var unsupported: Set<String> { ruleState.board.unsupported.union(unsupportedRules) }
    private var unsupportedRules: Set<String> = []

    /// The design rules check of `board`, its project's JSON in `project` (nil for KiCad's defaults) and the rules of
    /// its .kicad_dru in `designRules`
    public init(board: KiCadBoard, project: [String: Any]? = nil, designRules: String? = nil) {
        self.board = board
        settings = Settings(project: project)
        world = BoardWorld(board: board, project: project)
        netClasses = NetClasses(project: project)
        read()
        ruleState = makeRuleState(project: project, rulesText: designRules)
        // (the board's worst clearance with the rules' clearances in it)
        world.raiseMaxClearance(ruleState.engine.biggestClearanceValue(settings))
        unsupportedRules = Self.unsupportedConstraints(ruleState.engine.userConstraintTypes)
    }

    /// The same, the project read from its file, and the design rules from the .kicad_dru beside it (where KiCad's
    /// DRC engine finds them)
    public init(board: KiCadBoard, projectURL: URL?) {
        let json = projectURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        self.init(board: board, project: json, designRules: projectURL.flatMap(Self.designRules))
    }

    /// The rules file beside a project (NAME.kicad_dru), its text
    public static func designRules(_ projectURL: URL) -> String? {
        let url = projectURL.deletingPathExtension().appendingPathExtension("kicad_dru")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The constraint types the port's checks do not follow as KiCad's do
    static func unsupportedConstraints(_ types: Set<DRCConstraintType>) -> Set<String> {
        // (a thermal spoke width is the filler's, which the checks take the fills of as they are)
        let followed: Set<DRCConstraintType> = [.clearance, .holeClearance, .edgeClearance, .trackWidth, .viaDiameter, .holeSize,
                                                .annularWidth, .holeToHole, .disallow, .assertion, .courtyardClearance,
                                                .silkClearance, .zoneConnection, .thermalReliefGap, .thermalSpokeWidth,
                                                .minResolvedSpokes]
        return Set(types.subtracting(followed).map { "the \($0.keyword) constraint" })
    }

    // MARK: - The board's items

    /// A track, arc or via (PCB_TRACK, PCB_ARC, PCB_VIA), in the order the board holds them (BOARD::Tracks)
    struct Track {
        enum Kind { case track, arc, via }
        var kind: Kind
        var uuid: String
        var net: String
        /// Whether it was read with a net clause
        var hasNet = false
        var start = IPoint.zero, mid = IPoint.zero, end = IPoint.zero
        var width = 0
        var layer = ""
        // a via's
        var diameter = 0
        var drill = 0
        var viaType = Via.ViaType.through
        /// The copper layers it spans, as router layers
        var layers = LayerRange(0, 0)
        /// Its padstack's unconnected layer mode
        var unconnectedLayers = UnconnectedLayerMode.keepAll
        /// A free via (PCB_VIA::GetIsFree: one whose net the connectivity does not change)
        var free = false
    }

    /// PADSTACK::UNCONNECTED_LAYER_MODE: which copper layers a pad or via is kept on where nothing connects to it
    enum UnconnectedLayerMode {
        case keepAll, removeAll, removeExceptStartAndEnd

        init(_ node: SExpr) {
            if node.value("remove_unused_layers") != "yes" {
                self = .keepAll
            } else {
                self = node.value("keep_end_layers") == "yes" ? .removeExceptStartAndEnd : .removeAll
            }
        }

        /// ConditionallyFlashed: whether it is flashed on a layer only where something connects to it there
        func conditionallyFlashed(_ layer: Int, start: Int, end: Int) -> Bool {
            switch self {
            case .keepAll: return false
            case .removeAll: return true
            case .removeExceptStartAndEnd: return layer != start && layer != end
            }
        }
    }

    struct Footprint {
        var reference: String
        var pads: [Pad]
        /// Its pads of one number joined (FOOTPRINT::GetDuplicatePadNumbersAreJumpers)
        var duplicatePadNumbersAreJumpers = false
        /// Groups of its pads joined (FOOTPRINT::JumperPadGroups), by number
        var jumperPadGroups: [Set<String>] = []
    }

    /// A pad (PAD), with what the checks ask of it
    struct Pad {
        var uuid: String
        var number: String
        var net: String
        var pad: BoardWorld.Pad
        /// A custom pad's pieces
        var primitives: [SExpr] = []
        var pinType = ""
        var unconnectedLayers = UnconnectedLayerMode.keepAll
        var hasHole: Bool { pad.drill.x > 0 && pad.drill.y > 0 }
        /// PAD::HasDrilledHole: a hole of one diameter
        var hasDrilledHole: Bool { hasHole && pad.drill.x == pad.drill.y }
    }

    static func netName(_ node: SExpr) -> String {
        guard let n = node["net"] else { return "" }
        return (n.items.count >= 3 ? n.text(at: 1) : n.text(at: 0)) ?? ""
    }

    private mutating func read() {
        for node in board.root.items {
            switch node.head ?? "" {
            case "segment", "arc":
                var t = Track(kind: node.head == "arc" ? .arc : .track, uuid: node.value("uuid") ?? "", net: Self.netName(node))
                t.hasNet = node["net"] != nil
                t.start = BoardWorld.point(node["start"])
                t.mid = BoardWorld.point(node["mid"])
                t.end = BoardWorld.point(node["end"])
                t.width = node["width"].map { BoardWorld.iu($0, 0) } ?? 0
                t.layer = BoardWorld.itemLayer(node) ?? ""
                tracks.append(t)
            case "via":
                var t = Track(kind: .via, uuid: node.value("uuid") ?? "", net: Self.netName(node))
                t.hasNet = node["net"] != nil
                t.start = BoardWorld.point(node["at"])
                t.end = t.start
                t.diameter = node["size"].map { BoardWorld.iu($0, 0) } ?? 0
                t.drill = node["drill"].map { BoardWorld.iu($0, 0) } ?? 0
                let ls = (node["layers"]?.arguments.map(\.text) ?? ["F.Cu", "B.Cu"]).compactMap { world.layerIndex[$0] }
                t.layers = LayerRange(ls.min() ?? 0, ls.max() ?? world.copperLayers - 1)
                for arg in node.arguments where arg.kind == .symbol {
                    switch arg.text {
                    case "blind": t.viaType = .blind
                    case "buried": t.viaType = .buried
                    case "micro": t.viaType = .microVia
                    default: break
                    }
                }
                t.unconnectedLayers = UnconnectedLayerMode(node)
                t.free = node.value("free") == "yes"
                tracks.append(t)
            default:
                break
            }
        }
        for fp in board.root.all("footprint") {
            let placement = BoardWorld.FootprintPlacement(fp)
            let pads = fp.all("pad").map { node in
                Pad(uuid: node.value("uuid") ?? "", number: node.text(at: 0) ?? "", net: Self.netName(node),
                    pad: world.readPad(node, placement),
                    primitives: (node["primitives"]?.arguments ?? []).filter { $0.head != "gr_bbox" && $0.head != "gr_vector" },
                    pinType: node.value("pintype") ?? "", unconnectedLayers: UnconnectedLayerMode(node))
            }
            var footprint = Footprint(reference: placement.reference, pads: pads)
            footprint.duplicatePadNumbersAreJumpers = fp.value("duplicate_pad_numbers_are_jumpers") == "yes"
            footprint.jumperPadGroups = (fp["jumper_pad_groups"]?.arguments ?? []).map { Set($0.items.map(\.text)) }
            footprints.append(footprint)
        }
    }

    // MARK: - Running the checks

    /// The violations KiCad's DRC would find, those of each check in the order KiCad's finds them
    public func run() -> [DRCViolation] { runReport().violations }

    /// The check's report, with what it found that KiCad may or may not (`unsure`); `limited` false, each check's
    /// violations all, past KiCad's limit; the checks of `exhausted` as if at their limit from the start
    func runReport(limited: Bool = true, exhausted: Set<String> = []) -> Report {
        var out = Report(settings: settings, limited: limited, exhausted: exhausted)
        // (the board's copper items, which the rules evaluate, and the connectivity, built first, as KiCad builds it as
        // it reads the board: the nets it propagates are the items' nets for the checks)
        let copper = makeCopper()
        ruleState.copper = copper
        let connectivity = buildConnectivity(copper)
        // (the board's items of every kind, for the silkscreen's checks and the rules', and its outline as KiCad's cache
        // generator makes it)
        let items = boardItems(copper)
        let outline = SilkOutline(boardOutline())
        checkTrackWidths(&out, copper)
        checkViaDiameters(&out, copper)
        checkHoleSizes(&out, copper)
        checkAnnularWidths(&out, copper)
        checkHolesToHoles(&out, copper)
        // (the miscellaneous checks': the board's outline, the rules' assertions)
        checkOutline(&out)
        checkAssertions(&out, copper, items)
        checkCopperClearances(&out, copper)
        checkEdgeClearances(&out, copper, items, outline)
        // (by the rules engine where the board has rules of the user's own: their disallows among the keepouts', and the
        // collisions with areas its functions keep shared with theirs)
        if ruleState.hasUserRules || Self.disallowByEngine {
            checkDisallowRules(&out, copper, items)
        } else {
            checkKeepouts(&out, copper)
        }
        checkCourtyards(&out, copper)
        checkSilkToMask(&out, items)
        checkSolderMask(&out, copper)
        checkSilkClearances(&out, items, outline)
        checkConnectivity(&out, copper, connectivity)
        checkZoneConnections(&out, copper, connectivity)
        checkSlivers(&out, copper)
        // (each violation's items as KiCad's report names them)
        let named = reportableItems()
        for i in out.violations.indices { out.violations[i].items = out.violations[i].items.filter(named.contains) }
        for (type, sets) in out.unsure { out.unsure[type] = sets.map { $0.intersection(named) }.filter { !$0.isEmpty } }
        return out
    }

    /// The violations found so far, each check's up to KiCad's limit, those of checks set to be ignored left out
    /// (DRC_ENGINE::ReportViolation and the severities KiCad's markers are given)
    struct Report {
        let settings: Settings
        var limited = true
        var exhausted: Set<String> = []
        var violations: [DRCViolation] = []
        /// The items of violations KiCad may or may not find, by the order its threads happen to meet them in (a
        /// solder mask bridge of a footprint allowing them tried one way round and not the other, or an aperture
        /// claimed by the first net to reach it) or the order its items happen to be in memory (silkscreen across a
        /// corner of the board's two drawings meet at): by check, each a set of uuids, a violation with all of them
        /// unsure
        var unsure: [String: [Set<String>]] = [:]
        var counts: [String: Int] = [:]

        mutating func addUnsure(_ type: String, _ items: Set<String>) { unsure[type, default: []].append(items) }

        /// Whether KiCad may or may not find a violation of `type` between `items`
        func isUnsure(_ type: String, _ items: [String]) -> Bool {
            unsure[type]?.contains { $0.isSubset(of: items) } ?? false
        }

        /// IsErrorLimitExceeded: whether as many of a check have been found as KiCad reports
        func exceeded(_ type: String) -> Bool {
            exhausted.contains(type) || (limited && counts[type, default: 0] >= BoardDRC.errorLimit(type))
        }

        /// The severity of a violation (PCB_MARKER::GetSeverity: the violated rule's, if it sets one, else the check's)
        func severity(_ type: String, _ rule: DesignRule?) -> String {
            if let r = rule, r.severity != .undefined { return r.severity.rawValue }
            return settings.severity(type)
        }

        /// A violation reported in words of its own (DRC_ITEM::SetErrorMessage)
        mutating func addMessage(_ type: String, _ message: String, _ items: [String], rule: DesignRule? = nil) {
            guard settings.severity(type) != "ignore", !exceeded(type) else { return }
            counts[type, default: 0] += 1
            // (one a rule makes ignored or excluded counts, but is not in the report)
            let s = severity(type, rule)
            guard s == "error" || s == "warning" else { return }
            violations.append(DRCViolation(type: type, severity: s, description: message, items: items))
        }

        mutating func add(_ type: String, _ detail: String?, _ items: [String], rule: DesignRule? = nil) {
            guard settings.severity(type) != "ignore", !exceeded(type) else { return }
            counts[type, default: 0] += 1
            let s = severity(type, rule)
            guard s == "error" || s == "warning" else { return }
            let title = BoardDRC.titles[type] ?? type
            violations.append(DRCViolation(type: type, severity: s,
                                           description: detail.map { "\(title) \($0)" } ?? title, items: items))
        }
    }

    // MARK: - Messages

    /// A length as KiCad's DRC messages give it (MessageTextFromValue, in millimetres: one too small for its digits,
    /// all zeros, in scientific notation)
    static func messageText(_ v: Int) -> String {
        let value = Double(v) / 1e6
        let text = String(format: "%.4f", value)
        if value != 0 && !text.contains(where: { $0 >= "1" && $0 <= "9" }) { return String(format: "%.3e mm", value) }
        return text + " mm"
    }

    /// A length as KiCad gives it more precisely (StringFromValue, in millimetres)
    static func stringFromValue(_ v: Int) -> String {
        let value = Double(v) / 1e6
        func trimmed(_ s: String) -> String {
            var chars = Array(s)
            var len = chars.count
            var remove = 0
            len -= 1
            while len > 0 && chars[len] == "0" {
                remove += 1
                len -= 1
            }
            if len >= 0 && (chars[len] == "." || chars[len] == ",") { remove += 1 }
            chars.removeLast(remove)
            return String(chars)
        }
        var text = trimmed(String(format: "%.10f", value))
        if value != 0 && (text == "0" || text == "-0") { text = trimmed(String(format: "%.10f", value)) }
        return text + " mm"
    }

    /// formatMsg: a message with the rule's value and the actual one, the two more precise if they read the same
    static func formatMsg(_ format: (String, String, String) -> String, _ source: String, _ constraint: Int, _ actual: Int) -> String {
        var c = messageText(constraint), a = messageText(actual)
        if c == a {
            c = stringFromValue(constraint)
            a = stringFromValue(actual)
        }
        return format(source, c, a)
    }

    /// The name KiCad gives a minimum of its implicit rules
    static let boardSetup = "board setup constraints"

    // MARK: - Track widths (DRC_TEST_PROVIDER_TRACK_WIDTH)

    func checkTrackWidths(_ out: inout Report, _ c: Copper) {
        let engine = ruleState.engine
        guard !out.exceeded("track_width"), engine.hasRules(.trackWidth) else { return }
        for t in c.tracks where t.kind != .via {
            guard !out.exceeded("track_width") else { break }
            let item = ruleItem(t, c)
            let constraint = engine.evalRules(.trackWidth, item, nil, layer: item.layer)
            let actual = t.trackWidth
            var failMin = false, failMax = false, width = 0
            if constraint.severity != .ignore {
                if constraint.value.hasMin && actual < constraint.value.min { (failMin, width) = (true, constraint.value.min) }
                if constraint.value.hasMax && actual > constraint.value.max { (failMax, width) = (true, constraint.value.max) }
            }
            guard failMin || failMax else { continue }
            let name = failMin && constraint.implicitMin ? Self.boardSetup : constraint.ruleName
            // (both failing: the min message, with the max)
            let detail = failMin ? Self.formatMsg({ "(\($0) min width \($1); actual \($2))" }, name, width, actual)
                                 : Self.formatMsg({ "(\($0) max width \($1); actual \($2))" }, name, width, actual)
            out.add("track_width", detail, [t.uuid], rule: constraint.parentRule)
        }
    }

    // MARK: - Via diameters (DRC_TEST_PROVIDER_VIA_DIAMETER)

    func checkViaDiameters(_ out: inout Report, _ c: Copper) {
        let engine = ruleState.engine
        guard !out.exceeded("via_diameter"), engine.hasRules(.viaDiameter) else { return }
        for t in c.tracks where t.kind == .via {
            guard !out.exceeded("via_diameter"), let v = t.via else { break }
            // (a via of one padstack: its one layer, F.Cu)
            let constraint = engine.evalRules(.viaDiameter, ruleItem(t, c), nil, layer: KiLayer.fCu)
            let actual = v.diameter
            var failMin = false, failMax = false, diameter = 0
            if constraint.severity != .ignore {
                if constraint.value.hasMin && actual < constraint.value.min { (failMin, diameter) = (true, constraint.value.min) }
                if constraint.value.hasMax && actual > constraint.value.max { (failMax, diameter) = (true, constraint.value.max) }
            }
            guard failMin || failMax else { continue }
            let detail: String
            if failMin {
                let name = constraint.implicitMin ? Self.boardSetup : constraint.ruleName
                detail = Self.formatMsg({ "(\($0) min diameter \($1); actual \($2))" }, name, diameter, actual)
            } else {
                detail = Self.formatMsg({ "(\($0) max diameter \($1); actual \($2))" }, constraint.ruleName, diameter, actual)
            }
            out.add("via_diameter", detail, [t.uuid], rule: constraint.parentRule)
        }
    }

    // MARK: - Hole sizes (DRC_TEST_PROVIDER_HOLE_SIZE)

    func checkHoleSizes(_ out: inout Report, _ c: Copper) {
        let engine = ruleState.engine
        if !out.exceeded("drill_out_of_range") {
            for pads in c.footprintPads {
                for pad in pads {
                    guard !out.exceeded("drill_out_of_range"), let p = pad.pad else { continue }
                    let holeMinor = min(p.pad.drill.x, p.pad.drill.y), holeMajor = max(p.pad.drill.x, p.pad.drill.y)
                    if holeMinor == 0 { continue }
                    // (holes are not layer-specific)
                    let constraint = engine.evalRules(.holeSize, ruleItem(pad, c), nil, layer: KiLayer.undefined)
                    if constraint.severity == .ignore { continue }
                    var failMin = false, failMax = false, value = 0
                    if constraint.value.hasMax && holeMajor > constraint.value.max { (failMax, value) = (true, constraint.value.max) }
                    if constraint.value.hasMin && holeMinor < constraint.value.min { (failMin, value) = (true, constraint.value.min) }
                    guard failMin || failMax else { continue }
                    let detail: String
                    if failMin {
                        let name = constraint.parentRule?.isImplicit == true ? Self.boardSetup : constraint.ruleName
                        detail = Self.formatMsg({ "(\($0) min hole \($1); actual \($2))" }, name, value, holeMinor)
                    } else {
                        detail = Self.formatMsg({ "(\($0) max hole \($1); actual \($2))" }, constraint.ruleName, value, holeMajor)
                    }
                    out.add("drill_out_of_range", detail, [pad.uuid], rule: constraint.parentRule)
                }
            }
        }
        guard !out.exceeded("microvia_drill_out_of_range") || !out.exceeded("drill_out_of_range") else { return }
        for t in c.tracks where t.kind == .via {
            guard let v = t.via else { continue }
            let exceedMicro = out.exceeded("microvia_drill_out_of_range"), exceedStd = out.exceeded("drill_out_of_range")
            if exceedMicro && exceedStd { break }
            let micro = v.viaType == .microVia
            if micro ? exceedMicro : exceedStd { continue }
            let constraint = engine.evalRules(.holeSize, ruleItem(t, c), nil, layer: KiLayer.undefined)
            if constraint.severity == .ignore { continue }
            var failMin = false, failMax = false, value = 0
            if constraint.value.hasMin && v.drill < constraint.value.min { (failMin, value) = (true, constraint.value.min) }
            if constraint.value.hasMax && v.drill > constraint.value.max { (failMax, value) = (true, constraint.value.max) }
            guard failMin || failMax else { continue }
            let detail: String
            if failMin {
                let name = constraint.implicitMin ? Self.boardSetup : constraint.ruleName
                detail = Self.formatMsg({ "(\($0) min hole \($1); actual \($2))" }, name, value, v.drill)
            } else {
                detail = Self.formatMsg({ "(\($0) max hole \($1); actual \($2))" }, constraint.ruleName, value, v.drill)
            }
            out.add(micro ? "microvia_drill_out_of_range" : "drill_out_of_range", detail, [t.uuid], rule: constraint.parentRule)
        }
    }

    // MARK: - Annular widths (DRC_TEST_PROVIDER_ANNULAR_WIDTH)

    func checkAnnularWidths(_ out: inout Report, _ c: Copper) {
        let engine = ruleState.engine
        guard !out.exceeded("annular_width"), engine.hasRules(.annularWidth) else { return }
        func check(_ constraint: DRCConstraint, _ width: Int, _ uuid: String) {
            guard constraint.severity != .ignore else { return }
            var failMin = false, failMax = false
            if constraint.value.hasMin { failMin = width < constraint.value.min }
            if constraint.value.hasMax { failMax = width > constraint.value.max }
            guard failMin || failMax else { return }
            // (both failing: the max message)
            let detail = failMax
                ? Self.formatMsg({ "(\($0) max annular width \($1); actual \($2))" }, constraint.ruleName, constraint.value.max, width)
                : Self.formatMsg({ "(\($0) min annular width \($1); actual \($2))" }, constraint.ruleName, constraint.value.min, width)
            out.add("annular_width", detail, [uuid], rule: constraint.parentRule)
        }
        for t in c.tracks where t.kind == .via {
            guard !out.exceeded("annular_width"), let v = t.via else { break }
            let constraint = engine.evalRules(.annularWidth, ruleItem(t, c), nil, layer: KiLayer.fCu)
            let a = v.start - IPoint(v.drill / 2, 0), b = v.start - IPoint(v.diameter / 2, 0)
            check(constraint, (a - b).norm, t.uuid)
        }
        for (i, fp) in footprints.enumerated() {
            for (j, p) in fp.pads.enumerated() where p.hasHole && p.pad.attribute == .pth {
                guard !out.exceeded("annular_width") else { return }
                let constraint = engine.evalRules(.annularWidth, ruleItem(c.footprintPads[i][j], c), nil, layer: KiLayer.fCu)
                // (FOOTPRINT::GetPads: the footprint's other pads of the number, none for a pad with no number)
                let sameNumber = p.number.isEmpty ? [] : fp.pads.filter { $0.number == p.number && $0.uuid != p.uuid }
                guard let (a, b) = padAnnulusPoints(p, sameNumber, constraint.value) else { continue }
                check(constraint, (a - b).norm, p.uuid)
            }
        }
    }

    /// The pad's bounding box (PAD::GetBoundingBox: its shapes' and its hole's)
    func boundingBox(_ p: Pad) -> IBox {
        var shapes = world.effectiveShapes(p.pad)
        if p.pad.kind == .custom, let poly = world.padPolygon(p.pad, primitives: p.primitives, errorLocation: .inside) {
            shapes = poly.polygons.map { .simple($0[0]) }
        }
        if p.hasHole { shapes.append(world.holeShape(p.pad)) }
        var box = shapes.first?.bbox ?? IBox(p.pad.pos, p.pad.pos)
        for s in shapes.dropFirst() { box.merge(s.bbox) }
        return box
    }

    /// PAD::IsOnLayer for F.Cu: the layer the annular ring is checked on (each layer of a pad of one padstack)
    func onFront(_ p: Pad) -> Bool { p.pad.layers.contains("F.Cu") || p.pad.layers.contains("*.Cu") || p.pad.layers.contains("F&B.Cu") }

    /// Where a through-hole pad's annular ring is narrowest (getPadAnnulusPts), nil where KiCad takes it as wide enough
    /// without measuring
    func padAnnulusPoints(_ p: Pad, _ sameNumber: [Pad], _ value: MinOptMax) -> (IPoint, IPoint)? {
        let pad = p.pad
        var a = IPoint.zero, b = IPoint.zero
        var handled = false
        if pad.offset == .zero {
            let xDist = KiMath.round(Double(pad.size.x - pad.drill.x) / 2.0)
            let yDist = KiMath.round(Double(pad.size.y - pad.drill.y) / 2.0)
            if yDist < xDist {
                a = pad.pos - IPoint(0, pad.drill.y / 2)
                b = pad.pos - IPoint(0, pad.size.y / 2)
            } else {
                a = pad.pos - IPoint(pad.drill.x / 2, 0)
                b = pad.pos - IPoint(pad.size.x / 2, 0)
            }
            a = KiMath.rotate(a, around: pad.pos, pad.orientation)
            b = KiMath.rotate(b, around: pad.pos, pad.orientation)
            switch pad.kind {
            case .chamferedRect: handled = pad.chamferRatio <= 0.30
            case .circle, .oval, .rect, .roundrect: handled = true
            default: handled = false
            }
        }
        let box = boundingBox(p)
        let overlapping = sameNumber.filter { onFront($0) && box.intersects(boundingBox($0)) }
        // (same-numbered pads only add copper: the slow way only if one covers this pad, or its hole cuts into it)
        var constrainingHole = false, covers = false
        for o in overlapping {
            let ob = boundingBox(o)
            if ob.contains(box) { covers = true }
            if o.hasHole && box.intersects(world.holeShape(o.pad).bbox) { constrainingHole = true }
            if covers && constrainingHole { break }
        }
        if handled && !overlapping.isEmpty && !constrainingHole && !covers && value.hasMin && !value.hasMax {
            // a circle's ring is as wide all round, so its quick width holds where any side is uncovered; another's
            // narrow side a pad of the number can make up for, so its quick width is taken only if it passes
            if pad.kind == .circle || (a - b).norm >= value.min { return (a, b) }
        }
        if !handled || !overlapping.isEmpty {
            // the general way: the pad's outline (with its same-numbered pads', less their holes) against its hole
            let maxError = world.rules.maxError
            guard var outline = world.padPolygon(pad, primitives: p.primitives, errorLocation: .inside) else { return nil }
            guard case .segment(let slot, let slotWidth) = world.holeShape(pad) else { return nil }
            // (with pads of the number and no minimum, the points as they were)
            if !sameNumber.isEmpty && !value.hasMin { return (a, b) }
            if !sameNumber.isEmpty {
                var otherHoles = PolySet()
                for o in sameNumber {
                    guard let poly = world.padPolygon(o.pad, primitives: o.primitives, errorLocation: .outside) else { return nil }
                    outline.append(poly)
                    if o.hasHole, case .segment(let s, let w) = world.holeShape(o.pad) {
                        otherHoles.append(PadPolygon.oval(start: s.a, end: s.b, width: w, maxError: maxError, errorLocation: .inside))
                    }
                }
                outline.booleanSubtract(otherHoles)
            }
            if !Self.collides(outline, pad.pos) {
                // (the hole outside the pad)
                return (pad.pos, pad.pos)
            }
            return Self.nearestPoints(outline, slot, slotWidth)
        }
        return (a, b)
    }

    /// Whether a point is in a polygon set, or on its edge (SHAPE_POLY_SET::Collide with no clearance)
    static func collides(_ set: PolySet, _ p: IPoint) -> Bool {
        for poly in set.polygons {
            // (SquaredDistanceToPolygon: inside the outline, within a nanometre of its edge, and not in a hole)
            if poly[0].pointInside(p, accuracy: 1) && !poly.dropFirst().contains(where: { $0.pointInside(p) }) { return true }
            for chain in poly {
                for i in 0..<chain.segmentCount where chain.segment(i).squaredDistance(p) == 0 { return true }
            }
        }
        return false
    }

    /// The nearest points of a polygon set's edges (holes' too) and a slot (SHAPE::NearestPoints of a SHAPE_POLY_SET
    /// and a SHAPE_SEGMENT): on the edge, and on the slot's outline
    static func nearestPoints(_ set: PolySet, _ slot: Seg, _ slotWidth: Int) -> (IPoint, IPoint)? {
        var best: (IPoint, IPoint)?
        var bestDist = Int.max
        for poly in set.polygons {
            for chain in poly {
                for i in 0..<chain.segmentCount {
                    let seg = chain.segment(i)
                    var a = seg.nearestPoint(slot)
                    var b = slot.nearestPoint(a)
                    a = a + (b - a).resized(0)
                    b = b + (a - b).resized(slotWidth / 2)
                    let d = (b - a).squaredNorm
                    if d < bestDist {
                        bestDist = d
                        best = (a, b)
                    }
                }
            }
        }
        return best
    }

    // MARK: - Holes too close (DRC_TEST_PROVIDER_HOLE_TO_HOLE)

    func checkHolesToHoles(_ out: inout Report, _ c: Copper) {
        guard !out.exceeded("hole_to_hole") || !out.exceeded("holes_co_located") else { return }
        let engine = ruleState.engine
        // (the worst hole to hole clearance the tree's search goes out to; none above 0, no check at all)
        guard let worst = engine.worstConstraint(.holeToHole) else { return }
        let largest = worst.value.min
        // the holes drilled: round pad holes and vias' (slots are milled after)
        struct Hole {
            var item: CopperItem
            var center: IPoint
            var radius: Int
            var via: Track?
        }
        var holes: [Hole] = []
        for pads in c.footprintPads {
            for pad in pads {
                guard let p = pad.pad, p.hasDrilledHole else { continue }
                holes.append(Hole(item: pad, center: p.pad.pos, radius: p.pad.drill.x / 2, via: nil))
            }
        }
        for t in c.tracks where t.kind == .via {
            guard let v = t.via else { continue }
            holes.append(Hole(item: t, center: v.start, radius: v.drill / 2, via: v))
        }
        let epsilon = settings.epsilon
        func test(_ h: Hole, _ o: Hole) {
            // blind and buried vias are drilled before the board is laminated: only those that share layers
            if let a = h.via, let b = o.via, !a.layers.overlaps(b.layers) { return }
            var first = h.item.uuid, second = o.item.uuid
            if first > second { swap(&first, &second) }
            let d = h.center - o.center
            if d.squaredNorm < epsilon * epsilon {
                out.add("holes_co_located", nil, [first, second])
                return
            }
            guard !out.exceeded("hole_to_hole") else { return }
            let actual = max(0, d.norm - h.radius - o.radius)
            // (holes pierce all layers)
            let constraint = engine.evalRules(.holeToHole, ruleItem(h.item, c), ruleItem(o.item, c), layer: KiLayer.undefined)
            let minClearance = constraint.value.min
            guard constraint.severity != .ignore && minClearance >= 0 && actual < max(0, minClearance - epsilon) else { return }
            out.add("hole_to_hole", Self.formatMsg({ "(\($0) min \($1); actual \($2))" }, constraint.ruleName, minClearance, actual),
                    [first, second], rule: constraint.parentRule)
        }
        // (the holes within the worst hole to hole clearance of each other, as the R-tree finds them)
        func near(_ h: Hole, _ o: Hole) -> Bool {
            let r = h.radius + o.radius + largest
            return (h.center - o.center).squaredNorm < r * r
        }
        // each via's hole against the others (not a micro via's, burned, not drilled), each pair once; then each pad's
        var checked = Set<[String]>()
        for h in holes where h.via != nil && h.via!.viaType != .microVia {
            for o in holes where o.item !== h.item && near(h, o) && checked.insert([h.item.uuid, o.item.uuid].sorted()).inserted { test(h, o) }
        }
        checked.removeAll()
        for h in holes where h.via == nil {
            for o in holes where o.item !== h.item && near(h, o) && checked.insert([h.item.uuid, o.item.uuid].sorted()).inserted { test(h, o) }
        }
    }
}
