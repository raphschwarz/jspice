import XCTest
@testable import CircuitKit

/// Knobs: turned, swept for their effect on a frequency response, and moved back and forth by themselves, each against
/// what its circuit works out to on paper
final class KnobTests: XCTestCase {
    private func id(_ circuit: Circuit, _ name: String) throws -> UUID {
        try XCTUnwrap(circuit.elements.first { $0.name == name }, name).id
    }

    private func index(_ circuit: Circuit, _ name: String) throws -> Int {
        try XCTUnwrap(circuit.elements.firstIndex { $0.name == name }, name)
    }

    /// An RC low-pass whose resistor is a pot with its wiper on its b end: R = 10 kΩ × position into 100 nF
    private func filter() throws -> Circuit {
        try SchematicLayout.layout([
            NetlistPart(kind: .acVoltage, name: "V1", params: ["amplitude": 1, "frequency": 1000], connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .potentiometer, name: "P1", params: ["resistance": 10_000, "position": 0.5],
                        connections: ["a": "in", "b": "out", "wiper": "out"]),
            NetlistPart(kind: .capacitor, name: "C1", params: ["capacitance": 100e-9], connections: ["a": "out", "b": "GND"]),
        ])
    }

    func testKnobsAreTurnedOnTheSchematicAndInsideBlocks() throws {
        var circuit = try filter()
        let knob = KnobID(part: try id(circuit, "P1"))
        XCTAssertEqual(circuit.knobs.map { $0.name }, ["P1"])
        XCTAssertEqual(circuit.knobs.first?.id, knob)
        XCTAssertEqual(circuit.position(of: knob), 0.5)
        XCTAssertTrue(circuit.turn(knob, to: 0.8))
        XCTAssertEqual(circuit.position(of: knob), 0.8)
        // the same position again does not move it; past the ends it stops at them
        XCTAssertFalse(circuit.turn(knob, to: 0.8))
        XCTAssertTrue(circuit.turn(knob, to: 1.7))
        XCTAssertEqual(circuit.position(of: knob), 1)
        XCTAssertFalse(circuit.turn(knob, to: .nan))
        // a part that is not a pot is no knob
        let capacitor = KnobID(part: try id(circuit, "C1"))
        XCTAssertNil(circuit.position(of: capacitor))
        XCTAssertFalse(circuit.turn(capacitor, to: 0.3))

        // a pot inside a block
        var outer = Circuit()
        var element = Element(kind: .block, name: "X1", a: GridPoint(0, 0), b: GridPoint(4, 0))
        element.block = circuit.asBlock(named: "Filter")
        let part = outer.add(element)
        let inner = KnobID(part: part, inner: knob.part)
        XCTAssertEqual(outer.knobs.map { $0.name }, ["X1 P1"])
        XCTAssertEqual(outer.knobs.first?.id, inner)
        XCTAssertTrue(outer.turn(inner, to: 0.25))
        XCTAssertEqual(outer.position(of: inner), 0.25)
        XCTAssertEqual(outer.flattened()[UUID.inBlock(part, part: knob.part)]?[param: "position"], 0.25)
        XCTAssertNil(outer.position(of: KnobID(part: part, inner: capacitor.part)))
    }

    /// The response at each position is the RC low-pass's: −10 log₁₀(1 + (ωRC)²) dB and −atan(ωRC), R following the knob
    func testASweepFollowsTheKnobThroughAnRCFilter() throws {
        let circuit = try filter()
        let knob = KnobID(part: try id(circuit, "P1"))
        let frequencies = [50.0, 159.15, 318.31, 1000, 5000]
        let curves = KnobSweep.responses(circuit, knob: knob, positions: [0.25, 0.5, 1], element: try index(circuit, "C1"),
                                         input: try index(circuit, "V1"), frequencies: frequencies)
        XCTAssertEqual(curves.map(\.position), [0.25, 0.5, 1])
        for curve in curves {
            let r = 10_000 * curve.position
            for (k, f) in frequencies.enumerated() {
                let wrc = 2 * Double.pi * f * r * 100e-9
                XCTAssertEqual(curve.gains[k], -10 * log10(1 + wrc * wrc), accuracy: 0.01, "\(curve.position) at \(f) Hz")
                XCTAssertEqual(curve.phases[k], -atan(wrc) * 180 / .pi, accuracy: 0.1, "\(curve.position) at \(f) Hz")
            }
            XCTAssertNil(curve.margins)
        }
        // the circuit's own knob stays where it was
        XCTAssertEqual(circuit.position(of: knob), 0.5)
        XCTAssertEqual(KnobSweep.positions(5), [0, 0.25, 0.5, 0.75, 1])
        XCTAssertEqual(KnobSweep.positions(1), [0.5])
        // nothing to drive it from, or stopped at once: no curves
        XCTAssertTrue(KnobSweep.responses(circuit, knob: knob, positions: [0.5], element: try index(circuit, "C1"), input: nil,
                                          frequencies: frequencies).isEmpty)
        XCTAssertTrue(KnobSweep.responses(circuit, knob: knob, positions: [0.5], element: try index(circuit, "C1"),
                                          input: try index(circuit, "V1"), frequencies: frequencies, isCancelled: { true }).isEmpty)
    }

