// Ported from KiCad 10.0.7: pcbnew/drc/drc_test_provider_silk_clearance.cpp (silkscreen against silkscreen and against
// the solder mask's openings: the silk items' R-tree and their targets', each pair of pieces QueryCollidingPairs
// meets, as far as the board's outline), pcbnew/drc/drc_rtree.h (Insert: an item's pieces on a layer and a pad's hole;
// QueryCollidingPairs), pcbnew/drc/drc_test_provider.cpp (forEachGeometryItem of every kind of item, isInvisibleText),
// pcbnew/drc/drc_engine.cpp (the implicit rule "board setup constraints silk", on the silk layers only),
// pcbnew/pad.cpp, pcbnew/pcb_track.cpp, pcbnew/pcb_shape.cpp, pcbnew/pcb_text.cpp, pcbnew/pcb_field.cpp and
// pcbnew/zone.cpp (the items' layers, their shapes on the silk and mask layers, their boxes and centres, a via's
// tenting) and common/eda_shape.cpp (getBoundingBox, computeArcBBox, getCenter).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

extension BoardDRC {
    /// A board item as the silkscreen checks take it (a BOARD_ITEM of any kind)
    final class BoardItem {
        enum Kind { case track, arc, via, pad, shape, text, field, zone }
        let kind: Kind
        let uuid: String
        /// The footprint it is of (its index), nil for the board's own
        var footprint: Int?
        /// GetLayerSet, by the layers' names
        var layers: Set<String> = []
        /// GetEffectiveShape on a silk layer or on none (the pieces of a compound)
        var shapes: [Shape] = []
        /// GetEffectiveShape on a mask layer (a track's grown by its mask expansion)
        var maskShapes: [Shape] = []
        /// A zone's fill on each of its layers, cut into triangles
        var fills: [String: [Shape]] = [:]
        var hole: Shape?
        /// IsTented, on the front and on the back (only a via's may be)
        var tented: (front: Bool, back: Bool) = (false, false)
        /// GetBoundingBox and GetCenter
        var bbox = IBox(minX: 0, minY: 0, maxX: 0, maxY: 0)
        var center = IPoint.zero
        /// A field's visibility (PCB_FIELD::IsVisible)
        var visible = true
        var ruleArea = false
        /// Its effective shape a SHAPE_COMPOUND (a drawing's, a text's, a pad's), not one shape
        var compound = true
        /// A pad's properties the edge check skips it for
        var castellated = false, connector = false
        /// Its copper item, where the copper checks have one
        var copper: CopperItem?
        /// Where it is read from, and for a drawing its footprint's placement, its line's width and fill as KiCad
        /// reads them; a text's strokes; a zone's fill on each of its layers
        var node: SExpr?
        var placement: BoardWorld.FootprintPlacement?
        var lineWidth = 0, filled = false
        /// A track's or via's solder mask expansion (GetSolderMaskExpansion)
        var maskExpansion = 0
        var strokes: TextStrokes?
        var fillChains: [String: [LineChain]] = [:]

        init(kind: Kind, uuid: String) { (self.kind, self.uuid) = (kind, uuid) }

        func isOnLayer(_ l: String) -> Bool { layers.contains(l) }

        /// GetEffectiveShape on `layer`
        func shapes(on layer: String) -> [Shape] {
            if kind == .zone { return fills[layer] ?? [] }
            return layer.hasSuffix(".Mask") ? maskShapes : shapes
        }

        /// isInvisibleText
        var invisibleText: Bool { kind == .field && !visible }
    }

    /// KiCad's number of a layer (PCB_LAYER_ID), by its name: the order LSET runs over layers in
    static func layerID(_ name: String) -> Int? {
        let fixed: [String: Int] = ["F.Cu": 0, "B.Cu": 2, "F.Mask": 1, "B.Mask": 3, "F.SilkS": 5, "B.SilkS": 7, "F.Adhes": 9,
                                    "B.Adhes": 11, "F.Paste": 13, "B.Paste": 15, "Dwgs.User": 17, "Cmts.User": 19,
                                    "Eco1.User": 21, "Eco2.User": 23, "Edge.Cuts": 25, "Margin": 27, "B.CrtYd": 29,
                                    "F.CrtYd": 31, "B.Fab": 33, "F.Fab": 35, "Rescue": 37]
        if let id = fixed[name] { return id }
        if name.hasPrefix("In"), name.hasSuffix(".Cu"), let n = Int(name.dropFirst(2).dropLast(3)) { return 2 + 2 * n }
        if name.hasPrefix("User."), let n = Int(name.dropFirst(5)) { return 37 + 2 * n }
        return nil
    }

