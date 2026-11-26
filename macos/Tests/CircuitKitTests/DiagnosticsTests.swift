import XCTest
@testable import CircuitKit

/// What the simulator tells the user about a circuit (`Simulator.diagnostics`): each kind on a circuit as small as
/// shows it, with its severity and the drawn parts it points at, and `problems` as it was.
final class DiagnosticsTests: XCTestCase {
    private func id(_ simulator: Simulator, _ name: String) -> UUID {
        simulator.circuit.elements.first { $0.name == name }!.id
    }

    private func kind(_ d: Diagnostic) -> String { String(d.id.prefix { $0 != ":" }) }

    private func only(_ simulator: Simulator, _ kind: String, file: StaticString = #filePath, line: UInt = #line) throws -> Diagnostic {
        let found = simulator.diagnostics.filter { self.kind($0) == kind }
        XCTAssertEqual(found.count, 1, "\(simulator.diagnostics.map(\.message))", file: file, line: line)
        return try XCTUnwrap(found.first, file: file, line: line)
    }

    /// A 5 V battery V1 (− at (0,4), + at (0,0)) and R1 across it, grounded unless said
    private func battery(grounded: Bool = true) -> CircuitBuilder {
        var b = CircuitBuilder()
        b.add(.dcVoltage, (0, 4), (0, 0), ["voltage": 5], name: "V1")
        b.add(.resistor, (0, 0), (4, 0), ["resistance": 1000], name: "R1")
        b.wire((4, 0), (4, 4), (0, 4))
        if grounded { b.ground((0, 4)) }
        return b
    }

    // MARK: What there was before, unchanged

    func testAShortedSourceIsAnErrorOnIt() throws {
        var b = CircuitBuilder()
        b.add(.dcVoltage, (0, 4), (0, 0), ["voltage": 5], name: "V1")
        b.wire((0, 0), (0, 4))
        b.ground((0, 4))
        let simulator = Simulator(circuit: b.circuit, timeStep: 1e-3)
        XCTAssertEqual(simulator.problems, ["V1 is short-circuited."])
        let d = try only(simulator, "shorted")
        XCTAssertEqual(d.severity, .error)
        XCTAssertEqual(d.elements, [id(simulator, "V1")])
        XCTAssertNotNil(d.hint)
    }

