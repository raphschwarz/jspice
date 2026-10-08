import Foundation

/// The circuit built on stripboard (Veroboard): copper strips run along the rows, cut where one net must end and
/// another begin; parts stand across the strips, chips straddle a cut with each pin on a strip of its own, and wire
/// links join the pieces of strip that carry one net. The top strip and the bottom one or two carry the supplies.
///
/// The board is laid out in blocks of five holes along each strip, with a column between blocks where a strip can be
/// cut; a piece of strip is one block of one row (or a run of them on one net). The same packages, pinouts and
/// supplies as on a breadboard; pots, switches, sockets and supplies are wired from off the board, as in a box.
/// `verify` checks that the board connects exactly the circuit's nets.
public enum Stripboard {
    /// Strips on the board
    public static let rows = 25
    /// Holes in a block of strip
    static let span = 5

    public struct Hole: Hashable, Sendable, CustomStringConvertible {
        /// The strip, from 0 at the top
        public var row: Int
        /// The hole along it, from 0 at the left
        public var column: Int

        public init(row: Int, column: Int) {
            self.row = row
            self.column = column
        }

        /// Strips lettered from A at the top, holes numbered from 1 at the left, as on the board: "C12"
        public var description: String { Stripboard.letters(row) + "\(column + 1)" }
    }

    /// A strip's letters: A for the top one, … Z, AA, AB…
    public static func letters(_ row: Int) -> String {
        row < 26 ? String(Character(UnicodeScalar(UInt8(65 + row)))) : letters(row / 26 - 1) + letters(row % 26)
    }

    public struct Leg: Sendable {
        public var name: String
        public var hole: Hole
        public var net: String
    }

    public struct Placement: Sendable {
        public var name: String
        public var title: String
        public var style: Breadboard.Style
        public var legs: [Leg]
        public var note: String?
    }

    /// A wire link on the parts' side, joining two pieces of strip
    public struct Link: Sendable {
        public var from: Hole
        public var to: Hole
        public var net: String
    }

    public struct OffBoard: Sendable {
        public var name: String
        public var title: String
        public var wires: [Leg]
    }

    public struct Layout: Sendable {
        public var placements: [Placement] = []
        public var links: [Link] = []
        /// Holes where the strip is cut
        public var cuts: [Hole] = []
        public var offBoard: [OffBoard] = []
        /// The supply strips: row to net
        public var buses: [Int: String] = [:]
        public var bom: [Breadboard.Item] = []
        public var notes: [String] = []
        public var rows = Stripboard.rows
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

        /// The net of any hole: what is in it, or else what is on its piece of strip
        public func net(at hole: Hole) -> String? {
            if let net = nets[hole] { return net }
            if let net = buses[hole.row] { return net }
            let cuts = Set(self.cuts)
            for direction in [-1, 1] {
                var column = hole.column
                while column >= 0 && column < columns {
                    let h = Hole(row: hole.row, column: column)
                    if cuts.contains(h) { break }
                    if let net = nets[h], !net.isEmpty { return net }
                    column += direction
                }
            }
            return nil
        }
    }

    // MARK: - Laying out

    /// One block of one strip
    struct Piece: Hashable, Comparable {
        var block: Int
        var row: Int
        static func < (a: Piece, b: Piece) -> Bool { (a.block, a.row) < (b.block, b.row) }
    }

    static func columns(of block: Int) -> Range<Int> { block * (span + 1) ..< block * (span + 1) + span }
    /// The column between a block and the next, where strips are cut
    static func gap(after block: Int) -> Int { block * (span + 1) + span }

    /// The board as laid out so far: which net each piece of strip is for, and the holes in use
    struct Builder {
        var layout = Layout()
        var pieceNet: [Piece: String] = [:]
        var used = Set<Hole>()
        /// Each supply's strip
        var busRow: [String: Int] = [:]
        var signalRows: [Int] = []
        var blocks = 0

        func free(_ piece: Piece) -> [Int] {
            Stripboard.columns(of: piece.block).filter { !used.contains(Hole(row: piece.row, column: $0)) }
        }

