// Ported from KiCad 10.0.7: what the design rules engine reads of a board's items, as KiCad's BOARD_ITEMs give it:
// pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr_parser.cpp (layer masks such as *.Cu, a zone's settings and its being
// filled, groups), pcbnew/pcb_track.cpp (a via's layer set and tenting, GetEffectiveShape of tracks, arcs and vias,
// FlashLayer), pcbnew/pad.cpp (GetEffectiveShape, GetLayerSet, the pad's properties' values), pcbnew/footprint.cpp
// (GetFPIDAsString, GetSheetname, fields, GetLocalZoneConnection), pcbnew/zone.cpp (GetLayer, GetLocalClearance),
// pcbnew/board.cpp (GetEnabledLayers, GetLayerName) and pcbnew/drc/drc_engine.cpp (InitEngine: the rules file beside
// the board's project).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

extension BoardDRC {
    /// The board's design rules engine and its items as the engine sees them
    final class RuleState {
        let engine: DesignRuleEngine
        let board: RuleBoard
        /// The board's zones (rule areas among them) and footprints, as the engine's functions look them up
        let zones: [RuleItem]
        let footprints: [RuleItem]
        /// The zones by the board's node of each (a teardrop, which KiCad writes with no uuid, is told apart so)
        var zoneByNode: [ObjectIdentifier: RuleItem] = [:]
        /// The other items, by what they are made from, as asked for
        var byKey: [String: RuleItem] = [:]
        /// The copper items by uuid, once asked
        var copperByUUID: [String: CopperItem]?
        /// The board's copper items, the check's, or made when first asked
        var copper: Copper?

        func copper(_ drc: BoardDRC) -> Copper {
            if let copper { return copper }
            let c = drc.makeCopper()
            copper = c
            return c
        }

        init(engine: DesignRuleEngine, board: RuleBoard, zones: [RuleItem], footprints: [RuleItem]) {
            (self.engine, self.board, self.zones, self.footprints) = (engine, board, zones, footprints)
        }

        /// The user's rules (none if they did not parse)
        var hasUserRules: Bool { !engine.userConstraintTypes.isEmpty }
    }

    /// The layers of a mask in a board file (lookUpLayerSet: a layer's name, *.Cu every copper layer KiCad has,
    /// *In.Cu the inner ones, F&B.Cu, *.Mask and the like both sides')
    static func kiLayerSet(_ names: [String]) -> KiLayerSet {
        var s = KiLayerSet()
        for n in names {
            switch n {
            case "*.Cu": s = s.union(.allCu)
            case "*In.Cu": s = s.union(.internalCu)
            case "F&B.Cu": s = s.union(.externalCu)
            case "*.Adhes": s = s.union(KiLayerSet([KiLayer.bAdhes, KiLayer.fAdhes]))
            case "*.Paste": s = s.union(KiLayerSet([KiLayer.bPaste, KiLayer.fPaste]))
            case "*.Mask": s = s.union(KiLayerSet([KiLayer.bMask, KiLayer.fMask]))
            case "*.SilkS": s = s.union(KiLayerSet([KiLayer.bSilkS, KiLayer.fSilkS]))
            case "*.Fab": s = s.union(KiLayerSet([KiLayer.bFab, KiLayer.fFab]))
            case "*.CrtYd": s = s.union(KiLayerSet([KiLayer.bCrtYd, KiLayer.fCrtYd]))
            default: if let l = KiLayer.id(n) { s.insert(l) }
            }
        }
        return s
    }

    /// A node's layers as a board file gives them
    static func kiLayerSet(_ node: SExpr) -> KiLayerSet {
        kiLayerSet(node["layers"]?.arguments.map(\.text) ?? node.value("layer").map { [$0] } ?? [])
    }

    /// A router layer's KiCad layer
    func kiLayer(_ r: Int) -> Int { KiLayer.fromRouter(r, copperLayers: world.copperLayers) }

