// Ported from KiCad 10.0.7: pcbnew/zone_filler.cpp (ZONE_FILLER::Fill: the zones' fills made in the order their
// knockouts need, isolated islands removed by each zone's mode, the iterative refill of zones that can take back what
// a removed island or a higher zone's fill left them, islands outside the board's outline dropped;
// zoneKnockoutMayInteract), pcbnew/zone.cpp (HigherPriority, SameNet, GetBoundingBox, IsIsland), pcbnew/
// pcb_io/kicad_sexpr/pcb_io_kicad_sexpr_parser.cpp (parseZONE: a zone's settings and their defaults),
// pcbnew/zone_settings.cpp (the defaults), pcbnew/connectivity/connectivity_algo.cpp (FillIsolatedIslandsMap),
// pcbnew/board.cpp (GetBoardPolygonOutlines with its outline inferred, ComputeBoundingBox of the board's edges) and
// pcbnew/pcb_io/kicad_sexpr/pcb_io_kicad_sexpr.cpp (a zone's fill as KiCad writes it).
// Copyright (C) 2014-2017 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// KiCad's zone filler of a board (ZONE_FILLER::Fill of its zones, as `pcbnew.ZONE_FILLER(board).Fill(board.Zones())`
/// fills them): each of the board's zones' fill on each of its layers, its islands. What the port does not make yet
/// (a rule file of the user's own, padstacks, pads and vias kept only on layers where something joins them, a barcode
/// or dimension on copper...) is named in `unsupported`, and a fill made where it matters may not be KiCad's.
public final class ZoneFiller {
    /// The fills: by zone (its uuid), by layer (its name), the polygons as KiCad holds them once filled (each an outline
    /// with its holes fractured into it)
    public private(set) var fills: [String: [String: PolySet]] = [:]
    /// The outlines of each fill KiCad keeps as islands (ZONE::IsIsland: those of a zone of no net, and those a zone
    /// that never removes islands, or removes them below an area, keeps)
    public private(set) var islands: [String: [String: Set<Int>]] = [:]
    /// What the board has that the port's filler does not make, by name
    public internal(set) var unsupported: Set<String> = []

    let drc: BoardDRC
    var world: BoardWorld { drc.world }
    let copper: BoardDRC.Copper
    let rules: [BoardDRC.ClearanceRule]
    /// The board's zones then its footprints' (forEachBoardAndFootprintZone's order)
    var zones: [FillZone] = []
    /// The board's own zones (BOARD::Zones), the ones filled
    var boardZones: [FillZone] { zones.filter { $0.footprint == nil } }
    let maxError: Int
    /// ADVANCED_CFG's ExtraFillMargin, 0.0005 mm
    let extraMargin = 500
    let worstClearance: Int
    let zoneKnockoutSlack: Int
    /// The board's outline (GetBoardPolygonOutlines, inferred from its edges' box where it cannot be made), and
    /// whether it could be made
    var boardOutline = PolySet()
    var outlineValid = false
    /// Each KiCad layer id's name, and the board's copper layers' ids
    var layerNames: [Int: String] = [:]
    var boardCopper: [Int] = []
    /// The fills before other zones' knockouts, the same-net aprons and the fills before hatching, for the
    /// iterative refill (m_preKnockoutFillCache, m_sameNetApronCache, m_preHatchSolidFillCache), by zone and layer
    var preKnockoutFill: [FillKey: PolySet] = [:]
    var sameNetApronCache: [FillKey: PolySet] = [:]
    var preHatchSolid: [FillKey: PolySet] = [:]
    /// Each board zone's fills as the connectivity last took them
    var cnFills: [ObjectIdentifier: [Int: PolySet]] = [:]
    let debugStage: ((String, FillZone, PolySet) -> Void)?
    /// The footprints' pads with their zone settings
    var padCache: [FillPad]?

    struct FillKey: Hashable {
        let zone: ObjectIdentifier
        let layer: Int
        init(_ z: FillZone, _ l: Int) { (zone, layer) = (ObjectIdentifier(z), l) }
    }

