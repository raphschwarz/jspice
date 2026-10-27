// Ported from KiCad 10.0.7: pcbnew/connectivity (connectivity_algo.cpp, connectivity_items.cpp, connectivity_data.cpp:
// what touches what in the copper, the clusters of it, the nets propagated through them, and whether a track's or
// via's end is left dangling), pcbnew/ratsnest/ratsnest_data.cpp (each net's missing connections: a minimum spanning
// tree of its anchors over their Delaunay triangulation), pcbnew/drc/drc_test_provider_connectivity.cpp (the DRC's
// checks of them), pcbnew/pcb_shape.cpp (GetConnectionPoints) and pcbnew/pad.cpp (IsFreePad).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

extension BoardDRC {
    // MARK: - The connectivity's items

    /// A connectivity item (CN_ITEM): a pad, track, arc, via or copper drawing, or one outline of a zone's fill on
    /// one layer (CN_ZONE_LAYER). KiCad orders them, its clusters and the sets they are in by their addresses in
    /// memory, which are in the order it makes them; `serial` is that order.
    final class CNItem {
        let serial: Int
        let parent: CopperItem
        let canChangeNet: Bool
        var anchors: [CNAnchor] = []
        /// Its layers as the connectivity's R-tree has them (KiCad's layer ids, B.Cu last)
        var startLayer = 0, endLayer = Int.max
        /// What touches it, in serial order
        private(set) var connected: [CNItem] = []
        var bbox: IBox
        /// A zone outline's: its layer (a router layer), which outline of the fill, and the outline
        var zoneLayer: Int?
        var subpoly = 0
        var outline: LineChain?

        init(serial: Int, parent: CopperItem, canChangeNet: Bool, bbox: IBox) {
            self.serial = serial
            self.parent = parent
            self.canChangeNet = canChangeNet
            self.bbox = bbox
        }

        var net: Int { parent.net }
        var isZone: Bool { zoneLayer != nil }

        func connect(_ b: CNItem) {
            var lo = 0, hi = connected.count
            while lo < hi {
                let m = (lo + hi) / 2
                if connected[m].serial < b.serial { lo = m + 1 } else { hi = m }
            }
            if lo < connected.count && connected[lo] === b { return }
            connected.insert(b, at: lo)
        }

        /// CN_ITEM::GetAnchor's count (a zone outline's one point, though no anchor was added for it)
        var anchorCount: Int {
            if isZone { return (outline?.pointCount ?? 0) > 0 ? 1 : 0 }
            switch parent.kind {
            case .track, .arc: return 2
            case .shape: return anchors.count
            default: return 1
            }
        }

        /// CN_ITEM::GetAnchor: a pad's position (not where its shape is), a track's ends, a via's centre
        func anchor(_ n: Int) -> IPoint {
            if isZone { return outline!.point(0) }
            switch parent.kind {
            case .pad: return parent.pad!.pad.pos
            case .track, .arc: return n == 0 ? parent.trackStart : parent.trackEnd
            case .via: return parent.via!.start
            default: return n < anchors.count ? anchors[n].pos : .zero
            }
        }

        /// The layer KiCad gives it (CN_ITEM::Layer: its start layer)
        var layer: Int { startLayer }
    }

    final class CNAnchor {
        let pos: IPoint
        let item: CNItem
        var tag = -1
        var cluster: CNCluster?

        init(_ pos: IPoint, _ item: CNItem) { (self.pos, self.item) = (pos, item) }
    }

    final class CNCluster {
        let serial: Int
        var items: [CNItem] = []
        var originPad: CNItem?
        var originNet = -1
        var netRanks: [Int: Int] = [:]
        var conflicting = false

        init(serial: Int) { self.serial = serial }

        /// CN_CLUSTER::Add: the item, and the net of the most of its pads (not free ones) as its origin
        func add(_ item: CNItem, _ drc: BoardDRC) {
            items.append(item)
            let net = item.net
            guard net > 0 else { return }
            if originNet <= 0 {
                originNet = net
                netRanks[originNet] = 0
            }
            if item.parent.kind == .pad, let p = item.parent.pad, !drc.isFreePad(p) {
                let rank = (netRanks[net] ?? 0) + 1
                netRanks[net] = rank
                if originPad == nil || rank > netRanks[originNet] ?? 0 {
                    originPad = item
                    originNet = net
                }
                if originPad != nil && item.net != originNet { conflicting = true }
            }
        }

