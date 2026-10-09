import XCTest
@testable import CircuitKit

/// Transistors and diodes at DC against ngspice running the same `.model` cards. `crosscheck.py --devices` sweeps one
/// of a transistor's two sources (base or gate to emitter or source, collector or drain to emitter or source) while the
/// other holds, and records the currents into its base and collector (gate and drain), or sweeps the voltage across a
/// diode and records its current; JSpice solves each point here. Both solve the same equations (Gummel-Poon's, SPICE's
/// diode's and JFET's) to convergence, so they agree to a few parts per million: what is left is how far each converges.
final class DeviceModelTests: XCTestCase {
    struct Reference: Decodable {
        let ngspice: String
        let sweeps: [Sweep]
    }

    struct Sweep: Decodable {
        let id: String
        let note: String
        let kind: String
        let params: [String: Double]
        /// "vbe" or "vce" ("vgs" or "vds"): the source swept through `voltages`, the other held at `fixed`; "vd" across
        /// a diode
        let swept: String
        let fixed: Double
        let voltages: [Double]
        /// The currents into the transistor's base and collector (a JFET's gate and drain), or into the diode's anode
        let base: [Double]?
        let collector: [Double]?
        let gate: [Double]?
        let drain: [Double]?
        let anode: [Double]?
        /// °C, when not the parts' nominal 27 °C
        let temperature: Double?
    }

    /// Relative and absolute agreement asked of each current (the absolute part covers the picoamperes the two
    /// simulators' shunts to ground differ by)
    static let relative = 1e-5
    static let absolute = 5e-12

    /// The currents into the transistor's base and collector (gate and drain) with the sources at `vbe` and `vce`
    private func currents(_ sweep: Sweep, vbe: Double, vce: Double) throws -> (base: Double, collector: Double) {
        let kind = try XCTUnwrap(ElementKind(rawValue: sweep.kind))
        let terminals = kind == .njfet ? ["gate": "b", "drain": "c", "source": "GND"] : ["base": "b", "collector": "c", "emitter": "GND"]
        var circuit = try SchematicLayout.layout([
            NetlistPart(kind: .dcVoltage, name: "VBE", params: ["voltage": vbe], connections: ["plus": "b", "minus": "GND"]),
            NetlistPart(kind: .dcVoltage, name: "VCE", params: ["voltage": vce], connections: ["plus": "c", "minus": "GND"]),
            NetlistPart(kind: kind, name: "Q1", params: sweep.params, connections: terminals),
        ])
        if let temperature = sweep.temperature { circuit.settings.temperature = temperature }
        func index(_ name: String) throws -> Int { try XCTUnwrap(circuit.elements.firstIndex { $0.name == name }, name) }
        // long steps: the stored charges stop charging within three, and what is left is the DC solution
        let simulator = Simulator(circuit: circuit, timeStep: 1)
        for _ in 0..<4 { simulator.step() }
        let at = "\(sweep.id) at \(vbe) V, \(vce) V"
        XCTAssertFalse(simulator.isFailed, "\(at): \(simulator.problems)")
        // the transistor between the two sources (a source's current is what it delivers from its + terminal)
        let q1 = try index("Q1")
        XCTAssertEqual(simulator.terminalVoltage(q1, 0), vbe, accuracy: 1e-9, "\(at): control terminal")
        XCTAssertEqual(simulator.terminalVoltage(q1, 1), vce, accuracy: 1e-9, "\(at): output terminal")
        return (simulator.current(try index("VBE")), simulator.current(try index("VCE")))
    }

    /// The current into a diode's anode with `vd` across it
    private func current(_ sweep: Sweep, vd: Double) throws -> Double {
        let kind = try XCTUnwrap(ElementKind(rawValue: sweep.kind))
        var circuit = try SchematicLayout.layout([
            NetlistPart(kind: .dcVoltage, name: "VD", params: ["voltage": vd], connections: ["plus": "a", "minus": "GND"]),
            NetlistPart(kind: kind, name: "D1", params: sweep.params, connections: ["anode": "a", "cathode": "GND"]),
        ])
        if let temperature = sweep.temperature { circuit.settings.temperature = temperature }
        let simulator = Simulator(circuit: circuit, timeStep: 1)
        for _ in 0..<4 { simulator.step() }
        XCTAssertFalse(simulator.isFailed, "\(sweep.id) at \(vd) V: \(simulator.problems)")
        return simulator.current(try XCTUnwrap(circuit.elements.firstIndex { $0.name == "VD" }))
    }

