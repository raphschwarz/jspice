// Ported from KiCad 10.0.7: pcbnew/teardrop/teardrop.cpp (TEARDROP_MANAGER: UpdateTeardrops on a full update, its
// teardrops on pads and vias, tracks crossing them, AddTeardropsOnTracks, setTeardropPriorities, createTeardrop and
// createTeardropMask, createAndAddTeardropWithMask, tryCreateTrackTeardrop, teardropUuid, maskUuidFor,
// buildCrossingStub), pcbnew/teardrop/teardrop_utils.cpp (all of it: GetWidth, IsRound, BuildTrackCaches,
// ensureCopperIndex, copperNetcode, pairClearance, zoneConnections, areItemsInSameZone, collidesWithOtherNets,
// computeFittedTeardropPolygon, computeChordThroughShape, findTouchingTrack, computeCurvedForRoundShape,
// computeCornerTangentControlPoint, isPointOnOvalEnd, isPointOnRoundedCorner, computeCurvedForRectShape,
// computeAnchorPoints, findAnchorPointsOnTrack, computeTeardropPolygon), pcbnew/teardrop/teardrop.h (TRACK_BUFFER),
// pcbnew/teardrop/teardrop_parameters.h and teardrop_parameters.cpp (TEARDROP_PARAMETERS, TEARDROP_PARAMETERS_LIST,
// the targets' canonical names), pcbnew/board_design_settings.cpp (teardrop_options and teardrop_parameters in the
// project), pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr_parser.cpp (parseTEARDROP_PARAMETERS) and
// pcb_io_kicad_sexpr.cpp (formatTeardropParameters, isDefaultTeardropParameters, a teardrop zone as KiCad writes it,
// and the order it writes zones in: BOARD_ITEM::ptr_cmp), pcbnew/dialogs/dialog_global_edit_teardrops.cpp (the Set
// Teardrops dialog's adding and removing them with the default values for each shape), pcbnew/pad.cpp (HitTest,
// GetBoundingRadius as BuildEffectivePolygon works it out), pcbnew/pcb_track.cpp (PCB_TRACK, PCB_ARC and PCB_VIA's
// HitTest, IsPointOnEnds, GetLength, GetBoundingBox, PCB_ARC's GetRadius and GetAngle), libs/kimath/src/trigo.cpp
// (TestSegmentHit), libs/kimath/src/geometry/convex_hull.cpp (BuildConvexHull), libs/kimath/src/geometry/
// shape_poly_set.cpp (Collide of a shape) and pcbnew/drc/drc_rtree.h (CheckColliding with a clearance resolved for
// each item, QueryColliding of an item), common/kiid.cpp (KIID::Combine and Increment).
// Copyright (C) 2021 Jean-Pierre Charras; Copyright The KiCad Developers, see KiCad's AUTHORS.txt. Some of its
// calculations (computeCurvedForRoundShape) are derived from https://github.com/NilujePerchut/kicad_scripts.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// A teardrop's settings (KiCad's TEARDROP_PARAMETERS): a pad's or via's own, or the board's for a kind of target
public struct TeardropParameters: Sendable, Equatable {
    /// The longest a teardrop may be, and the widest (nm; 0 or less for no limit)
    public var maxLength = 1_000_000
    public var maxWidth = 2_000_000
    /// Its length and width as parts of the pad's or via's size (the least of a pad's two)
    public var bestLengthRatio = 0.5
    public var bestWidthRatio = 1.0
    /// The widest a track may be, as a part of the pad's or via's size, to have one
    public var widthToSizeFilterRatio = 0.9
    /// Its sides curves, else straight
    public var curvedEdges = false
    public var enabled = false
    /// Whether it may run on along the next track where the first is too short
    public var allowTwoSegments = true
    /// Whether a pad or via in a zone of its net that joins it to the track has one too (KiCad's "prefer zone
    /// connections" unticked)
    public var onPadsInZones = false

    public init(maxLength: Int = 1_000_000, maxWidth: Int = 2_000_000, bestLengthRatio: Double = 0.5, bestWidthRatio: Double = 1.0,
                widthToSizeFilterRatio: Double = 0.9, curvedEdges: Bool = false, enabled: Bool = false, allowTwoSegments: Bool = true,
                onPadsInZones: Bool = false) {
        (self.maxLength, self.maxWidth, self.bestLengthRatio, self.bestWidthRatio) = (maxLength, maxWidth, bestLengthRatio, bestWidthRatio)
        (self.widthToSizeFilterRatio, self.curvedEdges, self.enabled) = (widthToSizeFilterRatio, curvedEdges, enabled)
        (self.allowTwoSegments, self.onPadsInZones) = (allowTwoSegments, onPadsInZones)
    }

    /// PCB_IO_KICAD_SEXPR_PARSER::parseTEARDROP_PARAMETERS: a pad's or via's `(teardrops ...)`, which starts from
    /// off, no second track and no teardrops in zones (whatever the defaults), and then takes what it says
    init(node: SExpr) {
        self.init()
        enabled = false
        allowTwoSegments = false
        onPadsInZones = true
        func maybeAbsentBool(_ n: SExpr, _ absent: Bool) -> Bool {
            guard let v = n.text(at: 0) else { return absent }
            return v == "yes" || v == "true"
        }
        for item in node.arguments where item.isList {
            switch item.head ?? "" {
            case "enabled": enabled = maybeAbsentBool(item, true)
            case "allow_two_segments": allowTwoSegments = maybeAbsentBool(item, true)
            case "prefer_zone_connections": onPadsInZones = !maybeAbsentBool(item, false)
            case "best_length_ratio": bestLengthRatio = item.number(at: 0) ?? bestLengthRatio
            case "max_length": maxLength = BoardWorld.iu(item, 0)
            case "best_width_ratio": bestWidthRatio = item.number(at: 0) ?? bestWidthRatio
            case "max_width": maxWidth = BoardWorld.iu(item, 0)
            case "curve_points": curvedEdges = (item.number(at: 0) ?? 0) > 0
            case "curved_edges": curvedEdges = maybeAbsentBool(item, true)
            case "filter_ratio": widthToSizeFilterRatio = item.number(at: 0) ?? widthToSizeFilterRatio
            default: break
            }
        }
    }

    /// The parameters of a pad or via (its `(teardrops ...)`, or the defaults without one)
    init(item node: SExpr) {
        if let t = node["teardrops"] { self.init(node: t) } else { self.init() }
    }

    /// PCB_IO_KICAD_SEXPR::formatTeardropParameters
    var node: SExpr {
        func yesNo(_ b: Bool) -> Keyword { Keyword(b ? "yes" : "no") }
        return SExpr("teardrops", SExpr("best_length_ratio", Keyword(Self.formatDouble(bestLengthRatio))),
                     SExpr("max_length", Double(maxLength) / 1e6),
                     SExpr("best_width_ratio", Keyword(Self.formatDouble(bestWidthRatio))),
                     SExpr("max_width", Double(maxWidth) / 1e6), SExpr("curved_edges", yesNo(curvedEdges)),
                     SExpr("filter_ratio", Keyword(Self.formatDouble(widthToSizeFilterRatio))), SExpr("enabled", yesNo(enabled)),
                     SExpr("allow_two_segments", yesNo(allowTwoSegments)), SExpr("prefer_zone_connections", yesNo(!onPadsInZones)))
    }

    /// FormatDouble2Str of a ratio
    static func formatDouble(_ v: Double) -> String {
        if v != 0 && abs(v) <= 0.0001 {
            var s = String(format: "%.16f", v)
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            return s
        }
        return String(format: "%.10g", v)
    }

    /// The canonical names of the board's targets (GetTeardropTargetCanonicalName)
    static let targetNames = ["td_round_shape", "td_rect_shape", "td_track_end"]

    /// A project's teardrop_parameters entry of a target, read as BOARD_DESIGN_SETTINGS reads it over these
    mutating func read(_ entry: [String: Any]) {
        func bool(_ k: String) -> Bool? { (entry[k] as? NSNumber)?.boolValue }
        func number(_ k: String) -> Double? { (entry[k] as? NSNumber)?.doubleValue }
        if let v = bool("td_enabled") { enabled = v }
        if let v = number("td_maxlen") { maxLength = BoardWorld.iuMM(v) }
        if let v = number("td_maxheight") { maxWidth = BoardWorld.iuMM(v) }
        if let v = number("td_length_ratio") { bestLengthRatio = v }
        if let v = number("td_height_ratio") { bestWidthRatio = v }
        // (a curve's segment count of none leaves the edges as they were)
        if let v = number("td_curve_segcount"), Int(v) > 0 { curvedEdges = true }
        if let v = number("td_width_to_size_filter_ratio") { widthToSizeFilterRatio = v }
        if let v = bool("td_allow_use_two_tracks") { allowTwoSegments = v }
        if let v = bool("td_on_pad_in_zone") { onPadsInZones = v }
    }

    /// The entry BOARD_DESIGN_SETTINGS writes for a target
    func projectEntry(_ name: String) -> [String: Any] {
        ["td_target_name": name, "td_enabled": enabled, "td_maxlen": Double(maxLength) / 1e6, "td_maxheight": Double(maxWidth) / 1e6,
         "td_length_ratio": bestLengthRatio, "td_height_ratio": bestWidthRatio, "td_curve_segcount": curvedEdges ? 1 : 0,
         "td_width_to_size_filter_ratio": widthToSizeFilterRatio, "td_allow_use_two_tracks": allowTwoSegments,
         "td_on_pad_in_zone": onPadsInZones]
    }
}

/// The board's teardrop settings (KiCad's TEARDROP_PARAMETERS_LIST, kept in the board's project): those for round
/// pads and vias, for pads of other shapes and for track ends, and what the Set Teardrops dialog puts them on
public struct TeardropSettings: Sendable, Equatable {
    public var round = TeardropParameters()
    public var rect = TeardropParameters()
    public var track = TeardropParameters()
    public var vias = true
    public var pthPads = true
    public var smdPads = true
    public var trackToTrack = false
    public var roundShapesOnly = false

    public init(round: TeardropParameters = .init(), rect: TeardropParameters = .init(), track: TeardropParameters = .init(),
                vias: Bool = true, pthPads: Bool = true, smdPads: Bool = true, trackToTrack: Bool = false) {
        (self.round, self.rect, self.track) = (round, rect, track)
        (self.vias, self.pthPads, self.smdPads, self.trackToTrack) = (vias, pthPads, smdPads, trackToTrack)
    }

    /// The settings a project has (BOARD_DESIGN_SETTINGS' teardrop_options and teardrop_parameters), KiCad's
    /// defaults where it has none
    public init(project: [String: Any]?) {
        let ds = (project?["board"] as? [String: Any])?["design_settings"] as? [String: Any] ?? [:]
        for entry in ds["teardrop_options"] as? [[String: Any]] ?? [] where !entry.isEmpty {
            func bool(_ k: String) -> Bool? { (entry[k] as? NSNumber)?.boolValue }
            if let v = bool("td_onvia") { vias = v }
            if let v = bool("td_onpthpad") { pthPads = v }
            if let v = bool("td_onsmdpad") { smdPads = v }
            if let v = bool("td_ontrackend") { trackToTrack = v }
            if let v = bool("td_onroundshapesonly") { roundShapesOnly = v }
            // (the old settings, of all three targets)
            for i in 0..<3 {
                if let v = bool("td_allow_use_two_tracks") { self[i].allowTwoSegments = v }
                if let v = (entry["td_curve_segcount"] as? NSNumber)?.intValue, v > 0 { self[i].curvedEdges = true }
                if let v = bool("td_on_pad_in_zone") { self[i].onPadsInZones = v }
            }
        }
        for entry in ds["teardrop_parameters"] as? [[String: Any]] ?? [] where !entry.isEmpty {
            guard let name = entry["td_target_name"] as? String, let i = TeardropParameters.targetNames.firstIndex(of: name) else { continue }
            self[i].read(entry)
        }
    }

