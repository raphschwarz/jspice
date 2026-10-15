import Foundation
import KiCadKit

/// What a circuit says about its printed circuit board beyond its parts and wires: the footprints chosen where JSpice's
/// own choice will not do, the parts left off the board or not fitted, and the chips' units as the board has them
/// packed, so that the board keeps its layout as the schematic changes. Saved with the circuit.
public struct PCBDesign: Codable, Hashable, Sendable {
    /// Each part's footprint where it is not the one JSpice would choose ("Resistor_SMD:R_1206_3216Metric"), by the
    /// part's id
    public var footprints: [String: String] = [:]
    /// A transistor's legs in the order of its footprint's pads ("EBC", "BCE", "GDS"), where not the part's own
    public var pinouts: [String: String] = [:]
    /// Parts not on the board (a probe, a source that stands for what is wired to the board)
    public var offBoard: Set<String> = []
    /// Parts on the board but not fitted
    public var doNotPopulate: Set<String> = []
    /// Each chip unit's package and place in it (U1, unit 0 for A), as the board has them
    public var units: [String: Unit] = [:]
    /// The references of what has none of its own in the schematic (packages of several units, pin headers for supplies),
    /// by the id the board links them by
    public var references: [String: String] = [:]
    /// Through-hole or surface-mount parts, where a part has no footprint of its own
    public var style: Style = .throughHole
    /// The board's file, relative to the circuit's (by default the circuit's name with .kicad_pcb)
    public var board: String?
    /// Copper layers for a new board: 2, 4 or 6
    public var copperLayers: Int = 2
    /// What the board had of each part when the two were last brought together, by the path its footprint is linked
    /// by: the common ground from which a difference is known to be the board's (to bring back to the schematic) or the
    /// schematic's (to take to the board)
    public var synced: [String: Synced] = [:]

    public struct Synced: Codable, Hashable, Sendable {
        public var reference: String
        public var value: String
        public var footprint: String
        public var doNotPopulate: Bool

        public init(reference: String, value: String, footprint: String, doNotPopulate: Bool) {
            (self.reference, self.value, self.footprint, self.doNotPopulate) = (reference, value, footprint, doNotPopulate)
        }
    }

    public struct Unit: Codable, Hashable, Sendable {
        public var package: String
        public var unit: Int

        public init(package: String, unit: Int) { self.package = package; self.unit = unit }
    }

    public enum Style: String, Codable, CaseIterable, Sendable, Identifiable {
        case throughHole
        case surfaceMount

        public var id: String { rawValue }
        public var title: String { self == .throughHole ? "Through-hole" : "Surface-mount" }
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        footprints = try c.decodeIfPresent([String: String].self, forKey: .footprints) ?? [:]
        pinouts = try c.decodeIfPresent([String: String].self, forKey: .pinouts) ?? [:]
        offBoard = try c.decodeIfPresent(Set<String>.self, forKey: .offBoard) ?? []
        doNotPopulate = try c.decodeIfPresent(Set<String>.self, forKey: .doNotPopulate) ?? []
        units = try c.decodeIfPresent([String: Unit].self, forKey: .units) ?? [:]
        references = try c.decodeIfPresent([String: String].self, forKey: .references) ?? [:]
        style = try c.decodeIfPresent(Style.self, forKey: .style) ?? .throughHole
        board = try c.decodeIfPresent(String.self, forKey: .board)
        copperLayers = try c.decodeIfPresent(Int.self, forKey: .copperLayers) ?? 2
        synced = try c.decodeIfPresent([String: Synced].self, forKey: .synced) ?? [:]
    }
}

/// The circuit as KiCad's board sees it: KiCad's netlist of the parts that go on the board (as the breadboard has them,
/// op-amps and gates packed into their chips with the supplies the chips need, supplies and what is wired from off
/// the board on pin headers), each on a footprint from KiCad's libraries with its pads numbered as KiCad numbers
/// them, each linked to the parts of the schematic it stands for by their ids
public enum PCBNetlistBuilder {
    public struct Result: Sendable {
        public var netlist: PCBNetlist
        /// The design with the packing and the references used, to keep them the same from one update to the next
        public var design: PCBDesign
        /// What to know: supplies the chips need that the circuit leaves implicit, electrolytics whose polarity the
        /// circuit's resting voltages could not settle
        public var notes: [String]
        /// The parts left without a footprint
        public var unassigned: [String]
        /// The schematic's parts each component stands for, by reference
        public var parts: [String: [UUID]]
    }

