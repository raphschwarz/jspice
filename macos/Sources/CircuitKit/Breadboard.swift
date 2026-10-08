import Foundation

/// The circuit built on a solderless breadboard: which hole each leg of each part goes in, the jumper wires that join
/// the strips of one net, what goes on the power rails, what stays off the board (supplies, signal sources, speakers,
/// modules), and the bill of materials.
///
/// The board is a full-size one: 63 columns; in each, the five holes a–e (above the channel) are one strip and f–j
/// (below it) another; a + and a − rail run along the top and the bottom. Chips straddle the channel, pin 1 at the
/// bottom left. Parts that come several to a package (op-amps, gates, inverters, switches) are packed into as few
/// packages as their shared pins allow, and their supply pins wired to the rails. Every pin number comes from the
/// part's datasheet; `verify` checks that the board, as laid out, connects exactly the circuit's nets.
public enum Breadboard {
    public static let columns = 63

    public enum Rail: Int, CaseIterable, Hashable, Sendable {
        case topPositive, topNegative, bottomNegative, bottomPositive

        public var name: String {
            switch self {
            case .topPositive: return "top + rail"
            case .topNegative: return "top − rail"
            case .bottomNegative: return "bottom − rail"
            case .bottomPositive: return "bottom + rail"
            }
        }

        var top: Bool { self == .topPositive || self == .topNegative }
    }

    public enum Hole: Hashable, Sendable, CustomStringConvertible {
        /// Rows 0…4 are a–e (above the channel), 5…9 f–j (below it); columns count from 1
        case strip(column: Int, row: Int)
        case rail(Rail, column: Int)

        public var column: Int {
            switch self {
            case .strip(let column, _), .rail(_, let column): return column
            }
        }

        public var description: String {
            switch self {
            case .strip(let column, let row): return "\(Character(UnicodeScalar(UInt8(97 + row))))\(column)"
            case .rail(let rail, let column): return "\(rail.name) \(column)"
            }
        }
    }

    /// One leg of a part in a hole (or one end of an off-board wire), on a net
    public struct Leg: Sendable {
        public var name: String
        public var hole: Hole
        public var net: String
    }

    /// How a part looks on the board
    public enum Style: Sendable, Equatable {
        case resistor(ohms: Double)
        case ceramic, electrolytic, inductor, diode, zener, lamp
        case led(color: Int)
        /// A TO-92 (or metal can) transistor: its legs' letters from left to right, flat face towards you
        case transistor(pinout: String)
        case pot, vactrol, toggle, button
        case dip(pins: Int)
    }

    public struct Placement: Sendable {
        /// The part's name, or the package's ("U1") for parts that share one
        public var name: String
        /// What it is: "10 kΩ", "TL072", "2N3904"
        public var title: String
        public var style: Style
        public var legs: [Leg]
        /// Which way round, what else to know
        public var note: String?
    }

    public struct Jumper: Sendable {
        public var from: Hole
        public var to: Hole
        public var net: String
    }

    /// Something wired to the board from outside it: a supply, a signal source, a speaker, a module
    public struct OffBoard: Sendable {
        public var name: String
        public var title: String
        public var wires: [Leg]
    }

    public struct Item: Sendable {
        public var quantity: Int
        public var description: String
        public var parts: [String]
    }

    public struct Layout: Sendable {
        public var placements: [Placement] = []
        public var jumpers: [Jumper] = []
        public var offBoard: [OffBoard] = []
        public var rails: [Rail: String] = [:]
        public var bom: [Item] = []
        public var notes: [String] = []
        /// Columns in use: more than one board's 63 when the circuit needs them
        public var width = Breadboard.columns

        /// The net each hole in use is on: legs, wire ends, jumper ends
        public var nets: [Hole: String] {
            var result: [Hole: String] = [:]
            for placement in placements { for leg in placement.legs { result[leg.hole] = leg.net } }
            for item in offBoard { for wire in item.wires { result[wire.hole] = wire.net } }
            for jumper in jumpers {
                result[jumper.from] = jumper.net
                result[jumper.to] = jumper.net
            }
            return result
        }
    }

    // MARK: - Packages

    /// What feeds a chip's supply pin
    enum Supply: Hashable {
        case ground
        /// A supply at this voltage (negative for a negative supply)
        case volts(Double)
    }

    /// A chip as bought: its units' pins, the pins all its units share, its supply pins and pins tied to ground
    struct Package {
        var title: String
        var pins: Int
        /// Each unit's terminals' pin numbers, by terminal name
        var units: [[String: Int]]
        /// Terminals all units share (a CD4053's inhibit), by name
        var shared: [String: Int] = [:]
        var supplies: [(pin: Int, label: String, supply: Supply)]
        /// Pins tied to ground (an AD633's X2, Y2 and Z)
        var grounded: [Int] = []
        /// Each pin's label, for the legs' names
        var labels: [Int: String] = [:]
        var note: String?
    }

