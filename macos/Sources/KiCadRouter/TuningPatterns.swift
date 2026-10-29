// Length tunings kept in the board as KiCad keeps them: tuning patterns (PCB_TUNING_PATTERN, a generator: the
// meandered tracks its members, its settings and the line it was placed over in its properties), written and read
// as KiCad writes and reads them (PCB_IO_KICAD_SEXPR::format( PCB_GENERATOR ) and parseGENERATOR; the pattern's
// GetProperties and SetProperties), and made, edited and taken away as KiCad's generator tool drives them
// (EditStart, Update, EditFinish, EditCancel, Remove, with initBaseLines, resetToBaseline, removeToBaseline,
// recoverBaseline and getOutline), started as its Tune Length tool starts one (CreateNew, DRAWING_TOOL::
// PlaceTuningPattern), its end dragged as its point editor drags it
// (pcbnew/generators/pcb_tuning_pattern.cpp and .h, pcbnew/pcb_generator.cpp, pcbnew/tools/generator_tool.cpp,
// generator_tool_pns_proxy.cpp, pcbnew/board_commit.cpp (a removed item leaves its group),
// pcbnew/board_design_settings.cpp (tuning_pattern_settings), pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr.cpp and
// pcb_io_kicad_sexpr_parser.cpp, include/string_any_map.h, KiCad 10.0.7).
// Copyright (C) 2023 Alex Shvartzkop; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// A length tuning kept in the board (KiCad's PCB_TUNING_PATTERN, a `(generated (type tuning_pattern) ...)`): the
/// meandered tracks its members, the line it was placed over (its base line, and a pair's other line's), where it
/// starts and ends, the settings it was tuned with and what the tuning came to
public struct TuningPattern: Sendable {
    /// What it tunes (KiCad's LENGTH_TUNING_MODE): a track's length, a differential pair's, or a pair's skew
    public enum Mode: String, Sendable {
        case single = "single"
        case diffPair = "diff_pair"
        case skew = "diff_pair_skew"

        var routerMode: Router.Mode {
            switch self {
            case .single: return .tuneSingle
            case .diffPair: return .tuneDiffPair
            case .skew: return .tuneDiffPairSkew
            }
        }

        public init(_ mode: BoardRouter.TuningMode) {
            switch mode {
            case .single: self = .single
            case .diffPair: self = .diffPair
            case .skew: self = .skew
            }
        }

        public var tuningMode: BoardRouter.TuningMode {
            switch self {
            case .single: return .single
            case .diffPair: return .diffPair
            case .skew: return .skew
            }
        }
    }

    public typealias Status = MeanderPlacerBase.TuningStatus

    public static let generatorType = "tuning_pattern"
    public static let displayName = "Tuning Pattern"

    public var uuid: String
    public var name = TuningPattern.displayName
    /// Its layer (the layer of its first member that is a track, as KiCad writes it, else its own)
    public var layer = "F.Cu"
    public var locked = false
    public var origin = IPoint.zero
    public var end = IPoint(10_000_000, 0)
    /// What it tunes to and how (the target length or skew and its tolerance, the meanders' amplitudes, spacing,
    /// corners and sides)
    public var settings: MeanderSettings
    /// The time domain's targets (the delay to reach), kept as they are read: the port tunes lengths alone
    public var targetDelay = (min: 0, opt: TuningPattern.delayUnconstrained, max: TuningPattern.delayUnconstrained)
    public var isTimeDomain = false
    /// The line the meanders were placed over, from origin to end (and a differential pair's other line's)
    public var baseLine: LineChain?
    public var baseLineCoupled: LineChain?
    /// The width of its tracks and a pair's gap, as the last tuning had them (0: taken from the line tuned)
    public var trackWidth = 0
    public var diffPairGap = 0
    public var mode = Mode.single
    /// The net it tuned, and what its tuning came to (its length, a skew tuning's skew), as the last tuning left them
    public var lastNetName = ""
    public var tuningLength = 0
    public var status = Status.tuned
    /// Its meandered tracks, by uuid
    public var members: [String] = []

