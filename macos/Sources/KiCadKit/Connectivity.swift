import Foundation

/// What touches what in a board's copper, as KiCad's connectivity (pcbnew/connectivity) works it out: pads, tracks,
/// vias and zone fills, joined where an end of one lies on another on a copper layer they share. From it come the nets
/// the tracks take from the pads they reach (CN_CONNECTIVITY_ALGO::PropagateNets, which KiCad runs as a change to the
/// board is committed, and JSpice runs after it changes a board file itself), and the ratsnest: the connections a net
/// still lacks.
public final class KiCadConnectivity {
    public enum Kind: Sendable { case pad, track, via, zone }

    public struct Item {
        public let kind: Kind
        public let node: SExpr
        public let net: String?
        public let layers: Set<String>
        /// A pad's footprint's reference and the pad's number
        public let pad: (reference: String, number: String)?
        /// Where it connects: a track's ends, a pad's or a via's centre
        let anchors: [KiCadPoint]
        let shape: Shape
        let box: KiCadBox
        /// Whether propagation may give it another net (tracks and vias may; pads and zones keep theirs)
        public var canChangeNet: Bool { kind == .track || kind == .via }
    }

    enum Shape {
        case polygon([KiCadPoint])
        case line([KiCadPoint], halfWidth: Double)
        case disc(KiCadPoint, radius: Double)
        /// A zone's fill, by layer
        case fill([String: [[KiCadPoint]]])
    }

    public let items: [Item]
    /// The board's copper layers, top to bottom
    public let copperLayers: [String]

    public init(_ board: KiCadBoard) {
        // the copper layers in the order of the stack: F.Cu, In1.Cu…, B.Cu
        let declared = board.root["layers"]?.items.compactMap { $0.text(at: 0) }.filter { $0.hasSuffix(".Cu") } ?? []
        var stack = declared.filter { $0 != "F.Cu" && $0 != "B.Cu" }
            .sorted { (Int($0.dropFirst(2).dropLast(3)) ?? 0) < (Int($1.dropFirst(2).dropLast(3)) ?? 0) }
        stack.insert("F.Cu", at: 0)
        stack.append("B.Cu")
        copperLayers = stack
        let all = Set(stack)

        func padLayers(_ names: [String]) -> Set<String> {
            var set = Set<String>()
            for n in names {
                if n == "*.Cu" { set.formUnion(all) } else if n == "F&B.Cu" { set.formUnion(["F.Cu", "B.Cu"]) } else if all.contains(n) { set.insert(n) }
            }
            return set
        }

        var items: [Item] = []
        for footprint in board.footprints {
            let reference = footprint.reference
            for pad in footprint.pads where pad.isCopper {
                let outline = pad.outline
                guard let box = KiCadBox(outline) else { continue }
                items.append(Item(kind: .pad, node: pad.node, net: pad.net, layers: padLayers(pad.layers),
                                  pad: (reference, pad.number), anchors: [pad.position], shape: .polygon(outline), box: box))
            }
        }
        for track in board.tracks where all.contains(track.layer) {
            let points = track.points
            guard let box = KiCadBox(points)?.inflated(track.width / 2) else { continue }
            items.append(Item(kind: .track, node: track.node, net: track.net, layers: [track.layer], pad: nil,
                              anchors: [track.start, track.end], shape: .line(points, halfWidth: track.width / 2), box: box))
        }
        for via in board.vias {
            let ends = via.layers.compactMap { stack.firstIndex(of: $0) }
            let span = ends.count == 2 ? Set(stack[min(ends[0], ends[1])...max(ends[0], ends[1])]) : all
            let r = via.size / 2
            items.append(Item(kind: .via, node: via.node, net: via.net, layers: span, pad: nil, anchors: [via.position],
                              shape: .disc(via.position, radius: r),
                              box: KiCadBox(minX: via.position.x - r, minY: via.position.y - r, maxX: via.position.x + r, maxY: via.position.y + r)))
        }
        for zone in board.zones where zone.isCopper {
            var fills: [String: [[KiCadPoint]]] = [:]
            for fill in zone.fills where all.contains(fill.layer) && fill.points.count > 2 { fills[fill.layer, default: []].append(fill.points) }
            guard let box = KiCadBox(fills.values.flatMap { $0.flatMap { $0 } }) else { continue }
            items.append(Item(kind: .zone, node: zone.node, net: zone.net, layers: Set(fills.keys), pad: nil, anchors: [],
                              shape: .fill(fills), box: box))
        }
        self.items = items
    }