    /// The package a chip part comes in, by its kind and model; nil for parts that are not chips
    static func package(_ part: NetlistPart) -> Package? {
        func p(_ key: String) -> Double { part.params[key] ?? part.kind.params.first { $0.key == key }?.defaultValue ?? 0 }
        let model = Element(kind: part.kind, a: .zero, b: GridPoint(1, 0), params: part.params).model?.name
        func dual(_ title: String, plus: Double, minus: Double, note: String? = nil) -> Package {
            Package(title: title, pins: 8, units: [["minus": 2, "plus": 3, "out": 1], ["minus": 6, "plus": 5, "out": 7]],
                    supplies: [(4, "V−", minus == 0 ? .ground : .volts(minus)), (8, "V+", .volts(plus))],
                    labels: [1: "OUT A", 2: "−IN A", 3: "+IN A", 4: "V−", 5: "+IN B", 6: "−IN B", 7: "OUT B", 8: "V+"], note: note)
        }
        /// ± the op-amp's swing and a volt and a half: ±15 V for a 13.5 V swing
        func rails(_ swing: Double) -> Double { (max(swing, 1) + 1.5).rounded() }
        let cmos = p("supply")
        switch part.kind {
        case .opAmp:
            let v = rails(p("limit"))
            switch model {
            case "LM741":
                return Package(title: "LM741", pins: 8, units: [["minus": 2, "plus": 3, "out": 6]],
                               supplies: [(4, "V−", .volts(-v)), (7, "V+", .volts(v))],
                               labels: [1: "NULL", 2: "−IN", 3: "+IN", 4: "V−", 5: "NULL", 6: "OUT", 7: "V+", 8: "NC"])
            case "LM358", "NE5532", "TL072":
                return dual(model!, plus: v, minus: -v)
            default:
                return dual("TL072", plus: v, minus: -v, note: "An ideal op-amp: a TL072 stands in for it")
            }
        case .comparator:
            if model == "LM311" {
                return Package(title: "LM311", pins: 8, units: [["plus": 2, "minus": 3, "out": 7]],
                               supplies: [(1, "GND", .ground), (4, "V−", .volts(-15)), (8, "V+", .volts(15))],
                               labels: [1: "GND", 2: "+IN", 3: "−IN", 4: "V−", 5: "BAL", 6: "STRB", 7: "OUT", 8: "V+"],
                               note: "Open-collector output: pull it up to the output's high level with a resistor (about 1 kΩ)")
            }
            return Package(title: "LM393", pins: 8, units: [["minus": 2, "plus": 3, "out": 1], ["minus": 6, "plus": 5, "out": 7]],
                           supplies: [(4, "GND", .ground), (8, "VCC", .volts(max(p("high"), 5)))],
                           labels: [1: "OUT A", 2: "−IN A", 3: "+IN A", 4: "GND", 5: "+IN B", 6: "−IN B", 7: "OUT B", 8: "VCC"],
                           note: "Open-collector outputs: pull each up to \(SI.format(max(p("high"), 5), unit: "V")) with a resistor (about 4.7 kΩ)")
        case .schmittInverter, .unbufferedInverter:
            let title = part.kind == .schmittInverter ? (model == "74HC14" ? "74HC14" : "CD40106") : (model == "CD4049UB" ? "CD4049UB" : "CD4069UB")
            if title == "CD4049UB" {
                return Package(title: title, pins: 16,
                               units: [[3, 2], [5, 4], [7, 6], [9, 10], [11, 12], [14, 15]].map { ["in": $0[0], "out": $0[1]] },
                               supplies: [(1, "VDD", .volts(cmos)), (8, "VSS", .ground)], labels: [13: "NC", 16: "NC"])
            }
            return Package(title: title, pins: 14,
                           units: [[1, 2], [3, 4], [5, 6], [9, 8], [11, 10], [13, 12]].map { ["in": $0[0], "out": $0[1]] },
                           supplies: [(7, "VSS", .ground), (14, "VDD", .volts(cmos))])
        case .analogSwitch:
            return Package(title: "CD4066", pins: 14,
                           units: [[1, 2, 13], [4, 3, 5], [8, 9, 6], [11, 10, 12]].map { ["a": $0[0], "b": $0[1], "control": $0[2]] },
                           supplies: [(7, "VSS", .ground), (14, "VDD", .volts(cmos))],
                           note: model == "DG411" ? "A CD4066 stands in for the DG411 (more on-resistance; the DG411 itself switches on with its input low)" : nil)
        case .logicGate:
            let function = Int(Simulator.choice(p("function"), 0...5))
            let names = ["CD4011", "CD4001", "CD4081", "CD4071", "CD4070", "CD4077"]
            let title = model ?? (p("upper") > 0.55 && function == 0 ? "CD4093" : names[function])
            if title.hasPrefix("74") {
                return Package(title: title, pins: 14,
                               units: [[1, 2, 3], [4, 5, 6], [9, 10, 8], [12, 13, 11]].map { ["in1": $0[0], "in2": $0[1], "out": $0[2]] },
                               supplies: [(7, "GND", .ground), (14, "VCC", .volts(cmos))])
            }
            return Package(title: title, pins: 14,
                           units: [[1, 2, 3], [5, 6, 4], [8, 9, 10], [12, 13, 11]].map { ["in1": $0[0], "in2": $0[1], "out": $0[2]] },
                           supplies: [(7, "VSS", .ground), (14, "VDD", .volts(cmos))])
        case .flipFlop:
            return Package(title: "CD4013", pins: 14,
                           units: [["d": 5, "clock": 3, "set": 6, "reset": 4, "q": 1, "qbar": 2],
                                   ["d": 9, "clock": 11, "set": 8, "reset": 10, "q": 13, "qbar": 12]],
                           supplies: [(7, "VSS", .ground), (14, "VDD", .volts(cmos))])
        case .analogSelector:
            return Package(title: model ?? "CD4053", pins: 16,
                           units: [["x0": 12, "x1": 13, "select": 11, "x": 14], ["x0": 2, "x1": 1, "select": 10, "x": 15],
                                   ["x0": 5, "x1": 3, "select": 9, "x": 4]],
                           shared: ["inhibit": 6], supplies: [(7, "VEE", .ground), (8, "VSS", .ground), (16, "VDD", .volts(cmos))])
        case .ota:
            let v = (max(p("supply"), 3)).rounded()
            return Package(title: "LM13700", pins: 16, units: [["minus": 4, "plus": 3, "out": 5, "bias": 1], ["minus": 13, "plus": 14, "out": 12, "bias": 16]],
                           supplies: [(6, "V−", .volts(-v)), (11, "V+", .volts(v))],
                           labels: [2: "DIODE A", 7: "BUF IN A", 8: "BUF OUT A", 9: "BUF OUT B", 10: "BUF IN B", 15: "DIODE B"],
                           note: "The linearising diodes (pins 2, 15) and buffers (pins 7–10) are not used")
        case .timer555:
            return Package(title: model ?? "NE555", pins: 8,
                           units: [["gnd": 1, "trig": 2, "out": 3, "reset": 4, "ctrl": 5, "thr": 6, "dis": 7, "vcc": 8]], supplies: [])
        case .decadeCounter:
            return Package(title: model ?? "CD4017", pins: 16,
                           units: [["clock": 14, "inhibit": 13, "reset": 15, "q0": 3, "q1": 2, "q2": 4, "q3": 7, "q4": 10, "q5": 1,
                                    "q6": 5, "q7": 6, "q8": 9, "q9": 11, "carry": 12]],
                           supplies: [(8, "VSS", .ground), (16, "VDD", .volts(cmos))])
        case .binaryCounter:
            return Package(title: model ?? "CD4040", pins: 16,
                           units: [["clock": 10, "reset": 11, "q1": 9, "q2": 7, "q3": 6, "q4": 5, "q5": 3, "q6": 2, "q7": 4, "q8": 13,
                                    "q9": 12, "q10": 14, "q11": 15, "q12": 1]],
                           supplies: [(8, "VSS", .ground), (16, "VDD", .volts(cmos))])
        case .analogMux:
            return Package(title: model ?? "CD4051", pins: 16,
                           units: [["x0": 13, "x1": 14, "x2": 15, "x3": 12, "x4": 1, "x5": 5, "x6": 2, "x7": 4, "a": 11, "b": 10, "c": 9,
                                    "inhibit": 6, "x": 3]],
                           supplies: [(7, "VEE", .ground), (8, "VSS", .ground), (16, "VDD", .volts(cmos))])
        case .pll:
            return Package(title: model ?? "CD4046", pins: 16,
                           units: [["signal": 14, "comparator": 3, "vco_in": 9, "inhibit": 5, "vco_out": 4, "pc1": 2, "pc2": 13]],
                           supplies: [(8, "VSS", .ground), (16, "VDD", .volts(cmos))],
                           labels: [1: "PHASE PULSES", 6: "C1A", 7: "C1B", 10: "DEMOD", 11: "R1", 12: "R2", 15: "ZENER"],
                           note: "Its VCO's range is set by parts on pins 6–7 (C1), 11 (R1) and 12 (R2): choose them from the datasheet for \(SI.format(p("fMin"), unit: "Hz")) to \(SI.format(p("fMax"), unit: "Hz"))")
        case .dac:
            return Package(title: "MCP4921", pins: 8, units: [["cs": 2, "sck": 3, "sdi": 4, "ldac": 5, "vref": 6, "out": 8]],
                           supplies: [(1, "VDD", .volts(max(p("supply"), 2.7))), (7, "AVSS", .ground)])
        case .multiplier:
            return Package(title: "AD633", pins: 8, units: [["x": 1, "y": 3, "out": 7]],
                           supplies: [(5, "−VS", .volts(-15)), (8, "+VS", .volts(15))], grounded: [2, 4, 6],
                           labels: [1: "X1", 2: "X2", 3: "Y1", 4: "Y2", 5: "−VS", 6: "Z", 7: "W", 8: "+VS"])
        case .attiny85:
            return Package(title: "ATtiny85", pins: 8, units: [["pb5": 1, "pb3": 2, "pb4": 3, "pb0": 5, "pb1": 6, "pb2": 7]],
                           supplies: [(4, "GND", .ground), (8, "VCC", .volts(max(p("supply"), 1.8)))],
                           note: "Program it before it goes on the board (it runs the sketch uploaded in JSpice)")
        default:
            return nil
        }
    }