    /// Its side set again from where its end is, once, at the next EditStart (UpdateSideFromEnd)
    var updateSideFromEnd = false
    /// The width of the line tuned, its tracks outside the pattern given it back (m_assembledLineWidth)
    var assembledLineWidth = 0
    /// Not yet on the board (IS_NEW)
    var isNew = false
    /// Being edited (IN_EDIT)
    var inEdit = false

    /// KiCad's MEANDER_SETTINGS::DELAY_UNCONSTRAINED and DEFAULT_DELAY_TOLERANCE, in its internal units of time
    public static let delayUnconstrained = 1_000_000 * 1_000_000
    static let defaultDelayTolerance = 100_000

    /// A pattern as KiCad's constructor makes one: KiCad's default settings, starting on the left (PCB_TUNING_PATTERN())
    public init(uuid: String = KiCadBoard.newUUID(), mode: Mode = .single, layer: String = "F.Cu") {
        self.uuid = uuid
        self.mode = mode
        self.layer = layer
        settings = MeanderSettings()
        settings.initialSide = .left
    }

    // MARK: - Settings by default (BOARD_DESIGN_SETTINGS' meander settings, its project's tuning_pattern_settings)

    /// The settings a new pattern of `mode` starts with: KiCad's defaults (a pair's meanders 1 mm apart, a track's
    /// 0.6 mm), as the board's project changes them (board.design_settings.tuning_pattern_settings)
    public static func defaultSettings(_ mode: Mode, project: [String: Any]?) -> MeanderSettings {
        var s = MeanderSettings()
        s.spacing = mode == .diffPair ? 1_000_000 : 600_000
        let key = mode == .single ? "single_track_defaults" : mode == .diffPair ? "diff_pair_defaults" : "diff_pair_skew_defaults"
        let design = (project?["board"] as? [String: Any])?["design_settings"] as? [String: Any]
        guard let entry = (design?["tuning_pattern_settings"] as? [String: Any])?[key] as? [String: Any] else { return s }
        // (read_settings: KiCad's defaults for what the entry does not say, a pair's spacing among them)
        s = MeanderSettings()
        func mm(_ v: Any?) -> Int? { (v as? NSNumber).map { KiMath.round($0.doubleValue * 1_000_000) } }
        if let v = mm(entry["min_amplitude"]) { s.minAmplitude = v }
        if let v = mm(entry["max_amplitude"]) { s.maxAmplitude = v }
        if let v = mm(entry["spacing"]) { s.spacing = v }
        if let v = entry["corner_style"] as? NSNumber { s.cornerStyle = v.intValue == 0 ? .chamfer : .round }
        if let v = entry["corner_radius_percentage"] as? NSNumber { s.cornerRadiusPercentage = v.intValue }
        if let v = entry["single_sided"] as? Bool { s.singleSided = v }
        return s
    }

    // MARK: - Reading (parseGENERATOR, then SetProperties)

    /// A property's value as KiCad's parser keeps it (a wxAny of a bool, a double, a string, a point or a chain)
    enum Value {
        case bool(Bool), number(Double), string(String), point(IPoint), chain(LineChain)
    }

