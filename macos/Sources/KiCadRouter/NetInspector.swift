// Ported from KiCad 10.0.8: pcbnew/length_delay_calculation/length_delay_calculation.cpp (CalculateLengthDetails:
// optimiseVias, mergeLines, mergeShapeLineChains, optimiseTracesInPads, OptimiseTraceInVia; GetLengthCalculationItem,
// StackupHeight) and length_delay_calculation_item.h (SetLayers), pcbnew/widgets/pcb_net_inspector_panel.cpp
// (buildColumns, buildNetsList, netFilterMatches, relevantConnectivityItems, calculateNets, formatLength),
// pcbnew/widgets/pcb_net_inspector_panel_data_model.h (LIST_ITEM, DATA_MODEL's addItem, addCustomGroups, GetValue and
// Compare), pcbnew/board.cpp (BOARD::GetTrackLength), pcbnew/connectivity/connectivity_data.cpp (GetConnectedPads,
// GetConnectedItems), common/string_utils.cpp (ValueStringCompare, SplitString, ApplyModifier), common/eda_units.cpp
// (MessageTextFromValue of millimetres) and common/eda_pattern_match.cpp (EDA_COMBINED_MATCHER of CTX_NET: its
// regular expression, wildcard and substring matchers).
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation
import KiCadKit

/// The lengths of a set of a board's tracks, arcs, vias and pads, as KiCad measures them (LENGTH_DELAY_CALCULATION:
/// the length domain, not the time domain's delays): its lines joined where they meet end to end on a layer, cut to
/// the copper of the vias and pads they end in, each via as high as the board between the layers it takes the signal
/// across, and the pads' lengths to their dies
public struct LengthCalculation {
    /// An item of the calculation (LENGTH_DELAY_CALCULATION_ITEM)
    public struct Item {
        public enum Kind { case pad, via, line }
        enum MergeStatus { case unmerged, mergedInUse, mergedRetired }
        public var kind: Kind
        /// A line's shape: a track's two ends, an arc's points with the arc
        var line = LineChain()
        /// Its layers, router layers (the upper first)
        var layerStart = 0, layerEnd = 0
        var mergeStatus = MergeStatus.unmerged
        /// A pad's or via's position (PAD::GetPosition, PCB_VIA::GetPosition)
        var position = IPoint.zero
        /// A via's radius on its layers (its padstack's one size)
        var viaRadius = 0
        /// A via's layers as the board has them (its top and bottom layer)
        var viaLayers = LayerRange(0, 0)
        /// The side layer of the first pad the connectivity joins a via to (GetConnectedPads: KiCad's set of them, in
        /// the order of their places in memory, which the port takes to be the order they were made in), if any
        var coincidentPadSide: Int?
        /// The side layers of all the pads the connectivity joins a via to, each once, the first's first: which pad
        /// KiCad finds first goes by where its pads were made in memory, which differs from one run of it to another
        var coincidentPadSides: [Int] = []
        /// A pad's PAD::GetPadToDieLength
        var padToDie = 0
        /// A pad's layer on its side (an SMD or edge connector pad's first copper layer, else its footprint's side)
        var padSideLayer = 0
        /// The layers a pad is flashed on (PAD::FlashLayer)
        var flashed: Set<Int> = []
        /// A pad's polygon, its error inside (PAD::GetEffectivePolygon( layer, ERROR_INSIDE ))
        var polygon: (() -> PolySet?)?

        /// A track's or arc's item: its line on its layer
        static func line(_ chain: LineChain, layer: Int) -> Item {
            var item = Item(kind: .line)
            item.line = chain
            item.layerStart = layer
            item.layerEnd = layer
            return item
        }

        /// SetLayers: the upper layer first
        mutating func setLayers(_ a: Int, _ b: Int) {
            (layerStart, layerEnd) = a <= b ? (a, b) : (b, a)
        }
    }

    /// The statistics of a calculation (LENGTH_DELAY_STATS), nm
    public struct Stats: Equatable, Sendable {
        public var numPads = 0
        public var numVias = 0
        public var viaLength = 0
        public var trackLength = 0
        public var padToDieLength = 0
        /// Each copper layer's length of lines (router layers), where asked for
        public var layerLengths: [Int: Int] = [:]

        public var totalLength: Int { viaLength + trackLength + padToDieLength }
    }

    /// The board's thickness between each two copper layers (StackupHeight; all nought where the board does not use
    /// heights for lengths)
    let heights: [[Int]]
    /// m_UseHeightForLengthCalcs
    let useHeight: Bool

    init(heights: [[Int]], useHeight: Bool) {
        self.heights = heights
        self.useHeight = useHeight
    }

    func stackupHeight(_ a: Int, _ b: Int) -> Int {
        guard useHeight, a >= 0, b >= 0, a < heights.count, b < heights[a].count else { return 0 }
        return heights[a][b]
    }

