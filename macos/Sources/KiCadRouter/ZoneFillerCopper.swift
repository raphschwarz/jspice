// Ported from KiCad 10.0.7: pcbnew/zone_filler.cpp (fillSingleZone, fillCopperZone, fillNonCopperZone,
// knockoutThermalReliefs, buildCopperItemClearances, buildDifferentNetZoneClearances, subtractHigherPriorityZones,
// buildThermalSpokes, buildHatchZoneThermalRings, addHatchFillTypeOnZone, connect_nearby_polys with its
// VERTEX_CONNECTOR, postKnockoutMinWidthPrune, dropSubResolutionOutlines, refillZoneFromCache, addKnockout and
// addHoleKnockout, the knockout keys that skip coincident items), pcbnew/zone.cpp (BuildSmoothedPoly,
// GetInteractingZones, TransformSmoothedOutlineToPolygon, TransformShapeToPolygon), pcbnew/drc/drc_engine.cpp
// (EvalRules and EvalZoneConnection for the filler's constraints on the implicit rules: physical clearances, which
// they have none of, hole and edge clearances, thermal relief gaps and spoke widths, zone connections, with the pads'
// and footprints' overrides), pcbnew/pad.cpp (TransformHoleToPolygon, GetBoundingBox( layer ), the pad overrides),
// pcbnew/pcb_track.cpp (tracks', arcs' and vias' TransformShapeToPolygon and GetBoundingBox), pcbnew/pcb_text.cpp
// (TransformShapeToPolygon), libs/kimath/src/geometry/vertex_set.cpp and libs/kimath/include/geometry/vertex_set.h
// (VERTEX, VERTEX_SET: createList onto a tail, isEar of one outline, zOrder, updateList, zSort) and libs/kimath/src/
// geometry/convex_hull.cpp (BuildConvexHull).
// Copyright (C) 2014-2017 CERN; Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

extension ZoneFiller {
    // MARK: - The board's pads as the filler takes them

    /// A pad, with its footprint's and its own zone settings
    struct FillPad {
        let item: BoardDRC.CopperItem
        let pad: BoardDRC.Pad
        let node: SExpr
        let footprint: Int
        /// The copper layers it is on (PAD::IsOnLayer), KiCad's ids
        let layers: Set<Int>
        /// Its own zone connection and its footprint's (nil inherited)
        let zoneConnection: BoardDRC.ZoneConnection?
        let footprintZoneConnection: BoardDRC.ZoneConnection?
        let thermalGap: Int
        let spokeWidth: Int
        let spokeAngle: EDAAngle
        /// CUSTOM_SHAPE_ZONE_MODE::CONVEXHULL
        let convexHull: Bool
        /// Its spoke templates (proxy segments, gr_vector), in its own coordinates
        let spokeTemplates: [(IPoint, IPoint)]

        var p: BoardWorld.Pad { pad.pad }
        var hasDrill: Bool { p.drill.x > 0 }
    }

    func fillPads() -> [FillPad] {
        if let cached = padCache { return cached }
        var out: [FillPad] = []
        let fps = drc.board.root.all("footprint")
        for (f, fp) in fps.enumerated() {
            let nodes = fp.all("pad")
            func connection(_ n: SExpr) -> BoardDRC.ZoneConnection? {
                guard let v = n.value("zone_connect").flatMap(Int.init) else { return nil }
                return BoardDRC.ZoneConnection(rawValue: v)
            }
            for (j, item) in copper.footprintPads[f].enumerated() {
                guard let pad = item.pad else { continue }
                let node = nodes[j]
                var layers = Set<Int>()
                for rl in world.copper(pad.pad.layers) {
                    if let name = world.layerIndex.first(where: { $0.value == rl })?.key, let id = BoardDRC.layerID(name) { layers.insert(id) }
                }
                let angle: EDAAngle
                if let a = node["thermal_bridge_angle"]?.number(at: 0) {
                    angle = EDAAngle(degrees: a)
                } else if pad.pad.kind == .circle || (pad.pad.kind == .custom && !pad.pad.anchorRect) {
                    angle = .a45
                } else {
                    angle = .a90
                }
                var templates: [(IPoint, IPoint)] = []
                for prim in node["primitives"]?.arguments ?? [] where prim.head == "gr_vector" {
                    templates.append((BoardWorld.point(prim["start"]), BoardWorld.point(prim["end"])))
                }
                out.append(FillPad(item: item, pad: pad, node: node, footprint: f, layers: layers, zoneConnection: connection(node),
                                   footprintZoneConnection: connection(fp),
                                   thermalGap: node["thermal_gap"].map { BoardWorld.iu($0, 0) } ?? 0,
                                   spokeWidth: (node["thermal_bridge_width"] ?? node["thermal_width"]).map { BoardWorld.iu($0, 0) } ?? 0,
                                   spokeAngle: angle, convexHull: node["options"]?["clearance"]?.text(at: 0) == "convexhull",
                                   spokeTemplates: templates))
            }
        }
        padCache = out
        return out
    }

    func padOnLayer(_ pad: FillPad, _ layer: Int) -> Bool { pad.layers.contains(layer) }

    /// PAD::FlashLayer on a copper layer
    func padFlashLayer(_ pad: FillPad, _ layer: Int) -> Bool {
        guard let rl = routerLayer(layer) else { return false }
        return world.flash(pad.p, world.copper(pad.p.layers), rl)
    }

    /// The pad's polygon on a layer grown by a clearance, the error outside (PAD::TransformShapeToPolygon)
    func padPolygon(_ pad: FillPad, _ clearance: Int, errorLocation: ErrorLocation = .outside) -> PolySet? {
        world.padPolygon(pad.p, primitives: pad.pad.primitives, errorLocation: errorLocation, clearance: clearance, arcError: maxError)
    }

    /// PAD::TransformHoleToPolygon
    func holePolygon(_ pad: FillPad, _ clearance: Int, errorLocation: ErrorLocation = .outside) -> PolySet {
        guard pad.p.drill.x > 0 && pad.p.drill.y > 0, case .segment(let s, let w) = world.holeShape(pad.p) else { return PolySet() }
        return PadPolygon.oval(start: s.a, end: s.b, width: w + clearance * 2, maxError: maxError, errorLocation: errorLocation)
    }

    /// addKnockout of a pad: its polygon grown by the gap, or the convex hull of a custom pad's where it asks
    func addPadKnockout(_ pad: FillPad, _ gap: Int, _ holes: inout PolySet) {
        guard let poly = padPolygon(pad, gap) else {
            unsupported.insert("custom pad curve or old arc")
            return
        }
        if pad.p.kind == .custom && pad.convexHull {
            var pts: [IPoint] = []
            for p in poly.polygons { pts += p[0].points }
            holes.newOutline()
            for q in Self.convexHull(pts) { holes.append(q) }
        } else {
            holes.append(poly)
        }
    }