        func empty(_ piece: Piece) -> Bool { pieceNet[piece] == nil && free(piece).count == span }

        mutating func touch(_ block: Int) { blocks = max(blocks, block + 1) }

        func pieces(of net: String) -> [Piece] { pieceNet.filter { $0.value == net }.map(\.key).sorted() }

        mutating func claim(_ piece: Piece, _ net: String) {
            pieceNet[piece] = net
            touch(piece.block)
        }

        /// The rows `net` offers in `block` with room for a leg (keeping two holes for links): its pieces, and its strip
        /// if it is a supply
        func rows(of net: String, in block: Int) -> [Int] {
            var rows = signalRows.filter { pieceNet[Piece(block: block, row: $0)] == net && free(Piece(block: block, row: $0)).count >= 3 }
            if let bus = busRow[net] { rows.append(bus) }
            return rows
        }

        /// A column of `block` where a part (or link) can lie from row `a` to row `b`: every hole it covers free, and
        /// each piece of strip it crosses left with two holes for its links
        func column(in block: Int, rows a: Int, _ b: Int) -> Int? {
            Stripboard.columns(of: block).first { c in
                (min(a, b)...max(a, b)).allSatisfy { r in
                    let piece = Piece(block: block, row: r)
                    return !used.contains(Hole(row: r, column: c))
                        && (r == a || r == b || pieceNet[piece] == nil || free(piece).count >= 3)
                }
            }
        }

        /// Marks the holes a part or link lying down a column covers, its ends' included
        mutating func cover(_ a: Hole, _ b: Hole) {
            guard a.column == b.column else {
                used.insert(a)
                used.insert(b)
                return
            }
            for r in min(a.row, b.row)...max(a.row, b.row) { used.insert(Hole(row: r, column: a.column)) }
        }

        /// An empty piece in `block` for a net, nearest `row`, at least `distance` rows from `away` and at most `reach`
        func emptyRow(in block: Int, near row: Int, away: Int? = nil, distance: Int = 0, reach: Int = .max) -> Int? {
            signalRows.filter { r in
                empty(Piece(block: block, row: r)) && away.map { abs(r - $0) >= distance && abs(r - $0) <= reach } ?? true
            }.min { abs($0 - row) < abs($1 - row) }
        }

        /// The first block from `start` where `count` neighbouring rows are empty in `width` blocks side by side, and
        /// the first of those rows (nearest the middle of the board)
        func room(_ count: Int, width: Int = 1, from start: Int = 0) -> (block: Int, row: Int) {
            let middle = (signalRows.first! + signalRows.last!) / 2
            var block = start
            while true {
                let starts = signalRows.filter { r in
                    (0..<count).allSatisfy { k in
                        signalRows.contains(r + k) && (0..<width).allSatisfy { empty(Piece(block: block + $0, row: r + k)) }
                    }
                }
                if let row = starts.min(by: { abs($0 + count / 2 - middle) < abs($1 + count / 2 - middle) }) { return (block, row) }
                block += 1
            }
        }

        /// A free hole on `net`: in its strip if it is a supply, in a piece of it with room, or a new piece near `block`
        mutating func hole(on net: String, near block: Int) -> Hole {
            if let bus = busRow[net] {
                for b in 0..<max(blocks, 1) {
                    if let c = Stripboard.columns(of: (block + b) % max(blocks, 1)).first(where: { !used.contains(Hole(row: bus, column: $0)) }) {
                        let hole = Hole(row: bus, column: c)
                        used.insert(hole)
                        return hole
                    }
                }
            }
            let near = pieces(of: net).filter { free($0).count >= 3 }.min { abs($0.block - block) < abs($1.block - block) }
            let piece: Piece
            if let near {
                piece = near
            } else {
                let (b, row) = room(1, from: max(block, 0))
                piece = Piece(block: b, row: row)
                claim(piece, net)
            }
            let hole = Hole(row: piece.row, column: free(piece)[0])
            used.insert(hole)
            return hole
        }

