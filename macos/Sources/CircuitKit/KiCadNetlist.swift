import Foundation

/// The circuit as a KiCad netlist (the S-expression netlist of KiCad 6 and later, version E), for laying out a printed
/// circuit board in KiCad's PCB editor (File ▸ Import ▸ Netlist). The parts are those the breadboard has: op-amps and
/// gates packed into their chips (with the supplies the chips need), each part on a through-hole footprint from KiCad's
/// own libraries, its pads numbered as KiCad numbers them (a transistor's in its pinout's order, a diode's and an LED's
/// cathode pad 1, an electrolytic's + pad 1 on the higher DC voltage); supplies, sources, speakers, switches and the
/// modules wired from off the board each on a pin header. A part whose footprint JSpice does not know (an inductor, a
/// lamp, a vactrol) is left for KiCad's footprint assignment, and named.
public enum KiCadNetlist {
    public struct Export: Sendable {
        public var text: String
        /// The parts left without a footprint
        public var unassigned: [String]
        public var components: Int
        public var nets: Int
    }

    struct Component {
        var ref: String
        var value: String
        var footprint: String
        var description: String
        /// Pad number and net; a pad left free has none
        var pins: [(pad: String, net: String)]
        var id: UUID
    }

    // footprints of KiCad's standard libraries
    static let resistor = "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal"
    static let ceramic = "Capacitor_THT:C_Disc_D5.0mm_W2.5mm_P5.00mm"
    static let signalDiode = "Diode_THT:D_DO-35_SOD27_P7.62mm_Horizontal"
    static let rectifier = "Diode_THT:D_DO-41_SOD81_P10.16mm_Horizontal"
    static let led = "LED_THT:LED_D5.0mm"
    static let to92 = "Package_TO_SOT_THT:TO-92_Inline"
    static let pot = "Potentiometer_THT:Potentiometer_Alpha_RD901F-40-00D_Single_Vertical"

    /// A radial electrolytic big enough for its capacitance
    static func electrolytic(_ farads: Double) -> String {
        switch farads {
        case ..<56e-6: return "Capacitor_THT:CP_Radial_D5.0mm_P2.00mm"
        case ..<270e-6: return "Capacitor_THT:CP_Radial_D6.3mm_P2.50mm"
        case ..<560e-6: return "Capacitor_THT:CP_Radial_D8.0mm_P3.50mm"
        default: return "Capacitor_THT:CP_Radial_D10.0mm_P5.00mm"
        }
    }

    /// A dual-in-line package: 0.3 in wide up to 28 pins, 0.6 in above
    static func dip(_ pins: Int) -> String { "Package_DIP:DIP-\(pins)_W\(pins > 28 ? "15.24" : "7.62")mm" }

    /// A single row of 0.1 in header pins
    static func header(_ pins: Int) -> String {
        "Connector_PinHeader_2.54mm:PinHeader_1x" + String(format: "%02d", max(1, pins)) + "_P2.54mm_Vertical"
    }