    /// The fills of `board`'s zones as KiCad's filler makes them, the board's project file's JSON in `project`
    public convenience init(board: KiCadBoard, project: [String: Any]? = nil) {
        self.init(board: board, project: project, debug: nil)
    }

    /// The same, each stage of each copper fill told `debug` (its name, the zone, the polygons then)
    init(board: KiCadBoard, project: [String: Any]?, debug: ((String, FillZone, PolySet) -> Void)?) {
        debugStage = debug
        drc = BoardDRC(board: board, project: project)
        maxError = drc.settings.maxError
        // (the connectivity built, as KiCad builds it reading the board: the nets it propagates are the items' nets)
        copper = drc.makeCopper()
        connectivity = drc.buildConnectivity(copper)
        rules = drc.clearanceRules(copper.items + copper.zones)
        worstClearance = drc.world.rules.maxClearance ?? 0
        zoneKnockoutSlack = extraMargin + drc.settings.maxError
        readLayers()
        readZones()
        noteUnsupported()
        fill()
    }

    public convenience init(board: KiCadBoard, projectURL: URL?) {
        let json = projectURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        self.init(board: board, project: json)
    }

    let connectivity: BoardDRC.Connectivity

    // MARK: - The zones

    /// ISLAND_REMOVAL_MODE
    enum IslandRemoval: Int { case always = 0, never, area }

    /// A zone as the filler sees it (ZONE): its outline and settings, and its fill on each layer
    final class FillZone {
        let node: SExpr
        let uuid: String
        /// The footprint it is of (its index), nil for the board's own
        let footprint: Int?
        let ruleArea: Bool
        let doNotAllowTracks: Bool, doNotAllowVias: Bool, doNotAllowPads: Bool, doNotAllowFootprints: Bool
        let doNotAllowZoneFills: Bool
        /// Its layers (KiCad's ids, in LSET's order)
        let layers: [Int]
        let net: Int
        let priority: Int
        /// TEARDROP_TYPE: 0 none, 2 a pad's or via's, 3 a track's end
        let teardropType: Int
        let minThickness: Int
        let localClearance: Int
        let padConnection: BoardDRC.ZoneConnection
        let thermalGap: Int
        let spokeWidth: Int
        let hatched: Bool
        let hatchThickness: Int, hatchGap: Int
        let hatchOrientation: EDAAngle
        let hatchSmoothingLevel: Int
        let hatchSmoothingValue: Double
        let hatchHoleMinArea: Double
        let hatchOffsets: [Int: IPoint]
        /// CORNER_SMOOTHING: 0 none, 1 chamfer, 2 fillet
        let smoothing: Int
        let cornerRadius: Int
        let islandRemoval: IslandRemoval
        let minIslandArea: Double
        /// Its outline, arcs made points (ZONE::Outline, ClearArcs), and its box (GetBoundingBox)
        let outline: PolySet
        let bbox: IBox
        let numCorners: Int
        /// The copper item the rules see it as (nil off copper and for a rule area)
        let item: BoardDRC.CopperItem?
        var fills: [Int: PolySet] = [:]
        var islands: [Int: Set<Int>] = [:]
        var filled = false

        init(node: SExpr, uuid: String, footprint: Int?, ruleArea: Bool, keepout: [Bool], layers: [Int], net: Int, priority: Int,
             teardropType: Int, minThickness: Int, localClearance: Int, padConnection: BoardDRC.ZoneConnection, thermalGap: Int,
             spokeWidth: Int, hatched: Bool, hatch: (Int, Int, EDAAngle, Int, Double, Double), hatchOffsets: [Int: IPoint],
             smoothing: Int, cornerRadius: Int, islandRemoval: IslandRemoval, minIslandArea: Double, outline: PolySet,
             item: BoardDRC.CopperItem?) {
            (self.node, self.uuid, self.footprint, self.ruleArea) = (node, uuid, footprint, ruleArea)
            (doNotAllowTracks, doNotAllowVias, doNotAllowPads, doNotAllowFootprints, doNotAllowZoneFills) =
                (keepout[0], keepout[1], keepout[2], keepout[3], keepout[4])
            (self.layers, self.net, self.priority, self.teardropType) = (layers, net, priority, teardropType)
            (self.minThickness, self.localClearance, self.padConnection) = (minThickness, localClearance, padConnection)
            (self.thermalGap, self.spokeWidth, self.hatched) = (thermalGap, spokeWidth, hatched)
            (hatchThickness, hatchGap, hatchOrientation, hatchSmoothingLevel, hatchSmoothingValue, hatchHoleMinArea) = hatch
            (self.hatchOffsets, self.smoothing, self.cornerRadius) = (hatchOffsets, smoothing, cornerRadius)
            (self.islandRemoval, self.minIslandArea, self.outline, self.item) = (islandRemoval, minIslandArea, outline, item)
            var box: IBox?
            for poly in outline.polygons { if box == nil { box = poly[0].bbox } else { box!.merge(poly[0].bbox) } }
            bbox = box ?? IBox(minX: 0, minY: 0, maxX: 0, maxY: 0)
            numCorners = outline.totalVertices
        }