    /// The parameters of round shapes (0), other shapes (1) and track ends (2)
    public subscript(_ i: Int) -> TeardropParameters {
        get { i == 0 ? round : i == 1 ? rect : track }
        set {
            switch i {
            case 0: round = newValue
            case 1: rect = newValue
            default: track = newValue
            }
        }
    }

    /// What a project keeps of them (its board's design settings' teardrop_options and teardrop_parameters), to
    /// put into the project's JSON
    public var projectSettings: [String: Any] {
        ["teardrop_options": [["td_onvia": vias, "td_onpthpad": pthPads, "td_onsmdpad": smdPads, "td_ontrackend": trackToTrack,
                               "td_onroundshapesonly": roundShapesOnly]],
         "teardrop_parameters": (0..<3).map { self[$0].projectEntry(TeardropParameters.targetNames[$0]) }]
    }
}

/// The board's teardrops as KiCad's teardrop manager makes them (TEARDROP_MANAGER::UpdateTeardrops, all of them made
/// again): copper zones of a teardrop's type joining tracks to the pads and vias they end in or cross, and wider
/// tracks to the narrower ones that end on them, each as wide as the pad's or via's settings ask, narrowed where it
/// would come too close to another net's copper, and each a solder mask zone over it where its track has a mask
/// opening of its own
public final class Teardrops {
    /// A teardrop: a zone (of a teardrop's type, on one layer, of its track's net), what it joins, and its outline
    public struct Teardrop: Sendable {
        public enum Kind: Sendable { case padVia, trackEnd }
        public var kind: Kind
        /// Its layer's name (a copper layer, or for a mask teardrop F.Mask or B.Mask)
        public var layer: String
        public var net: String
        /// Its zone priority (set once all are made)
        public var priority = 0
        /// The polygon of its outline (and, until the zones are filled, of its fill)
        public var outline: [IPoint]
        /// The pad, via or (track end's) wider track it joins, and its track, by uuid
        public var anchor: String
        public var track: String
        /// The id KiCad makes it with (KIID::Combine of its track's and its anchor's, moved on for a track's
        /// second one), which orders the zones when KiCad writes them, though it writes none
        public var uuid: [UInt8]
        /// A mask teardrop (the opening over a copper one)
        public var isMask = false
        /// The copper layer's KiCad id (the mask's for a mask teardrop)
        var layerID: Int
        /// GetOutlineArea
        var area: Double = 0
        /// A mask teardrop's expansion (its track's)
        var maskExpansion = 0
    }

    public private(set) var teardrops: [Teardrop] = []
    /// What the port does not make teardrops round yet, by what it is (a board with any is not made)
    public private(set) var unsupported: Set<String> = []
    /// How many teardrops were narrowed to keep clear of other nets' copper, and how many were not made for it
    public private(set) var narrowed = 0, notFitted = 0

    let drc: BoardDRC
    let copper: BoardDRC.Copper
    let cn: BoardDRC.Connectivity
    let settings: TeardropSettings
    private var maxError: Int { drc.world.rules.maxError }
    /// m_tolerance: how far a track's end may be from another's for them to be joined (UpdateTeardrops' 0.01 mm)
    private let tolerance = 10_000

    /// Each pad's and via's own teardrop settings
    private var parameters: [ObjectIdentifier: TeardropParameters] = [:]
    /// The pads' polygons (TransformShapeToPolygon, the error inside) and bounding radii (GetBoundingRadius)
    private var padPolygons: [ObjectIdentifier: PolySet] = [:]
    private var boundingRadii: [ObjectIdentifier: Int] = [:]

    /// m_tracksRTree, each layer's, and m_trackLookupList (TRACK_BUFFER: the tracks by layer and net)
    private var tracksTree: [Int: RTree<TrackEntry, Double>] = [:]
    private var trackLookup: [Int: [BoardDRC.CopperItem]] = [:]
    private final class TrackEntry {
        let item: BoardDRC.CopperItem
        let shape: Shape
        init(_ item: BoardDRC.CopperItem, _ shape: Shape) { (self.item, self.shape) = (item, shape) }
    }

    /// m_copperRTree: the copper items and the teardrops made so far, each layer's (the entries' boxes, an item and
    /// its piece, or a teardrop)
    private var copperIndex: [Int: [(box: IBox, item: BoardDRC.CopperItem, shape: Shape?, teardrop: Int?)]] = [:]
    private var copperIndexed = false
    /// The zones the teardrops made so far are, as the clearance rules and the collisions see them, and their fills
    private var teardropItems: [BoardDRC.CopperItem] = []
    private var teardropPolys: [PolySet] = []
    private var zoneConnectionCache: [String: [Set<ObjectIdentifier>]] = [:]
    /// The tracks with a mask opening of their own (HasSolderMask, on F.Cu or B.Cu), and its expansion
    /// (GetSolderMaskExpansion)
    private var trackMasks: [ObjectIdentifier: Int] = [:]
    private var layerNames: [Int: String] = [:]
    /// The texts on copper (PCB_TEXT and PCB_FIELD: no net, their strokes their shape)
    private var texts: [BoardDRC.CopperItem] = []

    /// The teardrops of `board` (its own teardrops left out: they are all made again), from each pad's and via's own
    /// settings and the track ends' in `settings` (the project's unless given)
    public init(board: KiCadBoard, project: [String: Any]? = nil, settings: TeardropSettings? = nil, designRules: String? = nil) {
        let b = Self.withoutTeardrops(board)
        self.settings = settings ?? TeardropSettings(project: project)
        drc = BoardDRC(board: b, project: project, designRules: designRules)
        copper = drc.makeCopper()
        cn = drc.buildConnectivity(copper)
        for (name, l) in drc.world.layerIndex { layerNames[l] = name }
        readParameters(b)
        readTrackMasks(b)
        checkSupported(b)
        legacy = Self.legacyTeardrops(board)
        guard unsupported.isEmpty, !legacy else { return }
        update()
        // (what of the rules' conditions the port could not evaluate as the clearances asked)
        unsupported.formUnion(drc.ruleState.board.unsupported)
    }

    /// BOARD::LegacyTeardrops: a board of teardrops made the old way (its general settings say so, or it was written
    /// before KiCad made them as it does now and has some), which the teardrop manager leaves as they are
    public private(set) var legacy = false

    static func legacyTeardrops(_ board: KiCadBoard) -> Bool {
        // (a board written since has the flag; one written before, teardrops of its own)
        if let flag = board.root["general"]?["legacy_teardrops"] { return (flag.text(at: 0) ?? "yes") != "no" }
        return board.version < 20230517 && board.root.all("zone").contains { $0["attr"]?["teardrop"] != nil }
    }

    /// BOARD::SetLegacyTeardrops( false ), as the Set Teardrops dialog has it first (on a board of legacy teardrops)
    static func clearLegacyTeardrops(_ board: KiCadBoard) {
        guard legacyTeardrops(board), let general = board.root["general"] else { return }
        if let flag = general["legacy_teardrops"] {
            flag.items = [SExpr(symbol: "legacy_teardrops"), SExpr(symbol: "no")]
        } else {
            general.items.append(SExpr("legacy_teardrops", Keyword("no")))
        }
    }

    // MARK: - The board

    /// BOARD::BulkRemoveStaleTeardrops of all of them: the board without its teardrops
    static func withoutTeardrops(_ board: KiCadBoard) -> KiCadBoard {
        let b = board.copy()
        b.root.items.removeAll { $0.head == "zone" && $0["attr"]?["teardrop"] != nil }
        return b
    }

    private func readParameters(_ board: KiCadBoard) {
        var vias: [String: SExpr] = [:]
        for node in board.root.items where node.head == "via" { vias[node.value("uuid") ?? ""] = node }
        for t in copper.tracks where t.kind == .via {
            parameters[ObjectIdentifier(t)] = vias[t.uuid].map { TeardropParameters(item: $0) } ?? TeardropParameters()
        }
        for (i, fp) in board.root.all("footprint").enumerated() {
            for (j, node) in fp.all("pad").enumerated() where i < copper.footprintPads.count && j < copper.footprintPads[i].count {
                parameters[ObjectIdentifier(copper.footprintPads[i][j])] = TeardropParameters(item: node)
            }
        }
    }

    /// A track's mask opening: where its layers have its side's mask, its own margin or else the board's
    /// (PCB_TRACK::GetSolderMaskExpansion on the implicit rules: no less than half its width shrunk)
    private func readTrackMasks(_ board: KiCadBoard) {
        var nodes: [String: SExpr] = [:]
        for node in board.root.items where node.head == "segment" || node.head == "arc" { nodes[node.value("uuid") ?? ""] = node }
        let boardMargin = board.root["setup"]?["pad_to_mask_clearance"].map { BoardWorld.iu($0, 0) } ?? 0
        for t in copper.tracks where t.kind != .via {
            guard let node = nodes[t.uuid] else { continue }
            let layers = node["layers"]?.arguments.map(\.text) ?? []
            guard layers.contains("F.Mask") || layers.contains("B.Mask") else { continue }
            var margin = node["solder_mask_margin"].map { BoardWorld.iu($0, 0) } ?? boardMargin
            if margin < 0 { margin = max(margin, -t.trackWidth / 2) }
            trackMasks[ObjectIdentifier(t)] = margin
        }
    }

    private func layerName(_ l: Int) -> String { layerNames[l] ?? "" }

    /// What the port does not yet make teardrops round or near: dimensions, text boxes, tables and barcodes on
    /// copper, texts on copper it does not make (another font, a knockout, variables it cannot resolve) or a
    /// footprint's own text hidden there (which KiCad keeps teardrops off still), pads of a stack of shapes, custom
    /// pads of pieces it does not make. The texts on copper it makes are kept as obstacles (`texts`).
    private func checkSupported(_ board: KiCadBoard) {
        let names = Set(drc.world.layerIndex.keys)
        func onCopper(_ node: SExpr) -> Bool {
            if names.contains(BoardWorld.itemLayer(node) ?? "") { return true }
            return node["layers"]?.arguments.contains { names.contains($0.text) } ?? false
        }
        func text(_ node: SExpr, _ fp: SExpr?, _ footprint: Int?) {
            guard let l = BoardWorld.itemLayer(node).flatMap({ drc.world.layerIndex[$0] }) else { return }
            guard let t = BoardWorld.textStrokes(node, footprint: fp, unsupported: { _ in }) else {
                unsupported.insert("text on copper")
                return
            }
            // (a hidden field KiCad's index leaves out; a hidden text of a footprint's own it does not)
            if !t.visible {
                if node.head == "fp_text" && node.text(at: 0) == "user" { unsupported.insert("hidden text on copper") }
                return
            }
            let item = BoardDRC.CopperItem(kind: .shape, uuid: node.value("uuid") ?? "")
            item.connected = false
            item.netIdentity = Int.min
            item.footprint = footprint
            item.layers = [l]
            item.shapes[l] = t.shapes
            texts.append(item)
        }
        for node in board.root.items {
            switch node.head ?? "" {
            case "gr_text" where onCopper(node): text(node, nil, nil)
            case "gr_text_box", "dimension", "table", "barcode", "target":
                if onCopper(node) { unsupported.insert("dimension, text box, table or barcode on copper") }
            default: break
            }
        }
        for (i, fp) in board.root.all("footprint").enumerated() {
            for node in fp.items {
                switch node.head ?? "" {
                case "property" where onCopper(node), "fp_text" where onCopper(node): text(node, fp, i)
                case "fp_text_box", "dimension", "table", "barcode":
                    if onCopper(node) { unsupported.insert("dimension, text box, table or barcode on copper") }
                case "pad" where node["padstack"] != nil:
                    unsupported.insert("pad padstack")
                default: break
                }
            }
        }
        for pad in copper.footprintPads.joined() {
            guard let p = pad.pad else { continue }
            if drc.world.padPolygon(p.pad, primitives: p.primitives, errorLocation: .inside) == nil {
                unsupported.insert("custom pad curve or old arc")
            }
        }
    }