        var isOrphaned: Bool { originPad == nil }
    }

    struct CNEdge {
        var source: CNAnchor
        var target: CNAnchor
        var weight: Int
    }

    /// PAD::IsFreePad: a pad of a net of its own made for it ("unconnected-(…)"), of pin type free
    func isFreePad(_ p: Pad) -> Bool { p.net.hasPrefix("unconnected-(") && p.pinType == "free" }

    /// A router layer as KiCad's layer id, B.Cu the greatest (as CN_ITEM::SetLayers has it)
    func cnLayer(_ l: Int) -> Int {
        if l == 0 { return 0 }
        if l == world.copperLayers - 1 { return Int.max }
        return 2 + 2 * l
    }

    /// PCB_SHAPE::GetConnectionPoints
    static func connectionPoints(_ d: BoardWorld.Drawing) -> [IPoint] {
        if d.filled {
            switch d.kind {
            case .arc: return [d.center]
            case .circle: return [d.start]
            case .segment: return [IPoint((d.start.x + d.end.x) / 2, (d.start.y + d.end.y) / 2)]
            case .poly, .rect, .bezier:
                let pts = d.kind == .poly ? d.poly : [d.start, d.end]
                guard var box = pts.first.map({ IBox($0, $0) }) else { return [] }
                for p in pts.dropFirst() { box.merge(IBox(p, p)) }
                return [IPoint(box.minX + (box.maxX - box.minX) / 2, box.minY + (box.maxY - box.minY) / 2)]
            }
        }
        switch d.kind {
        case .circle:
            let r = d.radius, c = d.start
            return [IPoint(c.x, c.y + r), IPoint(c.x + r, c.y), IPoint(c.x, c.y - r), IPoint(c.x - r, c.y)]
        case .arc:
            return [KiMath.rotate(d.start, around: d.center, -d.arcAngle / 2.0), d.start, d.end]
        case .segment, .bezier:
            return [d.start, d.end]
        case .poly:
            return d.poly
        case .rect:
            return [d.start, IPoint(d.end.x, d.start.y), d.end, IPoint(d.start.x, d.end.y)]
        }
    }

    // MARK: - Building it

    /// CONNECTIVITY_DATA::Build of a board: its items, what touches what, the nets propagated, and each net's
    /// ratsnest
    final class Connectivity {
        var items: [CNItem] = []
        /// Each board item's connectivity items
        var entries: [ObjectIdentifier: [CNItem]] = [:]
        /// The ratsnest's nets, by net code: each one's missing connections
        var nets: [Int: [CNEdge]] = [:]
        /// How many clusters have been made (their serials)
        var clusterSerial = 0
        /// The ratsnest's cluster of each board item in one (by its uuid)
        var clusterOf: [String: Int] = [:]
    }

    func buildConnectivity(_ c: Copper) -> Connectivity {
        let cn = Connectivity()
        func add(_ item: CNItem) {
            cn.items.append(item)
            cn.entries[ObjectIdentifier(item.parent), default: []].append(item)
        }
        // (a box a nanometre or two wider than the shapes: KiCad's own boxes are at least as wide)
        func box(_ shapes: [Shape]) -> IBox {
            var b = shapes.first?.bbox ?? IBox(minX: 0, minY: 0, maxX: 0, maxY: 0)
            for s in shapes.dropFirst() { b.merge(s.bbox) }
            return b.inflated(2)
        }
        // the board's zones' fills, outline by outline, each layer of each in KiCad's order of them
        for zone in c.zones where zone.footprint == nil {
            for l in zone.layers {
                for (j, outline) in (zone.fills[l] ?? []).enumerated() {
                    let it = CNItem(serial: cn.items.count, parent: zone, canChangeNet: false,
                                    bbox: (zone.zoneBox ?? box([.simple(outline)])).inflated(2))
                    it.zoneLayer = l
                    it.subpoly = j
                    it.outline = outline
                    it.startLayer = cnLayer(l)
                    it.endLayer = cnLayer(l)
                    add(it)
                }
            }
        }
        // the tracks, arcs and vias
        for t in c.tracks {
            let shapes = t.layers.compactMap { t.shapes[$0] }.flatMap { $0 }
            let it = CNItem(serial: cn.items.count, parent: t, canChangeNet: t.kind != .via || !(t.via?.free ?? false), bbox: box(shapes))
            switch t.kind {
            case .via:
                it.anchors = [CNAnchor(t.via!.start, it)]
                it.startLayer = cnLayer(t.layers.min() ?? 0)
                it.endLayer = cnLayer(t.layers.max() ?? 0)
            default:
                it.anchors = [CNAnchor(t.trackStart, it), CNAnchor(t.trackEnd, it)]
                it.startLayer = cnLayer(t.layers[0])
                it.endLayer = it.startLayer
            }
            add(it)
        }
        // the footprints' pads on copper
        for pad in c.footprintPads.joined() where pad.copper {
            guard let p = pad.pad else { continue }
            var shapes = pad.outline
            if let h = pad.hole { shapes.append(h) }
            let it = CNItem(serial: cn.items.count, parent: pad, canChangeNet: false, bbox: box(shapes))
            // (one anchor, where its shape is: its padstack has one copper layer's shape)
            it.anchors = [CNAnchor(p.pad.shapePos, it)]
            switch p.pad.attribute {
            case .smd, .npth, .conn:
                // (its first copper layer, top to bottom)
                let first = pad.layers.min() ?? 0
                it.startLayer = cnLayer(first)
                it.endLayer = it.startLayer
            case .pth:
                it.startLayer = 0
                it.endLayer = Int.max
            }
            add(it)
        }
        // the board's copper drawings
        for d in c.drawings {
            let it = CNItem(serial: cn.items.count, parent: d, canChangeNet: true, bbox: box(d.shapes[d.layers[0]] ?? []))
            it.anchors = d.connectionPoints.map { CNAnchor($0, it) }
            it.startLayer = cnLayer(d.layers[0])
            it.endLayer = it.startLayer
            add(it)
        }
        searchConnections(cn)
        propagateNets(cn)
        ratsnest(cn)
        return cn
    }

