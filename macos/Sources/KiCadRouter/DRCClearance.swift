// Ported from KiCad 10.0.7: pcbnew/drc/drc_test_provider_copper_clearance.cpp (tracks, vias, pads and drawings against
// what is near them and against zones' fills), pcbnew/drc/drc_cache_generator.cpp and drc_rtree.h (the copper items'
// R-tree, each layer's, and how a search of it goes), pcbnew/drc/drc_engine.cpp (EvalRules for clearances and hole
// clearances on the implicit rules), pcbnew/drc/drc_test_provider.cpp (forEachGeometryItem: the order items are
// gathered in), pcbnew/pad.cpp (GetEffectiveShape, buildEffectiveShape for custom pads, GetClearanceOverrides),
// pcbnew/pcb_track.cpp (tracks', arcs' and vias' effective shapes), pcbnew/zone.cpp (GetLocalClearance) and
// pcbnew/footprint.cpp (MapPadNumbersToNetTieGroups, BuildNetTieCache: net ties).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

extension BoardDRC {
    /// A copper item as the clearance checks see it: a track, arc, via, pad, drawing or zone (BOARD_ITEM), with its
    /// shape on each of its copper layers
    final class CopperItem {
        enum Kind { case track, arc, via, pad, shape, zone }
        let kind: Kind
        let uuid: String
        /// Its net's code and name (0 and "" for none)
        var net = 0
        var netName = ""
        /// Which net object it holds (its NETINFO_ITEM): its net's, or for an item of no net the board's own net 0
        /// (a pad's, a zone's, or one read with a net clause naming none) or the orphaned item's that no board holds
        /// (-1: a track, via or drawing read without one)
        var netIdentity = 0
        /// BOARD_ITEM::IsConnected: all but a footprint's drawings (only the board's own copper drawings are)
        var connected = true
        /// The footprint it is of (its index), nil for the board's own
        var footprint: Int?
        /// The copper layers it is on (router layers), in KiCad's order of them (F.Cu, B.Cu, then the inner ones)
        var layers: [Int] = []
        /// Its shape on each layer (GetEffectiveShape: the pieces of a compound)
        var shapes: [Int: [Shape]] = [:]
        /// Its shape on a layer as the R-tree holds it (a pad's hole too, as DRC_RTREE::Insert adds it)
        var indexed: [Int: [Shape]] = [:]
        var hole: Shape?
        /// BOARD_ITEM::IsOnCopperLayer (an unplated hole with no copper round it is not)
        var copper = true
        /// A pad's or via's PAD::FlashLayer / PCB_VIA::FlashLayer, by layer
        var flashed: Set<Int> = []
        var pad: Pad?
        var via: Track?
        /// BOARD_CONNECTED_ITEM::GetClearanceOverrides: a pad's own clearance or its footprint's, and its source
        var clearanceOverride: (value: Int, source: String)?
        /// A zone's own clearance (ZONE::GetLocalClearance)
        var localClearance: (value: Int, source: String)?
        /// A zone's outline (ZONE::Outline), its priority, and whether it is a teardrop
        var zoneOutline = PolySet()
        var zonePriority = 0
        var teardrop = false
        /// A zone's fill on each layer, its fractured outlines
        var fills: [Int: [LineChain]] = [:]
        var zoneBox: IBox?
        var bbox = IBox(minX: 0, minY: 0, maxX: 0, maxY: 0)
        /// A pad's shape on a layer it is not on (PAD::GetEffectiveShape asked of any layer: its outline)
        var outline: [Shape] = []
        /// A castellated pad (PAD_PROP::CASTELLATED)
        var castellated = false
        /// A track's or arc's ends and width
        var trackStart = IPoint.zero, trackEnd = IPoint.zero, trackWidth = 0
        /// An arc's middle as read
        var trackMid = IPoint.zero
        /// A drawing's connection points (PCB_SHAPE::GetConnectionPoints)
        var connectionPoints: [IPoint] = []

        init(kind: Kind, uuid: String) { (self.kind, self.uuid) = (kind, uuid) }

        func anyLayerShapes(_ layer: Int) -> [Shape] { shapes[layer] ?? outline }

        var hasHole: Bool { hole != nil }
        /// Its net's code as the checks compare it (an item not connected has none)
        var netCode: Int { connected ? net : 0 }
    }

    /// An entry of the copper items' R-tree: an item and one of its pieces (ITEM_WITH_SHAPE)
    final class TreeEntry {
        let item: CopperItem
        let shape: Shape
        init(_ item: CopperItem, _ shape: Shape) { (self.item, self.shape) = (item, shape) }
    }

    /// The board's copper items, its copper zones, the R-tree of each copper layer, and the worst clearance the
    /// search for what is near goes out to
    struct Copper {
        var items: [CopperItem] = []
        var tracks: [CopperItem] = []
        var zones: [CopperItem] = []
        var footprintPads: [[CopperItem]] = []
        var drawings: [CopperItem] = []
        var footprintDrawings: [[CopperItem]] = []
        var trees: [Int: RTree<TreeEntry, Double>] = [:]
        var maxClearance = 0
        /// Each footprint's net tie groups: its pads' numbers' groups (MapPadNumbersToNetTieGroups, -1 for none),
        /// empty for a footprint that is no net tie
        var netTieGroups: [[String: Int]] = []
        /// The nets each of a net tie footprint's pads and copper drawings ties (BuildNetTieCache)
        var netTies: [ObjectIdentifier: Set<Int>] = [:]

        func isNetTie(_ footprint: Int?) -> Bool { footprint.map { !netTieGroups[$0].isEmpty } ?? false }