    public static func export(_ circuit: Circuit, title: String = "JSpice circuit", date: Date = Date()) -> Export {
        let plan = Breadboard.plan(circuit)
        var components: [Component] = []
        var used = Set(plan.parts.map(\.name) + plan.packs.map(\.name))
        /// A reference not used yet: J1, J2…
        func fresh(_ prefix: String) -> String {
            var k = 1
            while used.contains("\(prefix)\(k)") { k += 1 }
            used.insert("\(prefix)\(k)")
            return "\(prefix)\(k)"
        }
        func id(_ part: NetlistPart) -> UUID { part.id ?? uuid("part " + part.name) }

        // chips
        for pack in plan.packs {
            let netOfPin = plan.pins(pack)
            let pins = (1...pack.package.pins).map { pin in (pad: "\(pin)", net: netOfPin[pin]?.net ?? "") }
            components.append(Component(ref: pack.name, value: plan.title(pack), footprint: dip(pack.package.pins),
                                        description: pack.package.title, pins: pins, id: id(pack.units[0].part)))
        }
        // transistors, pots, vactrols: pads in the order of their legs
        for part in plan.inline {
            let (order, style, title, _) = Breadboard.inline(part, facing: "")
            let footprint: String
            switch style {
            case .transistor: footprint = to92
            case .pot: footprint = pot
            default: footprint = ""
            }
            let pins = order.enumerated().map { (pad: "\($0.offset + 1)", net: part.connections[$0.element] ?? "") }
            components.append(Component(ref: part.name, value: title, footprint: footprint, description: part.kind.displayName,
                                        pins: pins, id: id(part)))
        }
        // two-lead parts
        for part in plan.twoLead {
            let terminals = part.kind.terminalNames
            let (style, title, _) = Breadboard.describe(part, plan.voltages)
            let net = { (terminal: String) in part.connections[terminal] ?? "" }
            var pins = [(pad: "1", net: net(terminals[0])), (pad: "2", net: net(terminals[1]))]
            var footprint = ""
            switch style {
            case .resistor: footprint = resistor
            case .ceramic: footprint = ceramic
            case .electrolytic:
                footprint = electrolytic(part.params["capacitance"] ?? 0)
                // + (pad 1) on the higher voltage
                let (a, b) = (plan.voltages[net(terminals[0])] ?? 0, plan.voltages[net(terminals[1])] ?? 0)
                if b > a { pins = [(pad: "1", net: net(terminals[1])), (pad: "2", net: net(terminals[0]))] }
            case .diode, .zener, .led:
                // KiCad's diodes and LEDs: pad 1 the cathode, pad 2 the anode
                footprint = part.kind == .led ? led
                    : title.hasPrefix("1N40") || title.hasPrefix("1N54") || title.hasPrefix("1N58") || title.hasPrefix("1N47") ? rectifier
                    : signalDiode
                pins = [(pad: "1", net: net("cathode")), (pad: "2", net: net("anode"))]
            case .toggle, .button:
                // on the panel, wired to the board
                footprint = header(2)
            default:
                footprint = ""
            }
            components.append(Component(ref: part.name, value: title, footprint: footprint, description: part.kind.displayName,
                                        pins: pins, id: id(part)))
        }
        // off the board: supplies, then sources, speakers and modules, each on a pin header
        for supply in plan.wiredSupplies {
            components.append(Component(ref: fresh("J"), value: "Power \(SI.format(supply.volts, unit: "V"))", footprint: header(2),
                                        description: "Supply \(supply.name): + and common",
                                        pins: [(pad: "1", net: supply.net), (pad: "2", net: "GND")],
                                        id: uuid("supply " + supply.net)))
        }
        for part in plan.offBoardParts {
            let terminals = part.terminalNames.filter { part.connections[$0] != nil }
            guard !terminals.isEmpty else { continue }
            let pins = terminals.enumerated().map { (pad: "\($0.offset + 1)", net: part.connections[$0.element] ?? "") }
            components.append(Component(ref: part.name, value: Breadboard.offBoardTitle(part), footprint: header(pins.count),
                                        description: "Wired from off the board: " + terminals.joined(separator: ", "),
                                        pins: pins, id: id(part)))
        }
        return write(components, title: title, date: date)
    }

    /// An id made from a name, the same each time (FNV-1a, twice over)
    static func uuid(_ text: String) -> UUID {
        var h1: UInt64 = 0xcbf2_9ce4_8422_2325, h2: UInt64 = 0x8422_2325_cbf2_9ce4
        for byte in text.utf8 {
            h1 = (h1 ^ UInt64(byte)) &* 0x100_0000_01b3
            h2 = ((h2 ^ UInt64(byte)) &* 0x100_0000_01b3) &+ 0x9e37_79b9_7f4a_7c15
        }
        let b = withUnsafeBytes(of: (h1.bigEndian, h2.bigEndian)) { Array($0) }
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// The netlist's text
    static func write(_ components: [Component], title: String, date: Date) -> Export {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let stamp = ISO8601DateFormatter().string(from: date)
        var lines = [
            "(export (version \"E\")",
            "  (design",
            "    (source \(quoted(title)))",
            "    (date \(quoted(stamp)))",
            "    (tool \"JSpice\"))",
            "  (components",
        ]
        for c in components {
            lines.append("    (comp (ref \(quoted(c.ref)))")
            lines.append("      (value \(quoted(c.value)))")
            if !c.footprint.isEmpty { lines.append("      (footprint \(quoted(c.footprint)))") }
            lines.append("      (libsource (lib \"JSpice\") (part \(quoted(c.description))) (description \(quoted(c.description))))")
            lines.append("      (sheetpath (names \"/\") (tstamps \"/\"))")
            lines.append("      (tstamps \(quoted(c.id.uuidString.lowercased()))))")
        }
        lines[lines.count - 1] += ")"
        if components.isEmpty { lines[lines.count - 1] = "  (components)" }
        // each net with its pads, ground first, then by name
        var nodes: [String: [(ref: String, pad: String)]] = [:]
        for c in components {
            for pin in c.pins where !pin.net.isEmpty { nodes[pin.net, default: []].append((c.ref, pin.pad)) }
        }
        let names = nodes.keys.sorted { a, b in
            let (ga, gb) = (Topology.isGroundName(a), Topology.isGroundName(b))
            return ga != gb ? ga : a < b
        }
        lines.append("  (nets")
        for (code, name) in names.enumerated() {
            let net = Topology.isGroundName(name) ? "GND" : name
            lines.append("    (net (code \"\(code + 1)\") (name \(quoted(net)))")
            for node in nodes[name] ?? [] {
                lines.append("      (node (ref \(quoted(node.ref))) (pin \(quoted(node.pad))) (pintype \"passive\"))")
            }
            lines[lines.count - 1] += ")"
        }
        lines[lines.count - 1] += "))"
        let unassigned = components.filter { $0.footprint.isEmpty }.map(\.ref)
        return Export(text: lines.joined(separator: "\n") + "\n", unassigned: unassigned, components: components.count, nets: names.count)
    }
}
