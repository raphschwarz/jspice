// Ported from KiCad 10.0.7: pcbnew/drc/drc_test_provider_disallow.cpp (items in keepout areas: tracks against the
// areas keeping tracks out, each crossing, and every other item by the implicit keepout rules), pcbnew/drc/drc_engine.cpp
// (loadImplicitRules' keepout area rules and EvalRules of DISALLOW_CONSTRAINT: what each item's type is kept out by,
// its layers, the last rule that applies), pcbnew/pcbexpr_functions.cpp (intersectsKeepout: collidesWithArea, an
// area's outline shrunk by the DRC's epsilon), libs/kimath/src/geometry/shape_poly_set.cpp (SHAPE_POLY_SET::Collide:
// a segment's and a circle's distance to its polygons, else its triangles one by one) and pcbnew/drc/drc_rtree.h
// (QueryColliding of a zone's fill with an area's first outline).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

extension BoardDRC {
    /// A rule area with keepout rules, one of the implicit rules DRC_ENGINE::loadImplicitRules makes of them
    struct Keepout {
        let uuid: String
        /// The footprint it is of (its index), nil for the board's own
        let footprint: Int?
        /// The rule's name: "keepout area", "keepout area 'NAME' of REF"...
        let ruleName: String
        let layers: Set<String>
        let tracks: Bool, vias: Bool, pads: Bool, zones: Bool, footprints: Bool
        /// Its outline (ZONE::Outline)
        var outline: PolySet
        /// Its outline shrunk by the DRC's epsilon, so that touching is not colliding, cut into triangles
        /// (getDeflatedZoneOutline)
        var deflated: PolySet
        let box: IBox?
    }

    /// The names of the layers an item is on, its wildcards spelt out (its LSET)
    func layerSet(_ node: SExpr) -> Set<String> {
        let names = node["layers"]?.arguments.map(\.text) ?? node.value("layer").map { [$0] } ?? []
        var out = Set<String>()
        let copperNames = world.layerIndex.keys
        for n in names {
            switch n {
            case "*.Cu": out.formUnion(copperNames)
            case "F&B.Cu": out.formUnion(["F.Cu", "B.Cu"])
            case _ where n.hasPrefix("*."): out.formUnion(["F" + n.dropFirst(), "B" + n.dropFirst()])
            default: out.insert(n)
            }
        }
        return out
    }

    /// The rule areas with keepout rules, the board's then each footprint's, in the order their rules are made
    func keepouts() -> [Keepout] {
        var out: [Keepout] = []
        func add(_ node: SExpr, footprint: Int?, reference: String?) {
            guard let k = node["keepout"] else { return }
            func notAllowed(_ name: String) -> Bool { k[name]?.text(at: 0) == "not_allowed" }
            let tracks = notAllowed("tracks"), vias = notAllowed("vias"), pads = notAllowed("pads")
            let zones = notAllowed("copperpour"), footprints = notAllowed("footprints")
            guard tracks || vias || pads || zones || footprints else { return }
            let name = node.value("name") ?? ""
            let ref = reference.map { $0.isEmpty ? "<no reference designator>" : $0 }
            let ruleName = name.isEmpty ? (ref.map { "keepout area of \($0)" } ?? "keepout area")
                : (ref.map { "keepout area '\(name)' of \($0)" } ?? "keepout area '\(name)'")
            let outline = BoardWorld.zoneOutline(node)
            var deflated = outline
            deflated.clearArcs()
            deflated.inflate(-settings.epsilon, .allowAcuteCorners, maxError: 20_000)
            deflated.cacheTriangulation()
            var box: IBox?
            for poly in outline.polygons { for p in poly[0].points { if box == nil { box = IBox(p, p) } else { box!.merge(p) } } }
            out.append(Keepout(uuid: node.value("uuid") ?? "", footprint: footprint, ruleName: ruleName, layers: layerSet(node),
                               tracks: tracks, vias: vias, pads: pads, zones: zones, footprints: footprints,
                               outline: outline, deflated: deflated, box: box))
        }
        for node in board.root.all("zone") { add(node, footprint: nil, reference: nil) }
        for (i, fp) in board.root.all("footprint").enumerated() {
            let reference = BoardWorld.FootprintPlacement(fp).reference
            for node in fp.all("zone") { add(node, footprint: i, reference: reference) }
        }
        return out
    }

