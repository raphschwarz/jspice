// Ported from KiCad 10.0.7: pcbnew/drc/drc_engine.cpp (loadImplicitRules, EvalRules, as a board with no rules of the
// user's own has them), pcbnew/drc/drc_test_provider_track_width.cpp, drc_test_provider_via_diameter.cpp,
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
/// and net classes (no rules of the user's own, a .kicad_dru, yet), checks of copper only
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
        public var maxError = 5000
        /// GetDRCEpsilon: half a micron
        public var epsilon = 500
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
            mm("min_track_width", &minTrackWidth)
            mm("min_via_annular_width", &minViaAnnularWidth)
            mm("min_via_diameter", &minViaDiameter)
            mm("min_through_hole_diameter", &minThroughDrill)
            mm("min_microvia_diameter", &minMicroViaDiameter)
            mm("min_microvia_drill", &minMicroViaDrill)
            mm("min_hole_to_hole", &holeToHole)
            mm("min_hole_clearance", &holeClearance)
            mm("min_copper_edge_clearance", &edgeClearance)
            mm("max_error", &maxError)
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
    ]

    /// The checks' titles (DRC_ITEM's error texts)
    static let titles: [String: String] = [
        "track_width": "Track width", "via_diameter": "Via diameter", "annular_width": "Annular width",
        "drill_out_of_range": "Hole size out of range", "microvia_drill_out_of_range": "Micro via hole size out of range",
        "hole_to_hole": "Drilled hole too close to other hole", "holes_co_located": "Drilled holes co-located",
    ]

    /// How many of each check KiCad reports at most (DRC_ENGINE's ERROR_LIMIT)
    static let errorLimit = 199

    public let settings: Settings
    let board: KiCadBoard
    let world: BoardWorld
    let netClasses: NetClasses
    var tracks: [Track] = []
    var footprints: [Footprint] = []

    public init(board: KiCadBoard, project: [String: Any]? = nil) {
        self.board = board
        settings = Settings(project: project)
        world = BoardWorld(board: board, project: project)
        netClasses = NetClasses(project: project)
        read()
    }

    public init(board: KiCadBoard, projectURL: URL?) {
        let json = projectURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        self.init(board: board, project: json)
    }

    // MARK: - The board's items

    /// A track, arc or via (PCB_TRACK, PCB_ARC, PCB_VIA), in the order the board holds them (BOARD::Tracks)
    struct Track {
        enum Kind { case track, arc, via }
        var kind: Kind
        var uuid: String
        var net: String
        var start = IPoint.zero, mid = IPoint.zero, end = IPoint.zero
        var width = 0
        var layer = ""
        // a via's
        var diameter = 0
        var drill = 0
        var viaType = Via.ViaType.through
        /// The copper layers it spans, as router layers
        var layers = LayerRange(0, 0)
    }

    struct Footprint {
        var reference: String
        var pads: [Pad]
    }

    /// A pad (PAD), with what the checks ask of it
    struct Pad {
        var uuid: String
        var number: String
        var net: String
        var pad: BoardWorld.Pad
        /// A custom pad's pieces
        var primitives: [SExpr] = []
        var hasHole: Bool { pad.drill.x > 0 && pad.drill.y > 0 }
        /// PAD::HasDrilledHole: a hole of one diameter
        var hasDrilledHole: Bool { hasHole && pad.drill.x == pad.drill.y }
    }

    private static func netName(_ node: SExpr) -> String {
        guard let n = node["net"] else { return "" }
        return (n.items.count >= 3 ? n.text(at: 1) : n.text(at: 0)) ?? ""
    }

    private mutating func read() {
        for node in board.root.items {
            switch node.head ?? "" {
            case "segment", "arc":
                var t = Track(kind: node.head == "arc" ? .arc : .track, uuid: node.value("uuid") ?? "", net: Self.netName(node))
                t.start = BoardWorld.point(node["start"])
                t.mid = BoardWorld.point(node["mid"])
                t.end = BoardWorld.point(node["end"])
                t.width = node["width"].map { BoardWorld.iu($0, 0) } ?? 0
                t.layer = node.value("layer") ?? ""
                tracks.append(t)
            case "via":
                var t = Track(kind: .via, uuid: node.value("uuid") ?? "", net: Self.netName(node))
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
                    primitives: (node["primitives"]?.arguments ?? []).filter { $0.head != "gr_bbox" && $0.head != "gr_vector" })
            }
            footprints.append(Footprint(reference: placement.reference, pads: pads))
        }
    }

    // MARK: - Running the checks

    /// The violations KiCad's DRC would find, those of each check in the order KiCad's finds them
    public func run() -> [DRCViolation] {
        var out = Report(settings: settings)
        checkTrackWidths(&out)
        checkViaDiameters(&out)
        checkHoleSizes(&out)
        checkAnnularWidths(&out)
        checkHolesToHoles(&out)
        return out.violations
    }

    /// The violations found so far, each check's up to KiCad's limit, those of checks set to be ignored left out
    /// (DRC_ENGINE::ReportViolation and the severities KiCad's markers are given)
    struct Report {
        let settings: Settings
        var violations: [DRCViolation] = []
        var counts: [String: Int] = [:]

        mutating func add(_ type: String, _ detail: String?, _ items: [String]) {
            let severity = settings.severity(type)
            guard severity != "ignore", counts[type, default: 0] < BoardDRC.errorLimit else { return }
            counts[type, default: 0] += 1
            let title = BoardDRC.titles[type] ?? type
            violations.append(DRCViolation(type: type, severity: severity,
                                           description: detail.map { "\(title) \($0)" } ?? title, items: items))
        }
    }

    // MARK: - Messages

    /// A length as KiCad's DRC messages give it (MessageTextFromValue, in millimetres)
    static func messageText(_ v: Int) -> String { String(format: "%.4f mm", Double(v) / 1e6) }

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

    func checkTrackWidths(_ out: inout Report) {
        for t in tracks where t.kind != .via {
            // (the board setup's minimum; its net class's rule has the same minimum)
            let min = settings.minTrackWidth
            guard t.width < min else { continue }
            out.add("track_width", Self.formatMsg({ "(\($0) min width \($1); actual \($2))" }, Self.boardSetup, min, t.width),
                    [t.uuid])
        }
    }

    // MARK: - Via diameters (DRC_TEST_PROVIDER_VIA_DIAMETER)

    func checkViaDiameters(_ out: inout Report) {
        for t in tracks where t.kind == .via {
            // a micro via's minimum is its net class's micro via diameter (the net class rule, applied last, sets
            // its minimum to it); another's the board setup's
            let min = t.viaType == .microVia ? (netClasses.effective(t.net).microViaDiameter ?? settings.minMicroViaDiameter)
                                             : settings.minViaDiameter
            guard t.diameter < min else { continue }
            out.add("via_diameter", Self.formatMsg({ "(\($0) min diameter \($1); actual \($2))" }, Self.boardSetup, min, t.diameter),
                    [t.uuid])
        }
    }

    // MARK: - Hole sizes (DRC_TEST_PROVIDER_HOLE_SIZE)

    func checkHoleSizes(_ out: inout Report) {
        for fp in footprints {
            for p in fp.pads {
                let minor = min(p.pad.drill.x, p.pad.drill.y)
                if minor == 0 { continue }
                let limit = settings.minThroughDrill
                guard minor < limit else { continue }
                out.add("drill_out_of_range", Self.formatMsg({ "(\($0) min hole \($1); actual \($2))" }, Self.boardSetup, limit, minor),
                        [p.uuid])
            }
        }
        for t in tracks where t.kind == .via {
            let micro = t.viaType == .microVia
            let limit = micro ? settings.minMicroViaDrill : settings.minThroughDrill
            guard t.drill < limit else { continue }
            out.add(micro ? "microvia_drill_out_of_range" : "drill_out_of_range",
                    Self.formatMsg({ "(\($0) min hole \($1); actual \($2))" }, Self.boardSetup, limit, t.drill), [t.uuid])
        }
    }

    // MARK: - Annular widths (DRC_TEST_PROVIDER_ANNULAR_WIDTH)

    func checkAnnularWidths(_ out: inout Report) {
        let limit = settings.minViaAnnularWidth
        func check(_ width: Int, _ uuid: String) {
            guard width < limit else { return }
            out.add("annular_width", Self.formatMsg({ "(\($0) min annular width \($1); actual \($2))" }, Self.boardSetup, limit, width),
                    [uuid])
        }
        for t in tracks where t.kind == .via {
            let a = t.start - IPoint(t.drill / 2, 0), b = t.start - IPoint(t.diameter / 2, 0)
            check((a - b).norm, t.uuid)
        }
        for fp in footprints {
            for p in fp.pads where p.hasHole && p.pad.attribute == .pth {
                // (FOOTPRINT::GetPads: the footprint's other pads of the number, none for a pad with no number)
                let sameNumber = p.number.isEmpty ? [] : fp.pads.filter { $0.number == p.number && $0.uuid != p.uuid }
                guard let (a, b) = padAnnulusPoints(p, sameNumber, limit) else { continue }
                check((a - b).norm, p.uuid)
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
    func padAnnulusPoints(_ p: Pad, _ sameNumber: [Pad], _ limit: Int) -> (IPoint, IPoint)? {
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
        if handled && !overlapping.isEmpty && !constrainingHole && !covers {
            // a circle's ring is as wide all round, so its quick width holds where any side is uncovered; another's
            // narrow side a pad of the number can make up for, so its quick width is taken only if it passes
            if pad.kind == .circle || (a - b).norm >= limit { return (a, b) }
        }
        if !handled || !overlapping.isEmpty {
            // the general way: the pad's outline (with its same-numbered pads', less their holes) against its hole
            let maxError = world.rules.maxError
            guard var outline = world.padPolygon(pad, primitives: p.primitives, errorLocation: .inside) else { return nil }
            guard case .segment(let slot, let slotWidth) = world.holeShape(pad) else { return nil }
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

    func checkHolesToHoles(_ out: inout Report) {
        let clearance = settings.holeToHole
        // the holes drilled: round pad holes and vias' (slots are milled after)
        struct Hole {
            var uuid: String
            var center: IPoint
            var radius: Int
            var via: Track?
        }
        var holes: [Hole] = []
        for fp in footprints {
            for p in fp.pads where p.hasDrilledHole {
                holes.append(Hole(uuid: p.uuid, center: p.pad.pos, radius: p.pad.drill.x / 2, via: nil))
            }
        }
        for t in tracks where t.kind == .via { holes.append(Hole(uuid: t.uuid, center: t.start, radius: t.drill / 2, via: t)) }
        let epsilon = settings.epsilon
        func test(_ h: Hole, _ o: Hole) {
            // blind and buried vias are drilled before the board is laminated: only those that share layers
            if let a = h.via, let b = o.via, !a.layers.overlaps(b.layers) { return }
            var first = h, second = o
            if first.uuid > second.uuid { swap(&first, &second) }
            let d = h.center - o.center
            if d.squaredNorm < epsilon * epsilon {
                out.add("holes_co_located", nil, [first.uuid, second.uuid])
                return
            }
            let actual = max(0, d.norm - h.radius - o.radius)
            guard clearance >= 0 && actual < max(0, clearance - epsilon) else { return }
            out.add("hole_to_hole", Self.formatMsg({ "(\($0) min \($1); actual \($2))" }, Self.boardSetup, clearance, actual),
                    [first.uuid, second.uuid])
        }
        // (the holes within the worst hole to hole clearance of each other, as the R-tree finds them)
        func near(_ h: Hole, _ o: Hole) -> Bool {
            let r = h.radius + o.radius + clearance
            return (h.center - o.center).squaredNorm < r * r
        }
        // each via's hole against the others (not a micro via's, burned, not drilled), each pair once; then each pad's
        var checked = Set<[String]>()
        for h in holes where h.via != nil && h.via!.viaType != .microVia {
            for o in holes where o.uuid != h.uuid && near(h, o) && checked.insert([h.uuid, o.uuid].sorted()).inserted { test(h, o) }
        }
        checked.removeAll()
        for h in holes where h.via == nil {
            for o in holes where o.uuid != h.uuid && near(h, o) && checked.insert([h.uuid, o.uuid].sorted()).inserted { test(h, o) }
        }
    }
}
