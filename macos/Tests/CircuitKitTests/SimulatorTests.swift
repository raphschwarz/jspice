import XCTest
@testable import CircuitKit

final class SimulatorTests: XCTestCase {

    private func run(_ circuit: Circuit, timeStep: Double, for seconds: Double) -> Simulator {
        let simulator = Simulator(circuit: circuit, timeStep: timeStep)
        for _ in 0..<Int((seconds / timeStep).rounded()) { simulator.step() }
        return simulator
    }

    private func index(_ simulator: Simulator, _ name: String) -> Int {
        simulator.circuit.elements.firstIndex { $0.name == name }!
    }

    /// Battery (0,4)->(0,0), then `parts` in series around a rectangle, back to ground at (0,4)
    private func series(voltage: Double, _ parts: [(ElementKind, [String: Double])]) -> Circuit {
        var b = CircuitBuilder()
        b.add(.dcVoltage, (0, 4), (0, 0), ["voltage": voltage])
        var x = 0
        for (kind, params) in parts {
            b.add(kind, (x, 0), (x + 4, 0), params)
            x += 4
        }
        b.wire((x, 0), (x, 4), (0, 4))
        b.ground((0, 4))
        return b.circuit
    }

    func testVoltageDividerExample() {
        let simulator = run(Examples.voltageDivider.circuit, timeStep: 1e-3, for: 0.01)
        let probe = simulator.circuit.elements.firstIndex { $0.kind == .probe }!
        XCTAssertEqual(simulator.voltageAcross(probe), 10.0 * 2 / 3, accuracy: 1e-6)
        XCTAssertEqual(simulator.current(index(simulator, "R1")), 10.0 / 3000, accuracy: 1e-9)
        XCTAssertFalse(simulator.isFailed)
    }

    func testRCChargesToSixtyThreePercentAfterOneTimeConstant() {
        // R = 1k, C = 1 µF: tau = 1 ms
        let circuit = series(voltage: 5, [(.resistor, ["resistance": 1000]), (.capacitor, ["capacitance": 1e-6])])
        let simulator = run(circuit, timeStep: 1e-6, for: 1e-3)
        let c = index(simulator, "C1")
        XCTAssertEqual(simulator.voltageAcross(c), 5 * (1 - exp(-1)), accuracy: 0.01)
        // the capacitor current equals the resistor current, and the source delivers it
        XCTAssertEqual(simulator.current(c), simulator.current(index(simulator, "R1")), accuracy: 1e-9)
        XCTAssertEqual(simulator.current(index(simulator, "V1")), simulator.current(c), accuracy: 1e-9)
    }

    func testLCOscillatesAtResonanceWithoutLosingAmplitude() {
        var circuit = Examples.lcOscillator.circuit
        let switchIndex = circuit.elements.firstIndex { $0.kind == .toggleSwitch }!
        circuit.elements[switchIndex].closed = true
        let dt = 1e-5
        let simulator = Simulator(circuit: circuit, timeStep: dt)
        let c = circuit.elements.firstIndex { $0.kind == .capacitor }!
        var crossings: [Double] = []
        var previous = simulator.voltageAcross(c)
        var peak = 0.0
        for _ in 0..<Int(0.2 / dt) {
            simulator.step()
            let v = simulator.voltageAcross(c)
            if previous < 0 && v >= 0 { crossings.append(simulator.time) }
            previous = v
            if simulator.time > 0.15 { peak = max(peak, abs(v)) }
        }
        XCTAssertGreaterThan(crossings.count, 4)
        let period = (crossings.last! - crossings.first!) / Double(crossings.count - 1)
        XCTAssertEqual(period, 2 * .pi * (1 * 10e-6).squareRoot(), accuracy: 1e-4)
        XCTAssertEqual(peak, 5, accuracy: 0.05, "trapezoidal integration should not damp an ideal LC circuit")
    }

    func testDiodeForwardDrop() {
        let circuit = series(voltage: 5, [(.resistor, ["resistance": 1000]), (.diode, [:])])
        let simulator = run(circuit, timeStep: 1e-3, for: 0.01)
        let drop = simulator.voltageAcross(index(simulator, "D1"))
        XCTAssertGreaterThan(drop, 0.55)
        XCTAssertLessThan(drop, 0.75)
        XCTAssertEqual(simulator.current(index(simulator, "D1")), (5 - drop) / 1000, accuracy: 1e-6)
        XCTAssertEqual(simulator.convergenceFailures, 0)
    }

