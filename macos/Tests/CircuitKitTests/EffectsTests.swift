import XCTest
@testable import CircuitKit

/// The synth and effects parts: multiplier, bucket-brigade delay, vactrol, part models and audio taper
final class EffectsTests: XCTestCase {
    private func index(_ circuit: Circuit, _ name: String) -> Int {
        circuit.elements.firstIndex { $0.name == name }!
    }

    func testMultiplierMultiplies() throws {
        let circuit = Examples.ringModulator.circuit
        let simulator = Simulator(circuit: circuit, timeStep: 1e-5)
        let (x, y, out) = (index(circuit, "VX"), index(circuit, "VY"), index(circuit, "U1"))
        for _ in 0..<2000 {
            simulator.step()
            let expected = 11 * tanh(0.1 * simulator.voltageAcross(x) * simulator.voltageAcross(y) / 11)
            XCTAssertEqual(simulator.voltageAcross(out), expected, accuracy: 1e-6)
        }
        XCTAssertEqual(simulator.convergenceFailures, 0)
    }

    func testDelayLineDelaysByItsStagesOverTwiceTheClock() throws {
        let circuit = try SchematicLayout.layout([
            NetlistPart(kind: .acVoltage, name: "VIN", params: ["amplitude": 1, "frequency": 50], connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .delayLine, name: "U1", params: model(.delayLine, "MN3207"), connections: ["in": "in", "ctrl": "GND", "out": "out"]),
            NetlistPart(kind: .resistor, name: "RL", connections: ["a": "out", "b": "GND"]),
        ])
        let dt = 1e-5
        let simulator = Simulator(circuit: circuit, timeStep: dt)
        let (source, line) = (index(circuit, "VIN"), index(circuit, "U1"))
        let delay = 1024 / (2 * 40_000.0)
        XCTAssertEqual(delay, 0.0128)
        var history: [Double] = []
        while simulator.time < 0.1 {
            simulator.step()
            history.append(simulator.voltageAcross(source))
            if simulator.time > 0.03 {
                let past = history[history.count - 1 - Int((delay / dt).rounded())]
                XCTAssertEqual(simulator.voltageAcross(line), past, accuracy: 1e-3)
            }
        }
    }

    func testDelayLineClockFollowsItsControl() throws {
        let circuit = try SchematicLayout.layout([
            NetlistPart(kind: .squareVoltage, name: "VIN", params: ["high": 1, "low": 0, "frequency": 2, "duty": 0.5],
                        connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .dcVoltage, name: "VC", params: ["voltage": 2], connections: ["plus": "ctrl", "minus": "GND"]),
            NetlistPart(kind: .delayLine, name: "U1", params: model(.delayLine, "MN3207"), connections: ["in": "in", "ctrl": "ctrl", "out": "out"]),
            NetlistPart(kind: .resistor, name: "RL", connections: ["a": "out", "b": "GND"]),
        ])
        let simulator = Simulator(circuit: circuit, timeStep: 1e-5)
        let line = index(circuit, "U1")
        // the input rises at t = 0; with 2 V of control the clock is 60 kHz: the output rises 1024 / 120k = 8.5 ms later
        var rose: Double?
        while simulator.time < 0.02 {
            simulator.step()
            if rose == nil && simulator.voltageAcross(line) > 0.5 { rose = simulator.time }
        }
        XCTAssertEqual(rose ?? 0, 1024 / 120_000.0, accuracy: 2e-5)
    }

    func testVactrolOpensQuicklyAndClosesSlowly() throws {
        let circuit = Examples.lowpassGate.circuit
        let simulator = Simulator(circuit: circuit, timeStep: 2e-5)
        let vactrol = index(circuit, "VTL1")
        // the gate is high for the first 50 ms
        var resistanceAt: [Double: Double] = [:]
        let marks = [0.003, 0.045, 0.06, 0.12, 0.2]
        while simulator.time < 0.21 {
            simulator.step()
            for mark in marks where resistanceAt[mark] == nil && simulator.time >= mark {
                resistanceAt[mark] = 1 / simulator.vactrolConductance(vactrol)
            }
        }
        // lit by about 15 mA: near VTL5C3's 1.5 kΩ at 10 mA, a little less
        XCTAssertEqual(resistanceAt[0.045]!, 1500 * pow(0.01 / 0.015, 0.75), accuracy: 250)
        XCTAssertLessThan(resistanceAt[0.003]!, 5000, "on within a few milliseconds")
        XCTAssertLessThan(resistanceAt[0.06]!, 10_000, "still fairly low 10 ms after the gate")
        // the light falls with the 35 ms decay, and the resistance rises as a power of it
        XCTAssertGreaterThan(resistanceAt[0.12]!, 3 * resistanceAt[0.045]!, "rising as the light fades")
        XCTAssertGreaterThan(resistanceAt[0.2]!, 15_000, "much higher after 150 ms")
        XCTAssertFalse(simulator.isFailed)
    }