    /// A transistor's legs, left to right with its flat face towards you, and what to know about it
    static func transistor(_ part: NetlistPart) -> (title: String, pinout: String, note: String?) {
        let model = Element(kind: part.kind, a: .zero, b: GridPoint(1, 0), params: part.params).model?.name
        switch (part.kind, model) {
        case (.npn, "BC547C"): return ("BC547C", "CBE", nil)
        case (.npn, "2N5088"): return ("2N5088", "EBC", "Some makers' 2N5088 run C B E: check yours")
        case (.npn, "BC108"): return ("BC108", "EBC", "Metal can: seen from below, the tab is next to the emitter; bend the legs into a line")
        case (.npn, _): return (model == "2N3904" ? "2N3904" : "2N3904 (or any small NPN)", "EBC", nil)
        case (.pnp, "AC128"): return ("AC128", "EBC", "Germanium, metal can: the dot marks the collector; check with a meter")
        case (.pnp, _): return (model == "2N3906" ? "2N3906" : "2N3906 (or any small PNP)", "EBC", nil)
        case (.njfet, "2N3819"): return ("2N3819", "SGD", nil)
        case (.njfet, "J201"): return ("J201", "DSG", nil)
        case (.njfet, _): return (model ?? "2N5457", "DSG", nil)
        case (.nmos, _): return ("2N7000", "SGD", "A small N-MOSFET stands in for the generic one")
        default: return ("BS250", "DGS", "A small P-MOSFET stands in for the generic one; check its pinout")
        }
    }