    // MARK: - The items (forEachGeometryItem of s_allBasicItems)

    /// The board's items in the order forEachGeometryItem visits them: tracks, arcs and vias, the board's drawings and
    /// texts, its zones, then each footprint's fields, pads, drawings and texts, and zones (dimensions, text boxes,
    /// tables and the like not made)
    func boardItems(_ c: Copper) -> [BoardItem] {
        var out: [BoardItem] = []
        let setup = board.root["setup"]
        let boardMargin = setup?["pad_to_mask_clearance"].map { BoardWorld.iu($0, 0) } ?? 0
        let tenting = Self.frontBack(setup?["tenting"])
        let byUUID = Dictionary(c.items.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        let drawingHeads: Set<String> = ["line", "rect", "arc", "circle", "poly", "curve"]
        for node in board.root.items {
            switch node.head ?? "" {
            case "segment", "arc":
                if let item = silkTrack(node, boardMargin: boardMargin) { out.append(item) }
            case "via":
                guard let uuid = node.value("uuid"), let cu = byUUID[uuid], let v = cu.via else { continue }
                let item = BoardItem(kind: .via, uuid: uuid)
                item.copper = cu
                let names = Dictionary(uniqueKeysWithValues: world.layerIndex.map { ($0.value, $0.key) })
                item.layers = Set(cu.layers.compactMap { names[$0] })
                let tent = Self.frontBack(node["tenting"])
                item.tented = (tent.front ?? tenting.front ?? false, tent.back ?? tenting.back ?? false)
                if !item.tented.front && v.layers.start == 0 { item.layers.insert("F.Mask") }
                if !item.tented.back && v.layers.end == world.copperLayers - 1 { item.layers.insert("B.Mask") }
                item.maskShapes = [.circle(center: v.start, radius: v.diameter / 2)]
                item.shapes = item.maskShapes
                item.hole = cu.hole
                item.compound = false
                (item.node, item.maskExpansion) = (node, boardMargin)
                let r = (v.diameter + 1) / 2
                item.bbox = IBox(minX: v.start.x - r, minY: v.start.y - r, maxX: v.start.x + r + 1, maxY: v.start.y + r + 1)
                item.center = item.bbox.center
                out.append(item)
            default:
                break
            }
        }
        for node in board.root.items {
            let head = node.head ?? ""
            if head == "gr_text" {
                if let item = silkText(node, footprint: nil, index: nil, kind: .text) { out.append(item) }
            } else if head.hasPrefix("gr_"), drawingHeads.contains(String(head.dropFirst(3))) {
                if let item = silkDrawing(node, placement: nil, footprint: nil) { out.append(item) }
            }
        }
        for node in board.root.all("zone") { if let item = silkZone(node, footprint: nil) { out.append(item) } }
        for (i, fp) in board.root.all("footprint").enumerated() {
            let placement = BoardWorld.FootprintPlacement(fp)
            // its fields: the four every footprint has, then the user's, each as last read
            var fields: [(name: String, node: SExpr?)] = ["Reference", "Value", "Datasheet", "Description"].map { ($0, nil) }
            for node in fp.items {
                var name: String?
                if node.head == "property", let n = node.text(at: 0), n != "ki_fp_filters" && n != "Footprint" { name = n }
                if node.head == "fp_text", node.text(at: 0) == "reference" { name = "Reference" }
                if node.head == "fp_text", node.text(at: 0) == "value" { name = "Value" }
                guard let name else { continue }
                if let k = fields.firstIndex(where: { $0.name == name }) { fields[k].node = node } else { fields.append((name, node)) }
            }
            for f in fields {
                if let node = f.node, let item = silkText(node, footprint: fp, index: i, kind: .field) { out.append(item) }
            }
            for (j, node) in fp.all("pad").enumerated() {
                let cu = c.footprintPads[i][j]
                let item = BoardItem(kind: .pad, uuid: cu.uuid)
                item.footprint = i
                item.copper = cu
                item.layers = layerSet(node)
                item.shapes = cu.outline
                item.maskShapes = cu.outline
                item.hole = cu.hole
                item.bbox = cu.bbox
                item.center = cu.pad?.pad.pos ?? .zero
                item.castellated = cu.castellated
                item.node = node
                item.connector = cu.pad?.pad.attribute == .conn
                out.append(item)
            }
            for node in fp.items {
                let head = node.head ?? ""
                if head == "fp_text", node.text(at: 0) != "reference", node.text(at: 0) != "value" {
                    if let item = silkText(node, footprint: fp, index: i, kind: .text) { out.append(item) }
                } else if BoardWorld.footprintShapeHeads.contains(head) {
                    if let item = silkDrawing(node, placement: placement, footprint: i) { out.append(item) }
                }
            }
            for node in fp.all("zone") { if let item = silkZone(node, footprint: i) { out.append(item) } }
        }
        return out
    }

    /// A track or an arc, with its mask expansion on a mask layer (PCB_TRACK::GetSolderMaskExpansion: its own margin or
    /// the board's, no less than half its width taken off); nil off copper, as KiCad's parser drops it
    func silkTrack(_ node: SExpr, boardMargin: Int) -> BoardItem? {
        let names = node["layers"]?.arguments.map(\.text) ?? node.value("layer").map { [$0] } ?? []
        guard let cu = names.first, world.layerIndex[cu] != nil else { return nil }
        let isArc = node.head == "arc"
        let item = BoardItem(kind: isArc ? .arc : .track, uuid: node.value("uuid") ?? "")
        item.layers = [cu]
        if cu == "F.Cu" && names.contains("F.Mask") { item.layers.insert("F.Mask") }
        if cu == "B.Cu" && names.contains("B.Mask") { item.layers.insert("B.Mask") }
        let width = node["width"].map { BoardWorld.iu($0, 0) } ?? 0
        var margin = node["solder_mask_margin"].map { BoardWorld.iu($0, 0) } ?? boardMargin
        if margin < 0 { margin = max(margin, -width / 2) }
        let s = BoardWorld.point(node["start"]), e = BoardWorld.point(node["end"])
        func shape(_ w: Int) -> Shape {
            guard isArc else { return .segment(Seg(s, e), width: w) }
            let a = ShapeArc(start: s, mid: BoardWorld.point(node["mid"]), end: e, width: w)
            return a.isEffectiveLine ? .segment(Seg(s, e), width: w) : .arc(a)
        }
        item.shapes = [shape(width)]
        item.maskShapes = [shape(width + 2 * margin)]
        (item.node, item.lineWidth, item.maskExpansion) = (node, width, margin)
        item.compound = false
        // (PCB_TRACK::GetBoundingBox: its ends', or its arc's box, grown by half its width rounded up, one past the end)
        let r = (width + 1) / 2
        var box = isArc ? item.shapes[0].bbox : IBox(s, e)
        box = box.inflated(r)
        item.bbox = IBox(minX: box.minX, minY: box.minY, maxX: box.maxX + 1, maxY: box.maxY + 1)
        item.center = item.bbox.center
        return item
    }

    /// A drawing (PCB_SHAPE): its effective shapes as KiCad reads it (its width and fill defaults), its box and centre
    func silkDrawing(_ node: SExpr, placement: BoardWorld.FootprintPlacement?, footprint: Int?) -> BoardItem? {
        let names = node["layers"]?.arguments.map(\.text) ?? node.value("layer").map { [$0] } ?? []
        guard let layer = names.first, let o = world.outlineShape(node, placement: placement) else { return nil }
        let item = BoardItem(kind: .shape, uuid: node.value("uuid") ?? "")
        item.footprint = footprint
        item.layers = [layer]
        if layer == "F.Cu" && names.contains("F.Mask") { item.layers.insert("F.Mask") }
        if layer == "B.Cu" && names.contains("B.Mask") { item.layers.insert("B.Mask") }
        item.shapes = edgeEffectiveShapes(node, placement, o)
        item.maskShapes = item.shapes
        let filled: Bool
        if let fill = node["fill"] {
            let v = fill.text(at: 0) ?? fill["type"]?.text(at: 0)
            filled = v == "yes" || v == "solid" || v == "hatch" || v == "reverse_hatch" || v == "cross_hatch"
        } else {
            let kind = String((node.head ?? "").dropFirst(3))
            let raw = node["stroke"]?["width"].map { BoardWorld.iu($0, 0) } ?? node["width"].map { BoardWorld.iu($0, 0) } ?? 0
            filled = (raw == 0 && (kind == "rect" || kind == "circle")) || (kind == "poly" && layer != "Edge.Cuts")
        }
        (item.bbox, item.center) = Self.drawingBox(o, filled: filled, maxError: world.rules.maxError)
        (item.node, item.placement, item.lineWidth, item.filled) = (node, placement, o.width, filled)
        return item
    }

    /// EDA_SHAPE::getBoundingBox (its points' box grown by half its width) and getCenter
    static func drawingBox(_ o: OutlineShape, filled: Bool, maxError: Int) -> (IBox, IPoint) {
        var box: IBox
        switch o.kind {
        case .rect:
            box = IBox(o.start, o.end)
        case .segment:
            box = IBox(o.start, o.end)
        case .circle:
            box = IBox(o.start, o.start).inflated(o.radius)
        case .arc:
            // computeArcBBox: its ends, its centre if filled, and each axis' point of its circle it passes
            box = IBox(o.start, o.end)
            if filled { box.merge(o.center) }
            let radius = max(1, KiMath.round(o.center.distance(o.start)))
            var t1 = EDAAngle(DPoint(o.start - o.center)), t2 = EDAAngle(DPoint(o.end - o.center))
            if t2 == t1 { t2 = t1 + .a360 }
            while t2 < t1 { t2 += .a360 }
            t1 = t1.normalized
            t2 = t2.normalized
            let axes = [(EDAAngle.zero, IPoint(radius, 0)), (EDAAngle.a90, IPoint(0, radius)), (EDAAngle.a180, IPoint(-radius, 0)),
                        (EDAAngle.a270, IPoint(0, -radius))]
            for (a, d) in axes where t2 > t1 ? (t1 < a && t2 > a) : (t1 < a || t2 > a) { box.merge(o.center + d) }
        case .poly:
            box = IBox(points: o.points) ?? IBox(o.start, o.start)
        case .bezier:
            let pts = Outlines.bezierPoints(o.start, o.control1, o.control2, o.end, maxError: maxError)
            box = IBox(points: pts) ?? IBox(o.start, o.start)
        }
        box = box.inflated(max(0, o.width) / 2)
        let center: IPoint
        switch o.kind {
        case .arc: center = o.center
        case .circle: center = o.start
        case .segment: center = IPoint((o.start.x + o.end.x) / 2, (o.start.y + o.end.y) / 2)
        default: center = box.center
        }
        return (box, center)
    }

    /// A text or a field: its strokes (nil for one the port does not make, and for one with no layer)
    func silkText(_ node: SExpr, footprint fp: SExpr?, index: Int?, kind: BoardItem.Kind) -> BoardItem? {
        guard let layer = node.value("layer"), let t = BoardWorld.textStrokes(node, footprint: fp) else { return nil }
        let item = BoardItem(kind: kind, uuid: node.value("uuid") ?? "")
        item.footprint = index
        item.layers = [layer]
        item.shapes = t.shapes
        item.maskShapes = t.shapes
        item.visible = kind != .field || t.visible
        item.bbox = t.boundingBox
        item.center = t.boundingBox.center
        item.strokes = t
        return item
    }

    /// A zone: its fill on each layer, cut into triangles as a zone's fill is
    func silkZone(_ node: SExpr, footprint: Int?) -> BoardItem? {
        let item = BoardItem(kind: .zone, uuid: node.value("uuid") ?? "")
        item.footprint = footprint
        item.node = node
        item.layers = layerSet(node)
        item.ruleArea = node["keepout"] != nil
        item.compound = false
        var chains: [String: [LineChain]] = [:]
        for fill in node.all("filled_polygon") {
            guard let l = fill.value("layer") else { continue }
            let pts = (fill["pts"]?.arguments ?? []).filter { $0.head == "xy" }.map { BoardWorld.point($0) }
            guard pts.count >= 3 else { continue }
            chains[l, default: []].append(LineChain(pts, closed: true))
        }
        for (l, list) in chains {
            var set = PolySet(list.map { [$0] })
            set.cacheTriangulation(partition: true)
            var tris: [Shape] = []
            for tpoly in set.triangulatedPolygons {
                for k in tpoly.triangles.indices {
                    let (a, b, c) = tpoly.triangle(k)
                    tris.append(.simple(LineChain([a, b, c], closed: true)))
                }
            }
            item.fills[l] = tris
        }
        item.fillChains = chains
        let outline = BoardWorld.zoneOutline(node)
        var box: IBox?
        for poly in outline.polygons { for chain in poly { if box == nil { box = chain.bbox } else { box!.merge(chain.bbox) } } }
        item.bbox = box ?? item.bbox
        item.center = item.bbox.center
        return item
    }

    // MARK: - The check (DRC_TEST_PROVIDER_SILK_CLEARANCE)

    /// An entry of the silk items' R-tree or the targets' (ITEM_WITH_SHAPE)
    final class SilkEntry {
        let item: BoardItem
        let shape: Shape
        init(_ item: BoardItem, _ shape: Shape) { (self.item, self.shape) = (item, shape) }
    }

    /// The board's outline as the silkscreen checks collide with it: its polygons cut into triangles, and its box
    /// (BBoxFromCaches); nil where the board has none
    struct SilkOutline {
        var set: PolySet
        let box: KBox

        init?(_ outline: PolySet) {
            guard !outline.polygons.isEmpty, let box = BoardDRC.cachedBox(outline, width: 0) else { return nil }
            set = outline
            set.cacheTriangulation(partition: false)
            self.box = box
        }

        /// SHAPE::Collide of a shape with the outline, at no clearance
        func collides(_ s: Shape) -> Bool { BoardDRC.polySetCollide(set, [s], compound: false, wantActual: false) }
    }

    /// Whether KiCad tests no more of a check: its limit reached, or the check ignored (its limit set to none)
    func silkLimitReached(_ out: Report, _ type: String) -> Bool { settings.severity(type) == "ignore" || out.exceeded(type) }

    func checkSilkClearances(_ out: inout Report, _ items: [BoardItem], _ outline: SilkOutline?) {
        let overlap = "silk_overlap", overCopper = "silk_over_copper"
        // (a minimum web width has the solder mask check test silkscreen against the whole mask instead)
        let webWidth = board.root["setup"]?["solder_mask_min_width"].map { BoardWorld.iu($0, 0) } ?? 0
        let checkIndividualMaskItems = webWidth <= 0
        guard !(silkLimitReached(out, overlap) && silkLimitReached(out, overCopper)) else { return }
        let engine = ruleState.engine, copper = ruleState.copper(self)
        let largest = engine.worstConstraint(.silkClearance)?.value.min ?? 0
        // the silk items' R-trees and the targets' (rule areas left out; a hidden field put in neither), the targets'
        // only of the layers a pair can be found on (no rule gives silkscreen a clearance to the others)
        let silkLayers = ["F.SilkS", "B.SilkS"]
        var silkTrees: [String: RTree<SilkEntry, Double>] = [:], targetTrees: [String: RTree<SilkEntry, Double>] = [:]
        func insert(_ item: BoardItem, _ layer: String, _ trees: inout [String: RTree<SilkEntry, Double>]) {
            if item.invisibleText { return }
            let tree = trees[layer] ?? RTree<SilkEntry, Double>()
            trees[layer] = tree
            for s in item.shapes(on: layer) { tree.insert(s.bbox, SilkEntry(item, s)) }
            if item.kind == .pad, let h = item.hole { tree.insert(h.bbox, SilkEntry(item, h)) }
        }
        for item in items where !item.ruleArea && !item.layers.isDisjoint(with: silkLayers) {
            for l in silkLayers where item.isOnLayer(l) { insert(item, l, &silkTrees) }
        }
        let frontBack = Self.frontMask.union(Self.backMask).union(["Edge.Cuts", "Margin"])
        for item in items where !item.ruleArea && (item.kind == .pad && item.hole != nil || !item.layers.isDisjoint(with: frontBack)) {
            // (LSET order: F.Mask, B.Mask, F.SilkS, B.SilkS)
            for l in ["F.Mask", "B.Mask", "F.SilkS", "B.SilkS"] where item.isOnLayer(l) { insert(item, l, &targetTrees) }
        }
        // QueryCollidingPairs: each layer pair's silk pieces in the tree's order, each against the targets near it
        let all = IBox(minX: Int(Int32.min), minY: Int(Int32.min), maxX: Int(Int32.max), maxY: Int(Int32.max))
        var pairs: [(ref: SilkEntry, test: SilkEntry, refLayer: String, target: String)] = []
        for (refLayer, target) in [("F.SilkS", "F.SilkS"), ("F.SilkS", "F.Mask"), ("B.SilkS", "B.SilkS"), ("B.SilkS", "B.Mask")] {
            guard let silk = silkTrees[refLayer], let targets = targetTrees[target] else { continue }
            silk.search(all) { ref in
                targets.search(ref.shape.bbox.inflated(largest)) { test in
                    if test.item !== ref.item { pairs.append((ref, test, refLayer, target)) }
                    return true
                }
                return true
            }
        }
        struct PairKey: Hashable { let a: ObjectIdentifier, b: ObjectIdentifier }
        var colliding = Set<PairKey>()
        var outlineHits: [ObjectIdentifier: Bool] = [:]
        for p in pairs {
            if silkLimitReached(out, overlap) && silkLimitReached(out, overCopper) { break }
            let ia = ObjectIdentifier(p.ref.item), ib = ObjectIdentifier(p.test.item)
            let key = ia < ib ? PairKey(a: ia, b: ib) : PairKey(a: ib, b: ia)
            if colliding.contains(key) { continue }
            var refItem = p.ref.item, testItem = p.test.item
            var refShape = p.ref.shape, testShape = p.test.shape
            if refItem.invisibleText || testItem.invisibleText { continue }
            var holeShape = false
            if p.refLayer.hasPrefix("F.") ? testItem.tented.front : testItem.tented.back {
                guard let h = testItem.hole else { continue }
                testShape = h
                holeShape = true
            }
            if let outline {
                guard outline.box.intersects(KBox(testItem.bbox)) else { continue }
                let hit: Bool
                if holeShape {
                    hit = outline.collides(testShape)
                } else {
                    let id = ObjectIdentifier(p.test)
                    if let h = outlineHits[id] { hit = h } else { hit = outline.collides(testShape); outlineHits[id] = hit }
                }
                guard hit else { continue }
            }
            let mask = p.target.hasSuffix(".Mask")
            // (the implicit silk rule is of the silk layers only: on a mask layer none, unless each mask item is tested)
            let constraint = engine.evalRules(.silkClearance, ruleItem(refItem, copper), ruleItem(testItem, copper),
                                              layer: KiLayer.id(p.target) ?? KiLayer.undefined)
            var minClearance = -1
            if constraint.type != .null && constraint.severity != .ignore { minClearance = constraint.value.min }
            if mask && checkIndividualMaskItems { minClearance = max(minClearance, 0) }
            let type = mask ? overCopper : overlap
            if minClearance < 0 || silkLimitReached(out, type) { continue }
            // (drawings of one footprint, or both the board's, are often one drawing in pieces)
            if refItem.kind == .shape && testItem.kind == .shape && refItem.footprint == testItem.footprint { continue }
            if p.refLayer == p.target && refItem.uuid > testItem.uuid {
                swap(&refItem, &testItem)
                swap(&refShape, &testShape)
            }
            var actual: Int?, location: IPoint?
            guard refShape.collide(testShape, clearance: minClearance, actual: &actual, location: &location) else { continue }
            let detail = minClearance > 0 ? Self.formatMsg({ "(\($0) clearance \($1); actual \($2))" }, constraint.ruleName,
                                                           minClearance, actual ?? 0) : nil
            out.add(type, detail, [refItem.uuid, testItem.uuid], rule: constraint.parentRule)
            colliding.insert(key)
        }
    }
}