    /// CalculateLengthDetails with every optimisation but the via inferred in a pad (the net inspector's and
    /// GetTrackLength's), the lengths of each layer's lines too if `layerDetail`
    func calculate(_ items: inout [Item], layerDetail: Bool) -> Stats {
        var lines: [Int] = [], vias: [Int] = [], pads: [Int] = []
        // (lines by where they end: KiCad's map of points to the lines ending there)
        var linesAt: [IPoint: [Int]] = [:]
        func addLine(_ p: IPoint, _ i: Int) {
            if !(linesAt[p]?.contains(i) ?? false) { linesAt[p, default: []].append(i) }
        }
        for i in items.indices {
            switch items[i].kind {
            case .pad: pads.append(i)
            case .via: vias.append(i)
            case .line:
                lines.append(i)
                if items[i].line.pointCount > 0 {
                    addLine(items[i].line.point(0), i)
                    addLine(items[i].line.lastPoint, i)
                }
            }
        }
        optimiseVias(&items, vias, linesAt)
        mergeLines(&items, lines, linesAt)
        // (the lines in vias cut to the vias' copper)
        for v in vias {
            for l in lines where items[l].mergeStatus == .mergedInUse {
                _ = Topology.optimiseTraceInVia(&items[l].line, center: items[v].position, radius: items[v].viaRadius)
            }
        }
        // optimiseTracesInPads
        for p in pads {
            let pad = items[p]
            var polygon: PolySet??
            func shape() -> PolySet? {
                if polygon == nil { polygon = .some(pad.polygon?()) }
                return polygon!
            }
            for l in lines where items[l].mergeStatus == .mergedInUse {
                let layer = items[l].layerStart
                _ = Topology.optimiseTraceInPad(&items[l].line, padPosition: pad.position, flashed: pad.flashed.contains(layer), shape)
            }
        }
        var stats = Stats()
        for item in items where item.mergeStatus != .mergedRetired {
            switch item.kind {
            case .line:
                let length = item.line.length
                stats.trackLength += length
                if layerDetail { stats.layerLengths[item.layerStart, default: 0] += length }
            case .via:
                guard useHeight else { continue }
                // (KiCad adds each height to its int)
                stats.viaLength += stackupHeight(item.layerStart, item.layerEnd)
                stats.numVias += 1
            case .pad:
                stats.padToDieLength += item.padToDie
                stats.numPads += 1
            }
        }
        return stats
    }

    /// optimiseVias: each via's layers those of the lines that end in it (at its centre, or in its copper on their
    /// layer) and of a pad it is in (the pad's side), from the upper to the lower; a via nothing ends in on its top
    /// layer alone
    func optimiseVias(_ items: inout [Item], _ vias: [Int], _ linesAt: [IPoint: [Int]]) {
        for v in vias {
            let via = items[v]
            var connected = Set(linesAt[via.position] ?? [])
            let r = via.viaRadius
            for (pos, set) in linesAt where pos != via.position {
                let d = (pos - via.position).squaredNorm
                guard d <= r * r else { continue }
                // (the via's copper on the line's layer: a circle of its radius, collided by a point at no clearance)
                for l in set where d == 0 || d < r * r { connected.insert(l) }
            }
            var span = Set(connected.map { items[$0].layerStart })
            if let side = via.coincidentPadSide { span.insert(side) }
            if let top = span.min(), let bottom = span.max() {
                items[v].setLayers(top, bottom)
            } else {
                items[v].setLayers(via.viaLayers.start, via.viaLayers.start)
            }
        }
    }

    /// mergeLines: each line not yet merged joined to the lines that go on from its ends, where exactly two lines of
    /// its layer end there (more is a branch), until none go on
    func mergeLines(_ items: inout [Item], _ lines: [Int], _ linesAt: [IPoint: [Int]]) {
        func tryMerge(_ atStart: Bool, _ pos: IPoint, _ primary: Int) -> Bool {
            guard let bucket = linesAt[pos] else { return false }
            var toMerge: Int?
            var sameLayer = 0
            for i in bucket where items[i].layerStart == items[primary].layerStart {
                sameLayer += 1
                if i != primary && items[i].mergeStatus == .unmerged { toMerge = i }
            }
            guard sameLayer == 2, let other = toMerge else { return false }
            items[other].mergeStatus = .mergedRetired
            let secondary = items[other].line
            if atStart {
                var merged = secondary.point(0) == items[primary].line.point(0) ? secondary.reversed() : secondary
                merged.append(items[primary].line)
                items[primary].line = merged
            } else if secondary.point(0) == items[primary].line.lastPoint {
                items[primary].line.append(secondary)
            } else {
                items[primary].line.append(secondary.reversed())
            }
            return true
        }
        for primary in lines where items[primary].mergeStatus == .unmerged {
            items[primary].mergeStatus = .mergedInUse
            var complete = false
            while !complete {
                guard items[primary].line.pointCount > 0 else { break }
                let startPos = items[primary].line.point(0)
                let endPos = items[primary].line.lastPoint
                let startMerged = tryMerge(true, startPos, primary)
                let endMerged = tryMerge(false, endPos, primary)
                complete = !startMerged && !endMerged
            }
        }
    }
}

/// KiCad's Net Inspector (PCB_NET_INSPECTOR_PANEL) of a board: each net's pads, vias and lengths, as KiCad measures
/// them, and the panel's list of them: filtered by name, grouped by net class and by the user's rules, sorted by a
/// column, each value as the panel writes it
public struct NetInspector {
    /// A net's row (LIST_ITEM): its name, net class and lengths, nm
    public struct Net: Identifiable, Sendable {
        public var code: Int
        public var name: String
        public var netClass: String
        public var stats: LengthCalculation.Stats
        public var id: Int { code }
    }