    func testDevicesMatchNgspiceAtDC() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "spice-device-reference", withExtension: "json", subdirectory: "Fixtures"))
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        var table = ["Devices at DC against \(reference.ngspice) (largest difference, parts per million of the current):"]
        func check(_ value: Double, _ expected: Double, _ what: String) -> Double {
            XCTAssertEqual(value, expected, accuracy: Self.relative * abs(expected) + Self.absolute, what)
            return abs(value - expected) / max(abs(expected), Self.absolute / Self.relative)
        }
        for sweep in reference.sweeps {
            if let anode = sweep.anode {
                var worst = 0.0
                for (k, v) in sweep.voltages.enumerated() {
                    worst = max(worst, check(try current(sweep, vd: v), anode[k], "\(sweep.id): current at \(v) V (\(sweep.note))"))
                }
                table.append("  " + sweep.id.padding(toLength: 18, withPad: " ", startingAt: 0) + String(format: "anode %8.3f ppm", worst * 1e6))
                continue
            }
            let jfet = sweep.kind == ElementKind.njfet.rawValue
            let base = try XCTUnwrap(jfet ? sweep.gate : sweep.base), collector = try XCTUnwrap(jfet ? sweep.drain : sweep.collector)
            let (control, output) = jfet ? ("gate", "drain") : ("base", "collector")
            var worstBase = 0.0, worstCollector = 0.0
            for (k, v) in sweep.voltages.enumerated() {
                let (vbe, vce) = sweep.swept == "vbe" || sweep.swept == "vgs" ? (v, sweep.fixed) : (sweep.fixed, v)
                let ours = try currents(sweep, vbe: vbe, vce: vce)
                let at = jfet ? "at VGS \(vbe) V, VDS \(vce) V (\(sweep.note))" : "at VBE \(vbe) V, VCE \(vce) V (\(sweep.note))"
                worstBase = max(worstBase, check(ours.base, base[k], "\(sweep.id): \(control) current \(at)"))
                worstCollector = max(worstCollector, check(ours.collector, collector[k], "\(sweep.id): \(output) current \(at)"))
            }
            table.append("  " + sweep.id.padding(toLength: 18, withPad: " ", startingAt: 0)
                         + "\(control) " + String(format: "%8.3f ppm  ", worstBase * 1e6)
                         + "\(output) " + String(format: "%8.3f ppm", worstCollector * 1e6))
        }
        print(table.joined(separator: "\n"))
    }

    /// An ammeter in series with each terminal of a transistor reads the current the terminal takes: the base's and
    /// the collector's from their sources, the emitter's their sum
    func testAmmetersReadATransistorsCurrents() throws {
        let circuit = try SchematicLayout.layout([
            NetlistPart(kind: .dcVoltage, name: "VCC", params: ["voltage": 9], connections: ["plus": "vcc", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "RB", params: ["resistance": 470_000], connections: ["a": "vcc", "b": "vb"]),
            NetlistPart(kind: .ammeter, name: "AB", params: [:], connections: ["in": "vb", "out": "b"]),
            NetlistPart(kind: .resistor, name: "RC", params: ["resistance": 2200], connections: ["a": "vcc", "b": "vc"]),
            NetlistPart(kind: .ammeter, name: "AC", params: [:], connections: ["in": "vc", "out": "c"]),
            NetlistPart(kind: .npn, name: "Q1", params: ["beta": 200], connections: ["base": "b", "collector": "c", "emitter": "e"]),
            NetlistPart(kind: .ammeter, name: "AE", params: [:], connections: ["in": "e", "out": "GND"]),
        ])
        func index(_ name: String) throws -> Int { try XCTUnwrap(circuit.elements.firstIndex { $0.name == name }, name) }
        let simulator = Simulator(circuit: circuit, timeStep: 1e-4)
        for _ in 0..<20 { simulator.step() }
        let q1 = try index("Q1")
        let vb = simulator.terminalVoltage(q1, 0), vc = simulator.terminalVoltage(q1, 1)
        let base = (9 - vb) / 470_000, collector = (9 - vc) / 2200
        let readings = "AB \(simulator.current(try index("AB"))) A, AC \(simulator.current(try index("AC"))) A, AE "
            + "\(simulator.current(try index("AE"))) A; through RB \(base) A, RC \(collector) A, Q1 \(simulator.current(q1)) A"
        XCTAssertEqual(simulator.current(try index("AB")), base, accuracy: base * 1e-6, readings)
        XCTAssertEqual(simulator.current(try index("AC")), collector, accuracy: collector * 1e-6, readings)
        XCTAssertEqual(simulator.current(try index("AE")), base + collector, accuracy: collector * 1e-6, readings)
    }

    /// A manufacturer's card, read from a netlist, is the transistor it describes: every parameter JSpice models kept
    /// under its own key, and what it leaves out named
    func testImportedCardKeepsEveryParameter() throws {
        let text = """
        card import
        VCC vcc 0 12
        Q1 vcc b 0 QX
        RB vcc b 1meg
        .model QX NPN(IS=6.734f XTI=3 EG=1.11 VAF=74.03 BF=416.4 NE=1.259 ISE=6.734f IKF=66.78m XTB=1.5 BR=.7371
        + NC=2 ISC=0 IKR=0 RC=1 CJC=3.638p MJC=.3085 VJC=.75 FC=.5 CJE=4.493p MJE=.2593 VJE=.75 TR=239.5n TF=301.2p
        + ITF=.4 VTF=4 XTF=2 RB=10 PTF=12)
        .end
        """
        let imported = SpiceNetlist.parse(text)
        let q1 = try XCTUnwrap(imported.parts.first { $0.name == "Q1" })
        XCTAssertEqual(q1.params["vaf"], 74.03)
        XCTAssertEqual(q1.params["beta"], 416.4)
        XCTAssertEqual(try XCTUnwrap(q1.params["ikf"]), 66.78e-3, accuracy: 1e-15)
        XCTAssertEqual(q1.params["rb"], 10)
        XCTAssertEqual(try XCTUnwrap(q1.params["tr"]), 239.5e-9, accuracy: 1e-20)
        XCTAssertEqual(q1.params["br"], 0.7371)
        XCTAssertEqual(q1.params["cjc"], 3.638e-12)
        XCTAssertTrue(imported.warnings.contains { $0.contains("PTF") }, "\(imported.warnings)")
        // and it exports as the same card
        let (circuit, _) = try SpiceNetlist.circuit(from: text)
        let deck = SpiceNetlist.export(circuit)
        for word in ["VAF=74.03", "BF=416.4", "IKF=0.06678", "RB=10", "RC=1", "TR=2.395e-07", "XTB=1.5", "BR=0.7371"] {
            XCTAssertTrue(deck.contains(word), "\(word) in \(deck)")
        }
    }

    /// A diode's card the same way: a rectifier's (BV at its rating) stays a diode, one breaking down below 40 V is
    /// drawn as a Zener, and both export as the cards they were (a Zener's BV included at JSpice's default)
    func testImportedDiodeCardKeepsEveryParameter() throws {
        let text = """
        diode cards
        V1 in 0 SIN(0 10 1k)
        R1 in a 1k
        D1 a 0 DR
        R2 in z 1k
        D2 0 z DZ
        .model DR D(IS=2.5n RS=0.6 N=1.8 CJO=4p M=0.33 VJ=0.7 TT=6n BV=100 IBV=100n IKF=0.1 EG=1.11 XTI=3 TCV=0)
        .model DZ D(IS=1f N=1.1 RS=2 BV=5.1 IBV=5m NBV=1.5 CJO=50p ISR=1n)
        .end
        """
        let imported = SpiceNetlist.parse(text)
        let d1 = try XCTUnwrap(imported.parts.first { $0.name == "D1" })
        XCTAssertEqual(d1.kind, .diode)
        XCTAssertEqual(d1.params["rs"], 0.6)
        XCTAssertEqual(d1.params["bv"], 100)
        XCTAssertEqual(try XCTUnwrap(d1.params["ibv"]), 100e-9, accuracy: 1e-20)
        XCTAssertEqual(d1.params["ikf"], 0.1)
        XCTAssertEqual(d1.params["m"], 0.33)
        let d2 = try XCTUnwrap(imported.parts.first { $0.name == "D2" })
        XCTAssertEqual(d2.kind, .zener)
        XCTAssertEqual(d2.params["breakdown"], 5.1)
        XCTAssertEqual(d2.params["nbv"], 1.5)
        XCTAssertTrue(imported.warnings.contains { $0.contains("D2") && $0.contains("ISR") }, "\(imported.warnings)")
        XCTAssertFalse(imported.warnings.contains { $0.contains("D1") }, "TCV=0 makes no difference: \(imported.warnings)")
        let (circuit, _) = try SpiceNetlist.circuit(from: text)
        let deck = SpiceNetlist.export(circuit)
        for word in ["RS=0.6", "BV=100", "IBV=1e-07", "IKF=0.1", "M=0.33", "VJ=0.7", "TT=6e-09", "BV=5.1", "IBV=0.005", "NBV=1.5"] {
            XCTAssertTrue(deck.contains(word), "\(word) in \(deck)")
        }
        // a drawn Zener at its defaults keeps its breakdown voltage
        let drawn = try SchematicLayout.layout([
            NetlistPart(kind: .zener, name: "DZ1", params: [:], connections: ["anode": "GND", "cathode": "z"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 1000], connections: ["a": "z", "b": "GND"]),
        ])
        XCTAssertTrue(SpiceNetlist.export(drawn).contains("BV=5.1 IBV=0.005"), SpiceNetlist.export(drawn))
    }

    /// The internal nodes a transistor's resistances add: none at JSpice's defaults, one for each resistance given
    func testResistancesAddInternalNodes() throws {
        func nodes(_ params: [String: Double]) throws -> Int {
            let circuit = try SchematicLayout.layout([
                NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 5], connections: ["plus": "vcc", "minus": "GND"]),
                NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 100_000], connections: ["a": "vcc", "b": "b"]),
                NetlistPart(kind: .npn, name: "Q1", params: params, connections: ["base": "b", "collector": "vcc", "emitter": "GND"]),
            ])
            let simulator = Simulator(circuit: circuit, timeStep: 1e-5)
            return simulator.nodes(of: try XCTUnwrap(circuit.elements.firstIndex { $0.name == "Q1" })).count
        }
        XCTAssertEqual(try nodes([:]), 3)
        XCTAssertEqual(try nodes(["rb": 10]), 4)
        XCTAssertEqual(try nodes(["rb": 10, "rc": 1, "re": 0.5]), 6)
    }
}
