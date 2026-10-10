import Foundation

/// The circuit built on perfboard: a board of holes on a 0.1 in grid, each with a copper pad of its own and nothing
/// joining them. The parts stand where the stripboard puts them (chips straddling a gap, parts across the rows, the
/// supplies along the top and bottom rows), and where a stripboard's piece of strip joins two or more pins, the
/// perfboard has a trail: their pads joined along the row on the copper side, by a length of tinned copper wire
/// soldered to each pad (or a run of solder, for neighbouring pads). The stripboard's wire links stay, on the parts'
/// side; its cuts are not needed. `verify` checks that the pads, trails and links connect exactly the circuit's nets.
public enum Perfboard {
    public typealias Hole = Stripboard.Hole
    public typealias Leg = Stripboard.Leg
    public typealias Placement = Stripboard.Placement
    public typealias Link = Stripboard.Link
    public typealias OffBoard = Stripboard.OffBoard

    /// Pads joined along a row on the copper side, from the hole at `from` to the one at `to` (columns, from ≤ to)
    public struct Trail: Hashable, Sendable {
        public var row: Int
        public var from: Int
        public var to: Int
        public var net: String

        /// The holes it runs over
        public var holes: [Hole] { (from...to).map { Hole(row: row, column: $0) } }
    }

    public struct Layout: Sendable {
        public var placements: [Placement] = []
        public var links: [Link] = []
        public var trails: [Trail] = []
        public var offBoard: [OffBoard] = []
        /// The rows that carry the supplies: row to net
        public var buses: [Int: String] = [:]
        public var bom: [Breadboard.Item] = []
        public var notes: [String] = []
        public var rows = 0
        public var columns = 0

        /// The net each hole in use is on: legs, wire ends, link ends
        public var nets: [Hole: String] {
            var result: [Hole: String] = [:]
            for placement in placements { for leg in placement.legs { result[leg.hole] = leg.net } }
            for item in offBoard { for wire in item.wires { result[wire.hole] = wire.net } }
            for link in links {
                result[link.from] = link.net
                result[link.to] = link.net
            }
            return result
        }

        /// The net of a hole: what is in it, or the trail that runs over its pad
        public func net(at hole: Hole) -> String? {
            if let net = nets[hole] { return net }
            return trails.first { $0.row == hole.row && $0.from <= hole.column && hole.column <= $0.to }?.net
        }
    }

    public static func layout(_ circuit: Circuit) -> Layout {
        layout(from: Stripboard.layout(circuit))
    }

    /// The stripboard's layout on perfboard: each piece of strip (between cuts) that joins two or more pins becomes a
    /// trail from the first of them to the last
    static func layout(from strip: Stripboard.Layout) -> Layout {
        var layout = Layout()
        layout.placements = strip.placements
        layout.links = strip.links
        layout.offBoard = strip.offBoard
        layout.rows = strip.rows
        layout.columns = strip.columns
        var cutsInRow: [Int: [Int]] = [:]
        for cut in strip.cuts { cutsInRow[cut.row, default: []].append(cut.column) }
        /// The piece of strip a hole is on: its row and how many cuts lie to its left
        func piece(_ hole: Hole) -> [Int] { [hole.row, (cutsInRow[hole.row] ?? []).filter { $0 < hole.column }.count] }
        var pins: [[Int]: [(column: Int, net: String)]] = [:]
        for (hole, net) in strip.nets where !net.isEmpty { pins[piece(hole), default: []].append((hole.column, net)) }
        for (key, list) in pins where list.count >= 2 {
            let columns = list.map(\.column)
            layout.trails.append(Trail(row: key[0], from: columns.min()!, to: columns.max()!, net: list[0].net))
        }
        layout.trails.sort { ($0.row, $0.from) < ($1.row, $1.from) }
        // a supply row carries its net where something is on it
        for (row, net) in strip.buses where layout.trails.contains(where: { $0.row == row }) || strip.nets.contains(where: { $0.key.row == row }) {
            layout.buses[row] = net
        }
        layout.notes = strip.notes.filter { !$0.hasPrefix("Cut the strips") }
        layout.notes.append("On the copper side, join the pads along each trail drawn: a length of tinned copper wire laid over "
                            + "the pads and soldered to each (a blob of solder will do for two neighbouring pads). Put the wire "
                            + "links on the parts' side. Then check with a meter that neighbouring trails are apart")
        let length = layout.trails.reduce(0) { $0 + $1.to - $1.from }
        layout.bom = strip.bom.filter { !$0.description.hasPrefix("stripboard") }
        layout.bom.append(Breadboard.Item(quantity: 1, description: "perfboard (pads on a 0.1 in grid), \(layout.rows) × \(layout.columns) holes or more",
                                          parts: []))
        if !layout.trails.isEmpty {
            layout.bom.append(Breadboard.Item(quantity: layout.trails.count,
                                              description: "trails of tinned copper wire, about \(String(format: "%.0f", Double(length) * 2.54 + Double(layout.trails.count) * 5)) mm in all",
                                              parts: []))
        }
        return layout
    }