        var isTeardrop: Bool { teardropType != 0 }

        func isOnLayer(_ l: Int) -> Bool { layers.contains(l) }

        /// HasKeepoutParametersSet
        var hasKeepoutParameters: Bool {
            doNotAllowTracks || doNotAllowVias || doNotAllowPads || doNotAllowFootprints || doNotAllowZoneFills
        }

        /// ZONE::HigherPriority: a teardrop over any other, then the higher priority, then the greater uuid
        func higherPriority(_ o: FillZone) -> Bool {
            if (teardropType == 0) != (o.teardropType == 0) { return teardropType > o.teardropType }
            if priority != o.priority { return priority > o.priority }
            return uuid > o.uuid
        }

        func sameNet(_ o: FillZone) -> Bool { net == o.net }
    }

    private func readLayers() {
        for entry in drc.board.root["layers"]?.arguments ?? [] {
            guard let name = entry.text(at: 0), let id = BoardDRC.layerID(name) else { continue }
            layerNames[id] = name
        }
        boardCopper = world.layerIndex.keys.compactMap { BoardDRC.layerID($0) }.sorted()
        for id in boardCopper where layerNames[id] == nil { layerNames[id] = world.layerIndex.first { BoardDRC.layerID($0.key) == id }?.key }
    }

    func isCopperLayer(_ id: Int) -> Bool { id % 2 == 0 && id <= 64 }

    /// The router layer of a copper layer's id
    func routerLayer(_ id: Int) -> Int? { layerNames[id].flatMap { world.layerIndex[$0] } }

    /// The zones' layer ids from a zone's layer names ("*.Cu" the board's copper layers)
    private func zoneLayers(_ node: SExpr) -> [Int] {
        var out = Set<Int>()
        for name in drc.layerSet(node) { if let id = BoardDRC.layerID(name) { out.insert(id) } }
        return out.sorted()
    }