    /// The model's columns (COLUMN_NAME... COLUMN_PAD_COUNT), then one for each copper layer
    public enum Column: Hashable, Sendable {
        case name, netClass, totalLength, viaCount, viaLength, trackLength, dieLength, padCount
        /// A copper layer's length of tracks (a router layer)
        case layer(Int)

        public static let fixed: [Column] = [.name, .netClass, .totalLength, .viaCount, .viaLength, .trackLength, .dieLength, .padCount]
    }

    /// Every net of the board but the "no net" net, by its code, with its lengths (calculateNets)
    public private(set) var nets: [Net] = []
    /// The board's copper layers as the columns have them (in the order of KiCad's layer ids: F.Cu, B.Cu, In1.Cu...),
    /// each a router layer and its name (BOARD::GetLayerName: the user's name for it, if it has one)
    public private(set) var layers: [(layer: Int, name: String)] = []
    /// The model's columns, in their order
    public var columns: [Column] { Column.fixed + layers.map { .layer($0.layer) } }
    /// The titles of the model's columns, as the panel heads them (lengths, not delays)
    public var titles: [String] {
        ["Name", "Netclass", "Total Length", "Via Count", "Via Length", "Track Length", "Die Length", "Pad Count"] + layers.map(\.name)
    }

    private var calculation: LengthCalculation
    /// The connectivity's tracks, arcs, vias and pads (relevantConnectivityItems), each as an item of the calculation,
    /// with its net and its board item's id, in the connectivity's order
    private var cnItems: [(item: LengthCalculation.Item, net: Int, uuid: String, serial: Int)] = []
    /// Which of them touch which (the connectivity's), by their place in `cnItems`
    private var touching: [[Int]] = []
    /// Each net's items, by their place in `cnItems`, in the order they are measured in
    private var netMembers: [Int: [Int]] = [:]

    /// The net inspector of `board`, its project's settings in `project` (net classes, whether via heights count)
    public init(board: KiCadBoard, project: [String: Any]? = nil) {
        let drc = BoardDRC(board: board, project: project)
        let world = drc.world
        let rules = ((project?["board"] as? [String: Any])?["design_settings"] as? [String: Any])?["rules"] as? [String: Any]
        let useHeight = (rules?["use_height_for_length_calcs"] as? Bool) ?? true
        calculation = LengthCalculation(heights: Stackup.heights(board, project: project, layerIndex: world.layerIndex,
                                                                 copperLayers: world.copperLayers), useHeight: useHeight)
        // the columns: the board's copper layers, by its own names for them
        var names: [Int: String] = [:]
        for entry in board.root["layers"]?.items ?? [] {
            guard let canonical = entry.text(at: 1), let l = world.layerIndex[canonical] else { continue }
            let user = entry.text(at: 3) ?? ""
            names[l] = user.isEmpty ? canonical : user
        }
        layers = drc.kicadLayerOrder.map { ($0, names[$0] ?? BoardStackup.copperNames(world.copperLayers)[$0]) }

        // the connectivity, as KiCad builds it reading the board (the nets it propagates are the items' nets)
        let copper = drc.makeCopper()
        let cn = drc.buildConnectivity(copper)
        let fps = board.root.all("footprint")
        var padNodes: [ObjectIdentifier: (fp: SExpr, pad: SExpr)] = [:]
        for (i, fp) in fps.enumerated() {
            for (j, node) in fp.all("pad").enumerated() where i < copper.footprintPads.count && j < copper.footprintPads[i].count {
                padNodes[ObjectIdentifier(copper.footprintPads[i][j])] = (fp, node)
            }
        }
        var index: [ObjectIdentifier: Int] = [:]
        var relevant: [BoardDRC.CNItem] = []
        for it in cn.items where !it.isZone {
            let parent = it.parent
            var item: LengthCalculation.Item
            switch parent.kind {
            case .track:
                item = .line(LineChain([parent.trackStart, parent.trackEnd]), layer: parent.layers.first ?? 0)
            case .arc:
                let arc = ShapeArc(start: parent.trackStart, mid: parent.trackMid, end: parent.trackEnd, width: parent.trackWidth)
                item = .line(LineChain(arc: arc), layer: parent.layers.first ?? 0)
            case .via:
                guard let v = parent.via else { continue }
                item = LengthCalculation.Item(kind: .via)
                item.position = v.start
                item.viaRadius = v.diameter / 2
                item.viaLayers = v.layers
                item.setLayers(v.layers.start, v.layers.end)
            case .pad:
                guard let p = parent.pad else { continue }
                item = LengthCalculation.Item(kind: .pad)
                item.position = p.pad.pos
                item.flashed = parent.flashed
                let nodes = padNodes[ObjectIdentifier(parent)]
                item.padToDie = nodes.flatMap { $0.pad["die_length"] }.map { BoardWorld.iu($0, 0) } ?? 0
                switch p.pad.attribute {
                case .smd, .conn:
                    item.padSideLayer = world.copper(p.pad.layers).min() ?? 0
                case .pth, .npth:
                    item.padSideLayer = nodes?.fp.value("layer") == "B.Cu" ? world.copperLayers - 1 : 0
                }
                let primitives = p.primitives
                item.polygon = { world.padPolygon(p.pad, primitives: primitives, errorLocation: .inside) }
                let lmsk = world.copper(p.pad.layers)
                item.setLayers(lmsk.min() ?? 0, lmsk.count > 1 ? lmsk.max() ?? 0 : lmsk.min() ?? 0)
            default:
                continue
            }
            index[ObjectIdentifier(it)] = cnItems.count
            cnItems.append((item, it.net, parent.uuid, it.serial))
            relevant.append(it)
        }
        touching = relevant.map { it in it.connected.compactMap { index[ObjectIdentifier($0)] } }
        for (k, it) in relevant.enumerated() where cnItems[k].item.kind == .via {
            var sides: [Int] = []
            for pad in it.connected where pad.parent.kind == .pad {
                if let p = index[ObjectIdentifier(pad)], !sides.contains(cnItems[p].item.padSideLayer) {
                    sides.append(cnItems[p].item.padSideLayer)
                }
            }
            cnItems[k].item.coincidentPadSide = sides.first
            cnItems[k].item.coincidentPadSides = sides
        }

        // calculateNets: every net's items, in the order std::ranges::sort leaves the connectivity's items in sorting
        // them by net (libstdc++'s introsort, which does not keep the order of items of a net), each net's lengths
        // with each layer's (a net of no tracks, vias or pads has no row)
        var sorted = Array(cnItems.indices)
        Clipper.introSort(&sorted) { cnItems[$0].net < cnItems[$1].net }
        var byNet: [Int: [Int]] = [:]
        for k in sorted where cnItems[k].net > 0 { byNet[cnItems[k].net, default: []].append(k) }
        netMembers = byNet
        for (code, name) in world.netNames.sorted(by: { $0.key < $1.key }) where code > 0 {
            guard let members = byNet[code] else { continue }
            let stats = measure(members, layerDetail: true)
            nets.append(Net(code: code, name: name, netClass: drc.netClasses.effective(name).name, stats: stats))
        }
    }

