import XCTest
@testable import CircuitKit

/// The bucket-brigade chips, the digital reverbs and the photo-FET: a bucket brigade clocked from its pin delays by
/// its stages over twice its clock, counted exactly from a clock driver however long the steps; the clock driver's
/// frequency; the MN3011's taps; the FV-1's programs; the reverb brick's tail; the H11F1's resistance
final class DelayChipsTests: XCTestCase {
    private func part(_ kind: ElementKind, _ name: String, _ params: [String: Double] = [:], _ connections: [String: String]) -> NetlistPart {
        NetlistPart(kind: kind, name: name, params: params, connections: connections)
    }

    private func r(_ name: String, _ ohms: Double, _ a: String, _ b: String) -> NetlistPart {
        part(.resistor, name, ["resistance": ohms], ["a": a, "b": b])
    }

    private func dc(_ name: String, _ volts: Double, plus: String, minus: String = "GND") -> NetlistPart {
        part(.dcVoltage, name, ["voltage": volts], ["plus": plus, "minus": minus])
    }

    private func sine(_ name: String, _ amplitude: Double, _ frequency: Double, plus: String) -> NetlistPart {
        part(.acVoltage, name, ["amplitude": amplitude, "frequency": frequency], ["plus": plus, "minus": "GND"])
    }

    private func probe(_ name: String, _ plus: String, _ minus: String = "GND") -> NetlistPart {
        part(.probe, name, [:], ["plus": plus, "minus": minus])
    }

    /// Simulates `seconds` and calls `sample` with the time and the named parts' voltages at each step from `from` on
    private func run(_ parts: [NetlistPart], dt: Double, seconds: Double, from: Double = 0, watch: [String],
                     sample: (Double, [String: Double]) -> Void, file: StaticString = #filePath, line: UInt = #line) throws {
        let circuit = try SchematicLayout.layout(parts)
        let simulator = Simulator(circuit: circuit, timeStep: dt)
        let indices = try watch.map { name in try XCTUnwrap(circuit.elements.firstIndex { $0.name == name }, name, file: file, line: line) }
        while simulator.time < seconds {
            simulator.step()
            XCTAssertFalse(simulator.isFailed, simulator.problems.joined(separator: " "), file: file, line: line)
            if simulator.isFailed { break }
            guard simulator.time >= from else { continue }
            var values: [String: Double] = [:]
            for (name, index) in zip(watch, indices) { values[name] = simulator.voltageAcross(index) }
            sample(simulator.time, values)
        }
    }

    /// The largest difference between `name`'s voltage and a sine of `amplitude` and `frequency` delayed by `delay`
    private func error(against delay: Double, amplitude: Double, frequency: Double, of name: String, in parts: [NetlistPart],
                       dt: Double, seconds: Double, file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        var worst = 0.0
        try run(parts, dt: dt, seconds: seconds, from: delay + 0.01, watch: [name], sample: { t, v in
            worst = max(worst, abs((v[name] ?? 0) - amplitude * sin(2 * .pi * frequency * (t - delay))))
        }, file: file, line: line)
        return worst
    }

    func testBucketBrigadeOnItsClockPinDelaysByHalfItsStagesOfClockCycles() throws {
        // 1024 stages on a 20 kHz square wave: 512 cycles, 25.6 ms
        let parts = [
            sine("VS", 1, 50, plus: "in"),
            part(.squareVoltage, "CLK", ["high": 5, "low": 0, "frequency": 20_000], ["plus": "clk", "minus": "GND"]),
            part(.delayLine, "U1", Examples.model(.delayLine, "MN3207").merging(["clocking": 1]) { $1 },
                 ["in": "in", "ctrl": "clk", "out": "out"]),
            r("RL", 10_000, "out", "GND"),
            probe("OUT", "out"),
        ]
        XCTAssertLessThan(try error(against: 0.0256, amplitude: 1, frequency: 50, of: "OUT", in: parts, dt: 5e-6, seconds: 0.08), 0.03)
        // and without a clock it holds what it has: nothing comes through
        var largest = 0.0
        try run([
            sine("VS", 1, 50, plus: "in"),
            part(.delayLine, "U1", Examples.model(.delayLine, "MN3207").merging(["clocking": 1]) { $1 },
                 ["in": "in", "ctrl": "GND", "out": "out"]),
            r("RL", 10_000, "out", "GND"),
            probe("OUT", "out"),
        ], dt: 5e-6, seconds: 0.05, watch: ["OUT"]) { _, v in largest = max(largest, abs(v["OUT"] ?? 0)) }
        XCTAssertEqual(largest, 0, accuracy: 1e-9)
    }