    /// A KiCad copper layer's router layer, if the board has it
    func routerLayer(_ l: Int) -> Int? { KiLayer.toRouter(l, copperLayers: world.copperLayers) }

    /// The setup the implicit rules are made of
    static func ruleSetup(_ s: Settings, project: [String: Any]?) -> DesignRuleEngine.Setup {
        var setup = DesignRuleEngine.Setup()
        setup.minClearance = s.minClearance
        setup.trackMinWidth = s.minTrackWidth
        setup.minThroughDrill = s.minThroughDrill
        setup.viasMinAnnularWidth = s.minViaAnnularWidth
        setup.viasMinSize = s.minViaDiameter
        setup.holeToHoleMin = s.holeToHole
        setup.minResolvedSpokes = s.minResolvedSpokes
        setup.silkClearance = s.silkClearance
        setup.holeClearance = s.holeClearance
        setup.copperEdgeClearance = s.edgeClearance
        setup.microViasMinDrill = s.minMicroViaDrill
        setup.microViasMinSize = s.minMicroViaDiameter
        let rules = ((project?["board"] as? [String: Any])?["design_settings"] as? [String: Any])?["rules"] as? [String: Any] ?? [:]
        func mm(_ key: String, _ value: inout Int) {
            if let v = (rules[key] as? NSNumber)?.doubleValue { value = BoardWorld.iuScaled(v) }
        }
        mm("min_connection", &setup.minConnection)
        mm("min_text_height", &setup.minSilkTextHeight)
        mm("min_text_thickness", &setup.minSilkTextThickness)
        return setup
    }

    /// The board's rules engine: its implicit rules and the rules of `rulesText` (a .kicad_dru's)
    func makeRuleState(project: [String: Any]?, rulesText: String?) -> RuleState {
        // its layers: those its layer table enables, with their user names
        var enabled = KiLayerSet()
        var userNames: [Int: String] = [:]
        for l in board.root["layers"]?.arguments ?? [] {
            guard let name = l.text(at: 0), let id = KiLayer.id(name) else { continue }
            enabled.insert(id)
            if let user = l.text(at: 2), !user.isEmpty { userNames[id] = user }
        }
        let rb = RuleBoard(copperLayers: world.copperLayers, enabledLayers: enabled)
        rb.userLayerNames = userNames
        rb.netNames = Set(world.netCodes.keys.filter { !$0.isEmpty })
        rb.epsilon = settings.epsilon
        rb.maxError = settings.maxError
        let ns = project?["net_settings"] as? [String: Any]
        rb.hasComponentClasses = !((project?["component_class_settings"] as? [String: Any])?["assignments"] as? [Any] ?? []).isEmpty
            || (ns == nil && false)
        // its groups: each member's names of the groups it is in, the innermost first
        var parentGroup: [String: (name: String, uuid: String)] = [:]
        func readGroups(_ node: SExpr) {
            for g in node.all("group") {
                let name = g.text(at: 0) ?? ""
                let uuid = g.value("uuid") ?? ""
                for m in g["members"]?.arguments ?? [] { parentGroup[m.text] = (name, uuid) }
            }
        }
        readGroups(board.root)
        func groups(_ uuid: String) -> [String] {
            var out: [String] = []
            var cur = uuid
            var seen = Set<String>()
            while let g = parentGroup[cur], seen.insert(g.uuid).inserted {
                out.append(g.name)
                cur = g.uuid
            }
            return out
        }
        // the footprints
        let fps = board.root.all("footprint")
        var footprintItems: [RuleItem] = []
        for (i, fp) in fps.enumerated() {
            let item = RuleItem(.footprint, uuid: fp.value("uuid") ?? "")
            let placement = BoardWorld.FootprintPlacement(fp)
            item.footprintIndex = i
            item.reference = placement.reference
            item.fpid = fp.text(at: 0) ?? ""
            item.layer = KiLayer.id(fp.value("layer") ?? "F.Cu") ?? KiLayer.fCu
            item.layerSet = KiLayerSet([item.layer])
            item.flipped = item.layer == KiLayer.bCu
            item.isOnCopper = true
            item.sheetName = fp.value("sheetname") ?? ""
            for p in fp.all("property") {
                if let name = p.text(at: 0) { item.fields[name] = p.text(at: 1) ?? "" }
            }
            item.properties["Reference"] = .string(placement.reference)
            item.properties["Library Link"] = .string(item.fpid)
            item.properties["Locked"] = .bool(fp.value("locked") == "yes" || fp.flag("locked"))
            item.groups = groups(item.uuid)
            if let v = fp.value("zone_connect").flatMap(Int.init), let z = RuleZoneConnection(rawValue: v) { item.zoneConnection = z }
            let world = self.world
            item.courtyardProvider = { world.courtyards(fp) }
            footprintItems.append(item)
        }
        // the zones: the board's, then each footprint's
        var zoneItems: [RuleItem] = []
        var zoneByNode: [ObjectIdentifier: RuleItem] = [:]
        for node in board.root.all("zone") {
            let z = zoneRuleItem(node, footprint: nil, groups: groups)
            zoneItems.append(z)
            zoneByNode[ObjectIdentifier(node)] = z
        }
        for (i, fp) in fps.enumerated() {
            for node in fp.all("zone") {
                let z = zoneRuleItem(node, footprint: footprintItems[i], groups: groups)
                zoneItems.append(z)
                zoneByNode[ObjectIdentifier(node)] = z
            }
        }
        rb.zones = zoneItems
        rb.footprints = footprintItems
        readLockedAndWidths(rb)
        let engine = DesignRuleEngine(board: rb, setup: Self.ruleSetup(settings, project: project), netClasses: netClasses,
                                      nets: world.netCodes.keys.sorted(), keepouts: zoneItems, rulesText: rulesText)
        let state = RuleState(engine: engine, board: rb, zones: zoneItems, footprints: footprintItems)
        state.zoneByNode = zoneByNode
        // (a footprint's box, FOOTPRINT::GetBoundingBox, of its pads among the rest, made when first asked)
        let drc = self
        for (i, fp) in fps.enumerated() {
            footprintItems[i].bboxProvider = { [unowned state] in drc.footprintBox(i, fp, state.copper(drc)) }
        }
        return state
    }