        func netTieGroup(_ pad: CopperItem) -> Int {
            guard let f = pad.footprint, let number = pad.pad?.number else { return -1 }
            return netTieGroups[f][number] ?? -1
        }
    }

    /// FOOTPRINT::MapPadNumbersToNetTieGroups: each pad number's group in the footprint's net tie pad groups
    /// (numbers separated by commas, a backslash escaping the character after it)
    static func netTieGroups(_ fp: SExpr, _ pads: [Pad]) -> [String: Int] {
        let groups = fp["net_tie_pad_groups"]?.arguments.map(\.text) ?? []
        guard groups.contains(where: { !$0.isEmpty }) else { return [:] }
        var map: [String: Int] = [:]
        for p in pads { map[p.number] = -1 }
        for (i, group) in groups.enumerated() {
            var esc = false
            var pad = ""
            func process() {
                let n = pad.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { map[n] = i }
            }
            for ch in group {
                if esc {
                    esc = false
                    pad.append(ch)
                    continue
                }
                switch ch {
                case "\\": esc = true
                case ",":
                    process()
                    pad = ""
                default: pad.append(ch)
                }
            }
            process()
        }
        return map
    }

    // MARK: - The copper items

    /// The board's layers in KiCad's numbering order (F.Cu 0, B.Cu 2, In1.Cu 4...): the order LSET runs over them
    var kicadLayerOrder: [Int] {
        let n = world.copperLayers
        return [0, n - 1] + (n > 2 ? Array(1..<(n - 1)) : [])
    }

    func makeCopper() -> Copper {
        var c = Copper()
        c.maxClearance = min(world.rules.maxClearance ?? 0, Int(Int32.max) / 3)
        let order = kicadLayerOrder
        func ordered(_ ls: [Int]) -> [Int] { order.filter { ls.contains($0) } }
        let netCodes = world.netCodes
        // tracks, arcs and vias
        for t in tracks {
            let item = CopperItem(kind: t.kind == .track ? .track : t.kind == .arc ? .arc : .via, uuid: t.uuid)
            item.net = netCodes[t.net] ?? 0
            item.netName = t.net
            item.netIdentity = t.hasNet ? item.net : -1
            switch t.kind {
            case .track, .arc:
                guard let l = world.layerIndex[t.layer] else { continue }
                item.layers = [l]
                (item.trackStart, item.trackEnd, item.trackWidth, item.trackMid) = (t.start, t.end, t.width, t.mid)
                let s: Shape
                if t.kind == .arc {
                    let a = ShapeArc(start: t.start, mid: t.mid, end: t.end, width: t.width)
                    s = a.isEffectiveLine ? .segment(Seg(t.start, t.end), width: t.width) : .arc(a)
                } else {
                    s = .segment(Seg(t.start, t.end), width: t.width)
                }
                item.shapes[l] = [s]
                item.bbox = s.bbox
            case .via:
                item.via = t
                item.layers = ordered(Array(t.layers.start...t.layers.end))
                item.flashed = Set(item.layers)
                // (PCB_VIA::GetEffectiveHoleShape: a segment of no length, the drill wide)
                item.hole = .segment(Seg(t.start, t.start), width: t.drill)
                for l in item.layers { item.shapes[l] = [.circle(center: t.start, radius: t.diameter / 2)] }
                item.bbox = Shape.circle(center: t.start, radius: t.diameter / 2).bbox
            }
            item.indexed = item.shapes
            c.items.append(item)
            c.tracks.append(item)
        }
        // the board's drawings on copper
        for node in board.root.items where ["gr_line", "gr_rect", "gr_arc", "gr_circle", "gr_poly", "gr_curve"].contains(node.head ?? "") {
            if let item = drawingItem(node, placement: nil, footprint: nil) {
                c.items.append(item)
                c.drawings.append(item)
            }
        }
        // the copper zones (not rule areas), the board's and then the footprints'
        for zone in board.root.all("zone") { if let z = zoneItem(zone, footprint: nil) { c.zones.append(z) } }
        let fps = board.root.all("footprint")
        for (i, fp) in fps.enumerated() { for zone in fp.all("zone") { if let z = zoneItem(zone, footprint: i) { c.zones.append(z) } } }
        // the footprints' pads and drawings
        for (i, fp) in fps.enumerated() {
            let placement = BoardWorld.FootprintPlacement(fp)
            var pads: [CopperItem] = []
            for (j, node) in fp.all("pad").enumerated() {
                let p = footprints[i].pads[j]
                let item = padItem(p, node, fp, footprint: i)
                pads.append(item)
                c.items.append(item)
            }
            c.footprintPads.append(pads)
            var drawings: [CopperItem] = []
            for node in fp.items where ["fp_line", "fp_rect", "fp_arc", "fp_circle", "fp_poly", "fp_curve"].contains(node.head ?? "") {
                if let item = drawingItem(node, placement: placement, footprint: i) {
                    drawings.append(item)
                    c.items.append(item)
                }
            }
            c.footprintDrawings.append(drawings)
            // its net ties: pads of a group tie the group's nets, and its copper drawings touching them those nets
            let groups = Self.netTieGroups(fp, footprints[i].pads)
            c.netTieGroups.append(groups)
            if !groups.isEmpty {
                for (ii, pad) in pads.enumerated() {
                    guard let g = groups[pad.pad?.number ?? ""], g >= 0 else { continue }
                    var tied = false
                    for (jj, other) in pads.enumerated() where jj != ii {
                        guard let g2 = groups[other.pad?.number ?? ""], g2 >= 0, g2 == g else { continue }
                        c.netTies[ObjectIdentifier(pad), default: []].formUnion([pad.net, other.net])
                        c.netTies[ObjectIdentifier(other), default: []].formUnion([other.net, pad.net])
                        tied = true
                    }
                    guard tied else { continue }
                    for layer in kicadLayerOrder {
                        let padShape = pad.anyLayerShapes(layer)
                        for d in drawings where d.layers.contains(layer) {
                            if Self.collide(padShape, d.shapes[layer] ?? [], 0) != nil {
                                c.netTies[ObjectIdentifier(d), default: []].formUnion(c.netTies[ObjectIdentifier(pad)] ?? [])
                            }
                        }
                    }
                }
            }
        }
        // the R-trees, in the order forEachGeometryItem gathers the items: tracks, the board's drawings, then each
        // footprint's pads and drawings
        var gathered = c.tracks + c.drawings
        for i in fps.indices { gathered += c.footprintPads[i] + c.footprintDrawings[i] }
        for item in gathered {
            // (a pad with a hole is on every copper layer)
            let ls = item.kind == .pad && item.hasHole ? order : item.layers
            for l in ls {
                let tree = c.trees[l] ?? RTree<TreeEntry, Double>()
                c.trees[l] = tree
                for s in item.indexed[l] ?? [] { tree.insert(s.bbox.inflated(c.maxClearance), TreeEntry(item, s)) }
            }
        }
        return c
    }