    /// The pattern a board's `(generated ...)` holds, as KiCad reads it; nil if it is not a tuning pattern (or one
    /// KiCad's parser drops: of no members)
    public init?(_ node: SExpr) {
        guard node.head == "generated" else { return nil }
        var type = "", uuid = "", name = "", layer = "F.Cu", locked = false
        var members: [String] = []
        var props: [String: Value] = [:]
        for item in node.arguments where item.kind == .list {
            guard let head = item.head else { continue }
            switch head {
            case "uuid", "id": uuid = item.text(at: 0) ?? ""
            case "type": type = item.text(at: 0) ?? ""
            case "name": name = item.text(at: 0) ?? ""
            case "locked": locked = item.text(at: 0) == "yes"
            case "layer": layer = item.text(at: 0) ?? layer
            case "members": members += item.arguments.filter { $0.kind != .list }.map(\.text)
            default:
                // (the first of a name kept, as std::map's emplace keeps it)
                guard props[head] == nil, item.items.count >= 2 else { continue }
                let v = item.items[1]
                switch v.kind {
                case .symbol:
                    if v.text == "yes" {
                        props[head] = .bool(true)
                    } else if v.text == "no" {
                        props[head] = .bool(false)
                    } else if let d = Double(v.text) {
                        props[head] = .number(d)
                    }
                case .string:
                    props[head] = .string(v.text)
                case .list:
                    if v.head == "xy" {
                        props[head] = .point(BoardWorld.point(v))
                    } else if v.head == "pts" {
                        props[head] = .chain(Self.chain(v))
                    }
                }
            }
        }
        // (the 7.99 name too)
        guard type == Self.generatorType || type == "meanders", !members.isEmpty else { return nil }
        self.init(uuid: uuid)
        self.name = name
        self.layer = layer
        self.locked = locked
        self.members = members
        setProperties(props)
    }

    /// A chain as KiCad's parser reads a `(pts ...)`: points, and arcs by their start, middle and end
    /// (parseOutlinePoints)
    static func chain(_ pts: SExpr) -> LineChain {
        var chain = LineChain()
        for p in pts.arguments where p.kind == .list {
            if p.head == "xy" {
                chain.append(BoardWorld.point(p))
            } else if p.head == "arc" {
                chain.append(ShapeArc(start: BoardWorld.point(p["start"]), mid: BoardWorld.point(p["mid"]),
                                      end: BoardWorld.point(p["end"]), width: 0))
            }
        }
        return chain
    }

    /// KiCad's SetProperties: each property as the pattern takes it, a length in millimetres made nanometres cut
    /// toward 0 (get_to_iu), a property not given left as it was (a target delay not given taking the target
    /// length's number, as KiCad's variable it reads them through keeps it)
    mutating func setProperties(_ props: [String: Value]) {
        func string(_ k: String) -> String { if case .string(let s)? = props[k] { return s }; return "" }
        func bool(_ k: String) -> Bool? { if case .bool(let b)? = props[k] { return b }; return nil }
        func number(_ k: String) -> Double? { if case .number(let d)? = props[k] { return d }; return nil }
        func iu(_ k: String) -> Int? { number(k).map { Int(($0 * 1_000_000).rounded(.towardZero)) } }
        if case .point(let p)? = props["origin"] { origin = p }
        mode = Mode(rawValue: string("tuning_mode")) ?? .single
        switch string("initial_side") {
        case "left": settings.initialSide = .left
        case "right": settings.initialSide = .right
        default: settings.initialSide = .default
        }
        switch string("last_status") {
        case "too_long": status = .tooLong
        case "too_short": status = .tooShort
        default: status = .tuned
        }
        if let b = bool("is_time_domain") { isTimeDomain = b }
        if case .point(let p)? = props["end"] { end = p }
        if let d = number("corner_radius_percent") { settings.cornerRadiusPercentage = Int(d.rounded(.towardZero)) }
        if let b = bool("single_sided") { settings.singleSided = b }
        settings.cornerStyle = (bool("rounded") ?? false) ? .round : .chamfer
        // (one variable for the target length and delay, as KiCad has: nothing given, it holds what it held; KiCad's
        // starts undefined, taken here as 0)
        var val = 0
        if let v = iu("target_length") { val = v }
        settings.setTargetLength(val)
        if let v = iu("target_length_min") { settings.targetLength.min = v }
        if let v = iu("target_length_max") { settings.targetLength.max = v }
        if let v = iu("target_delay") { val = v }
        setTargetDelay(val)
        if let v = iu("target_delay_min") { targetDelay.min = v }
        if let v = iu("target_delay_max") { targetDelay.max = v }
        var intVal = 0
        if let v = iu("target_skew") { intVal = Int(Int32(truncatingIfNeeded: v)) }
        settings.setTargetSkew(intVal)
        if let v = iu("target_skew_min") { settings.targetSkew.min = Int(Int32(truncatingIfNeeded: v)) }
        if let v = iu("target_skew_max") { settings.targetSkew.max = Int(Int32(truncatingIfNeeded: v)) }
        if let v = iu("max_amplitude") { settings.maxAmplitude = v }
        if let v = iu("min_amplitude") { settings.minAmplitude = v }
        if let v = iu("min_spacing") { settings.spacing = v }
        if let v = iu("last_track_width") { trackWidth = v }
        if let v = iu("last_diff_pair_gap") { diffPairGap = v }
        if let v = iu("last_tuning_length") { tuningLength = v }
        if let b = bool("override_custom_rules") { settings.overrideCustomRules = b }
        if case .string(let s)? = props["last_netname"] { lastNetName = s }
        if case .chain(let c)? = props["base_line"] { baseLine = c }
        if case .chain(let c)? = props["base_line_coupled"] { baseLineCoupled = c }
    }