    private func readZones() {
        let fps = drc.board.root.all("footprint")
        var items: [String: BoardDRC.CopperItem] = [:]
        for z in copper.zones { items[z.uuid] = z }
        func add(_ node: SExpr, footprint: Int?) {
            let uuid = node.value("uuid") ?? ""
            let keepout = node["keepout"]
            let ruleArea = keepout != nil || node["placement"] != nil
            func notAllowed(_ name: String) -> Bool { keepout?[name]?.text(at: 0) == "not_allowed" }
            // (a rule area read without a keepout clause keeps ZONE_SETTINGS' defaults: tracks, vias and pads not allowed)
            let k = keepout == nil ? [true, true, true, false, false]
                : [notAllowed("tracks"), notAllowed("vias"), notAllowed("pads"), notAllowed("footprints"), notAllowed("copperpour")]
            let layers = zoneLayers(node)
            let onCopper = layers.contains(where: isCopperLayer)
            let item = items[uuid]
            let net = onCopper && !ruleArea ? item?.net ?? 0 : 0
            let connect = node["connect_pads"]
            let connectArgs = connect?.arguments.map(\.text) ?? []
            let padConnection: BoardDRC.ZoneConnection = connectArgs.contains("yes") ? .full : connectArgs.contains("no") ? .none
                : connectArgs.contains("thru_hole_only") ? .thtThermal : .thermal
            let fill = node["fill"]
            func fillValue(_ name: String) -> SExpr? { fill?[name] }
            let minThickness = node["min_thickness"].map { BoardWorld.iu($0, 0) } ?? 250_000
            let smoothingText = fillValue("smoothing")?.text(at: 0) ?? "none"
            var smoothing = 0
            if !ruleArea { smoothing = smoothingText == "chamfer" ? 1 : smoothingText == "fillet" ? 2 : 0 }
            let radius = ruleArea ? 0 : fillValue("radius").map { BoardWorld.iu($0, 0) } ?? 0
            var islandRemoval = IslandRemoval.always
            if let m = fillValue("island_removal_mode")?.text(at: 0).flatMap(Int.init), let mode = IslandRemoval(rawValue: m) {
                islandRemoval = mode
            }
            // (parseBoardUnits of the square millimetres, times IU_PER_MM)
            let minIslandArea = fillValue("island_area_min").map { Double(BoardWorld.iu($0, 0)) * 1e6 } ?? 10e12
            let teardrop = node["attr"]?["teardrop"]?["type"]?.text(at: 0)
            let teardropType = teardrop == "padvia" ? 2 : teardrop == "track_end" ? 3 : 0
            // ZONE_SETTINGS' defaults for the hatch, from its minimum thickness's default
            let hatchThickness = fillValue("hatch_thickness").map { BoardWorld.iu($0, 0) } ?? 1_000_000
            let hatchGap = fillValue("hatch_gap").map { BoardWorld.iu($0, 0) } ?? 1_500_000
            let hatchOrientation = EDAAngle(degrees: fillValue("hatch_orientation")?.number(at: 0) ?? 0)
            let hatchLevel = Int(fillValue("hatch_smoothing_level")?.number(at: 0) ?? 0)
            let hatchValue = fillValue("hatch_smoothing_value")?.number(at: 0) ?? 0.1
            let hatchMinArea = fillValue("hatch_min_hole_area")?.number(at: 0) ?? 0.15
            var offsets: [Int: IPoint] = [:]
            for prop in node.all("property") {
                guard let l = prop.value("layer").flatMap(BoardDRC.layerID), let pos = prop["hatch_position"]?["xy"] else { continue }
                offsets[l] = BoardWorld.point(pos)
            }
            var outline = BoardWorld.zoneOutline(node)
            outline.clearArcs()
            zones.append(FillZone(node: node, uuid: uuid, footprint: footprint, ruleArea: ruleArea, keepout: k, layers: layers, net: net,
                                  priority: node.value("priority").flatMap(Int.init) ?? 0, teardropType: teardropType,
                                  minThickness: minThickness,
                                  localClearance: connect?["clearance"].map { BoardWorld.iu($0, 0) } ?? 500_000,
                                  padConnection: padConnection,
                                  thermalGap: fillValue("thermal_gap").map { BoardWorld.iu($0, 0) } ?? 500_000,
                                  spokeWidth: fillValue("thermal_bridge_width").map { BoardWorld.iu($0, 0) } ?? 500_000,
                                  hatched: fillValue("mode")?.text(at: 0) == "hatch",
                                  hatch: (hatchThickness, hatchGap, hatchOrientation, hatchLevel, hatchValue, hatchMinArea),
                                  hatchOffsets: offsets, smoothing: smoothing, cornerRadius: radius, islandRemoval: islandRemoval,
                                  minIslandArea: minIslandArea, outline: outline, item: onCopper && !ruleArea ? item : nil))
            // its fill as read (what a zone not filled keeps)
            let z = zones[zones.count - 1]
            for fillNode in node.all("filled_polygon") {
                guard let l = fillNode.value("layer").flatMap(BoardDRC.layerID) else { continue }
                var chain = LineChain()
                for q in fillNode["pts"]?.arguments ?? [] where q.head == "xy" { chain.append(BoardWorld.point(q)) }
                chain.setClosed(true)
                z.fills[l, default: PolySet()].addOutline(chain)
            }
        }
        for node in drc.board.root.all("zone") { add(node, footprint: nil) }
        for (i, fp) in fps.enumerated() { for node in fp.all("zone") { add(node, footprint: i) } }
    }

