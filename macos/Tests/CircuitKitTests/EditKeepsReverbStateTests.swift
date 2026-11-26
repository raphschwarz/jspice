import XCTest
@testable import CircuitKit

/// A spring reverb's springs and an FV-1's delay memory and LFO are kept through an edit of the circuit as a delay
/// line's history is: a wire added while a reverb rings leaves its tail ringing on as it would have without the edit,
/// and a part removed and put back starts with its tank empty.
final class EditKeepsReverbStateTests: XCTestCase {
    private func part(_ kind: ElementKind, _ name: String, _ params: [String: Double] = [:], _ connections: [String: String]) -> NetlistPart {
        NetlistPart(kind: kind, name: name, params: params, connections: connections)
    }

    private func index(_ circuit: Circuit, _ name: String) -> Int {
        circuit.elements.firstIndex { $0.name == name } ?? -1
    }

    /// The probe's voltage at each step for `seconds`
    private func record(_ simulator: Simulator, _ probe: Int, seconds: Double) -> [Double] {
        var out: [Double] = []
        let end = simulator.time + seconds
        while simulator.time < end && !simulator.isFailed {
            simulator.step()
            out.append(simulator.voltageAcross(probe))
        }
        return out
    }

    private func rms(_ x: [Double]) -> Double { (x.reduce(0) { $0 + $1 * $1 } / Double(max(x.count, 1))).squareRoot() }

    /// Rings `circuit`'s part U1 for `ring` seconds, then: an edit out of the way (the tail goes on as in an unedited
    /// twin), and the part removed and put back (its tail gone)
    private func check(_ circuit: Circuit, timeStep: Double, ring: Double, listen: Double,
                       file: StaticString = #filePath, line: UInt = #line) {
        let probe = index(circuit, "OUT")
        let simulator = Simulator(circuit: circuit, timeStep: timeStep)
        let twin = Simulator(circuit: circuit, timeStep: timeStep)
        _ = record(simulator, probe, seconds: ring)
        _ = record(twin, probe, seconds: ring)
        XCTAssertFalse(simulator.isFailed, simulator.problems.joined(separator: " "), file: file, line: line)

        // a resistor added out of the way
        var edited = circuit
        edited.add(Element(kind: .resistor, a: GridPoint(400, 400), b: GridPoint(404, 400)))
        simulator.load(edited)
        let kept = record(simulator, probe, seconds: listen)
        let expected = record(twin, probe, seconds: listen)
        XCTAssertGreaterThan(rms(expected), 1e-4, "the tail is still ringing", file: file, line: line)
        XCTAssertEqual(kept.count, expected.count, file: file, line: line)
        let difference = zip(kept, expected).map { abs($0 - $1) }.max() ?? .infinity
        XCTAssertLessThan(difference, 1e-6 * max(1, rms(expected)), "the tail rings on through the edit", file: file, line: line)

        // removed, then put back: a part fresh from the box, all but silent with nothing going in
        let element = edited.elements[index(edited, "U1")]
        var without = edited
        without.remove([element.id])
        simulator.load(without)
        var back = without
        back.elements.append(element)
        simulator.load(back)
        let afresh = record(simulator, index(back, "OUT"), seconds: listen)
        XCTAssertLessThan(rms(afresh), 0.01 * rms(expected), "put back with its tank empty", file: file, line: line)
    }

    func testASpringReverbKeepsRingingThroughAnEdit() throws {
        // a 5 ms pulse at the start, then silence
        let circuit = try SchematicLayout.layout([
            part(.squareVoltage, "VS", ["high": 1, "low": 0, "frequency": 1, "duty": 0.005], ["plus": "in", "minus": "GND"]),
            part(.springReverb, "U1", [:], ["in": "in", "gnd": "GND", "out": "out"]),
            part(.probe, "OUT", [:], ["plus": "out", "minus": "GND"]),
        ])
        check(circuit, timeStep: 2e-5, ring: 0.1, listen: 0.05)
    }

    func testAnFV1KeepsItsReverbThroughAnEdit() throws {
        // a 20 ms burst of a 500 Hz tone into the hall reverb, then silence
        let circuit = try SchematicLayout.layout([
            part(.dcVoltage, "V33", ["voltage": 3.3], ["plus": "+3V3", "minus": "GND"]),
            part(.effectsProcessor, "U1", Examples.model(.effectsProcessor, "FV-1").merging(["program": 7]) { $1 },
                 ["in": "in", "pot0": "p0", "pot1": "p1", "pot2": "p2", "outL": "left", "outR": "right"]),
            part(.resistor, "RIN", ["resistance": 100_000], ["a": "in", "b": "GND"]),
            part(.dcVoltage, "VP0", ["voltage": 3.3 * 0.5], ["plus": "p0", "minus": "GND"]),
            part(.dcVoltage, "VP1", ["voltage": 3.3 * 0.5], ["plus": "p1", "minus": "GND"]),
            part(.dcVoltage, "VP2", ["voltage": 3.3 * 0.2], ["plus": "p2", "minus": "GND"]),
            part(.resistor, "RL", ["resistance": 10_000], ["a": "left", "b": "GND"]),
            part(.resistor, "RR", ["resistance": 10_000], ["a": "right", "b": "GND"]),
            part(.probe, "OUT", [:], ["plus": "left", "minus": "GND"]),
            part(.acVoltage, "VS", ["amplitude": 0.5, "frequency": 500], ["plus": "s", "minus": "GND"]),
            part(.analogSwitch, "S1", ["supply": 5, "onResistance": 1], ["a": "s", "b": "in", "control": "gate"]),
            part(.squareVoltage, "GATE", ["high": 5, "low": 0, "frequency": 0.5, "duty": 0.01], ["plus": "gate", "minus": "GND"]),
        ])
        check(circuit, timeStep: 1 / 48_000, ring: 0.3, listen: 0.1)
    }
}