    /// A loop probe's sweep is its loop gain's: an inverting op-amp stage whose feedback resistor is a pot. With
    /// R_in = 10 kΩ and R_f = 100 kΩ × position, the loop's DC gain is A0 R_in / (R_in + R_f)
    func testASweepOfALoopProbeGivesTheLoopGainAndMarginsAtEachPosition() throws {
        let opAmp = NetlistPart(kind: .opAmp, name: "U1", params: ["gain": 1e5, "gbw": 1e6, "limit": 15, "slewRate": 0, "offset": 0],
                                connections: ["minus": "fb", "plus": "GND", "out": "out"])
        let circuit = try SchematicLayout.layout([
            NetlistPart(kind: .acVoltage, name: "V1", params: ["amplitude": 0.1, "frequency": 1000], connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "RIN", params: ["resistance": 10_000], connections: ["a": "in", "b": "fb"]),
            NetlistPart(kind: .potentiometer, name: "GAIN", params: ["resistance": 100_000, "position": 0.5],
                        connections: ["a": "fb", "b": "y", "wiper": "y"]),
            NetlistPart(kind: .loopProbe, name: "LP1", connections: ["in": "out", "out": "y"]),
            opAmp,
        ])
        let knob = KnobID(part: try id(circuit, "GAIN"))
        let curves = KnobSweep.responses(circuit, knob: knob, positions: [0.1, 1], element: try index(circuit, "LP1"), input: nil,
                                         frequencies: FrequencySweep.logarithmic(from: 1, to: 10e6, pointsPerDecade: 20))
        XCTAssertEqual(curves.count, 2)
        for curve in curves {
            let beta = 10_000 / (10_000 + 100_000 * curve.position)
            // (at 1 Hz, a tenth of the op-amp's 10 Hz pole)
            XCTAssertEqual(curve.gains[0], 20 * log10(1e5 * beta) - 10 * log10(1.01), accuracy: 0.02, "\(curve.position)")
            // a single pole: the loop crosses over near β × GBW, with about 90° of margin
            let margins = try XCTUnwrap(curve.margins)
            XCTAssertEqual(try XCTUnwrap(margins.crossover), 1e6 * beta, accuracy: 1e6 * beta * 0.05, "\(curve.position)")
            XCTAssertEqual(try XCTUnwrap(margins.phaseMargin), 90, accuracy: 3, "\(curve.position)")
        }
        // more feedback resistance, less loop gain
        XCTAssertGreaterThan(curves[0].gains[0], curves[1].gains[0])
    }

    func testAMotionGoesBackAndForthFromWhereTheKnobIs() {
        let knob = KnobID(part: UUID())
        let motion = KnobMotion(knob: knob, period: 2, low: 0.2, high: 0.8)
        XCTAssertEqual(motion.position(at: 0), 0.2, accuracy: 1e-12)
        XCTAssertEqual(motion.position(at: 0.5), 0.5, accuracy: 1e-12)
        XCTAssertEqual(motion.position(at: 1), 0.8, accuracy: 1e-12)
        XCTAssertEqual(motion.position(at: 1.5), 0.5, accuracy: 1e-12)
        XCTAssertEqual(motion.position(at: 2), 0.2, accuracy: 1e-12)
        XCTAssertEqual(motion.position(at: 7), 0.8, accuracy: 1e-12)
        // started from where the knob is, on its way up
        let from = KnobMotion(knob: knob, period: 2, low: 0.2, high: 0.8, from: 0.35)
        XCTAssertEqual(from.position(at: 0), 0.35, accuracy: 1e-12)
        XCTAssertGreaterThan(from.position(at: 0.01), 0.35)
        XCTAssertEqual(from.position(at: 2), 0.35, accuracy: 1e-12)
        // from outside its range: at the nearer end
        XCTAssertEqual(KnobMotion(knob: knob, low: 0.2, high: 0.8, from: 0.9).position(at: 0), 0.8, accuracy: 1e-12)
        XCTAssertEqual(KnobMotion(knob: knob, low: 0.2, high: 0.8, from: 0).position(at: 0), 0.2, accuracy: 1e-12)
        // a motion that does not move stays at its low end
        XCTAssertEqual(KnobMotion(knob: knob, period: 0, low: 0.3, high: 0.9).position(at: 5), 0.3)
    }