    // MARK: - TEARDROP_MANAGER::UpdateTeardrops

    private func update() {
        buildTrackCaches()
        for track in copper.tracks where track.kind == .track || track.kind == .arc {
            var pads: [BoardDRC.CopperItem] = [], vias: [BoardDRC.CopperItem] = []
            connectedPadsAndVias(track, &pads, &vias)
            let layer = track.layers[0]
            for pad in pads {
                guard let tdParams = parameters[ObjectIdentifier(pad)], let p = pad.pad else { continue }
                let annularWidth = min(p.pad.size.x, p.pad.size.y)
                guard tdParams.enabled else { continue }
                // (a track as wide as the teardrop or the filter would be: none; a max width of 0 is no limit)
                if (tdParams.maxWidth > 0 && track.trackWidth >= tdParams.maxWidth)
                    || Double(track.trackWidth) >= Double(annularWidth) * tdParams.bestWidthRatio
                    || Double(track.trackWidth) >= Double(annularWidth) * tdParams.widthToSizeFilterRatio {
                    continue
                }
                let startHitsPad = padHitTest(pad, track.trackStart, onLayer: layer)
                let endHitsPad = padHitTest(pad, track.trackEnd, onLayer: layer)
                if startHitsPad && endHitsPad { continue }
                // (a tangential graze, not a short entry)
                if startHitsPad != endHitsPad
                    && computeChordThroughShape(track, pad, layer, startHitsPad ? track.trackStart : track.trackEnd) < track.trackWidth {
                    continue
                }
                if !tdParams.onPadsInZones && areItemsInSameZone(pad, track) { continue }
                let pos = p.pad.pos
                if !startHitsPad && !endHitsPad && trackHitTest(track, pos, 0) {
                    // (a track across the pad: a teardrop each side)
                    let stub = buildCrossingStub(track, pos)
                    stub.trackStart = track.trackEnd
                    tryCreateTrackTeardrop(tdParams, .padVia, stub, track, pad, pos, Self.teardropUuid(track, pad, 0))
                    stub.trackStart = track.trackStart
                    tryCreateTrackTeardrop(tdParams, .padVia, stub, track, pad, pos, Self.teardropUuid(track, pad, 1))
                } else {
                    tryCreateTrackTeardrop(tdParams, .padVia, track, track, pad, pos, Self.teardropUuid(track, pad, 0))
                }
            }
            for via in vias {
                guard let tdParams = parameters[ObjectIdentifier(via)], let v = via.via else { continue }
                let annularWidth = v.diameter
                guard tdParams.enabled else { continue }
                if (tdParams.maxWidth > 0 && track.trackWidth >= tdParams.maxWidth)
                    || Double(track.trackWidth) >= Double(annularWidth) * tdParams.bestWidthRatio
                    || Double(track.trackWidth) >= Double(annularWidth) * tdParams.widthToSizeFilterRatio {
                    continue
                }
                let startHitsVia = viaHitTest(via, track.trackStart, 0)
                let endHitsVia = viaHitTest(via, track.trackEnd, 0)
                if startHitsVia && endHitsVia { continue }
                if startHitsVia != endHitsVia
                    && computeChordThroughShape(track, via, layer, startHitsVia ? track.trackStart : track.trackEnd) < track.trackWidth {
                    continue
                }
                let pos = v.start
                if !startHitsVia && !endHitsVia && trackHitTest(track, pos, 0) {
                    let stub = buildCrossingStub(track, pos)
                    stub.trackStart = track.trackEnd
                    tryCreateTrackTeardrop(tdParams, .padVia, stub, track, via, pos, Self.teardropUuid(track, via, 0))
                    stub.trackStart = track.trackStart
                    tryCreateTrackTeardrop(tdParams, .padVia, stub, track, via, pos, Self.teardropUuid(track, via, 1))
                } else {
                    tryCreateTrackTeardrop(tdParams, .padVia, track, track, via, pos, Self.teardropUuid(track, via, 0))
                }
            }
        }
        if settings.track.enabled { addTeardropsOnTracks() }
        setTeardropPriorities()
    }

    /// CONNECTIVITY_DATA::GetConnectedPadsAndVias: the pads and vias the item's connectivity items touch
    private func connectedPadsAndVias(_ item: BoardDRC.CopperItem, _ pads: inout [BoardDRC.CopperItem], _ vias: inout [BoardDRC.CopperItem]) {
        for citem in cn.entries[ObjectIdentifier(item)] ?? [] {
            for connected in citem.connected {
                switch connected.parent.kind {
                case .pad: pads.append(connected.parent)
                case .via: vias.append(connected.parent)
                default: break
                }
            }
        }
    }

    /// AddTeardropsOnTracks of every track: a teardrop at the end of each track on a narrower one's end, on the
    /// narrower (each group of a layer's and a net's tracks)
    private func addTeardropsOnTracks() {
        var params = settings.track
        for key in trackLookup.keys.sorted() {
            var sublist = trackLookup[key]!
            if sublist.count <= 1 { continue }
            // (by width, as std::sort sorts them)
            Clipper.introSort(&sublist) { $0.trackWidth < $1.trackWidth }
            var minWidth = sublist.first!.trackWidth
            let maxWidth = sublist.last!.trackWidth
            if maxWidth == minWidth { continue }
            for ii in 0..<(sublist.count - 1) {
                let track = sublist[ii]
                let trackLen = Int(Self.length(track))
                minWidth = track.trackWidth
                // (not between tracks of about one width)
                params.widthToSizeFilterRatio = max(params.widthToSizeFilterRatio, 0.1)
                let th = 1.0 / params.widthToSizeFilterRatio
                minWidth = KiMath.round(Double(minWidth) * th)
                for jj in (ii + 1)..<sublist.count {
                    let candidate = sublist[jj]
                    if minWidth >= candidate.trackWidth { continue }
                    if trackLen <= candidate.trackWidth / 2 { continue }
                    var pos = candidate.trackStart
                    var matchPoints = Self.isPointOnEnds(track, pos, tolerance)
                    if matchPoints == 0 {
                        pos = candidate.trackEnd
                        matchPoints = Self.isPointOnEnds(track, pos, tolerance)
                    }
                    if matchPoints == 0 { continue }
                    // (a pad's or via's teardrop first)
                    var existingPadOrVia = false
                    var pads: [BoardDRC.CopperItem] = [], vias: [BoardDRC.CopperItem] = []
                    connectedPadsAndVias(track, &pads, &vias)
                    for pad in pads where padHitTest(pad, pos, 0) { existingPadOrVia = true }
                    for via in vias where viaHitTest(via, pos, 0) { existingPadOrVia = true }
                    if existingPadOrVia { continue }
                    tryCreateTrackTeardrop(params, .trackEnd, track, track, candidate, pos, Self.teardropUuid(track, candidate, 0))
                }
            }
        }
    }

    /// setTeardropPriorities: by layer, the biggest first (their uuids breaking ties), from 30000 up
    private func setTeardropPriorities() {
        let magicTeardropZoneID = 30000
        var order = teardrops.indices.filter { !teardrops[$0].isMask }
        for i in order { teardrops[i].area = abs(teardrops[i].area) }
        order.sort { a, b in
            let ta = teardrops[a], tb = teardrops[b]
            if ta.layerID == tb.layerID {
                if ta.area != tb.area { return ta.area > tb.area }
                return ta.uuid.lexicographicallyPrecedes(tb.uuid)
            }
            return ta.layerID < tb.layerID
        }
        var currLayer = -1
        var priorityBase = magicTeardropZoneID
        for i in order {
            if teardrops[i].layerID != currLayer {
                currLayer = teardrops[i].layerID
                priorityBase = magicTeardropZoneID
            }
            teardrops[i].priority = priorityBase
            priorityBase += 1
        }
    }

    // MARK: - Making one

    /// tryCreateTrackTeardrop and createAndAddTeardropWithMask
    private func tryCreateTrackTeardrop(_ params: TeardropParameters, _ kind: Teardrop.Kind, _ track: BoardDRC.CopperItem,
                                        _ sourceTrack: BoardDRC.CopperItem, _ candidate: BoardDRC.CopperItem, _ pos: IPoint,
                                        _ uuid: [UInt8]) {
        var points: [IPoint] = []
        guard computeFittedTeardropPolygon(params, &points, track, sourceTrack, candidate, pos) else { return }
        let layer = sourceTrack.layers[0]
        let layerName = self.layerName(layer)
        // (ZONE's outline: SHAPE_POLY_SET::Append, a point the same as the one before left out)
        var outline = LineChain()
        outline.setClosed(true)
        for p in points { outline.append(p) }
        var t = Teardrop(kind: kind, layer: layerName, net: sourceTrack.netName, outline: outline.points, anchor: candidate.uuid,
                         track: sourceTrack.uuid, uuid: uuid, layerID: BoardDRC.layerID(layerName) ?? 0)
        t.area = outline.area()
        teardrops.append(t)
        // (the next teardrop sees this one)
        ensureCopperIndex()
        let item = BoardDRC.CopperItem(kind: .zone, uuid: "")
        item.net = sourceTrack.net
        item.netName = sourceTrack.netName
        item.netIdentity = sourceTrack.net
        item.layers = [layer]
        item.localClearance = (0, "zone")
        item.teardrop = true
        let poly = PolySet([[outline]])
        item.zoneOutline = poly
        let index = teardropItems.count
        teardropItems.append(item)
        teardropPolys.append(poly)
        copperIndex[layer, default: []].append((poly.bbox(), item, nil, index))
        if let mask = trackMasks[ObjectIdentifier(sourceTrack)], layerName == "F.Cu" || layerName == "B.Cu" {
            // createTeardropMask: the same outline on the side's mask, grown by the track's mask expansion
            var maskOutline = PolySet([[outline]])
            if mask != 0 { maskOutline.inflate(mask, .allowAcuteCorners, maxError: maxError) }
            let name = layerName == "F.Cu" ? "F.Mask" : "B.Mask"
            var m = Teardrop(kind: kind, layer: name, net: "", outline: maskOutline.polygons.first?.first?.points ?? [],
                             anchor: candidate.uuid, track: sourceTrack.uuid, uuid: Self.maskUuidFor(uuid), layerID: BoardDRC.layerID(name) ?? 0)
            m.isMask = true
            m.maskExpansion = mask
            teardrops.append(m)
        }
    }

    /// buildCrossingStub: a segment of the track's layer, width and net from one of its ends (set after) to `end`
    private func buildCrossingStub(_ track: BoardDRC.CopperItem, _ end: IPoint) -> BoardDRC.CopperItem {
        let stub = BoardDRC.CopperItem(kind: .track, uuid: "")
        stub.layers = track.layers
        stub.trackWidth = track.trackWidth
        stub.net = track.net
        stub.netName = track.netName
        stub.netIdentity = track.netIdentity
        stub.trackEnd = end
        return stub
    }

    // MARK: - KIIDs