    func padItem(_ p: Pad, _ node: SExpr, _ fp: SExpr, footprint: Int) -> CopperItem {
        let item = CopperItem(kind: .pad, uuid: p.uuid)
        item.pad = p
        item.footprint = footprint
        item.net = world.netCodes[p.net] ?? 0
        item.netName = p.net
        item.netIdentity = item.net
        let lmsk = world.copper(p.pad.layers)
        switch p.pad.attribute {
        case .pth, .npth: item.layers = kicadLayerOrder.filter { lmsk.contains($0) }
        case .smd, .conn: item.layers = lmsk.first.map { [$0] } ?? []
        }
        item.copper = world.isOnCopper(p.pad, lmsk)
        item.castellated = node["property"]?.arguments.contains { $0.text == "pad_prop_castellated" } == true
        item.flashed = Set(item.layers.filter { world.flash(p.pad, lmsk, $0) })
        if p.hasHole { item.hole = world.holeShape(p.pad) }
        if let o = world.clearanceOverride(node, fp) {
            item.clearanceOverride = (o, node["clearance"] != nil ? "pad" : "footprint \(BoardWorld.FootprintPlacement(fp).reference)")
        }
        var flashedShapes = world.effectiveShapes(p.pad)
        if p.pad.kind == .custom {
            // (the anchor, and each piece's shapes turned and moved with the pad)
            for prim in p.primitives {
                guard let d = world.readDrawing(prim, placement: nil), let shapes = world.effectiveShapes(d) else { continue }
                flashedShapes += shapes.map { Self.transformed($0, p.pad.orientation, p.pad.shapePos) }
            }
        }
        item.outline = flashedShapes
        let layersWithShapes = p.hasHole ? kicadLayerOrder : item.layers
        for l in layersWithShapes {
            // (a plated pad where it is not flashed: its hole)
            let shapes = p.pad.attribute == .pth && !item.flashed.contains(l) ? item.hole.map { [$0] } ?? [] : flashedShapes
            item.shapes[l] = shapes
            item.indexed[l] = shapes + (item.hole.map { [$0] } ?? [])
        }
        var box = flashedShapes.first?.bbox ?? IBox(p.pad.pos, p.pad.pos)
        for s in flashedShapes.dropFirst() { box.merge(s.bbox) }
        if let h = item.hole { box.merge(h.bbox) }
        item.bbox = box
        return item
    }

    func drawingItem(_ node: SExpr, placement: BoardWorld.FootprintPlacement?, footprint: Int?) -> CopperItem? {
        guard let layerName = node.value("layer"), let l = world.layerIndex[layerName] else { return nil }
        guard let d = world.readDrawing(node, placement: placement), let shapes = world.effectiveShapes(d), !shapes.isEmpty else { return nil }
        let item = CopperItem(kind: .shape, uuid: node.value("uuid") ?? "")
        item.footprint = footprint
        item.connectionPoints = Self.connectionPoints(d)
        let name = Self.netName(node)
        item.net = world.netCodes[name] ?? 0
        item.netName = name
        item.netIdentity = node["net"] != nil ? item.net : -1
        if footprint != nil {
            // (a footprint's drawing is not connected: no net of its own)
            item.connected = false
            item.net = 0
            item.netName = ""
            item.netIdentity = Int.min
        }
        item.layers = [l]
        item.shapes[l] = shapes
        item.indexed = item.shapes
        var box = shapes[0].bbox
        for s in shapes.dropFirst() { box.merge(s.bbox) }
        item.bbox = box
        return item
    }

