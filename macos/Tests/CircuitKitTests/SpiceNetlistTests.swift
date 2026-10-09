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
        XCTAssertTrue(imported.warnings.isEmpty, "\(imported.warnings)")
        XCTAssertEqual(imported.parts.first { $0.name == "E1" }?.kind, .behavioralSource)
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

    /// A subcircuit's parameters: PARAMS: defaults, an instance's values, its own .param worked out from them, and a
    /// block for each different set
    func testSubcircuitParameters() throws {
        let text = """
        dividers with parameters
        .func twice(x) {2*x}
        .param big={twice(10k)}
        .subckt DIV top mid PARAMS: R=1k RATIO=1
        .param RLOW={R*RATIO}
        R1 top mid {R}
        R2 mid 0 {RLOW}
        .ends
        V1 a 0 DC 3
        X1 a b DIV
        X2 a c DIV PARAMS: R={big} RATIO=2
        X3 a d DIV R=1k
        """
        let imported = SpiceNetlist.parse(text)
        XCTAssertTrue(imported.warnings.isEmpty, "\(imported.warnings)")
        func resistors(_ name: String) throws -> [Double] {
            let block = try XCTUnwrap(imported.parts.first { $0.name == name }?.block)
            return block.circuit.elements.filter { $0.kind == .resistor }.map { $0[param: "resistance"] }.sorted()
        }
        XCTAssertEqual(try resistors("X1"), [1000, 1000])
        XCTAssertEqual(try resistors("X2"), [20_000, 40_000])
        XCTAssertEqual(try resistors("X3"), [1000, 1000])
        XCTAssertEqual(imported.parts.first { $0.name == "X2" }?.connections, ["top": "a", "mid": "c"])
        let (circuit, _) = try SpiceNetlist.circuit(from: text)
        let simulator = Simulator(circuit: circuit, timeStep: 1e-3)
        simulator.step()
        let x2 = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "X2" })
        let mid = try XCTUnwrap(circuit.elements[x2].terminalNames.firstIndex(of: "mid"))
        XCTAssertEqual(simulator.terminalVoltage(x2, mid), 2, accuracy: 1e-9)
    }

    /// .include and .lib read through the includer: a library's section alone, the files it includes in turn, and a
    /// warning for what can't be read
    func testIncludesAndLibrarySections() throws {
        let files = [
            "lib/parts.lib": """
            * two sections
            .lib fast
            .model DF D(IS=1e-12 RS=2)
            .include more.mod
            .endl
            .lib slow
            .model DF D(IS=1e-15)
            .endl
            """,
            "lib/more.mod": ".model QF NPN(IS=3e-15 BF=210)",
        ]
        var asked: [(String, String?)] = []
        let include: SpiceNetlist.Includer = { path, from in
            asked.append((path, from))
            // relative to the file that includes it
            let folder = from.map { ($0 as NSString).deletingLastPathComponent } ?? ""
            let name = folder.isEmpty ? path : folder + "/" + path
            return files[name].map { (name, $0) }
        }
        let deck = """
        library
        .lib "lib/parts.lib" fast
        .include missing.mod
        V1 a 0 DC 1
        D1 a b DF
        R1 b 0 1k
        Q1 a b 0 QF
        """
        let imported = SpiceNetlist.parse(deck, include: include)
        XCTAssertEqual(imported.warnings, ["missing.mod: can't read it, left out"])
        XCTAssertEqual(asked.map { $0.0 }, ["lib/parts.lib", "more.mod", "missing.mod"])
        XCTAssertEqual(asked[1].1, "lib/parts.lib")
        let diode = try XCTUnwrap(imported.parts.first { $0.name == "D1" })
        XCTAssertEqual(diode.params["saturationCurrent"], 1e-12, "the fast section's model")
        XCTAssertEqual(diode.params["rs"], 2)
        XCTAssertEqual(imported.parts.first { $0.name == "Q1" }?.params["beta"], 210)
        // a deck given as text has no files to read
        let alone = SpiceNetlist.parse(deck)
        XCTAssertTrue(alone.warnings.contains { $0.hasPrefix("lib/parts.lib: the files a deck includes") }, "\(alone.warnings)")
    }

    /// An instance's area (after its model, or AREA=, times M=) scales its card as ngspice does
    func testAreaFactors() throws {
        let imported = SpiceNetlist.parse("""
        areas
        D1 a 0 DX 4
        D2 a 0 DX AREA=2 M=3
        Q1 a b 0 QX 3
        Q2 a b 0 sub QX 2
        J1 a b 0 JX 2
        .model DX D(IS=1e-14 RS=6 CJO=2p IBV=1m)
        .model QX NPN(IS=1e-15 RB=90 CJE=4p BF=100)
        .model JX PJF(BETA=1e-4 VTO=-1.5 RD=20 CGS=2p)
        """)
        XCTAssertTrue(imported.warnings.isEmpty, "\(imported.warnings)")
        func p(_ name: String, _ key: String) throws -> Double {
            try XCTUnwrap(imported.parts.first { $0.name == name }?.params[key], "\(name) \(key)")
        }
        XCTAssertEqual(try p("D1", "saturationCurrent"), 4e-14, accuracy: 1e-27)
        XCTAssertEqual(try p("D1", "rs"), 1.5, accuracy: 1e-12)
        XCTAssertEqual(try p("D1", "cj0"), 8e-12, accuracy: 1e-24)
        XCTAssertEqual(try p("D2", "saturationCurrent"), 6e-14, accuracy: 1e-27)
        XCTAssertEqual(try p("Q1", "saturationCurrent"), 3e-15, accuracy: 1e-28)
        XCTAssertEqual(try p("Q1", "rb"), 30, accuracy: 1e-9)
        XCTAssertEqual(try p("Q1", "beta"), 100, "BF is not scaled")
        XCTAssertEqual(try p("Q2", "saturationCurrent"), 2e-15, accuracy: 1e-28)
        let jfet = try XCTUnwrap(imported.parts.first { $0.name == "J1" })
        XCTAssertEqual(jfet.kind, .pjfet)
        // IDSS = BETA × VTO², for twice the area
        XCTAssertEqual(try p("J1", "idss"), 2 * 1e-4 * 2.25, accuracy: 1e-12)
        XCTAssertEqual(try p("J1", "rd"), 10, accuracy: 1e-9)
    }

    /// A P-JFET's card comes back as PJF with the same numbers
    func testPChannelJFETRoundTrip() throws {
        let text = """
        P-JFET source follower
        VDD vdd 0 DC -9
        VG g 0 SIN(0 0.2 1k)
        J1 vdd g s JP
        RS s 0 2.2k
        .model JP PJF(BETA=3e-4 VTO=-1.2 LAMBDA=0.02 IS=1e-13 CGS=3p CGD=1p)
        """
        let (circuit, warnings) = try SpiceNetlist.circuit(from: text)
        XCTAssertTrue(warnings.isEmpty, "\(warnings)")
        let deck = SpiceNetlist.export(circuit)
        XCTAssertTrue(deck.contains(" PJF(BETA=0.0003 VTO=-1.2 LAMBDA=0.02 IS=1e-13 CGS=3e-12 CGD=1e-12"), deck)
        // the stage runs
        let simulator = Simulator(circuit: circuit, timeStep: 1e-5)
        for _ in 0..<50 { simulator.step() }
        XCTAssertFalse(simulator.isFailed)
        let j1 = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "J1" })
        let v = simulator.terminalVoltages(j1)
        // a P-channel follower's source sits below its gate (by about 0.41 V here)
        XCTAssertGreaterThan(v[0] - v[2], 0.3, "source below gate: \(v)")
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