    // MARK: - SHAPE_POLY_SET::Collide

    /// SHAPE_POLY_SET::containsSingle: inside a polygon's outline (or on it, `accuracy` away) and in none of its
    /// holes (nor on one)
    static func containsSingle(_ poly: [LineChain], _ p: IPoint, _ accuracy: Int) -> Bool {
        guard poly[0].pointInside(p, accuracy: accuracy) else { return false }
        for hole in poly.dropFirst() where hole.pointInside(p, accuracy: 1) { return false }
        return true
    }

    /// Each segment of a polygon's outline and then of its holes (CIterateSegmentsWithHoles)
    static func segmentsWithHoles(_ poly: [LineChain]) -> [Seg] {
        poly.flatMap { c in (0..<c.segmentCount).map(c.segment) }
    }

    /// SquaredDistanceToSeg: 0 for a segment both of whose ends are in a polygon, else the least distance to an edge
    static func squaredDistance(_ set: PolySet, _ s: Seg) -> Int {
        var best = Int.max
        for poly in set.polygons {
            var d: Int
            if containsSingle(poly, s.a, 1) && containsSingle(poly, s.b, 1) {
                d = 0
            } else {
                let segs = segmentsWithHoles(poly)
                guard let first = segs.first else { continue }
                d = first.squaredDistance(s)
                for e in segs.dropFirst() where d > 0 { d = min(d, e.squaredDistance(s)) }
            }
            best = min(best, d)
        }
        return best
    }

    /// SquaredDistance of a point: 0 inside a polygon, else the least distance to an edge
    static func squaredDistance(_ set: PolySet, _ p: IPoint) -> Int {
        var best = Int.max
        for poly in set.polygons {
            var d: Int
            if containsSingle(poly, p, 1) {
                d = 0
            } else {
                let segs = segmentsWithHoles(poly)
                guard let first = segs.first else { continue }
                d = first.squaredDistance(p)
                for e in segs.dropFirst() where d > 0 { d = min(d, e.squaredDistance(p)) }
            }
            best = min(best, d)
        }
        return best
    }

    /// SHAPE_POLY_SET::Collide of a shape, at no clearance: a segment and a circle by their distance to its polygons,
    /// anything else (a compound, a pad's, piece by piece) against its triangles in turn
    static func polySetCollide(_ set: PolySet, _ shapes: [Shape], compound: Bool, wantActual: Bool) -> Bool {
        if !compound, shapes.count == 1 {
            switch shapes[0] {
            case .segment(let s, let w):
                let extra = w / 2
                let d = squaredDistance(set, s)
                return d == 0 || d < extra * extra
            case .circle(let c, let r):
                guard set.polygons.contains(where: { $0.contains { $0.pointCount > 0 } }) else { return false }
                let d = squaredDistance(set, c)
                return d == 0 || d < r * r
            default: break
            }
        }
        for tpoly in set.triangulatedPolygons {
            for i in tpoly.triangles.indices {
                let (a, b, c) = tpoly.triangle(i)
                let tri = Shape.simple(LineChain([a, b, c], closed: true))
                for s in shapes {
                    var actual: Int?
                    if s.collide(tri, clearance: 0, wantActual: wantActual, actual: &actual) { return true }
                }
            }
        }
        return false
    }