    /// The lengths of these items (places in `cnItems`)
    private func measure(_ members: [Int], layerDetail: Bool) -> LengthCalculation.Stats {
        var items = members.map { cnItems[$0].item }
        return calculation.calculate(&items, layerDetail: layerDetail)
    }

    /// The lengths a net (by its code) comes to with each other first pad its vias joined to pads of different sides
    /// can have (at most `limit` of them): KiCad takes the pad first in memory, and its pads' places there differ from
    /// one run of it to another
    func alternatives(_ code: Int, limit: Int = 256) -> [LengthCalculation.Stats] {
        guard let members = netMembers[code] else { return [] }
        let choices = members.filter { cnItems[$0].item.coincidentPadSides.count > 1 }
        var out: [LengthCalculation.Stats] = []
        var pick = [Int](repeating: 0, count: choices.count)
        while out.count < limit {
            var items = members.map { cnItems[$0].item }
            for (c, k) in choices.enumerated() {
                let i = members.firstIndex(of: k)!
                items[i].coincidentPadSide = items[i].coincidentPadSides[pick[c]]
            }
            out.append(calculation.calculate(&items, layerDetail: true))
            // (the next choice, as a number of mixed radix counts)
            var c = 0
            while c < choices.count {
                pick[c] += 1
                if pick[c] < cnItems[choices[c]].item.coincidentPadSides.count { break }
                pick[c] = 0
                c += 1
            }
            if c == choices.count { break }
        }
        return out
    }

    /// A net's lengths (by its code) replaced by others it can come to (one of `alternatives`)
    mutating func adopt(_ code: Int, _ stats: LengthCalculation.Stats) {
        if let i = nets.firstIndex(where: { $0.code == code }) { nets[i].stats = stats }
    }

    /// BOARD::GetTrackLength of a track or arc (by its id): how many tracks, arcs, vias and pads of its net are
    /// connected to it, zones left out (CONNECTIVITY_DATA::GetConnectedItems( EXCLUDE_ZONES ): it among them), their
    /// length of tracks and vias, and their pads' lengths to their dies; nil for none
    public func trackLength(_ uuid: String) -> (items: Int, length: Int, padToDie: Int)? { trackLength(uuid, reorder: nil) }

    func trackLength(_ uuid: String, reorder: (([Int]) -> [Int])?) -> (items: Int, length: Int, padToDie: Int)? {
        guard let start = cnItems.firstIndex(where: { $0.uuid == uuid && $0.item.kind == .line }) else { return nil }
        let net = cnItems[start].net
        guard net > 0 else { return (0, 0, 0) }
        // (SearchClusters of the net: each cluster from the first of its items in the connectivity's order, as
        // KiCad's set of them is in the order of their places in memory, its items as a search from there finds them)
        var visited = Set<Int>()
        for root in cnItems.indices where cnItems[root].net == net && !visited.contains(root) {
            visited.insert(root)
            var queue = [root], head = 0
            while head < queue.count {
                let k = queue[head]
                head += 1
                for n in touching[k] where cnItems[n].net == net && visited.insert(n).inserted { queue.append(n) }
            }
            guard queue.contains(start) else { continue }
            let stats = measure(reorder?(queue) ?? queue, layerDetail: false)
            return (queue.count, stats.trackLength + stats.viaLength, stats.padToDieLength)
        }
        return nil
    }

