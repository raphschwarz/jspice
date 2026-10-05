import XCTest
@testable import CircuitKit

/// Regression tests for the bug sweep: state that must survive an edit, inputs that must not trap, layout that must not
/// join nets
final class SweepTests: XCTestCase {
    private func index(_ circuit: Circuit, _ name: String) -> Int {
        circuit.elements.firstIndex { $0.name == name }!
    }

    func testNoiseKeepsChangingAfterAnEdit() throws {
        let circuit = try SchematicLayout.layout([
            NetlistPart(kind: .noiseVoltage, name: "N1", params: ["amplitude": 1], connections: ["plus": "n", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 1000], connections: ["a": "n", "b": "GND"]),
        ])
        let simulator = Simulator(circuit: circuit, timeStep: 1 / 48_000)
        for _ in 0..<10 { simulator.step() }
        // any edit: a new value, and a new part
        var edited = circuit
        edited.update(edited.elements[index(edited, "R1")].id) { $0[param: "resistance"] = 2000 }
        edited.add(Element(kind: .resistor, a: GridPoint(40, 40), b: GridPoint(44, 40)))
        simulator.load(edited)
        let noise = index(edited, "N1")
        var values = Set<Double>()
        for _ in 0..<100 {
            simulator.step()
            values.insert(simulator.voltageAcross(noise))
        }
        XCTAssertGreaterThan(values.count, 90, "noise, not a constant")
        XCTAssertLessThan(values.map(abs).max() ?? 0, 6)
    }