    func testClockDriverRunsAtOneOverTwoPointTwoRCWithAntiphaseOutputsAndVGG() throws {
        // 56 kΩ and the internal 1 kΩ with 100 pF: 1 / (2.2 × 57 kΩ × 100 pF) = 79.7 kHz
        var rising = 0
        var last = 0.0
        var antiphase = true
        var vgg = 0.0
        try run([
            r("RT", 56_000, "rx", "GND"),
            part(.bbdClock, "U1", Examples.model(.bbdClock, "MN3101"), ["rx": "rx", "cp1": "cp1", "cp2": "cp2", "vgg": "vgg"]),
            r("R1", 100_000, "cp1", "GND"),
            r("R2", 100_000, "cp2", "GND"),
            r("R3", 100_000, "vgg", "GND"),
            probe("CP1", "cp1"),
            probe("CP2", "cp2"),
            probe("VGG", "vgg"),
        ], dt: 2e-7, seconds: 2.1e-3, from: 1e-4, watch: ["CP1", "CP2", "VGG"]) { _, v in
            let cp1 = v["CP1"] ?? 0, cp2 = v["CP2"] ?? 0
            if last < 7.5 && cp1 >= 7.5 { rising += 1 }
            last = cp1
            // between edges, one is high while the other is low
            if abs(cp1 - 7.5) > 6 && abs(cp1 + cp2 - 15) > 0.5 { antiphase = false }
            vgg = v["VGG"] ?? 0
        }
        XCTAssertEqual(Double(rising) / 2e-3, 1 / (2.2 * 57_000 * 100e-12), accuracy: 0.02 / (2.2 * 57_000 * 100e-12))
        XCTAssertTrue(antiphase)
        XCTAssertEqual(vgg, 14, accuracy: 1e-6)
    }

    func testBucketBrigadeCountsItsClockDriversCyclesWhateverTheStep() throws {
        // an 80 kHz clock and steps of 50 µs (four clock cycles each): still 512 cycles, 6.4 ms
        let rx = 1 / (2.2 * 100e-12 * 80_000) - 1000
        let parts = [
            sine("VS", 1, 20, plus: "in"),
            r("RT", rx, "rx", "GND"),
            part(.bbdClock, "U1", Examples.model(.bbdClock, "MN3102"), ["rx": "rx", "cp1": "cp1", "cp2": "cp2", "vgg": "vgg"]),
            part(.delayLine, "U2", Examples.model(.delayLine, "MN3207").merging(["clocking": 1]) { $1 },
                 ["in": "in", "ctrl": "cp2", "out": "out"]),
            r("RL", 10_000, "out", "GND"),
            probe("OUT", "out"),
        ]
        XCTAssertLessThan(try error(against: 0.0064, amplitude: 1, frequency: 20, of: "OUT", in: parts, dt: 5e-5, seconds: 0.1), 0.02)
        XCTAssertLessThan(try error(against: 0.0064, amplitude: 1, frequency: 20, of: "OUT", in: parts, dt: 2e-6, seconds: 0.05), 0.02)
    }