    /// The lengths GetTrackLength can come to with the cluster's items in other orders (`orders` of them, shuffled):
    /// KiCad's order is that of their places in memory, and where a line is cut by vias at both its ends, whichever
    /// cuts it first changes its length by a few nanometres (an arc cut again comes out a little longer or shorter), as
    /// which line of a chain is the one the others are merged into does
    func trackLengths(_ uuid: String, orders: Int) -> Set<Int> {
        var rng = SystemRandomNumberGenerator()
        var out = Set<Int>()
        for _ in 0..<orders {
            let value = trackLength(uuid) { members in
                members.shuffled(using: &rng)
            }
            if let value { out.insert(value.length) }
        }
        return out
    }

    // MARK: - The panel's list

    /// The net inspector's settings (the project's local settings' net_inspector_panel, PANEL_NET_INSPECTOR_SETTINGS)
    public struct Settings: Equatable, Sendable {
        public var filterText = ""
        public var filterByNetName = true
        public var filterByNetclass = true
        public var groupByNetclass = false
        public var customGroupRules: [String] = []
        public var showZeroPadNets = false
        public var showUnconnectedNets = false
        /// The model column sorted by (-1: none, the name's then), and whether up
        public var sortingColumn = -1
        public var sortAscending = true

        public init() {}

        /// As KiCad's panel takes them from the local settings' net_inspector_panel as it shows a board (its
        /// show_unconnected_nets is written, but not read back: the panel starts without them each time)
        public init(localSettings json: KiCadJSON?) {
            let p = json?["net_inspector_panel"]
            filterText = p?["filter_text"]?.string ?? ""
            filterByNetName = p?["filter_by_net_name"]?.bool ?? true
            filterByNetclass = p?["filter_by_netclass"]?.bool ?? true
            groupByNetclass = p?["group_by_netclass"]?.bool ?? false
            customGroupRules = (p?["custom_group_rules"]?.array ?? []).compactMap(\.string)
            showZeroPadNets = p?["show_zero_pad_nets"]?.bool ?? false
            sortingColumn = p?["sorting_column"]?.int ?? -1
            sortAscending = p?["sort_ascending"]?.bool ?? true
        }

        /// The settings written back into the local settings' net_inspector_panel (SaveSettings)
        public func write(into json: inout KiCadJSON) {
            json[path: "net_inspector_panel.filter_text"] = .string(filterText)
            json[path: "net_inspector_panel.filter_by_net_name"] = .bool(filterByNetName)
            json[path: "net_inspector_panel.filter_by_netclass"] = .bool(filterByNetclass)
            json[path: "net_inspector_panel.group_by_netclass"] = .bool(groupByNetclass)
            json[path: "net_inspector_panel.custom_group_rules"] = .array(customGroupRules.map { .string($0) })
            json[path: "net_inspector_panel.show_zero_pad_nets"] = .bool(showZeroPadNets)
            json[path: "net_inspector_panel.show_unconnected_nets"] = .bool(showUnconnectedNets)
            json[path: "net_inspector_panel.sorting_column"] = .integer(Int64(sortingColumn))
            json[path: "net_inspector_panel.sort_ascending"] = .bool(sortAscending)
        }
    }

    /// A row of the list: a net's, or a group's (LIST_ITEM: a net class's or a custom rule's, its nets' sums)
    public struct Row: Identifiable, Sendable {
        public enum Group: Equatable, Sendable { case netClass(String), custom(String) }
        public var net: Net?
        public var group: Group?
        public var stats: LengthCalculation.Stats
        public var children: [Row] = []
        /// The group's number among the groups (its place as made), or the net's code
        public var number: Int

        public var id: String { group.map { "group \($0)" } ?? "net \(net?.code ?? 0)" }
        public var isGroup: Bool { group != nil }

        /// The name shown (GetValue of COLUMN_NAME): a group's kind and name, else the net's
        public var name: String {
            switch group {
            case .netClass(let n): return "Netclass: " + n
            case .custom(let n): return "Custom: " + n
            case nil: return net?.name ?? ""
            }
        }
    }

    /// netFilterMatches: never the "no net" net; with a filter text, a net whose class's name (if filtered by) or
    /// name (if filtered by) holds it, case aside; nets of unconnected pads only where they are shown
    public static func matches(_ net: Net, _ settings: Settings) -> Bool {
        guard net.code > 0 else { return false }
        let filter = settings.filterText.uppercased()
        let name = net.name.uppercased()
        var matched = filter.isEmpty
        if !matched && settings.filterByNetclass && net.netClass.uppercased().contains(filter) { matched = true }
        if !matched && settings.filterByNetName && name.contains(filter) { matched = true }
        if matched && !settings.showUnconnectedNets { matched = !name.hasPrefix("UNCONNECTED-(") }
        return matched
    }

