import XCTest
@testable import CircuitKit

/// The synth chips: VCO, VCF, envelope, VCA, sample and hold, comparator and clock divider
final class SynthChipTests: XCTestCase {
    private func model(_ kind: ElementKind, _ name: String) -> [String: Double] { Examples.model(kind, name) }

    /// Simulates the parts for `seconds` and returns the time and the voltage of the part named `probe` at every step
    private func run(_ parts: [NetlistPart], timeStep: Double, seconds: Double, probe: String) throws -> [(t: Double, v: Double)] {
        let circuit = try SchematicLayout.layout(parts)
        let simulator = Simulator(circuit: circuit, timeStep: timeStep)
        XCTAssertTrue(simulator.problems.isEmpty, simulator.problems.joined(separator: " "))
        let index = try XCTUnwrap(circuit.elements.firstIndex { $0.name == probe })
        var values: [(t: Double, v: Double)] = []
        values.reserveCapacity(Int(seconds / timeStep) + 2)
        while simulator.time < seconds && !simulator.isFailed {
            simulator.step()
            values.append((simulator.time, simulator.voltageAcross(index)))
        }
        XCTAssertFalse(simulator.isFailed, simulator.problems.joined(separator: " "))
        XCTAssertEqual(simulator.convergenceFailures, 0)
        return values
    }

    /// Frequency from the upward crossings of the mean
    private func frequency(_ values: ArraySlice<(t: Double, v: Double)>) -> Double {
        let mean = values.map(\.v).reduce(0, +) / Double(values.count)
        var crossings: [Double] = []
        var previous = values.first!.v
        for value in values.dropFirst() {
            if previous < mean && value.v >= mean { crossings.append(value.t) }
            previous = value.v
        }
        guard crossings.count > 2 else { return 0 }
        return Double(crossings.count - 1) / (crossings.last! - crossings.first!)
    }

    private func dc(_ name: String, _ volts: Double, _ net: String) -> NetlistPart {
        NetlistPart(kind: .dcVoltage, name: name, params: ["voltage": volts], connections: ["plus": net, "minus": "GND"])
    }