    /// A uuid's sixteen bytes (KIID( std::string ): an old timestamp's in the last four; none, for one KiCad would
    /// give a random uuid, all naught)
    static func kiid(_ s: String) -> [UInt8] {
        if !s.isEmpty && s.count <= 8 && s.allSatisfy(\.isHexDigit) {
            var out = Array(repeating: UInt8(0), count: 16)
            // (each octet's two characters, or what is left of them: strtol of none is naught)
            let c = Array(s)
            for i in 0..<4 where 2 * i < c.count { out[i + 12] = UInt8(String(c[(2 * i)..<min(2 * i + 2, c.count)]), radix: 16) ?? 0 }
            return out
        }
        let hex = s.filter { $0.isHexDigit }
        guard hex.count == 32 else { return Array(repeating: 0, count: 16) }
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16) ?? 0)
            i = j
        }
        return out
    }

    /// KIID::Increment
    static func increment(_ u: inout [UInt8]) {
        for i in stride(from: 15, through: 0, by: -1) {
            u[i] &+= 1
            if u[i] != 0 { break }
        }
    }

    /// teardropUuid: KIID::Combine of the track's and the candidate's (each byte the one's xor the other's), a
    /// slot two on
    static func teardropUuid(_ track: BoardDRC.CopperItem, _ candidate: BoardDRC.CopperItem, _ slot: Int) -> [UInt8] {
        let a = kiid(track.uuid), b = kiid(candidate.uuid)
        var u = zip(a, b).map { $0 ^ $1 }
        for _ in 0..<(2 * slot) { increment(&u) }
        return u
    }

    /// maskUuidFor: the copper's, one on
    static func maskUuidFor(_ copper: [UInt8]) -> [UInt8] {
        var u = copper
        increment(&u)
        return u
    }

    // MARK: - The items' sizes and shapes

    /// GetWidth: a via's diameter, the least of a pad's sizes, a track's width
    private func width(_ item: BoardDRC.CopperItem) -> Int {
        switch item.kind {
        case .via: return item.via?.diameter ?? 0
        case .pad: return item.pad.map { min($0.pad.size.x, $0.pad.size.y) } ?? 0
        case .track, .arc: return item.trackWidth
        default: return 0
        }
    }

    /// IsRound: a round pad (or an oval one as long as it is wide); a via or a track
    private func isRound(_ item: BoardDRC.CopperItem) -> Bool {
        guard item.kind == .pad, let p = item.pad?.pad else { return true }
        return p.kind == .circle || (p.kind == .oval && p.size.x == p.size.y)
    }

    /// PAD::TransformShapeToPolygon on its layer, no clearance, the error inside
    private func padPolygon(_ pad: BoardDRC.CopperItem) -> PolySet {
        if let p = padPolygons[ObjectIdentifier(pad)] { return p }
        let p = pad.pad.flatMap { drc.world.padPolygon($0.pad, primitives: $0.primitives, errorLocation: .inside) } ?? PolySet()
        padPolygons[ObjectIdentifier(pad)] = p
        return p
    }

    /// The pad's or via's polygon the teardrop's points are found on: a round one's circle (16 segments at least),
    /// else the pad's polygon
    private func shapeBuffer(_ other: BoardDRC.CopperItem, _ pos: IPoint) -> PolySet {
        if isRound(other) {
            return circleBuffer(pos, width(other) / 2)
        }
        return padPolygon(other)
    }

    /// TransformCircleToPolygon of a round pad, via or track end: at least 16 segments, the error inside
    private func circleBuffer(_ center: IPoint, _ radius: Int) -> PolySet {
        PolySet([[PadPolygon.circle(center: center, radius: radius, maxError: maxError, errorLocation: .inside, minSegCount: 16)]])
    }

    /// PAD::GetBoundingRadius: the furthest of its polygon's points (the error outside) from its position, or its
    /// hole's half size
    private func boundingRadius(_ pad: BoardDRC.CopperItem) -> Int {
        if let r = boundingRadii[ObjectIdentifier(pad)] { return r }
        guard let p = pad.pad else { return 0 }
        var r = 0
        if let poly = drc.world.padPolygon(p.pad, primitives: p.primitives, errorLocation: .outside) {
            for outline in poly.polygons {
                for q in outline[0].points { r = max(r, KiMath.round((q - p.pad.pos).distance(.zero))) }
            }
        }
        r = max(r, KiMath.round(Double(p.pad.drill.x) / 2.0))
        r = max(r, KiMath.round(Double(p.pad.drill.y) / 2.0))
        boundingRadii[ObjectIdentifier(pad)] = r
        return r
    }

    /// PAD::HitTest of a point on a layer (`layer` nil: on any, its hole too)
    private func padHitTest(_ pad: BoardDRC.CopperItem, _ p: IPoint, _ accuracy: Int, _ layer: Int? = nil) -> Bool {
        guard let pp = pad.pad else { return false }
        if let layer, !drc.world.copper(pp.pad.layers).contains(layer) { return false }
        let delta = p - pp.pad.pos
        let r = boundingRadius(pad) + accuracy
        if delta.squaredNorm > r * r { return false }
        if padPolygon(pad).contains(p, accuracy: accuracy) { return true }
        if layer != nil { return false }
        // (its hole, a segment of the drill's width, of none without a hole: SHAPE_SEGMENT::Collide of a point)
        guard case .segment(let s, let w) = drc.world.holeShape(pp.pad) else { return false }
        let minDist = (w + 1) / 2 + accuracy
        let d = s.squaredDistance(p)
        return d == 0 || d < minDist * minDist
    }

    private func padHitTest(_ pad: BoardDRC.CopperItem, _ p: IPoint, onLayer layer: Int) -> Bool { padHitTest(pad, p, 0, layer) }

    /// PCB_VIA::HitTest
    private func viaHitTest(_ via: BoardDRC.CopperItem, _ p: IPoint, _ accuracy: Int) -> Bool {
        guard let v = via.via else { return false }
        let maxDist = accuracy + v.diameter / 2
        let rel = DPoint(Double(p.x - v.start.x), Double(p.y - v.start.y))
        return rel.x * rel.x + rel.y * rel.y <= Double(maxDist) * Double(maxDist)
    }

    /// PCB_TRACK::HitTest and PCB_ARC::HitTest of a point
    private func trackHitTest(_ t: BoardDRC.CopperItem, _ p: IPoint, _ accuracy: Int) -> Bool {
        if t.kind == .arc {
            let maxDist = Double(accuracy) + Double(t.trackWidth) / 2.0
            if t.trackStart.distance(p) <= maxDist || t.trackEnd.distance(p) <= maxDist { return true }
            let center = KiMath.arcCenter(t.trackStart, t.trackMid, t.trackEnd)
            let relpos = p - center
            let dist = relpos.norm
            let radius = Self.arcRadius(t)
            if abs(Double(dist) - radius) > maxDist { return false }
            let arcAngle = Self.arcAngle(t)
            let arcAngleStart = EDAAngle(DPoint(t.trackStart) - DPoint(center)).normalized
            var hit = EDAAngle(relpos)
            hit = (hit - arcAngleStart).normalized
            if arcAngle < .zero { return hit >= EDAAngle.a360 + arcAngle }
            return hit <= arcAngle
        }
        return Self.testSegmentHit(p, t.trackStart, t.trackEnd, accuracy + t.trackWidth / 2)
    }

    /// The other item's HitTest of a point (BOARD_ITEM::HitTest, no accuracy)
    private func hitTest(_ other: BoardDRC.CopperItem, _ p: IPoint) -> Bool {
        switch other.kind {
        case .pad: return padHitTest(other, p, 0, nil)
        case .via: return viaHitTest(other, p, 0)
        default: return trackHitTest(other, p, 0)
        }
    }

    /// TestSegmentHit
    static func testSegmentHit(_ ref: IPoint, _ start: IPoint, _ end: IPoint, _ dist: Int) -> Bool {
        var xmin = start.x, xmax = end.x, ymin = start.y, ymax = end.y
        let delta = start - ref
        if xmax < xmin { swap(&xmax, &xmin) }
        if ymax < ymin { swap(&ymax, &ymin) }
        if ymin - ref.y > dist || ref.y - ymax > dist { return false }
        if xmin - ref.x > dist || ref.x - xmax > dist { return false }
        if start.x == end.x && ref.y > ymin && ref.y < ymax { return abs(delta.x) <= dist }
        if start.y == end.y && ref.x > xmin && ref.x < xmax { return abs(delta.y) <= dist }
        return Seg(start, end).squaredDistance(ref) < (dist + 1) * (dist + 1)
    }

    /// PCB_TRACK::IsPointOnEnds: 1 its start, 2 its end, 3 both, within `minDist`
    static func isPointOnEnds(_ t: BoardDRC.CopperItem, _ p: IPoint, _ minDist: Int) -> Int {
        var result = 0
        let m = minDist < 0 ? t.trackWidth / 2 : minDist
        if m == 0 {
            if t.trackStart == p { result |= 1 }
            if t.trackEnd == p { result |= 2 }
        } else {
            if Double(m) >= t.trackStart.distance(p) { result |= 1 }
            if Double(m) >= t.trackEnd.distance(p) { result |= 2 }
        }
        return result
    }

    /// PCB_ARC::GetRadius
    static func arcRadius(_ t: BoardDRC.CopperItem) -> Double {
        let center = KiMath.arcCenter(t.trackStart, t.trackMid, t.trackEnd)
        return min(center.distance(t.trackStart), Double(Int32.max) / 2.0)
    }

    /// PCB_ARC::GetAngle
    static func arcAngle(_ t: BoardDRC.CopperItem) -> EDAAngle {
        let center = DPoint(KiMath.arcCenter(t.trackStart, t.trackMid, t.trackEnd))
        let angle1 = EDAAngle(DPoint(t.trackMid) - center) - EDAAngle(DPoint(t.trackStart) - center)
        let angle2 = EDAAngle(DPoint(t.trackEnd) - center) - EDAAngle(DPoint(t.trackMid) - center)
        return angle1.normalized180 + angle2.normalized180
    }

    /// PCB_TRACK::GetLength and PCB_ARC::GetLength
    static func length(_ t: BoardDRC.CopperItem) -> Double {
        if t.kind == .arc { return arcRadius(t) * abs(arcAngle(t).radians) }
        return t.trackStart.distance(t.trackEnd)
    }

    /// The track's shape (GetEffectiveShape: a segment, or an arc)
    private static func trackShape(_ t: BoardDRC.CopperItem) -> Shape {
        if t.kind == .arc { return .arc(ShapeArc(start: t.trackStart, mid: t.trackMid, end: t.trackEnd, width: t.trackWidth)) }
        return .segment(Seg(t.trackStart, t.trackEnd), width: t.trackWidth)
    }

    /// The item's shape on a layer (GetEffectiveShape: a pad's or drawing's pieces)
    private func effectiveShapes(_ item: BoardDRC.CopperItem, _ layer: Int) -> [Shape] {
        switch item.kind {
        case .track, .arc: return [Self.trackShape(item)]
        case .pad: return item.anyLayerShapes(layer)
        default: return item.shapes[layer] ?? []
        }
    }

    // MARK: - The caches

    /// BuildTrackCaches
    private func buildTrackCaches() {
        for t in copper.tracks where t.kind == .track || t.kind == .arc {
            let layer = t.layers[0]
            let s = Self.trackShape(t)
            let tree = tracksTree[layer] ?? RTree<TrackEntry, Double>()
            tracksTree[layer] = tree
            tree.insert(s.bbox, TrackEntry(t, s))
            // (TRACK_BUFFER's index: the net code above the layer's id)
            let id = BoardDRC.layerID(layerName(layer)) ?? 0
            trackLookup[(t.net << 8) + (id & 0xFF), default: []].append(t)
        }
    }

    /// ensureCopperIndex: the tracks and vias, the teardrops so far, the board's drawings and the footprints' pads
    /// and drawings, on each of their copper layers, with their pieces' boxes (a pad's hole too)
    private func ensureCopperIndex() {
        if copperIndexed { return }
        copperIndexed = true
        var items = copper.tracks + copper.drawings
        for i in copper.footprintPads.indices { items += copper.footprintPads[i] + copper.footprintDrawings[i] }
        items += texts
        for item in items {
            for l in item.layers {
                var pieces: [Shape]
                switch item.kind {
                case .track, .arc: pieces = [Self.trackShape(item)]
                case .pad:
                    pieces = item.anyLayerShapes(l)
                    if let p = item.pad, p.hasHole { pieces.append(drc.world.holeShape(p.pad)) }
                default: pieces = item.shapes[l] ?? []
                }
                for s in pieces { copperIndex[l, default: []].append((s.bbox, item, s, nil)) }
            }
        }
    }

    /// pairClearance: what the rules ask between the track and the item on the layer, less the DRC's epsilon
    private func pairClearance(_ track: BoardDRC.CopperItem, _ item: BoardDRC.CopperItem, _ layer: Int) -> Int {
        max(0, (drc.clearanceConstraint(track, item, layer, copper).value.min ?? 0) - drc.settings.epsilon)
    }

    /// zoneConnections: what each island of the zone's fill on the layer touches
    private func zoneConnections(_ zone: BoardDRC.CopperItem, _ layer: Int) -> [Set<ObjectIdentifier>] {
        let key = "\(ObjectIdentifier(zone).hashValue) \(layer)"
        if let c = zoneConnectionCache[key] { return c }
        var islands: [Set<ObjectIdentifier>] = []
        for citem in cn.entries[ObjectIdentifier(zone)] ?? [] where citem.zoneLayer == layer {
            islands.append(Set(citem.connected.map { ObjectIdentifier($0.parent) }))
        }
        zoneConnectionCache[key] = islands
        return islands
    }

    /// areItemsInSameZone: whether one island of a zone of the track's net on its layer (not a teardrop) reaches
    /// both
    private func areItemsInSameZone(_ padOrVia: BoardDRC.CopperItem, _ track: BoardDRC.CopperItem) -> Bool {
        let layer = track.layers[0]
        for zone in copper.zones where zone.footprint == nil && !zone.teardrop && zone.layers.contains(layer) && zone.net == track.net {
            guard zone.fills[layer] != nil else { continue }
            let islands = zoneConnections(zone, layer)
            if islands.contains(where: { $0.contains(ObjectIdentifier(padOrVia)) && $0.contains(ObjectIdentifier(track)) }) { return true }
        }
        return false
    }

    // MARK: - Other nets' copper

    /// SHAPE_POLY_SET::Collide of a shape: a segment's or circle's by distance, else against the set's triangles
    static func polySetCollide(_ set: inout PolySet, _ shape: Shape, _ clearance: Int) -> Bool {
        switch shape {
        case .segment(let s, let w):
            let c = clearance + w / 2
            let d = BoardDRC.squaredDistance(set, s)
            return d == 0 || d < c * c
        case .circle(let center, let r):
            if set.polygons.isEmpty { return false }
            let c = clearance + r
            let d = BoardDRC.squaredDistance(set, center)
            return d == 0 || d < c * c
        default:
            set.cacheTriangulation()
            for tpoly in set.triangulatedPolygons {
                for i in tpoly.triangles.indices {
                    let (a, b, c) = tpoly.triangle(i)
                    if shape.collide(.simple(LineChain([a, b, c], closed: true)), clearance: clearance) { return true }
                }
            }
            return false
        }
    }

    /// A set (another teardrop) against a set (SHAPE_POLY_SET::Collide of a SHAPE_POLY_SET: the one's triangles
    /// each against the other's)
    static func polySetCollide(_ a: inout PolySet, _ b: inout PolySet, _ clearance: Int) -> Bool {
        a.cacheTriangulation()
        for tpoly in a.triangulatedPolygons {
            for i in tpoly.triangles.indices {
                let (p, q, r) = tpoly.triangle(i)
                if polySetCollide(&b, .simple(LineChain([p, q, r], closed: true)), clearance) { return true }
            }
        }
        return false
    }

    /// collidesWithOtherNets: whether a teardrop of these points would come too near copper of another net (its
    /// anchor and tracks, `exempt`, left out; for a track of no net, what touches them too)
    private func collidesWithOtherNets(_ points: [IPoint], _ sourceTrack: BoardDRC.CopperItem, _ exempt: [BoardDRC.CopperItem]) -> Bool {
        if points.count < 3 { return false }
        var teardrop = PolySet()
        teardrop.newOutline()
        for p in points { teardrop.append(p) }
        // (it can cross itself on awkward entries)
        teardrop.simplify()
        if teardrop.outlineCount == 0 { return false }
        ensureCopperIndex()
        let layer = sourceTrack.layers[0]
        let netcode = sourceTrack.net
        var anchorShapes: [Shape] = []
        if netcode <= 0 { for item in exempt { anchorShapes += effectiveShapes(item, layer) } }
        var touchesAnchor: [ObjectIdentifier: Bool] = [:]
        func touchesTeardropAnchor(_ item: BoardDRC.CopperItem, _ teardrop: Int?) -> Bool {
            if let t = touchesAnchor[ObjectIdentifier(item)] { return t }
            var touches = false
            if let t = teardrop {
                for s in anchorShapes where Self.polySetCollide(&teardropPolys[t], s, 0) { touches = true; break }
            } else {
                let shapes = effectiveShapes(item, layer)
                touches = anchorShapes.contains { a in shapes.contains { a.collide($0, clearance: 0) } }
            }
            touchesAnchor[ObjectIdentifier(item)] = touches
            return touches
        }
        func isSameConductor(_ item: BoardDRC.CopperItem, _ teardrop: Int?) -> Bool {
            // (copperNetcode: a connected item's net, else none)
            let itemNet = item.net
            if netcode > 0 { return itemNet == netcode }
            return itemNet <= 0 && touchesTeardropAnchor(item, teardrop)
        }
        let maxClearance = drc.world.rules.maxClearance ?? 0
        let box = teardrop.bbox().inflated(maxClearance)
        var resolved: [ObjectIdentifier: (Bool, Int)] = [:]
        for entry in copperIndex[layer] ?? [] where entry.box.intersects(box) {
            let id = ObjectIdentifier(entry.item)
            if resolved[id] == nil {
                if exempt.contains(where: { $0 === entry.item }) || isSameConductor(entry.item, entry.teardrop) {
                    resolved[id] = (false, 0)
                } else {
                    resolved[id] = (true, pairClearance(sourceTrack, entry.item, layer))
                }
            }
            let (test, clearance) = resolved[id]!
            if !test { continue }
            if let t = entry.teardrop {
                if Self.polySetCollide(&teardrop, &teardropPolys[t], clearance) { return true }
            } else if let s = entry.shape, Self.polySetCollide(&teardrop, s, clearance) {
                return true
            }
        }
        return false
    }

    /// computeFittedTeardropPolygon: the teardrop as wide as asked, else the widest that clears other nets' copper
    /// (bisected down to the track's width four times)
    private func computeFittedTeardropPolygon(_ params: TeardropParameters, _ points: inout [IPoint], _ track: BoardDRC.CopperItem,
                                              _ sourceTrack: BoardDRC.CopperItem, _ other: BoardDRC.CopperItem, _ otherPos: IPoint) -> Bool {
        let exempt = [other, sourceTrack, track]
        guard computeTeardropPolygon(params, &points, track, sourceTrack, other, otherPos) else { return false }
        if !collidesWithOtherNets(points, sourceTrack, exempt) { return true }
        notFitted += 1
        let preferred = KiMath.round(Double(width(other)) * params.bestWidthRatio)
        var hi = params.maxWidth > 0 ? min(params.maxWidth, preferred) : preferred
        var lo = track.trackWidth
        if lo >= hi { return false }
        var p = params
        var fitted: [IPoint] = []
        func tryWidth(_ w: Int) -> Bool {
            var candidate: [IPoint] = []
            p.maxWidth = w
            if !computeTeardropPolygon(p, &candidate, track, sourceTrack, other, otherPos)
                || collidesWithOtherNets(candidate, sourceTrack, exempt) {
                return false
            }
            fitted = candidate
            return true
        }
        if !tryWidth(lo) { return false }
        var ii = 0
        while ii < 4 && hi - lo > 1 {
            let mid = lo + (hi - lo) / 2
            if tryWidth(mid) { lo = mid } else { hi = mid }
            ii += 1
        }
        points = fitted
        if !points.isEmpty { (narrowed, notFitted) = (narrowed + 1, notFitted - 1) }
        return !points.isEmpty
    }

    /// computeChordThroughShape: how long the track's line runs through the pad's or via's copper where the end
    /// inside it is (Int.max for an arc, a track of no length, or a line that does not cross it)
    private func computeChordThroughShape(_ track: BoardDRC.CopperItem, _ other: BoardDRC.CopperItem, _ layer: Int, _ insidePoint: IPoint) -> Int {
        if track.kind == .arc { return Int.max }
        let delta = DPoint(track.trackEnd - track.trackStart)
        let len = delta.norm
        if len == 0 { return Int.max }
        var shapebuffer = shapeBuffer(other, other.kind == .pad ? other.pad!.pad.pos : other.via?.start ?? .zero)
        let dir = delta / len
        let mid = (track.trackStart + track.trackEnd).divided(by: 2)
        let bbox = shapebuffer.bbox()
        let reach = KiMath.round(Double(IPoint(bbox.width, bbox.height).norm) + len)
        let ext = IPoint(KiMath.round(dir.x * Double(reach)), KiMath.round(dir.y * Double(reach)))
        let extStart = mid - ext, extEnd = mid + ext
        var pts: [LineChain.Intersection] = []
        for i in 0..<shapebuffer.outlineCount {
            for j in shapebuffer.polygons[i].indices {
                shapebuffer.polygons[i][j].setClosed(true)
                Self.intersect(shapebuffer.polygons[i][j], Seg(extStart, extEnd), &pts)
            }
        }
        if pts.count < 2 { return Int.max }
        // (VECTOR2I::Dot takes a VECTOR2I: the direction cut to whole numbers)
        let idir = dir.truncated
        var proj = pts.map { Double(($0.p - extStart).dot(idir)) }
        Clipper.introSort(&proj) { $0 < $1 }
        let insideProj = (DPoint(insidePoint) - DPoint(extStart)).x * dir.x + (DPoint(insidePoint) - DPoint(extStart)).y * dir.y
        for ii in 0..<(proj.count - 1) {
            let sum = proj[ii] + proj[ii + 1]
            let spanMid = extStart + IPoint(KiMath.round(dir.x * sum / 2), KiMath.round(dir.y * sum / 2))
            if !shapebuffer.contains(spanMid) { continue }
            if insideProj >= proj[ii] && insideProj <= proj[ii + 1] { return KiMath.round(proj[ii + 1] - proj[ii]) }
        }
        return Int.max
    }

    /// SHAPE_LINE_CHAIN::Intersect of a segment into a list: its crossings added, and the whole list sorted by
    /// their distance from the segment's start
    static func intersect(_ chain: LineChain, _ s: Seg, _ list: inout [LineChain.Intersection]) {
        list += chain.intersect(s)
        Clipper.introSort(&list) { (s.a - $0.p).norm < (s.a - $1.p).norm }
    }

    /// findTouchingTrack: the track (not the stub's own) whose end is at `endPoint`, the longest where several
    /// are, and which of its ends (1 its start, 2 its end)
    private func findTouchingTrack(_ matchType: inout Int, _ trackRef: BoardDRC.CopperItem, _ sourceTrack: BoardDRC.CopperItem,
                                   _ endPoint: IPoint) -> BoardDRC.CopperItem? {
        var matches = 0
        var candidate: BoardDRC.CopperItem?
        let layer = trackRef.layers[0]
        guard let tree = tracksTree[layer] else { return nil }
        // (QueryColliding of the track: its box, then its shape against each piece)
        let refShape = Self.trackShape(trackRef)
        var box = refShape.bbox
        if trackRef.kind != .arc {
            let r = (trackRef.trackWidth + 1) / 2
            let (s, e) = (trackRef.trackStart, trackRef.trackEnd)
            box = IBox(minX: min(s.x, e.x) - r, minY: min(s.y, e.y) - r, maxX: max(s.x, e.x) + r + 1, maxY: max(s.y, e.y) + r + 1)
        } else {
            let r = (trackRef.trackWidth + 1) / 2
            box = IBox(minX: box.minX - r, minY: box.minY - r, maxX: box.maxX + r + 1, maxY: box.maxY + r + 1)
        }
        var colliding = Set<ObjectIdentifier>()
        var filtered: [ObjectIdentifier: Bool] = [:]
        _ = tree.search(box) { entry in
            let item = entry.item
            if item === trackRef { return true }
            let id = ObjectIdentifier(item)
            if colliding.contains(id) { return true }
            let rejected = filtered[id] ?? { let r = !(item !== trackRef && item !== sourceTrack); filtered[id] = r; return r }()
            if rejected { return true }
            guard refShape.collide(entry.shape, clearance: 0) else { return true }
            colliding.insert(id)
            let match = Self.isPointOnEnds(item, endPoint, tolerance)
            if match != 0 {
                // (at a Y junction, the longest)
                matches += 1
                if matches > 1 {
                    let previousLen = Self.length(candidate!)
                    let currLen = Self.length(item)
                    if previousLen >= currLen { return true }
                }
                matchType = match
                candidate = item
            }
            return true
        }
        return candidate
    }

    /// NormalizeVector
    private static func normalize(_ v: IPoint) -> DPoint {
        let d = DPoint(v)
        return d / d.norm
    }

    /// A VECTOR2I made of two doubles (each cut to a whole number, as the int constructor takes them)
    private static func cut(_ x: Double, _ y: Double) -> IPoint { IPoint(Int(x), Int(y)) }

    // MARK: - The curves

    /// computeCurvedForRoundShape
    private func computeCurvedForRoundShape(_ params: TeardropParameters, _ poly: inout [IPoint], _ layer: Int, _ trackHalfWidth: Int,
                                            _ trackDir: DPoint, _ other: BoardDRC.CopperItem, _ otherPos: IPoint, _ pts: inout [IPoint]) {
        var vpercent = params.bestWidthRatio
        let tdHeight = KiMath.round(Double(width(other)) * vpercent)
        if params.maxWidth > 0 && params.maxWidth < tdHeight { vpercent *= Double(params.maxWidth) / Double(tdHeight) }
        var radius = width(other) / 2
        if radius == 0 { radius = 1 }
        let minVpercent = Double(trackHalfWidth) / Double(radius)
        let weaken = (vpercent - minVpercent) / (1 - minVpercent) / Double(radius)
        // (the hull's points onto the circle, where they are not on it)
        var vecC = pts[2] - otherPos
        let distC = Double(vecC.norm)
        if distC > 0 && abs(distC - Double(radius)) > Double(maxError) {
            pts[2] = otherPos + vecC.resized(radius)
            vecC = pts[2] - otherPos
        }
        var vecE = pts[4] - otherPos
        let distE = Double(vecE.norm)
        if distE > 0 && abs(distE - Double(radius)) > Double(maxError) {
            pts[4] = otherPos + vecE.resized(radius)
            vecE = pts[4] - otherPos
        }
        let biasBC = 0.5 * Double(Seg(pts[1], pts[2]).length)
        let biasAE = 0.5 * Double(Seg(pts[4], pts[0]).length)
        let tangentC = Self.cut(Double(pts[2].x) - Double(vecC.y) * biasBC * weaken, Double(pts[2].y) + Double(vecC.x) * biasBC * weaken)
        let tangentE = Self.cut(Double(pts[4].x) + Double(vecE.y) * biasAE * weaken, Double(pts[4].y) - Double(vecE.x) * biasAE * weaken)
        let tangentB = Self.cut(Double(pts[1].x) - trackDir.x * biasBC, Double(pts[1].y) - trackDir.y * biasBC)
        let tangentA = Self.cut(Double(pts[0].x) - trackDir.x * biasAE, Double(pts[0].y) - trackDir.y * biasAE)
        poly += Outlines.bezierPoints(pts[1], tangentB, tangentC, pts[2], maxError: maxError)
        poly.append(pts[3])
        poly += Outlines.bezierPoints(pts[4], tangentE, tangentA, pts[0], maxError: maxError)
    }

    /// computeCornerTangentControlPoint
    private static func cornerTangentControlPoint(_ anchor: IPoint, _ cornerCenter: IPoint, _ bias: Double, _ desiredDir: IPoint) -> IPoint {
        let radial = anchor - cornerCenter
        if radial.norm == 0 { return anchor }
        let tangent1 = IPoint(radial.y, -radial.x), tangent2 = IPoint(-radial.y, radial.x)
        let dot1 = tangent1.x * desiredDir.x + tangent1.y * desiredDir.y
        let dot2 = tangent2.x * desiredDir.x + tangent2.y * desiredDir.y
        let tangent = dot1 > dot2 ? tangent1 : tangent2
        return anchor + tangent.resized(KiMath.round(bias))
    }

    /// isPointOnOvalEnd: whether the point is on one of the oval's round ends, and that end's centre
    private static func isPointOnOvalEnd(_ point: IPoint, _ padPos: IPoint, _ padSize: IPoint, _ rotation: EDAAngle,
                                         _ arcCenter: inout IPoint) -> Bool {
        let localPt = KiMath.rotate(point - padPos, rotation)
        let halfW = padSize.x / 2, halfH = padSize.y / 2
        let radius = min(halfW, halfH)
        if halfW > halfH {
            let centerOffset = halfW - radius
            if abs(localPt.x) <= centerOffset { return false }
            arcCenter = IPoint(localPt.x > 0 ? centerOffset : -centerOffset, 0)
        } else {
            let centerOffset = halfH - radius
            if abs(localPt.y) <= centerOffset { return false }
            arcCenter = IPoint(0, localPt.y > 0 ? centerOffset : -centerOffset)
        }
        arcCenter = KiMath.rotate(arcCenter, EDAAngle(degrees: -rotation.degrees)) + padPos
        return true
    }

    /// isPointOnRoundedCorner: whether the point is in one of a rounded rectangle's corners, and that corner's centre
    private static func isPointOnRoundedCorner(_ point: IPoint, _ padPos: IPoint, _ padSize: IPoint, _ cornerRadius: Int, _ rotation: EDAAngle,
                                               _ cornerCenter: inout IPoint) -> Bool {
        let localPt = KiMath.rotate(point - padPos, rotation)
        let innerHalfW = padSize.x / 2 - cornerRadius, innerHalfH = padSize.y / 2 - cornerRadius
        if !(abs(localPt.x) > innerHalfW) || !(abs(localPt.y) > innerHalfH) { return false }
        cornerCenter = IPoint(localPt.x > 0 ? innerHalfW : -innerHalfW, localPt.y > 0 ? innerHalfH : -innerHalfH)
        cornerCenter = KiMath.rotate(cornerCenter, EDAAngle(degrees: -rotation.degrees)) + padPos
        return true
    }

    /// computeCurvedForRectShape
    private func computeCurvedForRectShape(_ params: TeardropParameters, _ poly: inout [IPoint], _ tdWidth: Int, _ trackHalfWidth: Int,
                                           _ pts: [IPoint], _ intersection: IPoint, _ other: BoardDRC.CopperItem, _ otherPos: IPoint,
                                           _ layer: Int) {
        let side1 = pts[2] - pts[1]
        let side2 = pts[4] - pts[0]
        let trackDir = intersection - (pts[0] + pts[1]).divided(by: 2)
        var isRoundRect = false, isOval = false
        var cornerRadius = 0
        var padSize = IPoint.zero
        var padRotation = EDAAngle.zero
        if other.kind == .pad, let p = other.pad?.pad {
            if p.kind == .roundrect {
                isRoundRect = true
                cornerRadius = p.cornerRadius
                padSize = p.size
                padRotation = p.orientation
            } else if p.kind == .oval {
                isOval = true
                padSize = p.size
                padRotation = p.orientation
            }
        }
        var ctrl1 = pts[1] + trackDir.resized(side1.norm / 4)
        let towardTrack = -trackDir
        var ctrl2 = (pts[2] + intersection).divided(by: 2)
        if isRoundRect && cornerRadius > 0 {
            var cornerCenter = IPoint.zero
            if Self.isPointOnRoundedCorner(pts[2], otherPos, padSize, cornerRadius, padRotation, &cornerCenter) {
                ctrl2 = Self.cornerTangentControlPoint(pts[2], cornerCenter, 0.5 * Double(side1.norm), towardTrack)
            }
        } else if isOval {
            var arcCenter = IPoint.zero
            if Self.isPointOnOvalEnd(pts[2], otherPos, padSize, padRotation, &arcCenter) {
                ctrl2 = Self.cornerTangentControlPoint(pts[2], arcCenter, 0.5 * Double(side1.norm), towardTrack)
            }
        }
        poly += Outlines.bezierPoints(pts[1], ctrl1, ctrl2, pts[2], maxError: maxError)
        poly.append(pts[3])
        ctrl1 = (pts[4] + intersection).divided(by: 2)
        if isRoundRect && cornerRadius > 0 {
            var cornerCenter = IPoint.zero
            if Self.isPointOnRoundedCorner(pts[4], otherPos, padSize, cornerRadius, padRotation, &cornerCenter) {
                ctrl1 = Self.cornerTangentControlPoint(pts[4], cornerCenter, 0.5 * Double(side2.norm), towardTrack)
            }
        } else if isOval {
            var arcCenter = IPoint.zero
            if Self.isPointOnOvalEnd(pts[4], otherPos, padSize, padRotation, &arcCenter) {
                ctrl1 = Self.cornerTangentControlPoint(pts[4], arcCenter, 0.5 * Double(side2.norm), towardTrack)
            }
        }
        ctrl2 = pts[0] + trackDir.resized(side2.norm / 4)
        poly += Outlines.bezierPoints(pts[4], ctrl1, ctrl2, pts[0], maxError: maxError)
    }

    // MARK: - The polygon

    /// BuildConvexHull (Andrew's monotone chain, counter-clockwise; duplicates kept as KiCad keeps them)
    static func buildConvexHull(_ input: [IPoint]) -> [IPoint] {
        var poly = input
        let n = poly.count
        if n < 2 { return [] }
        poly.sort { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }
        func cross(_ o: IPoint, _ a: IPoint, _ b: IPoint) -> Int { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var result = Array(repeating: IPoint.zero, count: 2 * n)
        var k = 0
        for ii in 0..<n {
            while k >= 2 && cross(result[k - 2], result[k - 1], poly[ii]) <= 0 { k -= 1 }
            result[k] = poly[ii]
            k += 1
        }
        let t = k + 1
        for ii in stride(from: n - 2, through: 0, by: -1) {
            while k >= t && cross(result[k - 2], result[k - 1], poly[ii]) <= 0 { k -= 1 }
            result[k] = poly[ii]
            k += 1
        }
        if k > 1 && result[0] == result[k - 1] { k -= 1 }
        return Array(result[0..<k])
    }

    /// computeAnchorPoints: the teardrop's two points on the pad, via or track (C and E, pts[2] and pts[4]), from
    /// the convex hull of its shape (cut to the teardrop's width along its axis) and its two points on the track
    private func computeAnchorPoints(_ params: TeardropParameters, _ layer: Int, _ item: BoardDRC.CopperItem, _ pos: IPoint,
                                     _ pts: inout [IPoint]) -> Bool {
        var preferredWidth = KiMath.round(Double(width(item)) * params.bestWidthRatio)
        var forceClip = params.bestWidthRatio < 1.0
        var cBuffer: PolySet
        if isRound(item) {
            cBuffer = circleBuffer(pos, width(item) / 2)
        } else {
            guard item.kind == .pad else { return false }
            forceClip = true
            preferredWidth = KiMath.round(Double(width(item)) * params.bestWidthRatio)
            cBuffer = padPolygon(item)
        }
        if forceClip || (params.maxWidth > 0 && params.maxWidth < preferredWidth) {
            // (a max width of 0 is no limit)
            let halfsize = (params.maxWidth > 0 ? min(params.maxWidth, preferredWidth) : preferredWidth) / 2
            let refOnTrack = (pts[0] + pts[1]).divided(by: 2)
            let teardropAxis = pts[3] - refOnTrack
            let orient = EDAAngle(teardropAxis)
            let len = teardropAxis.norm
            var clippingRect = PolySet()
            clippingRect.newOutline()
            clippingRect.append(IPoint(0, -halfsize))
            clippingRect.append(IPoint(0, halfsize))
            clippingRect.append(IPoint(len, halfsize))
            clippingRect.append(IPoint(len, -halfsize))
            clippingRect.rotate(EDAAngle(degrees: -orient.degrees))
            clippingRect.move(refOnTrack)
            cBuffer.booleanIntersection(clippingRect)
        }
        if cBuffer.outlineCount == 0 { return false }
        let points = cBuffer.polygons[0][0].points
        let hull = Self.buildConvexHull([pts[0], pts[1]] + points)
        var pointC = IPoint.zero, pointE = IPoint.zero
        var foundStart = -1, foundEnd = -1
        let start = pts[0], pend = pts[1]
        for ii in hull.indices {
            var next = ii + 1
            if next >= hull.count { next = 0 }
            var prev = ii - 1
            if prev < 0 { prev = hull.count - 1 }
            if hull[ii] == start {
                pointE = hull[next] != pend ? hull[next] : hull[prev]
                foundStart = ii
            }
            if hull[ii] == pend {
                pointC = hull[next] != start ? hull[next] : hull[prev]
                foundEnd = ii
            }
        }
        if foundStart < 0 {
            var ii = foundEnd - 1
            if ii < 0 { ii = hull.count - 1 }
            pointE = hull[ii]
        }
        if foundEnd < 0 {
            var ii = foundStart - 1
            if ii < 0 { ii = hull.count - 1 }
            pointC = hull[ii]
        }
        pts[2] = pointC
        pts[4] = pointE
        // (whichever way round gives the bigger polygon)
        let area1 = LineChain(pts, closed: true).area()
        pts.swapAt(2, 4)
        let area2 = LineChain(pts, closed: true).area()
        if area1 > area2 { pts.swapAt(2, 4) }
        return true
    }

    /// findAnchorPointsOnTrack: where the teardrop's track points go (the track's reference segment, `start` inside
    /// the teardrop, `end` outside), where the track's line meets the pad or via, and how far along it they are;
    /// onto the next track where this one is too short and that is allowed; `track` the track they are on
    private func findAnchorPointsOnTrack(_ params: TeardropParameters, _ startPoint: inout IPoint, _ endPoint: inout IPoint,
                                         _ intersection: inout IPoint, _ track: inout BoardDRC.CopperItem, _ sourceTrack: BoardDRC.CopperItem,
                                         _ other: BoardDRC.CopperItem, _ otherPos: IPoint, _ effectiveTeardropLen: inout Int) -> Bool {
        var start = track.trackStart
        var end = track.trackEnd
        let radius = width(other) / 2
        var targetLength = KiMath.round(Double(width(other)) * params.bestLengthRatio)
        if params.maxLength > 0 { targetLength = min(params.maxLength, targetLength) }
        var needSwap = false
        if !hitTest(other, start) {
            swap(&start, &end)
            needSwap = true
        }
        var shapebuffer: PolySet
        if isRound(other) {
            shapebuffer = circleBuffer(otherPos, radius)
        } else {
            guard other.kind == .pad else { return false }
            shapebuffer = padPolygon(other)
        }
        guard shapebuffer.outlineCount > 0 else { return false }
        var outline = shapebuffer.polygons[0][0]
        outline.setClosed(true)
        var pts: [LineChain.Intersection]
        if track.kind == .arc {
            let arc = ShapeArc(start: track.trackStart, mid: track.trackMid, end: track.trackEnd, width: track.trackWidth)
            pts = outline.intersect(arc.convertToPolyline(maxError))
        } else {
            pts = []
            Self.intersect(outline, Seg(start, end), &pts)
        }
        if pts.count < 1 { return false }
        intersection = pts[0].p
        start = intersection
        var actualTdLen = min(targetLength, Seg(start, end).length)
        let refLengthPoint = start
        if actualTdLen < targetLength && params.allowTwoSegments {
            var consumed = 0
            while actualTdLen + consumed < targetLength {
                var matchType = 0
                guard let connected = findTouchingTrack(&matchType, track, sourceTrack, end) else { break }
                // (not round a bend of more than 60°)
                let minCosForTwoSegmentExtension = 0.5
                let firstDir = Self.normalize(end - refLengthPoint)
                let secondDir = matchType == 1 ? Self.normalize(connected.trackEnd - connected.trackStart)
                                               : Self.normalize(connected.trackStart - connected.trackEnd)
                let cosAngle = firstDir.x * secondDir.x + firstDir.y * secondDir.y
                if cosAngle < minCosForTwoSegmentExtension { break }
                consumed += actualTdLen
                actualTdLen = min(targetLength - consumed, Int(Self.length(connected)))
                track = connected
                end = connected.trackEnd
                start = connected.trackStart
                needSwap = false
                if matchType != 1 {
                    swap(&start, &end)
                    needSwap = true
                }
                break
            }
        }
        if track.kind == .arc {
            // (the point on the arc itself: its polyline's points moved onto it, the first segment from the end
            // nearer than the length)
            var arc = ShapeArc(start: track.trackStart, mid: track.trackMid, end: track.trackEnd, width: track.trackWidth)
            if needSwap { arc.reverse() }
            var poly = arc.convertToPolyline(maxError)
            for ii in 0..<poly.pointCount { poly.setPoint(ii, arc.nearestPoint(poly.point(ii))) }
            if poly.pointCount > 2 {
                for ii in stride(from: poly.pointCount - 1, through: 0, by: -1) {
                    let distFromStart = (poly.point(ii) - start).norm
                    if distFromStart < actualTdLen || ii == 0 {
                        start = poly.point(ii)
                        if ii < poly.pointCount - 1 { end = poly.point(ii + 1) }
                        actualTdLen -= (start - refLengthPoint).norm
                        if actualTdLen < 0 { actualTdLen = 0 }
                        actualTdLen = min(actualTdLen, (end - start).norm)
                        break
                    }
                }
            }
        }
        startPoint = start
        endPoint = end
        effectiveTeardropLen = actualTdLen
        return true
    }

    /// computeTeardropPolygon: the teardrop's corners (A and B on the track, C and E on the pad or via, D behind its
    /// centre, the curves between, and the bend's points where it runs onto the next track)
    private func computeTeardropPolygon(_ params: TeardropParameters, _ corners: inout [IPoint], _ trackIn: BoardDRC.CopperItem,
                                        _ sourceTrack: BoardDRC.CopperItem, _ other: BoardDRC.CopperItem, _ otherPos: IPoint) -> Bool {
        var start = IPoint.zero, end = IPoint.zero, intersection = IPoint.zero
        var trackStubLen = 0
        var track = trackIn
        let originalTrack = trackIn
        guard findAnchorPointsOnTrack(params, &start, &end, &intersection, &track, sourceTrack, other, otherPos, &trackStubLen) else {
            return false
        }
        if start == end { return false }
        let vecT = Self.normalize(end - start)
        let twoSegments = track !== originalTrack
        var vecVia = vecT
        if twoSegments && start != intersection { vecVia = Self.normalize(start - intersection) }
        var trackHalfwidth = track.trackWidth / 2
        if track.kind == .arc { trackHalfwidth = max(track.trackWidth / 4, track.trackWidth / 2 - maxError) }
        let pointB = start + Self.cut(vecT.x * Double(trackStubLen) + vecT.y * Double(trackHalfwidth),
                                      vecT.y * Double(trackStubLen) - vecT.x * Double(trackHalfwidth))
        let pointA = start + Self.cut(vecT.x * Double(trackStubLen) - vecT.y * Double(trackHalfwidth),
                                      vecT.y * Double(trackStubLen) + vecT.x * Double(trackHalfwidth))
        let layer = track.layers[0]
        if !isRound(other) {
            if padHitTest(other, pointA, onLayer: layer) { return false }
            if padHitTest(other, pointB, onLayer: layer) { return false }
        }
        // pointD, behind the centre, along the track's line
        let padRadius = width(other) / 2
        let intToPad = DPoint(otherPos - intersection)
        let projOnTrack = -(intToPad.x * vecVia.x + intToPad.y * vecVia.y)
        let offset = 1000  // pcbIUScale.mmToIU( 0.001 )
        let isCustomPad = other.kind == .pad && other.pad?.pad.kind == .custom
        var effectiveDist = isCustomPad ? Double(padRadius) : max(projOnTrack, Double(padRadius))
        if !isRound(other) && other.kind == .pad {
            var padPoly = padPolygon(other)
            let reach = effectiveDist + 2.0 * Double(boundingRadius(other)) + Double(offset)
            let rayEnd = intersection + IPoint(KiMath.round(-vecVia.x * reach), KiMath.round(-vecVia.y * reach))
            var hits: [LineChain.Intersection] = []
            for ii in 0..<padPoly.outlineCount {
                for jj in padPoly.polygons[ii].indices {
                    padPoly.polygons[ii][jj].setClosed(true)
                    Self.intersect(padPoly.polygons[ii][jj], Seg(intersection, rayEnd), &hits)
                }
            }
            var crossings: [Double] = []
            for hit in hits {
                let d = Double((hit.p - intersection).norm)
                if d > Double(offset) { crossings.append(d) }
            }
            Clipper.introSort(&crossings) { $0 < $1 }
            var exitEdge = 0.0
            for d in crossings {
                let probe = intersection + IPoint(KiMath.round(-vecVia.x * (d + Double(offset))), KiMath.round(-vecVia.y * (d + Double(offset))))
                if !padPoly.contains(probe) {
                    exitEdge = d
                    break
                }
            }
            effectiveDist = min(effectiveDist, max(0.0, exitEdge - 2.0 * Double(offset)))
        } else {
            let r = Double(padRadius)
            let cx = intToPad.x, cy = intToPad.y
            let distCenterSq = cx * cx + cy * cy
            let disc = projOnTrack * projOnTrack - (distCenterSq - r * r)
            if disc >= 0 {
                let farEdge = projOnTrack + disc.squareRoot()
                let maxAllowed = max(0.0, farEdge - 2.0 * Double(offset))
                if effectiveDist > maxAllowed { effectiveDist = maxAllowed }
            }
        }
        let pointD = intersection + IPoint(KiMath.round(-vecVia.x * (effectiveDist + Double(offset))),
                                           KiMath.round(-vecVia.y * (effectiveDist + Double(offset))))
        // the bend's points, each side, along each track
        var junctionBSeg2 = IPoint.zero, junctionBSeg1 = IPoint.zero, junctionASeg2 = IPoint.zero, junctionASeg1 = IPoint.zero
        if twoSegments {
            let hw = Double(trackHalfwidth)
            junctionBSeg2 = start + IPoint(KiMath.round(vecT.y * hw), KiMath.round(-vecT.x * hw))
            junctionASeg2 = start + IPoint(KiMath.round(-vecT.y * hw), KiMath.round(vecT.x * hw))
            junctionBSeg1 = start + IPoint(KiMath.round(vecVia.y * hw), KiMath.round(-vecVia.x * hw))
            junctionASeg1 = start + IPoint(KiMath.round(-vecVia.y * hw), KiMath.round(vecVia.x * hw))
        }
        var skipJunctionA = false, skipJunctionB = false
        if twoSegments {
            let transA = DPoint(junctionASeg2 - junctionASeg1), anchorDirA = DPoint(pointA - junctionASeg1)
            skipJunctionA = transA.x * anchorDirA.x + transA.y * anchorDirA.y < 0
            let transB = DPoint(junctionBSeg2 - junctionBSeg1), anchorDirB = DPoint(pointB - junctionBSeg1)
            skipJunctionB = transB.x * anchorDirB.x + transB.y * anchorDirB.y < 0
        }
        let anchorA = twoSegments ? junctionASeg1 : pointA
        let anchorB = twoSegments ? junctionBSeg1 : pointB
        var pts = [anchorA, anchorB, IPoint.zero, pointD, IPoint.zero]
        guard computeAnchorPoints(params, layer, other, otherPos, &pts) else { return false }
        // (C and E as far each side of the track's line, for a track off the centre of a round one)
        if isRound(other) {
            let perpVia = DPoint(-vecVia.y, vecVia.x)
            let padOffset = DPoint(otherPos - intersection)
            let perpDistToCenter = padOffset.x * perpVia.x + padOffset.y * perpVia.y
            if abs(perpDistToCenter) > Double(padRadius) * 0.1 {
                let d = abs(perpDistToCenter)
                if d < Double(padRadius) {
                    let maxSymmetric = Double(padRadius) - d
                    let preferredWidth = KiMath.round(Double(width(other)) * params.bestWidthRatio)
                    var maxHalfWidth = preferredWidth / 2
                    if params.maxWidth > 0 { maxHalfWidth = min(maxHalfWidth, params.maxWidth / 2) }
                    let symHalfWidth = min(maxSymmetric, Double(maxHalfWidth))
                    if symHalfWidth > Double(trackHalfwidth) {
                        let center = DPoint(otherPos)
                        let r = Double(padRadius)
                        func findCircleLineIntersection(_ perpDist: Double) -> IPoint {
                            let projAlongTrack = padOffset.x * vecVia.x + padOffset.y * vecVia.y
                            let lineOrigin = DPoint(intersection) + vecVia * projAlongTrack + perpVia * perpDist
                            let oc = lineOrigin - center
                            let bCoeff = oc.x * vecVia.x + oc.y * vecVia.y
                            let cCoeff = oc.x * oc.x + oc.y * oc.y - r * r
                            let disc = bCoeff * bCoeff - cCoeff
                            if disc < 0 { return IPoint(KiMath.round(lineOrigin.x), KiMath.round(lineOrigin.y)) }
                            let sqrtDisc = disc.squareRoot()
                            let t1 = -bCoeff - sqrtDisc, t2 = -bCoeff + sqrtDisc
                            let p1 = lineOrigin + vecVia * t1, p2 = lineOrigin + vecVia * t2
                            let intPt = DPoint(intersection)
                            if (p1 - intPt).norm < (p2 - intPt).norm { return IPoint(KiMath.round(p1.x), KiMath.round(p1.y)) }
                            return IPoint(KiMath.round(p2.x), KiMath.round(p2.y))
                        }
                        pts[2] = findCircleLineIntersection(-symHalfWidth)
                        pts[4] = findCircleLineIntersection(symHalfWidth)
                    }
                }
            }
        }
        if !params.curvedEdges {
            if twoSegments {
                corners.append(pointA)
                corners.append(pointB)
                if !skipJunctionB { corners.append(junctionBSeg2) }
                corners += [pts[1], pts[2], pts[3], pts[4], pts[0]]
                if !skipJunctionA { corners.append(junctionASeg2) }
            } else {
                corners = pts
            }
            return true
        }
        if isRound(other) {
            if twoSegments {
                var curvePoly: [IPoint] = []
                computeCurvedForRoundShape(params, &curvePoly, layer, trackHalfwidth, vecVia, other, otherPos, &pts)
                corners.append(pointB)
                if !skipJunctionB { corners.append(junctionBSeg2) }
                corners += curvePoly
                if !skipJunctionA { corners.append(junctionASeg2) }
                corners.append(pointA)
            } else {
                computeCurvedForRoundShape(params, &corners, layer, trackHalfwidth, vecT, other, otherPos, &pts)
            }
        } else {
            var tdWidth = KiMath.round(Double(width(other)) * params.bestWidthRatio)
            if params.maxWidth > 0 && params.maxWidth < tdWidth { tdWidth = params.maxWidth }
            if twoSegments {
                var curvePoly: [IPoint] = []
                computeCurvedForRectShape(params, &curvePoly, tdWidth, trackHalfwidth, pts, intersection, other, otherPos, layer)
                corners.append(pointB)
                if !skipJunctionB { corners.append(junctionBSeg2) }
                corners += curvePoly
                if !skipJunctionA { corners.append(junctionASeg2) }
                corners.append(pointA)
            } else {
                computeCurvedForRectShape(params, &corners, tdWidth, trackHalfwidth, pts, intersection, other, otherPos, layer)
            }
        }
        return true
    }
}