    /// BuildConvexHull: Andrew's monotone chain, counter-clockwise, its last point dropped if it is its first
    static func convexHull(_ input: [IPoint]) -> [IPoint] {
        var poly = input
        let n = poly.count
        if n < 2 { return [] }
        Clipper.introSort(&poly) { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }
        func cross(_ o: IPoint, _ a: IPoint, _ b: IPoint) -> Int { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var result = [IPoint](repeating: .zero, count: 2 * n)
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

    /// PAD_KNOCKOUT_KEY: where, how big (a round pad by the larger of its size and its drill), its shape, its angle
    /// and its net
    struct PadKey: Hashable {
        let position: IPoint
        let size: IPoint
        let shape: BoardWorld.Pad.Kind
        let orientation: Double
        let net: Int
    }

    func padKey(_ pad: FillPad) -> PadKey? {
        let p = pad.p
        guard p.kind != .custom else { return nil }
        var size = p.size
        if p.kind == .circle {
            let m = max(p.size.x, p.size.y, max(p.drill.x, p.drill.y))
            size = IPoint(m, m)
        }
        return PadKey(position: p.pos, size: size, shape: p.kind, orientation: p.orientation.degrees, net: pad.item.net)
    }

    // MARK: - The rules (DRC_ENGINE::EvalRules, EvalZoneConnection)

    /// The zone as the rules see it
    func ruleZone(_ z: FillZone) -> RuleItem {
        if let r = z.rule { return r }
        let r = drc.ruleZone(z.node, uuid: z.uuid, footprint: z.footprint) ?? RuleItem(.zone, uuid: z.uuid)
        z.rule = r
        return r
    }

    /// evalRulesForItems: EvalRules of a constraint between the zone and an item on a layer, its minimum; -1 where no
    /// rule sets it
    func evalRules(_ type: DRCConstraintType, _ z: FillZone, _ item: RuleItem, _ layer: Int) -> Int {
        let c = drc.ruleState.engine.evalRules(type, ruleZone(z), item, layer: layer)
        return c.type == .null ? -1 : c.value.min
    }

    func evalRules(_ type: DRCConstraintType, _ z: FillZone, _ item: BoardDRC.CopperItem, _ layer: Int) -> Int {
        evalRules(type, z, drc.ruleItem(item, copper), layer)
    }

    /// EvalRules of a constraint between an item and the zone (the item first, as the thermal reliefs ask)
    func itemConstraint(_ type: DRCConstraintType, _ item: BoardDRC.CopperItem, _ z: FillZone, _ layer: Int) -> DRCConstraint {
        drc.ruleState.engine.evalRules(type, drc.ruleItem(item, copper), ruleZone(z), layer: layer)
    }

    /// EvalZoneConnection of a pad or via and the zone: the pad's own, its footprint's, the zone's (or a rule's); a
    /// through-hole thermal one thermal for a plated pad, solid for another
    func zoneConnection(_ item: BoardDRC.CopperItem, _ z: FillZone, _ layer: Int) -> BoardDRC.ZoneConnection {
        let c = drc.ruleState.engine.evalZoneConnection(drc.ruleItem(item, copper), ruleZone(z), layer: layer).zoneConnection
        switch c {
        case .none: return .none
        case .full: return .full
        case .thtThermal: return .thtThermal
        default: return .thermal
        }
    }

    /// THERMAL_RELIEF_GAP_CONSTRAINT: the pad's own gap, else the zone's (or a rule's)
    func thermalGap(_ item: BoardDRC.CopperItem, _ z: FillZone, _ layer: Int) -> Int {
        itemConstraint(.thermalReliefGap, item, z, layer).value.min
    }

    /// THERMAL_SPOKE_WIDTH_CONSTRAINT: its opt (the pad's own width, no less than the zone's minimum thickness, else
    /// the zone's, or a rule's), and the constraint's min and max a pad's is clamped to
    func spokeWidth(_ item: BoardDRC.CopperItem, _ z: FillZone, _ layer: Int) -> (opt: Int, min: Int, max: Int) {
        let c = itemConstraint(.thermalSpokeWidth, item, z, layer)
        return (c.value.opt, c.value.min, c.value.max)
    }

    /// A text or field as the rules see it (PCB_TEXT, PCB_FIELD): its layer, footprint and box
    func textRuleItem(_ node: SExpr, layerName: String, footprint: Int?, box: IBox) -> RuleItem {
        let r = RuleItem(node.head == "property" ? .field : .text, uuid: node.value("uuid") ?? "")
        r.parentFootprint = footprint.map { drc.ruleState.footprints[$0] }
        r.layer = KiLayer.id(layerName) ?? KiLayer.undefined
        r.layerSet = KiLayerSet([r.layer])
        r.isOnCopper = KiLayer.isCopper(r.layer)
        r.bbox = box
        r.netClass = drc.ruleNetClass("")
        if node.head == "property", let name = node.text(at: 0) { r.properties["Name"] = .string(name) }
        return r
    }

    /// knockoutCourtyardClearance: a footprint's courtyard taken out by a physical clearance rule between the zone and
    /// it, on the layer's side (an inner layer's, the footprint's), grown by the clearance; only of a footprint whose
    /// box (FOOTPRINT::GetBoundingBox, its texts in it) reaches the zone's grown by the worst clearance
    func knockoutCourtyard(_ z: FillZone, _ layer: Int, _ footprint: Int, _ zoneBox: IBox, _ holes: inout PolySet) {
        guard drc.ruleState.engine.hasRules(.physicalClearance) else { return }
        let fp = drc.ruleState.footprints[footprint]
        guard let box = fp.bbox, box.intersects(zoneBox) else { return }
        let gap = evalRules(.physicalClearance, z, fp, layer)
        guard gap >= 0, let yards = fp.courtyards else { return }
        let side = KiLayer.isCopper(layer) && layer != KiLayer.fCu && layer != KiLayer.bCu ? fp.layer : layer
        let yard = KiLayerSet.back.contains(side) ? yards.back : yards.front
        if gap == 0 {
            holes.append(yard)
        } else {
            var grown = yard
            grown.inflate(gap, .roundAllCorners, maxError: maxError)
            holes.append(grown)
        }
    }

    // MARK: - fillSingleZone

    func fillSingleZone(_ z: FillZone, _ layer: Int) -> PolySet? {
        guard let (maxExtents, smoothed) = buildSmoothedPoly(z, layer, outlineValid ? boardOutline : nil) else { return nil }
        if z.layers.contains(where: isCopperLayer) {
            return fillCopperZone(z, layer, smoothed, maxExtents)
        }
        return fillNonCopperZone(z, layer, smoothed)
    }

    /// GetInteractingZones: the board's other zones on the layer (not rule areas, not teardrops) whose boxes touch the
    /// zone's grown a micrometre, those of its net whose outlines collide with its, and those of other nets
    func interactingZones(_ z: FillZone, _ layer: Int) -> (sameNet: [FillZone], otherNet: [FillZone]) {
        let box = z.bbox.inflated(1000)
        var same: [FillZone] = [], other: [FillZone] = []
        for c in boardZones where c !== z && c.isOnLayer(layer) && !c.ruleArea && !c.isTeardrop && c.bbox.intersects(box) {
            if c.net == z.net {
                if Self.outlineCollide(z.outline, c.outline) { same.append(c) }
            } else {
                other.append(c)
            }
        }
        return (same, other)
    }

    static func outlineCollide(_ a: PolySet, _ b: PolySet) -> Bool { BoardDRC.polySetsCollide(a, b) }

    /// BuildSmoothedPoly: the zone's outline with the same-net zones it meets added, cut to the board, its corners
    /// smoothed and then cut back to the outline (the smoothed outline, and with the apron of the same-net zones it
    /// meets, its minimum thickness wide)
    func buildSmoothedPoly(_ z: FillZone, _ layer: Int, _ board: PolySet?) -> (smoothed: PolySet, apron: PolySet)? {
        guard z.numCorners > 2 else { return nil }
        let flattened = z.outline
        if z.ruleArea { return (flattened, flattened) }
        let smoothRequested = (z.smoothing == 1 || z.smoothing == 2) && !z.isTeardrop
        func smooth(_ poly: inout PolySet) {
            guard smoothRequested else { return }
            if z.smoothing == 1 { poly = poly.chamfer(z.cornerRadius) } else { poly = poly.fillet(z.cornerRadius, maxError: maxError) }
        }
        let maxExtents = flattened
        var smoothed = flattened
        let (sameNet, otherNet) = interactingZones(z, layer)
        for s in sameNet {
            let sameNetBox = s.bbox
            var diffNetPoly = PolySet()
            for d in otherNet where d.higherPriority(s) && d.bbox.intersects(sameNetBox) { diffNetPoly.booleanAdd(d.outline) }
            var isolated = false
            if diffNetPoly.outlineCount > 0 {
                var thisPoly = z.outline
                thisPoly.booleanSubtract(diffNetPoly)
                isolated = thisPoly.outlineCount == 0
            }
            if !isolated { smoothed.booleanAdd(s.outline) }
        }
        if let board { smoothed.booleanIntersection(board) }
        let withSameNet = smoothed
        smooth(&smoothed)
        var poly = maxExtents
        poly.inflate(z.minThickness, .roundAllCorners, maxError: maxError)
        poly.booleanIntersection(withSameNet)
        var apron = smoothed
        apron.booleanIntersection(poly)
        smoothed.booleanIntersection(maxExtents)
        return (smoothed, apron)
    }

    // MARK: - fillCopperZone

    func fillCopperZone(_ z: FillZone, _ layer: Int, _ smoothedOutline: PolySet, _ maxExtents: PolySet) -> PolySet {
        let halfMinWidth = z.minThickness / 2
        let epsilon = 1000
        var thermalPads: [ThermalItem] = []
        var noConnectionPads: [FillPad] = []
        var solidItems: [BoardDRC.CopperItem] = []
        var fill = smoothedOutline

        debugStage?("smoothed", z, fill)
        knockoutThermalReliefs(z, layer, &fill, &thermalPads, &noConnectionPads, &solidItems)
        debugStage?("thermals", z, fill)

        var thermalRings = PolySet()
        if z.hatched { buildHatchZoneThermalRings(z, layer, smoothedOutline, thermalPads, &fill, &thermalRings) }

        // (iterative refill on: the zones' clearances apart, the keepouts in with the items')
        var clearanceHoles = PolySet()
        buildCopperItemClearances(z, layer, noConnectionPads, &clearanceHoles)
        var addedKeepoutHoles = false
        if !z.isTeardrop {
            for k in zones where isZoneFillKeepout(k, layer, z.bbox) {
                appendSmoothedOutline(k, &clearanceHoles)
                addedKeepoutHoles = true
            }
        }
        if addedKeepoutHoles { clearanceHoles.simplify() }

        debugStage?("holes", z, clearanceHoles)
        let spokes = buildThermalSpokes(z, layer, thermalPads)

        var testAreas = fill
        testAreas.booleanSubtract(clearanceHoles)
        var zoneClearances = PolySet()
        buildDifferentNetZoneClearances(z, layer, &zoneClearances)
        if zoneClearances.outlineCount > 0 { testAreas.booleanSubtract(zoneClearances) }
        if halfMinWidth - epsilon > epsilon {
            testAreas.deflate(halfMinWidth - epsilon, .chamferAllCorners, maxError: maxError)
            testAreas.inflate(halfMinWidth - epsilon, .chamferAllCorners, maxError: maxError)
        }
        for (i, spoke) in spokes.enumerated() {
            let testPt = spoke.point(3)
            if testAreas.contains(testPt, accuracy: 1) {
                fill.addOutline(spoke)
                continue
            }
            for (j, other) in spokes.enumerated() where j != i {
                if other.pointInside(testPt, accuracy: 1) && spoke.pointInside(other.point(3), accuracy: 1) {
                    fill.addOutline(spoke)
                    break
                }
            }
        }
        fill.booleanSubtract(clearanceHoles)
        debugStage?("trimmed", z, fill)

        // pruned of what is narrower than the minimum width
        if halfMinWidth - epsilon > epsilon {
            fill.deflate(halfMinWidth - epsilon, .chamferAllCorners, maxError: maxError)
            if thermalRings.outlineCount > 0 { thermalRings.deflate(halfMinWidth - epsilon, .chamferAllCorners, maxError: maxError) }
        }
        dropSmallIslands(&fill, z.minThickness)
        debugStage?("deflated", z, fill)

        if z.hatched {
            var ringsToProtect = thermalRings
            ringsToProtect.booleanAdd(clearanceHoles)
            for item in solidItems {
                guard let v = item.via, let rl = routerLayer(layer), item.layers.contains(rl) else { continue }
                var disc = PolySet([[PadPolygon.circle(center: v.start, radius: v.diameter / 2, maxError: maxError, errorLocation: .outside)]])
                disc.booleanIntersection(smoothedOutline)
                ringsToProtect.booleanAdd(disc)
            }
            var solid = fill
            if halfMinWidth - epsilon > epsilon { solid.inflate(halfMinWidth - epsilon, .roundAllCorners, maxError: maxError, simplify: true) }
            solid.booleanIntersection(maxExtents)
            solid.booleanSubtract(clearanceHoles)
            preHatchSolid[FillKey(z, layer)] = solid
            addHatchFillTypeOnZone(z, layer, &fill, ringsToProtect)
        } else {
            fill.fracture()
            connectNearbyPolys(&fill, z.minThickness)
        }
        debugStage?("connected", z, fill)

        if halfMinWidth - epsilon > epsilon { fill.inflate(halfMinWidth - epsilon, .roundAllCorners, maxError: maxError, simplify: true) }
        fill.booleanAdd(thermalRings)
        debugStage?("reinflated", z, fill)

        for t in thermalPads { if case .pad(let pad) = t { clearanceHoles.append(holePolygon(pad, 0)) } }
        fill.booleanIntersection(maxExtents)
        fill.booleanSubtract(clearanceHoles)

        // (cached before the other zones' knockouts, for the iterative refill)
        var sameNetApron = smoothedOutline
        sameNetApron.booleanSubtract(maxExtents)
        sameNetApron.booleanSubtract(clearanceHoles)
        preKnockoutFill[FillKey(z, layer)] = fill
        sameNetApronCache[FillKey(z, layer)] = sameNetApron
        var knockoutsApplied = false
        if zoneClearances.outlineCount > 0 {
            fill.booleanSubtract(zoneClearances)
            sameNetApron.booleanSubtract(zoneClearances)
            knockoutsApplied = true
        }
        if knockoutsApplied { postKnockoutMinWidthPrune(z, &fill, sameNetApron) }

        subtractHigherPriorityZones(z, layer, &fill)
        dropSubResolutionOutlines(&fill)
        fill.fracture()
        return fill
    }

    /// The fill's islands too small to be anything: those whose outline's box is less than the minimum thickness
    /// across both ways (the box grown point by point, stopped once it is more)
    func dropSmallIslands(_ fill: inout PolySet, _ minThickness: Int) {
        for ii in stride(from: fill.outlineCount - 1, through: 0, by: -1) {
            var box: IBox?
            for pt in fill.polygons[ii][0].points {
                if box == nil { box = IBox(pt, pt) } else { box!.merge(pt) }
                if max(box!.width, box!.height) > minThickness { break }
            }
            let size = box.map { max($0.width, $0.height) } ?? 0
            if size < minThickness { fill.deletePolygon(ii) }
        }
    }

    /// isZoneFillKeepout: a rule area keeping zones' fills out, on the layer, whose box touches the zone's
    func isZoneFillKeepout(_ k: FillZone, _ layer: Int, _ box: IBox) -> Bool {
        k.ruleArea && k.hasKeepoutParameters && k.doNotAllowZoneFills && k.isOnLayer(layer) && k.bbox.intersects(box)
    }

    /// TransformSmoothedOutlineToPolygon of a rule area, no clearance: its outline as it is, fractured
    func appendSmoothedOutline(_ k: FillZone, _ out: inout PolySet) {
        var poly = k.outline
        poly.fracture()
        out.append(poly)
    }

    // MARK: - Thermal reliefs (knockoutThermalReliefs)

    /// An item a thermal relief is made round: a pad, or in a hatched zone a via
    enum ThermalItem {
        case pad(FillPad)
        case via(BoardDRC.CopperItem)
    }

    func knockoutThermalReliefs(_ z: FillZone, _ layer: Int, _ fill: inout PolySet, _ thermalPads: inout [ThermalItem],
                                _ noConnectionPads: inout [FillPad], _ solidItems: inout [BoardDRC.CopperItem]) {
        var holes = PolySet()
        var processed = Set<PadKey>()
        var triangulated = fill
        triangulated.cacheTriangulation()
        func fillCollides(_ shapes: [Shape]) -> Bool { BoardDRC.polySetCollide(triangulated, shapes, compound: true, wantActual: false) }
        for pad in fillPads() {
            let npthWithHole = pad.p.attribute == .npth && pad.p.drill.x > 0
            if !padOnLayer(pad, layer) && !npthWithHole { continue }
            if !pad.item.bbox.inflated(worstClearance).intersects(z.bbox) { continue }
            if let key = padKey(pad), !processed.insert(key).inserted { continue }
            var noConnection = pad.item.net != z.net
            if !z.isTeardrop && z.net == 0 { noConnection = true }
            if noConnection {
                noConnectionPads.append(pad)
                continue
            }
            if z.hatched {
                var connection = zoneConnection(pad.item, z, layer)
                if connection == .thermal && !padFlashLayer(pad, layer) { connection = .none }
                switch connection {
                case .thermal:
                    if fillCollides(pad.item.outline) {
                        thermalPads.append(.pad(pad))
                        addPadKnockout(pad, thermalGap(pad.item, z, layer), &holes)
                    }
                case .none:
                    noConnectionPads.append(pad)
                default:
                    break
                }
                continue
            }
            var connection = z.isTeardrop ? .full : zoneConnection(pad.item, z, layer)
            if connection == .thermal && !padFlashLayer(pad, layer) { connection = .none }
            switch connection {
            case .thermal:
                if fillCollides(pad.item.outline) {
                    thermalPads.append(.pad(pad))
                    addPadKnockout(pad, thermalGap(pad.item, z, layer), &holes)
                }
            case .none:
                // (a physical clearance rule's, where more than the zone's own clearance)
                let physical = itemConstraint(.physicalClearance, pad.item, z, layer).value.min
                let padClearance = physical > z.localClearance ? physical : z.localClearance
                if padFlashLayer(pad, layer) {
                    addPadKnockout(pad, padClearance, &holes)
                } else if pad.p.drill.x > 0 {
                    let physicalHole = itemConstraint(.physicalHoleClearance, pad.item, z, layer).value.min
                    holes.append(holePolygon(pad, physicalHole > padClearance ? physicalHole : padClearance))
                }
            default:
                continue
            }
        }
        if z.hatched {
            var processedVias = Set<[Int]>()
            for t in copper.tracks where t.kind == .via {
                guard let v = t.via, let rl = routerLayer(layer), t.layers.contains(rl) else { continue }
                if !viaBox(v).inflated(worstClearance).intersects(z.bbox) { continue }
                if !processedVias.insert([v.start.x, v.start.y, max(v.drill, v.diameter), t.net]).inserted { continue }
                var noConnection = t.net != z.net
                if v.unconnectedLayers == .removeExceptStartAndEnd, let rl = routerLayer(layer), rl != v.layers.start && rl != v.layers.end {
                    noConnection = true
                }
                if noConnection { continue }
                switch zoneConnection(t, z, layer) {
                case .thermal:
                    let gap = thermalGap(t, z, layer)
                    if gap > 0 {
                        thermalPads.append(.via(t))
                        holes.addOutline(PadPolygon.circle(center: v.start, radius: v.diameter / 2 + gap, maxError: maxError,
                                                           errorLocation: .outside))
                    }
                case .none:
                    break
                default:
                    solidItems.append(t)
                }
            }
        }
        fill.booleanSubtract(holes)
    }

    // MARK: - Clearances (buildCopperItemClearances)

    /// PCB_VIA::GetBoundingBox: its round, the radius rounded up, a nanometre wider at the right and bottom
    func viaBox(_ v: BoardDRC.Track) -> IBox {
        let r = (v.diameter + 1) / 2
        return IBox(minX: v.start.x - r, minY: v.start.y - r, maxX: v.start.x + r + 1, maxY: v.start.y + r + 1)
    }

    /// PCB_TRACK::GetBoundingBox: its ends' (an arc's shape's) box grown by half its width rounded up, a nanometre wider
    func trackBox(_ t: BoardDRC.CopperItem) -> IBox {
        let radius = (t.trackWidth + 1) / 2
        var b: IBox
        if t.kind == .arc, let s = t.shapes.values.first?.first {
            b = s.bbox
        } else {
            b = IBox(t.trackStart, t.trackEnd)
        }
        return IBox(minX: b.minX - radius, minY: b.minY - radius, maxX: b.maxX + radius + 1, maxY: b.maxY + radius + 1)
    }

    func buildCopperItemClearances(_ z: FillZone, _ layer: Int, _ noConnectionPads: [FillPad], _ holes: inout PolySet) {
        let zoneBox = z.bbox.inflated(worstClearance + extraMargin)
        let rl = routerLayer(layer)

        // the pads not connected
        var processed = Set<PadKey>()
        for pad in noConnectionPads {
            if let key = padKey(pad), !processed.insert(key).inserted { continue }
            let initGap = evalRules(.physicalClearance, z, pad.item, layer)
            var gap = initGap
            let hasHole = pad.p.drill.x > 0
            let flash = padFlashLayer(pad, layer)
            let platedHole = hasHole && pad.p.attribute == .pth
            if flash || platedHole { gap = max(gap, evalRules(.clearance, z, pad.item, layer)) }
            if flash && gap >= 0 { addPadKnockout(pad, gap + extraMargin, &holes) }
            if hasHole {
                if pad.p.attribute == .npth { gap = initGap }
                gap = max(gap, evalRules(.physicalHoleClearance, z, pad.item, layer))
                gap = max(gap, evalRules(.holeClearance, z, pad.item, layer))
                if pad.p.attribute == .npth && pad.p.drill.x != pad.p.drill.y { gap = max(gap, evalRules(.edgeClearance, z, pad.item, layer)) }
                if gap >= 0 { holes.append(holePolygon(pad, gap + extraMargin)) }
            }
        }

        // the tracks and vias not connected
        var processedVias = Set<[Int]>()
        var processedTracks = Set<[Int]>()
        for t in copper.tracks {
            guard let rl, t.layers.contains(rl) else { continue }
            if let v = t.via {
                if !processedVias.insert([v.start.x, v.start.y, max(v.drill, v.diameter), t.net]).inserted { continue }
            } else {
                let (a, b) = t.trackStart.x < t.trackEnd.x || (t.trackStart.x == t.trackEnd.x && t.trackStart.y <= t.trackEnd.y)
                    ? (t.trackStart, t.trackEnd) : (t.trackEnd, t.trackStart)
                if !processedTracks.insert([a.x, a.y, b.x, b.y, t.trackWidth]).inserted { continue }
            }
            let box = t.via.map(viaBox) ?? trackBox(t)
            guard box.intersects(zoneBox) else { continue }
            var sameNet = t.net == z.net
            if !z.isTeardrop && z.net == 0 { sameNet = false }
            var gap = evalRules(.physicalClearance, z, t, layer)
            if !sameNet { gap = max(gap, evalRules(.clearance, z, t, layer)) }
            if let v = t.via {
                if gap > 0 {
                    holes.addOutline(PadPolygon.circle(center: v.start, radius: v.diameter / 2 + gap + extraMargin, maxError: maxError,
                                                       errorLocation: .outside))
                }
                gap = max(gap, evalRules(.physicalHoleClearance, z, t, layer))
                if !sameNet { gap = max(gap, evalRules(.holeClearance, z, t, layer)) }
                if gap >= 0 {
                    holes.addOutline(PadPolygon.circle(center: v.start, radius: v.drill / 2 + gap + extraMargin, maxError: maxError,
                                                       errorLocation: .outside))
                }
            } else if gap >= 0 {
                let w = t.trackWidth + 2 * (gap + extraMargin)
                if t.kind == .arc {
                    holes.append(PadPolygon.arc(start: t.trackStart, mid: t.trackMid, end: t.trackEnd, width: w, maxError: maxError,
                                                errorLocation: .outside))
                } else {
                    holes.append(PadPolygon.oval(start: t.trackStart, end: t.trackEnd, width: w, maxError: maxError, errorLocation: .outside))
                }
            }
        }

        // the drawings and texts: the footprints' (their reference and value, then their drawings), then the board's
        let fps = drc.board.root.all("footprint")
        for (f, fp) in fps.enumerated() {
            let placement = BoardWorld.FootprintPlacement(fp)
            knockoutCourtyard(z, layer, f, zoneBox, &holes)
            for field in fp.all("property") where ["Reference", "Value"].contains(field.text(at: 0) ?? "") {
                knockoutGraphic(z, layer, field, footprint: fp, footprintIndex: f, placement: placement, zoneBox, &holes)
            }
            // a net tie's drawings touching its pads of the zone's net (or those tied to them) left in
            var allowed: [BoardDRC.CopperItem] = []
            if copper.isNetTie(f) {
                for pad in copper.footprintPads[f] {
                    var sameNet = pad.net == z.net
                    if !z.isTeardrop && z.net == 0 { sameNet = false }
                    guard sameNet else { continue }
                    if let rl, pad.layers.contains(rl), !allowed.contains(where: { $0 === pad }) { allowed.append(pad) }
                    let g = copper.netTieGroup(pad)
                    if g >= 0 {
                        for other in copper.footprintPads[f] where other !== pad && copper.netTieGroup(other) == g {
                            if let rl, other.layers.contains(rl), !allowed.contains(where: { $0 === other }) { allowed.append(other) }
                        }
                    }
                }
            }
            for node in fp.items {
                let head = node.head ?? ""
                guard BoardWorld.footprintShapeHeads.contains(head) || head == "fp_text" || head == "fp_text_box" else { continue }
                if BoardWorld.footprintShapeHeads.contains(head), let rl, node.value("layer").flatMap({ world.layerIndex[$0] }) == rl {
                    // (the footprint's copper drawing, as the clearance checks have it)
                    let item = copper.footprintDrawings[f].first { $0.uuid == (node.value("uuid") ?? "") }
                    if let item, !allowed.isEmpty {
                        var skip = false
                        for pad in allowed where pad.bbox.intersects(item.bbox) {
                            if BoardDRC.collide(pad.anyLayerShapes(rl), item.shapes[rl] ?? [], 0) != nil {
                                skip = true
                                break
                            }
                        }
                        if skip { continue }
                    }
                }
                knockoutGraphic(z, layer, node, footprint: fp, footprintIndex: f, placement: placement, zoneBox, &holes)
            }
        }
        for node in drc.board.root.items {
            switch node.head ?? "" {
            case "gr_line", "gr_rect", "gr_arc", "gr_circle", "gr_poly", "gr_curve", "gr_text":
                knockoutGraphic(z, layer, node, footprint: nil, footprintIndex: nil, placement: nil, zoneBox, &holes)
            default:
                break
            }
        }
        holes.simplify()
    }

    /// knockoutGraphicClearance of a drawing or text: on the zone's layer (of another net) by its clearance, on
    /// Edge.Cuts by the board's edge clearance (its line's width left out), on Margin by it too
    func knockoutGraphic(_ z: FillZone, _ layer: Int, _ node: SExpr, footprint fp: SExpr?, footprintIndex: Int?,
                         placement: BoardWorld.FootprintPlacement?, _ zoneBox: IBox, _ holes: inout PolySet) {
        let head = node.head ?? ""
        let isText = head == "property" || head == "fp_text" || head == "gr_text"
        guard let layerName = BoardWorld.itemLayer(node) else { return }
        let onLayer = layerName == layerNames[layer]
        guard onLayer || layerName == "Edge.Cuts" || layerName == "Margin" else { return }
        // the item as the rules see it, and its box
        var item: BoardDRC.CopperItem?
        var rule: RuleItem?
        let box: IBox
        var text: TextStrokes?
        if isText {
            guard let t = BoardWorld.textStrokes(node, footprint: fp, unsupported: { self.unsupported.insert($0) }) else { return }
            text = t
            box = t.boundingBox
            if node.flag("knockout") || node["layer"]?.arguments.contains(where: { $0.text == "knockout" }) == true {
                unsupported.insert("knockout text")
            }
            rule = textRuleItem(node, layerName: layerName, footprint: footprintIndex, box: box)
        } else {
            guard let o = world.outlineShape(node, placement: placement) else {
                unsupported.insert("drawing")
                return
            }
            box = BoardDRC.drawingBox(o, filled: BoardDRC.solidFill(node), maxError: maxError).0
            if onLayer {
                let uuid = node.value("uuid") ?? ""
                if let f = footprintIndex {
                    item = copper.footprintDrawings[f].first { $0.uuid == uuid }
                } else {
                    item = copper.drawings.first { $0.uuid == uuid }
                }
            }
        }
        // (a PCB_SHAPE's net: a footprint's drawing has none)
        let shapeNet = isText ? -1 : (footprintIndex != nil ? 0 : item?.net ?? 0)
        var sameNet = shapeNet == z.net
        if !z.isTeardrop && z.net == 0 { sameNet = false }
        guard box.intersects(zoneBox) else { return }
        if rule == nil {
            if let item {
                rule = drc.ruleItem(item, copper)
            } else {
                // (a drawing off copper: its layer and box)
                let r = RuleItem(.shape, uuid: node.value("uuid") ?? "")
                r.parentFootprint = footprintIndex.map { drc.ruleState.footprints[$0] }
                r.layer = KiLayer.id(layerName) ?? KiLayer.undefined
                r.layerSet = KiLayerSet([r.layer])
                r.bbox = box
                r.netClass = drc.ruleNetClass("")
                rule = r
            }
        }
        var ignoreLineWidth = false
        var gap = evalRules(.physicalClearance, z, rule!, layer)
        if onLayer && !sameNet {
            gap = max(gap, evalRules(.clearance, z, rule!, layer))
        } else if layerName == "Edge.Cuts" {
            gap = max(gap, evalRules(.edgeClearance, z, rule!, layer))
            ignoreLineWidth = true
        } else if layerName == "Margin" {
            gap = max(gap, evalRules(.edgeClearance, z, rule!, layer))
        }
        guard gap >= 0 else { return }
        gap += extraMargin
        if let text {
            guard text.visible else { return }
            if let hull = BoardDRC.textHull(node, footprint: fp, maxError: maxError, errorLocation: .outside, clearance: gap) {
                holes.append(hull)
            }
        } else if let poly = drc.drawingPolygon(node, placement: placement, maxError: maxError, errorLocation: .outside,
                                                clearance: gap, ignoreLineWidth: ignoreLineWidth) {
            holes.append(poly)
        } else {
            unsupported.insert("rounded rectangle outline")
        }
    }

    /// buildDifferentNetZoneClearances: the fills of higher zones of other nets that may reach this one, each grown by
    /// the clearance between the two (no rule areas: their outlines are taken out with the items' clearances)
    func buildDifferentNetZoneClearances(_ z: FillZone, _ layer: Int, _ holes: inout PolySet) {
        for k in zones {
            if k.ruleArea || !k.isOnLayer(layer) { continue }
            guard k.higherPriority(z) && !k.sameNet(z) && zoneKnockoutMayInteract(z, k) else { continue }
            var gap = max(0, evalRules(.physicalClearance, z, ruleZone(k), layer))
            gap = max(gap, evalRules(.clearance, z, ruleZone(k), layer))
            guard let f = k.fills[layer] else { continue }
            holes.append(zoneShapePolygon(f, gap + extraMargin))
        }
        holes.simplify()
    }

    /// ZONE::TransformShapeToPolygon: the fill grown by a clearance (and the error), its holes linked
    func zoneShapePolygon(_ fill: PolySet, _ clearance: Int) -> PolySet {
        var buf = fill
        if clearance == 0 { return buf }
        buf.inflateWithLinkedHoles(clearance + maxError, .roundAllCorners, maxError: maxError)
        return buf
    }

    /// subtractHigherPriorityZones: the outlines of the zones of its net of higher priority (not teardrops)
    func subtractHigherPriorityZones(_ z: FillZone, _ layer: Int, _ fill: inout PolySet) {
        var knockouts = PolySet()
        for k in zones where k.sameNet(z) && k.priority > z.priority && !k.isTeardrop {
            guard k.isOnLayer(layer), k.bbox.intersects(z.bbox) else { continue }
            knockouts.append(k.outline)
        }
        if knockouts.outlineCount > 0 { fill.booleanSubtract(knockouts) }
    }

    /// dropSubResolutionOutlines: outlines of less area than the maximum error squared
    func dropSubResolutionOutlines(_ polys: inout PolySet) {
        let noise = Double(maxError) * Double(maxError)
        for ii in stride(from: polys.outlineCount - 1, through: 0, by: -1) where polys.polygons[ii][0].area() < noise {
            polys.deletePolygon(ii)
        }
    }

    /// postKnockoutMinWidthPrune: the minimum width pruned again after the other zones' knockouts, the same-net apron
    /// standing in for the zones the fill meets
    func postKnockoutMinWidthPrune(_ z: FillZone, _ fill: inout PolySet, _ apronIn: PolySet) {
        let halfMinWidth = z.minThickness / 2
        let epsilon = 1000
        if halfMinWidth - epsilon <= epsilon { return }
        let preDeflate = fill
        if apronIn.outlineCount > 0 {
            var apron = apronIn
            apron.inflate(epsilon, .roundAllCorners, maxError: maxError)
            fill.booleanAdd(apron)
        }
        fill.deflate(halfMinWidth - epsilon, .chamferAllCorners, maxError: maxError)
        fill.fracture()
        connectNearbyPolys(&fill, z.minThickness)
        dropSmallIslands(&fill, z.minThickness)
        fill.inflate(halfMinWidth - epsilon, .roundAllCorners, maxError: maxError, simplify: true)
        fill.booleanIntersection(preDeflate)
    }

    // MARK: - Spokes (buildThermalSpokes)

    func buildThermalSpokes(_ z: FillZone, _ layer: Int, _ items: [ThermalItem]) -> [LineChain] {
        var spokes: [LineChain] = []
        var zoneHalfWidth = z.minThickness / 2
        if z.hatched { zoneHalfWidth = z.hatchThickness / 2 }
        let biggest = drc.ruleState.engine.biggestClearanceValue(drc.settings)
        let zoneBB = z.bbox.inflated(max(biggest, z.localClearance))
        let epsilon = maxError
        for t in items {
            var pad: FillPad?
            var via: BoardDRC.CopperItem?
            var circular = false
            switch t {
            case .pad(let p):
                guard padOnLayer(p, layer) else { continue }
                pad = p
                circular = p.p.kind == .circle || (p.p.kind == .oval && p.p.size.x == p.p.size.y)
            case .via(let v):
                guard let rl = routerLayer(layer), v.layers.contains(rl) else { continue }
                via = v
                circular = true
            }
            var gap = 0, spokeW = 0
            if let pad {
                gap = thermalGap(pad.item, z, layer)
                let w = spokeWidth(pad.item, z, layer)
                spokeW = min(max(w.opt, w.min), w.max)
                spokeW = min(spokeW, min(pad.p.size.x, pad.p.size.y))
                if spokeW < z.minThickness { continue }
            } else if let via, let v = via.via {
                guard z.hatched else { continue }
                gap = thermalGap(via, z, layer)
                spokeW = min(spokeWidth(via, z, layer).opt, v.diameter)
                if spokeW < z.minThickness { continue }
            }
            let spokeHalfW = spokeW / 2
            let itemBB = (pad.map { $0.item.bbox } ?? via.flatMap { $0.via.map(viaBox) }!).inflated(gap + epsilon)
            if !itemBB.intersects(zoneBB) { continue }

            if let pad, pad.p.kind == .custom, !pad.spokeTemplates.isEmpty {
                spokes += customSpokes(pad, z, layer, gap, epsilon, spokeHalfW)
                continue
            }

            func buildSpokesFromOrigin(_ box: IBox, _ angle: EDAAngle) {
                let center = box.center
                let halfSize = IPoint(KiMath.round(Double(box.width) / 2.0), KiMath.round(Double(box.height) / 2.0))
                func intersectBBox(_ spokeAngle: EDAAngle) -> (IPoint, IPoint) {
                    let dx = spokeAngle.cos, dy = spokeAngle.sin
                    if dx == 0 { return (IPoint(spokeHalfW, 0), IPoint(0, KiMath.round(dy * Double(halfSize.y)))) }
                    if dy == 0 { return (IPoint(0, spokeHalfW), IPoint(KiMath.round(dx * Double(halfSize.x)), 0)) }
                    let distX = Double(halfSize.x) / abs(dx), distY = Double(halfSize.y) / abs(dy)
                    if distX < distY {
                        return (IPoint(0, KiMath.round(Double(spokeHalfW) / (EDAAngle.a90 - spokeAngle).sin)),
                                IPoint(KiMath.round(dx * distX), KiMath.round(dy * distX)))
                    }
                    return (IPoint(KiMath.round(Double(spokeHalfW) / spokeAngle.sin), 0),
                            IPoint(KiMath.round(dx * distY), KiMath.round(dy * distY)))
                }
                for a in [EDAAngle(degrees: 0) + angle, EDAAngle(degrees: 90) + angle, EDAAngle(degrees: 180) + angle,
                          EDAAngle(degrees: 270) + angle] {
                    let (side, intersection) = intersectBBox(a)
                    var spoke = LineChain()
                    spoke.append(center + side)
                    spoke.append(center - side)
                    spoke.append(center + intersection - side)
                    spoke.append(center + intersection)
                    spoke.append(center + intersection + side)
                    spoke.setClosed(true)
                    spokes.append(spoke)
                }
            }

            let spokeAngle = pad?.spokeAngle ?? .zero
            var spokesBox: IBox
            var position = IPoint.zero
            var orientation = EDAAngle.zero
            if let pad {
                // (a copy of the pad at the origin, not turned, its shape not offset)
                var dummy = pad.p
                dummy.pos = .zero
                dummy.orientation = .zero
                dummy.offset = .zero
                var shapes = world.effectiveShapes(dummy)
                if pad.p.kind == .custom {
                    for prim in pad.pad.primitives {
                        guard let d = world.readDrawing(prim, placement: nil), let s = world.effectiveShapes(d) else { continue }
                        shapes += s
                    }
                }
                var b = shapes.first?.bbox ?? IBox(minX: 0, minY: 0, maxX: 0, maxY: 0)
                for s in shapes.dropFirst() { b.merge(s.bbox) }
                spokesBox = b
                position = pad.p.shapePos
                orientation = pad.p.orientation
            } else {
                var v = via!.via!
                v.start = .zero
                spokesBox = viaBox(v)
                position = via!.via!.start
            }
            spokesBox = spokesBox.inflated(gap + epsilon + zoneHalfWidth)
            let first = spokes.count
            if circular {
                buildSpokesFromOrigin(spokesBox, .zero)
                if spokeAngle != .zero {
                    for i in first..<spokes.count { spokes[i] = spokes[i].rotated(spokeAngle) }
                }
            } else {
                buildSpokesFromOrigin(spokesBox, spokeAngle)
            }
            for i in first..<spokes.count { spokes[i] = spokes[i].rotated(orientation).moved(position) }
        }
        return spokes
    }

    /// A custom pad's spokes along its spoke templates, trimmed to the pad and its thermal relief
    func customSpokes(_ pad: FillPad, _ z: FillZone, _ layer: Int, _ gap: Int, _ epsilon: Int, _ spokeHalfW: Int) -> [LineChain] {
        var out: [LineChain] = []
        guard let thermalPoly = padPolygon(pad, gap + epsilon), let effective = padPolygon(pad, 0) else { return out }
        let thermalOutline = thermalPoly.polygons.first?[0] ?? LineChain()
        guard let padOutline = effective.polygons.first?[0] else { return out }
        func trimToOutline(_ seg: inout Seg) -> Bool {
            if !padOutline.intersect(seg).isEmpty {
                if let first = thermalOutline.intersect(seg).first {
                    seg = Seg(seg.a, first.p)
                    return true
                }
            }
            return false
        }
        for (a0, b0) in pad.spokeTemplates {
            var seg = Seg(KiMath.rotate(a0, pad.p.orientation) + pad.p.shapePos, KiMath.rotate(b0, pad.p.orientation) + pad.p.shapePos)
            if !effective.contains(seg.a) {
                if !effective.contains(seg.b) { continue }
                seg = Seg(seg.b, seg.a)
            }
            guard trimToOutline(&seg) else { continue }
            var direction = (seg.b - seg.a).resized(spokeHalfW)
            let offset = direction.perpendicular.resized(spokeHalfW)
            var segL = Seg(seg.a - direction - offset, seg.b + direction - offset)
            var segR = Seg(seg.a - direction + offset, seg.b + direction + offset)
            guard trimToOutline(&segL) && trimToOutline(&segR) else { continue }
            direction = direction.resized(z.minThickness)
            var spoke = LineChain()
            spoke.append(seg.a + offset)
            spoke.append(seg.a - offset)
            spoke.append(segL.b + direction)
            spoke.append(seg.b + direction)
            spoke.append(segR.b + direction)
            spoke.setClosed(true)
            out.append(spoke)
        }
        return out
    }

    // MARK: - Hatching

    func buildHatchZoneThermalRings(_ z: FillZone, _ layer: Int, _ smoothedOutline: PolySet, _ items: [ThermalItem],
                                    _ fill: inout PolySet, _ rings: inout PolySet) {
        for t in items {
            var isCircular = false
            var gap = 0, spokeW = 0, padRadius = 0
            var position = IPoint.zero
            var pad: FillPad?
            switch t {
            case .pad(let p):
                guard padOnLayer(p, layer) else { continue }
                pad = p
                position = p.p.shapePos
                isCircular = p.p.kind == .circle || (p.p.kind == .oval && p.p.size.x == p.p.size.y)
                if isCircular { padRadius = max(p.p.size.x, p.p.size.y) / 2 }
                gap = thermalGap(p.item, z, layer)
                spokeW = min(spokeWidth(p.item, z, layer).opt, min(p.p.size.x, p.p.size.y))
            case .via(let v):
                guard let rl = routerLayer(layer), v.layers.contains(rl), let via = v.via else { continue }
                position = via.start
                isCircular = true
                padRadius = via.diameter / 2
                gap = thermalGap(v, z, layer)
                spokeW = min(spokeWidth(v, z, layer).opt, padRadius * 2)
            }
            if spokeW < z.minThickness { continue }
            var ring: PolySet
            if isCircular {
                let inner = padRadius + gap
                ring = PadPolygon.ring(center: position, radius: inner + spokeW / 2, width: spokeW, maxError: maxError, errorLocation: .outside)
            } else {
                guard let pad, let outer = padPolygon(pad, gap + spokeW), let inner = padPolygon(pad, gap) else { continue }
                ring = outer
                ring.booleanSubtract(inner)
            }
            ring.booleanIntersection(smoothedOutline)
            fill.booleanAdd(ring)
            rings.booleanAdd(ring)
        }
    }

    func addHatchFillTypeOnZone(_ z: FillZone, _ layer: Int, _ fill: inout PolySet, _ thermalRings: PolySet) {
        let thickness = max(z.hatchThickness, z.minThickness + 1000)
        let gridsize = thickness + z.hatchGap
        var maxError = self.maxError
        var filledPolys = fill
        if z.hatchOrientation.degrees != 0 { filledPolys.rotate(EDAAngle(degrees: -z.hatchOrientation.degrees)) }
        let bbox = filledPolys.bbox(0)
        var holeBase = LineChain()
        let holeSize = z.hatchGap + z.minThickness
        holeBase.append(IPoint(0, 0))
        holeBase.append(IPoint(holeSize, 0))
        holeBase.append(IPoint(holeSize, holeSize))
        holeBase.append(IPoint(0, holeSize))
        holeBase.setClosed(true)
        let minimalHoleArea = holeBase.area() * z.hatchHoleMinArea
        if z.hatchSmoothingLevel > 0 {
            var smoothValue = KiMath.round(Double(z.hatchGap) * z.hatchSmoothingValue / 2)
            if smoothValue > 20_000 {
                var smoothHole = PolySet()
                smoothHole.addOutline(holeBase)
                var level = z.hatchSmoothingLevel
                if smoothValue < 40_000 && level > 1 { level = 1 }
                smoothValue += z.minThickness / 2
                smoothValue = min(smoothValue, z.hatchGap / 2)
                maxError = max(maxError * 2, smoothValue / 20)
                switch level {
                case 1:
                    holeBase = smoothHole.chamfer(smoothValue).polygons[0][0]
                default:
                    if z.hatchSmoothingLevel > 2 { maxError /= 2 }
                    holeBase = smoothHole.fillet(smoothValue, maxError: maxError).polygons[0][0]
                }
            }
        }
        var holes = PolySet()
        if drc.board.root["setup"]?["zone_defaults"] != nil { unsupported.insert("the board's default hatch offsets") }
        let offset = z.hatchOffsets[layer] ?? .zero
        let xOffset = bbox.minX - bbox.minX % gridsize - gridsize
        let yOffset = bbox.minY - bbox.minY % gridsize - gridsize
        var xx = xOffset
        while xx <= bbox.maxX {
            var yy = yOffset
            while yy <= bbox.maxY {
                var hole = holeBase.moved(IPoint(xx, yy))
                if z.hatchOrientation.degrees != 0 { hole = hole.rotated(z.hatchOrientation) }
                hole = hole.moved(IPoint(offset.x % gridsize, offset.y % gridsize))
                holes.addOutline(hole)
                yy += gridsize
            }
            xx += gridsize
        }
        var deflatedThickness = z.hatchThickness - z.minThickness
        deflatedThickness = max(deflatedThickness, maxError * 2)
        var deflatedFilled = fill
        deflatedFilled.deflate(deflatedThickness, .chamferAllCorners, maxError: maxError)
        holes.booleanIntersection(deflatedFilled)
        var deflatedOutline = z.outline
        deflatedOutline.deflate(z.minThickness, .chamferAllCorners, maxError: maxError)
        holes.booleanIntersection(deflatedOutline)
        var ii = 0
        while ii < holes.outlineCount {
            if holes.polygons[ii][0].area() < minimalHoleArea { holes.deletePolygon(ii) } else { ii += 1 }
        }
        if thermalRings.outlineCount > 0 {
            let thermalBBox = thermalRings.bbox(0)
            for holeIdx in stride(from: holes.outlineCount - 1, through: 0, by: -1) {
                let hole = holes.polygons[holeIdx][0]
                let holeBBox = hole.bbox
                if !holeBBox.intersects(thermalBBox) { continue }
                for ringIdx in 0..<thermalRings.outlineCount {
                    let ring = thermalRings.polygons[ringIdx][0]
                    let ringBBox = ring.bbox
                    if !holeBBox.contains(ringBBox) { continue }
                    if !hole.pointInside(ringBBox.center) { continue }
                    if ring.pointCount == 0 || !hole.pointInside(ring.point(0)) { continue }
                    if ring.intersect(hole).isEmpty {
                        holes.deletePolygon(holeIdx)
                        break
                    }
                }
            }
        }
        fill.booleanSubtract(holes)
    }

    // MARK: - fillNonCopperZone

    func fillNonCopperZone(_ z: FillZone, _ layer: Int, _ smoothedOutline: PolySet) -> PolySet {
        // (knockout items on the layer, which KiCad takes out of the fill: not made here)
        drc.board.root.walk { node in
            if let l = node["layer"], l.text(at: 0) == layerNames[layer], l.arguments.contains(where: { $0.text == "knockout" }) {
                unsupported.insert("knockout item")
            }
        }
        var fill = smoothedOutline
        var keepoutHoles = PolySet()
        for k in zones where isZoneFillKeepout(k, layer, z.bbox) { keepoutHoles.append(k.outline) }
        if keepoutHoles.outlineCount > 0 { fill.booleanSubtract(keepoutHoles) }
        let halfMinWidth = z.minThickness / 2
        let epsilon = 1000
        fill.deflate(halfMinWidth - epsilon, .chamferAllCorners, maxError: maxError)
        if z.hatched { addHatchFillTypeOnZone(z, layer, &fill, PolySet()) }
        if halfMinWidth - epsilon > epsilon { fill.inflate(halfMinWidth - epsilon, .roundAllCorners, maxError: maxError) }
        fill.fracture()
        return fill
    }

    // MARK: - The iterative refill (refillZoneFromCache)

    func refillZoneFromCache(_ z: FillZone, _ layer: Int, _ snapshot: [FillKey: PolySet]) -> PolySet? {
        let key = FillKey(z, layer)
        guard var fill = preKnockoutFill[key] else { return nil }
        let zoneBox = z.bbox.inflated(worstClearance + extraMargin)
        var knockoutsApplied = false
        var diffNet = PolySet(), sameNet = PolySet()
        for k in zones {
            if k === z || !k.isOnLayer(layer) { continue }
            if k.isTeardrop && k.sameNet(z) { continue }
            if !k.higherPriority(z) { continue }
            if k.sameNet(z) {
                if !k.bbox.intersects(zoneBox) { continue }
            } else if !zoneKnockoutMayInteract(z, k) {
                continue
            }
            guard let f = snapshot[FillKey(k, layer)], f.outlineCount > 0 else { continue }
            if k.sameNet(z) {
                let ownsOutline = k.hatched && k.priority > z.priority
                if ownsOutline { sameNet.append(k.outline) } else { sameNet.append(f) }
            } else {
                var gap = max(0, evalRules(.physicalClearance, z, ruleZone(k), layer))
                gap = max(gap, evalRules(.clearance, z, ruleZone(k), layer))
                var inflated = f
                inflated.inflate(gap + extraMargin + maxError, .roundAllCorners, maxError: maxError)
                diffNet.append(inflated)
                knockoutsApplied = true
            }
        }
        if diffNet.outlineCount > 0 { fill.booleanSubtract(diffNet) }
        if knockoutsApplied {
            var apron = sameNetApronCache[key] ?? PolySet()
            if apron.outlineCount > 0 && diffNet.outlineCount > 0 { apron.booleanSubtract(diffNet) }
            postKnockoutMinWidthPrune(z, &fill, apron)
        }
        if sameNet.outlineCount > 0 { fill.booleanSubtract(sameNet) }
        if z.hatched {
            let solidExtent = preHatchSolid[key] ?? PolySet()
            var knockouts = diffNet
            knockouts.append(sameNet)
            if solidExtent.outlineCount > 0 && knockouts.outlineCount > 0 {
                var border = knockouts
                border.inflate(z.minThickness, .roundAllCorners, maxError: maxError)
                border.booleanSubtract(knockouts)
                border.booleanIntersection(solidExtent)
                fill.booleanAdd(border)
            }
        }
        dropSubResolutionOutlines(&fill)
        fill.fracture()
        return fill
    }

    // MARK: - connect_nearby_polys

    /// connect_nearby_polys: each pair of convex points of the outlines within `distance` of each other (not near
    /// along one outline) joined by a line of no width, so that inflating joins them
    func connectNearbyPolys(_ polys: inout PolySet, _ distance: Int) {
        guard polys.outlineCount >= 1 else { return }
        var bbox = polys.polygons[0][0].bbox
        for p in polys.polygons.dropFirst() { bbox.merge(p[0].bbox) }
        let vs = VertexConnector(bbox, polys, distance)
        vs.findResults()
        var insertion: [Int: [(Int, IPoint)]] = [:]
        for r in vs.results.sorted(by: <) {
            let pt1 = polys.polygons[r.outline1][0].point(r.vertex1)
            let pt2 = polys.polygons[r.outline2][0].point(r.vertex2)
            insertion[r.outline1, default: []].append((r.vertex1, pt1))
            insertion[r.outline1, default: []].append((r.vertex1, pt2))
        }
        for outline in insertion.keys.sorted() {
            // (a stable sort, the highest index first)
            let vertices = insertion[outline]!.enumerated().sorted { a, b in
                a.element.0 != b.element.0 ? a.element.0 > b.element.0 : a.offset < b.offset
            }.map(\.element)
            for (vertex, pt) in vertices { polys.polygons[outline][0].insert(pt, at: vertex + 1) }
        }
    }
}

/// A result of VERTEX_CONNECTOR: two outlines' points to join
struct ConnectorResult: Hashable, Comparable {
    let outline1: Int, outline2: Int, vertex1: Int, vertex2: Int

    static func < (a: ConnectorResult, b: ConnectorResult) -> Bool {
        if a.outline1 != b.outline1 { return a.outline1 < b.outline1 }
        if a.outline2 != b.outline2 { return a.outline2 < b.outline2 }
        if a.vertex1 != b.vertex1 { return a.vertex1 < b.vertex1 }
        return a.vertex2 < b.vertex2
    }
}

/// A point of VERTEX_CONNECTOR's list (KiCad's VERTEX, its user data the outline it is of)
final class ConnectorVertex {
    let i: Int
    let x: Double, y: Double
    let outline: Int
    unowned(unsafe) var prev: ConnectorVertex?
    unowned(unsafe) var next: ConnectorVertex?
    unowned(unsafe) var prevZ: ConnectorVertex?
    unowned(unsafe) var nextZ: ConnectorVertex?
    var z: UInt32 = 0

    init(_ i: Int, _ x: Double, _ y: Double, _ outline: Int) { (self.i, self.x, self.y, self.outline) = (i, x, y, outline) }

    func remove() {
        next!.prev = prev
        prev!.next = next
        if let prevZ { prevZ.nextZ = nextZ }
        if let nextZ { nextZ.prevZ = prevZ }
        next = nil
        prev = nil
        nextZ = nil
        prevZ = nil
    }

    func same(_ o: ConnectorVertex) -> Bool { x == o.x && y == o.y }

    func inTriangle(_ a: ConnectorVertex, _ b: ConnectorVertex, _ c: ConnectorVertex) -> Bool {
        (c.x - x) * (a.y - y) - (a.x - x) * (c.y - y) >= 0 && (a.x - x) * (b.y - y) - (b.x - x) * (a.y - y) >= 0
            && (b.x - x) * (c.y - y) - (c.x - x) * (b.y - y) >= 0
    }
}

/// VERTEX_CONNECTOR: the outlines' points in one ring (VERTEX_SET::createList onto the last outline's tail), in
/// z-order over their box, and the pairs of convex points of different outlines (or far apart along one) nearer than
/// a distance
final class VertexConnector {
    private var vertices: [ConnectorVertex] = []
    private let bbox: IBox
    /// (VERTEX_SET squares the level it is made with: 50 nm)
    private let simplificationLevel = 50 * 50
    private var outlineDistances: [[Double]] = []
    private let dist: Int
    private(set) var results = Set<ConnectorResult>()

    init(_ bbox: IBox, _ polys: PolySet, _ distance: Int) {
        self.bbox = bbox
        dist = distance
        var tail: ConnectorVertex?
        for i in 0..<polys.outlineCount {
            let outline = polys.polygons[i][0]
            var distances: [Double] = [0]
            for j in 0..<outline.pointCount {
                distances.append(distances.last! + Double((outline.point(j + 1) - outline.point(j)).norm))
            }
            outlineDistances.append(distances)
            tail = createList(outline, tail, i)
        }
        tail?.updateList(self)
    }

    private func insertVertex(_ index: Int, _ pt: IPoint, _ last: ConnectorVertex?, _ outline: Int) -> ConnectorVertex {
        let p = ConnectorVertex(index, Double(pt.x), Double(pt.y), outline)
        vertices.append(p)
        if let last {
            p.next = last.next
            p.prev = last
            last.next!.prev = p
            last.next = p
        } else {
            p.prev = p
            p.next = p
        }
        return p
    }

    private func createList(_ points: LineChain, _ aTail: ConnectorVertex?, _ outline: Int) -> ConnectorVertex? {
        var tail = aTail
        var sum = 0.0
        for i in 0..<points.pointCount {
            let p1 = DPoint(points.point(i)), p2 = DPoint(points.point(i + 1))
            sum += (p2.x - p1.x) * (p2.y + p1.y)
        }
        var last = IPoint.zero
        var first = true
        func add(_ i: Int) {
            let pt = points.point(i)
            if first || (pt - last).squaredNorm > simplificationLevel {
                tail = insertVertex(i, pt, tail, outline)
                last = pt
                first = false
            }
        }
        if sum > 0 {
            for i in stride(from: points.pointCount - 1, through: 0, by: -1) { add(i) }
        } else {
            for i in 0..<points.pointCount { add(i) }
        }
        if let t = tail, t.same(t.next!) { t.next!.remove() }
        return tail
    }

    func zOrder(_ ax: Double, _ ay: Double) -> UInt32 {
        let limitX = min(max((ax - Double(bbox.minX)) / Double(bbox.width), 0), 1)
        let limitY = min(max((ay - Double(bbox.minY)) / Double(bbox.height), 0), 1)
        var x = Self.toUInt32(limitX * 32767.0), y = Self.toUInt32(limitY * 32767.0)
        x = (x | (x << 8)) & 0x00FF00FF
        x = (x | (x << 4)) & 0x0F0F0F0F
        x = (x | (x << 2)) & 0x33333333
        x = (x | (x << 1)) & 0x55555555
        y = (y | (y << 8)) & 0x00FF00FF
        y = (y | (y << 4)) & 0x0F0F0F0F
        y = (y | (y << 2)) & 0x33333333
        y = (y | (y << 1)) & 0x55555555
        return x | (y << 1)
    }

    /// static_cast<uint32_t> of a double as x86-64 makes it (through a 64-bit conversion; a NaN, of a box of no width,
    /// its lowest 32 bits of 0x8000000000000000)
    static func toUInt32(_ v: Double) -> UInt32 {
        if v.isNaN || v.isInfinite { return 0 }
        return UInt32(truncatingIfNeeded: Int64(v))
    }

    func area(_ p: ConnectorVertex, _ q: ConnectorVertex, _ r: ConnectorVertex) -> Double {
        (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y)
    }

    func isEar(_ v: ConnectorVertex, matchUserData: Bool) -> Bool {
        var a = v.prev!
        let b = v
        var c = v.next!
        if matchUserData {
            while a.outline != v.outline { a = a.prev! }
            while c.outline != v.outline { c = c.next! }
        }
        if area(a, b, c) >= 0 { return false }
        let minTX = min(a.x, min(b.x, c.x)), minTY = min(a.y, min(b.y, c.y))
        let maxTX = max(a.x, max(b.x, c.x)), maxTY = max(a.y, max(b.y, c.y))
        let minZ = zOrder(minTX, minTY), maxZ = zOrder(maxTX, maxTY)
        var p = v.nextZ
        while let q = p, q.z <= maxZ {
            if (!matchUserData || q.outline == v.outline) && q !== a && q !== c && q.inTriangle(a, b, c)
                && area(q.prev!, q, q.next!) >= 0 { return false }
            p = q.nextZ
        }
        p = v.prevZ
        while let q = p, q.z >= minZ {
            if (!matchUserData || q.outline == v.outline) && q !== a && q !== c && q.inTriangle(a, b, c)
                && area(q.prev!, q, q.next!) >= 0 { return false }
            p = q.prevZ
        }
        return true
    }

    private func getPoint(_ pt: ConnectorVertex) -> ConnectorVertex? {
        let d = Double(dist)
        let maxZ = zOrder(pt.x + d, pt.y + d), minZ = zOrder(pt.x - d, pt.y - d)
        let limit2 = dist * dist
        var minDist = Int.max
        var best: ConnectorVertex?
        func check(_ p: ConnectorVertex) {
            if p.outline == pt.outline {
                let distances = outlineDistances[p.outline]
                let direct = abs(distances[p.i] - distances[pt.i])
                let contour = min(direct, distances.last! - direct)
                if contour < d { return }
            }
            let dx = p.x - pt.x, dy = p.y - pt.y
            let dist2 = Int(dx * dx + dy * dy)
            if dist2 > 0 && dist2 < limit2 && dist2 < minDist && isEar(p, matchUserData: true) {
                minDist = dist2
                best = p
            }
        }
        var p = pt.nextZ
        while let q = p, q.z <= maxZ {
            check(q)
            p = q.nextZ
        }
        p = pt.prevZ
        while let q = p, q.z >= minZ {
            check(q)
            p = q.prevZ
        }
        return best
    }

    func findResults() {
        guard let front = vertices.first else { return }
        var p = front.next
        var visited = Set<ObjectIdentifier>()
        while let v = p, v !== front {
            if !isEar(v, matchUserData: false) {
                p = v.next
                continue
            }
            if !visited.contains(ObjectIdentifier(v)), let q = getPoint(v) {
                visited.insert(ObjectIdentifier(v))
                if !visited.contains(ObjectIdentifier(q)),
                   results.insert(ConnectorResult(outline1: v.outline, outline2: q.outline, vertex1: v.i, vertex2: q.i)).inserted {
                    for n in [v.prev!, v.prev!.prev!, v.next!, v.next!.next!, q.prev!, q.prev!.prev!, q.next!, q.next!.next!, q] {
                        visited.insert(ObjectIdentifier(n))
                    }
                }
            }
            p = v.next
        }
    }

    fileprivate func updateOrderOf(_ v: ConnectorVertex) {
        if v.z == 0 { v.z = zOrder(v.x, v.y) }
    }
}

extension ConnectorVertex {
    /// VERTEX::updateList: repeated points taken out, each point's z-order worked out, and the list sorted by it
    func updateList(_ set: VertexConnector) {
        var p = next!
        while p !== self {
            if p.same(p.next!) {
                p = p.prev!
                p.next!.remove()
                if p === p.next! { break }
            }
            set.updateOrderOf(p)
            p = p.next!
        }
        set.updateOrderOf(self)
        // zSort
        var queue: [ConnectorVertex] = [self]
        var q = next
        while let v = q, v !== self {
            queue.append(v)
            q = v.next
        }
        Clipper.introSort(&queue) { a, b in
            if a.z != b.z { return a.z < b.z }
            if a.x != b.x { return a.x < b.x }
            if a.y != b.y { return a.y < b.y }
            return a.i < b.i
        }
        var prevElem: ConnectorVertex?
        for elem in queue {
            prevElem?.nextZ = elem
            elem.prevZ = prevElem
            prevElem = elem
        }
        prevElem?.nextZ = nil
    }
}
