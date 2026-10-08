import XCTest
@testable import CircuitKit

/// Small-signal (AC) analysis: against ngspice's operating point and .ac sweep of the same circuits with the same device
/// equations (tools/spice-reference/crosscheck.py --ac), and, for the parts ngspice has no equivalent of (the synth
/// chips, delay lines, OTAs), against JSpice's own transient simulation driven with a small sine.
final class SmallSignalTests: XCTestCase {
    struct Reference: Decodable {
        let ngspice: String
        let cases: [Case]
    }

    struct Case: Decodable {
        let id: String
        let note: String
        let source: String
        let settle: Double
        let frequencies: [Double]
        let probes: [Probe]
        let example: String?
        let parts: [Part]?
    }

    struct Probe: Decodable {
        let net: String
        let part: String
        let terminal: String
        let gainDB: [Double]
        let phaseDegrees: [Double]

        enum CodingKeys: String, CodingKey {
            case net, part, terminal
            case gainDB = "gain_db"
            case phaseDegrees = "phase_deg"
        }
    }

    struct Part: Decodable {
        let kind: String
        let name: String
        let params: [String: Double]
        let connections: [String: String]
    }

    private func circuit(_ test: Case) throws -> Circuit {
        if let id = test.example { return try XCTUnwrap(Examples.all.first { $0.id == id }).circuit }
        let parts = try (test.parts ?? []).map { part -> NetlistPart in
            NetlistPart(kind: try XCTUnwrap(ElementKind(rawValue: part.kind)), name: part.name, params: part.params,
                        connections: part.connections)
        }
        return try SchematicLayout.layout(parts)
    }