    // MARK: - Checking

    /// What is wrong with a layout: a hole used twice or off the board, a trail running over a pad of another net, a
    /// net split between pads the board does not join, or two nets it joins. Empty when the board connects exactly the
    /// circuit's nets.
    public static func verify(_ layout: Layout) -> [String] {
        var problems: [String] = []
        var parent: [Hole: Hole] = [:]
        func find(_ h: Hole) -> Hole {
            var h = h
            while let p = parent[h], p != h { h = p }
            return h
        }
        func union(_ a: Hole, _ b: Hole) {
            if parent[a] == nil { parent[a] = a }
            if parent[b] == nil { parent[b] = b }
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        var ends: [(hole: Hole, net: String, what: String)] = []
        for placement in layout.placements {
            for leg in placement.legs { ends.append((leg.hole, leg.net, "\(placement.name) \(leg.name)")) }
        }
        for item in layout.offBoard { for wire in item.wires { ends.append((wire.hole, wire.net, "\(item.name) \(wire.name)")) } }
        for link in layout.links {
            ends.append((link.from, link.net, "link on \(link.net)"))
            ends.append((link.to, link.net, "link on \(link.net)"))
        }
        func onBoard(_ h: Hole) -> Bool { h.row >= 0 && h.row < layout.rows && h.column >= 0 && h.column < layout.columns }
        var occupied: [Hole: String] = [:]
        for end in ends {
            if !onBoard(end.hole) { problems.append("\(end.what) is off the board at \(end.hole)") }
            if let other = occupied[end.hole] { problems.append("\(end.hole) holds both \(other) and \(end.what)") }
            occupied[end.hole] = end.what
            union(end.hole, end.hole)
        }
        for link in layout.links { union(link.from, link.to) }
        for trail in layout.trails {
            if trail.from > trail.to || !onBoard(Hole(row: trail.row, column: trail.from)) || !onBoard(Hole(row: trail.row, column: trail.to)) {
                problems.append("The trail on \(trail.net) along row \(Stripboard.letters(trail.row)) is off the board")
                continue
            }
            // its pads are one node, with whatever is in them
            for hole in trail.holes { union(hole, Hole(row: trail.row, column: trail.from)) }
        }
        var netsOf: [Hole: Set<String>] = [:]
        var rootsOf: [String: Set<Hole>] = [:]
        for end in ends where !end.net.isEmpty {
            let root = find(end.hole)
            netsOf[root, default: []].insert(end.net)
            rootsOf[end.net, default: []].insert(root)
        }
        for trail in layout.trails {
            let root = find(Hole(row: trail.row, column: trail.from))
            if let nets = netsOf[root], !nets.contains(trail.net) {
                problems.append("The trail on \(trail.net) joins \(nets.sorted().joined(separator: ", "))")
            }
        }
        for end in ends where end.net.isEmpty {
            if let nets = netsOf[find(end.hole)], !nets.isEmpty { problems.append("\(end.what), a free pin, is joined to \(nets.sorted().joined(separator: ", "))") }
        }
        for (_, nets) in netsOf where nets.count > 1 {
            problems.append("The board joins nets that should be apart: \(nets.sorted().joined(separator: ", "))")
        }
        for (net, roots) in rootsOf where roots.count > 1 {
            problems.append("\(net) is in \(roots.count) places the board does not join")
        }
        return problems.sorted()
    }
}
