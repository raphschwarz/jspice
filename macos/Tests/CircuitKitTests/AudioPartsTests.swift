import XCTest
@testable import CircuitKit

/// The audio parts against their datasheets: preamp gain, a line receiver's rejection, the LM386's bias and gain, the
/// NE570's expansion, RMS detection, bar-graph thresholds, a loudspeaker's resonance, a reverb tank's delay
final class AudioPartsTests: XCTestCase {
    private func part(_ kind: ElementKind, _ name: String, _ params: [String: Double] = [:], _ connections: [String: String]) -> NetlistPart {
        NetlistPart(kind: kind, name: name, params: params, connections: connections)
    }

    private func r(_ name: String, _ ohms: Double, _ a: String, _ b: String) -> NetlistPart {
        part(.resistor, name, ["resistance": ohms], ["a": a, "b": b])
    }

    private func probe(_ name: String, _ net: String) -> NetlistPart {
        part(.probe, name, [:], ["plus": net, "minus": "GND"])
    }

    /// The smallest and largest voltage each named part reads between `from` and `seconds`
    private func run(_ parts: [NetlistPart], dt: Double, seconds: Double, from: Double = 0, watch: [String],
                     file: StaticString = #filePath, line: UInt = #line) throws -> [String: (min: Double, max: Double)] {
        let circuit = try SchematicLayout.layout(parts)
        let simulator = Simulator(circuit: circuit, timeStep: dt)
        let indices = try watch.map { name in try XCTUnwrap(circuit.elements.firstIndex { $0.name == name }, name, file: file, line: line) }
        var result = [String: (min: Double, max: Double)]()
        while simulator.time < seconds {
            simulator.step()
            XCTAssertFalse(simulator.isFailed, simulator.problems.joined(separator: " "), file: file, line: line)
            if simulator.isFailed { break }
            guard simulator.time >= from else { continue }
            for (name, index) in zip(watch, indices) {
                let v = simulator.voltageAcross(index)
                let old = result[name] ?? (v, v)
                result[name] = (min(old.min, v), max(old.max, v))
            }
        }
        return result
    }

    func testInstrumentationAmpGainIsOnePlusTwiceRfOverRG() throws {
        for (model, rg, gain) in [("SSM2019", 100.0, 101.0), ("THAT1510", 50.0, 101.0), ("INA217", 1000.0, 11.0)] {
            let v = try run([
                part(.acVoltage, "VS", ["amplitude": 0.01, "frequency": 1000], ["plus": "src", "minus": "GND"]),
                part(.instrumentationAmp, "U1", Examples.model(.instrumentationAmp, model),
                     ["minus": "GND", "plus": "src", "rg1": "g1", "rg2": "g2", "ref": "GND", "out": "out"]),
                r("RG", rg, "g1", "g2"),
                probe("OUT", "out"),
            ], dt: 2e-6, seconds: 4e-3, from: 2e-3, watch: ["OUT"])
            XCTAssertEqual(try XCTUnwrap(v["OUT"]).max, 0.01 * gain, accuracy: 0.03 * 0.01 * gain, model)
        }
    }

    func testLineReceiverPassesTheDifferenceAndRejectsWhatBothInputsShare() throws {
        let v = try run([
            part(.acVoltage, "VS", ["amplitude": 1, "frequency": 1000], ["plus": "src", "minus": "GND"]),
            part(.acVoltage, "VH", ["amplitude": 2, "frequency": 50], ["plus": "hum", "minus": "GND"]),
            part(.lineReceiver, "U1", [:], ["minus": "hum", "plus": "both", "ref": "GND", "out": "out"]),
            // + gets the signal on top of the hum, − the hum alone
            part(.acVoltage, "VD", ["amplitude": 1, "frequency": 1000], ["plus": "both", "minus": "hum"]),
            part(.lineReceiver, "U2", [:], ["minus": "hum", "plus": "hum", "ref": "GND", "out": "cm"]),
            probe("OUT", "out"),
            probe("CM", "cm"),
        ], dt: 5e-6, seconds: 0.04, from: 0.02, watch: ["OUT", "CM"])
        let out = try XCTUnwrap(v["OUT"]), cm = try XCTUnwrap(v["CM"])
        XCTAssertEqual(out.max, 1, accuracy: 0.02)
        XCTAssertEqual(out.min, -1, accuracy: 0.02)
        XCTAssertLessThan(max(abs(cm.max), abs(cm.min)), 1e-3, "common mode")
    }

