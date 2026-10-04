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
        while simulator.time < settle + listen {
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

    func testEverySoundExampleHasASpeaker() {
        for id in ["beeper", "tone", "tremolo"] {
            XCTAssertTrue(Examples.example(id)?.circuit.elements.contains { $0.kind == .speaker } ?? false, id)
        }
    }
}