    /// The list as the panel builds it (buildNetsList): the nets the filter lets through (those of no pads left out
    /// unless shown), each in the first custom group whose rule it matches, else in its net class's group where
    /// grouped by net class; the groups first (the custom ones, then the net classes' as they come), each with its
    /// nets' sums; sorted by `settings`' column, each group's nets among themselves
    public func rows(_ settings: Settings) -> [Row] {
        var groups: [Row] = settings.customGroupRules.enumerated().map {
            Row(net: nil, group: .custom($1), stats: LengthCalculation.Stats(), number: $0)
        }
        var loose: [Row] = []
        let matchers = settings.customGroupRules.map(NetMatcher.init)
        for net in nets where Self.matches(net, settings) && (settings.showZeroPadNets || net.stats.numPads > 0) {
            let row = Row(net: net, group: nil, stats: net.stats, number: net.code)
            var target: Int?
            if let rule = matchers.firstIndex(where: { $0.find(net.name) }) {
                target = rule
            } else if settings.groupByNetclass {
                if let g = groups.firstIndex(where: { $0.group == .netClass(net.netClass) }) {
                    target = g
                } else {
                    groups.append(Row(net: nil, group: .netClass(net.netClass), stats: LengthCalculation.Stats(), number: groups.count))
                    target = groups.count - 1
                }
            }
            if let target {
                groups[target].children.append(row)
                groups[target].stats.add(net.stats)
            } else {
                loose.append(row)
            }
        }
        let column = settings.sortingColumn >= 0 && settings.sortingColumn < columns.count ? settings.sortingColumn : 0
        let ascending = settings.sortingColumn >= 0 && settings.sortingColumn < columns.count ? settings.sortAscending : true
        func sorted(_ rows: [Row]) -> [Row] {
            rows.sorted { compare($0, $1, column: column, ascending: ascending) < 0 }
        }
        for g in groups.indices { groups[g].children = sorted(groups[g].children) }
        return sorted(groups + loose)
    }

    /// A row's value in a column, as the panel shows it (GetValue): names as they are, counts as numbers, lengths
    /// in millimetres to four places, "mm" after them
    public func value(_ row: Row, column: Int) -> String {
        guard column >= 0 && column < columns.count else { return "" }
        let s = row.stats
        switch columns[column] {
        case .name: return row.name
        case .netClass: return row.net?.netClass ?? ""
        case .padCount: return String(s.numPads)
        case .viaCount: return String(s.numVias)
        case .viaLength: return Self.formatLength(s.viaLength)
        case .trackLength: return Self.formatLength(s.boardWireLength)
        case .dieLength: return Self.formatLength(s.padToDieLength)
        case .totalLength: return Self.formatLength(s.boardWireLength + s.viaLength + s.padToDieLength)
        case .layer(let l): return Self.formatLength(s.layerLengths[l] ?? 0)
        }
    }

    /// MessageTextFromValue of a length in millimetres ("%.4f mm")
    public static func formatLength(_ nm: Int) -> String { String(format: "%.4f mm", Double(nm) / 1e6) }

    /// DATA_MODEL::Compare: groups before nets; then by the column (names and net classes as ValueStringCompare
    /// compares them, numbers as numbers), up or down; the net names where equal
    public func compare(_ a: Row, _ b: Row, column: Int, ascending: Bool) -> Int {
        compare(a, b, column: column, ascending: ascending, lastResort: true)
    }

    /// The same, the rows' places in memory (which the port takes to be their numbers) left out where `lastResort` is
    /// off: 0 where only they would tell two rows apart
    func compare(_ a: Row, _ b: Row, column: Int, ascending: Bool, lastResort: Bool) -> Int {
        if a.isGroup && !b.isGroup { return -1 }
        if b.isGroup && !a.isGroup { return 1 }
        func names() -> Int { ascending ? Self.valueStringCompare(a.name, b.name) : Self.valueStringCompare(b.name, a.name) }
        func numbers(_ x: Int, _ y: Int) -> Int? {
            guard x != y else { return nil }
            return ascending ? (x < y ? -1 : 1) : (y < x ? -1 : 1)
        }
        let sa = a.stats, sb = b.stats
        var result: Int?
        switch column < columns.count ? columns[column] : .name {
        case .name:
            let r = names()
            if r != 0 { return r }
        case .netClass:
            let ca = a.net?.netClass ?? "", cb = b.net?.netClass ?? ""
            let r = ascending ? Self.valueStringCompare(ca, cb) : Self.valueStringCompare(cb, ca)
            if r != 0 { return r }
        case .padCount: result = numbers(sa.numPads, sb.numPads)
        case .viaCount: result = numbers(sa.numVias, sb.numVias)
        case .viaLength: result = numbers(sa.viaLength, sb.viaLength)
        case .trackLength: result = numbers(sa.boardWireLength, sb.boardWireLength)
        case .dieLength: result = numbers(sa.padToDieLength, sb.padToDieLength)
        case .totalLength:
            result = numbers(sa.boardWireLength + sa.viaLength + sa.padToDieLength, sb.boardWireLength + sb.viaLength + sb.padToDieLength)
        case .layer(let l): result = numbers(sa.layerLengths[l] ?? 0, sb.layerLengths[l] ?? 0)
        }
        if let result { return result }
        let r = names()
        if r != 0 { return r }
        // (KiCad's last resort is the rows' places in memory; the port's, their numbers)
        if !lastResort { return 0 }
        return ascending ? (a.number < b.number ? -1 : a.number > b.number ? 1 : 0) : (b.number < a.number ? -1 : b.number > a.number ? 1 : 0)
    }

    // MARK: - ValueStringCompare