    /// The shape an item is collided by in the search for connections: a pad or via flashed on every layer it is
    /// on, unless it is flashed only where something connects to it, where it is its hole
    func cnShape(_ it: CopperItem, _ layer: Int, alwaysFlashed: Bool) -> [Shape] {
        switch it.kind {
        case .pad:
            if alwaysFlashed { return it.outline }
            return it.pad?.pad.attribute == .pth ? it.hole.map { [$0] } ?? [] : it.outline
        case .via:
            let v = it.via!
            return [.circle(center: v.start, radius: (alwaysFlashed ? v.diameter : v.drill) / 2)]
        default:
            return it.shapes[layer] ?? []
        }
    }

    /// Whether a pad or via is always flashed on a layer (not ConditionallyFlashed)
    func alwaysFlashed(_ it: CopperItem, _ layer: Int) -> Bool {
        switch it.kind {
        case .pad: return !(it.pad?.unconnectedLayers.conditionallyFlashed(layer, start: 0, end: world.copperLayers - 1) ?? false)
        case .via:
            let v = it.via!
            return !v.unconnectedLayers.conditionallyFlashed(layer, start: v.layers.start, end: v.layers.end)
        default: return false
        }
    }

    /// CN_ZONE_LAYER::ContainsPoint: in the outline's fill (on its edge too)
    static func zoneContains(_ z: CNItem, _ p: IPoint) -> Bool {
        guard let o = z.outline, o.pointCount > 0 else { return false }
        return collide([.simple(o)], [.segment(Seg(p, p), width: 0)], 0) != nil
    }