    /// A copper zone (not a rule area) with its fills; nil for a rule area or one on no copper layer
    func zoneItem(_ node: SExpr, footprint: Int?) -> CopperItem? {
        if node["keepout"] != nil { return nil }
        let names = node["layers"]?.arguments.map(\.text) ?? node.value("layer").map { [$0] } ?? []
        let ls = world.copper(names)
        guard !ls.isEmpty else { return nil }
        let item = CopperItem(kind: .zone, uuid: node.value("uuid") ?? "")
        item.footprint = footprint
        let name = Self.netName(node)
        item.net = world.netCodes[name] ?? 0
        item.netName = name
        item.netIdentity = item.net
        item.layers = kicadLayerOrder.filter { ls.contains($0) }
        let clearance = node["connect_pads"]?["clearance"].map { BoardWorld.iu($0, 0) } ?? 0
        item.localClearance = (clearance, "zone")
        for fill in node.all("filled_polygon") {
            guard let l = fill.value("layer").flatMap({ world.layerIndex[$0] }) else { continue }
            let pts = (fill["pts"]?.arguments ?? []).filter { $0.head == "xy" }.map { BoardWorld.point($0) }
            guard pts.count >= 3 else { continue }
            item.fills[l, default: []].append(LineChain(pts, closed: true))
        }
        var box: IBox?
        for poly in node.all("polygon") {
            for q in (poly["pts"]?.arguments ?? []) where q.head == "xy" {
                let p = BoardWorld.point(q)
                if box == nil { box = IBox(p, p) } else { box!.merge(p) }
            }
        }
        item.zoneBox = box
        item.zoneOutline = BoardWorld.zoneOutline(node)
        item.zonePriority = node.value("priority").flatMap(Int.init) ?? 0
        item.teardrop = node["attr"]?["teardrop"] != nil
        return item
    }

    /// A shape turned about the origin and moved (SHAPE::Rotate and Move, as a custom pad's pieces are)
    static func transformed(_ s: Shape, _ angle: EDAAngle, _ d: IPoint) -> Shape {
        func t(_ p: IPoint) -> IPoint { KiMath.rotate(p, angle) + d }
        switch s {
        case .circle(let c, let r): return .circle(center: t(c), radius: r)
        case .segment(let g, let w): return .segment(Seg(t(g.a), t(g.b)), width: w)
        // (SHAPE_SIMPLE::Rotate and Move: its arcs turned and moved too)
        case .simple(let c): return .simple(c.rotated(angle).moved(d))
        case .chain(let c): return .chain(c.rotated(angle).moved(d))
        case .arc(let a):
            // (SHAPE_ARC::Rotate and Move: its three points turned and moved, its centre found again from them)
            return .arc(ShapeArc(start: t(a.start), mid: t(a.mid), end: t(a.end), width: a.width))
        case .rect(let b): return .simple(LineChain([IPoint(b.minX, b.minY), IPoint(b.maxX, b.minY), IPoint(b.maxX, b.maxY),
                                                     IPoint(b.minX, b.maxY)].map(t), closed: true))
        }
    }

    // MARK: - Rules (EvalRules on the implicit rules)

    /// An effective net class's clearance rule: the class's name, its clearance, and the name of the class it comes
    /// from (NETCLASS::GetClearanceParent); `named` false where KiCad takes its fast way to net classes' clearances,
    /// which gives the clearance no rule's name
    struct ClearanceRule {
        var netClass: String
        var clearance: Int
        var parent: String
        var named = true
    }

    /// The net classes' clearance rules as KiCad orders them (the default class, the classes by name, then the
    /// composite ones by name, sorted by clearance, least first: the last that applies wins)
    func clearanceRules(_ items: [CopperItem]) -> [ClearanceRule] {
        var rules = [ClearanceRule(netClass: "Default", clearance: netClasses.defaultClass.clearance ?? 0, parent: "Default")]
        for name in netClasses.classes.keys.sorted() {
            if let c = netClasses.classes[name]?.clearance { rules.append(ClearanceRule(netClass: name, clearance: c, parent: name)) }
        }
        var composites: [String: ClearanceRule] = [:]
        for item in items {
            let e = netClasses.effective(item.netName)
            if e.name.contains(",") && composites[e.name] == nil {
                composites[e.name] = ClearanceRule(netClass: e.name, clearance: e.clearance ?? 0, parent: e.clearanceParent ?? "Default")
            }
        }
        for name in composites.keys.sorted() { rules.append(composites[name]!) }
        // EvalRules' fast way (no rules of the user's own): unless a class's diff pair gap is less than its clearance,
        // which makes a rule of its own for coupled pairs
        var diffPairOverrides = netClasses.defaultClass.diffPairGap.map { $0 < netClasses.defaultClass.clearance ?? -1 } ?? false
        for c in netClasses.classes.values where c.diffPairGap.map({ $0 < c.clearance ?? -1 }) ?? false { diffPairOverrides = true }
        for item in items where !diffPairOverrides {
            let e = netClasses.effective(item.netName)
            if e.name.contains(","), let gap = e.diffPairGap, gap < e.clearance ?? -1 { diffPairOverrides = true }
        }
        if !diffPairOverrides { for i in rules.indices { rules[i].named = false } }
        // (few enough for std::sort's insertion sort: ties keep their order)
        return rules.enumerated().sorted { $0.element.clearance != $1.element.clearance ? $0.element.clearance < $1.element.clearance
                                                                                        : $0.offset < $1.offset }.map(\.element)
    }