    /// The items locked, and the drawings' and texts' widths as the rules read them: a rectangle's its end's x less its
    /// start's (on the board, its footprint's placement taken: 0 if that turned it into a polygon), any other
    /// drawing's 0, a text's or field's its font's width
    func readLockedAndWidths(_ rb: RuleBoard) {
        func locked(_ node: SExpr) -> Bool { node.value("locked") == "yes" || node.flag("locked") }
        func visit(_ node: SExpr, placement: BoardWorld.FootprintPlacement?) {
            guard let head = node.head, let uuid = node.value("uuid") else { return }
            if locked(node) { rb.lockedItems.insert(uuid) }
            if head == "gr_text" || head == "fp_text" || head == "property" {
                // (its size: its height, then its width)
                if let size = node["effects"]?["font"]?["size"] { rb.itemWidths[uuid] = BoardWorld.iu(size, 1) }
            } else if head.hasPrefix("gr_") || head.hasPrefix("fp_") {
                let d = world.readDrawing(node, placement: placement)
                rb.itemWidths[uuid] = d.map { $0.kind == .rect ? $0.end.x - $0.start.x : 0 } ?? 0
            }
        }
        for node in board.root.items { visit(node, placement: nil) }
        for fp in board.root.all("footprint") {
            let placement = BoardWorld.FootprintPlacement(fp)
            for node in fp.items where node.head != "pad" { visit(node, placement: placement) }
        }
    }