    func testReversedDiodeBlocks() {
        var circuit = series(voltage: 5, [(.resistor, ["resistance": 1000]), (.diode, [:])])
        let d = circuit.elements.firstIndex { $0.kind == .diode }!
        swap(&circuit.elements[d].a, &circuit.elements[d].b)
        let simulator = run(circuit, timeStep: 1e-3, for: 0.01)
        XCTAssertLessThan(abs(simulator.current(d)), 1e-9)
    }

    func testLEDLightsWithForwardVoltageOfItsColor() {
        let simulator = run(Examples.ledSwitch.circuit, timeStep: 1e-3, for: 0.01)
        let led = simulator.circuit.elements.firstIndex { $0.kind == .led }!
        XCTAssertEqual(simulator.voltageAcross(led), 1.9, accuracy: 0.15)
        XCTAssertGreaterThan(simulator.brightness(led), 0.9)
    }

    func testOpenSwitchStopsTheCurrent() {
        var circuit = Examples.ledSwitch.circuit
        let s = circuit.elements.firstIndex { $0.kind == .toggleSwitch }!
        circuit.elements[s].closed = false
        let simulator = run(circuit, timeStep: 1e-3, for: 0.01)
        let led = circuit.elements.firstIndex { $0.kind == .led }!
        XCTAssertLessThan(abs(simulator.current(led)), 1e-9)
        XCTAssertEqual(simulator.brightness(led), 0, accuracy: 1e-6)
    }

    func testWiresCarryTheLoopCurrent() {
        let simulator = run(Examples.ledSwitch.circuit, timeStep: 1e-3, for: 0.01)
        let led = simulator.circuit.elements.firstIndex { $0.kind == .led }!
        let current = simulator.current(led)
        XCTAssertGreaterThan(current, 0.01)
        for (i, element) in simulator.circuit.elements.enumerated() where element.kind == .wire || element.kind == .toggleSwitch {
            XCTAssertEqual(abs(simulator.current(i)), current, accuracy: 1e-9, "wire \(i) from \(element.a) to \(element.b)")
        }
    }

    func testCMOSInverterInvertsItsInput() {
        var circuit = Examples.cmosInverter.circuit
        let probe = circuit.elements.firstIndex { $0.kind == .probe }!
        let input = circuit.elements.firstIndex { $0.kind == .toggleSwitch }!

        var simulator = run(circuit, timeStep: 1e-3, for: 0.02)
        XCTAssertEqual(simulator.voltageAcross(probe), 5, accuracy: 0.6, "input low -> output high")

        circuit.elements[input].closed = true
        simulator = run(circuit, timeStep: 1e-3, for: 0.02)
        XCTAssertEqual(simulator.voltageAcross(probe), 0, accuracy: 0.1, "input high -> output low")
        XCTAssertEqual(simulator.convergenceFailures, 0)
    }

    func testTransistorSwitchesTheLED() {
        var circuit = Examples.transistorSwitch.circuit
        let led = circuit.elements.firstIndex { $0.kind == .led }!
        let input = circuit.elements.firstIndex { $0.kind == .toggleSwitch }!
        XCTAssertLessThan(run(circuit, timeStep: 1e-3, for: 0.02).brightness(led), 0.01)
        circuit.elements[input].closed = true
        XCTAssertGreaterThan(run(circuit, timeStep: 1e-3, for: 0.02).brightness(led), 0.5)
    }

    func testMemristorSwitchesOnUnderPositiveBias() {
        var b = CircuitBuilder()
        b.add(.dcVoltage, (0, 4), (0, 0), ["voltage": 1])
        b.add(.memristor, (0, 0), (4, 0), ["ron": 100, "roff": 10_000, "tau": 0.01])
        b.wire((4, 0), (4, 4), (0, 4))
        b.ground((0, 4))
        let simulator = run(b.circuit, timeStep: 1e-4, for: 0.1)
        let m = simulator.circuit.elements.firstIndex { $0.kind == .memristor }!
        XCTAssertGreaterThan(simulator.memristorState(m), 0.99)
        XCTAssertEqual(simulator.value(.resistance, of: m), 100, accuracy: 5)
    }