    /// DRC_RTREE::QueryColliding of a zone's fill on a layer with a polygon set, as yes or no. For a set of one outline
    /// and no holes: whether a side of one of the fill's triangles touches the outline, or the outline's first point is
    /// in one, which is whether the fill and the outline touch or overlap; for any other, whether the set collides with
    /// one of the fill's triangles, triangle by triangle
    static func fillCollides(_ fill: [LineChain], _ set: PolySet) -> Bool {
        guard set.polygons.count == 1, set.polygons[0].count == 1 else {
            var f = PolySet(fill.map { [$0] })
            f.cacheTriangulation()
            for tpoly in f.triangulatedPolygons {
                for i in tpoly.triangles.indices {
                    let (a, b, c) = tpoly.triangle(i)
                    if polySetCollide(set, [.simple(LineChain([a, b, c], closed: true))], compound: true, wantActual: false) { return true }
                }
            }
            return false
        }
        guard let outline = set.polygons.first?[0], outline.pointCount > 0 else { return false }
        for f in fill {
            for i in 0..<f.segmentCount {
                var actual: Int?, location: IPoint?
                if outline.collide(f.segment(i), clearance: 0, wantActual: false, actual: &actual, location: &location) { return true }
            }
            if f.pointInside(outline.point(0)) { return true }
        }
        return false
    }

    /// LSET::FrontMask and BackMask: a side's copper and technical layers
    static let frontMask: Set<String> = ["F.Cu", "F.SilkS", "F.Mask", "F.Adhes", "F.Paste", "F.CrtYd", "F.Fab"]
    static let backMask: Set<String> = ["B.Cu", "B.SilkS", "B.Mask", "B.Adhes", "B.Paste", "B.CrtYd", "B.Fab"]

    /// FOOTPRINT::GetBoundingBox, but for its texts: its position and a quarter of a millimetre round it, its
    /// drawings and its pads
    func footprintBox(_ i: Int, _ fp: SExpr, _ c: Copper) -> IBox {
        let placement = BoardWorld.FootprintPlacement(fp)
        let pos = placement.position
        var box = IBox(minX: pos.x - 250_000, minY: pos.y - 250_000, maxX: pos.x + 250_000, maxY: pos.y + 250_000)
        let privateLayers = Set(fp["private_layers"]?.arguments.map(\.text) ?? [])
        let drawingHeads: Set<String> = ["fp_line", "fp_rect", "fp_arc", "fp_circle", "fp_poly", "fp_curve"]
        var drawn = false
        for node in fp.items where drawingHeads.contains(node.head ?? "") {
            drawn = true
            if let l = node.value("layer"), privateLayers.contains(l) { continue }
            guard let d = world.readDrawing(node, placement: placement), let shapes = world.effectiveShapes(d) else { continue }
            for s in shapes { box.merge(s.bbox) }
        }
        for pad in c.footprintPads[i] {
            drawn = true
            box.merge(pad.bbox)
            if let p = pad.pad { box.merge(p.pad.pos) }
        }
        for zone in fp.all("zone") {
            drawn = true
            for poly in BoardWorld.zoneOutline(zone).polygons { box.merge(poly[0].bbox) }
        }
        // its texts (GetBoundingBox( true )): its texts and fields shown, then its value and reference (the board
        // shows every layer); all of them where it has nothing else
        var references: [SExpr] = []
        for node in fp.items {
            let head = node.head ?? ""
            let field = head == "property" || (head == "fp_text" && node.text(at: 0) != "user")
            guard field || head == "fp_text" else { continue }
            // (a footprint's own text is one of its drawings)
            if !field { drawn = true }
            if field, ["Reference", "Value", "reference", "value"].contains(node.text(at: 0) ?? "") {
                references.append(node)
                continue
            }
            if let l = node.value("layer"), privateLayers.contains(l) { continue }
            guard let t = BoardWorld.textStrokes(node, footprint: fp), t.visible || !field else { continue }
            box.merge(t.boundingBox)
        }
        for node in references {
            guard let t = BoardWorld.textStrokes(node, footprint: fp), t.visible || !drawn else { continue }
            box.merge(t.boundingBox)
        }
        return box
    }