    /// What the board has that the filler does not make
    private func noteUnsupported() {
        let root = drc.board.root
        if root.all("footprint").contains(where: { fp in fp.all("pad").contains { $0["padstack"] != nil } }) { unsupported.insert("pad padstack") }
        if root.all("via").contains(where: { $0["padstack"] != nil }) { unsupported.insert("via padstack") }
        let removes = root.all("via") + root.all("footprint").flatMap { $0.all("pad") }
        if removes.contains(where: { $0.value("remove_unused_layers") == "yes" || $0.flag("remove_unused_layers") }) {
            unsupported.insert("pad or via without unconnected layers")
        }
        root.walk { node in
            switch node.head ?? "" {
            case "backdrill", "post_machining", "tertiary_drill", "secondary_drill": self.unsupported.insert("backdrilled hole")
            case "barcode": self.unsupported.insert("barcode")
            case "dimension": self.unsupported.insert("dimension")
            case "table", "gr_text_box", "fp_text_box", "target": self.unsupported.insert(node.head!)
            default: break
            }
        }
    }

    // MARK: - Filling (ZONE_FILLER::Fill)

    /// zoneKnockoutMayInteract: whether a zone's knockout of another can reach it (their boxes within reach, then their
    /// outlines)
    func zoneKnockoutMayInteract(_ zone: FillZone, _ knockout: FillZone) -> Bool {
        let reach = worstClearance + zoneKnockoutSlack + zone.minThickness
        // (m_ZoneKeepExternalFillets would add the corner radii; it is off but for KiCad 5's boards)
        if !zone.bbox.inflated(reach).intersects(knockout.bbox) { return false }
        return Self.outlinesCollide(zone.outline, knockout.outline, reach)
    }

    /// SHAPE_POLY_SET::Collide of a polygon set with another: each triangle of the first against each of the second's
    private static func outlinesCollide(_ a: PolySet, _ b: PolySet, _ clearance: Int) -> Bool {
        var a = a, b = b
        a.cacheTriangulation()
        b.cacheTriangulation()
        var trisB: [Shape] = []
        for tpoly in b.triangulatedPolygons {
            for i in tpoly.triangles.indices {
                let (p, q, r) = tpoly.triangle(i)
                trisB.append(.simple(LineChain([p, q, r], closed: true)))
            }
        }
        for tpoly in a.triangulatedPolygons {
            for i in tpoly.triangles.indices {
                let (p, q, r) = tpoly.triangle(i)
                let triA = Shape.simple(LineChain([p, q, r], closed: true))
                for triB in trisB where triA.collide(triB, clearance: clearance) { return true }
            }
        }
        return false
    }

