import XCTest
@testable import CircuitKit

/// SPICE netlists in and out
final class SpiceNetlistTests: XCTestCase {
    func testValues() {
        XCTAssertEqual(SpiceNetlist.value("4.7k"), 4700)
        XCTAssertEqual(SpiceNetlist.value("10meg"), 1e7)
        XCTAssertEqual(SpiceNetlist.value("1M"), 1e-3, "M is milli in SPICE")
        XCTAssertEqual(SpiceNetlist.value("100nF")!, 1e-7, accuracy: 1e-20)
        XCTAssertEqual(SpiceNetlist.value("2.2u")!, 2.2e-6, accuracy: 1e-18)
        XCTAssertEqual(SpiceNetlist.value("1e3"), 1000)
        XCTAssertEqual(SpiceNetlist.value("5V"), 5)
        XCTAssertNil(SpiceNetlist.value("abc"))
    }

    static let commonEmitter = """
    * common emitter amplifier
    VCC vcc 0 DC 12
    VIN sig 0 SIN(0 50m 1k) AC 1
    RB1 vcc base 47k
    RB2 base 0 10k ; the bias divider
    RC vcc col 4.7k
    RE emi 0 1k
    CE emi 0 10u
    CIN sig base
    + 1u
    Q1 col base emi QGEN
    .model QGEN NPN(IS=1e-14 BF=150 CJE=1p
    + CJC=1p)
    .tran 1u 10m
    .end
    """

    func testImportsAnAmplifier() throws {
        let imported = SpiceNetlist.parse(Self.commonEmitter)
        XCTAssertEqual(imported.title, "common emitter amplifier")
        XCTAssertTrue(imported.warnings.isEmpty, "\(imported.warnings)")
        XCTAssertEqual(imported.parts.count, 9)
        let q1 = try XCTUnwrap(imported.parts.first { $0.name == "Q1" })
        XCTAssertEqual(q1.kind, .npn)
        XCTAssertEqual(q1.params["beta"], 150)
        XCTAssertEqual(q1.params["cjc"], 1e-12)
        XCTAssertEqual(q1.connections, ["collector": "col", "base": "base", "emitter": "emi"])
        let vin = try XCTUnwrap(imported.parts.first { $0.name == "VIN" })
        XCTAssertEqual(vin.kind, .acVoltage)
        XCTAssertEqual(vin.params["amplitude"], 0.05)
        XCTAssertEqual(vin.params["frequency"], 1000)
        XCTAssertEqual(imported.parts.first { $0.name == "CIN" }?.params["capacitance"], 1e-6, "a continued line")
        XCTAssertEqual(imported.parts.first { $0.name == "RB2" }?.connections["b"], "GND")
        // drawn and simulated: the collector biased about half way down
        let (circuit, _) = try SpiceNetlist.circuit(from: Self.commonEmitter)
        let index = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "Q1" })
        let source = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "VIN" })
        let simulator = Simulator.settled(circuit, holding: source, duration: 0.5)
        XCTAssertTrue(simulator.problems.isEmpty, "\(simulator.problems)")
        let collector = simulator.terminalVoltages(index)[1]
        XCTAssertGreaterThan(collector, 3)
        XCTAssertLessThan(collector, 9)
    }

    func testCoupledInductorsBecomeATransformer() throws {
        let imported = SpiceNetlist.parse("""
        transformer
        V1 p 0 SIN(0 10 50)
        L1 p 0 10
        L2 s 0 0.1
        K1 L1 L2 0.99
        R1 s 0 100
        """)
        XCTAssertEqual(imported.parts.count, 3)
        let t = try XCTUnwrap(imported.parts.first { $0.kind == .transformer })
        XCTAssertEqual(t.params["ratio"] ?? 0, 0.1, accuracy: 1e-12)
        XCTAssertEqual(t.params["coupling"], 0.99)
        XCTAssertEqual(t.connections, ["p1": "p", "p2": "GND", "s1": "s", "s2": "GND"])
    }

    func testSubcircuitsBecomeBlocks() throws {
        let text = """
        two RC sections
        .subckt RCLP in out
        R1 in out 1k
        C1 out 0 1u
        .ends RCLP
        V1 a 0 SIN(0 1 100)
        X1 a b RCLP
        X2 b c RCLP
        E1 d 0 c 0 10
        """
        let imported = SpiceNetlist.parse(text)
        let blocks = imported.parts.filter { $0.kind == .block }
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].block?.terminalNames.sorted(), ["in", "out"])
        XCTAssertEqual(blocks[1].connections, ["in": "b", "out": "c"])
        XCTAssertEqual(imported.warnings.count, 1, "the E source is left out")
        let (circuit, _) = try SpiceNetlist.circuit(from: text)
        // two poles at 159 Hz, loading each other
        let source = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "V1" })
        let simulator = Simulator.settled(circuit, holding: source, duration: 0.01)
        let x2 = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "X2" })
        let model = try XCTUnwrap(simulator.smallSignalModel())
        let out = simulator.nodes(of: x2)[try XCTUnwrap(circuit.elements[x2].terminalNames.firstIndex(of: "out"))]
        let gain = try XCTUnwrap(model.solve(input: source, frequencies: [1])?.first?[out])
        XCTAssertEqual(gain.magnitude, 1, accuracy: 1e-3)
    }

    func testExportRunsTheSameCircuit() throws {
        let (original, _) = try SpiceNetlist.circuit(from: Self.commonEmitter)
        let deck = SpiceNetlist.export(original, title: "round trip")
        XCTAssertTrue(deck.hasPrefix("* round trip"))
        XCTAssertTrue(deck.contains(".model Q_Q1 NPN(IS=1e-14 BF=150"), deck)
        XCTAssertTrue(deck.contains("\n.end\n"))
        let again = SpiceNetlist.parse(deck)
        XCTAssertTrue(again.warnings.isEmpty, "\(again.warnings)")
        XCTAssertEqual(again.parts.count, 9)
        let (circuit, _) = try SpiceNetlist.circuit(from: deck)
        func collector(_ c: Circuit) throws -> Double {
            let source = try XCTUnwrap(c.elements.firstIndex { $0.kind == .acVoltage })
            let simulator = Simulator.settled(c, holding: source, duration: 0.5)
            return simulator.terminalVoltages(try XCTUnwrap(c.elements.firstIndex { $0.name == "Q1" }))[1]
        }
        XCTAssertEqual(try collector(circuit), try collector(original), accuracy: 1e-6)
        // parts without a SPICE element are named, not dropped silently
        let chip = SpiceNetlist.export(Examples.all.first { $0.id == "tone" }!.circuit)
        XCTAssertTrue(chip.contains("no SPICE equivalent") || chip.contains("B_"), chip)
    }
}