    /// CN_CONNECTIVITY_ALGO::searchConnections: each item against those it might touch, once each pair
    func searchConnections(_ cn: Connectivity) {
        var deferredNetCodes: [(CNItem, Int)] = []
        func zoneItem(_ z: CNItem, _ item: CNItem) {
            guard let layer = z.zoneLayer, item.parent.layers.contains(layer) else { return }
            func connect() {
                if item.parent.kind == .via && item.canChangeNet { deferredNetCodes.append((item, z.net)) }
                z.connect(item)
                item.connect(z)
            }
            for i in 0..<item.anchorCount where Self.zoneContains(z, item.anchor(i)) {
                connect()
                return
            }
            let shapes = item.parent.kind == .via || item.parent.kind == .pad
                ? cnShape(item.parent, layer, alwaysFlashed: true) : cnShape(item.parent, layer, alwaysFlashed: false)
            if Self.collide(shapes, [.simple(z.outline!)], 0) != nil { connect() }
        }
        func zoneZone(_ a: CNItem, _ b: CNItem) {
            guard let oa = a.outline, let ob = b.outline, oa.pointCount > 0, ob.pointCount > 0, a.zoneLayer == b.zoneLayer,
                  a.bbox.intersects(b.bbox) else { return }
            for p in oa.points where b.bbox.contains(p) && Self.zoneContains(b, p) {
                a.connect(b)
                b.connect(a)
                return
            }
            for p in ob.points where a.bbox.contains(p) && Self.zoneContains(a, p) {
                a.connect(b)
                b.connect(a)
                return
            }
        }
        let items = cn.items
        for (i, m) in items.enumerated() {
            for cand in items[(i + 1)...] {
                // (the R-tree's search: boxes and layers that overlap)
                guard m.startLayer <= cand.endLayer && cand.startLayer <= m.endLayer, m.bbox.intersects(cand.bbox) else { continue }
                // CN_VISITOR, the later item the candidate
                guard m.parent !== cand.parent else { continue }
                if !cand.canChangeNet && !m.canChangeNet && cand.net != m.net { continue }
                if cand.isZone && m.isZone { zoneZone(m, cand); continue }
                if cand.isZone { zoneItem(cand, m); continue }
                if m.isZone { zoneItem(m, cand); continue }
                let a = cand.parent, b = m.parent
                for layer in kicadLayerOrder where a.layers.contains(layer) && b.layers.contains(layer) {
                    let sa = cnShape(a, layer, alwaysFlashed: alwaysFlashed(a, layer))
                    let sb = cnShape(b, layer, alwaysFlashed: alwaysFlashed(b, layer))
                    if Self.collide(sa, sb, 0) != nil {
                        m.connect(cand)
                        cand.connect(m)
                        break
                    }
                }
            }
        }
        // vias touching only zones take a zone's net (theirs if one is, else the least), via by via
        var nets: [Int: (CNItem, [Int])] = [:]
        for (item, net) in deferredNetCodes { nets[item.serial, default: (item, [])].1.append(net) }
        for (_, (item, zoneNets)) in nets.sorted(by: { $0.key < $1.key }) where item.connected.allSatisfy(\.isZone) {
            if !zoneNets.contains(item.parent.net) { setNet(item.parent, zoneNets.min()!) }
        }
    }

    /// A board item given another net, as the connectivity gives it (its name with it)
    func setNet(_ it: CopperItem, _ net: Int) {
        it.net = net
        it.netIdentity = net
        it.netName = world.netCodes.first { $0.value == net }?.key ?? ""
    }

    /// CN_CONNECTIVITY_ALGO::SearchClusters
    func searchClusters(_ cn: Connectivity, ratsnest: Bool, serial: inout Int) -> [CNCluster] {
        let excludeZones = !ratsnest
        var pending = cn.items.filter { item in
            if ratsnest && item.net <= 0 { return false }
            if excludeZones && item.isZone { return false }
            return true
        }
        var visited = Set<ObjectIdentifier>()
        var clusters: [CNCluster] = []
        var next = 0
        while next < pending.count {
            let root = pending[next]
            next += 1
            if visited.contains(ObjectIdentifier(root)) { continue }
            visited.insert(ObjectIdentifier(root))
            let cluster = CNCluster(serial: serial)
            serial += 1
            var queue = [root], head = 0
            while head < queue.count {
                let current = queue[head]
                head += 1
                cluster.add(current, self)
                for n in current.connected {
                    if ratsnest && n.net != root.net { continue }
                    if excludeZones && n.isZone { continue }
                    if visited.insert(ObjectIdentifier(n)).inserted { queue.append(n) }
                }
            }
            clusters.append(cluster)
        }
        pending.removeAll()
        Clipper.introSort(&clusters) { $0.originNet < $1.originNet }
        return clusters
    }

    /// CN_CONNECTIVITY_ALGO::PropagateNets: jumpers joined, then each cluster's tracks, vias and drawings given its
    /// pads' net
    func propagateNets(_ cn: Connectivity) {
        // updateJumperPads
        var byFootprint: [Int: [String: [CNItem]]] = [:]
        for item in cn.items where item.parent.kind == .pad {
            guard let f = item.parent.footprint, let p = item.parent.pad else { continue }
            byFootprint[f, default: [:]][p.number, default: []].append(item)
        }
        for (f, pads) in byFootprint.sorted(by: { $0.key < $1.key }) {
            func join(_ list: [CNItem]) {
                for i in list.indices {
                    for j in 1..<max(1, list.count) {
                        list[i].connect(list[j])
                        list[j].connect(list[i])
                    }
                }
            }
            if footprints[f].duplicatePadNumbersAreJumpers { for list in pads.values { join(list) } }
            for group in footprints[f].jumperPadGroups { join(group.flatMap { pads[$0] ?? [] }) }
        }
        var serial = cn.clusterSerial
        for cluster in searchClusters(cn, ratsnest: false, serial: &serial) where !cluster.conflicting && cluster.originNet > 0 {
            for item in cluster.items where item.canChangeNet && item.parent.net != cluster.originNet {
                setNet(item.parent, cluster.originNet)
            }
        }
        cn.clusterSerial = serial
    }