    func testShortedSourceIsReportedNotCrashing() {
        var b = CircuitBuilder()
        b.add(.dcVoltage, (0, 4), (0, 0), ["voltage": 5])
        b.wire((0, 0), (0, 4))
        let simulator = run(b.circuit, timeStep: 1e-3, for: 0.01)
        XCTAssertTrue(simulator.problems.contains { $0.contains("short-circuited") })
    }

    func testParallelVoltageSourcesFailGracefully() {
        var b = CircuitBuilder()
        b.add(.dcVoltage, (0, 4), (0, 0), ["voltage": 5])
        b.add(.dcVoltage, (4, 4), (4, 0), ["voltage": 3])
        b.wire((0, 0), (4, 0))
        b.wire((0, 4), (4, 4))
        b.ground((0, 4))
        let simulator = run(b.circuit, timeStep: 1e-3, for: 0.01)
        XCTAssertTrue(simulator.isFailed)
        XCTAssertFalse(simulator.problems.isEmpty)
    }

    func testFloatingPartsStillSolve() {
        var circuit = Examples.voltageDivider.circuit
        circuit.add(Element(kind: .resistor, a: GridPoint(30, 30), b: GridPoint(34, 30)))
        circuit.add(Element(kind: .capacitor, a: GridPoint(40, 30), b: GridPoint(44, 30)))
        let simulator = run(circuit, timeStep: 1e-3, for: 0.01)
        XCTAssertFalse(simulator.isFailed)
    }

    func testCircuitWithoutGroundUsesASourceAsReference() {
        var circuit = Examples.voltageDivider.circuit
        circuit.elements.removeAll { $0.kind == .ground }
        let simulator = run(circuit, timeStep: 1e-3, for: 0.01)
        let probe = circuit.elements.firstIndex { $0.kind == .probe }!
        XCTAssertEqual(simulator.voltageAcross(probe), 10.0 * 2 / 3, accuracy: 1e-6)
    }

    func testStateSurvivesEditingTheCircuit() {
        let circuit = series(voltage: 5, [(.resistor, ["resistance": 1000]), (.capacitor, ["capacitance": 1e-6])])
        let simulator = run(circuit, timeStep: 1e-6, for: 5e-3)
        let c = index(simulator, "C1")
        let charged = simulator.voltageAcross(c)
        var edited = circuit
        edited.update(edited.elements[index(simulator, "R1")].id) { $0[param: "resistance"] = 2000 }
        simulator.load(edited)
        simulator.step()
        XCTAssertEqual(simulator.voltageAcross(c), charged, accuracy: 0.01)
    }

    func testEveryExampleRunsWithItsSuggestedPacing() {
        for example in Examples.all {
            let pacing = Pacing.suggest(for: example.circuit)
            let simulator = Simulator(circuit: example.circuit, timeStep: pacing.timeStep)
            let steps = min(20_000, Int(pacing.speed * 3 / pacing.timeStep))
            for _ in 0..<steps { simulator.step() }
            XCTAssertFalse(simulator.isFailed, "\(example.id): \(simulator.problems)")
            XCTAssertTrue(simulator.problems.isEmpty, "\(example.id): \(simulator.problems)")
            XCTAssertLessThan(simulator.convergenceFailures, steps / 100 + 1, example.id)
            for i in example.circuit.elements.indices {
                XCTAssertTrue(simulator.current(i).isFinite, "\(example.id) element \(i)")
            }
            for scope in example.circuit.scopes {
                XCTAssertNotNil(simulator.trace(scope.id), example.id)
            }
        }
    }

    func testAdvanceStopsAtTheDeadline() {
        let circuit = Examples.cmosInverter.circuit
        let simulator = Simulator(circuit: circuit, timeStep: 1e-6)
        let start = ProcessInfo.processInfo.systemUptime
        let progress = simulator.advance(by: 10, deadline: start + 0.02)
        XCTAssertTrue(progress.fellBehind)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
    }
}

