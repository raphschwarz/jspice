import XCTest
@testable import CircuitKit

/// The sound examples, simulated as the app does with sound on: real time, one step per sample at 48 kHz.
final class AudioTests: XCTestCase {
    /// Frequency of the speaker's signal, from upward crossings of its mean, after the circuit has settled
    private func pitch(_ example: Example, settle: Double = 0.2, listen: Double = 0.3) -> Double {
        let circuit = example.circuit
        let speaker = circuit.elements.firstIndex { $0.kind == .speaker }!
        let simulator = Simulator(circuit: circuit, timeStep: 1 / 48_000)
        var values: [(Double, Double)] = []
        while simulator.time < settle + listen && !simulator.isFailed {
            simulator.step()
            if simulator.time > settle { values.append((simulator.time, simulator.voltageAcross(speaker))) }
        }
        XCTAssertFalse(simulator.isFailed, example.id)
        let mean = values.map(\.1).reduce(0, +) / Double(values.count)
        var crossings: [Double] = []
        for k in 1..<values.count where values[k - 1].1 < mean && values[k].1 >= mean { crossings.append(values[k].0) }
        guard crossings.count > 2 else { return 0 }
        return Double(crossings.count - 1) / (crossings.last! - crossings.first!)
    }

    func testBeeperPlaysItsDesignPitch() {
        // T = ln 2 (RA + 2 RB) C
        let period: Double = log(2.0) * 31_000.0 * 100e-9
        XCTAssertEqual(pitch(Examples.beeper), 1 / period, accuracy: 30)
    }

    func testToneFollowsThePotentiometer() {
        // R = 10k + half of the 100k pot; thresholds 0.38 and 0.6 of the supply
        let swing: Double = log(0.62 / 0.4) + log(0.6 / 0.38)
        let expected: Double = 1 / (60_000.0 * 22e-9 * swing)
        XCTAssertEqual(pitch(Examples.tone), expected, accuracy: expected * 0.1)
    }

    func testTremoloCarriesTheTone() {
        XCTAssertEqual(pitch(Examples.tremolo, settle: 0.1, listen: 0.5), 220, accuracy: 5)
    }

    /// The window's simulator follows the sound thread's by taking on its state; from then on both must agree exactly
    func testAdoptedStateCarriesOnIdentically() {
        for example in [Examples.tremolo, Examples.beeper, Examples.lfo] {
            let original = Simulator(circuit: example.circuit, timeStep: 1 / 48_000)
            for _ in 0..<2_000 { original.step() }
            let follower = Simulator(circuit: example.circuit, timeStep: 1e-4)
            follower.adoptState(of: original)
            XCTAssertEqual(follower.time, original.time, example.id)
            for _ in 0..<500 {
                original.step()
                follower.step()
            }
            for i in example.circuit.elements.indices {
                XCTAssertEqual(follower.voltageAcross(i), original.voltageAcross(i), accuracy: 1e-9, example.id)
                XCTAssertEqual(follower.current(i), original.current(i), accuracy: 1e-12, example.id)
            }
        }
    }

    // MARK: Keyboard