    /// EvalRules(CLEARANCE_CONSTRAINT, a, b): the clearance between two copper items and the name of what sets it
    func clearanceConstraint(_ a: CopperItem, _ b: CopperItem, _ rules: [ClearanceRule], _ c: Copper) -> (Int, String) {
        let aNonCopper = !a.copper, bNonCopper = !b.copper
        // a footprint's net tie: no clearance between its items and the nets it ties them to (between an item
        // connected and one not, or two of one footprint)
        if (a.connected != b.connected || (a.footprint != nil && a.footprint == b.footprint)) && !aNonCopper && !bNonCopper {
            if a.footprint != nil, b.connected, c.netTies[ObjectIdentifier(a)]?.contains(b.net) == true { return (0, "net tie") }
            if b.footprint != nil, a.connected, c.netTies[ObjectIdentifier(b)]?.contains(a.net) == true { return (0, "net tie") }
        }
        // local overrides take precedence over everything but the board's minimum
        let oa = a.connected && !bNonCopper ? a.clearanceOverride : nil
        let ob = b.connected && !aNonCopper ? b.clearanceOverride : nil
        if oa != nil || ob != nil {
            var value = 0, source = ""
            if let oa { (value, source) = oa }
            if let ob, ob.value > value { (value, source) = ob }
            if value != 0 {
                if value < settings.minClearance { return (settings.minClearance, "board minimum") }
                return (value, source)
            }
        }
        var clearance = 0, name = ""
        if !aNonCopper && !bNonCopper {
            let ca = netClasses.effective(a.netName).name, cb = netClasses.effective(b.netName).name
            for r in rules where (a.connected && r.netClass == ca) || (b.connected && r.netClass == cb) {
                (clearance, name) = (r.clearance, r.named ? "netclass '\(r.parent)'" : "")
            }
        }
        if clearance > BoardWorld.maximumClearance { clearance = BoardWorld.maximumClearance }
        for local in [a.connected ? a.localClearance : nil, b.connected ? b.localClearance : nil].compactMap({ $0 })
            where local.value > clearance {
            (clearance, name) = (local.value, local.source)
        }
        if !aNonCopper && !bNonCopper && clearance < settings.minClearance { (clearance, name) = (settings.minClearance, "board minimum") }
        return (clearance, name)
    }

    /// EvalRules(HOLE_CLEARANCE_CONSTRAINT, hole's item, other)
    func holeClearanceConstraint(_ a: CopperItem, _ b: CopperItem) -> (Int, String) {
        let oa = a.connected && b.copper ? a.clearanceOverride : nil
        let ob = b.connected && a.copper ? b.clearanceOverride : nil
        if oa != nil || ob != nil {
            var value = 0, source = ""
            if let oa { (value, source) = oa }
            if let ob, ob.value > value { (value, source) = ob }
            if value != 0 {
                if value < settings.holeClearance { return (settings.holeClearance, "board minimum hole") }
                return (value, source)
            }
        }
        return (min(settings.holeClearance, BoardWorld.maximumClearance), "board setup constraints hole")
    }

    // MARK: - Collisions

    /// SHAPE::Collide of two compounds (pieces), with how close: the least of the pieces' that collide
    static func collide(_ a: [Shape], _ b: [Shape], _ clearance: Int) -> Int? {
        collideAt(a, b, clearance)?.actual
    }

    /// The same, with about where (the place of the closest pieces' collision)
    static func collideAt(_ a: [Shape], _ b: [Shape], _ clearance: Int) -> (actual: Int, location: IPoint)? {
        var best: (actual: Int, location: IPoint)?
        for sa in a {
            for sb in b {
                var actual: Int?, location: IPoint?
                if sa.collide(sb, clearance: clearance, actual: &actual, location: &location) {
                    let v = actual ?? 0
                    if best == nil || v < best!.actual { best = (v, location ?? .zero) }
                    if v == 0 { return best }
                }
            }
        }
        return best
    }

    /// DRC_ENGINE::IsNetTieExclusion: whether a collision at `pos` of an item of `net` with `colliding` is in a pad
    /// of a net tie footprint of that net (`colliding`'s), where it may be
    func isNetTieExclusion(_ net: Int, _ layer: Int, _ pos: IPoint, _ colliding: CopperItem, _ c: Copper) -> Bool {
        guard let f = colliding.footprint, c.isNetTie(f) else { return false }
        for pad in c.footprintPads[f] where c.netTieGroup(pad) >= 0 && pad.net == net {
            if Self.compoundPointCollide(pad.anyLayerShapes(layer), pos, settings.epsilon) { return true }
        }
        return false
    }

    /// SHAPE_COMPOUND::Collide of a point (as a segment of no length): each piece's own Collide( SEG ), a polygon's
    /// with arcs by its straight segments and then its arcs as arcs (SHAPE_LINE_CHAIN::Collide), not the chords
    /// its arcs were made of
    static func compoundPointCollide(_ shapes: [Shape], _ p: IPoint, _ clearance: Int) -> Bool {
        for s in shapes {
            switch s {
            case .simple(let l) where !l.arcs.isEmpty, .chain(let l) where !l.arcs.isEmpty:
                if l.collide(Seg(p, p), clearance: clearance) { return true }
            default:
                if collide([s], [.circle(center: p, radius: 0)], clearance) != nil { return true }
            }
        }
        return false
    }

    /// The fill of a zone on a layer against a shape, as the zone's R-tree of its fill's triangles answers
    /// (QueryColliding: the least of what collides)
    static func collide(_ shapes: [Shape], fill: [LineChain], _ clearance: Int) -> Int? {
        collide(shapes, fill.map { Shape.simple($0) }, clearance)
    }

    // MARK: - The checks (DRC_TEST_PROVIDER_COPPER_CLEARANCE)