    // footprints of KiCad's standard libraries
    static let resistorTHT = "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal"
    static let resistorSMD = "Resistor_SMD:R_0805_2012Metric"
    static let ceramicTHT = "Capacitor_THT:C_Disc_D5.0mm_W2.5mm_P5.00mm"
    static let ceramicSMD = "Capacitor_SMD:C_0805_2012Metric"
    static let inductorTHT = "Inductor_THT:L_Axial_L5.3mm_D2.2mm_P10.16mm_Horizontal_Vishay_IM-1"
    static let inductorSMD = "Inductor_SMD:L_0805_2012Metric"
    static let signalDiodeTHT = "Diode_THT:D_DO-35_SOD27_P7.62mm_Horizontal"
    static let signalDiodeSMD = "Diode_SMD:D_SOD-123"
    static let rectifierTHT = "Diode_THT:D_DO-41_SOD81_P10.16mm_Horizontal"
    static let rectifierSMD = "Diode_SMD:D_SMA"
    static let ledTHT = "LED_THT:LED_D5.0mm"
    static let ledSMD = "LED_SMD:LED_0805_2012Metric"
    static let to92 = "Package_TO_SOT_THT:TO-92_Inline"
    static let sot23 = "Package_TO_SOT_SMD:SOT-23"
    static let pot = "Potentiometer_THT:Potentiometer_Alpha_RD901F-40-00D_Single_Vertical"

    /// A radial electrolytic big enough for its capacitance
    static func electrolytic(_ farads: Double, _ style: PCBDesign.Style) -> String {
        if style == .surfaceMount {
            switch farads {
            case ..<27e-6: return "Capacitor_SMD:CP_Elec_4x5.4"
            case ..<56e-6: return "Capacitor_SMD:CP_Elec_5x5.4"
            case ..<120e-6: return "Capacitor_SMD:CP_Elec_6.3x5.4"
            case ..<270e-6: return "Capacitor_SMD:CP_Elec_8x6.2"
            default: return "Capacitor_SMD:CP_Elec_10x10"
            }
        }
        switch farads {
        case ..<56e-6: return "Capacitor_THT:CP_Radial_D5.0mm_P2.00mm"
        case ..<270e-6: return "Capacitor_THT:CP_Radial_D6.3mm_P2.50mm"
        case ..<560e-6: return "Capacitor_THT:CP_Radial_D8.0mm_P3.50mm"
        default: return "Capacitor_THT:CP_Radial_D10.0mm_P5.00mm"
        }
    }

    /// A chip's package: dual in line (0.3 in wide up to 28 pins, 0.6 in above), or small outline for surface mount
    static func chip(_ pins: Int, _ style: PCBDesign.Style) -> String {
        if style == .surfaceMount {
            switch pins {
            case 8: return "Package_SO:SOIC-8_3.9x4.9mm_P1.27mm"
            case 14: return "Package_SO:SOIC-14_3.9x8.7mm_P1.27mm"
            case 16: return "Package_SO:SOIC-16_3.9x9.9mm_P1.27mm"
            case 18: return "Package_SO:SOIC-18W_7.5x11.6mm_P1.27mm"
            case 20: return "Package_SO:SOIC-20W_7.5x12.8mm_P1.27mm"
            case 24: return "Package_SO:SOIC-24W_7.5x15.4mm_P1.27mm"
            case 28: return "Package_SO:SOIC-28W_7.5x17.9mm_P1.27mm"
            default: break
            }
        }
        return "Package_DIP:DIP-\(pins)_W\(pins > 28 ? "15.24" : "7.62")mm"
    }

    /// A single row of 0.1 in header pins
    static func header(_ pins: Int) -> String {
        "Connector_PinHeader_2.54mm:PinHeader_1x" + String(format: "%02d", max(1, pins)) + "_P2.54mm_Vertical"
    }