    /// A transistor's, pot's or vactrol's legs in order, how it looks, what it is, and which way round it goes
    /// (`facing` says where the flat face of a transistor is, and in which order its legs then run)
    static func inline(_ part: NetlistPart, facing: String) -> (order: [String], style: Style, title: String, note: String?) {
        switch part.kind {
        case .potentiometer:
            let ohms = part.params["resistance"] ?? 10_000
            return (["a", "wiper", "b"], .pot, SI.format(ohms, unit: "Ω") + ((part.params["taper"] ?? 0) >= 0.5 ? " audio (A)" : " linear (B)"),
                    "Lugs 1, 2, 3 (shaft towards you, lugs down, left to right): a, wiper, b; turning it clockwise moves the wiper towards b")
        case .vactrol:
            return (["anode", "cathode", "a", "b"], .vactrol,
                    Element(kind: .vactrol, a: .zero, b: GridPoint(1, 0), params: part.params).model?.name ?? "VTL5C3",
                    "The LED's leads (+ is the anode) at one end, the photoresistor's at the other")
        default:
            let t = transistor(part)
            let letter: [Character: String] = ["E": "emitter", "B": "base", "C": "collector", "D": "drain", "S": "source", "G": "gate"]
            return (t.pinout.map { letter[$0] ?? "" }, .transistor(pinout: t.pinout), t.title,
                    "Flat face \(facing): " + t.pinout.map(String.init).joined(separator: " ") + (t.note.map { ". " + $0 } ?? ""))
        }
    }

    // MARK: - Laying out

    struct Strip: Hashable, Comparable {
        var column: Int
        var top: Bool
        static func < (a: Strip, b: Strip) -> Bool { (a.column, a.top ? 0 : 1) < (b.column, b.top ? 0 : 1) }
        /// Rows from the channel outwards
        var rows: [Int] { top ? [4, 3, 2, 1, 0] : [5, 6, 7, 8, 9] }
    }

    struct Builder {
        var layout = Layout()
        var stripNet: [Strip: String] = [:]
        var used = Set<Hole>()
        /// Each net's rails
        var railsOf: [String: [Rail]] = [:]
        var cursor = 2

        func free(_ strip: Strip) -> Int { strip.rows.filter { !used.contains(.strip(column: strip.column, row: $0)) }.count }

        /// A free hole in the strip, the nearest the channel first (or the farthest, for jumpers)
        mutating func take(_ strip: Strip, outer: Bool = false) -> Hole? {
            let rows = outer ? strip.rows.reversed() : strip.rows
            for row in rows {
                let hole = Hole.strip(column: strip.column, row: row)
                if !used.contains(hole) {
                    used.insert(hole)
                    return hole
                }
            }
            return nil
        }

        /// A strip with nothing on it near `column` (on `top` first, then the other half)
        mutating func newStrip(for net: String, near column: Int, top: Bool) -> Strip {
            // past the board's last used column every strip is free, so this always ends
            for distance in 0... {
                for c in [column + distance, column - distance] where c >= 1 {
                    for half in [top, !top] {
                        let strip = Strip(column: c, top: half)
                        if stripNet[strip] == nil && free(strip) == 5 {
                            stripNet[strip] = net
                            layout.width = max(layout.width, c)
                            return strip
                        }
                    }
                }
            }
            fatalError("unreachable")
        }

        func strips(of net: String) -> [Strip] { stripNet.filter { $0.value == net }.map(\.key).sorted() }

        /// A free hole on the rail for `net` nearest `column`, on the side of `top` when the net has a rail there
        mutating func railHole(_ net: String, near column: Int, top: Bool) -> Hole? {
            guard let rails = railsOf[net], !rails.isEmpty else { return nil }
            let rail = rails.first { $0.top == top } ?? rails[0]
            for distance in 0..<200 {
                for c in [column + distance, column - distance] where c >= 1 && c <= max(layout.width, Breadboard.columns) {
                    let hole = Hole.rail(rail, column: c)
                    if !used.contains(hole) {
                        used.insert(hole)
                        return hole
                    }
                }
            }
            return nil
        }

        /// A hole on `net` near `column`: on its rail, in one of its strips with room (keeping two holes for jumpers),
        /// or in a new strip of its own
        mutating func hole(on net: String, near column: Int, top: Bool, within: Int = 8) -> Hole {
            if railsOf[net] != nil, let hole = railHole(net, near: column, top: top) { return hole }
            // (two holes kept for the jumpers that may join the strip to the net's others)
            let near = strips(of: net).filter { free($0) >= 3 && abs($0.column - column) <= within }
                .min { abs($0.column - column) < abs($1.column - column) }
            if let near, let hole = take(near) { return hole }
            let strip = newStrip(for: net, near: column, top: top)
            return take(strip)!
        }

        /// `count` neighbouring empty strips in one half (or both, for a chip across the channel), from the cursor on
        mutating func run(_ count: Int, top: Bool?) -> Int {
            func empty(_ strip: Strip) -> Bool { stripNet[strip] == nil && free(strip) == 5 }
            var c = cursor
            while !(0..<count).allSatisfy({ k in
                top.map { empty(Strip(column: c + k, top: $0)) } ?? (empty(Strip(column: c + k, top: true)) && empty(Strip(column: c + k, top: false)))
            }) {
                c += 1
            }
            layout.width = max(layout.width, c + count)
            return c
        }
    }

    /// A chip package and the parts whose units it holds
    struct Pack {
        var package: Package
        var key: String
        var units: [(part: NetlistPart, unit: Int)]
        /// The package's name: "U1", or its one part's name
        var name = ""
    }