    /// ValueStringCompare: the strings' beginnings (up to a number) compared case aside, then their numbers (a
    /// modifier after one, such as k or M, applied), then their ends case aside where no modifier was
    public static func valueStringCompare(_ a: String, _ b: String) -> Int {
        let (aBeg, aMid, aEnd) = splitString(Array(a.unicodeScalars))
        let (bBeg, bMid, bEnd) = splitString(Array(b.unicodeScalars))
        let c = cmpNoCase(aBeg, bBeg)
        if c != 0 { return c > 0 ? 1 : -1 }
        var first = cDouble(convertSeparators(aMid))
        var second = cDouble(convertSeparators(bMid))
        var modifier = false
        modifier = applyModifier(&first, aEnd) || modifier
        modifier = applyModifier(&second, bEnd) || modifier
        if first > second { return 1 }
        if first < second { return -1 }
        if !modifier { return cmpNoCase(aEnd, bEnd) }
        return 0
    }

    /// wxString::CmpNoCase: character by character, each lower-cased
    static func cmpNoCase(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        func lower(_ s: Unicode.Scalar) -> UInt32 { s.properties.lowercaseMapping.unicodeScalars.first?.value ?? s.value }
        for (p, q) in zip(a, b) {
            let x = lower(p), y = lower(q)
            if x != y { return x < y ? -1 : 1 }
        }
        return a.count < b.count ? -1 : a.count > b.count ? 1 : 0
    }

    static func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 48 && c.value <= 57 }

    /// NUMERIC_EVALUATOR::IsOldSchoolDecimalSeparator: a letter that stands for a decimal point with a multiplier
    /// (4k7)
    static let oldSchoolSeparators: Set<Unicode.Scalar> = ["p", "n", "\u{00B5}", "\u{03BC}", "u", "m", "L", "R", "F", "k", "K", "M", "G", "T"]

    /// SplitString: from the last digit back, the digits (with decimal separators, and the first old-school separator
    /// among them made a point and put before the end), what comes before them and what after
    static func splitString(_ s: [Unicode.Scalar]) -> ([Unicode.Scalar], [Unicode.Scalar], [Unicode.Scalar]) {
        guard !s.isEmpty else { return ([], [], []) }
        var ii = s.count - 1
        while ii >= 0 && !isDigit(s[ii]) { ii -= 1 }
        if ii < 0 { return (s, [], []) }
        var end = Array(s[(ii + 1)...])
        let position = ii + 1
        var infix: Unicode.Scalar?
        while ii >= 0 {
            let c = s[ii]
            if isDigit(c) {
                ii -= 1
            } else if infix == nil && oldSchoolSeparators.contains(c) {
                infix = c
                ii -= 1
            } else if c == "." || c == "," {
                ii -= 1
            } else {
                break
            }
        }
        var beginning: [Unicode.Scalar] = []
        var digits: [Unicode.Scalar]
        if ii < 0 {
            digits = Array(s[0..<position])
        } else {
            digits = Array(s[(ii + 1)..<position])
            beginning = Array(s[0...ii])
        }
        if let infix {
            digits = digits.map { $0 == infix ? "." : $0 }
            end = [infix] + end
        }
        return (beginning, digits, end)
    }

    /// convertSeparators: spaces taken out, a number's thousands separators and its decimal separator told apart
    /// (as far as they can be: else the C locale's point), the thousands' taken out and the decimal's made a point;
    /// as it was where it cannot be a number
    static func convertSeparators(_ input: [Unicode.Scalar]) -> [Unicode.Scalar] {
        let value = input.filter { $0 != " " }
        var ambiguous: Unicode.Scalar?, thousands: Unicode.Scalar?, decimal: Unicode.Scalar?
        var thousandsFound = false, decimalFound = false
        var digits = 0
        for ii in stride(from: value.count - 1, through: 0, by: -1) {
            let c = value[ii]
            if isDigit(c) {
                digits += 1
            } else if c == "." || c == "," {
                if decimal != nil || thousands != nil {
                    if c == decimal {
                        if thousandsFound || decimalFound { return value }
                        decimalFound = true
                    } else if c == thousands {
                        if digits != 3 { return value }
                        thousandsFound = true
                    }
                } else if let a = ambiguous {
                    if c == a {
                        thousands = a
                        thousandsFound = true
                        decimal = c == "." ? "," : "."
                    } else {
                        decimal = a
                        decimalFound = true
                        thousands = c
                        thousandsFound = true
                    }
                } else if (ii == 1 && value[0] == "0") || digits != 3 {
                    decimal = c
                    decimalFound = true
                    thousands = c == "." ? "," : "."
                } else {
                    ambiguous = c
                }
                digits = 0
            } else {
                digits = 0
            }
        }
        if decimal == nil && thousands == nil {
            decimal = "."
            thousands = ","
        }
        return value.compactMap { $0 == thousands ? nil : $0 == decimal ? "." : $0 }
    }

    /// wxString::ToCDouble: the whole of it a number in the C locale, else nothing (0)
    static func cDouble(_ s: [Unicode.Scalar]) -> Double {
        Double(String(String.UnicodeScalarView(s))) ?? 0
    }

    /// ApplyModifier: what follows a number, a multiplier (a, f, p, n, u, µ, m, L, R, F, k, K, M, G, T, P, E) and a
    /// unit (none, F, Hz, W, V, A or H) or a unit alone, applied; whether it was one
    static func applyModifier(_ value: inout Double, _ suffix: [Unicode.Scalar]) -> Bool {
        guard let first = suffix.first else { return false }
        let modifiers: Set<Unicode.Scalar> = ["a", "f", "p", "n", "u", "\u{00B5}", "\u{03BC}", "m", "L", "R", "F", "k", "K", "M", "G", "T", "P", "E"]
        var modifier: Unicode.Scalar = " "
        var units: [Unicode.Scalar]
        if modifiers.contains(first) {
            modifier = first
            units = Array(suffix.dropFirst())
        } else {
            units = suffix
        }
        // (wxString::Trim: the spaces on its right)
        while let last = units.last, last == " " || last == "\t" || last == "\n" || last == "\r" { units.removeLast() }
        let unit = String(String.UnicodeScalarView(units)).lowercased()
        if !units.isEmpty && !["f", "hz", "w", "v", "a", "h"].contains(unit) { return false }
        switch modifier {
        case "a": value *= 1.0e-18
        case "f": value *= 1.0e-15
        case "p": value *= 1.0e-12
        case "n": value *= 1.0e-9
        case "u", "\u{00B5}", "\u{03BC}": value *= 1.0e-6
        case "m", "L": value *= 1.0e-3
        case "k", "K": value *= 1.0e3
        case "M": value *= 1.0e6
        case "G": value *= 1.0e9
        case "T": value *= 1.0e12
        case "P": value *= 1.0e15
        case "E": value *= 1.0e18
        default: break
        }
        return true
    }
}