    func checkCopperClearances(_ out: inout Report, _ c: Copper) {
        guard c.maxClearance > 0 else { return }
        let rules = clearanceRules(c.items + c.zones)
        let epsilon = settings.epsilon
        func subE(_ v: Int) -> Int { max(0, v - epsilon) }

        func netNameOrNone(_ i: CopperItem) -> String { i.net != 0 ? i.netName : "<no net>" }

        /// testSingleLayerItemAgainstItem: false where a violation is found
        func testSingleLayer(_ itemIn: CopperItem, _ itemShapeIn: [Shape], _ layer: Int, _ otherIn: CopperItem) -> Bool {
            var testClearance = !out.exceeded("clearance"), testShorting = !out.exceeded("shorting_items")
            let testHoles = !out.exceeded("hole_clearance")
            var item = itemIn, other = otherIn
            var itemShape = itemShapeIn
            if item.netIdentity == other.netIdentity { testClearance = false; testShorting = false }
            var otherShape: [Shape]
            if other.kind == .pad, !other.flashed.contains(layer) {
                if other.pad?.pad.attribute == .npth { testClearance = false; testShorting = false }
                otherShape = other.hole.map { [$0] } ?? []
            } else if other.kind == .via, !other.flashed.contains(layer) {
                otherShape = other.hole.map { [$0] } ?? []
            } else {
                otherShape = other.shapes[layer] ?? []
            }
            if item.uuid > other.uuid {
                swap(&item, &other)
                swap(&itemShape, &otherShape)
            }
            var clearance = -1, name = ""
            if testClearance || testShorting { (clearance, name) = clearanceConstraint(item, other, rules, c) }
            if clearance > 0 {
                if item.kind == .track && other.kind == .track,
                   case .segment(let s1, _)? = item.shapes[layer]?.first, case .segment(let s2, _)? = other.shapes[layer]?.first,
                   s1.intersect(s2) != nil {
                    out.add("tracks_crossing", nil, [item.uuid, other.uuid])
                    return false
                }
                if let (actual, pos) = Self.collideAt(itemShape, otherShape, subE(clearance)) {
                    if isNetTieExclusion(item.net, layer, pos, other, c) || isNetTieExclusion(other.net, layer, pos, item, c) {
                        // (a copper item into a pad of a net tie: allowed, whichever side was tested first)
                    } else if actual == 0 && other.connected && testShorting {
                        out.add("shorting_items", "(nets \(netNameOrNone(item)) and \(netNameOrNone(other)))", [item.uuid, other.uuid])
                        return false
                    } else if testClearance {
                        out.add("clearance", Self.formatMsg({ "(\($0) clearance \($1); actual \($2))" }, name, clearance, actual),
                                [item.uuid, other.uuid])
                        return false
                    }
                }
            }
            if testHoles && (item.hasHole || other.hasHole) {
                let pairs = [(item, other, itemShape), (other, item, otherShape)]
                for (a, b, aShape) in pairs {
                    let hole: Shape
                    if b.kind == .via {
                        guard b.layers.contains(layer), let h = b.hole else { continue }
                        hole = h
                    } else {
                        guard let h = b.hole else { continue }
                        hole = h
                    }
                    let (hc, hname) = holeClearanceConstraint(b, a)
                    if let actual = Self.collide(aShape, [hole], subE(hc)) {
                        let detail = hc != 0 ? Self.formatMsg({ "(\($0) clearance \($1); actual \($2))" }, hname, hc, actual)
                                             : Self.formatMsg({ c, v, _ in "(\(c) clearance \(v); actual < 0)" }, hname, hc, actual)
                        out.add("hole_clearance", detail, [a.uuid, b.uuid])
                        return false
                    }
                }
            }
            return true
        }

        /// testItemAgainstZone
        func testAgainstZone(_ item: CopperItem, _ zone: CopperItem, _ layer: Int) {
            guard zone.layers.contains(layer) else { return }
            if zone.net != 0 && item.connected && zone.net == item.net { return }
            guard let zbox = zone.zoneBox, item.bbox.inflated(c.maxClearance).intersects(zbox) else { return }
            guard let fill = zone.fills[layer], !fill.isEmpty else { return }
            // a net tie's drawing touching its pads of the zone's net (or pads tied to them) is the zone's
            if item.kind == .shape, let f = item.footprint, c.isNetTie(f), zone.net != 0 {
                var allowed: [CopperItem] = []
                for pad in c.footprintPads[f] where pad.net == zone.net {
                    if pad.layers.contains(layer) { allowed.append(pad) }
                    let g = c.netTieGroup(pad)
                    if g >= 0 {
                        for other in c.footprintPads[f] where other !== pad && c.netTieGroup(other) == g && other.layers.contains(layer) {
                            allowed.append(other)
                        }
                    }
                }
                for pad in allowed where pad.bbox.intersects(item.bbox) {
                    if Self.collide(pad.anyLayerShapes(layer), item.shapes[layer] ?? [], 0) != nil { return }
                }
            }
            var testClearance = !out.exceeded("clearance")
            let testHoles = !out.exceeded("hole_clearance")
            if !testClearance && !testHoles { return }
            if item.kind == .pad, let p = item.pad {
                let flashedPad = item.flashed.contains(layer)
                let platedHole = p.hasHole && p.pad.attribute == .pth
                if !flashedPad && !platedHole { testClearance = false }
            }
            if testClearance {
                let (clearance, name) = clearanceConstraint(item, zone, rules, c)
                if clearance > 0, let actual = Self.collide(item.shapes[layer] ?? [], fill: fill, subE(clearance)) {
                    out.add("clearance", Self.formatMsg({ "(\($0) clearance \($1); actual \($2))" }, name, clearance, actual),
                            [item.uuid, zone.uuid])
                }
            }
            if testHoles, let hole = item.hole, item.kind != .via || item.layers.contains(layer) {
                let (hc, hname) = holeClearanceConstraint(item, zone)
                if hc > 0, let actual = Self.collide([hole], fill: fill, subE(hc)) {
                    out.add("hole_clearance", Self.formatMsg({ "(\($0) clearance \($1); actual \($2))" }, hname, hc, actual),
                            [item.uuid, zone.uuid])
                }
            }
        }

        /// DRC_RTREE::QueryColliding of an item on a layer: each item near it that the filter lets through, visited
        /// in the tree's order, until the visitor says to stop
        func query(_ ref: CopperItem, _ layer: Int, filter: (CopperItem) -> Bool, visit: (CopperItem) -> Bool) {
            guard let tree = c.trees[layer] else { return }
            let refShape = ref.shapes[layer] ?? []
            var colliding = Set<ObjectIdentifier>()
            var filtered: [ObjectIdentifier: Bool] = [:]
            tree.search(ref.bbox.inflated(c.maxClearance)) { entry in
                let other = entry.item
                if other === ref { return true }
                let id = ObjectIdentifier(other)
                if colliding.contains(id) { return true }
                let rejected = filtered[id] ?? { let r = !filter(other); filtered[id] = r; return r }()
                if rejected { return true }
                guard Self.collide(refShape, [entry.shape], c.maxClearance) != nil else { return true }
                colliding.insert(id)
                return visit(other)
            }
        }

        /// testPadAgainstItem
        func testPadAgainstItem(_ pad: CopperItem, _ padShape: [Shape], _ layer: Int, _ other: CopperItem, footprint: Int) {
            var testClearance = !out.exceeded("clearance"), testShorting = !out.exceeded("shorting_items")
            var testHoles = !out.exceeded("hole_clearance")
            if other.footprint == pad.footprint {
                let group = c.netTieGroup(pad)
                if other.kind == .pad, let p = pad.pad, let o = other.pad {
                    if group >= 0 && group == c.netTieGroup(other) { testClearance = false; testShorting = false }
                    if !p.number.isEmpty && p.number == o.number { testHoles = false }
                }
                if other.kind == .shape && group >= 0 { testClearance = false; testShorting = false }
            }
            let otherPad = other.kind == .pad ? other : nil
            let otherVia = other.kind == .via ? other : nil
            if pad.pad?.pad.attribute == .npth && !pad.flashed.contains(layer) { testClearance = false; testShorting = false }
            if let op = otherPad, op.pad?.pad.attribute == .npth && !op.flashed.contains(layer) { testClearance = false; testShorting = false }
            if other.kind == .track || other.kind == .arc || other.kind == .via { testClearance = false; testShorting = false }
            if other.kind == .shape { testClearance = false; testShorting = false }
            if other.netCode != 0 && other.netCode == pad.net {
                testClearance = false; testShorting = false; testHoles = false
            }
            if !((pad.pad?.pad.drill.x ?? 0) > 0) && !((otherPad?.pad?.pad.drill.x ?? 0) > 0) && !((otherVia?.via?.drill ?? 0) > 0) {
                testHoles = false
            }
            if !testClearance && !testShorting && !testHoles { return }
            let otherShape = other.shapes[layer] ?? []
            if let op = otherPad, let p = pad.pad, let o = op.pad, op.footprint == pad.footprint, !p.number.isEmpty, p.number == o.number {
                // the same logical pad: of one net, if their nets are real
                if testShorting {
                    if pad.net == 0 || pad.net == op.net { return }
                    if pad.netName.hasPrefix("unconnected-(") && op.netName.hasPrefix("unconnected-(") { return }
                    out.add("shorting_items", "(nets \(netNameOrNone(pad)) and \(netNameOrNone(op)))", [pad.uuid, op.uuid])
                }
                return
            }
            if testClearance || testShorting {
                let (clearance, name) = clearanceConstraint(pad, other, rules, c)
                if clearance > 0, let (actual, pos) = Self.collideAt(padShape, otherShape, subE(clearance)) {
                    if isNetTieExclusion(pad.net, layer, pos, other, c) {
                        // (pads of a net tie's nets may touch its drawings)
                    } else if actual == 0 && pad.net != 0 && other.netCode != 0 && testShorting {
                        out.add("shorting_items", "(nets \(netNameOrNone(pad)) and \(netNameOrNone(other)))", [pad.uuid, other.uuid])
                        testHoles = false
                    } else if testClearance {
                        out.add("clearance", Self.formatMsg({ "(\($0) clearance \($1); actual \($2))" }, name, clearance, actual),
                                [pad.uuid, other.uuid])
                        testHoles = false
                    }
                }
            }
            guard testHoles else { return }
            let (hc, hname) = holeClearanceConstraint(pad, other)
            func doTestHole(_ a: CopperItem, _ shape: [Shape], _ b: CopperItem, _ hole: Shape, _ clearance: Int) -> Bool {
                guard let actual = Self.collide(shape, [hole], subE(clearance)) else { return false }
                out.add("hole_clearance", Self.formatMsg({ "(\($0) clearance \($1); actual \($2))" }, hname, clearance, actual),
                        [a.uuid, b.uuid])
                return true
            }
            if let op = otherPad, let h = op.hole, pad.flashed.contains(layer), hc > 0 {
                if doTestHole(pad, padShape, op, h, hc) { return }
            }
            if let h = pad.hole, let op = otherPad, op.flashed.contains(layer), hc > 0 {
                if doTestHole(op, otherShape, pad, h, hc) { return }
            }
            if let ov = otherVia, let h = ov.hole {
                let clearance = ov.layers.contains(layer) ? hc : 0
                if clearance > 0 { _ = doTestHole(pad, padShape, ov, h, clearance) }
            }
        }

        // tracks and vias
        var freePadsUsage: [ObjectIdentifier: Int] = [:]
        for track in c.tracks {
            for layer in track.layers {
                let trackShape = track.shapes[layer] ?? []
                query(track, layer, filter: { other in
                    if other.connected && other.net == track.net { return false }
                    if (other.kind == .track || other.kind == .arc || other.kind == .via) && track.uuid > other.uuid { return false }
                    return true
                }, visit: { other in
                    if other.kind == .pad, isFreePad(other), Self.collide(other.shapes[layer] ?? [], trackShape, 0) != nil {
                        let id = ObjectIdentifier(other)
                        if let net = freePadsUsage[id] {
                            if net == track.net { return true }
                        } else {
                            freePadsUsage[id] = track.net
                            return true
                        }
                    }
                    return testSingleLayer(track, trackShape, layer, other)
                })
                for zone in c.zones { testAgainstZone(track, zone, layer) }
            }
        }

        // pads
        for (fi, pads) in c.footprintPads.enumerated() {
            for pad in pads {
                for layer in pad.layers {
                    let padShape = pad.shapes[layer] ?? []
                    query(pad, layer, filter: { other in !(other.kind == .pad && pad.uuid > other.uuid) },
                          visit: { other in
                              testPadAgainstItem(pad, padShape, layer, other, footprint: fi)
                              return true
                          })
                    for zone in c.zones { testAgainstZone(pad, zone, layer) }
                }
            }
        }

        // drawings on copper
        for graphic in c.drawings + c.footprintDrawings.flatMap({ $0 }) {
            guard let layer = graphic.layers.first else { continue }
            for zone in c.zones { testAgainstZone(graphic, zone, layer) }
            let shape = graphic.shapes[layer] ?? []
            query(graphic, layer, filter: { other in
                if other.kind == .shape && graphic.footprint != nil && graphic.footprint == other.footprint { return false }
                if other.kind == .track || other.kind == .arc || other.kind == .via { return false }
                if graphic.netCode != 0 && graphic.netCode == other.netCode { return false }
                if other.kind == .shape && graphic.uuid > other.uuid { return false }
                return true
            }, visit: { other in
                _ = testSingleLayer(graphic, shape, layer, other)
                return true
            })
        }
        if !out.exceeded("clearance") || !out.exceeded("zones_intersect") { testZonesToZones(&out, c, rules) }
    }