    /// The delay to reach, KiCad's default tolerance either side (SetTargetLengthDelay)
    mutating func setTargetDelay(_ opt: Int) {
        if opt == Self.delayUnconstrained {
            targetDelay = (0, opt, opt)
        } else {
            targetDelay = (opt - Self.defaultDelayTolerance, opt, opt + Self.defaultDelayTolerance)
        }
    }

    /// The board's tuning patterns, in its file's order (the order KiCad keeps them in as it reads the board)
    public static func all(_ board: KiCadBoard) -> [TuningPattern] {
        board.root.items.compactMap { $0.head == "generated" ? TuningPattern($0) : nil }
    }

    // MARK: - Writing (GetProperties, then PCB_IO_KICAD_SEXPR::format( PCB_GENERATOR ))

    /// A number as KiCad writes a generator's (fmt's {:.10g})
    static func number(_ v: Double) -> SExpr { SExpr(symbol: String(format: "%.10g", v)) }

    /// A length as KiCad writes a generator's (set_iu: millimetres, {:.10g})
    static func length(_ v: Int) -> SExpr { number(Double(v) / 1_000_000) }

    static func xy(_ p: IPoint) -> SExpr {
        SExpr("xy", SExpr(symbol: KiCadNumber.format(BoardRouter.mm(p.x))), SExpr(symbol: KiCadNumber.format(BoardRouter.mm(p.y))))
    }

    /// A chain as KiCad writes one (formatPolyPts): its points, an arc's by its start, middle and end
    static func pts(_ chain: LineChain) -> SExpr {
        func coords(_ p: IPoint) -> [SExprConvertible] {
            [SExpr(symbol: KiCadNumber.format(BoardRouter.mm(p.x))), SExpr(symbol: KiCadNumber.format(BoardRouter.mm(p.y)))]
        }
        var items: [SExprConvertible] = []
        var ii = 0
        while ii < chain.pointCount {
            let ind = chain.arcIndex(ii)
            if ind < 0 {
                items.append(SExpr("xy", coords(chain.points[ii])))
            } else {
                let arc = chain.arcs[ind]
                items.append(SExpr("arc", SExpr("start", coords(arc.start)), SExpr("mid", coords(arc.mid)), SExpr("end", coords(arc.end))))
                repeat { ii += 1 } while ii < chain.pointCount && chain.arcIndex(ii) == ind
                ii -= 1
            }
            ii += 1
        }
        return SExpr("pts", items)
    }