        /// Takes a free hole of the piece: the leftmost, or the rightmost
        mutating func take(_ piece: Piece, right: Bool = false) -> Hole? {
            let columns = free(piece)
            guard let c = right ? columns.last : columns.first else { return nil }
            let hole = Hole(row: piece.row, column: c)
            used.insert(hole)
            return hole
        }
    }

    /// How far apart a part's legs must be, in strips: a resistor or diode lies flat across three
    static func minimumSpan(_ style: Breadboard.Style) -> Int {
        switch style {
        case .resistor, .diode, .zener, .inductor: return 3
        case .lamp: return 2
        default: return 1
        }
    }

    /// Lays the circuit out on stripboard
    public static func layout(_ circuit: Circuit) -> Layout {
        let plan = Breadboard.plan(circuit)
        let voltages = plan.voltages
        var b = Builder()

        // the supplies' strips: the most used positive at the top, ground at the bottom, a second supply above ground
        let first = plan.positives.first
        let second = plan.negatives.first ?? plan.positives.dropFirst().first
        var bottom = Stripboard.rows - 1
        b.busRow["GND"] = bottom
        b.layout.buses[bottom] = "GND"
        if let second {
            bottom -= 1
            b.busRow[second.net] = bottom
            b.layout.buses[bottom] = second.net
        }
        var top = 0
        if let first {
            b.busRow[first.net] = 0
            b.layout.buses[0] = first.net
            top = 1
        }
        b.signalRows = Array(top..<bottom)
        b.layout.notes += plan.supplyNotes
        var unique = 0
        /// A net of its own for a free pin, so its strip is cut from its neighbours
        func freePin() -> String {
            unique += 1
            return "\u{0}\(unique)"
        }

        // chips across a cut, pin 1 at the top left, the notch towards the top: pins down the left, back up the right
        for pack in plan.packs {
            let p = pack.package
            let half = p.pins / 2
            let (block, row) = b.room(half, width: 2)
            let left = Stripboard.columns(of: block).last!, right = left + 3
            let netOfPin = plan.pins(pack)
            var legs: [Leg] = []
            for pin in 1...p.pins {
                let onLeft = pin <= half
                let r = onLeft ? row + pin - 1 : row + p.pins - pin
                let hole = Hole(row: r, column: onLeft ? left : right)
                b.used.insert(hole)
                let net = netOfPin[pin]
                b.claim(Piece(block: onLeft ? block : block + 1, row: r), net?.net ?? freePin())
                legs.append(Leg(name: "\(pin) \(net?.label ?? p.labels[pin] ?? "—")", hole: hole, net: net?.net ?? ""))
                // the hole under the chip, between its rows
                if !onLeft { b.used.insert(Hole(row: r, column: right - 1)) }
            }
            b.layout.placements.append(Placement(name: pack.name, title: plan.title(pack), style: .dip(pins: p.pins), legs: legs, note: plan.note(pack)))
        }

        // transistors and vactrols: their legs down one column, across neighbouring strips
        var offParts: [NetlistPart] = []
        for part in plan.inline {
            if part.kind == .potentiometer {
                offParts.append(part)
                continue
            }
            let (order, style, title, note) = Breadboard.inline(part, facing: "to the left, legs from the top")
            let (block, row) = b.room(order.count)
            let column = Stripboard.columns(of: block).lowerBound + span / 2
            var legs: [Leg] = []
            for (k, terminal) in order.enumerated() {
                let hole = Hole(row: row + k, column: column)
                b.used.insert(hole)
                b.claim(Piece(block: block, row: row + k), part.connections[terminal] ?? freePin())
                legs.append(Leg(name: terminal, hole: hole, net: part.connections[terminal] ?? ""))
            }
            b.layout.placements.append(Placement(name: part.name, title: title, style: style, legs: legs,
                                                 note: part.kind == .vactrol ? (note ?? "") + "; its leads bent to one column" : note))
        }

        // two-lead parts across the strips: both legs in one column, on pieces of their nets
        for part in plan.twoLead {
            if part.kind == .toggleSwitch || part.kind == .pushButton {
                offParts.append(part)
                continue
            }
            let terminals = part.kind.terminalNames
            guard let n0 = part.connections[terminals[0]], let n1 = part.connections[terminals[1]] else {
                b.layout.notes.append("\(part.name) is not connected at both ends: left off the board")
                continue
            }
            let (style, title, described) = Breadboard.describe(part, voltages)
            var note = described
            let middle = (b.signalRows.first! + b.signalRows.last!) / 2
            let least = minimumSpan(style), reach = max(least + 5, 8)
            var holes: (Hole, Hole)?
            // where both nets are already, close enough
            var best: (block: Int, r0: Int, r1: Int, column: Int)?
            for block in 0..<b.blocks {
                for r0 in b.rows(of: n0, in: block) {
                    for r1 in b.rows(of: n1, in: block) where abs(r0 - r1) >= least && abs(r0 - r1) <= reach {
                        guard let c = b.column(in: block, rows: r0, r1) else { continue }
                        if best == nil || abs(r0 - r1) < abs(best!.r0 - best!.r1) { best = (block, r0, r1, c) }
                    }
                }
            }
            if let best {
                holes = (Hole(row: best.r0, column: best.column), Hole(row: best.r1, column: best.column))
            }
            // beside a piece of one net (or its supply strip), with a new piece of the other
            if holes == nil {
                search: for (anchor, other, swapped) in [(n0, n1, false), (n1, n0, true)] {
                    for block in (0..<b.blocks).reversed() {
                        for r in b.rows(of: anchor, in: block) {
                            guard let row = b.emptyRow(in: block, near: r < middle ? r + least : r - least, away: r, distance: least, reach: reach),
                                  let c = b.column(in: block, rows: r, row) else { continue }
                            b.claim(Piece(block: block, row: row), other)
                            let a = Hole(row: r, column: c), o = Hole(row: row, column: c)
                            holes = swapped ? (o, a) : (a, o)
                            break search
                        }
                    }
                }
            }
            // a block of their own: a supply's strip, or a new piece, the first near the other's supply or in the middle
            var block = b.blocks
            while holes == nil {
                var r0 = b.busRow[n0], r1 = b.busRow[n1]
                // two supplies far apart: a piece of the second beside the first's strip
                if let a = r0, let c = r1, abs(a - c) > reach { r1 = nil }
                let new0 = r0 == nil, new1 = r1 == nil
                if r0 == nil { r0 = b.emptyRow(in: block, near: r1.map { $0 < middle ? $0 + least : $0 - least } ?? middle, away: r1, distance: least) }
                if r1 == nil, let a = r0 { r1 = b.emptyRow(in: block, near: a < middle ? a + least : a - least, away: a, distance: least) }
                if let a = r0, let c = r1, let column = b.column(in: block, rows: a, c) {
                    if new0 { b.claim(Piece(block: block, row: a), n0) }
                    if new1 { b.claim(Piece(block: block, row: c), n1) }
                    b.touch(block)
                    holes = (Hole(row: a, column: column), Hole(row: c, column: column))
                }
                block += 1
            }
            let (h0, h1) = holes!
            b.cover(h0, h1)
            var legs = [Leg(name: terminals[0], hole: h0, net: n0), Leg(name: terminals[1], hole: h1, net: n1)]
            if style == .electrolytic {
                // + on the higher voltage
                let plus = (voltages[n1] ?? 0) > (voltages[n0] ?? 0) ? 1 : 0
                legs = [Leg(name: "+", hole: legs[plus].hole, net: legs[plus].net), Leg(name: "−", hole: legs[1 - plus].hole, net: legs[1 - plus].net)]
            }
            if abs(h0.row - h1.row) > 6 { note = (note.map { $0 + ". " } ?? "") + "Long leads: sleeve them" }
            b.layout.placements.append(Placement(name: part.name, title: title, style: style, legs: legs, note: note))
        }

        // off the board: supplies, pots, switches, sources, speakers, modules, each wire to a hole of its net
        for supply in plan.wiredSupplies {
            let plus = b.hole(on: supply.net, near: b.blocks - 1)
            let ground = b.hole(on: "GND", near: b.blocks - 1)
            b.layout.offBoard.append(OffBoard(name: supply.name, title: "Power supply, \(SI.format(supply.volts, unit: "V"))",
                                              wires: [Leg(name: supply.volts > 0 ? "+" : "−", hole: plus, net: supply.net), Leg(name: "common", hole: ground, net: "GND")]))
        }
        for part in offParts + plan.offBoardParts {
            var wires: [Leg] = []
            let near = b.pieces(of: part.connections.values.first { b.busRow[$0] == nil } ?? "").first?.block ?? 0
            for terminal in part.kind == .potentiometer ? ["a", "wiper", "b"] : part.terminalNames {
                guard let net = part.connections[terminal] else { continue }
                let name = part.kind == .potentiometer ? ["a": "lug 1", "wiper": "lug 2", "b": "lug 3"][terminal] ?? terminal : terminal
                wires.append(Leg(name: name, hole: b.hole(on: net, near: near), net: net))
            }
            let title: String
            switch part.kind {
            case .potentiometer: title = Breadboard.inline(part, facing: "").title + " potentiometer, on the panel"
            case .toggleSwitch: title = "switch (SPST), on the panel"
            case .pushButton: title = "push button, on the panel"
            default: title = Breadboard.offBoardTitle(part)
            }
            b.layout.offBoard.append(OffBoard(name: part.name, title: title, wires: wires))
        }

        // the cuts: where a strip's net changes (a piece with nothing on it goes with the one to its left)
        for row in b.signalRows {
            var last: String?
            for block in 0..<b.blocks {
                guard let net = b.pieceNet[Piece(block: block, row: row)] else { continue }
                if let last, last != net { b.layout.cuts.append(Hole(row: row, column: gap(after: block - 1))) }
                last = net
            }
        }

        // links: each net's pieces of strip, as the cuts leave them, joined in a chain; a supply's to its strip
        let cuts = Set(b.layout.cuts)
        /// The run of strip a piece is in: its row, and the cuts before it
        func run(_ piece: Piece) -> Hole {
            Hole(row: piece.row, column: -1 - (0..<piece.block).filter { cuts.contains(Hole(row: piece.row, column: gap(after: $0))) }.count)
        }
        for net in Set(b.pieceNet.values).sorted() where !net.hasPrefix("\u{0}") {
            var groups: [Hole: [Piece]] = [:]
            for piece in b.pieces(of: net) { groups[run(piece), default: []].append(piece) }
            let ordered = groups.values.map { $0.sorted() }.sorted { $0[0] < $1[0] }
            /// A hole in one of the pieces and one in the supply's strip, down one column
            func linkHoles(_ a: [Piece], toRow bus: Int) -> (Hole, Hole)? {
                for piece in a {
                    if let c = b.column(in: piece.block, rows: piece.row, bus) { return (Hole(row: piece.row, column: c), Hole(row: bus, column: c)) }
                }
                return nil
            }
            if let bus = b.busRow[net] {
                for group in ordered {
                    if let (from, to) = linkHoles(group, toRow: bus) {
                        b.cover(from, to)
                        b.layout.links.append(Link(from: from, to: to, net: net))
                    } else if let piece = group.first(where: { !b.free($0).isEmpty }), let from = b.take(piece) {
                        let to = b.hole(on: net, near: piece.block)
                        b.layout.links.append(Link(from: from, to: to, net: net))
                    } else {
                        b.layout.notes.append("No room for a link from \(net) to its strip")
                    }
                }
                continue
            }
            for (a, c) in zip(ordered, ordered.dropFirst()) {
                // the nearest two pieces of the two runs, in one column if they share a block
                var pair: (Hole, Hole)?
                for pa in a { for pc in c where pa.block == pc.block {
                    if pair == nil, let column = b.column(in: pa.block, rows: pa.row, pc.row) {
                        pair = (Hole(row: pa.row, column: column), Hole(row: pc.row, column: column))
                    }
                } }
                if let (from, to) = pair {
                    b.cover(from, to)
                    b.layout.links.append(Link(from: from, to: to, net: net))
                    continue
                }
                guard let pa = a.last(where: { !b.free($0).isEmpty }), let pc = c.first(where: { !b.free($0).isEmpty }),
                      let from = b.take(pa, right: true), let to = b.take(pc) else {
                    b.layout.notes.append("No room for a link on \(net)")
                    continue
                }
                b.layout.links.append(Link(from: from, to: to, net: net))
            }
        }

        b.layout.columns = max(b.blocks * (span + 1) - 1, span)
        b.layout.notes.append("Cut the strips at the holes marked ✕ (a 3.5 mm drill bit turned by hand), then check with a meter that neighbouring strips are apart")
        b.layout.bom = Breadboard.billOfMaterials(b.layout.placements.map { ($0.name, $0.title, $0.style) },
                                                  offBoard: b.layout.offBoard.map { ($0.name, $0.title) },
                                                  wires: b.layout.links.count, wireName: "wire links")
        b.layout.bom.append(Breadboard.Item(quantity: 1, description: "stripboard, \(Stripboard.rows) strips × \(b.layout.columns) holes", parts: []))
        for pins in Set(plan.packs.map(\.package.pins)).sorted() {
            let names = plan.packs.filter { $0.package.pins == pins }.map(\.name)
            b.layout.bom.append(Breadboard.Item(quantity: names.count, description: "DIP-\(pins) socket", parts: names))
        }
        return b.layout
    }