    private func fill() {
        buildBoardOutline()
        // the zones filled, each on each of its layers, those whose knockouts read others' fills after them: by
        // priority, the highest first (a zone waits only for a higher one of another net)
        let toFill = boardZones.filter { !$0.ruleArea && $0.numCorners > 2 }
        // (the connectivity built before the zones are emptied: their fills as read)
        for z in boardZones { cnFills[ObjectIdentifier(z)] = z.fills }
        for z in toFill {
            z.fills = [:]
            z.islands = [:]
            z.filled = false
        }
        var order = toFill
        Clipper.introSort(&order) { $0.higherPriority($1) }
        for z in order {
            for l in z.layers {
                z.fills[l] = fillSingleZone(z, l) ?? PolySet()
            }
        }

        // the isolated islands, by the connectivity of the new fills
        var isolated = isolatedIslands(toFill.flatMap { z in z.layers.map { (z, $0) } })
        for z in toFill { z.filled = true }
        var removedIslands = Set<FillKey>()
        var initiallyFullyIsolated = Set<FillKey>()
        for z in toFill {
            var allLayersFullyIsolated = true
            for l in z.layers {
                let count = isolated[FillKey(z, l)]?.count ?? 0
                if count == z.fills[l]?.outlineCount ?? 0 {
                    initiallyFullyIsolated.insert(FillKey(z, l))
                } else {
                    allLayersFullyIsolated = false
                }
            }
            if allLayersFullyIsolated { continue }
            for l in z.layers {
                guard let list = isolated[FillKey(z, l)], !list.isEmpty else { continue }
                if removeIslands(z, l, list) { removedIslands.insert(FillKey(z, l)) }
            }
        }

        // the iterative refill
        var seeds = Set<FillKey>()
        let candidates = zones.filter { !$0.ruleArea && !$0.isTeardrop }
        for lower in boardZones where !lower.ruleArea && !lower.isTeardrop {
            for higher in candidates where higher !== lower && higher.net == lower.net && higher.priority > lower.priority {
                guard lower.bbox.intersects(higher.bbox) else { continue }
                for l in lower.layers where boardCopper.contains(l) && higher.isOnLayer(l) { seeds.insert(FillKey(lower, l)) }
            }
        }
        if !removedIslands.isEmpty || !seeds.isEmpty {
            iterativeRefill(removedIslands.union(seeds), initiallyFullyIsolated, toFill)
        }

        // islands outside the board's outline, or too small to be anything
        for z in boardZones {
            let minArea = Double(z.minThickness) * Double(z.minThickness) * 3
            for l in z.layers where boardCopper.contains(l) {
                guard var poly = z.fills[l] else { continue }
                var drop: [Int] = []
                for jj in stride(from: poly.outlineCount - 1, through: 0, by: -1) {
                    let test = poly.polygons[jj][0]
                    let area = test.area()
                    if area < minArea { continue }
                    var island = PolySet()
                    island.addOutline(test)
                    var intersection = boardOutline
                    intersection.booleanIntersection(island)
                    if intersection.area < area / 2 { drop.append(jj) }
                }
                for jj in drop { deletePolygonAndTriangulation(&poly, z, l, jj) }
                z.fills[l] = poly
            }
        }

        // the results
        for z in boardZones where !z.ruleArea {
            var layers: [String: PolySet] = [:]
            var isl: [String: Set<Int>] = [:]
            for l in z.layers {
                guard let name = layerNames[l] else { continue }
                layers[name] = z.fills[l] ?? PolySet()
                var set = z.islands[l] ?? []
                // (IsIsland: every outline of a zone of no net)
                if z.net < 1 { set = Set(0..<(z.fills[l]?.outlineCount ?? 0)) }
                isl[name] = set
            }
            fills[z.uuid] = layers
            islands[z.uuid] = isl
        }
    }

    /// DeletePolygonAndTriangulationData: the outline taken out, the islands after it renumbered
    func deletePolygonAndTriangulation(_ poly: inout PolySet, _ z: FillZone, _ l: Int, _ idx: Int) {
        poly.deletePolygon(idx)
        // (ZONE's island indices are not renumbered by KiCad: those it keeps stay as they were)
    }

    /// Islands removed from a zone's fill on a layer by its island removal mode, the rest kept as islands; whether
    /// any was removed
    func removeIslands(_ z: FillZone, _ l: Int, _ list: [Int]) -> Bool {
        var removed = false
        var poly = z.fills[l] ?? PolySet()
        for idx in list.sorted(by: >) {
            let outline = poly.polygons[idx][0]
            if z.islandRemoval == .always || (z.islandRemoval == .area && outline.area() < z.minIslandArea) {
                poly.deletePolygon(idx)
                removed = true
            } else {
                z.islands[l, default: []].insert(idx)
            }
        }
        z.fills[l] = poly
        return removed
    }