    /// The pattern as KiCad writes it: its uuid, type, name and layer, locked if it is, its properties in the order
    /// of their names (GetProperties' map), its members by their uuids in order
    public var node: SExpr {
        var items: [SExprConvertible] = [SExpr("uuid", uuid), SExpr("type", Keyword(Self.generatorType)), SExpr("name", name),
                                         SExpr("layer", layer)]
        if locked { items.append(SExpr("locked", Keyword("yes"))) }
        func yes(_ b: Bool) -> Keyword { Keyword(b ? "yes" : "no") }
        var props: [(String, SExpr)] = []
        if let baseLine { props.append(("base_line", Self.pts(baseLine))) }
        if let baseLineCoupled { props.append(("base_line_coupled", Self.pts(baseLineCoupled))) }
        let side: String
        switch settings.initialSide {
        case .left: side = "left"
        case .right: side = "right"
        case .default: side = "default"
        }
        let statusText: String
        switch status {
        case .tooLong: statusText = "too_long"
        case .tooShort: statusText = "too_short"
        case .tuned: statusText = "tuned"
        }
        props += [
            ("corner_radius_percent", Self.number(Double(settings.cornerRadiusPercentage))),
            ("end", Self.xy(end)),
            ("initial_side", SExpr(string: side)),
            ("is_time_domain", yes(isTimeDomain).sexpr),
            ("last_diff_pair_gap", Self.length(diffPairGap)),
            ("last_netname", SExpr(string: lastNetName)),
            ("last_status", SExpr(string: statusText)),
            ("last_track_width", Self.length(trackWidth)),
            ("last_tuning_length", Self.length(tuningLength)),
            ("max_amplitude", Self.length(settings.maxAmplitude)),
            ("min_amplitude", Self.length(settings.minAmplitude)),
            ("min_spacing", Self.length(settings.spacing)),
            ("origin", Self.xy(origin)),
            ("override_custom_rules", yes(settings.overrideCustomRules).sexpr),
            ("rounded", yes(settings.cornerStyle == .round).sexpr),
            ("single_sided", yes(settings.singleSided).sexpr),
            ("target_delay", Self.length(targetDelay.opt)),
            ("target_delay_max", Self.length(targetDelay.max)),
            ("target_delay_min", Self.length(targetDelay.min)),
            ("target_length", Self.length(settings.targetLength.opt)),
            ("target_length_max", Self.length(settings.targetLength.max)),
            ("target_length_min", Self.length(settings.targetLength.min)),
            ("target_skew", Self.length(settings.targetSkew.opt)),
            ("target_skew_max", Self.length(settings.targetSkew.max)),
            ("target_skew_min", Self.length(settings.targetSkew.min)),
            ("tuning_mode", SExpr(string: mode.rawValue)),
        ]
        for (key, value) in props { items.append(SExpr(key, value)) }
        items.append(SExpr("members", members.sorted().map { $0 as SExprConvertible }))
        return SExpr("generated", items)
    }

    // MARK: - On the board

    /// The pattern written into `board`: in the place of the generator of its uuid, or among the board's
    /// generators where KiCad sorts them (after its groups, by their members' layers and then their uuids:
    /// BOARD_ITEM::ptr_cmp), the layer it is on taken from its first member that is a track
    /// The pattern written into the board (PCB_IO_KICAD_SEXPR's order: after the board's groups, by layer and uuid),
    /// on the layer of its first track; the pattern as written, and its node
    @discardableResult
    func write(into board: KiCadBoard) -> (pattern: TuningPattern, node: SExpr) {
        var p = self
        if let first = p.members.lazy.compactMap({ uuid in board.copperItems.first { $0.value("uuid") == uuid } })
            .first(where: { $0.head == "segment" || $0.head == "arc" }), let l = first.value("layer") {
            p.layer = l
        }
        let node = p.node
        let items = board.root.items
        if let i = items.firstIndex(where: { $0.head == "generated" && $0.value("uuid") == uuid }) {
            board.root.items[i] = node
            return (p, node)
        }
        let ids = Self.layerIDs(board)
        func key(_ n: SExpr) -> (Int, String) { (ids[n.value("layer") ?? ""] ?? Int.max, n.value("uuid") ?? "") }
        let mine = key(node)
        if let i = items.firstIndex(where: { $0.head == "generated" && key($0) > mine }) {
            board.root.items.insert(node, at: i)
        } else if let last = items.lastIndex(where: { $0.head == "generated" || $0.head == "group" }) {
            board.root.items.insert(node, at: last + 1)
        } else if let first = items.firstIndex(where: { ["embedded_fonts", "embedded_files"].contains($0.head ?? "") }) {
            board.root.items.insert(node, at: first)
        } else {
            board.root.items.append(node)
        }
        return (p, node)
    }