    private func load(_ net: String) -> NetlistPart {
        NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 10_000], connections: ["a": net, "b": "GND"])
    }

    // MARK: VCO

    func testVCOTracksOneVoltPerOctave() throws {
        for volts in [0.0, 1, 2, 3] {
            let values = try run([
                dc("VCV", volts, "cv"),
                NetlistPart(kind: .vco, name: "U1", params: model(.vco, "AS3340"), connections: ["cv": "cv", "pw": "GND", "out": "out"]),
                load("out"),
            ], timeStep: 1 / 192_000.0, seconds: 0.5, probe: "U1")
            let expected = 65.406 * pow(2, volts)
            XCTAssertEqual(frequency(values[values.count / 5...]), expected, accuracy: expected * 0.002, "\(volts) V")
            XCTAssertEqual(values.map(\.v).max() ?? 0, 5, accuracy: 0.1)
            XCTAssertEqual(values.map(\.v).min() ?? 0, -5, accuracy: 0.1)
        }
    }

    func testVCOWaveformsAndPulseWidth() throws {
        func wave(_ waveform: Double, pw: Double) throws -> [Double] {
            try run([
                dc("VPW", pw, "pw"),
                NetlistPart(kind: .vco, name: "U1", params: ["waveform": waveform, "frequency": 200],
                            connections: ["cv": "GND", "pw": "pw", "out": "out"]),
                load("out"),
            ], timeStep: 1 / 192_000.0, seconds: 0.2, probe: "U1").map(\.v)
        }
        // pulse: +2 V on PW makes the pulse high for 70 % of each cycle
        let pulse = try wave(2, pw: 2)
        XCTAssertEqual(Double(pulse.filter { $0 > 0 }.count) / Double(pulse.count), 0.7, accuracy: 0.01)
        let square = try wave(2, pw: 0)
        XCTAssertEqual(Double(square.filter { $0 > 0 }.count) / Double(square.count), 0.5, accuracy: 0.01)
        // triangle from −5 to 5 V; sine with the RMS of a 5 V sine
        let triangle = try wave(1, pw: 0)
        XCTAssertEqual(triangle.max() ?? 0, 5, accuracy: 0.02)
        XCTAssertEqual(triangle.min() ?? 0, -5, accuracy: 0.02)
        let sine = try wave(3, pw: 0)
        let rms = (sine.map { $0 * $0 }.reduce(0, +) / Double(sine.count)).squareRoot()
        XCTAssertEqual(rms, 5 / 2.0.squareRoot(), accuracy: 0.02)
    }

    // MARK: VCF

    private func filterGain(at frequency: Double, cutoff: Double = 1000, resonance: Double = 0, cv: Double = 0) throws -> Double {
        let amplitude = 0.05
        let values = try run([
            NetlistPart(kind: .acVoltage, name: "VIN", params: ["amplitude": amplitude, "frequency": frequency],
                        connections: ["plus": "in", "minus": "GND"]),
            dc("VCV", cv, "cv"),
            NetlistPart(kind: .vcf, name: "U1", params: ["cutoff": cutoff, "resonance": resonance],
                        connections: ["in": "in", "cv": "cv", "out": "out"]),
            load("out"),
        ], timeStep: 1 / 192_000.0, seconds: max(0.3, 6 / frequency), probe: "U1")
        let tail = values[(values.count / 2)...].map(\.v)
        return ((tail.max() ?? 0) - (tail.min() ?? 0)) / 2 / amplitude
    }

    func testVCFIsAFourPoleLowPass() throws {
        // four poles at the cutoff: each passes 1/√2 there, a quarter in all; 24 dB per octave above it
        XCTAssertEqual(try filterGain(at: 100), 0.98, accuracy: 0.01)
        XCTAssertEqual(try filterGain(at: 1000), 0.25, accuracy: 0.01)
        XCTAssertLessThan(try filterGain(at: 4000), 0.005)
        // the cutoff doubles with each volt: 250 Hz and 2 V is 1 kHz
        XCTAssertEqual(try filterGain(at: 1000, cutoff: 250, cv: 2), 0.25, accuracy: 0.01)
    }

    func testVCFResonance() throws {
        // resonance feeds the output back: the pass band drops to 1 / (1 + 4 r), the cutoff rises to a peak
        XCTAssertEqual(try filterGain(at: 5, resonance: 0.5), 1.0 / 3, accuracy: 0.01)
        XCTAssertGreaterThan(try filterGain(at: 1000, resonance: 0.9), 1.5)
        // past 1 it rings on by itself after a kick, near the cutoff
        let values = try run([
            NetlistPart(kind: .squareVoltage, name: "KICK", params: ["high": 0.5, "low": 0, "frequency": 1, "duty": 0.002],
                        connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .vcf, name: "U1", params: ["cutoff": 1000, "resonance": 1.1], connections: ["in": "in", "cv": "GND", "out": "out"]),
            load("out"),
        ], timeStep: 1 / 192_000.0, seconds: 0.5, probe: "U1")
        let tail = values[(values.count / 2)...]
        XCTAssertGreaterThan(tail.map(\.v).max() ?? 0, 0.5)
        XCTAssertEqual(frequency(tail), 950, accuracy: 100)
    }

    // MARK: Envelope

    func testEnvelopeAttackDecaySustainRelease() throws {
        let values = try run([
            NetlistPart(kind: .squareVoltage, name: "GATE", params: ["high": 5, "low": 0, "frequency": 1, "duty": 0.5],
                        connections: ["plus": "gate", "minus": "GND"]),
            NetlistPart(kind: .envelope, name: "U1", params: ["attack": 0.01, "decay": 0.1, "sustain": 0.5, "release": 0.2, "peak": 5],
                        connections: ["gate": "gate", "trig": "GND", "out": "env"]),
            load("env"),
        ], timeStep: 1e-4, seconds: 0.8, probe: "U1")
        func at(_ t: Double) -> Double { values.min { abs($0.t - t) < abs($1.t - t) }!.v }
        // the attack reaches the 5 V peak in 10 ms (plus a step or two to read the gate)
        let peak = values.max { $0.v < $1.v }!
        XCTAssertEqual(peak.v, 5, accuracy: 1e-9)
        XCTAssertEqual(peak.t, 0.0102, accuracy: 0.0003)
        XCTAssertEqual(at(0.005), 5 * 1.5 * (1 - pow(3, -0.0049 / 0.01)), accuracy: 0.1)
        // decay: nine tenths of the way to the 2.5 V sustain level in 100 ms, then it holds
        XCTAssertEqual(at(0.1102), 2.75, accuracy: 0.03)
        XCTAssertEqual(at(0.45), 2.5, accuracy: 0.01)
        // release: down to a tenth in 200 ms after the gate falls at 0.5 s
        XCTAssertEqual(at(0.7002), 0.25, accuracy: 0.01)
    }

    func testEnvelopeTriggerRestartsTheAttack() throws {
        let values = try run([
            dc("GATE", 5, "gate"),
            NetlistPart(kind: .squareVoltage, name: "TRIG", params: ["high": 5, "low": 0, "frequency": 2, "duty": 0.05],
                        connections: ["plus": "trig", "minus": "GND"]),
            NetlistPart(kind: .envelope, name: "U1", params: ["attack": 0.005, "decay": 0.05, "sustain": 0.2, "release": 0.2, "peak": 5],
                        connections: ["gate": "gate", "trig": "trig", "out": "env"]),
            load("env"),
        ], timeStep: 1e-4, seconds: 0.7, probe: "U1")
        // settled to sustain before the trigger at 0.5 s, back at the peak just after it
        XCTAssertEqual(values.last { $0.t < 0.49 }!.v, 1, accuracy: 0.01)
        XCTAssertEqual(values.filter { $0.t > 0.5 && $0.t < 0.52 }.map(\.v).max() ?? 0, 5, accuracy: 1e-9)
    }

    // MARK: VCA

    func testVCAExponentialAndLinearResponse() throws {
        func gain(_ name: String, cv: Double) throws -> Double {
            try run([
                dc("VIN", 1, "in"),
                dc("VCV", cv, "cv"),
                NetlistPart(kind: .vca, name: "U1", params: model(.vca, name), connections: ["in": "in", "cv": "cv", "out": "out"]),
                load("out"),
            ], timeStep: 1e-4, seconds: 0.001, probe: "U1").last!.v
        }
        // SSM2164: unity at 0 V, 20 dB down with 0.66 V (−33 mV per dB)
        XCTAssertEqual(try gain("SSM2164", cv: 0), 1, accuracy: 0.01)
        XCTAssertEqual(try gain("SSM2164", cv: 0.66), 0.1, accuracy: 0.002)
        XCTAssertEqual(try gain("SSM2164", cv: -0.66), 12 * tanh(10.0 / 12), accuracy: 0.01)
        // linear: half the gain at half of 5 V, nothing below 0 V
        XCTAssertEqual(try gain("Linear", cv: 2.5), 0.5, accuracy: 0.005)
        XCTAssertEqual(try gain("Linear", cv: -1), 0, accuracy: 1e-9)
    }

    // MARK: Sample and hold

    func testSampleAndHoldOnEachRisingEdge() throws {
        let values = try run([
            NetlistPart(kind: .acVoltage, name: "VIN", params: ["amplitude": 1, "frequency": 1], connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .squareVoltage, name: "CLK", params: ["high": 5, "low": 0, "frequency": 10, "duty": 0.5],
                        connections: ["plus": "clk", "minus": "GND"]),
            NetlistPart(kind: .sampleHold, name: "U1", params: model(.sampleHold, "Clocked"), connections: ["in": "in", "trig": "clk", "out": "out"]),
            load("out"),
        ], timeStep: 1e-4, seconds: 1, probe: "U1")
        for value in values where value.t > 0.1 {
            let edge = (value.t * 10).rounded(.down) / 10
            guard value.t - edge > 0.001 else { continue }
            XCTAssertEqual(value.v, sin(2 * .pi * edge), accuracy: 0.005, "t = \(value.t)")
        }
    }

    func testLF398TracksWhileHighAndHoldsWhileLow() throws {
        let values = try run([
            NetlistPart(kind: .acVoltage, name: "VIN", params: ["amplitude": 1, "frequency": 1], connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .squareVoltage, name: "CLK", params: ["high": 5, "low": 0, "frequency": 10, "duty": 0.5],
                        connections: ["plus": "clk", "minus": "GND"]),
            NetlistPart(kind: .sampleHold, name: "U1", params: model(.sampleHold, "LF398"), connections: ["in": "in", "trig": "clk", "out": "out"]),
            load("out"),
        ], timeStep: 1e-4, seconds: 1, probe: "U1")
        for value in values where value.t > 0.1 {
            let edge = (value.t * 10).rounded(.down) / 10
            let into = value.t - edge
            if into > 0.001 && into < 0.049 {
                XCTAssertEqual(value.v, sin(2 * .pi * value.t), accuracy: 0.01, "tracking at \(value.t)")
            } else if into > 0.051 {
                XCTAssertEqual(value.v, sin(2 * .pi * (edge + 0.05)), accuracy: 0.005, "holding at \(value.t)")
            }
        }
    }

    // MARK: Comparator

    func testComparatorSwitchesWithHysteresis() throws {
        let values = try run([
            NetlistPart(kind: .acVoltage, name: "VIN", params: ["amplitude": 1, "frequency": 10], connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .comparator, name: "U1", params: ["hysteresis": 0.2], connections: ["plus": "in", "minus": "GND", "out": "out"]),
            load("out"),
        ], timeStep: 1e-5, seconds: 0.3, probe: "U1")
        // LM393 levels
        XCTAssertEqual(values.map(\.v).max() ?? 0, 5, accuracy: 1e-9)
        XCTAssertEqual(values.map(\.v).min() ?? 0, 0.1, accuracy: 1e-9)
        var rises: [Double] = []
        var falls: [Double] = []
        for k in 1..<values.count where (values[k].v > 2.5) != (values[k - 1].v > 2.5) {
            if values[k].v > 2.5 { rises.append(values[k].t) } else { falls.append(values[k].t) }
        }
        // it goes high once the sine passes +0.1 V and low once it passes −0.1 V
        let delay = asin(0.1) / (2 * .pi * 10)
        XCTAssertEqual(rises.count, 3)
        XCTAssertEqual(falls.count, 3)
        for (k, t) in rises.enumerated() { XCTAssertEqual(t, Double(k) * 0.1 + delay, accuracy: 3e-5) }
        for (k, t) in falls.enumerated() { XCTAssertEqual(t, Double(k) * 0.1 + 0.05 + delay, accuracy: 3e-5) }
    }

    // MARK: Divider

    func testDividerDividesTheClock() throws {
        func risingEdges(division: Double, reset: Double = 0) throws -> Double {
            let values = try run([
                NetlistPart(kind: .squareVoltage, name: "CLK", params: ["high": 5, "low": 0, "frequency": 100, "duty": 0.5],
                            connections: ["plus": "clk", "minus": "GND"]),
                dc("VR", reset, "reset"),
                NetlistPart(kind: .divider, name: "U1", params: ["division": division], connections: ["clock": "clk", "reset": "reset", "out": "out"]),
                load("out"),
            ], timeStep: 1e-4, seconds: 1, probe: "U1")
            return Double((1..<values.count).filter { values[$0].v > 2.5 && values[$0 - 1].v < 2.5 }.count)
        }
        XCTAssertEqual(try risingEdges(division: 2), 50, accuracy: 1)
        XCTAssertEqual(try risingEdges(division: 3), 33, accuracy: 1)
        XCTAssertEqual(try risingEdges(division: 10), 10, accuracy: 1)
        // held in reset, the count stays at zero (output high)
        XCTAssertEqual(try risingEdges(division: 2, reset: 5), 0)
    }

    // MARK: Examples

    func testChipExamplesPlay() throws {
        for example in [Examples.chipVoice, Examples.randomNotes, Examples.comparatorPWM] {
            let simulator = Simulator(circuit: example.circuit, timeStep: 1 / 96_000.0)
            XCTAssertTrue(simulator.problems.isEmpty, "\(example.id): \(simulator.problems)")
            let speaker = try XCTUnwrap(example.circuit.elements.firstIndex { $0.kind == .speaker })
            var sum = 0.0
            var count = 0
            while simulator.time < 0.4 && !simulator.isFailed {
                simulator.step()
                if simulator.time > 0.05 {
                    sum += simulator.voltageAcross(speaker) * simulator.voltageAcross(speaker)
                    count += 1
                }
            }
            XCTAssertFalse(simulator.isFailed, example.id)
            let rms = (sum / Double(max(count, 1))).squareRoot()
            let fullScale = example.circuit.elements[speaker][param: "fullScale"]
            XCTAssertGreaterThan(rms, 0.05 * fullScale, example.id)
            XCTAssertLessThan(rms, 1.5 * fullScale, example.id)
        }
    }

    func testChoicesNameTheirValues() {
        let waveform = ElementKind.vco.params.first { $0.key == "waveform" }!
        XCTAssertEqual(waveform.choices.map(\.name), ["Saw", "Triangle", "Pulse", "Sine"])
        let division = ElementKind.divider.params.first { $0.key == "division" }!
        XCTAssertTrue(division.choices.contains(ParamChoice(name: "÷10", value: 10)))
    }
}