    /// FillIsolatedIslandsMap: the islands of each zone's fill on each of its copper layers that are in no cluster
    /// with a pad (the first, where none of its fill's islands is in a cluster: a zone of no net's), by the
    /// connectivity of the board's copper with the fills as they are now
    func isolatedIslands(_ items: [(FillZone, Int)]) -> [FillKey: [Int]] {
        // the zones' fills as the connectivity has them: those of the map's zones as they are now (each removed from
        // it and added again, all its layers), the others' as they were when they were last added (CN_ZONE_LAYER
        // copies its outline then)
        for (z, _) in items { cnFills[ObjectIdentifier(z)] = z.fills }
        for z in boardZones {
            guard let item = z.item else { continue }
            item.fills = [:]
            for l in z.layers {
                guard let rl = routerLayer(l), let fill = cnFills[ObjectIdentifier(z)]?[l] else { continue }
                item.fills[rl] = fill.polygons.map { $0[0] }
            }
        }
        let cn = drc.connectivityItems(copper)
        drc.searchConnections(cn)
        var serial = 0
        let clusters = drc.searchClusters(cn, ratsnest: true, serial: &serial)
        var out: [FillKey: [Int]] = [:]
        for (z, l) in items {
            guard isCopperLayer(l), let fill = z.fills[l], fill.outlineCount > 0 else { continue }
            guard let item = z.item, let rl = routerLayer(l) else {
                out[FillKey(z, l)] = [0]
                continue
            }
            var list: [Int] = []
            var inConnectivity = false
            for cluster in clusters {
                for it in cluster.items where it.parent === item && it.zoneLayer == rl {
                    inConnectivity = true
                    if cluster.isOrphaned { list.append(it.subpoly) }
                }
            }
            if !inConnectivity { list.append(0) }
            out[FillKey(z, l)] = list
        }
        return out
    }

    // MARK: - The iterative refill

    private func iterativeRefill(_ seed: Set<FillKey>, _ initiallyFullyIsolated: Set<FillKey>, _ aZones: [FillZone]) {
        let maxIterations = 8
        var changed = seed
        var byID: [ObjectIdentifier: FillZone] = [:]
        for z in zones { byID[ObjectIdentifier(z)] = z }
        for _ in 0..<maxIterations {
            var toRefill: [(FillZone, Int)] = []
            var toRefillSet = Set<FillKey>()
            // (std::set of pairs of pointers: the order the changed zones are taken in is by their addresses, which
            // only orders the refills, each read from one snapshot)
            for key in changed {
                guard let changedZone = byID[key.zone] else { continue }
                let changedLayer = key.layer
                let box = changedZone.bbox.inflated(worstClearance)
                for zone in boardZones where !zone.ruleArea && zone.isOnLayer(changedLayer) {
                    if zone !== changedZone && !changedZone.higherPriority(zone) && !changedZone.sameNet(zone) { continue }
                    if zone !== changedZone && !changedZone.sameNet(zone) {
                        if !zoneKnockoutMayInteract(zone, changedZone) { continue }
                    } else if !zone.bbox.intersects(box) {
                        continue
                    }
                    if toRefillSet.insert(FillKey(zone, changedLayer)).inserted { toRefill.append((zone, changedLayer)) }
                }
            }
            if toRefill.isEmpty { break }
            let before = toRefill.map { $0.0.fills[$0.1]?.polygons ?? [] }
            // the snapshot every refill of the wave reads others' fills from
            var snapshot: [FillKey: PolySet] = [:]
            let layers = Set(toRefill.map(\.1))
            for z in zones where !z.ruleArea {
                for l in z.layers where boardCopper.contains(l) && layers.contains(l) {
                    if let f = z.fills[l], f.outlineCount > 0 { snapshot[FillKey(z, l)] = f }
                }
            }
            for (z, l) in toRefill {
                if let f = refillZoneFromCache(z, l, snapshot) { z.fills[l] = f }
            }
            // the refilled zones' islands
            let isolated = isolatedIslands(toRefill)
            for (z, l) in toRefill {
                guard let list = isolated[FillKey(z, l)], !list.isEmpty else { continue }
                if initiallyFullyIsolated.contains(FillKey(z, l)) && list.count == z.fills[l]?.outlineCount ?? 0 { continue }
                // (KiCad's island indices of the earlier wave stay set: SetIsIsland only adds)
                _ = removeIslands(z, l, list)
            }
            changed.removeAll()
            for (i, (z, l)) in toRefill.enumerated() where (z.fills[l]?.polygons ?? []) != before[i] { changed.insert(FillKey(z, l)) }
            if changed.isEmpty { break }
        }
    }

    // MARK: - The board's outline