    // MARK: - Checking

    /// What is wrong with a layout: a hole used twice, off the board or on a cut, a net split between pieces of strip
    /// the board does not join, or two nets it joins. Empty when the board connects exactly the circuit's nets.
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
        let cuts = Set(layout.cuts)
        var cutsInRow: [Int: [Int]] = [:]
        for cut in layout.cuts { cutsInRow[cut.row, default: []].append(cut.column) }
        /// The run of strip a hole is on, between cuts
        func strip(_ h: Hole) -> Hole { Hole(row: h.row, column: -1 - (cutsInRow[h.row] ?? []).filter { $0 < h.column }.count) }
        var ends: [(hole: Hole, net: String, what: String)] = []
        for placement in layout.placements {
            for leg in placement.legs { ends.append((leg.hole, leg.net, "\(placement.name) \(leg.name)")) }
        }
        for item in layout.offBoard { for wire in item.wires { ends.append((wire.hole, wire.net, "\(item.name) \(wire.name)")) } }
        for link in layout.links {
            ends.append((link.from, link.net, "link on \(link.net)"))
            ends.append((link.to, link.net, "link on \(link.net)"))
        }
        var occupied: [Hole: String] = [:]
        for end in ends {
            if end.hole.row < 0 || end.hole.row >= layout.rows || end.hole.column < 0 || end.hole.column >= layout.columns {
                problems.append("\(end.what) is off the board at \(end.hole)")
            }
            if cuts.contains(end.hole) { problems.append("\(end.what) is in \(end.hole), where the strip is cut") }
            if let other = occupied[end.hole] { problems.append("\(end.hole) holds both \(other) and \(end.what)") }
            occupied[end.hole] = end.what
            union(end.hole, strip(end.hole))
        }
        for link in layout.links { union(link.from, link.to) }
        var netsOf: [Hole: Set<String>] = [:]
        var rootsOf: [String: Set<Hole>] = [:]
        for end in ends where !end.net.isEmpty {
            let root = find(end.hole)
            netsOf[root, default: []].insert(end.net)
            rootsOf[end.net, default: []].insert(root)
        }
        // the supply strips carry their nets
        for (row, net) in layout.buses {
            let root = find(strip(Hole(row: row, column: 0)))
            if let nets = netsOf[root], !nets.contains(net) { problems.append("The \(net) strip carries \(nets.sorted().joined(separator: ", "))") }
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