    func testOverdriveClipsAtTheDiodes() {
        let circuit = Examples.overdrive.circuit
        let simulator = Simulator(circuit: circuit, timeStep: 1e-5)
        let speaker = index(circuit, "SPK1")
        var peak = 0.0
        while simulator.time < 0.05 {
            simulator.step()
            if simulator.time > 0.02 { peak = max(peak, abs(simulator.voltageAcross(speaker))) }
        }
        // the op-amp swings ±6.7 V; the 1N4148s hold the output near 0.6 V
        XCTAssertEqual(peak, 0.62, accuracy: 0.12)
    }

    func testFuzzFaceBiasesAndDistorts() {
        let circuit = Examples.fuzz.circuit
        let simulator = Simulator(circuit: circuit, timeStep: 1e-5)
        let (q2, speaker) = (index(circuit, "Q2"), index(circuit, "SPK1"))
        var output: [Double] = []
        while simulator.time < 0.4 {
            simulator.step()
            if simulator.time > 0.3 { output.append(simulator.voltageAcross(speaker)) }
        }
        let mean = output.reduce(0, +) / Double(output.count)
        let centred = output.map { $0 - mean }
        let (top, bottom) = (centred.max() ?? 0, centred.min() ?? 0)
        let peak = max(top, -bottom)
        // near either of its own peaks: a sine spends 29 % of its time above 90 % of its peak, a fuzzed one much more
        let high = centred.filter { $0 > 0.9 * top || $0 < 0.9 * bottom }.count
        XCTAssertFalse(simulator.isFailed)
        let collector = simulator.terminalVoltages(q2)[1]
        XCTAssertGreaterThan(collector, 1, "Q2 conducts but is not saturated")
        XCTAssertLessThan(collector, 8.9)
        XCTAssertGreaterThan(peak, 0.05, "it is loud")
        // a sine spends a third of its time above 70 % of its peak; a fuzzed one, most of it
        XCTAssertGreaterThan(Double(high) / Double(output.count), 0.5, "squared off")
    }

    func testAudioTaperPotentiometer() throws {
        let circuit = try SchematicLayout.layout([
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 10], connections: ["plus": "top", "minus": "GND"]),
            NetlistPart(kind: .potentiometer, name: "P1", params: ["resistance": 10_000, "position": 0.5, "taper": 1],
                        connections: ["a": "GND", "b": "top", "wiper": "w"]),
            NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 1e9], connections: ["a": "w", "b": "GND"]),
        ])
        let simulator = Simulator(circuit: circuit, timeStep: 1e-4)
        simulator.step()
        // half way round an audio pot is about a tenth of the way along its track
        XCTAssertEqual(simulator.voltageAcross(index(circuit, "RL")), 10 * 9 / 99, accuracy: 0.01)
    }

    func testPartModelsSetTheirValues() {
        XCTAssertEqual(ElementKind.diode.models.first?.name, "Generic silicon")
        XCTAssertNotNil(ElementKind.diode.models.first { $0.name == "1N34A" })
        XCTAssertNotNil(ElementKind.pnp.models.first { $0.name == "AC128" })
        var element = Element(kind: .npn, a: GridPoint(0, 0), b: GridPoint(2, 0))
        for spec in ElementKind.npn.params { element[param: spec.key] = spec.defaultValue }
        XCTAssertEqual(element.model?.name, "Generic")
        XCTAssertEqual(Element(kind: .vactrol, a: GridPoint(0, 0), b: GridPoint(4, 0)).posts.count, 4)
    }

    func testEffectsExamplesRunAtAudioRate() {
        for example in [Examples.ringModulator, Examples.chorus, Examples.fuzz, Examples.overdrive, Examples.lowpassGate] {
            let simulator = Simulator(circuit: example.circuit, timeStep: 1 / 96_000)
            let speaker = example.circuit.elements.firstIndex { $0.kind == .speaker }!
            var peak = 0.0
            while simulator.time < 0.3 && !simulator.isFailed {
                simulator.step()
                peak = max(peak, abs(simulator.voltageAcross(speaker)))
            }
            XCTAssertFalse(simulator.isFailed, example.id)
            XCTAssertLessThan(simulator.convergenceFailures, 50, example.id)
            XCTAssertGreaterThan(peak, 0.05, example.id)
        }
    }

    private func model(_ kind: ElementKind, _ name: String) -> [String: Double] { Examples.model(kind, name) }
}