    func testMN3011TapsAreAlongTheLine() throws {
        // a 20 kHz clock: each tap delays by its stages over 40 000
        let taps: [Double] = [396, 662, 1194, 1726, 2790, 3328]
        for (k, stages) in taps.enumerated() {
            let parts = [
                sine("VS", 1, 20, plus: "in"),
                part(.squareVoltage, "CLK", ["high": 9, "low": 0, "frequency": 20_000], ["plus": "clk", "minus": "GND"]),
                part(.multiTapDelay, "U1", Examples.model(.multiTapDelay, "MN3011"),
                     ["in": "in", "cp": "clk", "out1": "t1", "out2": "t2", "out3": "t3", "out4": "t4", "out5": "t5", "out6": "t6"]),
                probe("TAP", "t\(k + 1)"),
            ]
            XCTAssertLessThan(try error(against: stages / 40_000, amplitude: 1, frequency: 20, of: "TAP", in: parts, dt: 5e-6, seconds: 0.12),
                              0.02, "tap \(k + 1)")
        }
    }

    /// The FV-1 running `program` for `seconds` on what `source` puts on its input, its pots at the given fractions of
    /// 3.3 V: its left output at each step
    private func fv1(program: Int, pots: [Double], source: [NetlistPart], seconds: Double, dt: Double = 1 / 96_000) throws -> [Double] {
        var out: [Double] = []
        try run([
            dc("V33", 3.3, plus: "+3V3"),
            part(.effectsProcessor, "U1", Examples.model(.effectsProcessor, "FV-1").merging(["program": Double(program)]) { $1 },
                 ["in": "in", "pot0": "p0", "pot1": "p1", "pot2": "p2", "outL": "left", "outR": "right"]),
            r("RIN", 100_000, "in", "GND"),
            dc("VP0", 3.3 * pots[0], plus: "p0"),
            dc("VP1", 3.3 * pots[1], plus: "p1"),
            dc("VP2", 3.3 * pots[2], plus: "p2"),
            r("RL", 10_000, "left", "GND"),
            r("RR", 10_000, "right", "GND"),
            probe("LEFT", "left"),
        ] + source, dt: dt, seconds: seconds, watch: ["LEFT"]) { _, v in out.append(v["LEFT"] ?? 0) }
        return out
    }

    /// A 0.5 V, 440 Hz tone into the processor
    private var tone: [NetlistPart] { [sine("VS", 0.5, 440, plus: "in")] }

    /// A 20 ms burst of a 500 Hz tone, then silence
    private var burst: [NetlistPart] {
        [
            sine("VS", 0.5, 500, plus: "s"),
            part(.analogSwitch, "S1", ["supply": 5, "onResistance": 1], ["a": "s", "b": "in", "control": "gate"]),
            part(.squareVoltage, "GATE", ["high": 5, "low": 0, "frequency": 0.5, "duty": 0.01], ["plus": "gate", "minus": "GND"]),
        ]
    }

    private func rms(_ x: ArraySlice<Double>) -> Double { (x.reduce(0) { $0 + $1 * $1 } / Double(max(x.count, 1))).squareRoot() }

    /// The size of the `frequency` component of `x`, sampled every `dt`
    private func component(_ x: ArraySlice<Double>, _ frequency: Double, dt: Double) -> Double {
        var re = 0.0, im = 0.0
        for (k, v) in x.enumerated() {
            re += v * cos(2 * .pi * frequency * Double(k) * dt)
            im += v * sin(2 * .pi * frequency * Double(k) * dt)
        }
        return 2 * (re * re + im * im).squareRoot() / Double(x.count)
    }

    func testFV1TestProgramPassesTheInputAndPitchShiftShiftsIt() throws {
        let dt = 1 / 96_000.0
        let through = try fv1(program: 5, pots: [0, 0, 0], source: tone, seconds: 0.2)
        XCTAssertEqual(rms(through[9600...]), 0.5 / 2.squareRoot(), accuracy: 0.02)
        // POT0 at the top: four semitones up, 554 Hz, and almost nothing left at 440 Hz
        let up = try fv1(program: 3, pots: [1, 0, 0], source: tone, seconds: 0.4)
        let shifted = up[9600...]
        XCTAssertGreaterThan(component(shifted, 440 * pow(2, 4.0 / 12), dt: dt), 0.3)
        XCTAssertLessThan(component(shifted, 440, dt: dt), 0.03)
        // and a quarter of the way: two semitones down
        let down = try fv1(program: 3, pots: [0.25, 0, 0], source: tone, seconds: 0.4)
        XCTAssertGreaterThan(component(down[9600...], 440 * pow(2, -2.0 / 12), dt: dt), 0.3)
    }