    // MARK: - The ratsnest

    /// CONNECTIVITY_DATA::internalRecalculateRatsnest and RN_NET::UpdateNet: each net's clusters' anchors, a
    /// minimum spanning tree of them over their Delaunay triangulation, its edges between clusters the missing
    /// connections
    func ratsnest(_ cn: Connectivity) {
        var serial = cn.clusterSerial
        let clusters = searchClusters(cn, ratsnest: true, serial: &serial)
        var nodes: [Int: [CNAnchor]] = [:]
        var boardEdges: [Int: [CNEdge]] = [:]
        var order: [Int] = []
        for cl in clusters {
            for item in cl.items { cn.clusterOf[item.parent.uuid] = cl.serial }
            if cl.isOrphaned && cl.items.count == 1 && cl.items[0].isZone { continue }
            let net = cl.originNet
            guard net > 0 else { continue }
            if nodes[net] == nil { order.append(net) }
            // RN_NET::AddCluster: its items' anchors (none of a zone's), each joined to its first
            var first: CNAnchor?
            for item in cl.items {
                let count = item.isZone ? min(1, item.anchors.count) : item.anchors.count
                for a in item.anchors.prefix(count) {
                    a.cluster = cl
                    Self.insertNode(&nodes[net, default: []], a)
                    if let f = first {
                        if f !== a { boardEdges[net, default: []].append(CNEdge(source: f, target: a, weight: 0)) }
                    } else {
                        first = a
                    }
                }
            }
        }
        for net in order {
            var edges = Self.compute(nodes[net] ?? [], boardEdges[net] ?? [])
            optimizeEdges(&edges)
            cn.nets[net] = edges
        }
    }

    /// Into the multiset of a net's nodes, by place, after those in the same place
    static func insertNode(_ nodes: inout [CNAnchor], _ a: CNAnchor) {
        var lo = 0, hi = nodes.count
        while lo < hi {
            let m = (lo + hi) / 2
            let n = nodes[m].pos
            if a.pos.x < n.x || (a.pos.x == n.x && a.pos.y < n.y) { hi = m } else { lo = m + 1 }
        }
        nodes.insert(a, at: lo)
    }

    /// CN_ANCHOR::Dist: the length between them, as an unsigned integer
    static func dist(_ a: CNAnchor, _ b: CNAnchor) -> Int { (a.pos - b.pos).norm }

    /// RN_NET::compute
    static func compute(_ nodes: [CNAnchor], _ boardEdges: [CNEdge]) -> [CNEdge] {
        if nodes.count <= 2 {
            if boardEdges.isEmpty && nodes.count == 2 {
                nodes[0].tag = 0
                nodes[1].tag = 1
                return [CNEdge(source: nodes[0], target: nodes[1], weight: 0)]
            }
            for n in nodes { n.tag = 0 }
            return []
        }
        var edges = triangulate(nodes)
        edges += boardEdges
        Clipper.introSort(&edges) { $0.weight < $1.weight }
        // kruskalMST
        var set = DisjointSet(nodes.count)
        for (i, n) in nodes.enumerated() { n.tag = i }
        var out: [CNEdge] = []
        for e in edges where set.unite(e.source.tag, e.target.tag) {
            if e.weight > 0 { out.append(e) }
        }
        return out
    }