    // MARK: - The check (DRC_TEST_PROVIDER_DISALLOW)

    func checkKeepouts(_ out: inout Report, _ c: Copper) {
        let areas = keepouts()
        guard !areas.isEmpty else { return }
        let fps = board.root.all("footprint")
        let names = Dictionary(uniqueKeysWithValues: world.layerIndex.map { ($0.value, $0.key) })
        // (the board's layers, those its layer table names)
        let enabled = Set((board.root["layers"]?.items ?? []).compactMap { $0.text(at: 0) })
        var zoneNodes: [String: SExpr] = [:]
        for z in board.root.all("zone") + fps.flatMap({ $0.all("zone") }) { if let u = z.value("uuid") { zoneNodes[u] = z } }
        // (each area's own outline, cut into triangles when a track is first tried against it)
        var outlines: [Int: PolySet] = [:]
        func triangulated(_ i: Int) -> PolySet {
            if let o = outlines[i] { return o }
            var o = areas[i].outline
            o.cacheTriangulation()
            outlines[i] = o
            return o
        }

        /// An item's bounding box as KiCad's GetBoundingBox gives it: a via's out to its radius rounded up, and one more
        /// on its right and bottom ([pos, dim)); a pad's its shapes' and its hole's (a point where it has none); a
        /// zone's its outline's
        func itemBox(_ item: CopperItem) -> IBox? {
            switch item.kind {
            case .via:
                guard let v = item.via else { return nil }
                let r = (v.diameter + 1) / 2
                return IBox(minX: v.start.x - r, minY: v.start.y - r, maxX: v.start.x + r + 1, maxY: v.start.y + r + 1)
            case .pad:
                var b = item.bbox
                if !item.hasHole, let p = item.pad { b.merge(p.pad.pos) }
                return b
            case .zone:
                guard let node = zoneNodes[item.uuid] else { return nil }
                let outline = BoardWorld.zoneOutline(node)
                var box: IBox?
                for p in outline.polygons.first?[0].points ?? [] { if box == nil { box = IBox(p, p) } else { box!.merge(p) } }
                return box
            default:
                return item.bbox
            }
        }

        /// intersectsKeepout of an item: whether it collides with the area on a layer they share, their bounding
        /// boxes meeting
        func intersects(_ item: CopperItem, _ itemLayers: Set<String>, _ area: Keepout) -> Bool {
            let common = area.layers.intersection(itemLayers)
            guard !common.isEmpty else { return false }
            guard let a = area.box, let b = itemBox(item),
                  max(a.minX, b.minX) <= min(a.maxX, b.maxX) && max(a.minY, b.minY) <= min(a.maxY, b.maxY) else { return false }
            for layer in common {
                switch item.kind {
                case .zone:
                    // (a copper zone by its fill on the layer)
                    guard let l = world.layerIndex[layer], let fill = item.fills[l], !fill.isEmpty else { continue }
                    if Self.fillCollides(fill, area.deflated) { return true }
                case .via:
                    guard let l = world.layerIndex[layer], let shapes = item.shapes[l] else { continue }
                    if Self.polySetCollide(area.deflated, shapes, compound: false, wantActual: false) { return true }
                default:
                    // (a pad's shape on the layer, on a layer not of copper its outline)
                    let shapes = world.layerIndex[layer].flatMap { item.shapes[$0] } ?? item.outline
                    if Self.polySetCollide(area.deflated, shapes, compound: true, wantActual: false) { return true }
                }
            }
            return false
        }

        /// EvalRules( DISALLOW_CONSTRAINT ) of an item: the last keepout rule that keeps it out (one on a layer of the
        /// item's, the board's own, that it intersects)
        func disallowedBy(_ item: CopperItem, _ itemLayers: Set<String>, kept: (Keepout) -> Bool) -> Keepout? {
            var found: Keepout?
            for area in areas where kept(area) {
                guard !area.layers.isDisjoint(with: itemLayers), !area.layers.isDisjoint(with: enabled) else { continue }
                if intersects(item, itemLayers, area) { found = area }
            }
            return found
        }

        func check(_ item: CopperItem, _ itemLayers: Set<String>, kept: (Keepout) -> Bool) {
            guard !out.exceeded("items_not_allowed"), let area = disallowedBy(item, itemLayers, kept: kept) else { return }
            out.add("items_not_allowed", "(\(area.ruleName))", [item.uuid])
        }

        /// A copper zone, kept out as a zone (a teardrop as a track)
        func checkZone(_ z: CopperItem) {
            let teardrop = zoneNodes[z.uuid]?["attr"]?["teardrop"] != nil
            check(z, Set(z.layers.compactMap { names[$0] }), kept: { teardrop ? $0.tracks : $0.zones })
        }

        // the items in the order forEachGeometryItem gathers them: the tracks, arcs and vias, a track or an arc against
        // the areas keeping tracks out on its layer, each one it crosses (the implicit rules not asked again of it)
        for t in c.tracks {
            if t.kind == .via {
                // (a keepout's vias are only through vias: DRC_DISALLOW_VIAS is DRC_DISALLOW_THROUGH_VIAS, and a micro,
                // blind or buried via is asked of its own flag, which no keepout sets)
                if t.via?.viaType == .through { check(t, Set(t.layers.compactMap { names[$0] }), kept: \.vias) }
                continue
            }
            guard let l = t.layers.first, let layer = names[l] else { continue }
            let shapes = t.shapes[l] ?? []
            for i in areas.indices where areas[i].tracks && areas[i].layers.contains(layer) {
                guard !out.exceeded("items_not_allowed") else { break }
                if Self.polySetCollide(triangulated(i), shapes, compound: false, wantActual: true) {
                    out.add("items_not_allowed", nil, [t.uuid])
                }
            }
        }
        // the board's copper zones, then each footprint's pads and zones
        for z in c.zones where z.footprint == nil { checkZone(z) }
        for (i, fp) in fps.enumerated() {
            let padNodes = fp.all("pad")
            for (j, pad) in c.footprintPads[i].enumerated() { check(pad, layerSet(padNodes[j]), kept: \.pads) }
            for z in c.zones where z.footprint == i { checkZone(z) }
            checkFootprint(i, fp, c)
        }

        /// A footprint, by its courtyards: kept out by an area of another footprint's or the board's on its own copper
        /// layer (its layer set, F.Cu or B.Cu), whose deflated outline its front courtyard's first outline collides
        /// with where the area is on a front layer, or its back one's where it is on a back layer; not if either
        /// courtyard is malformed
        func checkFootprint(_ i: Int, _ fp: SExpr, _ c: Copper) {
            guard !out.exceeded("items_not_allowed"), areas.contains(where: { $0.footprints && $0.footprint != i }),
                  let uuid = fp.value("uuid") else { return }
            let side = fp.value("layer") ?? "F.Cu"
            let yards = courtyards(i)
            var itemLayers: Set<String> = [side]
            if !yards.front.polygons.isEmpty { itemLayers.formUnion(Self.frontMask) }
            if !yards.back.polygons.isEmpty { itemLayers.formUnion(Self.backMask) }
            let box = footprintBox(i, fp, c)
            var found: Keepout?
            for area in areas where area.footprints && area.footprint != i {
                guard !area.layers.isDisjoint(with: itemLayers), !area.layers.isDisjoint(with: enabled),
                      area.layers.contains(side), let a = area.box,
                      max(a.minX, box.minX) <= min(a.maxX, box.maxX) && max(a.minY, box.minY) <= min(a.maxY, box.maxY),
                      !yards.malformedFront && !yards.malformedBack else { continue }
                var hit = false
                for (yard, mask) in [(yards.front, Self.frontMask), (yards.back, Self.backMask)] where !area.layers.isDisjoint(with: mask) {
                    guard let outline = yard.polygons.first?[0] else { continue }
                    if Self.polySetCollide(area.deflated, [.chain(outline)], compound: true, wantActual: false) {
                        hit = true
                        break
                    }
                }
                if hit { found = area }
            }
            if let area = found { out.add("items_not_allowed", "(\(area.ruleName))", [uuid]) }
        }
    }
}