    /// What goes on a board before any of it is placed, the same for a breadboard and a stripboard: the parts, the
    /// chips' units packed into packages, the supplies (the circuit's own, and those the chips need), and each net's
    /// voltage at rest
    struct Plan {
        var parts: [NetlistPart] = []
        var voltages: [String: Double] = [:]
        var supplies: [(net: String, volts: Double)] = []
        /// Supplies the chips need that the circuit leaves implicit
        var virtual: [String: Double] = [:]
        var packs: [Pack] = []
        /// Resistors, capacitors, diodes, LEDs, lamps, switches
        var twoLead: [NetlistPart] = []
        /// Transistors, pots, vactrols
        var inline: [NetlistPart] = []
        /// Sources, speakers, modules, tubes: wired from off the board
        var off: [NetlistPart] = []

        /// How many legs, wires and supply pins a net has
        func uses(_ net: String) -> Int {
            parts.reduce(0) { $0 + $1.connections.values.filter { $0 == net }.count }
                + packs.reduce(0) { total, pack in total + pack.package.supplies.filter { Breadboard.netName($0.supply, supplies) == net }.count }
        }

        /// The supplies the most parts use first: positive ones, negative ones
        var positives: [(net: String, volts: Double)] { supplies.filter { $0.volts > 0 }.sorted { uses($0.net) > uses($1.net) } }
        var negatives: [(net: String, volts: Double)] { supplies.filter { $0.volts < 0 }.sorted { uses($0.net) > uses($1.net) } }

        /// Each pin of a package: its net and label (nil for a pin left free)
        func pins(_ pack: Pack) -> [Int: (net: String, label: String)] {
            let p = pack.package
            var netOfPin: [Int: (net: String, label: String)] = [:]
            for (part, unit) in pack.units {
                let letter = pack.units.count > 1 ? String(Character(UnicodeScalar(UInt8(65 + unit)))) : ""
                for (terminal, pin) in p.units[unit] {
                    if let net = part.connections[terminal] { netOfPin[pin] = (net, p.labels[pin] ?? "\(terminal.uppercased())\(letter.isEmpty ? "" : " " + letter)") }
                }
                for (terminal, pin) in p.shared {
                    if let net = part.connections[terminal] { netOfPin[pin] = (net, terminal.uppercased()) }
                }
            }
            for supply in p.supplies { netOfPin[supply.pin] = (Breadboard.netName(supply.supply, supplies), supply.label) }
            for pin in p.grounded { netOfPin[pin] = ("GND", p.labels[pin] ?? "GND") }
            return netOfPin
        }

        /// The note for a package: the datasheet's, and its spare units
        func note(_ pack: Pack) -> String? {
            let p = pack.package
            var note = p.note
            if pack.units.count < p.units.count && p.units.count > 1 {
                let spare = "\(p.units.count - pack.units.count) of its \(p.units.count) units unused: tie their inputs to ground"
                note = note.map { $0 + ". " + spare } ?? spare
            }
            return note
        }

        func title(_ pack: Pack) -> String {
            pack.package.title + (pack.units.count > 1 ? " (\(pack.units.map(\.part.name).joined(separator: ", ")))" : "")
        }

        /// The notes every board shares: the supplies the circuit leaves implicit
        var supplyNotes: [String] {
            virtual.sorted { $0.key < $1.key }.map { "The chips need a \(SI.format($0.value, unit: "V")) supply (\($0.key)), which the circuit leaves implicit" }
        }

        /// The supplies wired to the board: each with its source's name
        var wiredSupplies: [(net: String, volts: Double, name: String)] {
            supplies.sorted { $0.volts > $1.volts }.filter { uses($0.net) > 0 || virtual[$0.net] != nil }.map { supply in
                (supply.net, supply.volts, parts.first { $0.kind == .dcVoltage && $0.connections.values.contains(supply.net) }?.name ?? supply.net)
            }
        }

        /// The parts wired from off the board, but for the supplies already wired
        var offBoardParts: [NetlistPart] {
            off.filter { part in
                part.kind != .dcVoltage || !supplies.contains { s in part.connections.values.contains(s.net) && part.connections.values.contains("GND") }
            }
        }
    }

    static func plan(_ circuit: Circuit) -> Plan {
        let flat = circuit.flattened(expandingModels: false)
        var plan = Plan()
        plan.parts = NetlistExtractor.netlist(from: flat).filter { $0.kind != .block && $0.kind != .port }
        plan.voltages = netVoltages(flat, plan.parts)

        // supplies: the circuit's own DC sources to ground, and what the chips need
        for part in plan.parts where part.kind == .dcVoltage {
            let v = part.params["voltage"] ?? 0
            if part.connections["minus"] == "GND", let net = part.connections["plus"], v != 0 { plan.supplies.append((net, v)) }
            if part.connections["plus"] == "GND", let net = part.connections["minus"], v != 0 { plan.supplies.append((net, -v)) }
        }

        // chips: units packed into packages
        for part in plan.parts {
            if let package = package(part) {
                let shared = package.shared.keys.sorted().map { part.connections[$0] ?? "-" }.joined(separator: ",")
                let key = package.title + "|" + shared + "|" + package.supplies.map { "\($0.supply)" }.joined(separator: ",")
                if let k = plan.packs.firstIndex(where: { $0.key == key && $0.units.count < $0.package.units.count }) {
                    plan.packs[k].units.append((part, plan.packs[k].units.count))
                } else {
                    plan.packs.append(Pack(package: package, key: key, units: [(part, 0)]))
                }
                continue
            }
            switch part.kind {
            case .resistor, .capacitor, .inductor, .diode, .zener, .led, .lamp, .toggleSwitch, .pushButton:
                plan.twoLead.append(part)
            case .npn, .pnp, .njfet, .nmos, .pmos, .potentiometer, .vactrol:
                plan.inline.append(part)
            case .wire, .ground, .netLabel, .port, .block, .probe:
                break
            default:
                plan.off.append(part)
            }
        }
        // the supplies the chips need: one of the circuit's at that voltage, or one added for them
        for pack in plan.packs {
            for supply in pack.package.supplies {
                guard case .volts(let v) = supply.supply, !plan.supplies.contains(where: { abs($0.volts - v) < 0.5 }) else { continue }
                let name = (v > 0 ? "+" : "−") + SI.trimmed(abs(v), digits: 3) + "V"
                plan.virtual[name] = v
                plan.supplies.append((name, v))
            }
        }
        // the packages' names: U1, U2… for shared ones, the part's own for a chip alone
        let usedNames = Set(plan.parts.map(\.name))
        var number = 0
        for k in plan.packs.indices {
            if plan.packs[k].units.count == 1 {
                plan.packs[k].name = plan.packs[k].units[0].part.name
                continue
            }
            repeat { number += 1 } while usedNames.contains("U\(number)")
            plan.packs[k].name = "U\(number)"
        }
        return plan
    }