// MARK: - Onto the board

extension Teardrops {
    /// The Set Teardrops dialog with "add teardrops with default values for shape" and no filters
    /// (DIALOG_GLOBAL_EDIT_TEARDROPS::TransferDataFromWindow and processItem): each via, if asked, and each plated
    /// pad, and each surface or connector pad, if asked, given the board's settings for its shape (round: a round
    /// pad, or an oval one as long as it is wide, and a via; else the other shapes'), teardrops on; the track ends'
    /// settings on where asked. The board is changed where it stands; the settings as the dialog leaves them are
    /// handed back (for the board's project, and for making the teardrops).
    @discardableResult
    public static func applySettings(_ s: TeardropSettings, to board: KiCadBoard) -> TeardropSettings {
        clearLegacyTeardrops(board)
        var kept = s
        if s.vias {
            for node in board.root.items where node.head == "via" {
                var p = s.round
                p.enabled = true
                setParameters(node, p, before: ["net", "uuid"])
            }
        }
        for fp in board.root.all("footprint") {
            for pad in fp.all("pad") {
                let attribute = pad.text(at: 1) ?? ""
                guard (s.pthPads && attribute == "thru_hole") || (s.smdPads && (attribute == "smd" || attribute == "connect")) else { continue }
                var p = isRoundPad(pad) ? s.round : s.rect
                p.enabled = true
                setParameters(pad, p, before: ["tenting", "uuid"])
            }
        }
        // (the track ends': on where asked, else as they were)
        if s.trackToTrack { kept.track.enabled = true }
        return kept
    }