    /// A zone as the rules see it (ZONE): its name, rule area settings, layers, outline, fills, net and pad settings
    func zoneRuleItem(_ node: SExpr, footprint: RuleItem?, groups: (String) -> [String]) -> RuleItem {
        let item = RuleItem(.zone, uuid: node.value("uuid") ?? "")
        item.parentFootprint = footprint
        item.zoneName = node.value("name") ?? ""
        let keepout = node["keepout"]
        item.isRuleArea = keepout != nil || node["placement"] != nil
        func notAllowed(_ name: String) -> Bool { keepout?[name]?.text(at: 0) == "not_allowed" }
        if item.isRuleArea {
            if keepout == nil {
                // (ZONE_SETTINGS' defaults)
                (item.keepoutTracks, item.keepoutVias, item.keepoutPads) = (true, true, true)
            } else {
                item.keepoutTracks = notAllowed("tracks")
                item.keepoutVias = notAllowed("vias")
                item.keepoutPads = notAllowed("pads")
                item.keepoutZoneFills = notAllowed("copperpour")
                item.keepoutFootprints = notAllowed("footprints")
            }
        }
        item.layerSet = Self.kiLayerSet(node)
        item.layer = item.layerSet.count == 1 ? item.layerSet.layers[0] : KiLayer.undefined
        item.isOnCopper = item.layerSet.intersects(.allCu)
        item.connected = !item.isRuleArea
        let net = Self.netName(node)
        item.netName = item.isRuleArea ? "" : net
        item.netCode = item.isRuleArea ? 0 : world.netCodes[net] ?? 0
        item.netClass = ruleNetClass(item.netName)
        item.zoneOutline = BoardWorld.zoneOutline(node)
        item.bbox = RuleFunctions.polyBox(item.zoneOutline!)
        item.zonePriority = node.value("priority").flatMap(Int.init) ?? 0
        item.isTeardrop = node["attr"]?["teardrop"] != nil
        item.zoneMinThickness = node["min_thickness"].map { BoardWorld.iu($0, 0) } ?? 250_000
        let connect = node["connect_pads"]
        let args = connect?.arguments.map(\.text) ?? []
        item.zonePadConnection = args.contains("yes") ? .full : args.contains("no") ? .none : args.contains("thru_hole_only") ? .thtThermal : .thermal
        let clearance = connect?["clearance"].map { BoardWorld.iu($0, 0) } ?? 0
        item.localClearance = (item.isRuleArea ? 0 : clearance, "zone")
        let fill = node["fill"]
        item.zoneThermalGap = fill?["thermal_gap"].map { BoardWorld.iu($0, 0) } ?? 500_000
        item.zoneSpokeWidth = fill?["thermal_bridge_width"].map { BoardWorld.iu($0, 0) } ?? 500_000
        item.zoneFilled = fill?.text(at: 0) == "yes"
        for f in node.all("filled_polygon") {
            guard let l = f.value("layer").flatMap(KiLayer.id) else { continue }
            let pts = (f["pts"]?.arguments ?? []).filter { $0.head == "xy" }.map { BoardWorld.point($0) }
            guard pts.count >= 3 else { continue }
            item.zoneFills[l, default: []].append(LineChain(pts, closed: true))
        }
        item.properties["Locked"] = .bool(node.value("locked") == "yes" || node.flag("locked"))
        item.groups = groups(item.uuid)
        return item
    }