    func testAnEditKeepsTheNodeVoltages() throws {
        let circuit = try SchematicLayout.layout([
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 5], connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 1000], connections: ["a": "in", "b": "out"]),
            NetlistPart(kind: .capacitor, name: "C1", params: ["capacitance": 1e-6], connections: ["a": "out", "b": "GND"]),
        ])
        let simulator = Simulator(circuit: circuit, timeStep: 1e-5)
        for _ in 0..<100 { simulator.step() }
        let c1 = index(circuit, "C1")
        let before = simulator.terminalVoltages(c1)
        XCTAssertGreaterThan(before[0], 3)
        var edited = circuit
        edited.add(Element(kind: .resistor, a: GridPoint(40, 40), b: GridPoint(44, 40)))
        simulator.load(edited)
        XCTAssertEqual(simulator.terminalVoltages(c1)[0], before[0], accuracy: 1e-12, "shown before the next step")
    }

    func testTurningAKnobOnlyUpdatesParameters() throws {
        let circuit = Examples.chorus.circuit
        let simulator = Simulator(circuit: circuit, timeStep: 1 / 96_000)
        let line = index(circuit, "U1")
        for _ in 0..<4000 { simulator.step() }
        XCTAssertGreaterThan(abs(simulator.voltageAcross(line)), 0.5, "the delay line is putting out its input")
        // a parameter change keeps everything, the delay line's history included
        var turned = circuit
        turned.update(turned.elements[index(turned, "R3")].id) { $0[param: "resistance"] = 12_000 }
        XCTAssertTrue(simulator.updateParameters(turned))
        simulator.step()
        XCTAssertGreaterThan(abs(simulator.voltageAcross(line)), 0.5, "still delaying, not silent")
        // so does a full reload
        var added = turned
        added.add(Element(kind: .resistor, a: GridPoint(60, 60), b: GridPoint(64, 60)))
        XCTAssertFalse(simulator.updateParameters(added), "a new part is not just a parameter change")
        simulator.load(added)
        simulator.step()
        XCTAssertGreaterThan(abs(simulator.voltageAcross(line)), 0.5, "the history survives a reload")
    }

    func testStoppingTheSequenceLetsGoOfTheKey() throws {
        var circuit = Examples.acid.circuit
        let simulator = Simulator(circuit: circuit, timeStep: 1e-4)
        for _ in 0..<50 { simulator.step() }
        XCTAssertTrue(simulator.keyboard.gate, "the first step is playing")
        circuit.sequence?.playing = false
        simulator.load(circuit)
        simulator.step()
        XCTAssertFalse(simulator.keyboard.gate)
    }

    func testOutOfRangeChoicesDoNotTrap() throws {
        for (kind, key) in [(ElementKind.vco, "waveform"), (.divider, "division"), (.vca, "response"), (.sampleHold, "mode"),
                            (.led, "color")] {
            for value in [1e30, -1e30, .nan, .infinity] {
                var circuit = Circuit()
                var element = Element(kind: kind, a: GridPoint(0, 0), b: GridPoint(4, 0))
                element[param: key] = value
                circuit.add(element)
                circuit.add(Element(kind: .ground, a: GridPoint(4, 0), b: GridPoint(4, 1)))
                let simulator = Simulator(circuit: circuit, timeStep: 1e-4)
                for _ in 0..<20 { simulator.step() }
                XCTAssertTrue(simulator.voltageAcross(0).isFinite || simulator.isFailed, "\(kind) \(key) \(value)")
            }
        }
    }

    func testPlannedEliminationSolvesLikeAFreshOne() {
        // sparse systems solved again and again with changing values, as Newton-Raphson does: the plan is replayed,
        // and when an entry appears outside the plan or a pivot shrinks, elimination falls back and plans again
        var generator = SystemRandomNumberGenerator()
        func random() -> Double { Double.random(in: -1...1, using: &generator) }
        for trial in 0..<60 {
            let n = 2 + trial % 30
            var pattern = [Bool](repeating: false, count: n * n)
            for r in 0..<n {
                pattern[r * n + r] = trial % 3 != 0 || r % 2 == 0
                for _ in 0..<3 { pattern[r * n + Int.random(in: 0..<n, using: &generator)] = true }
            }
            let base = pattern.map { $0 ? random() : 0 }
            var plan: EliminationPlan?
            for iteration in 0..<20 {
                var a = base.enumerated().map { $0.element * (1 + 0.05 * random()) }
                if iteration % 7 == 3 { a[Int.random(in: 0..<(n * n), using: &generator)] += 1 }
                if iteration % 5 == 4 { for i in a.indices where pattern[i] && Double.random(in: 0...1, using: &generator) < 0.2 { a[i] = 0 } }
                let b = (0..<n).map { _ in random() }
                var matrix = a
                var x = b
                guard LUSolver.solveInPlace(&matrix, &x, size: n, plan: &plan, changed: nil) else { continue }
                var worst = 0.0
                for r in 0..<n {
                    var sum = -b[r]
                    for c in 0..<n { sum += a[r * n + c] * x[c] }
                    worst = max(worst, abs(sum))
                }
                let scale = max(1, x.map(abs).max() ?? 1)
                XCTAssertLessThan(worst / scale, 1e-8, "trial \(trial) iteration \(iteration)")
            }
        }
    }

    func testNoteNamesRejectWhatTheyCannotPlay() {
        XCTAssertEqual(NoteName.number("C4"), 60)
        XCTAssertEqual(NoteName.number("bb2"), 46)
        XCTAssertNil(NoteName.number("inf"))
        XCTAssertNil(NoteName.number("1e999"))
        XCTAssertNil(NoteName.number("ß4"))
        XCTAssertNil(NoteName.number("C9223372036854775807"))
        XCTAssertEqual(NoteName.name(.nan), "?")
        XCTAssertEqual(NoteName.name(1e300), "?")
        XCTAssertEqual(NoteName.name(69), "A4")
    }

    func testRailNames() {
        XCTAssertTrue(SchematicLayout.isRailName("+15V"))
        XCTAssertTrue(SchematicLayout.isRailName("-15"))
        XCTAssertTrue(SchematicLayout.isRailName("9V"))
        XCTAssertTrue(SchematicLayout.isRailName("VCC"))
        XCTAssertFalse(SchematicLayout.isRailName("1"), "a SPICE node number")
        XCTAssertFalse(SchematicLayout.isRailName("12"))
    }

    func testManyChipsOnOneNetDoNotLandOnEachOther() throws {
        var parts = [NetlistPart(kind: .keyboardPitch, name: "KB1", connections: ["plus": "cv", "minus": "GND"])]
        for k in 1...12 {
            parts.append(NetlistPart(kind: .vco, name: "U\(k)", connections: ["cv": "cv", "pw": "GND", "out": "o\(k)"]))
            parts.append(NetlistPart(kind: .resistor, name: "R\(k)", connections: ["a": "o\(k)", "b": "GND"]))
        }
        let circuit = try SchematicLayout.layout(parts)
        // what is drawn connects exactly what the netlist does: no two outputs joined
        let extracted = NetlistExtractor.netlist(from: circuit)
        var netOf: [String: String] = [:]
        for part in extracted {
            for (terminal, net) in part.connections { netOf[part.name + "." + terminal] = net }
        }
        let outputs = Set((1...12).compactMap { netOf["U\($0).out"] })
        XCTAssertEqual(outputs.count, 12)
        for k in 1...12 { XCTAssertEqual(netOf["U\(k).out"], netOf["R\(k).a"], "U\(k)") }
    }
}