    /// RN_NET::TRIANGULATOR_STATE::Triangulate: the edges of the triangulation of the nodes' places, and between
    /// the nodes in one place
    static func triangulate(_ all: [CNAnchor]) -> [CNEdge] {
        var edges: [CNEdge] = []
        func addEdge(_ a: CNAnchor, _ b: CNAnchor) { edges.append(CNEdge(source: a, target: b, weight: dist(a, b))) }
        var anchors: [CNAnchor] = []
        var chains: [[CNAnchor]] = []
        for n in all {
            if anchors.last.map({ $0.pos != n.pos }) ?? true {
                anchors.append(n)
                chains.append([])
            }
            chains[chains.count - 1].append(n)
        }
        if anchors.isEmpty { return [] }
        if anchors.count == 1 {
            // (all in one place: those of no layer in common joined)
            var prev: CNAnchor?
            for n in all {
                if let p = prev, !p.item.parent.layers.contains(where: n.item.parent.layers.contains) {
                    edges.append(CNEdge(source: p, target: n, weight: 1))
                }
                prev = n
            }
            return edges
        }
        let p0 = anchors[0].pos, v0 = anchors[1].pos - p0
        let colinear = anchors.count <= 2 || anchors.dropFirst(2).allSatisfy { v0.cross($0.pos - p0) == 0 }
        if colinear {
            for i in 0..<(anchors.count - 1) { addEdge(anchors[i], anchors[i + 1]) }
        } else if let d = try? Delaunator(x: anchors.map { Double($0.pos.x) }, y: anchors.map { Double($0.pos.y) }) {
            let t = d.triangles
            for i in stride(from: 0, to: t.count, by: 3) {
                addEdge(anchors[t[i]], anchors[t[i + 1]])
                addEdge(anchors[t[i + 1]], anchors[t[i + 2]])
                addEdge(anchors[t[i + 2]], anchors[t[i]])
            }
            for (i, h) in d.halfedges.enumerated() where h != Delaunator.invalid {
                addEdge(anchors[t[i]], anchors[t[h]])
            }
        }
        for var chain in chains where chain.count >= 2 {
            Clipper.introSort(&chain) { ($0.cluster?.serial ?? -1) < ($1.cluster?.serial ?? -1) }
            for j in 1..<chain.count {
                let a = chain[j - 1], b = chain[j]
                edges.append(CNEdge(source: a, target: b, weight: a.cluster !== b.cluster ? 1 : 0))
            }
        }
        return edges
    }

    /// The disjoint set RN_NET's Kruskal works with
    struct DisjointSet {
        var data: [Int], depth: [Int]

        init(_ n: Int) {
            data = Array(0..<n)
            depth = Array(repeating: 0, count: n)
        }

        mutating func find(_ v: Int) -> Int {
            var root = v
            while data[root] != root { root = data[root] }
            var a = v
            while data[a] != a {
                let next = data[a]
                data[a] = root
                a = next
            }
            return root
        }

        mutating func unite(_ a: Int, _ b: Int) -> Bool {
            let ra = find(a), rb = find(b)
            guard ra != rb else { return false }
            if depth[ra] < depth[rb] {
                data[ra] = rb
            } else {
                data[rb] = ra
                if depth[ra] == depth[rb] { depth[ra] += 1 }
            }
            return true
        }
    }

    /// CN_ANCHOR::ConnectedItemsCount: how many of what its item touches are at it
    func connectedItemsCount(_ a: CNAnchor) -> Int {
        guard a.cluster != nil else { return 0 }
        var n = 0
        for item in a.item.connected {
            if let l = item.zoneLayer {
                if Self.collide((item.parent.fills[l] ?? []).map { .simple($0) }, [.segment(Seg(a.pos, a.pos), width: 0)], 0) != nil { n += 1 }
            } else if hitTest(item.parent, a.pos, 0) {
                n += 1
            }
        }
        return n
    }

    /// BOARD_ITEM::HitTest of a point
    func hitTest(_ it: CopperItem, _ p: IPoint, _ accuracy: Int) -> Bool {
        let shapes: [Shape]
        switch it.kind {
        case .pad: shapes = it.outline
        case .via: shapes = [.circle(center: it.via!.start, radius: it.via!.diameter / 2)]
        default: shapes = it.layers.first.flatMap { it.shapes[$0] } ?? []
        }
        return Self.collide(shapes, [.segment(Seg(p, p), width: 0)], accuracy) != nil
    }