    /// Any board item as the rules see it: a copper item's, a zone's or footprint's, or one made of the item's
    /// layers and shapes (a drawing, text or field off copper)
    func ruleItem(_ b: BoardItem, _ c: Copper) -> RuleItem {
        if let cu = b.copper { return ruleItem(cu, c) }
        // (a track or arc, which the silkscreen's items make of their own)
        if b.kind == .track || b.kind == .arc, let cu = copperItem(b.uuid, c) { return ruleItem(cu, c) }
        if b.kind == .zone, let z = ruleZone(b.node, uuid: b.uuid, footprint: b.footprint) { return z }
        let key = "board \(b.uuid) \(b.footprint ?? -1)"
        if let r = ruleState.byKey[key] { return r }
        let kind: RuleItem.Kind
        switch b.kind {
        case .track: kind = .track
        case .arc: kind = .arc
        case .via: kind = .via
        case .pad: kind = .pad
        case .shape: kind = .shape
        case .text: kind = .text
        case .field: kind = .field
        case .zone: kind = .zone
        }
        let r = RuleItem(kind, uuid: b.uuid)
        r.parentFootprint = b.footprint.map { ruleState.footprints[$0] }
        r.layerSet = b.node.map { Self.kiLayerSet($0) } ?? KiLayerSet(b.layers.compactMap(KiLayer.id))
        r.layer = b.node.flatMap { BoardWorld.itemLayer($0) }.flatMap(KiLayer.id) ?? r.layerSet.layers.first ?? KiLayer.undefined
        if kind == .text || kind == .field { r.layer = b.layers.first.flatMap(KiLayer.id) ?? r.layer }
        r.isOnCopper = r.layerSet.intersects(.allCu)
        let shapes = b.shapes
        r.effectiveShape = { _ in shapes }
        r.compoundShape = b.compound
        r.bbox = b.bbox
        r.netClass = ruleNetClass("")
        r.netCode = 0
        if let node = b.node { r.properties["Locked"] = .bool(node.value("locked") == "yes" || node.flag("locked")) }
        if kind == .field, let name = b.node?.text(at: 0) { r.properties["Name"] = .string(name) }
        ruleState.byKey[key] = r
        return r
    }

    // MARK: - Assertions (DRC_TEST_PROVIDER_MISC::testAssertions)

    /// Each item of the board (forEachGeometryItem's, every kind) against each assertion of the rules: one whose
    /// condition it meets and whose test is false is a failure (the rule's layers asked of no item: KiCad only says
    /// so)
    func checkAssertions(_ out: inout Report, _ c: Copper, _ items: [BoardItem]) {
        let engine = ruleState.engine
        guard engine.hasRules(.assertion), !out.exceeded("assertion_failure") else { return }
        // (the items the port does not make: dimensions, text boxes, tables, barcodes, targets)
        for node in board.root.items + board.root.all("footprint").flatMap(\.items) {
            switch node.head ?? "" {
            case "dimension", "gr_text_box", "fp_text_box", "table", "gr_table", "barcode", "target", "gr_target":
                ruleState.board.unsupported.insert("assertions of a \(node.head!)")
            default: break
            }
        }
        func test(_ item: RuleItem) {
            guard !out.exceeded("assertion_failure") else { return }
            engine.processAssertions(item) { constraint in
                out.add("assertion_failure", "(\(constraint.ruleName))", [item.uuid], rule: constraint.parentRule)
            }
        }
        // the items in forEachGeometryItem's order: the board's, then each footprint's and the footprint itself
        var byFootprint: [Int: [BoardItem]] = [:]
        for b in items {
            if let f = b.footprint { byFootprint[f, default: []].append(b) } else { test(ruleItem(b, c)) }
        }
        for (f, fp) in ruleState.footprints.enumerated() {
            for b in byFootprint[f] ?? [] { test(ruleItem(b, c)) }
            test(fp)
        }
    }

    /// An item's net class as the rules see it (GetEffectiveNetClass)
    func ruleNetClass(_ net: String) -> RuleItem.NetClassRef {
        let e = netClasses.effective(net)
        return RuleItem.NetClassRef(name: e.name, constituents: e.constituents, clearanceParent: e.clearanceParent ?? "Default")
    }

    /// A zone as the rules see it: by the board's node of it where there is one, else by its uuid and footprint
    func ruleZone(_ node: SExpr?, uuid: String, footprint: Int?) -> RuleItem? {
        if let node, let z = ruleState.zoneByNode[ObjectIdentifier(node)] { return z }
        return ruleState.zones.first { $0.uuid == uuid && $0.parentFootprint?.footprintIndex == footprint }
    }