extension LengthCalculation.Stats {
    /// LIST_ITEM::GetBoardWireLength: the lengths of the layers' lines summed (the net inspector has them by layer)
    public var boardWireLength: Int { layerLengths.values.reduce(0, +) }

    /// A net's sums added to a group's (LIST_ITEM::SetParent)
    mutating func add(_ other: LengthCalculation.Stats) {
        numPads += other.numPads
        numVias += other.numVias
        viaLength += other.viaLength
        trackLength += other.trackLength
        padToDieLength += other.padToDieLength
        for (l, v) in other.layerLengths { layerLengths[l, default: 0] += v }
    }
}

/// EDA_COMBINED_MATCHER of a net (CTX_NET): a regular expression, a wildcard pattern and a part of a name, any of
/// which may find the name anywhere in it, case and all
struct NetMatcher {
    let regex: NSRegularExpression?
    let wildcard: NSRegularExpression?
    let pattern: String

    init(_ pattern: String) {
        self.pattern = pattern
        regex = Self.regex(pattern)
        // (EDA_PATTERN_MATCH_WILDCARD: ? any character, * any run of them, the rest as they are, as a regular
        // expression between slashes)
        var w = ""
        for ch in pattern {
            switch ch {
            case "?": w += "."
            case "*": w += ".*"
            default: w += ".*+?^${}()|[]/\\".contains(ch) ? "\\" + String(ch) : String(ch)
            }
        }
        wildcard = Self.regex("/" + w + "/")
    }

    /// EDA_PATTERN_MATCH_REGEX::SetPattern: only a pattern between ^ and $, or after a slash (and before one), is a
    /// regular expression; none where it does not compile
    static func regex(_ pattern: String) -> NSRegularExpression? {
        var p: String
        if pattern.hasPrefix("^") && pattern.hasSuffix("$") {
            p = pattern
        } else if pattern.hasPrefix("/") {
            p = String(pattern.dropFirst())
            if p.hasSuffix("/") { p.removeLast() }
        } else {
            return nil
        }
        guard quantifiersHaveOperands(p) else { return nil }
        return try? NSRegularExpression(pattern: p)
    }

    /// Whether every quantifier (*, +, ?, a bound) of a regular expression follows something it can repeat, as
    /// wxRegEx's advanced expressions (Henry Spencer's, Tcl's) require: one at the start, after ^, $, ( or |, or after
    /// another (but for the ? that makes it lazy) does not compile there, where ICU's would take it
    static func quantifiersHaveOperands(_ p: String) -> Bool {
        let c = Array(p)
        var i = 0
        var operand = false, quantified = false
        while i < c.count {
            let ch = c[i]
            switch ch {
            case "\\":
                i += 2
                operand = true
                quantified = false
                continue
            case "[":
                // (a bracket expression: a ] first in it is one of its characters)
                var j = i + 1
                if j < c.count && c[j] == "^" { j += 1 }
                if j < c.count && c[j] == "]" { j += 1 }
                while j < c.count && c[j] != "]" { j += 1 }
                i = j + 1
                operand = true
                quantified = false
                continue
            case "(":
                if i + 2 < c.count && c[i + 1] == "?" && ":=!".contains(c[i + 2]) { i += 2 }
                operand = false
                quantified = false
            case "|", "^", "$":
                operand = false
                quantified = false
            case "*", "+", "?":
                if quantified && ch == "?" {
                    quantified = false
                } else if !operand {
                    return false
                } else {
                    operand = false
                    quantified = true
                }
            case "{" where i + 1 < c.count && c[i + 1].isNumber:
                guard operand else { return false }
                while i < c.count && c[i] != "}" { i += 1 }
                operand = false
                quantified = true
            default:
                operand = true
                quantified = false
            }
            i += 1
        }
        return true
    }

    func find(_ name: String) -> Bool {
        let range = NSRange(name.startIndex..., in: name)
        if let regex, regex.firstMatch(in: name, range: range) != nil { return true }
        if let wildcard, wildcard.firstMatch(in: name, range: range) != nil { return true }
        // (EDA_PATTERN_MATCH_SUBSTR: wxString::Find, case and all; an empty pattern is found at the start)
        return pattern.isEmpty || name.contains(pattern)
    }
}