    /// testZonesToZones: each pair of zones on a copper layer (teardrops left out), of one net and one priority
    /// whose outlines touch (zones_intersect), or of two nets whose fills are nearer than their clearance, the first
    /// pair of the fills' edges found nearer (their edges swept by x)
    func testZonesToZones(_ out: inout Report, _ c: Copper, _ rules: [ClearanceRule]) {
        let testClearance = !out.exceeded("clearance"), testIntersects = !out.exceeded("zones_intersect")
        let zones = c.zones
        // each fill's edges, each one's ends from left to right, sorted by them
        var segments: [Int: [Int: [Seg]]] = [:]
        func edges(_ z: Int, _ l: Int) -> [Seg] {
            if let s = segments[z]?[l] { return s }
            var list: [Seg] = []
            for chain in zones[z].fills[l] ?? [] {
                for i in 0..<chain.segmentCount {
                    var seg = chain.segment(i)
                    if seg.a.x > seg.b.x { seg = Seg(seg.b, seg.a) }
                    list.append(seg)
                }
            }
            list.sort { a, b in
                if a.a.x != b.a.x { return a.a.x < b.a.x }
                if a.a.y != b.a.y { return a.a.y < b.a.y }
                if a.b.x != b.b.x { return a.b.x < b.b.x }
                return a.b.y < b.b.y
            }
            segments[z, default: [:]][l] = list
            return list
        }
        func fillSet(_ z: CopperItem, _ l: Int) -> PolySet { PolySet((z.fills[l] ?? []).map { [$0] }) }
        for l in 0..<world.copperLayers {
            let onLayer = zones.indices.filter { !zones[$0].teardrop && zones[$0].layers.contains(l) }
            for (k, ia) in onLayer.enumerated() {
                for ib in onLayer[(k + 1)...] {
                    let a = zones[ia], b = zones[ib]
                    let sameNet = a.net == b.net && a.net >= 0
                    if sameNet && a.zonePriority != b.zonePriority { continue }
                    let setA = sameNet ? a.zoneOutline : fillSet(a, l), setB = sameNet ? b.zoneOutline : fillSet(b, l)
                    guard let boxA = Self.cachedBox(setA, width: 0), let boxB = Self.cachedBox(setB, width: 0),
                          boxA.intersects(boxB) else { continue }
                    if sameNet {
                        if testIntersects && Self.polySetsCollide(setA, setB) {
                            out.add("zones_intersect", "(intersecting zones must have distinct priorities)", [a.uuid, b.uuid])
                        }
                    } else if testClearance {
                        let (clearance, name) = clearanceConstraint(a, b, rules, c)
                        guard clearance > 0 else { continue }
                        let testSegments = edges(ib, l)
                        search: for ref in edges(ia, l) {
                            for test in testSegments {
                                if ref.b.x < test.a.x { break }
                                let (_, _, d2) = ref.nearestPoints(test)
                                let actual = Int((Double(d2).squareRoot() + 0.5).rounded(.down))
                                if actual < clearance {
                                    out.add("clearance", Self.formatMsg({ "(\($0) clearance \($1); actual \($2))" }, name, clearance,
                                                                        max(actual, 0)), [a.uuid, b.uuid])
                                    break search
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// PAD::IsFreePad: a pad of a free pin on a net of its own
    func isFreePad(_ item: CopperItem) -> Bool {
        guard let p = item.pad else { return false }
        return p.net.hasPrefix("unconnected-(") && p.pinType == "free"
    }
}