    /// A pot across 9 V, moved by a simulation every millisecond: its wiper reads 9 V × (1 − position) wherever the
    /// motion has it
    func testASimulationMovesTheKnobAsItRuns() throws {
        let circuit = try SchematicLayout.layout([
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 9], connections: ["plus": "vcc", "minus": "GND"]),
            NetlistPart(kind: .potentiometer, name: "P1", params: ["resistance": 10_000, "position": 0.5],
                        connections: ["a": "vcc", "b": "GND", "wiper": "w"]),
        ])
        let pot = try index(circuit, "P1")
        let motion = KnobMotion(knob: KnobID(part: circuit.elements[pot].id), period: 0.04)
        let simulator = Simulator(circuit: circuit, timeStep: 1e-4)
        var checked = 0
        for step in 0..<800 {
            if step % 10 == 0 {
                let time = simulator.time
                simulator.move([motion], at: time)
                simulator.step()
                let wiper = try XCTUnwrap(simulator.terminalVoltages(pot).last)
                XCTAssertEqual(wiper, 9 * (1 - motion.position(at: time)), accuracy: 2e-3, "at \(time) s")
                checked += 1
            } else {
                simulator.step()
            }
        }
        XCTAssertEqual(checked, 80)
        XCTAssertFalse(simulator.isFailed)
        // not moved again where the motion has it where it is
        XCTAssertFalse(simulator.move([KnobMotion(knob: motion.knob, period: 0, low: simulator.circuit.position(of: motion.knob) ?? 0)], at: 0))
    }

    /// A volume knob moved from full to off and back while a tone plays: the sound is loud where the knob is near 0
    /// (the wiper at the top) and silent where it is near 1
    func testARenderedSoundFollowsAMovingKnob() throws {
        let circuit = try SchematicLayout.layout([
            NetlistPart(kind: .acVoltage, name: "V1", params: ["amplitude": 0.5, "frequency": 1000], connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .potentiometer, name: "VOLUME", params: ["resistance": 10_000, "position": 0.5],
                        connections: ["a": "in", "b": "GND", "wiper": "w"]),
            NetlistPart(kind: .speaker, name: "SPK1", connections: ["plus": "w", "minus": "GND"]),
        ])
        let speaker = try index(circuit, "SPK1")
        let knob = KnobID(part: try id(circuit, "VOLUME"))
        let result = AudioRender.render(circuit, output: speaker, duration: 0.5, sampleRate: 24_000, oversampling: 2,
                                        knobs: [KnobMotion(knob: knob, period: 0.5)])
        XCTAssertEqual(result.samples.count, 12_000)
        func rms(_ from: Double, _ to: Double) -> Double {
            let slice = result.samples[Int(from * 24_000)..<Int(to * 24_000)]
            return sqrt(slice.reduce(0) { $0 + Double($1) * Double($1) } / Double(slice.count))
        }
        // near 0 at the start and the end, at 1 half way
        let start = rms(0.01, 0.04), middle = rms(0.235, 0.265), end = rms(0.46, 0.49)
        XCTAssertGreaterThan(start, 20 * middle, "\(start) \(middle)")
        XCTAssertGreaterThan(end, 20 * middle, "\(end) \(middle)")
        // without the motion, the knob stays half way
        let still = AudioRender.render(circuit, output: speaker, duration: 0.1, sampleRate: 24_000, oversampling: 2)
        let level = sqrt(still.samples[1200...].reduce(0) { $0 + Double($1) * Double($1) } / Double(still.samples.count - 1200))
        XCTAssertEqual(level, start / 2, accuracy: start * 0.1)
    }
}