    func testLineDriverDrivesItsOutputsInOppositeDirections() throws {
        let v = try run([
            part(.acVoltage, "VS", ["amplitude": 1, "frequency": 1000], ["plus": "src", "minus": "GND"]),
            part(.lineDriver, "U1", [:], ["in": "src", "outPlus": "p", "outMinus": "m"]),
            r("RP", 10_000, "p", "GND"),
            r("RM", 10_000, "m", "GND"),
            probe("P", "p"),
            part(.probe, "DIFF", [:], ["plus": "p", "minus": "m"]),
        ], dt: 5e-6, seconds: 3e-3, from: 1e-3, watch: ["P", "DIFF"])
        XCTAssertEqual(try XCTUnwrap(v["P"]).max, 1, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(v["DIFF"]).max, 2, accuracy: 0.04, "6 dB balanced")
    }

    func testLM386SitsAtHalfTheSupplyWithAGainOf20Or200() throws {
        func amp(gainCap: Bool) throws -> (min: Double, max: Double) {
            var parts = [
                part(.acVoltage, "VS", ["amplitude": 0.01, "frequency": 1000], ["plus": "in", "minus": "GND"]),
                part(.audioPowerAmp, "U1", [:], ["minus": "GND", "plus": "in", "gain1": "g1", "gain8": "g8", "bypass": "byp", "out": "out"]),
                r("RL", 10_000, "out", "GND"),
                probe("OUT", "out"),
            ]
            if gainCap { parts.append(part(.capacitor, "CG", ["capacitance": 10e-6], ["a": "g1", "b": "g8"])) }
            return try XCTUnwrap(try run(parts, dt: 2e-6, seconds: 6e-3, from: 4e-3, watch: ["OUT"])["OUT"])
        }
        let twenty = try amp(gainCap: false)
        XCTAssertEqual((twenty.max + twenty.min) / 2, 4.5, accuracy: 0.1, "biased at half of 9 V")
        XCTAssertEqual((twenty.max - twenty.min) / 2, 0.2, accuracy: 0.02)
        let twoHundred = try amp(gainCap: true)
        XCTAssertEqual((twoHundred.max - twoHundred.min) / 2, 2, accuracy: 0.3)
    }

    func testNE570ExpandsTwoToOne() throws {
        func level(_ amplitude: Double) throws -> Double {
            let v = try run([
                part(.acVoltage, "VS", ["amplitude": amplitude, "frequency": 1000], ["plus": "in", "minus": "GND"]),
                part(.compander, "U1", [:], ["rectIn": "in", "gainIn": "in", "rectCap": "rc", "invIn": "inv", "r3": "out", "out": "out"]),
                part(.capacitor, "C1", ["capacitance": 1e-6], ["a": "rc", "b": "GND"]),
                probe("OUT", "out"),
            ], dt: 5e-6, seconds: 0.06, from: 0.05, watch: ["OUT"])
            return try XCTUnwrap(v["OUT"]).max
        }
        // a 0 dBu sine (0.775 V rms) comes out at unity; 10 dB less comes out 20 dB less
        let full = try level(0.775 * 2.0.squareRoot())
        XCTAssertEqual(full, 0.775 * 2.0.squareRoot(), accuracy: 0.08)
        let quiet = try level(0.775 * 2.0.squareRoot() / pow(10, 0.5))
        XCTAssertEqual(20 * log10(full / quiet), 20, accuracy: 1.5)
    }

    func testRMSDetectorReadsSixPointOneMillivoltsPerDecibel() throws {
        for (rms, expected) in [(0.775, 0.0), (7.75, 0.122), (0.0775, -0.122)] {
            let v = try run([
                part(.acVoltage, "VS", ["amplitude": rms * 2.0.squareRoot(), "frequency": 1000], ["plus": "in", "minus": "GND"]),
                part(.levelDetector, "U1", [:], ["in": "in", "ref": "GND", "out": "det"]),
                probe("DET", "det"),
            ], dt: 1e-5, seconds: 0.4, from: 0.35, watch: ["DET"])
            let det = try XCTUnwrap(v["DET"])
            XCTAssertEqual((det.max + det.min) / 2, expected, accuracy: 0.004, "\(rms) V rms")
        }
    }