    /// Lays the circuit out on a breadboard
    public static func layout(_ circuit: Circuit) -> Layout {
        let plan = plan(circuit)
        let voltages = plan.voltages
        var b = Builder()

        // the rails: ground on both − rails; the supply most parts use on the top + rail, a second (a negative one first)
        // on the bottom + rail
        b.railsOf["GND"] = [.topNegative, .bottomNegative]
        b.layout.rails[.topNegative] = "GND"
        b.layout.rails[.bottomNegative] = "GND"
        let positives = plan.positives, negatives = plan.negatives
        if let first = positives.first {
            b.railsOf[first.net] = [.topPositive]
            b.layout.rails[.topPositive] = first.net
        }
        if let second = negatives.first ?? positives.dropFirst().first {
            b.railsOf[second.net] = [.bottomPositive]
            b.layout.rails[.bottomPositive] = second.net
        } else if let first = positives.first {
            b.railsOf[first.net]?.append(.bottomPositive)
            b.layout.rails[.bottomPositive] = first.net
        }
        b.layout.notes += plan.supplyNotes

        // chips across the channel, pin 1 at the bottom left
        for pack in plan.packs {
            let p = pack.package
            let width = p.pins / 2
            let column = b.run(width, top: nil)
            b.cursor = column + width + 1
            let netOfPin = plan.pins(pack)
            var legs: [Leg] = []
            for pin in 1...p.pins {
                let top = pin > width
                let c = top ? column + (p.pins - pin) : column + pin - 1
                let hole = Hole.strip(column: c, row: top ? 4 : 5)
                b.used.insert(hole)
                let strip = Strip(column: c, top: top)
                if let (net, label) = netOfPin[pin] {
                    b.stripNet[strip] = net
                    legs.append(Leg(name: "\(pin) \(label)", hole: hole, net: net))
                } else {
                    // a pin left free keeps its strip to itself
                    b.stripNet[strip] = "\u{0}"
                    legs.append(Leg(name: "\(pin) \(p.labels[pin] ?? "—")", hole: hole, net: ""))
                }
            }
            b.layout.placements.append(Placement(name: pack.name, title: plan.title(pack), style: .dip(pins: p.pins), legs: legs, note: plan.note(pack)))
        }

        // transistors, pots and vactrols: their legs in neighbouring strips, alternately above and below the channel
        var top = true
        for part in plan.inline {
            let (order, style, title, note) = inline(part, facing: "towards you, legs left to right")
            let column = b.run(order.count, top: top)
            var legs: [Leg] = []
            for (k, terminal) in order.enumerated() {
                let strip = Strip(column: column + k, top: top)
                let net = part.connections[terminal] ?? "\u{0}"
                b.stripNet[strip] = net
                let hole = Hole.strip(column: strip.column, row: top ? 2 : 7)
                b.used.insert(hole)
                legs.append(Leg(name: terminal, hole: hole, net: part.connections[terminal] ?? ""))
            }
            b.layout.placements.append(Placement(name: part.name, title: title, style: style, legs: legs, note: note))
            if !top { b.cursor = column + order.count + 1 }
            top.toggle()
        }
        b.cursor += 1

        // two-lead parts: each lead on a strip of its net (or its rail), the two close together
        for part in plan.twoLead {
            let terminals = part.kind.terminalNames
            guard let n0 = part.connections[terminals[0]], let n1 = part.connections[terminals[1]] else {
                b.layout.notes.append("\(part.name) is not connected at both ends: left off the board")
                continue
            }
            // anchor on a net that has strips already, not on a rail (whose lead then goes into the rail beside it)
            let has0 = !b.strips(of: n0).isEmpty, has1 = !b.strips(of: n1).isEmpty
            let swap = (!has0 && has1) || (b.railsOf[n0] != nil && b.railsOf[n1] == nil)
            let (anchor, other) = swap ? (n1, n0) : (n0, n1)
            let anchorStrip = b.strips(of: anchor).first
            let h0 = b.hole(on: anchor, near: anchorStrip?.column ?? b.cursor, top: anchorStrip?.top ?? true)
            var top0 = anchorStrip?.top ?? true
            if case .strip(_, let row) = h0 { top0 = row < 5 }
            let h1 = b.hole(on: other, near: h0.column + 3, top: top0)
            let holeOf = swap ? [terminals[0]: h1, terminals[1]: h0] : [terminals[0]: h0, terminals[1]: h1]
            var legs = terminals.map { Leg(name: $0, hole: holeOf[$0]!, net: part.connections[$0] ?? "") }
            let (style, title, note) = describe(part, voltages)
            if style == .electrolytic {
                // + on the higher voltage
                let plus = (voltages[n1] ?? 0) > (voltages[n0] ?? 0) ? 1 : 0
                legs = [Leg(name: "+", hole: legs[plus].hole, net: legs[plus].net), Leg(name: "−", hole: legs[1 - plus].hole, net: legs[1 - plus].net)]
            }
            b.layout.placements.append(Placement(name: part.name, title: title, style: style, legs: legs, note: note))
        }

        // off the board: supplies, sources, speakers, modules, each terminal wired to a hole of its net
        for supply in plan.wiredSupplies {
            let plus = b.hole(on: supply.net, near: Breadboard.columns, top: supply.volts > 0)
            let ground = b.hole(on: "GND", near: Breadboard.columns, top: supply.volts > 0)
            b.layout.offBoard.append(OffBoard(name: supply.name, title: "Power supply, \(SI.format(supply.volts, unit: "V"))",
                                              wires: [Leg(name: supply.volts > 0 ? "+" : "−", hole: plus, net: supply.net), Leg(name: "common", hole: ground, net: "GND")]))
        }
        for part in plan.offBoardParts {
            var wires: [Leg] = []
            for terminal in part.terminalNames {
                guard let net = part.connections[terminal] else { continue }
                wires.append(Leg(name: terminal, hole: b.hole(on: net, near: b.cursor, top: true), net: net))
            }
            b.layout.offBoard.append(OffBoard(name: part.name, title: offBoardTitle(part), wires: wires))
        }

        // jumpers: the strips of each net joined in a chain; strips of a rail's net to the rail
        // (in order of name, so the same circuit gives the same jumpers every time)
        for net in Set(b.stripNet.values).sorted() where net != "\u{0}" {
            let strips = b.strips(of: net)
            if b.railsOf[net] != nil {
                for strip in strips {
                    guard let from = b.take(strip, outer: true), let to = b.railHole(net, near: strip.column, top: strip.top) else { continue }
                    b.layout.jumpers.append(Jumper(from: from, to: to, net: net))
                }
                continue
            }
            for (a, c) in zip(strips, strips.dropFirst()) {
                guard let from = b.take(a, outer: true), let to = b.take(c, outer: true) else {
                    b.layout.notes.append("No room for a jumper on \(net) at column \(a.column)")
                    continue
                }
                b.layout.jumpers.append(Jumper(from: from, to: to, net: net))
            }
        }
        // a net on both rails of a kind: the two joined at the right-hand end
        for (net, rails) in b.railsOf where rails.count == 2 {
            let end = max(b.layout.width, Breadboard.columns)
            if let from = b.railHole(net, near: end, top: true), let to = b.railHole(net, near: end, top: false) {
                b.layout.jumpers.append(Jumper(from: from, to: to, net: net))
            }
        }
        if b.layout.width > Breadboard.columns {
            b.layout.notes.append("The circuit needs \(b.layout.width) columns: more than one breadboard (63 each), side by side with their rails joined")
        }
        b.layout.bom = billOfMaterials(b.layout.placements.map { ($0.name, $0.title, $0.style) }, offBoard: b.layout.offBoard.map { ($0.name, $0.title) },
                                       wires: b.layout.jumpers.count, wireName: "jumper wires")
        return b.layout
    }