    /// KiCad's layer ids by name, as the board's layer table numbers them
    static func layerIDs(_ board: KiCadBoard) -> [String: Int] {
        var out: [String: Int] = [:]
        for l in board.root["layers"]?.arguments ?? [] where l.kind == .list {
            if let id = l.items.first.flatMap({ Int($0.text) }), let name = l.text(at: 0) { out[name] = id }
        }
        return out
    }

    /// The board's generator of `uuid` taken away
    static func remove(_ uuid: String, from board: KiCadBoard) {
        board.root.items.removeAll { $0.head == "generated" && $0.value("uuid") == uuid }
    }

    /// Tracks and vias taken off the board taken out of the groups and generators they were in, as KiCad's commit
    /// takes them out (BOARD_COMMIT::Push); a tuning pattern left with no members dropped, as KiCad drops it when it
    /// writes the board
    static func leaveGroups(_ board: KiCadBoard, _ removed: Set<String>, memory: TuningPatternMemory? = nil) {
        guard !removed.isEmpty else { return }
        var empty: [SExpr] = []
        for node in board.root.items where node.head == "group" || node.head == "generated" {
            guard let members = node["members"] else { continue }
            let before = members.items.count
            let was = node.head == "generated" ? memory?.pattern(node) : nil
            let head = members.items[0]
            members.items.removeAll { $0 !== head && $0.kind != .list && removed.contains($0.text) }
            if members.items.count != before && members.items.count == 1 && node.head == "generated"
                && (node.value("type") == generatorType || node.value("type") == "meanders") {
                empty.append(node)
            } else if members.items.count != before, var p = was {
                // (the rest of the pattern as KiCad has it)
                p.members.removeAll { removed.contains($0) }
                memory?.remember(p, as: node)
            }
        }
        for node in empty { board.root.remove(node) }
    }

    // MARK: - Its outline (getOutline)

    /// KiCad's ARC_LOW_DEF: how far a rounded outline's corners may be from round
    static let arcLowDef = 20_000