    func testFV1ReverbRingsOnAndDiesAwayAndItsMixPotsStartDry() throws {
        // a 20 ms burst, then silence: the tail is there long after, and smaller later
        let tail = try fv1(program: 7, pots: [0.5, 0.5, 0.2], source: burst, seconds: 1.5, dt: 1 / 48_000)
        let early = rms(tail[(48_000 / 5)..<(48_000 * 2 / 5)])
        let late = rms(tail[(48_000 * 6 / 5)..<(48_000 * 7 / 5)])
        XCTAssertGreaterThan(early, 1e-3)
        XCTAssertLessThan(late, early / 2)
        XCTAssertTrue(tail.allSatisfy { $0.isFinite && abs($0) <= EffectsProcessor.fullScale })
        // chorus-reverb with its mix pots down: just the input
        let dry = try fv1(program: 0, pots: [0, 0.5, 0], source: tone, seconds: 0.2)
        XCTAssertEqual(rms(dry[9600...]), 0.5 / 2.squareRoot(), accuracy: 0.02)
    }

    func testReverbBrickRingsAfterItsInputStops() throws {
        var during = 0.0, after = 0.0
        try run([
            part(.squareVoltage, "VS", ["high": 0.5, "low": -0.5, "frequency": 200], ["plus": "s", "minus": "GND"]),
            part(.analogSwitch, "S1", ["supply": 5, "onResistance": 1], ["a": "s", "b": "in", "control": "gate"]),
            part(.squareVoltage, "GATE", ["high": 5, "low": 0, "frequency": 1, "duty": 0.1], ["plus": "gate", "minus": "GND"]),
            r("RIN", 100_000, "in", "GND"),
            part(.reverbBrick, "U1", Examples.model(.reverbBrick, "BTDR-2H"), ["in": "in", "gnd": "GND", "out1": "o1", "out2": "o2"]),
            r("RL1", 10_000, "o1", "GND"),
            r("RL2", 10_000, "o2", "GND"),
            probe("OUT", "o1"),
        ], dt: 2e-5, seconds: 0.5, watch: ["OUT"]) { t, v in
            let out = abs(v["OUT"] ?? 0)
            if t < 0.1 { during = max(during, out) } else if t > 0.3 { after = max(after, out) }
        }
        XCTAssertGreaterThan(during, 0.01)
        XCTAssertGreaterThan(after, 1e-3)
        XCTAssertLessThan(after, 1)
    }

    func testH11F1ChannelIsAboutItsOnResistanceAt16mAAndOpenDark() throws {
        func resistance(led: Double) throws -> Double {
            var current = 0.0
            try run([
                part(.currentSource, "IF", ["current": max(led, 1e-6)], ["plus": "a", "minus": "GND"]),
                part(.vactrol, "U1", Examples.model(.vactrol, "H11F1"), ["anode": "a", "cathode": "GND", "a": "x", "b": "GND"]),
                dc("VX", 0.1, plus: "y"),
                r("RS", 1, "y", "x"),
                probe("RS_V", "y", "x"),
            ], dt: 1e-6, seconds: 3e-4, from: 2.9e-4, watch: ["RS_V"]) { _, v in current = v["RS_V"] ?? 0 }
            return (0.1 - current) / max(current, 1e-15)
        }
        XCTAssertEqual(try resistance(led: 0.016), 150, accuracy: 15)
        XCTAssertGreaterThan(try resistance(led: 1e-6), 1e6)
    }
}