    func testBarGraphLightsTheLEDsBelowTheSignal() throws {
        var parts = [
            part(.dcVoltage, "V1", ["voltage": 12], ["plus": "+12V", "minus": "GND"]),
            part(.dcVoltage, "VH", ["voltage": 10], ["plus": "hi", "minus": "GND"]),
            part(.dcVoltage, "VS", ["voltage": 4.5], ["plus": "sig", "minus": "GND"]),
            part(.barGraphDriver, "U1", Examples.model(.barGraphDriver, "LM3914"),
                 ["sig": "sig", "rlo": "GND", "rhi": "hi", "refOut": "ro", "refAdj": "GND"]
                    .merging(Dictionary(uniqueKeysWithValues: (1...10).map { ("led\($0)", "l\($0)") })) { $1 }),
        ]
        for k in 1...10 { parts.append(part(.led, "LED\(k)", [:], ["anode": "+12V", "cathode": "l\(k)"])) }
        let circuit = try SchematicLayout.layout(parts)
        let simulator = Simulator(circuit: circuit, timeStep: 1e-5)
        for _ in 0..<200 { simulator.step() }
        XCTAssertFalse(simulator.isFailed, simulator.problems.joined(separator: " "))
        for k in 1...10 {
            let index = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "LED\(k)" })
            let current = simulator.current(index)
            if k <= 4 {
                XCTAssertEqual(current, 0.01, accuracy: 0.002, "LED\(k) lit: 4.5 V is above its \(k) V")
            } else {
                XCTAssertLessThan(current, 1e-4, "LED\(k) dark")
            }
        }
    }

    func testLoudspeakerImpedancePeaksAtItsResonance() throws {
        let circuit = try SchematicLayout.layout([
            part(.acVoltage, "VS", ["amplitude": 1, "frequency": 100], ["plus": "in", "minus": "GND"]),
            r("R1", 1000, "in", "s"),
            part(.speaker, "SPK1", Examples.model(.speaker, "Full-range 4\" 8 Ω"), ["plus": "s", "minus": "GND"]),
        ])
        let source = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "VS" })
        let speaker = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "SPK1" })
        let simulator = Simulator.settled(circuit, holding: source)
        let model = try XCTUnwrap(simulator.smallSignalModel())
        let (plus, minus) = try XCTUnwrap(simulator.acrossNodes(speaker))
        // through 1 kΩ the voltage across the speaker follows its impedance: Re + Re Qms / Qes = 38.4 Ω at 90 Hz
        let values = try XCTUnwrap(model.response(input: source, plus: plus, minus: minus, frequencies: [90, 400]))
        let atResonance = values[0].magnitude * 1000 / (1 - values[0].magnitude)
        XCTAssertEqual(atResonance, 38.4, accuracy: 1.5)
        XCTAssertGreaterThan(values[0].magnitude, 3 * values[1].magnitude)
    }

    func testElectretAndCondenserMicsSitWhereTheirBiasPutsThem() throws {
        let v = try run([
            part(.dcVoltage, "V1", ["voltage": 9], ["plus": "+9V", "minus": "GND"]),
            r("R1", 2200, "+9V", "d"),
            part(.electretMic, "MIC1", ["level": 1e-6], ["out": "d", "gnd": "GND"]),
            part(.dcVoltage, "P48", ["voltage": 48], ["plus": "+48V", "minus": "GND"]),
            part(.microphone, "MIC2", Examples.model(.microphone, "Large-diaphragm condenser").merging(["level": 1e-6]) { $1 },
                 ["gnd": "GND", "hot": "h", "cold": "k"]),
            r("R2", 6810, "+48V", "h"),
            r("R3", 6810, "+48V", "k"),
            probe("D", "d"),
            probe("H", "h"),
        ], dt: 1e-5, seconds: 2e-3, from: 1e-3, watch: ["D", "H"])
        // the JFET at IDSS (0.3 mA) through 2.2 kΩ; 48 V through 6.81 kΩ into the mic's 15 kΩ and the 100 Ω behind it
        XCTAssertEqual(try XCTUnwrap(v["D"]).max, 9 - 0.3e-3 * 2200, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(v["H"]).max, 48 * 15_100 / (15_100 + 6810), accuracy: 0.3)
    }

    func testSpringReverbAnswersAfterItsSpringsDelay() throws {
        let circuit = try SchematicLayout.layout([
            part(.squareVoltage, "VS", ["high": 1, "low": 0, "frequency": 1, "duty": 0.005], ["plus": "in", "minus": "GND"]),
            part(.springReverb, "RT1", [:], ["in": "in", "gnd": "GND", "out": "out"]),
            probe("OUT", "out"),
        ])
        let simulator = Simulator(circuit: circuit, timeStep: 2e-5)
        let out = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "OUT" })
        var early = 0.0, late = 0.0
        while simulator.time < 0.2 {
            simulator.step()
            let v = abs(simulator.voltageAcross(out))
            if simulator.time < 0.025 { early = max(early, v) } else { late = max(late, v) }
        }
        XCTAssertFalse(simulator.isFailed)
        XCTAssertLessThan(early, 1e-9, "nothing before the shortest spring's 29 ms")
        XCTAssertGreaterThan(late, 1e-4)
    }

    func testVUMeterReadsZeroAtItsReferenceLevel() throws {
        let circuit = try SchematicLayout.layout([
            part(.acVoltage, "VS", ["amplitude": 1.228 * 2.0.squareRoot(), "frequency": 100], ["plus": "in", "minus": "GND"]),
            part(.vuMeter, "VU1", [:], ["plus": "in", "minus": "GND"]),
        ])
        let simulator = Simulator(circuit: circuit, timeStep: 5e-5)
        let meter = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "VU1" })
        while simulator.time < 0.8 { simulator.step() }
        XCTAssertEqual(simulator.meterReading(meter), 0, accuracy: 0.3)
    }

    func testToneControlIsFlatAtTheMiddleAndBoostsAtTheTop() throws {
        func output(bass: Double) throws -> Double {
            let v = try run([
                part(.acVoltage, "VS", ["amplitude": 0.1, "frequency": 60], ["plus": "in", "minus": "GND"]),
                part(.toneControl, "U1", [:], ["in": "in", "volume": "vol", "bass": "bas", "treble": "tre", "ref": "ref", "out": "out"]),
                part(.dcVoltage, "VV", ["voltage": 5.4], ["plus": "vol", "minus": "GND"]),
                part(.dcVoltage, "VB", ["voltage": bass], ["plus": "bas", "minus": "GND"]),
                part(.dcVoltage, "VT", ["voltage": 2.7], ["plus": "tre", "minus": "GND"]),
                probe("OUT", "out"),
            ], dt: 2e-5, seconds: 0.1, from: 0.05, watch: ["OUT"])
            return try XCTUnwrap(v["OUT"]).max
        }
        XCTAssertEqual(try output(bass: 2.7), 0.1, accuracy: 0.01)
        XCTAssertGreaterThan(try output(bass: 5.4), 0.3, "about +12 dB at 60 Hz with the bass up")
    }

    func testSingleSupplyOpAmpSwingsAboutItsMidpoint() throws {
        let v = try run([
            part(.acVoltage, "VS", ["amplitude": 1, "frequency": 1000], ["plus": "in", "minus": "GND"]),
            part(.opAmp, "U1", ["gain": 1e5, "limit": 4, "midpoint": 4.5, "gbw": 0], ["plus": "in", "minus": "GND", "out": "out"]),
            probe("OUT", "out"),
        ], dt: 5e-6, seconds: 3e-3, from: 1e-3, watch: ["OUT"])
        let out = try XCTUnwrap(v["OUT"])
        XCTAssertEqual(out.max, 8.5, accuracy: 0.05)
        XCTAssertEqual(out.min, 0.5, accuracy: 0.05)
    }

    func testChipsArePackagedWithTheirDatasheetPins() throws {
        let preamp = try XCTUnwrap(Breadboard.package(part(.instrumentationAmp, "U1", Examples.model(.instrumentationAmp, "SSM2019"), [:])))
        XCTAssertEqual(preamp.units[0], ["rg1": 1, "minus": 2, "plus": 3, "ref": 5, "out": 6, "rg2": 8])
        let lm386 = try XCTUnwrap(Breadboard.package(part(.audioPowerAmp, "U2", [:], [:])))
        XCTAssertEqual(lm386.units[0], ["gain1": 1, "minus": 2, "plus": 3, "out": 5, "bypass": 7, "gain8": 8])
        XCTAssertEqual(lm386.supplies.map(\.pin), [4, 6])
        let meter = try XCTUnwrap(Breadboard.package(part(.barGraphDriver, "U3", [:], [:])))
        XCTAssertEqual(meter.units[0]["led1"], 1)
        XCTAssertEqual(meter.units[0]["led2"], 18)
        XCTAssertEqual(meter.units[0]["led10"], 10)
        XCTAssertEqual(meter.units[0]["sig"], 5)
        // and every audio chip's box has the kind's terminals
        for kind in ElementKind.allCases {
            guard let package = kind.audioChipPackage else { continue }
            XCTAssertEqual(package.terminalNames, kind.terminalNames, "\(kind)")
            XCTAssertEqual(package.pinPlaces.count, package.terminalNames.count, "\(kind)")
        }
    }
}
