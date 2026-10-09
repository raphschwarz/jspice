import XCTest
@testable import CircuitKit

/// The ring modulator chips and parts: a Gilbert cell's product and carrier suppression, a centre-tapped winding's
/// halves, a diode ring following its carrier, and the frequency shifter's 90° networks
final class ChipPartsTests: XCTestCase {
    private func part(_ kind: ElementKind, _ name: String, _ params: [String: Double] = [:], _ connections: [String: String]) -> NetlistPart {
        NetlistPart(kind: kind, name: name, params: params, connections: connections)
    }

    private func r(_ name: String, _ ohms: Double, _ a: String, _ b: String) -> NetlistPart {
        part(.resistor, name, ["resistance": ohms], ["a": a, "b": b])
    }

    private func dc(_ name: String, _ volts: Double, plus: String, minus: String = "GND") -> NetlistPart {
        part(.dcVoltage, name, ["voltage": volts], ["plus": plus, "minus": minus])
    }

    private func probe(_ name: String, _ plus: String, _ minus: String = "GND") -> NetlistPart {
        part(.probe, name, [:], ["plus": plus, "minus": minus])
    }

    /// Simulates `seconds` and calls `sample` with the named parts' voltages at each step from `from` on
    private func run(_ parts: [NetlistPart], dt: Double, seconds: Double, from: Double = 0, watch: [String],
                     sample: ([String: Double]) -> Void, file: StaticString = #filePath, line: UInt = #line) throws {
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
            sample(values)
        }
    }

    /// The last reading of each named part after `seconds`
    private func settle(_ parts: [NetlistPart], seconds: Double = 2e-3, watch: [String]) throws -> [String: Double] {
        var last: [String: Double] = [:]
        try run(parts, dt: 1e-5, seconds: seconds, watch: watch) { last = $0 }
        return last
    }

    func testMC1496OutputIsTheSignalTimesTheCarriersSign() throws {
        func difference(signal: Double, carrier: Double) throws -> Double {
            let v = try settle([
                dc("VP", 12, plus: "+12V"),
                dc("VS", signal, plus: "sp"),
                dc("VB", 6, plus: "cb"),
                dc("VC", carrier, plus: "cp", minus: "cb"),
                part(.balancedModulator, "U1", Examples.model(.balancedModulator, "MC1496"),
                     ["sigPlus": "sp", "sigMinus": "GND", "carPlus": "cp", "carMinus": "cb", "bias": "b5", "gain1": "g1", "gain2": "g2",
                      "outPlus": "op", "outMinus": "om"]),
                r("RE", 1000, "g1", "g2"),
                r("RB", 6800, "b5", "GND"),
                r("RL1", 3900, "+12V", "op"),
                r("RL2", 3900, "+12V", "om"),
                probe("DIFF", "op", "om"),
                probe("BIAS", "b5"),
            ], watch: ["DIFF", "BIAS"])
            // about 1 mA into pin 5: it sits 6.8 V below ground
            XCTAssertEqual(try XCTUnwrap(v["BIAS"]), -6.8, accuracy: 0.3)
            return try XCTUnwrap(v["DIFF"])
        }
        let up = try difference(signal: 0.05, carrier: 0.2)
        let down = try difference(signal: 0.05, carrier: -0.2)
        // the signal pair's difference current, 50 mV over about 1 kΩ, steered to one output or the other: 2 × 3.9 kΩ × 48 µA
        XCTAssertEqual(abs(up), 0.37, accuracy: 0.07)
        XCTAssertEqual(up, -down, accuracy: 0.02, "the carrier's sign flips the output")
        // no signal, no output, whatever the carrier: carrier suppression
        XCTAssertEqual(try difference(signal: 0, carrier: 0.2), 0, accuracy: 0.01)
    }

    func testSA612MixesItsInputWithItsOscillator() throws {
        func difference(input: Double, oscillator: Double) throws -> Double {
            let v = try settle([
                dc("VA", 1.6 + input, plus: "ia"),
                dc("VB", 1.6, plus: "ib"),
                dc("VO", 4 + oscillator, plus: "ob"),
                part(.mixerOscillator, "U1", Examples.model(.mixerOscillator, "SA612"),
                     ["inA": "ia", "inB": "ib", "oscBase": "ob", "oscEmitter": "oe", "outA": "oa", "outB": "obb"]),
                r("RE", 100_000, "oe", "GND"),
                probe("DIFF", "oa", "obb"),
                probe("OUT", "oa"),
            ], watch: ["DIFF", "OUT"])
            // the outputs sit about 0.75 V below the 6 V supply (0.5 mA each through 1.5 kΩ)
            XCTAssertEqual(try XCTUnwrap(v["OUT"]), 5.25, accuracy: 0.6)
            return try XCTUnwrap(v["DIFF"])
        }
        let up = try difference(input: 0.05, oscillator: 0.2)
        let down = try difference(input: 0.05, oscillator: -0.2)
        XCTAssertGreaterThan(abs(up), 0.1)
        XCTAssertEqual(up, -down, accuracy: 0.05 * abs(up), "the oscillator's sign flips the output")
        XCTAssertEqual(try difference(input: 0, oscillator: 0.2), 0, accuracy: 0.01)
    }

    func testCentreTappedWindingSplitsInHalves() throws {
        var top = 0.0, bottom = 0.0, whole = 0.0
        try run([
            part(.acVoltage, "VS", ["amplitude": 1, "frequency": 1000], ["plus": "a", "minus": "GND"]),
            part(.tappedTransformer, "T1", Examples.model(.tappedTransformer, "600 Ω : 600 Ω CT"),
                 ["a1": "a", "a2": "GND", "b1": "b1", "ct": "GND", "b2": "b2"]),
            r("R1", 1e6, "b1", "GND"),
            r("R2", 1e6, "b2", "GND"),
            probe("TOP", "b1"),
            probe("BOTTOM", "b2"),
            probe("WHOLE", "b1", "b2"),
        ], dt: 1e-5, seconds: 0.02, from: 0.01, watch: ["TOP", "BOTTOM", "WHOLE"]) { v in
            top = max(top, v["TOP"] ?? 0)
            bottom = max(bottom, -(v["BOTTOM"] ?? 0))
            whole = max(whole, v["WHOLE"] ?? 0)
        }
        // a 1:1 transformer with its secondary tapped in the middle: half the voltage each side, opposite in phase
        XCTAssertEqual(top, 0.5, accuracy: 0.03)
        XCTAssertEqual(bottom, 0.5, accuracy: 0.03)
        XCTAssertEqual(whole, 1, accuracy: 0.05)
    }

    func testDiodeRingFollowsItsCarriersSign() throws {
        /// The output's correlation with the signal: positive in phase, negative inverted
        func correlation(carrier: Double) throws -> (correlation: Double, peak: Double) {
            var sum = 0.0, peak = 0.0
            try run([
                part(.acVoltage, "SIG", ["amplitude": 0.2, "frequency": 1000], ["plus": "s", "minus": "GND"]),
                part(.tappedTransformer, "T1", Examples.model(.tappedTransformer, "600 Ω : 600 Ω CT"),
                     ["a1": "s", "a2": "GND", "b1": "ra", "ct": "ct1", "b2": "rc"]),
                dc("VC", carrier, plus: "c0"),
                r("R2", 100, "c0", "ct1"),
                part(.diode, "D1", Examples.model(.diode, "OA90"), ["anode": "ra", "cathode": "rb"]),
                part(.diode, "D2", Examples.model(.diode, "OA90"), ["anode": "rb", "cathode": "rc"]),
                part(.diode, "D3", Examples.model(.diode, "OA90"), ["anode": "rc", "cathode": "rd"]),
                part(.diode, "D4", Examples.model(.diode, "OA90"), ["anode": "rd", "cathode": "ra"]),
                part(.tappedTransformer, "T2", Examples.model(.tappedTransformer, "600 Ω : 600 Ω CT"),
                     ["a1": "out", "a2": "GND", "b1": "rb", "ct": "GND", "b2": "rd"]),
                r("RL", 600, "out", "GND"),
                probe("SIGNAL", "s"),
                probe("OUT", "out"),
            ], dt: 1e-5, seconds: 0.01, from: 0.005, watch: ["SIGNAL", "OUT"]) { v in
                sum += (v["SIGNAL"] ?? 0) * (v["OUT"] ?? 0)
                peak = max(peak, abs(v["OUT"] ?? 0))
            }
            return (sum, peak)
        }
        let forward = try correlation(carrier: 1)
        let reverse = try correlation(carrier: -1)
        XCTAssertGreaterThan(forward.peak, 0.02, "the signal passes while the carrier holds two diodes on")
        XCTAssertGreaterThan(reverse.peak, 0.02)
        XCTAssertLessThan(forward.correlation * reverse.correlation, 0, "the carrier's sign decides the output's phase")
    }

    func testFrequencyShifterNetworksStayNinetyDegreesApart() throws {
        let example = try XCTUnwrap(Examples.example("frequency-shifter"))
        let circuit = example.circuit
        let simulator = Simulator(circuit: circuit, timeStep: 1e-6)
        // drive the input with a steady 1 kHz sine in place of the guitar riff, and time the two chains' zero crossings
        var driven = circuit
        let guitar = try XCTUnwrap(driven.elements.firstIndex { $0.name == "GTR" })
        driven.elements[guitar].kind = .acVoltage
        driven.elements[guitar].params = ["amplitude": 0.2, "frequency": 1000]
        simulator.load(driven)
        let i = try XCTUnwrap(driven.elements.firstIndex { $0.name == "UA4" })
        let q = try XCTUnwrap(driven.elements.firstIndex { $0.name == "UB4" })
        var lastI = 0.0, lastQ = 0.0
        var crossingI: Double?, crossingQ: Double?
        while simulator.time < 0.04 {
            simulator.step()
            let vi = simulator.terminalVoltage(i, 2), vq = simulator.terminalVoltage(q, 2)
            if simulator.time > 0.03 {
                if crossingI == nil && lastI < 0 && vi >= 0 { crossingI = simulator.time }
                if crossingQ == nil && lastQ < 0 && vq >= 0 { crossingQ = simulator.time }
            }
            lastI = vi
            lastQ = vq
        }
        let ti = try XCTUnwrap(crossingI), tq = try XCTUnwrap(crossingQ)
        // a quarter of a 1 ms period between them, the second chain behind
        var lag = (tq - ti).truncatingRemainder(dividingBy: 1e-3)
        if lag < 0 { lag += 1e-3 }
        XCTAssertEqual(lag * 360 / 1e-3, 90, accuracy: 3)
    }

    // MARK: - Synth chips

    func testFunctionGeneratorsRunAtTheirDatasheetFrequencies() throws {
        // XR2206: R from pin 7 to ground, f = 1 / (R C); ICL8038: R from pins 4–5 to V+, f = 0.15 / (R C);
        // LM566: R from pin 6 to V+, f = 2 (V+ − Vc) / (R C V+)
        let cases: [(String, [NetlistPart], Double)] = [
            ("XR2206", [r("RT", 10_000, "t", "GND")], 10_000),
            ("ICL8038", [r("RT", 15_000, "+12V", "t")], 1000),
            ("LM566", [r("RT", 10_000, "+12V", "t"), dc("VC", 10.2, plus: "c")], 3000),
        ]
        for (model, timing, expected) in cases {
            var rising = 0
            var last = 0.0
            try run([
                dc("VP", 12, plus: "+12V"),
                part(.functionGenerator, "U1", Examples.model(.functionGenerator, model).merging(["capacitance": 10e-9]) { $1 },
                     ["timing": "t", "control": "c", "out": "o", "square": "sq"]),
                r("RO", 100_000, "o", "GND"),
                r("RS", 100_000, "sq", "GND"),
                probe("SQUARE", "sq"),
            ] + timing, dt: 1e-6, seconds: 5e-3, from: 1e-3, watch: ["SQUARE"]) { v in
                let now = v["SQUARE"] ?? 0
                if last < 6 && now >= 6 { rising += 1 }
                last = now
            }
            XCTAssertEqual(Double(rising) / 4e-3, expected, accuracy: 0.03 * expected, model)
        }
    }

    func testNortonAmpBiasesAtRfOverRbiasOfTheSupplyAndInverts() throws {
        var low = Double.infinity, high = -Double.infinity
        try run([
            dc("VP", 15, plus: "+15V"),
            part(.acVoltage, "VS", ["amplitude": 0.01, "frequency": 1000], ["plus": "s", "minus": "GND"]),
            part(.capacitor, "C1", ["capacitance": 10e-6], ["a": "s", "b": "ci"]),
            r("RIN", 10_000, "ci", "inv"),
            r("RBIAS", 200_000, "+15V", "noninv"),
            r("RF", 100_000, "out", "inv"),
            part(.nortonAmp, "U1", Examples.model(.nortonAmp, "LM3900"), ["minus": "inv", "plus": "noninv", "out": "out"]),
            probe("OUT", "out"),
        ], dt: 1e-5, seconds: 0.4, from: 0.39, watch: ["OUT"]) { v in
            low = min(low, v["OUT"] ?? 0)
            high = max(high, v["OUT"] ?? 0)
        }
        // the rest point: about Rf / Rbias of the supply (above it by a junction's share)
        XCTAssertEqual((high + low) / 2, 7.5, accuracy: 0.7)
        // a gain of −Rf / Rin = −10 on 10 mV
        XCTAssertEqual((high - low) / 2, 0.1, accuracy: 0.015)
    }

    func testShiftRegistersShiftLatchAndClear() {
        // inputs: SER, SRCLK, RCLK, OE, SRCLR as bits 0–4
        func step(_ state: LogicState, _ inputs: UInt32, _ chip: Int) -> LogicState {
            Logic.next(.shiftRegister, state, inputs: inputs, function: chip)
        }
        let ser: UInt32 = 1, clock: UInt32 = 2, latch: UInt32 = 4, clear: UInt32 = 16
        // 74HC595: shift in 1 then 0, then latch: Q1 high, Q0 low; Q7S the last stage
        var s = LogicState(inputs: clear)
        s = step(s, clear | ser, 1)
        s = step(s, clear | ser | clock, 1)
        s = step(s, clear, 1)
        s = step(s, clear | clock, 1)
        s = step(s, clear, 1)
        XCTAssertEqual(Logic.outputs(.shiftRegister, s, function: 1).prefix(8).filter { $0 }.count, 0, "nothing reaches Q until RCLK")
        s = step(s, clear | latch, 1)
        var q = Logic.outputs(.shiftRegister, s, function: 1)
        XCTAssertEqual(Array(q.prefix(2)), [false, true])
        // OE high turns the outputs off
        s = step(s, clear | latch | 8, 1)
        q = Logic.outputs(.shiftRegister, s, function: 1)
        XCTAssertFalse(q[1])
        // SRCLR low clears the stages
        s = step(s, latch, 1)
        XCTAssertEqual(s.shift, 0)
        // CD4015: four stages, the fifth clock pushes the first one out; RESET high clears
        var c = LogicState()
        for k in 0..<5 {
            c = step(c, (k == 0 ? ser : 0), 0)
            c = step(c, (k == 0 ? ser : 0) | clock, 0)
            c = step(c, 0, 0)
        }
        XCTAssertEqual(c.shift, 0, "the one shifted in has left the four stages")
        c = step(c, ser, 0)
        c = step(c, ser | clock, 0)
        XCTAssertTrue(Logic.outputs(.shiftRegister, c, function: 0)[0])
        c = step(c, 16, 0)
        XCTAssertEqual(c.shift, 0)
    }
}