extension BoardDRC {
    /// Whether the keepout check goes by the rules engine (the user's disallow rules among the implicit keepout ones)
    /// even where the user has no disallow rules: for checking it against the check of the implicit ones alone
    nonisolated(unsafe) static var disallowByEngine = false

    /// DRC_TEST_PROVIDER_DISALLOW by the rules engine, as KiCad runs it with the user's disallow rules: each item
    /// forEachGeometryItem visits (a rule area with keepout settings left out), a track or an arc against each area
    /// keeping tracks out that it crosses, then EvalRules( DISALLOW_CONSTRAINT ) of the item (its implicit keepout
    /// rules not asked again of a track or an arc), and of its hole as a hole (HOLE_PROXY)
    func checkDisallowRules(_ out: inout Report, _ c: Copper, _ items: [BoardItem]) {
        let engine = ruleState.engine
        let areas = keepouts()
        let names = Dictionary(uniqueKeysWithValues: world.layerIndex.map { ($0.value, $0.key) })
        var outlines: [Int: PolySet] = [:]
        func triangulated(_ i: Int) -> PolySet {
            if let o = outlines[i] { return o }
            var o = areas[i].outline
            o.cacheTriangulation()
            outlines[i] = o
            return o
        }
        func test(_ item: RuleItem, _ b: BoardItem?) {
            guard !out.exceeded("items_not_allowed") else { return }
            if item.kind == .zone && item.isRuleArea && item.hasKeepoutParameters { return }
            item.holeProxy = false
            let isTrackOrArc = item.kind == .track || item.kind == .arc
            if isTrackOrArc, let cu = b?.copper ?? copperItem(item.uuid, c), let l = cu.layers.first, let layer = names[l] {
                let shapes = cu.shapes[l] ?? []
                for i in areas.indices where areas[i].tracks && areas[i].layers.contains(layer) {
                    guard !out.exceeded("items_not_allowed") else { break }
                    if Self.polySetCollide(triangulated(i), shapes, compound: false, wantActual: true) {
                        out.add("items_not_allowed", nil, [item.uuid])
                    }
                }
            }
            func report(_ k: DRCConstraint) {
                guard let rule = k.parentRule, !(isTrackOrArc && rule.isImplicit), !out.exceeded("items_not_allowed") else { return }
                out.add("items_not_allowed", "(\(k.ruleName))", [item.uuid], rule: rule)
            }
            let k = engine.evalRules(.disallow, item, nil, layer: KiLayer.undefined)
            if !k.disallowFlags.isEmpty && k.severity != .ignore { report(k) }
            if item.hasHole {
                item.holeProxy = true
                let h = engine.evalRules(.disallow, item, nil, layer: KiLayer.undefined)
                item.holeProxy = false
                if !h.disallowFlags.isEmpty && h.severity != .ignore { report(h) }
            }
        }
        // the items in forEachGeometryItem's order: the board's, then each footprint's and the footprint itself
        var byFootprint: [Int: [BoardItem]] = [:]
        for b in items {
            if let f = b.footprint { byFootprint[f, default: []].append(b) } else { test(ruleItem(b, c), b) }
        }
        for (f, fp) in ruleState.footprints.enumerated() {
            for b in byFootprint[f] ?? [] { test(ruleItem(b, c), b) }
            test(fp, nil)
        }
    }

    /// The copper item of a uuid (a track's, as the rules see it)
    func copperItem(_ uuid: String, _ c: Copper) -> CopperItem? {
        if ruleState.copperByUUID == nil {
            ruleState.copperByUUID = Dictionary(c.items.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        }
        return ruleState.copperByUUID?[uuid]
    }
}