    /// A copper item as the rules see it, made once
    func ruleItem(_ c: CopperItem, _ copper: Copper) -> RuleItem {
        if let r = c.ruleItem { return r }
        let r: RuleItem
        switch c.kind {
        case .zone:
            r = ruleZone(c.zoneNode, uuid: c.uuid, footprint: c.footprint) ?? RuleItem(.zone, uuid: c.uuid)
        case .track, .arc:
            r = RuleItem(c.kind == .track ? .track : .arc, uuid: c.uuid)
            let l = c.layers.first.map(kiLayer) ?? KiLayer.undefined
            r.layer = l
            r.layerSet = KiLayerSet([l])
            if let shape = c.shapes[c.layers.first ?? 0]?.first {
                r.effectiveShape = { _ in [shape] }
                r.bbox = c.kind == .track ? RuleItem.trackBox(c.trackStart, c.trackEnd, width: c.trackWidth)
                    : RuleItem.arcBox(shape.bbox, width: c.trackWidth)
                let maxError = settings.maxError
                r.polygon = { _ in
                    if case .arc(let a) = shape {
                        return PadPolygon.arc(start: a.start, mid: a.mid, end: a.end, width: c.trackWidth, maxError: maxError, errorLocation: .outside)
                    }
                    return PadPolygon.oval(start: c.trackStart, end: c.trackEnd, width: c.trackWidth, maxError: maxError,
                                           errorLocation: .outside)
                }
            }
            r.properties["Width"] = .int(c.trackWidth)
        case .via:
            r = RuleItem(.via, uuid: c.uuid)
            guard let v = c.via else { break }
            r.viaType = v.viaType
            r.layerSet = KiLayerSet(c.layers.map(kiLayer))
            // (PCB_VIA::GetLayer: its drill's start, the upper of its layers once SanitizeLayers has put them in
            // order, F.Cu for a through via)
            r.layer = v.viaType == .through ? KiLayer.fCu : c.layers.min().map(kiLayer) ?? KiLayer.fCu
            r.hasHole = true
            r.hasDrilledHole = true
            r.holeShape = c.hole
            r.bbox = RuleItem.viaBox(v.start, diameter: v.diameter)
            let flashed = c.flashed
            let toRouter = { (l: Int) in self.routerLayer(l) }
            r.effectiveShape = { l in
                // (PCB_VIA::GetEffectiveShape: its copper where it is flashed, else its hole)
                if l == KiLayer.undefined { return [.circle(center: v.start, radius: v.diameter / 2)] }
                if let rl = toRouter(l) {
                    return [.circle(center: v.start, radius: (flashed.contains(rl) ? v.diameter : v.drill) / 2)]
                }
                return KiLayer.isCopper(l) ? [.circle(center: v.start, radius: v.drill / 2)] : [.circle(center: v.start, radius: v.diameter / 2)]
            }
            let maxError = settings.maxError
            r.polygon = { _ in PolySet([[PadPolygon.circle(center: v.start, radius: v.diameter / 2, maxError: maxError, errorLocation: .outside)]]) }
            let typeName: String
            switch v.viaType {
            case .blind: typeName = "Blind"
            case .buried: typeName = "Buried"
            case .microVia: typeName = "Micro"
            default: typeName = "Through"
            }
            r.properties["Via Type"] = .enumString(typeName)
            r.properties["Diameter"] = .int(v.diameter)
            r.properties["Hole"] = .int(v.drill)
        case .pad:
            r = RuleItem(.pad, uuid: c.uuid)
            guard let p = c.pad, let f = c.footprint else { break }
            r.parentFootprint = ruleState.footprints[f]
            r.padAttribute = p.pad.attribute
            let node = board.root.all("footprint")[f].all("pad").first { $0.value("uuid") == c.uuid }
            r.layerSet = node.map { Self.kiLayerSet($0) } ?? KiLayerSet()
            // (PAD::GetLayer: BOARD_ITEM's m_layer, F.Cu as a pad read from a file has it; its Layer property is its
            // footprint's)
            r.layer = KiLayer.fCu
            r.hasHole = p.hasHole
            r.hasDrilledHole = p.hasDrilledHole
            r.holeShape = c.hole
            var box = c.bbox
            if !c.hasHole { box.merge(p.pad.pos) }
            r.bbox = box
            r.compoundShape = true
            let toRouter = { (l: Int) in self.routerLayer(l) }
            r.effectiveShape = { l in
                if l == KiLayer.edgeCuts { return c.hole.map { [$0] } ?? [] }
                if let rl = toRouter(l) { return c.anyLayerShapes(rl) }
                // (off copper: a plated hole's pad where it is not flashed, its hole)
                if p.pad.attribute == .pth && !r.layerSet.contains(l) { return c.hole.map { [$0] } ?? [] }
                return c.outline
            }
            let world = self.world
            let primitives = p.primitives
            r.polygon = { _ in p.pad.kind == .custom ? nil : world.padPolygon(p.pad, primitives: primitives, errorLocation: .outside) }
            let attr: String
            switch p.pad.attribute {
            case .pth: attr = "Through-hole"
            case .smd: attr = "SMD"
            case .conn: attr = "Edge connector"
            case .npth: attr = "NPTH, mechanical"
            }
            let shape: String
            switch p.pad.kind {
            case .circle: shape = "Circle"
            case .rect: shape = "Rectangle"
            case .oval: shape = "Oval"
            case .trapezoid: shape = "Trapezoid"
            case .roundrect: shape = "Rounded rectangle"
            case .chamferedRect: shape = "Chamfered rectangle"
            case .custom: shape = "Custom"
            }
            r.properties["Pad Type"] = .enumString(attr)
            r.properties["Pad Shape"] = .enumString(shape)
            r.properties["Pad Number"] = .string(p.number)
            r.properties["Pin Name"] = .string(node?.value("pinfunction") ?? "")
            r.properties["Pin Type"] = .string(p.pinType)
            r.properties["Size X"] = .int(p.pad.size.x)
            r.properties["Size Y"] = .int(p.pad.size.y)
            r.properties["Hole Size X"] = .int(p.pad.drill.x)
            r.properties["Hole Size Y"] = .int(p.pad.drill.y)
            let props = node?["property"]?.arguments.map(\.text) ?? []
            let fab: [String: String] = ["pad_prop_bga": "BGA pad", "pad_prop_fiducial_glob": "Fiducial, global to board",
                                         "pad_prop_fiducial_loc": "Fiducial, local to footprint", "pad_prop_testpoint": "Test point pad",
                                         "pad_prop_heatsink": "Heatsink pad", "pad_prop_castellated": "Castellated pad",
                                         "pad_prop_mechanical": "Mechanical pad", "pad_prop_pressfit": "Press-fit pad"]
            r.properties["Fabrication Property"] = .enumString(props.compactMap { fab[$0] }.first ?? "None")
            if let o = c.clearanceOverride { r.clearanceOverride = o }
            if let v = node?.value("zone_connect").flatMap(Int.init), let z = RuleZoneConnection(rawValue: v) { r.zoneConnection = z }
            r.thermalGapOverride = node?["thermal_gap"].map { BoardWorld.iu($0, 0) }
            r.spokeWidthOverride = node?["thermal_bridge_width"].map { BoardWorld.iu($0, 0) }
        case .shape:
            r = RuleItem(.shape, uuid: c.uuid)
            if let f = c.footprint { r.parentFootprint = ruleState.footprints[f] }
            let l = c.layers.first.map(kiLayer) ?? KiLayer.undefined
            r.layer = l
            r.layerSet = KiLayerSet([l])
            let shapes = c.shapes[c.layers.first ?? 0] ?? []
            r.effectiveShape = { _ in shapes }
            r.compoundShape = true
            r.bbox = c.bbox
        }
        if c.kind != .zone {
            r.connected = c.connected
            r.netCode = c.netCode
            r.netName = c.netName
            r.netClass = ruleNetClass(c.netName)
            r.isOnCopper = c.copper
            r.netTieNets = copper.netTies[ObjectIdentifier(c)] ?? []
        }
        c.ruleItem = r
        return r
    }
}