    /// The angle between two phases in degrees, from −180 to 180
    private static func angle(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    func testSmallSignalAnalysisMatchesNgspice() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "spice-ac-reference", withExtension: "json", subdirectory: "Fixtures"))
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        var table = ["Small-signal analysis against \(reference.ngspice) (largest differences within 60 dB of each peak):"]
        for test in reference.cases {
            let circuit = try circuit(test)
            let source = try XCTUnwrap(circuit.elements.firstIndex { $0.name == test.source }, test.id)
            let simulator = Simulator.settled(circuit, holding: source, duration: test.settle)
            XCTAssertFalse(simulator.isFailed, test.id)
            let model = try XCTUnwrap(simulator.smallSignalModel(), test.id)
            let solution = try XCTUnwrap(model.solve(input: source, frequencies: test.frequencies), test.id)
            for probe in test.probes {
                let index = try XCTUnwrap(circuit.elements.firstIndex { $0.name == probe.part }, "\(test.id) \(probe.part)")
                let terminal = try XCTUnwrap(circuit.elements[index].kind.terminalNames.firstIndex(of: probe.terminal))
                let node = simulator.nodes(of: index)[terminal]
                let peak = probe.gainDB.max() ?? 0
                var worstGain = 0.0, worstPhase = 0.0
                for (k, voltages) in solution.enumerated() where probe.gainDB[k] > peak - 60 {
                    let value = voltages[node]
                    let gain = 20 * log10(max(value.magnitude, 1e-30))
                    let phase = value.phase * 180 / .pi
                    let gainError = gain - probe.gainDB[k]
                    let phaseError = Self.angle(phase, probe.phaseDegrees[k])
                    if abs(gainError) > abs(worstGain) { worstGain = gainError }
                    if abs(phaseError) > abs(worstPhase) { worstPhase = phaseError }
                    XCTAssertEqual(gain, probe.gainDB[k], accuracy: 0.001,
                                   "\(test.id) \(probe.net) gain at \(test.frequencies[k]) Hz")
                    XCTAssertEqual(phaseError, 0, accuracy: 0.01, "\(test.id) \(probe.net) phase at \(test.frequencies[k]) Hz")
                }
                table.append("  " + test.id.padding(toLength: 16, withPad: " ", startingAt: 0)
                             + probe.net.padding(toLength: 6, withPad: " ", startingAt: 0)
                             + String(format: "%9.6f dB %9.6f°", worstGain, worstPhase))
            }
        }
        print(table.joined(separator: "\n"))
    }

    /// The response the transient simulation gives: the source driven with a sine of `amplitude` at `frequency`, the
    /// circuit given `settle` seconds and then whole cycles, and the fundamental of V(plus) − V(minus) over that of
    /// the source
    private func measured(_ circuit: Circuit, source: Int, plus: Int, minus: Int = 0, frequency: Double, amplitude: Double,
                          settle: Double, file: StaticString = #filePath, line: UInt = #line) -> Complex {
        var test = circuit
        test.elements[source][param: "amplitude"] = amplitude
        test.elements[source][param: "frequency"] = frequency
        let perCycle = 512
        let timeStep = 1 / (frequency * Double(perCycle))
        let simulator = Simulator(circuit: test, timeStep: timeStep)
        let settleSteps = Int((settle * frequency).rounded(.up)) * perCycle + 8 * perCycle
        let measureSteps = 8 * perCycle
        var input = Complex(0), output = Complex(0)
        for step in 1...(settleSteps + measureSteps) {
            simulator.step()
            guard step > settleSteps else { continue }
            let angle = 2 * Double.pi * frequency * simulator.time
            let rotation = Complex(cos(angle), -sin(angle))
            input = input + simulator.voltageAcross(source) * rotation
            output = output + (simulator.nodeVoltage(plus) - simulator.nodeVoltage(minus)) * rotation
        }
        XCTAssertFalse(simulator.isFailed, file: file, line: line)
        return output / input
    }

    /// Compares the small-signal response with the transient one at each frequency: within `tolerance` of it, as a
    /// fraction of its size (3 % is about 0.25 dB and 1.7°)
    private func compare(_ parts: [NetlistPart], source name: String, output: (part: String, terminal: String),
                         frequencies: [Double], amplitude: Double, settle: Double, tolerance: Double = 0.03,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        let circuit = try SchematicLayout.layout(parts)
        let source = try XCTUnwrap(circuit.elements.firstIndex { $0.name == name })
        let part = try XCTUnwrap(circuit.elements.firstIndex { $0.name == output.part })
        let terminal = try XCTUnwrap(circuit.elements[part].kind.terminalNames.firstIndex(of: output.terminal))
        let simulator = Simulator.settled(circuit, holding: source, duration: settle)
        let node = simulator.nodes(of: part)[terminal]
        let model = try XCTUnwrap(simulator.smallSignalModel())
        let response = try XCTUnwrap(model.response(input: source, plus: node, minus: 0, frequencies: frequencies))
        for (frequency, value) in zip(frequencies, response) {
            let reference = measured(circuit, source: source, plus: node, frequency: frequency, amplitude: amplitude,
                                     settle: settle, file: file, line: line)
            let error = (value - reference).magnitude / max(reference.magnitude, 1e-12)
            print(String(format: "  %@ at %.0f Hz: AC %.4f ∠%.1f°, transient %.4f ∠%.1f°", output.part as NSString, frequency,
                         value.magnitude, value.phase * 180 / .pi, reference.magnitude, reference.phase * 180 / .pi))
            XCTAssertLessThan(error, tolerance, "\(output.part) at \(frequency) Hz", file: file, line: line)
        }
    }

    private func ac(_ name: String, _ net: String, offset: Double = 0) -> NetlistPart {
        NetlistPart(kind: .acVoltage, name: name, params: ["amplitude": 0, "offset": offset, "frequency": 100],
                    connections: ["plus": net, "minus": "GND"])
    }

    private func dc(_ name: String, _ net: String, _ volts: Double) -> NetlistPart {
        NetlistPart(kind: .dcVoltage, name: name, params: ["voltage": volts], connections: ["plus": net, "minus": "GND"])
    }

    private func load(_ net: String) -> NetlistPart {
        NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 10_000], connections: ["a": net, "b": "GND"])
    }

    func testFilterChipPassesSmallSignalsAsInTime() throws {
        try compare([
            ac("VIN", "in"), dc("VCV", "cv", 0.5),
            NetlistPart(kind: .vcf, name: "U1", params: ElementKind.vcf.models[0].values.merging(["cutoff": 700, "resonance": 0.3]) { $1 },
                        connections: ["in": "in", "cv": "cv", "out": "out"]),
            load("out"),
        ], source: "VIN", output: ("U1", "out"), frequencies: [200, 1000, 3000], amplitude: 0.01, settle: 0.05, tolerance: 0.05)
    }

    func testVCAPassesSmallSignalsAsInTime() throws {
        // the audio input, and the control input around a steady 1 V of audio
        let vca = NetlistPart(kind: .vca, name: "U1", params: [:], connections: ["in": "in", "cv": "cv", "out": "out"])
        try compare([ac("VIN", "in"), dc("VCV", "cv", -0.3), vca, load("out")],
                    source: "VIN", output: ("U1", "out"), frequencies: [100, 1000], amplitude: 0.01, settle: 0.01)
        try compare([dc("VIN", "in", 1), ac("VCV", "cv", offset: -0.3), vca, load("out")],
                    source: "VCV", output: ("U1", "out"), frequencies: [100, 1000], amplitude: 0.001, settle: 0.01)
    }

    func testDelayLinesPassSmallSignalsAsInTime() throws {
        try compare([
            ac("VIN", "in"), dc("VC", "ctrl", 0),
            NetlistPart(kind: .delayLine, name: "U1", params: [:], connections: ["in": "in", "ctrl": "ctrl", "out": "out"]),
            load("out"),
        ], source: "VIN", output: ("U1", "out"), frequencies: [100, 330, 1000], amplitude: 0.01, settle: 0.05)
        try compare([
            ac("VIN", "in"),
            NetlistPart(kind: .resistor, name: "RT", params: ["resistance": 4700], connections: ["a": "time", "b": "GND"]),
            NetlistPart(kind: .digitalDelay, name: "U1", params: ["noise": 0], connections: ["in": "in", "time": "time", "out": "out"]),
            load("out"),
        ], source: "VIN", output: ("U1", "out"), frequencies: [100, 500, 1500], amplitude: 0.01, settle: 0.2)
    }

    func testOTAFilterPassesSmallSignalsAsInTime() throws {
        // the LM13700 state-variable filter of the "vcf" example, around its resonance
        let input = NetlistPart(kind: .acVoltage, name: "VIN", params: ["amplitude": 0, "frequency": 100],
                                connections: ["plus": "in", "minus": "GND"])
        try compare(Examples.filterParts(input: input), source: "VIN", output: ("U4", "out"),
                    frequencies: [100, 500, 1000, 2000, 5000], amplitude: 0.01, settle: 0.02)
    }

    func testRCLowPassCornerIsThreeDecibelsDown() throws {
        let circuit = try SchematicLayout.layout([
            ac("V1", "in"),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 1000], connections: ["a": "in", "b": "out"]),
            NetlistPart(kind: .capacitor, name: "C1", params: ["capacitance": 1e-6], connections: ["a": "out", "b": "GND"]),
        ])
        let source = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "V1" })
        let capacitor = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "C1" })
        let simulator = Simulator.settled(circuit, holding: source)
        let model = try XCTUnwrap(simulator.smallSignalModel())
        let corner = 1 / (2 * Double.pi * 1000 * 1e-6)
        let (plus, minus) = try XCTUnwrap(simulator.acrossNodes(capacitor))
        let value = try XCTUnwrap(model.response(input: source, plus: plus, minus: minus, frequencies: [corner])?.first)
        XCTAssertEqual(20 * log10(value.magnitude), -3.0103, accuracy: 1e-3)
        XCTAssertEqual(value.phase * 180 / .pi, -45, accuracy: 1e-3)
        XCTAssertFalse(model.canDrive(from: capacitor))
    }
}