final class ModelTests: XCTestCase {
    func testSIFormatting() {
        XCTAssertEqual(SI.format(0.0047, unit: "A"), "4.7 mA")
        XCTAssertEqual(SI.format(1500, unit: "Ω"), "1.5 kΩ")
        XCTAssertEqual(SI.format(10e-6, unit: "F"), "10 µF")
        XCTAssertEqual(SI.format(-0.25, unit: "V"), "−250 mV")
        XCTAssertEqual(SI.format(0, unit: "V"), "0 V")
        XCTAssertEqual(SI.format(999.96, unit: "Ω"), "1 kΩ")
    }

    func testSIParsing() {
        XCTAssertEqual(SI.parse("4.7k")!, 4700, accuracy: 1e-9)
        XCTAssertEqual(SI.parse("100 nF")!, 1e-7, accuracy: 1e-20)
        XCTAssertEqual(SI.parse("1M")!, 1e6, accuracy: 1e-9)
        XCTAssertEqual(SI.parse("2m")!, 2e-3, accuracy: 1e-15)
        XCTAssertEqual(SI.parse("1meg")!, 1e6, accuracy: 1e-9)
        XCTAssertEqual(SI.parse("10 µF")!, 1e-5, accuracy: 1e-18)
        XCTAssertEqual(SI.parse("5")!, 5, accuracy: 1e-12)
        XCTAssertEqual(SI.parse("−3 V")!, -3, accuracy: 1e-12)
        XCTAssertEqual(SI.parse("60 Hz")!, 60, accuracy: 1e-12)
        XCTAssertNil(SI.parse("abc"))
    }

    func testCircuitRoundTripsThroughJSON() throws {
        let circuit = Examples.memristorHysteresis.circuit
        let data = try JSONEncoder().encode(circuit)
        XCTAssertEqual(try JSONDecoder().decode(Circuit.self, from: data), circuit)
    }

    func testMovingStretchesAttachedWires() {
        var circuit = Examples.ledSwitch.circuit
        let resistor = circuit.elements.first { $0.kind == .resistor }!
        circuit.move([resistor.id], by: GridPoint(0, -2))
        let moved = circuit[resistor.id]!
        XCTAssertEqual(moved.a, resistor.a + GridPoint(0, -2))
        // the wire that ended on the resistor's right terminal followed it
        XCTAssertTrue(circuit.elements.contains { $0.kind == .wire && ($0.a == moved.b || $0.b == moved.b) })
    }

    func testRotationKeepsLength() {
        var circuit = Circuit()
        let id = circuit.add(Element(kind: .resistor, a: GridPoint(0, 0), b: GridPoint(4, 0)))
        circuit.rotate([id])
        let rotated = circuit[id]!
        XCTAssertEqual(rotated.a.x, rotated.b.x)
        XCTAssertEqual(abs(rotated.b.y - rotated.a.y), 4)
    }

    func testTransistorTerminals() {
        let nmos = Element(kind: .nmos, a: GridPoint(0, 0), b: GridPoint(2, 0))
        XCTAssertEqual(nmos.transistorTerminals.drain, GridPoint(2, -2))
        XCTAssertEqual(nmos.transistorTerminals.source, GridPoint(2, 2))
        let pmos = Element(kind: .pmos, a: GridPoint(0, 0), b: GridPoint(2, 0))
        XCTAssertEqual(pmos.transistorTerminals.source, GridPoint(2, -2))
    }

    func testPacing() {
        // tau = 1 s: slow enough to watch in real time
        XCTAssertEqual(Pacing.suggest(for: Examples.rcCharging.circuit).speed, 1)
        // 100 Hz with a 1 ms time constant: slow motion
        let lowPass = Pacing.suggest(for: Examples.lowPass.circuit)
        XCTAssertLessThan(lowPass.speed, 0.05)
        XCTAssertLessThanOrEqual(lowPass.timeStep, 1e-3 / 20)
        // no dynamics at all: real time
        XCTAssertEqual(Pacing.suggest(for: Examples.ledSwitch.circuit).speed, 1)
        XCTAssertEqual(Pacing.describe(speed: 1), "Real time")
        XCTAssertEqual(Pacing.describe(speed: 0.005), "5 ms per second")
    }
}