    /// The outline round the pattern's base line its meanders keep within (getOutline): the base line offset by the
    /// meanders' largest amplitude (no less than the least they can have) and half the track's width, a pair's lines'
    /// united; on one side of the line only where they are single-sided. Empty with no base line.
    public var outline: LineChain {
        guard let baseLine else { return LineChain() }
        var clampedMaxAmplitude = settings.maxAmplitude
        var minAllowedAmplitude = 0
        let baselineOffset = mode == .diffPair ? (diffPairGap + trackWidth) / 2 : 0
        if settings.cornerStyle == .round {
            minAllowedAmplitude = baselineOffset + trackWidth
        } else {
            let correction = Int((Double(trackWidth) * Foundation.tan(1 - Foundation.tan(22.5 * Double.pi / 180))).rounded(.towardZero))
            minAllowedAmplitude = baselineOffset + correction
        }
        clampedMaxAmplitude = max(clampedMaxAmplitude, minAllowedAmplitude)
        if settings.singleSided {
            let clBase = baseLine
            if mode != .diffPair {
                let amplitude = clampedMaxAmplitude + KiMath.round(Double(trackWidth) / 2)
                if let (left, right) = clBase.offsetLine(amplitude, .roundAllCorners, maxError: Self.arcLowDef, simplify: true) {
                    var chain = LineChain()
                    chain.append(settings.initialSide.rawValue >= 0 ? right : left)
                    chain.append(clBase.reversed())
                    chain.setClosed(true)
                    return chain
                }
            } else if let clCoupled = baseLineCoupled {
                let amplitude = clampedMaxAmplitude + trackWidth + KiMath.round(Double(diffPairGap) / 2)
                var chain1 = LineChain(), chain2 = LineChain()
                let half = KiMath.round(Double(trackWidth) / 2)
                if let (left, right) = clBase.offsetLine(amplitude, .roundAllCorners, maxError: Self.arcLowDef, simplify: true) {
                    chain1.append(settings.initialSide.rawValue >= 0 ? right : left)
                    if let (l2, r2) = clBase.offsetLine(half, .roundAllCorners, maxError: Self.arcLowDef, simplify: true) {
                        chain1.append(settings.initialSide.rawValue >= 0 ? l2.reversed() : r2.reversed())
                    }
                    chain1.setClosed(true)
                }
                if let (left, right) = clCoupled.offsetLine(amplitude, .roundAllCorners, maxError: Self.arcLowDef, simplify: true) {
                    chain2.append(settings.initialSide.rawValue >= 0 ? right : left)
                    if let (l2, r2) = clCoupled.offsetLine(half, .roundAllCorners, maxError: Self.arcLowDef, simplify: true) {
                        chain2.append(settings.initialSide.rawValue >= 0 ? l2.reversed() : r2.reversed())
                    }
                    chain2.setClosed(true)
                }
                var merged = PolySet()
                var a = PolySet(), b = PolySet()
                if chain1.pointCount > 0 { _ = a.addOutline(chain1) }
                if chain2.pointCount > 0 { _ = b.addOutline(chain2) }
                merged = a
                merged.booleanAdd(b)
                if merged.outlineCount > 0 { return merged.polygons[0][0] }
            }
        }
        // (not single-sided, or what that could not make)
        var poly = PolySet()
        let amplitude = mode == .diffPair ? clampedMaxAmplitude + diffPairGap / 2 + trackWidth
            : clampedMaxAmplitude + KiMath.round(Double(trackWidth) / 2)
        poly.offsetLineChain(baseLine, amplitude, .roundAllCorners, maxError: Self.arcLowDef)
        if mode == .diffPair, let baseLineCoupled {
            var polyCoupled = PolySet()
            polyCoupled.offsetLineChain(baseLineCoupled, amplitude, .roundAllCorners, maxError: Self.arcLowDef)
            poly.clearArcs()
            polyCoupled.clearArcs()
            var merged = poly
            merged.booleanAdd(polyCoupled)
            if merged.outlineCount > 0 { return merged.polygons[0][0] }
        }
        if poly.outlineCount > 0 { return poly.polygons[0][0] }
        return LineChain()
    }

    /// Whether its base lines are there to tune along (baselineValid): the line's, and a pair's other line's too
    var baselineValid: Bool {
        if mode == .diffPair || mode == .skew {
            return (baseLine?.pointCount ?? 0) > 1 && (baseLineCoupled?.pointCount ?? 0) > 1
        }
        return (baseLine?.pointCount ?? 0) > 1
    }

    /// The largest amplitude set, no less than 0, the least brought down to it if it is above (SetMaxAmplitude)
    public mutating func setMaxAmplitude(_ value: Int) {
        settings.maxAmplitude = max(value, 0)
        if settings.maxAmplitude < settings.minAmplitude { settings.minAmplitude = settings.maxAmplitude }
    }

    /// The least amplitude set, no less than 0, the largest brought up to it if it is below (SetMinAmplitude)
    public mutating func setMinAmplitude(_ value: Int) {
        settings.minAmplitude = max(value, 0)
        if settings.maxAmplitude < settings.minAmplitude { settings.maxAmplitude = settings.minAmplitude }
    }
}