    /// The dialog's "remove all teardrops": every pad's and via's teardrops off (their settings dropped where that
    /// leaves them KiCad's defaults), and the track ends' off; the settings so changed handed back
    @discardableResult
    public static func disableAll(on board: KiCadBoard, settings: TeardropSettings) -> TeardropSettings {
        clearLegacyTeardrops(board)
        var kept = settings
        let items = board.root.items.filter { $0.head == "via" } + board.root.all("footprint").flatMap { $0.all("pad") }
        for node in items {
            var p = TeardropParameters(item: node)
            p.enabled = false
            if p == TeardropParameters() {
                node.items.removeAll { $0.head == "teardrops" }
            } else {
                setParameters(node, p, before: node.head == "via" ? ["net", "uuid"] : ["tenting", "uuid"])
            }
        }
        kept.track.enabled = false
        return kept
    }

    /// TEARDROP_MANAGER::IsRound of a pad as written: round, or oval and as long as wide
    static func isRoundPad(_ pad: SExpr) -> Bool {
        let shape = pad.text(at: 2) ?? ""
        let size = pad["size"]
        return shape == "circle" || (shape == "oval" && size?.number(at: 0) == size?.number(at: 1))
    }

    /// A pad's or via's settings set: where its `(teardrops ...)` is, else before the first of `before`
    static func setParameters(_ node: SExpr, _ p: TeardropParameters, before: [String]) {
        if let i = node.items.firstIndex(where: { $0.head == "teardrops" }) {
            node.items[i] = p.node
        } else if let i = node.items.firstIndex(where: { before.contains($0.head ?? "") }) {
            node.items.insert(p.node, at: i)
        } else {
            node.items.append(p.node)
        }
    }