    static func netName(_ supply: Supply, _ supplies: [(net: String, volts: Double)]) -> String {
        guard case .volts(let v) = supply else { return "GND" }
        return supplies.first { abs($0.volts - v) < 0.5 }?.net ?? ""
    }

    /// Each net's DC voltage where the circuit rests, its signal sources held still
    static func netVoltages(_ circuit: Circuit, _ parts: [NetlistPart]) -> [String: Double] {
        var still = circuit
        for i in still.elements.indices where [.acVoltage, .squareVoltage, .noiseVoltage, .audioInput].contains(still.elements[i].kind) {
            still = Simulator.quiet(still, holding: i)
        }
        // long enough for coupling capacitors to charge, without running microcontrollers for seconds
        let simulator = Simulator.settled(still, holding: nil, duration: min(Simulator.settling(still).duration, 0.5), maxSteps: 20_000)
        var result: [String: Double] = ["GND": 0]
        for part in parts {
            guard let id = part.id, let index = still.index(of: id) else { continue }
            let v = simulator.terminalVoltages(index)
            let names = still.elements[index].terminalNames
            for (k, terminal) in names.enumerated() where k < v.count {
                if let net = part.connections[terminal], result[net] == nil { result[net] = v[k] }
            }
        }
        return result
    }

    /// How a two-lead part looks, what it is called, and what to know
    static func describe(_ part: NetlistPart, _ voltages: [String: Double]) -> (Style, String, String?) {
        func p(_ key: String) -> Double { part.params[key] ?? part.kind.params.first { $0.key == key }?.defaultValue ?? 0 }
        let model = Element(kind: part.kind, a: .zero, b: GridPoint(1, 0), params: part.params).model?.name
        switch part.kind {
        case .resistor:
            return (.resistor(ohms: p("resistance")), SI.format(p("resistance"), unit: "Ω"), nil)
        case .capacitor:
            let farads = p("capacitance")
            if farads >= 1e-6 {
                let a = part.connections["a"].flatMap { voltages[$0] } ?? 0, b = part.connections["b"].flatMap { voltages[$0] } ?? 0
                let across = abs(a - b)
                let rating = [6.3, 10, 16, 25, 35, 50, 63, 100, 160, 250, 400, 450].first { $0 >= across * 1.5 + 1 } ?? 450
                let note = across < 0.1 ? "No DC across it: either way round, or a non-polar (bipolar) electrolytic"
                    : "Electrolytic: + to the higher voltage, the stripe (−) to the lower"
                return (.electrolytic, SI.format(farads, unit: "F") + " \(SI.trimmed(rating, digits: 3)) V", note)
            }
            return (.ceramic, SI.format(farads, unit: "F"), nil)
        case .inductor:
            return (.inductor, SI.format(p("inductance"), unit: "H"), nil)
        case .diode:
            return (.diode, model == "Generic silicon" || model == nil ? "1N4148" : model!, "The band marks the cathode")
        case .zener:
            return (.zener, SI.trimmed(p("breakdown"), digits: 3) + " V Zener", "The band marks the cathode")
        case .led:
            let color = Int(Simulator.choice(p("color"), 0...4))
            return (.led(color: color), (["red", "green", "blue", "yellow", "white"][color]) + " LED", "The longer leg is the anode (+)")
        case .lamp:
            return (.lamp, "lamp, \(SI.format(p("resistance"), unit: "Ω"))", nil)
        case .toggleSwitch:
            return (.toggle, "switch (SPST)", nil)
        default:
            return (.button, "push button", nil)
        }
    }