extension LineChain {
    /// The chain's two sides offset by `amount` (KiCad's OffsetLine): the outline of the chain grown by it, cut at
    /// the chain's ends into the side on its left and the side on its right, each from the chain's start, without
    /// the points at its ends; nil where the outline cannot be cut so
    func offsetLine(_ amount: Int, _ cornerStrategy: PolySet.CornerStrategy, maxError: Int,
                    simplify: Bool) -> (left: LineChain, right: LineChain)? {
        guard pointCount >= 2 else { return nil }
        var poly = PolySet()
        poly.offsetLineChain(self, amount, cornerStrategy, maxError: maxError, simplify: simplify)
        guard poly.outlineCount == 1, poly.polygons[0][0].pointCount >= 3, !poly.hasHoles else { return nil }
        var outline = poly.polygons[0][0]
        let start = point(0), end = lastPoint
        outline.split(start, exact: true)
        outline.split(end, exact: true)
        let idA = outline.find(start), idB = outline.find(end)
        guard idA != -1, idB != -1 else { return nil }
        var left = LineChain(), right = LineChain()
        var i = idA
        while true {
            left.append(outline.point(i))
            i = (i + 1) % outline.pointCount
            if i == idB {
                left.append(outline.point(i))
                break
            }
            if i == idA { return nil }
        }
        guard left.pointCount >= 2 else { return nil }
        i = idB
        while true {
            right.append(outline.point(i))
            i = (i + 1) % outline.pointCount
            if i == idA {
                right.append(outline.point(i))
                break
            }
            if i == idB { return nil }
        }
        guard right.pointCount >= 2 else { return nil }
        if left.point(0) != start { left = left.reversed() }
        if right.point(0) != start { right = right.reversed() }
        let base = Seg(point(0), point(1))
        let sideLeft = base.side(left.point(1)), sideRight = base.side(right.point(1))
        guard sideLeft != 0, sideRight != 0, sideLeft != sideRight else { return nil }
        if sideLeft > 0 && sideRight < 0 { swap(&left, &right) }
        guard left.pointCount >= 4, right.pointCount >= 4 else { return nil }
        left.remove(0)
        left.remove(left.pointCount - 1)
        right.remove(0)
        right.remove(right.pointCount - 1)
        return (left, right)
    }

    /// The square of the distance from `p` to the chain (KiCad's SquaredDistance: 0 inside a closed chain)
    func squaredDistance(_ p: IPoint, outlineOnly: Bool = false) -> Int {
        if isClosed && pointInside(p) && !outlineOnly { return 0 }
        var d = Int.max
        for s in 0..<segmentCount { d = min(d, segment(s).squaredDistance(p)) }
        return d
    }
}

/// The tuning patterns as KiCad has them in memory while its editor has the board (each a PCB_TUNING_PATTERN), by the
/// node each is written as: a pattern KiCad read is as SetProperties took it (lengths cut toward 0 to the nanometre),
/// one it made or tuned again as it made it, which is not always what reading its node again gives (a length it
/// writes as 66.7284 reads back as 66.728399). KiCad writes each as it has it whenever it saves the board.
public final class TuningPatternMemory: @unchecked Sendable {
    private var patterns: [String: TuningPattern] = [:]

    public init() {}

    /// The pattern the node is: as KiCad has it, where it is one of these, else as KiCad reads it
    public func pattern(_ node: SExpr) -> TuningPattern? {
        guard node.head == "generated" else { return nil }
        if let p = patterns[node.compact] { return p }
        return TuningPattern(node)
    }

    /// The board's tuning patterns, in its file's order
    public func all(_ board: KiCadBoard) -> [TuningPattern] { board.root.items.compactMap(pattern) }

    /// A pattern as KiCad has it, written as `node`
    func remember(_ p: TuningPattern, as node: SExpr) { patterns[node.compact] = p }

    /// The board's tuning patterns read as KiCad reads them (SetProperties), each written as KiCad then writes it
    /// when it saves the board, and kept as read; one of no members left out (KiCad drops it as it reads the board)
    func read(_ board: KiCadBoard) {
        for (i, node) in board.root.items.enumerated().reversed() where node.head == "generated" {
            let type = node["type"]?.text(at: 0)
            guard type == TuningPattern.generatorType || type == "meanders" else { continue }
            guard let p = pattern(node) else {
                board.root.items.remove(at: i)
                continue
            }
            let n = p.node
            remember(p, as: n)
            if n.compact != node.compact { board.root.items[i] = n }
        }
    }
}