    /// A teardrop as KiCad writes it (PCB_IO_KICAD_SEXPR::format of a ZONE made by createTeardrop or
    /// createTeardropMask, no uuid): its net (none on a mask), its layer, the hatch of an invisible border, its
    /// priority, its type, its pads joined solidly with no clearance (a mask teardrop's the zone defaults': none
    /// solidly, half a millimetre), its least width, its fill (islands kept), its outline, and its fill as its outline
    /// until the zones are filled
    func zoneNode(_ t: Teardrop) -> SExpr {
        var items: [SExprConvertible] = []
        if !t.isMask && (drc.world.netCodes[t.net] ?? 0) > 0 { items.append(SExpr("net", t.net)) }
        items.append(SExpr("layer", t.layer))
        items.append(SExpr("hatch", Keyword("none"), 0.1))
        if t.priority > 0 { items.append(SExpr("priority", t.priority)) }
        items.append(SExpr("attr", SExpr("teardrop", SExpr("type", Keyword(t.kind == .padVia ? "padvia" : "track_end")))))
        if t.isMask {
            items.append(SExpr("connect_pads", SExpr("clearance", 0.5)))
            items.append(SExpr("min_thickness", Double(max(25_400, t.maskExpansion)) / 1e6))
        } else {
            items.append(SExpr("connect_pads", Keyword("yes"), SExpr("clearance", 0)))
            items.append(SExpr("min_thickness", 0.0254))
        }
        items.append(SExpr("fill", Keyword("yes"), SExpr("island_removal_mode", 1)))
        func pts(_ points: [IPoint]) -> SExpr {
            SExpr("pts", points.map { SExpr("xy", Double($0.x) / 1e6, Double($0.y) / 1e6) as SExprConvertible })
        }
        items.append(SExpr("polygon", pts(t.outline)))
        items.append(SExpr("filled_polygon", SExpr("layer", t.layer), pts(t.outline)))
        return SExpr("zone", items)
    }