    /// Frequency and RMS (around its mean) of a part's voltage over `listen` seconds, after `settle` seconds
    private func listen(_ simulator: Simulator, to index: Int, settle: Double, listen: Double) -> (frequency: Double, rms: Double) {
        let end = simulator.time + settle + listen
        let start = simulator.time + settle
        var values: [(Double, Double)] = []
        let failuresBefore = simulator.convergenceFailures
        let deadline = Date().addingTimeInterval(120)
        while simulator.time < end && !simulator.isFailed {
            simulator.step()
            if simulator.time > start { values.append((simulator.time, simulator.voltageAcross(index))) }
            if Date() > deadline {
                XCTFail("too slow: reached \(simulator.time) s of \(end) s with \(simulator.convergenceFailures - failuresBefore) unconverged steps")
                break
            }
        }
        XCTAssertFalse(simulator.isFailed, simulator.problems.joined(separator: " "))
        XCTAssertLessThan(simulator.convergenceFailures - failuresBefore, values.count / 100 + 5, "unconverged steps")
        guard values.count > 2 else { return (0, 0) }
        let mean = values.map(\.1).reduce(0, +) / Double(values.count)
        let rms = (values.map { ($0.1 - mean) * ($0.1 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
        var crossings: [Double] = []
        for k in 1..<values.count where values[k - 1].1 < mean && values[k].1 >= mean { crossings.append(values[k].0) }
        guard crossings.count > 2 else { return (0, rms) }
        return (Double(crossings.count - 1) / (crossings.last! - crossings.first!), rms)
    }

    func testKeyboardSourcesFollowTheKeyboard() throws {
        let circuit = try SchematicLayout.layout([
            NetlistPart(kind: .keyboardPitch, name: "KB1", params: ["glide": 0], connections: ["plus": "cv", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "R1", connections: ["a": "cv", "b": "GND"]),
            NetlistPart(kind: .keyboardGate, name: "KB2", params: ["high": 10], connections: ["plus": "gate", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "R2", connections: ["a": "gate", "b": "GND"]),
        ])
        let simulator = Simulator(circuit: circuit, timeStep: 1e-4)
        let pitch = circuit.elements.firstIndex { $0.name == "KB1" }!
        let gate = circuit.elements.firstIndex { $0.name == "KB2" }!
        simulator.step()
        XCTAssertEqual(simulator.voltageAcross(pitch), 2, accuracy: 1e-9, "middle C is 2 V above C2")
        XCTAssertEqual(simulator.voltageAcross(gate), 0, accuracy: 1e-9)
        simulator.keyboard = Simulator.KeyboardState(note: 69, gate: true)
        simulator.step()
        XCTAssertEqual(simulator.voltageAcross(pitch), 33.0 / 12, accuracy: 1e-9)
        XCTAssertEqual(simulator.voltageAcross(gate), 10, accuracy: 1e-9)
    }

    func testGlideSlidesBetweenNotes() throws {
        let circuit = try SchematicLayout.layout([
            NetlistPart(kind: .keyboardPitch, name: "KB1", params: ["glide": 0.1], connections: ["plus": "cv", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "R1", connections: ["a": "cv", "b": "GND"]),
        ])
        let simulator = Simulator(circuit: circuit, timeStep: 1e-3)
        let pitch = circuit.elements.firstIndex { $0.name == "KB1" }!
        simulator.step()
        XCTAssertEqual(simulator.voltageAcross(pitch), 2, accuracy: 1e-9)
        simulator.keyboard.note = 72
        for _ in 0..<100 { simulator.step() }
        // one time constant: 63 % of the way from 2 V to 3 V
        XCTAssertEqual(simulator.voltageAcross(pitch), 2 + (1 - exp(-1)), accuracy: 0.01)
    }

    /// The renderer runs four steps per 48 kHz sample
    private let oversampledStep = 1 / 192_000.0

    func testVCOTracksOneVoltPerOctave() {
        let circuit = Examples.keyboardVCO.circuit
        let speaker = circuit.elements.firstIndex { $0.kind == .speaker }!
        let simulator = Simulator(circuit: circuit, timeStep: oversampledStep)
        let c4 = listen(simulator, to: speaker, settle: 0.05, listen: 0.2)
        XCTAssertFalse(simulator.isFailed)
        XCTAssertEqual(c4.frequency, 261.63, accuracy: 261.63 * 0.04, "C4")
        XCTAssertEqual(c4.rms, 4.5 / 3.0.squareRoot(), accuracy: 0.4, "a ±4.5 V triangle")
        simulator.keyboard.note = 72
        let c5 = listen(simulator, to: speaker, settle: 0.02, listen: 0.2)
        simulator.keyboard.note = 48
        let c3 = listen(simulator, to: speaker, settle: 0.02, listen: 0.3)
        XCTAssertEqual(c5.frequency / c4.frequency, 2, accuracy: 0.06, "an octave up doubles the frequency")
        XCTAssertEqual(c4.frequency / c3.frequency, 2, accuracy: 0.06, "an octave down halves it")
    }

    func testSynthSoundsOnlyWhileAKeyIsHeld() {
        let circuit = Examples.monoSynth.circuit
        let speaker = circuit.elements.firstIndex { $0.kind == .speaker }!
        let simulator = Simulator(circuit: circuit, timeStep: oversampledStep)
        let silent = listen(simulator, to: speaker, settle: 0.4, listen: 0.1)
        XCTAssertLessThan(silent.rms, 0.02, "no key, no sound")
        simulator.keyboard = Simulator.KeyboardState(note: 69, gate: true)
        let playing = listen(simulator, to: speaker, settle: 0.1, listen: 0.2)
        XCTAssertGreaterThan(playing.rms, 0.3, "a held key sounds")
        XCTAssertEqual(playing.frequency, 440, accuracy: 440 * 0.05, "A4")
        simulator.keyboard.gate = false
        let released = listen(simulator, to: speaker, settle: 0.8, listen: 0.1)
        XCTAssertLessThan(released.rms, 0.02, "the note dies away after release")
        XCTAssertFalse(simulator.isFailed)
    }

    func testSynthVoiceOpensItsFilterWithTheEnvelope() {
        let circuit = Examples.voice.circuit
        let speaker = circuit.elements.firstIndex { $0.kind == .speaker }!
        let filterBias = circuit.elements.firstIndex { $0.name == "FRB1" }!
        let simulator = Simulator(circuit: circuit, timeStep: oversampledStep)
        let silent = listen(simulator, to: speaker, settle: 0.1, listen: 0.1)
        XCTAssertLessThan(silent.rms, 0.02, "no key, no sound")
        XCTAssertLessThan(abs(simulator.current(filterBias)), 1e-6, "filter closed")
        simulator.keyboard = Simulator.KeyboardState(note: 69, gate: true)
        let playing = listen(simulator, to: speaker, settle: 0.1, listen: 0.2)
        XCTAssertGreaterThan(playing.rms, 0.3, "a held key sounds")
        XCTAssertEqual(playing.frequency, 440, accuracy: 440 * 0.05, "A4")
        // about 420 µA: a cutoff near 2.8 kHz
        XCTAssertEqual(simulator.current(filterBias), 420e-6, accuracy: 80e-6, "filter open")
        simulator.keyboard.gate = false
        let released = listen(simulator, to: speaker, settle: 0.5, listen: 0.1)
        XCTAssertLessThan(released.rms, 0.02, "the note dies away after release")
        XCTAssertLessThan(abs(simulator.current(filterBias)), 1e-6, "and the filter closes")
    }

    func testNoiseIsWhiteGaussianAndRepeatable() throws {
        let circuit = try SchematicLayout.layout([
            NetlistPart(kind: .noiseVoltage, name: "N1", params: ["amplitude": 0.5], connections: ["plus": "n", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "R1", connections: ["a": "n", "b": "GND"]),
        ])
        let noise = circuit.elements.firstIndex { $0.name == "N1" }!
        func run() -> [Double] {
            let simulator = Simulator(circuit: circuit, timeStep: 1 / 48_000)
            return (0..<48_000).map { _ in
                simulator.step()
                return simulator.voltageAcross(noise)
            }
        }
        let samples = run()
        let mean = samples.reduce(0, +) / Double(samples.count)
        let rms = (samples.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(samples.count)).squareRoot()
        XCTAssertEqual(mean, 0, accuracy: 0.01)
        XCTAssertEqual(rms, 0.5, accuracy: 0.01)
        // white: one sample says nothing about the next
        var correlation = 0.0
        for k in 1..<samples.count { correlation += (samples[k] - mean) * (samples[k - 1] - mean) }
        XCTAssertEqual(correlation / Double(samples.count - 1) / (rms * rms), 0, accuracy: 0.02)
        // Gaussian: about 4.6 % of samples beyond two standard deviations
        let tails = Double(samples.filter { abs($0 - mean) > 2 * rms }.count) / Double(samples.count)
        XCTAssertEqual(tails, 0.0455, accuracy: 0.006)
        XCTAssertEqual(run(), samples, "the same every run")
    }

    func testFilterAndWindExamplesSound() {
        for example in [Examples.filter, Examples.wind] {
            let speaker = example.circuit.elements.firstIndex { $0.kind == .speaker }!
            let simulator = Simulator(circuit: example.circuit, timeStep: oversampledStep)
            let heard = listen(simulator, to: speaker, settle: 0.05, listen: 0.2)
            XCTAssertGreaterThan(heard.rms, 0.2, example.id)
            XCTAssertLessThan(heard.rms, 10, example.id)
        }
    }

    func testEverySoundExampleHasASpeaker() {
        for id in ["beeper", "tone", "tremolo", "vco", "synth", "vcf", "wind", "voice"] {
            XCTAssertTrue(Examples.example(id)?.circuit.elements.contains { $0.kind == .speaker } ?? false, id)
        }
    }
}