    /// RN_NET::OptimizeRNEdges: an edge to an item in a zone of its net drawn to the zone's nearest point instead,
    /// and between items in zones, between the zones' nearest points
    func optimizeEdges(_ edges: inout [CNEdge]) {
        func zoneAnchor(_ pos: IPoint, _ layers: [Int], _ anchor: CNAnchor) -> CNAnchor? {
            var closest = (anchor.pos - pos).squaredNorm
            var best: CNAnchor?
            for item in anchor.item.connected where item.net == anchor.item.net {
                guard let l = item.zoneLayer, layers.contains(l), let o = item.outline else { continue }
                for p in o.points {
                    let d = (p - pos).squaredNorm
                    if d < closest {
                        closest = d
                        best = CNAnchor(p, item)
                    }
                }
            }
            return best
        }
        for i in edges.indices {
            let s = edges[i].source, t = edges[i].target
            if connectedItemsCount(s) == 0 {
                if let o = zoneAnchor(s.pos, s.item.parent.layers, t) { edges[i].target = o }
            } else if connectedItemsCount(t) == 0 {
                if let o = zoneAnchor(t.pos, t.item.parent.layers, s) { edges[i].source = o }
            } else {
                // (zone to zone: the three pairs of their outlines whose middles are nearest)
                let za = s.item.connected.filter(\.isZone), zb = t.item.connected.filter(\.isZone)
                var pairs: [(Int, CNItem, CNItem)] = []
                for a in za {
                    for b in zb {
                        let ca = a.outline!.bbox.center, cb = b.outline!.bbox.center
                        pairs.append(((cb - ca).squaredNorm, a, b))
                    }
                }
                Clipper.introSort(&pairs) { $0.0 < $1.0 }
                for (_, a, b) in pairs.prefix(3) where a !== b {
                    if let (pa, pb) = a.outline!.closestSegmentsFast(b.outline!) {
                        edges[i].source = CNAnchor(pa, a)
                        edges[i].target = CNAnchor(pb, b)
                    }
                }
            }
        }
    }

    // MARK: - The checks

    /// CONNECTIVITY_DATA::TestTrackEndpointDangling (pads and vias a track lies in not counted as dangling)
    func trackDangling(_ cn: Connectivity, _ t: CopperItem) -> Bool {
        guard let item = cn.entries[ObjectIdentifier(t)]?.first else { return false }
        if t.kind == .via {
            if item.connected.isEmpty { return t.net > 0 }
            let first = item.connected[0].layer
            return item.connected.allSatisfy { $0.layer == first }
        }
        let layer = t.layers[0]
        let accuracy = KiMath.round(Double(t.trackWidth) / 2)
        let start = t.trackStart, end = t.trackEnd
        var startCount = 0, endCount = 0
        func minDist(_ it: CopperItem, _ p: IPoint) -> Double {
            switch it.kind {
            case .track, .arc: return min(it.trackStart.distance(p), it.trackEnd.distance(p))
            case .pad: return it.pad!.pad.pos.distance(p)
            case .via: return it.via!.start.distance(p)
            case .zone: return (it.fills.values.first?.first?.point(0) ?? .zero).distance(p)
            case .shape: return (item.anchors.first?.pos ?? .zero).distance(p)
            }
        }
        for connected in item.connected {
            let other = connected.parent
            var hitStart = false, hitEnd = false
            if other.kind == .zone {
                let fill = (other.fills[layer] ?? []).map { Shape.simple($0) }
                hitStart = Self.collide([.circle(center: start, radius: accuracy)], fill, 0) != nil
                hitEnd = Self.collide([.circle(center: end, radius: accuracy)], fill, 0) != nil
            } else {
                let shapes: [Shape]
                switch other.kind {
                case .pad: shapes = other.shapes[layer] ?? other.outline
                case .via: shapes = [.circle(center: other.via!.start, radius: other.via!.diameter / 2)]
                default: shapes = other.shapes[layer] ?? []
                }
                hitStart = Self.collide(shapes, [.segment(Seg(start, start), width: 0)], accuracy) != nil
                hitEnd = Self.collide(shapes, [.segment(Seg(end, end), width: 0)], accuracy) != nil
            }
            if hitStart && hitEnd {
                if other.kind == .zone || other.kind == .pad || other.kind == .via { return false }
                if minDist(other, start) < minDist(other, end) { startCount += 1 } else { endCount += 1 }
            } else if hitStart {
                startCount += 1
            } else if hitEnd {
                endCount += 1
            }
            if startCount > 0 && endCount > 0 { return false }
        }
        return true
    }