    /// BOARD_ITEM::ptr_cmp of two zones: by their layers' ids, then their uuids
    static func precedes(_ a: ([Int], [UInt8]), _ b: ([Int], [UInt8])) -> Bool {
        if a.0 != b.0 { return a.0.lexicographicallyPrecedes(b.0) }
        return a.1.lexicographicallyPrecedes(b.1)
    }

    /// The board with its teardrops made again: its own taken away (BulkRemoveStaleTeardrops), these put among its
    /// zones where KiCad writes them (in the order of their layers and the uuids they were made with); a board of
    /// legacy teardrops as it is
    public func board(_ board: KiCadBoard) -> KiCadBoard {
        if legacy { return board.copy() }
        let out = Self.withoutTeardrops(board)
        func key(_ zone: SExpr) -> ([Int], [UInt8]) {
            let names = zone["layers"]?.arguments.map(\.text) ?? zone.value("layer").map { [$0] } ?? []
            return (names.compactMap { BoardDRC.layerID($0) }.sorted(), Self.kiid(zone.value("uuid") ?? ""))
        }
        // (one after another in KiCad's order, each before the first of the board's own zones written after it)
        for t in teardrops.sorted(by: { Self.precedes(([$0.layerID], $0.uuid), ([$1.layerID], $1.uuid)) }) {
            let node = zoneNode(t)
            let items = out.root.items
            if let i = items.firstIndex(where: { $0.head == "zone" && $0["attr"]?["teardrop"] == nil
                                                 && Self.precedes(([t.layerID], t.uuid), key($0)) }) {
                out.root.items.insert(node, at: i)
            } else if let last = items.lastIndex(where: { $0.head == "zone" })
                        ?? items.lastIndex(where: { ["segment", "arc", "via"].contains($0.head ?? "") }) {
                out.root.items.insert(node, at: last + 1)
            } else if let first = items.firstIndex(where: { ["group", "generated", "embedded_fonts", "embedded_files"].contains($0.head ?? "") }) {
                out.root.items.insert(node, at: first)
            } else {
                out.root.items.append(node)
            }
        }
        return out
    }
}