    // MARK: - What touches what

    /// Whether `p`, on `layer`, lies on item `b`
    func contains(_ b: Item, _ p: KiCadPoint, on layer: String) -> Bool {
        let tolerance = 1e-4
        switch b.shape {
        case .polygon(let outline): return KiCadPolygon.distance(p, to: outline) <= tolerance
        case .line(let points, let halfWidth):
            for i in 1..<max(points.count, 2) where i < points.count {
                if KiCadPolygon.distance(p, toSegment: points[i - 1], points[i]) <= halfWidth + tolerance { return true }
            }
            return false
        case .disc(let c, let r): return p.distance(to: c) <= r + tolerance
        case .fill(let fills): return (fills[layer] ?? []).contains { KiCadPolygon.contains($0, p) }
        }
    }

    /// The points of an item that may meet a zone's fill: a pad's outline (thermal spokes reach its edge), a via's
    /// ring, a track's ends
    func probes(_ a: Item) -> [KiCadPoint] {
        switch a.shape {
        case .polygon(let outline): return outline + a.anchors
        case .disc(let c, let r): return [c] + KiCadPolygon.circle(center: c, radius: r * 0.98, segments: 12)
        default: return a.anchors
        }
    }

    /// Whether two items touch on a copper layer they share
    func connected(_ a: Item, _ b: Item) -> Bool {
        guard a.box.inflated(1e-3).intersects(b.box) else { return false }
        let shared = a.layers.intersection(b.layers)
        guard !shared.isEmpty else { return false }
        for layer in shared {
            if a.kind == .zone || b.kind == .zone {
                let (zone, other) = a.kind == .zone ? (a, b) : (b, a)
                if other.kind == .zone { return false }
                if probes(other).contains(where: { contains(zone, $0, on: layer) }) { return true }
                // the fill reaching into a pad
                if other.kind == .pad, case .fill(let fills) = zone.shape {
                    for outline in fills[layer] ?? [] where outline.contains(where: { contains(other, $0, on: layer) }) { return true }
                }
                continue
            }
            if a.anchors.contains(where: { contains(b, $0, on: layer) }) { return true }
            if b.anchors.contains(where: { contains(a, $0, on: layer) }) { return true }
            // two pads overlapping
            if a.kind == .pad, b.kind == .pad, case .polygon(let pa) = a.shape, case .polygon(let pb) = b.shape {
                if pa.contains(where: { KiCadPolygon.contains(pb, $0) }) || pb.contains(where: { KiCadPolygon.contains(pa, $0) }) { return true }
            }
        }
        return false
    }