    /// GetBoardPolygonOutlines( outline, true ): the outline of the board's edges, simplified; a box round its edges
    /// where it cannot be made
    private func buildBoardOutline() {
        var outlines = PolySet()
        var errors: [BoardDRC.OutlineError]?
        let cuts = drc.edgeCuts()
        var success = drc.buildBoardPolygonOutlines(cuts, maxError: maxError, &outlines, &errors)
        if !success || outlines.outlineCount == 0 {
            success = false
            // GetBoardEdgesBoundingBox: the board's and its footprints' drawings on Edge.Cuts, by their boxes
            var box: IBox?
            func merge(_ node: SExpr, _ placement: BoardWorld.FootprintPlacement?) {
                guard node.value("layer") == "Edge.Cuts", let o = world.outlineShape(node, placement: placement) else { return }
                let b = BoardDRC.drawingBox(o, filled: BoardDRC.solidFill(node), maxError: maxError).0
                if box == nil { box = b } else { box!.merge(b) }
            }
            for node in drc.board.root.items where ["gr_line", "gr_rect", "gr_arc", "gr_circle", "gr_poly", "gr_curve"].contains(node.head ?? "") {
                merge(node, nil)
            }
            for fp in drc.board.root.all("footprint") {
                let placement = BoardWorld.FootprintPlacement(fp)
                for node in fp.items where BoardWorld.footprintShapeHeads.contains(node.head ?? "") { merge(node, placement) }
            }
            if box == nil || box!.width == 0 || box!.height == 0 {
                unsupported.insert("board outline inferred from its items")
                box = box ?? IBox(minX: 0, minY: 0, maxX: 0, maxY: 0)
                if box!.width == 0 || box!.height == 0 { box = box!.inflated(1_000_000) }
            }
            let b = box!
            outlines = PolySet()
            outlines.newOutline()
            for p in [IPoint(b.minX, b.minY), IPoint(b.minX, b.maxY), IPoint(b.maxX, b.maxY), IPoint(b.maxX, b.minY)] { outlines.append(p) }
        }
        outlines.simplify()
        boardOutline = outlines
        outlineValid = success
    }

    // MARK: - Writing the fills back

    /// The board with each of its zones' fills replaced by the filler's, as KiCad writes them (its filled polygons
    /// layer by layer, an island marked, the zone marked filled)
    public func refilledBoard(_ board: KiCadBoard) -> KiCadBoard {
        let out = board.copy()
        for node in out.root.all("zone") {
            guard let uuid = node.value("uuid"), let layers = fills[uuid] else { continue }
            node.remove("filled_polygon")
            if let fill = node["fill"], fill.items.count >= 1, fill.text(at: 0) != "yes" {
                fill.items.insert(SExpr(symbol: "yes"), at: 1)
            }
            let order = layers.keys.compactMap { name in BoardDRC.layerID(name).map { ($0, name) } }.sorted { $0.0 < $1.0 }
            for (_, name) in order {
                guard let set = layers[name] else { continue }
                for (i, poly) in set.polygons.enumerated() {
                    var items: [SExpr] = [SExpr(symbol: "filled_polygon"), SExpr("layer", name)]
                    if islands[uuid]?[name]?.contains(i) == true { items.append(SExpr("island", Keyword("yes"))) }
                    var pts: [SExpr] = [SExpr(symbol: "pts")]
                    for p in poly[0].points {
                        pts.append(SExpr("xy", Double(p.x) / 1e6, Double(p.y) / 1e6))
                    }
                    items.append(SExpr(list: pts))
                    node.items.append(SExpr(list: items))
                }
            }
        }
        return out
    }
}

/// Every zone's fill on each of its layers as KiCad's zone filler makes it: by zone (its uuid), by layer (its name)
public func fillZones(board: KiCadBoard, project: [String: Any]?) -> [String: [String: PolySet]] {
    ZoneFiller(board: board, project: project).fills
}

/// The board with its zones filled again, as KiCad's filler fills them and writes them
public func refillZones(board: KiCadBoard, project: [String: Any]?) -> KiCadBoard {
    ZoneFiller(board: board, project: project).refilledBoard(board)
}