    func testAnOutputOnGroundIsAnErrorOnIt() throws {
        let circuit = try SchematicLayout.layout([
            NetlistPart(kind: .dcVoltage, name: "VIN", params: ["voltage": 1], connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 1000], connections: ["a": "in", "b": "GND"]),
            NetlistPart(kind: .opAmp, name: "U1", connections: ["plus": "in", "minus": "in", "out": "GND"]),
        ])
        let simulator = Simulator(circuit: circuit, timeStep: 1e-5)
        XCTAssertEqual(simulator.problems, ["The output of U1 is connected straight to ground."])
        let d = try only(simulator, "output-grounded")
        XCTAssertEqual(d.severity, .error)
        XCTAssertEqual(d.elements, [id(simulator, "U1")])
    }

    func testAnExpressionThatCannotBeReadIsAnErrorOnItsSource() throws {
        var source = NetlistPart(kind: .behavioralSource, name: "B1", connections: ["plus": "out", "minus": "GND"])
        source.code = "V(in1"
        let circuit = try SchematicLayout.layout([
            source, NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 1000], connections: ["a": "out", "b": "GND"]),
        ])
        let simulator = Simulator(circuit: circuit, timeStep: 1e-5)
        XCTAssertEqual(simulator.problems.count, 1, "\(simulator.problems)")
        XCTAssertTrue(simulator.problems[0].hasPrefix("B1: can't read its expression V(in1: "), simulator.problems[0])
        let d = try only(simulator, "expression-expression")
        XCTAssertEqual(d.severity, .error)
        XCTAssertEqual(d.elements, [id(simulator, "B1")])
    }

    /// A part inside a block is pointed at as the block part
    func testAPartInsideABlockIsReportedAsTheBlock() throws {
        var inner = NetlistPart(kind: .behavioralSource, name: "B1", connections: ["plus": "out", "minus": "GND"])
        inner.code = "I(VNONE)"
        let block = try SchematicLayout.layout([
            NetlistPart(kind: .port, name: "out", params: ["side": 2], connections: ["net": "out"]),
            inner,
        ]).asBlock(named: "SRC")
        var x1 = NetlistPart(kind: .block, name: "X1", connections: ["out": "out"])
        x1.block = block
        let circuit = try SchematicLayout.layout([
            x1, NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 1000], connections: ["a": "out", "b": "GND"]),
        ])
        let simulator = Simulator(circuit: circuit, timeStep: 1e-5)
        XCTAssertEqual(simulator.problems, ["X1.B1: no voltage source VNONE for its expression to read the current of"])
        let d = try only(simulator, "expression-current")
        XCTAssertEqual(d.elements, [id(simulator, "X1")])
    }

    // MARK: Failures

    func testParallelSourcesAreNamed() throws {
        var b = CircuitBuilder()
        b.add(.dcVoltage, (0, 4), (0, 0), ["voltage": 5], name: "V1")
        b.add(.dcVoltage, (4, 4), (4, 0), ["voltage": 3], name: "V2")
        b.wire((0, 0), (4, 0))
        b.wire((0, 4), (4, 4))
        b.ground((0, 4))
        let simulator = Simulator(circuit: b.circuit, timeStep: 1e-3)
        simulator.step()
        XCTAssertTrue(simulator.isFailed)
        let d = try XCTUnwrap(simulator.diagnostics.first)
        XCTAssertEqual(d.severity, .error)
        XCTAssertEqual(d.message, "The circuit can't be solved: V1 and V2 are voltage sources in parallel.")
        XCTAssertEqual(Set(d.elements), [id(simulator, "V1"), id(simulator, "V2")])
        XCTAssertEqual(simulator.problems, [d.message])
    }

    func testALoopOfSourcesIsNamed() throws {
        var b = CircuitBuilder()
        b.add(.dcVoltage, (0, 4), (0, 0), ["voltage": 1], name: "V1")
        b.add(.dcVoltage, (0, 0), (4, 0), ["voltage": 1], name: "V2")
        b.add(.dcVoltage, (4, 0), (0, 4), ["voltage": 1], name: "V3")
        b.add(.resistor, (0, 0), (0, 8), ["resistance": 1000], name: "R1")
        b.ground((0, 4))
        b.wire((0, 8), (0, 4))
        let simulator = Simulator(circuit: b.circuit, timeStep: 1e-3)
        simulator.step()
        XCTAssertTrue(simulator.isFailed)
        let d = try only(simulator, "source-loop")
        XCTAssertEqual(d.message, "The circuit can't be solved: V1, V2 and V3 make a loop of voltage sources and wires.")
        XCTAssertEqual(Set(d.elements), [id(simulator, "V1"), id(simulator, "V2"), id(simulator, "V3")])
    }

    /// Running out of time is not a fault in the circuit, and is not said to be one
    func testATimeBudgetStopIsNotAWiringFault() throws {
        let simulator = Simulator(circuit: battery().circuit, timeStep: 1e-3)
        for _ in 0..<10 { simulator.step() }
        simulator.stopRequested = true
        simulator.step()
        XCTAssertTrue(simulator.isFailed)
        let d = try only(simulator, "stopped")
        XCTAssertEqual(d.severity, .error)
        XCTAssertEqual(d.message, "The analysis took too long and was stopped at 10 ms of circuit time: the rest of it was not simulated.")
        XCTAssertTrue(d.elements.isEmpty)
        XCTAssertEqual(simulator.problems, [d.message])
        for said in simulator.problems + [d.hint ?? ""] {
            XCTAssertFalse(said.contains("can't be solved") || said.contains("voltage sources") || said.contains("loop"), said)
        }
        // the small-signal analysis's budget stops it the same way
        let settled = Simulator.settled(battery().circuit, holding: nil, duration: 1, maxSteps: 1000, budget: 0)
        XCTAssertTrue(settled.isFailed)
        XCTAssertEqual(settled.diagnostics.map(kind), ["stopped"])
    }

    /// (The engine keeps its values finite in all a test can build cheaply, so the failure is given as a solve would)
    func testABlowUpNamesWhereItHappened() throws {
        let simulator = Simulator(circuit: battery().circuit, timeStep: 1e-3)
        // the unknowns: the node of V1's + and R1, then V1's current
        simulator.fail(.numerical(0))
        XCTAssertTrue(simulator.isFailed)
        let d = try only(simulator, "blew-up")
        XCTAssertEqual(d.severity, .error)
        XCTAssertEqual(d.message, "The simulation broke down: the voltage at the node joining V1 and R1 became infinite or not a number.")
        XCTAssertEqual(d.elements, [id(simulator, "V1"), id(simulator, "R1")])
        XCTAssertFalse(d.message.contains("can't be solved"))
        let unknown = Simulator(circuit: battery().circuit, timeStep: 1e-3)
        unknown.fail(.numerical(nil))
        XCTAssertEqual(unknown.problems, ["The simulation broke down: a voltage or current became infinite or not a number."])
    }

    /// A source that cannot settle (an exponential of its own output, stepped far too coarsely) is said to, by name
    func testARealUnconvergedCircuitNamesThePart() throws {
        var source = NetlistPart(kind: .behavioralSource, name: "B1", params: ["mode": 1], connections: ["plus": "out", "minus": "GND"])
        source.code = "exp(V(plus)*100)"
        let circuit = try SchematicLayout.layout([
            source, NetlistPart(kind: .capacitor, name: "C1", params: ["capacitance": 1e-6], connections: ["a": "out", "b": "GND"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 1000], connections: ["a": "out", "b": "k"]),
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 1], connections: ["plus": "k", "minus": "GND"]),
        ])
        let simulator = Simulator(circuit: circuit, timeStep: 1e-5)
        for _ in 0..<5 where simulator.convergenceFailures < Simulator.unconvergedLimit { simulator.step() }
        XCTAssertFalse(simulator.isFailed)
        let d = try only(simulator, "unconverged")
        XCTAssertEqual(d.message, "The simulation did not settle at many steps, at the current through B1: the waveforms may be wrong there.")
        XCTAssertEqual(d.elements, [id(simulator, "B1")])
    }

    // MARK: New warnings

    func testNoGroundSaysWhatTheVoltagesAreRelativeTo() throws {
        let simulator = Simulator(circuit: battery(grounded: false).circuit, timeStep: 1e-3)
        let d = try only(simulator, "no-ground")
        XCTAssertEqual(d.severity, .warning)
        XCTAssertEqual(d.message, "The circuit has no ground: voltages are shown relative to the − terminal of V1.")
        XCTAssertEqual(d.elements, [id(simulator, "V1")])
        XCTAssertEqual(simulator.problems, [d.message])
        XCTAssertTrue(Simulator(circuit: battery().circuit, timeStep: 1e-3).diagnostics.isEmpty)
    }

    func testAnIslandNotConnectedToTheRestIsNamed() throws {
        var b = battery()
        b.add(.resistor, (10, 0), (14, 0), ["resistance": 1000], name: "R2")
        b.add(.resistor, (10, 4), (14, 4), ["resistance": 1000], name: "R3")
        b.wire((10, 0), (10, 4))
        b.wire((14, 0), (14, 4))
        let simulator = Simulator(circuit: b.circuit, timeStep: 1e-3)
        let d = try only(simulator, "floating")
        XCTAssertEqual(d.severity, .warning)
        XCTAssertEqual(d.message, "R2 and R3 are not connected to ground or to the rest of the circuit.")
        XCTAssertEqual(d.elements, [id(simulator, "R2"), id(simulator, "R3")])
        XCTAssertEqual(simulator.diagnostics.count, 1)
    }

    func testANodeReachedOnlyThroughCapacitorsHasNoDCPath() throws {
        var b = CircuitBuilder()
        b.add(.dcVoltage, (0, 4), (0, 0), ["voltage": 5], name: "V1")
        b.add(.resistor, (0, 0), (4, 0), ["resistance": 1000], name: "R1")
        b.add(.capacitor, (4, 0), (8, 0), ["capacitance": 1e-6], name: "C1")
        b.add(.capacitor, (8, 0), (8, 4), ["capacitance": 1e-6], name: "C2")
        b.wire((8, 4), (0, 4))
        b.ground((0, 4))
        let simulator = Simulator(circuit: b.circuit, timeStep: 1e-3)
        let d = try only(simulator, "no-dc-path")
        XCTAssertEqual(d.severity, .warning)
        XCTAssertEqual(d.message, "C1 and C2 have no DC path to ground: they are reached only through capacitors or a current source.")
        XCTAssertEqual(d.elements, [id(simulator, "C1"), id(simulator, "C2")])
        // a resistor to ground gives it one
        b.add(.resistor, (8, 0), (12, 0), ["resistance": 1e6], name: "R2")
        b.wire((12, 0), (12, 4), (8, 4))
        XCTAssertTrue(Simulator(circuit: b.circuit, timeStep: 1e-3).diagnostics.isEmpty)
    }

    func testATerminalConnectedToNothingIsNamed() throws {
        var b = battery()
        b.add(.resistor, (4, 0), (8, 0), ["resistance": 1000], name: "R2")
        b.add(.npn, (0, 10), (2, 10), name: "Q1")
        let q1 = b.circuit.elements.last!.posts
        // its base and emitter on the circuit, its collector on nothing
        b.wire((q1[0].x, q1[0].y), (0, 4))
        b.wire((q1[2].x, q1[2].y), (4, 4))
        let simulator = Simulator(circuit: b.circuit, timeStep: 1e-3)
        let dangling = simulator.diagnostics.filter { kind($0) == "dangling" }
        XCTAssertEqual(dangling.map(\.message), ["One end of R2 is connected to nothing.", "The collector of Q1 is connected to nothing."])
        XCTAssertEqual(dangling.map(\.elements), [[id(simulator, "R2")], [id(simulator, "Q1")]])
        XCTAssertEqual(dangling.map(\.severity), [.warning, .warning])
        XCTAssertEqual(simulator.diagnostics.count, 2, "\(simulator.diagnostics.map(\.message))")
    }

    func testAPartConnectedToNothingIsNamedOnce() throws {
        var b = battery()
        b.add(.capacitor, (20, 0), (24, 0), ["capacitance": 1e-6], name: "C9")
        let simulator = Simulator(circuit: b.circuit, timeStep: 1e-3)
        XCTAssertEqual(simulator.diagnostics.map(\.message), ["C9 is not connected to anything."])
        XCTAssertEqual(simulator.diagnostics.first?.elements, [id(simulator, "C9")])
    }

    /// What is left open by design in this app is not warned of: an open switch, a probe, a potentiometer's spare
    /// end, a supply drawn for the chips that take it of themselves
    func testWhatIsOpenByDesignIsNotWarnedOf() throws {
        var b = battery()
        b.add(.toggleSwitch, (4, 0), (8, 0), closed: false, name: "S1")
        b.add(.capacitor, (8, 0), (8, 4), ["capacitance": 1e-6], name: "C1")
        b.wire((8, 4), (4, 4))
        b.add(.probe, (20, 0), (20, 4), name: "P1")
        b.add(.potentiometer, (4, 0), (4, 4), name: "POT")
        b.add(.dcVoltage, (30, 4), (30, 0), ["voltage": 9], name: "V9")
        b.ground((30, 4))
        let simulator = Simulator(circuit: b.circuit, timeStep: 1e-3)
        XCTAssertTrue(simulator.diagnostics.isEmpty, "\(simulator.diagnostics.map(\.message))")
    }

    // MARK: Steps that do not converge

    func testUnconvergedStepsAreSaidOnceTheyComeOftenAndStay() throws {
        let simulator = Simulator(circuit: battery().circuit, timeStep: 1e-3)
        simulator.step()
        simulator.unsettledUnknown = 0
        for _ in 1..<Simulator.unconvergedLimit { simulator.noteUnconverged() }
        XCTAssertTrue(simulator.diagnostics.isEmpty)
        simulator.noteUnconverged()
        let d = try only(simulator, "unconverged")
        XCTAssertEqual(d.severity, .warning)
        XCTAssertTrue(d.message.hasPrefix("The simulation did not settle at many steps, at "), d.message)
        XCTAssertFalse(d.elements.isEmpty)
        XCTAssertEqual(simulator.problems, [d.message])
        // it stays, the same, while the circuit runs
        for _ in 0..<100 {
            simulator.step()
            simulator.noteUnconverged()
        }
        XCTAssertEqual(simulator.diagnostics, [d])
        // the window's simulator takes it from the sound's
        let display = Simulator(circuit: battery().circuit, timeStep: 1e-3)
        display.step()
        display.adoptState(of: simulator)
        XCTAssertEqual(display.diagnostics, [d])
        XCTAssertEqual(display.problems, [d.message])
        simulator.reset()
        XCTAssertTrue(simulator.diagnostics.isEmpty)
    }

    /// Now and then is not often: a few in a window do not warn
    func testScatteredUnconvergedStepsAreNotSaid() {
        let simulator = Simulator(circuit: battery().circuit, timeStep: 1e-3)
        for k in 0..<(10 * Simulator.unconvergedLimit) {
            simulator.step()
            if k % (Simulator.unconvergedWindow / 10) == 0 { simulator.noteUnconverged() }
        }
        XCTAssertTrue(simulator.diagnostics.isEmpty)
    }

    // MARK: Severity and order

    func testErrorsComeFirstAndNotesAreNotProblems() {
        let notice = Simulator.chipNotice("U1 (STM32F405): its firmware reset it once (SYSRESETREQ).", chip: [], index: 0)
        XCTAssertEqual(notice.severity, .note)
        let unmodelled = Simulator.chipNotice("U1 (STM32F405): the firmware writes CAN1 (first at 0x40006400, from about 0x0800000C), which the model does not run: it reads 0 there, and what it writes is lost.", chip: [], index: 0)
        XCTAssertEqual(unmodelled.severity, .warning)
        let error = Diagnostic(severity: .error, message: "e", id: "e")
        XCTAssertEqual(Diagnostic.ordered([notice, unmodelled, error]).map(\.severity), [.error, .warning, .note])
        XCTAssertLessThan(Diagnostic.Severity.error, .warning)
        XCTAssertLessThan(Diagnostic.Severity.warning, .note)
    }

    // MARK: The examples

    /// No built-in example has anything to be told of when it loads (their runs are checked in `SimulatorTests`)
    func testTheExamplesHaveNoDiagnostics() {
        for example in Examples.all {
            let simulator = Simulator(circuit: example.circuit, timeStep: Pacing.suggest(for: example.circuit).timeStep)
            XCTAssertEqual(simulator.diagnostics.map(\.message), [], example.id)
        }
    }
}