    /// The groups of items joined by copper, among those `include` takes, joining only items `join` allows
    public func clusters(include: (Item) -> Bool = { _ in true }, join: (Item, Item) -> Bool = { _, _ in true }) -> [[Int]] {
        let chosen = items.indices.filter { include(items[$0]) }
        var parent = Dictionary(uniqueKeysWithValues: chosen.map { ($0, $0) })
        func find(_ i: Int) -> Int {
            var r = i
            while parent[r]! != r { r = parent[r]! }
            var j = i
            while parent[j]! != r { let next = parent[j]!; parent[j] = r; j = next }
            return r
        }
        // items sorted by their boxes' left edges, so only those whose boxes overlap in x are compared
        let order = chosen.sorted { items[$0].box.minX < items[$1].box.minX }
        for (n, i) in order.enumerated() {
            let a = items[i]
            for j in order[(n + 1)...] {
                let b = items[j]
                if b.box.minX > a.box.maxX + 1e-3 { break }
                guard join(a, b), find(i) != find(j), connected(a, b) else { continue }
                parent[find(i)] = find(j)
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in chosen { groups[find(i), default: []].append(i) }
        return groups.values.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }

    // MARK: - Propagating nets

    public struct NetChange: Sendable, Hashable {
        public var uuid: String
        public var kind: String
        public var from: String?
        public var to: String
    }

    /// Gives each track and via the net of the pads its copper reaches, as KiCad does when a change is committed: in
    /// each group of copper joined regardless of nets (zones left out), the net most of its pads are on, unless its
    /// pads disagree (then nothing is changed, the user's intent being unknown); in a group without pads, the first
    /// net found
    @discardableResult
    public func propagateNets(on board: KiCadBoard) -> [NetChange] {
        var changes: [NetChange] = []
        for cluster in clusters(include: { $0.kind != .zone }) {
            var origin: String?
            var originIsPad = false
            var ranks: [String: Int] = [:]
            var conflicting = false
            for i in cluster {
                let item = items[i]
                guard let net = item.net else { continue }
                if origin == nil { origin = net; ranks[net] = 0 }
                if item.kind == .pad {
                    ranks[net, default: 0] += 1
                    if !originIsPad || ranks[net]! > ranks[origin!]! {
                        origin = net
                        originIsPad = true
                    }
                    if net != origin { conflicting = true }
                }
            }
            guard !conflicting, let net = origin else { continue }
            for i in cluster where items[i].canChangeNet && items[i].net != net {
                let item = items[i]
                if item.kind == .track { KiCadTrack(item.node, board: board).setNet(net) }
                if item.kind == .via { KiCadVia(item.node, board: board).setNet(net) }
                changes.append(NetChange(uuid: item.node.value("uuid") ?? "", kind: item.node.head ?? "", from: item.net, to: net))
            }
        }
        return changes
    }

    // MARK: - Ratsnest

    /// A connection a net still lacks, between the nearest points of two of its pieces of copper
    public struct Airwire: Sendable, Hashable {
        public var net: String
        public var from: KiCadPoint
        public var to: KiCadPoint
        /// The pads it joins, where it joins pads ("R1.2")
        public var ends: [String]
    }

    /// The connections each net still lacks: its pieces of copper (joined within the net, zones included) linked by
    /// the shortest wires that join them all (a minimum spanning tree, as KiCad's ratsnest is)
    public func ratsnest() -> [Airwire] {
        let groups = clusters(include: { $0.net != nil }, join: { $0.net == $1.net })
        var byNet: [String: [[Int]]] = [:]
        for g in groups { if let net = items[g[0]].net { byNet[net, default: []].append(g) } }
        var wires: [Airwire] = []
        for (net, pieces) in byNet {
            // only the pieces with something to connect: pads, or copper ending somewhere
            let parts = pieces.filter { $0.contains { items[$0].kind == .pad } }
            guard parts.count > 1 else { continue }
            func points(_ piece: [Int]) -> [(KiCadPoint, String?)] {
                piece.flatMap { i -> [(KiCadPoint, String?)] in
                    let item = items[i]
                    let label = item.pad.map { "\($0.reference).\($0.number)" }
                    return item.anchors.map { ($0, label) }
                }
            }
            let anchors = parts.map(points)
            // Prim's tree over the pieces, each edge the closest pair of their points
            var inTree = [true] + Array(repeating: false, count: parts.count - 1)
            for _ in 1..<parts.count {
                var best: (d: Double, a: (KiCadPoint, String?), b: (KiCadPoint, String?), j: Int)?
                for i in parts.indices where inTree[i] {
                    for j in parts.indices where !inTree[j] {
                        for a in anchors[i] {
                            for b in anchors[j] {
                                let d = a.0.distance(to: b.0)
                                if best == nil || d < best!.d { best = (d, a, b, j) }
                            }
                        }
                    }
                }
                guard let edge = best else { break }
                inTree[edge.j] = true
                wires.append(Airwire(net: net, from: edge.a.0, to: edge.b.0, ends: [edge.a.1, edge.b.1].compactMap { $0 }))
            }
        }
        return wires.sorted { ($0.net, $0.from.x, $0.from.y) < ($1.net, $1.from.x, $1.from.y) }
    }

    /// The pads a zone's fill reaches
    public func pads(touching zone: SExpr) -> [Item] {
        guard let z = items.first(where: { $0.node === zone }) else { return [] }
        return items.filter { $0.kind == .pad && connected($0, z) }
    }
}