    static func offBoardTitle(_ part: NetlistPart) -> String {
        switch part.kind {
        case .acVoltage, .squareVoltage, .noiseVoltage: return "Signal source (generator or input jack)"
        case .audioInput: return "Audio input jack"
        case .keyboardPitch, .keyboardGate: return "Keyboard CV / gate input"
        case .speaker: return "Speaker or output jack"
        case .ammeter: return "Multimeter on its current range"
        case .currentSource: return "Current source"
        case .dcVoltage: return "Power supply, \(SI.format(part.params["voltage"] ?? 0, unit: "V"))"
        case .atmega328p, .atmega2560, .rp2040: return (part.kind.board?.title ?? "Board") + ", wired by jumper leads"
        case .triode, .pentode, .transformer: return "\(part.kind.displayName): not for a breadboard (high voltage), on a turret board or chassis"
        default: return part.kind.displayName + ": a module wired to the board"
        }
    }

    static func billOfMaterials(_ placements: [(name: String, title: String, style: Style)], offBoard: [(name: String, title: String)],
                                wires: Int, wireName: String) -> [Item] {
        var groups: [String: [String]] = [:]
        var order: [String] = []
        func add(_ description: String, _ name: String) {
            if groups[description] == nil { order.append(description) }
            groups[description, default: []].append(name)
        }
        for placement in placements {
            switch placement.style {
            case .resistor: add(placement.title + " resistor, ¼ W", placement.name)
            case .ceramic: add(placement.title + " capacitor, ceramic or film", placement.name)
            case .electrolytic: add(placement.title + " electrolytic capacitor", placement.name)
            case .inductor: add(placement.title + " inductor", placement.name)
            case .transistor(let pinout): add(placement.title + " (legs " + pinout.map(String.init).joined(separator: " ") + ")", placement.name)
            case .pot: add(placement.title + " potentiometer", placement.name)
            case .dip(let pins): add(placement.title.components(separatedBy: " (").first! + " (DIP-\(pins))", placement.name)
            default: add(placement.title, placement.name)
            }
        }
        for item in offBoard { add(item.title, item.name) }
        var items = order.map { Item(quantity: groups[$0]?.count ?? 0, description: $0, parts: groups[$0] ?? []) }
        if wires > 0 { items.append(Item(quantity: wires, description: wireName, parts: [])) }
        return items
    }

    // MARK: - Checking

    /// What is wrong with a layout: a hole used twice or off the board, a net split between holes the board does not
    /// join, or two nets the board joins. Empty when the board connects exactly the circuit's nets.
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
        /// The board's own joins: a strip's five holes, a rail's whole length
        func board(_ h: Hole) -> Hole {
            switch h {
            case .strip(let column, let row): return .strip(column: column, row: row < 5 ? 0 : 5)
            case .rail(let rail, _): return .rail(rail, column: 0)
            }
        }
        var occupied: [Hole: String] = [:]
        var ends: [(hole: Hole, net: String, what: String)] = []
        for placement in layout.placements {
            for leg in placement.legs { ends.append((leg.hole, leg.net, "\(placement.name) \(leg.name)")) }
        }
        for item in layout.offBoard { for wire in item.wires { ends.append((wire.hole, wire.net, "\(item.name) \(wire.name)")) } }
        for jumper in layout.jumpers {
            ends.append((jumper.from, jumper.net, "jumper on \(jumper.net)"))
            ends.append((jumper.to, jumper.net, "jumper on \(jumper.net)"))
        }
        for end in ends {
            if case .strip(let column, let row) = end.hole, column < 1 || row < 0 || row > 9 {
                problems.append("\(end.what) is off the board at \(end.hole)")
            }
            // the ends of a jumper joining two rails may share the end hole with nothing else
            if let other = occupied[end.hole] { problems.append("\(end.hole) holds both \(other) and \(end.what)") }
            occupied[end.hole] = end.what
            union(end.hole, board(end.hole))
        }
        for jumper in layout.jumpers { union(jumper.from, jumper.to) }
        var netsOf: [Hole: Set<String>] = [:]
        var rootsOf: [String: Set<Hole>] = [:]
        for end in ends where !end.net.isEmpty {
            let root = find(end.hole)
            netsOf[root, default: []].insert(end.net)
            rootsOf[end.net, default: []].insert(root)
        }
        // free chip pins sit alone
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