    /// DRC_TEST_PROVIDER_CONNECTIVITY: dangling tracks and vias, then each net's missing connections
    func checkConnectivity(_ out: inout Report, _ c: Copper, _ cn: Connectivity) {
        for t in c.tracks {
            let exceedT = out.exceeded("track_dangling"), exceedV = out.exceeded("via_dangling")
            if exceedT && exceedV { break }
            if t.kind == .via && exceedV { continue }
            if t.kind != .via && exceedT { continue }
            if trackDangling(cn, t) { out.add(t.kind == .via ? "via_dangling" : "track_dangling", nil, [t.uuid]) }
        }
        guard !out.exceeded("unconnected_items") else { return }
        for net in cn.nets.keys.sorted() {
            // (GetEdges: by their source's place)
            let edges = cn.nets[net]!.enumerated().sorted { a, b in
                let p = a.element.source.pos, q = b.element.source.pos
                if p.x != q.x { return p.x < q.x }
                if p.y != q.y { return p.y < q.y }
                if a.element.weight != b.element.weight { return a.element.weight < b.element.weight }
                return a.offset < b.offset
            }.map(\.element)
            for e in edges {
                guard !out.exceeded("unconnected_items") else { return }
                out.add("unconnected_items", nil, [e.source.item.parent.uuid, e.target.item.parent.uuid])
            }
        }
    }
}

extension Seg {
    /// SEG::NearestPoints: where they cross, else the nearest of each end to the other segment
    func nearestPoints(_ s: Seg) -> (IPoint, IPoint, Int) {
        if let p = intersect(s) { return (p, p, 0) }
        let origin = [s.nearestPoint(a), s.nearestPoint(b), nearestPoint(s.a), nearestPoint(s.b)]
        let outA = [a, b, origin[2], origin[3]], outB = [origin[0], origin[1], s.a, s.b]
        let dist = [(origin[0] - a).squaredNorm, (origin[1] - b).squaredNorm, (origin[2] - s.a).squaredNorm, (origin[3] - s.b).squaredNorm]
        var m = 0
        for i in 0..<4 where dist[i] < dist[m] { m = i }
        return (outA[m], outB[m], dist[m])
    }
}

extension LineChain {
    /// SHAPE_LINE_CHAIN::ClosestSegmentsFast: the nearest points of their outlines, looked for among the boxes of
    /// their points that are nearest
    func closestSegmentsFast(_ other: LineChain) -> (IPoint, IPoint)? {
        let mine = points, theirs = other.points
        guard !mine.isEmpty, !theirs.isEmpty else { return nil }
        let myPer = Swift.max(20, mine.count / 100 + 1), otherPer = Swift.max(20, theirs.count / 100 + 1)
        func boxes(_ pts: [IPoint], _ per: Int) -> [(center: IPoint, radius: Int)] {
            stride(from: 0, to: pts.count, by: per).map { start in
                let chunk = pts[start..<Swift.min(start + per, pts.count)]
                var lx = chunk.first!.x, ly = chunk.first!.y, hx = lx, hy = ly
                for p in chunk {
                    lx = Swift.min(lx, p.x); ly = Swift.min(ly, p.y); hx = Swift.max(hx, p.x); hy = Swift.max(hy, p.y)
                }
                let d = Double(hx - lx).hypot(Double(hy - ly))
                return (IPoint((lx + hx) / 2, (ly + hy) / 2), Int(d / 2))
            }
        }
        let a = boxes(mine, myPer), b = boxes(theirs, otherPer)
        var pairs: [(Int, Int, Int)] = []
        for (ia, ca) in a.enumerated() {
            for (ib, cb) in b.enumerated() {
                pairs.append(((cb.center - ca.center).norm - ca.radius - cb.radius, ia, ib))
            }
        }
        Clipper.introSort(&pairs) { $0.0 < $1.0 }
        var best = Int.max
        var found: (IPoint, IPoint)?
        for (_, ia, ib) in pairs.prefix(5) {
            let ms = ia * myPer, me = Swift.min(ms + myPer, mine.count)
            let os = ib * otherPer, oe = Swift.min(os + otherPer, theirs.count)
            var lastA = mine[ms == 0 ? mine.count - 1 : ms - 1]
            var closest = Int.max
            var pair: (IPoint, IPoint)?
            for pa in mine[ms..<me] {
                var lastB = theirs[os == 0 ? theirs.count - 1 : os - 1]
                for pb in theirs[os..<oe] {
                    let (na, nb, d) = Seg(lastA, pa).nearestPoints(Seg(lastB, pb))
                    if d < closest {
                        closest = d
                        pair = (na, nb)
                    }
                    lastB = pb
                }
                lastA = pa
            }
            if let pair, closest < best {
                best = closest
                found = pair
            }
        }
        return found
    }
}

private extension Double {
    func hypot(_ b: Double) -> Double { Foundation.hypot(self, b) }
}
