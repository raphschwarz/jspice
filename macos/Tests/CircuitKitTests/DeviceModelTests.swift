import XCTest
@testable import CircuitKit

/// Transistors at DC against ngspice running the same `.model` cards. `crosscheck.py --devices` sweeps one of a
/// transistor's two sources (base to emitter, or collector to emitter) while the other holds, and records the currents
/// into its base and collector; JSpice solves each point here. Both solve the same Gummel-Poon equations to convergence,
/// so they agree to a few parts per million: what is left is how far each converges.
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
        /// "vbe" or "vce": the source swept through `voltages`, the other held at `fixed`
        let swept: String
        let fixed: Double
        let voltages: [Double]
        /// The currents into the transistor's base and collector
        let base: [Double]
        let collector: [Double]
        /// °C, when not the parts' nominal 27 °C
        let temperature: Double?
    }

    /// Relative and absolute agreement asked of each current (the absolute part covers the picoamperes the two
    /// simulators' shunts to ground differ by)
    static let relative = 1e-5
    static let absolute = 5e-12

    /// The currents into the transistor's base and collector with the sources at `vbe` and `vce`
    private func currents(_ sweep: Sweep, vbe: Double, vce: Double) throws -> (base: Double, collector: Double) {
        let kind = try XCTUnwrap(ElementKind(rawValue: sweep.kind))
        var circuit = try SchematicLayout.layout([
            NetlistPart(kind: .dcVoltage, name: "VBE", params: ["voltage": vbe], connections: ["plus": "vb", "minus": "GND"]),
            NetlistPart(kind: .ammeter, name: "AB", params: [:], connections: ["in": "vb", "out": "b"]),
            NetlistPart(kind: .dcVoltage, name: "VCE", params: ["voltage": vce], connections: ["plus": "vc", "minus": "GND"]),
            NetlistPart(kind: .ammeter, name: "AC", params: [:], connections: ["in": "vc", "out": "c"]),
            NetlistPart(kind: kind, name: "Q1", params: sweep.params, connections: ["base": "b", "collector": "c", "emitter": "GND"]),
        ])
        if let temperature = sweep.temperature { circuit.settings.temperature = temperature }
        func index(_ name: String) throws -> Int { try XCTUnwrap(circuit.elements.firstIndex { $0.name == name }, name) }
        // long steps: the stored charges stop charging within three, and what is left is the DC solution
        let simulator = Simulator(circuit: circuit, timeStep: 1)
        for _ in 0..<4 { simulator.step() }
        XCTAssertFalse(simulator.isFailed, "\(sweep.id) at VBE \(vbe) V, VCE \(vce) V: \(simulator.problems)")
        return (simulator.current(try index("AB")), simulator.current(try index("AC")))
    }

    func testTransistorsMatchNgspiceAtDC() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "spice-device-reference", withExtension: "json", subdirectory: "Fixtures"))
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        var table = ["Transistors at DC against \(reference.ngspice) (largest difference, parts per million of the current):"]
        for sweep in reference.sweeps {
            var worstBase = 0.0, worstCollector = 0.0
            for (k, v) in sweep.voltages.enumerated() {
                let (vbe, vce) = sweep.swept == "vbe" ? (v, sweep.fixed) : (sweep.fixed, v)
                let ours = try currents(sweep, vbe: vbe, vce: vce)
                for (name, value, expected) in [("base", ours.base, sweep.base[k]), ("collector", ours.collector, sweep.collector[k])] {
                    let limit = Self.relative * abs(expected) + Self.absolute
                    XCTAssertEqual(value, expected, accuracy: limit,
                                   "\(sweep.id): \(name) current at VBE \(vbe) V, VCE \(vce) V (\(sweep.note))")
                    let error = abs(value - expected) / max(abs(expected), Self.absolute / Self.relative)
                    if name == "base" { worstBase = max(worstBase, error) } else { worstCollector = max(worstCollector, error) }
                }
            }
            table.append("  " + sweep.id.padding(toLength: 18, withPad: " ", startingAt: 0)
                         + String(format: "base %8.3f ppm  collector %8.3f ppm", worstBase * 1e6, worstCollector * 1e6))
        }
        print(table.joined(separator: "\n"))
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