    /// A value as KiCad's schematics write one: 10k, 4.7k, 100n, 10u
    public static func compact(_ value: Double) -> String {
        SI.format(value, unit: "").replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "µ", with: "u")
            .replacingOccurrences(of: "−", with: "-")
    }

    /// A net's name as it goes on the board: in ASCII
    static func boardNet(_ name: String) -> String {
        Topology.isGroundName(name) ? "GND" : name.replacingOccurrences(of: "−", with: "-")
    }

    struct Draft {
        var component: PCBNetlist.Component
        /// Each pad's net as the schematic names it, before unnamed nets are named for the board
        var nets: [String: String]
        var types: [String: (function: String, type: String)]
        var pads: [String]
        var parts: [UUID]
    }

    /// The board netlist of `circuit`, as `design` (the circuit's own by default) would have it
    public static func netlist(_ circuit: Circuit, design: PCBDesign? = nil) -> Result {
        var design = design ?? circuit.pcb ?? PCBDesign()
        let style = design.style
        var packing: [UUID: (package: String, unit: Int)] = [:]
        for (id, unit) in design.units { if let uuid = UUID(uuidString: id) { packing[uuid] = (unit.package, unit.unit) } }
        let plan = Breadboard.plan(circuit, packing: packing)
        let elements = Dictionary(circuit.elements.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var drafts: [Draft] = []
        var used = Set(plan.parts.map(\.name) + plan.packs.map(\.name))
        func fresh(_ prefix: String, key: String) -> String {
            if let kept = design.references[key], !kept.isEmpty, !used.contains(kept) {
                used.insert(kept)
                return kept
            }
            var k = 1
            while used.contains("\(prefix)\(k)") { k += 1 }
            used.insert("\(prefix)\(k)")
            return "\(prefix)\(k)"
        }
        func id(_ part: NetlistPart) -> UUID { part.id ?? KiCadNetlist.uuid("part " + part.name) }
        func hint(_ ids: [UUID]) -> KiCadPoint? {
            guard let e = ids.lazy.compactMap({ elements[$0] }).first else { return nil }
            return KiCadPoint(Double(e.a.x + e.b.x) / 2, Double(e.a.y + e.b.y) / 2)
        }
        func footprint(_ ids: [UUID], _ fallback: String) -> String {
            ids.lazy.compactMap { design.footprints[$0.uuidString] }.first ?? fallback
        }
        func add(reference: String, value: String, footprint: String, description: String, ids: [UUID],
                 nets: [(pad: String, net: String?, function: String, type: String)], parts: [UUID], fields: [(String, String)] = []) {
            var component = PCBNetlist.Component(reference: reference, value: value, footprint: footprint,
                                                 ids: ids.map { $0.uuidString.lowercased() }, pins: [:])
            component.fields = [("Datasheet", ""), ("Description", description)] + fields
            component.placementHint = hint(parts)
            component.excludeFromBoard = parts.contains { design.offBoard.contains($0.uuidString) }
            component.doNotPopulate = parts.contains { design.doNotPopulate.contains($0.uuidString) }
            var draft = Draft(component: component, nets: [:], types: [:], pads: nets.map(\.pad), parts: parts)
            for pin in nets {
                if let net = pin.net, !net.isEmpty { draft.nets[pin.pad] = net }
                draft.types[pin.pad] = (pin.function, pin.type)
            }
            drafts.append(draft)
        }

        // chips: the package's pins, its units recorded for the next update
        var units: [String: PCBDesign.Unit] = [:]
        for pack in plan.packs {
            let netOfPin = plan.pins(pack)
            let ids = pack.units.map { id($0.part) }
            let supplies = Set(pack.package.supplies.map(\.pin))
            let outputs = Set(pack.package.units.compactMap { $0["out"] })
            let pins = (1...pack.package.pins).map { pin -> (pad: String, net: String?, function: String, type: String) in
                let type = supplies.contains(pin) ? "power_in" : outputs.contains(pin) ? "output" : netOfPin[pin] == nil ? "passive" : "input"
                return ("\(pin)", netOfPin[pin]?.net, netOfPin[pin]?.label ?? pack.package.labels[pin] ?? "", type)
            }
            let roles = pack.units.count > 1
                ? ": " + pack.units.map { "\(Character(UnicodeScalar(UInt8(65 + $0.unit)))) \($0.part.name)" }.joined(separator: ", ") : ""
            add(reference: pack.name, value: pack.package.title, footprint: footprint(ids, chip(pack.package.pins, style)),
                description: pack.package.title + roles, ids: ids, nets: pins, parts: ids)
            drafts[drafts.count - 1].component.units = pack.package.units.count > 1
                ? pack.package.units.enumerated().map { u, pins in
                    PCBNetlist.Unit(name: String(Character(UnicodeScalar(UInt8(65 + u)))), pins: pins.values.sorted().map(String.init))
                } : []
            for (part, unit) in pack.units { units[id(part).uuidString] = PCBDesign.Unit(package: pack.name, unit: unit) }
        }
        // transistors, pots, vactrols: pads in the order of their legs on their footprints
        for part in plan.inline {
            let partID = id(part)
            let (order, kind, title, _) = Breadboard.inline(part, facing: "")
            var fp: String
            var legs = order
            switch kind {
            case .transistor:
                fp = footprint([partID], style == .surfaceMount ? sot23 : to92)
                if fp.contains("SOT-23") || fp.contains("SOT-323") {
                    // JEDEC's small-outline order: B E C, G S D, D S G
                    switch part.kind {
                    case .npn, .pnp: legs = ["base", "emitter", "collector"]
                    case .nmos, .pmos: legs = ["gate", "source", "drain"]
                    default: legs = ["drain", "source", "gate"]
                    }
                }
            case .pot: fp = footprint([partID], pot)
            default: fp = footprint([partID], "")
            }
            if let pinout = design.pinouts[partID.uuidString], !pinout.isEmpty {
                let letter: [Character: String] = ["E": "emitter", "B": "base", "C": "collector", "D": "drain", "S": "source", "G": "gate"]
                let mapped = pinout.uppercased().compactMap { letter[$0] }
                if mapped.count == legs.count { legs = mapped }
            }
            var value = title
            if part.kind == .potentiometer {
                value = compact(part.params["resistance"] ?? 10_000) + ((part.params["taper"] ?? 0) >= 0.5 ? " A" : " B")
            }
            let pins = legs.enumerated().map { (pad: "\($0.offset + 1)", net: part.connections[$0.element], function: $0.element, type: "passive") }
            add(reference: part.name, value: value, footprint: fp, description: part.kind.displayName, ids: [partID], nets: pins, parts: [partID])
        }
        // two-lead parts
        for part in plan.twoLead {
            let partID = id(part)
            let terminals = part.kind.terminalNames
            let (kind, title, _) = Breadboard.describe(part, plan.voltages)
            let net = { (terminal: String) in part.connections[terminal] }
            var pins: [(pad: String, net: String?, function: String, type: String)] = [("1", net(terminals[0]), terminals[0], "passive"),
                                                                                    ("2", net(terminals[1]), terminals[1], "passive")]
            var fp = ""
            var value = title
            var fields: [(String, String)] = []
            switch kind {
            case .resistor:
                fp = style == .surfaceMount ? resistorSMD : resistorTHT
                value = compact(part.params["resistance"] ?? 0)
            case .ceramic:
                fp = style == .surfaceMount ? ceramicSMD : ceramicTHT
                value = compact(part.params["capacitance"] ?? 0)
            case .electrolytic:
                let farads = part.params["capacitance"] ?? 0
                fp = electrolytic(farads, style)
                value = compact(farads)
                if let rating = title.split(separator: " ").dropFirst(2).first { fields.append(("Voltage", rating + "V")) }
                // + (pad 1) on the higher voltage
                let (a, b) = (net(terminals[0]).flatMap { plan.voltages[$0] } ?? 0, net(terminals[1]).flatMap { plan.voltages[$0] } ?? 0)
                pins = [("1", net(terminals[0]), "+", "passive"), ("2", net(terminals[1]), "-", "passive")]
                if b > a { pins = [("1", net(terminals[1]), "+", "passive"), ("2", net(terminals[0]), "-", "passive")] }
            case .inductor:
                // an audio choke is too big for a small axial part: left for KiCad's footprint assignment
                if (part.params["inductance"] ?? 0) <= 1e-3 { fp = style == .surfaceMount ? inductorSMD : inductorTHT }
                value = compact(part.params["inductance"] ?? 0)
            case .diode, .zener, .led:
                // KiCad's diodes and LEDs: pad 1 the cathode, pad 2 the anode
                let rectifier = title.hasPrefix("1N40") || title.hasPrefix("1N54") || title.hasPrefix("1N58") || title.hasPrefix("1N47")
                fp = part.kind == .led ? (style == .surfaceMount ? ledSMD : ledTHT)
                    : rectifier ? (style == .surfaceMount ? rectifierSMD : rectifierTHT) : (style == .surfaceMount ? signalDiodeSMD : signalDiodeTHT)
                pins = [("1", net("cathode"), "K", "passive"), ("2", net("anode"), "A", "passive")]
            case .toggle, .button:
                // on the panel, wired to the board
                fp = header(2)
            default:
                fp = ""
            }
            add(reference: part.name, value: value, footprint: footprint([partID], fp), description: part.kind.displayName,
                ids: [partID], nets: pins, parts: [partID], fields: fields)
        }
        // off the board: supplies, then sources, speakers and modules, each on a pin header
        for supply in plan.wiredSupplies {
            let key = KiCadNetlist.uuid("supply " + supply.net)
            let source = plan.parts.first { $0.kind == .dcVoltage && $0.connections.values.contains(supply.net) }
            let reference = fresh("J", key: key.uuidString.lowercased())
            add(reference: reference, value: "Power \(SI.format(supply.volts, unit: "V"))", footprint: footprint(source.map { [id($0)] } ?? [], header(2)),
                description: "Supply \(supply.name): + and common", ids: [key],
                nets: [("1", supply.net, "+", "power_in"), ("2", "GND", "common", "power_in")], parts: source.map { [id($0)] } ?? [])
        }
        for part in plan.offBoardParts {
            let terminals = part.terminalNames.filter { part.connections[$0] != nil }
            guard !terminals.isEmpty else { continue }
            let pins = terminals.enumerated().map { (pad: "\($0.offset + 1)", net: part.connections[$0.element], function: $0.element, type: "passive") }
            add(reference: part.name, value: Breadboard.offBoardTitle(part), footprint: footprint([id(part)], header(pins.count)),
                description: "Wired from off the board: " + terminals.joined(separator: ", "), ids: [id(part)], nets: pins, parts: [id(part)])
        }

        // nets the schematic leaves unnamed (N1, N2…, whose numbers move as it changes) named as KiCad names them,
        // after their first pad: Net-(R1-Pad2)
        let named = Set(circuit.elements.filter { $0.kind == .netLabel }.map { $0.name.trimmingCharacters(in: .whitespaces) })
            .union(circuit.netNames.values)
        func isUnnamed(_ net: String) -> Bool {
            net.count > 1 && net.first == "N" && net.dropFirst().allSatisfy(\.isNumber) && !named.contains(net)
        }
        var firstPad: [String: (ref: String, pad: String)] = [:]
        for draft in drafts where !draft.component.excludeFromBoard {
            for (pad, net) in draft.nets where isUnnamed(net) {
                let candidate = (ref: draft.component.reference, pad: pad)
                if let current = firstPad[net] {
                    let r = candidate.ref.localizedStandardCompare(current.ref)
                    if r == .orderedAscending || (r == .orderedSame && candidate.pad.localizedStandardCompare(current.pad) == .orderedAscending) {
                        firstPad[net] = candidate
                    }
                } else {
                    firstPad[net] = candidate
                }
            }
        }
        var components: [PCBNetlist.Component] = []
        var parts: [String: [UUID]] = [:]
        for draft in drafts {
            var component = draft.component
            for pad in draft.pads {
                let (function, type) = draft.types[pad] ?? ("", "passive")
                if let net = draft.nets[pad] {
                    let name = isUnnamed(net) ? firstPad[net].map { "Net-(\($0.ref)-Pad\($0.pad))" } ?? net : boardNet(net)
                    component.pins[pad] = PCBNetlist.Pin(net: name, function: function, type: type)
                } else {
                    // a pin left free: on a net of its own, as KiCad's schematic puts it
                    component.pins[pad] = PCBNetlist.Pin(net: "unconnected-(\(component.reference)-Pad\(pad))", function: function,
                                                         type: type + "+no_connect")
                }
            }
            components.append(component)
            parts[component.reference] = draft.parts
        }

        design.units = units
        var references: [String: String] = [:]
        for c in components where c.reference.hasPrefix("J") || c.ids.count > 1 { references[c.ids.first ?? ""] = c.reference }
        design.references = references
        return Result(netlist: PCBNetlist(components: components), design: design, notes: plan.supplyNotes,
                      unassigned: components.filter { $0.footprint.isEmpty && !$0.excludeFromBoard }.map(\.reference), parts: parts)
    }
}
