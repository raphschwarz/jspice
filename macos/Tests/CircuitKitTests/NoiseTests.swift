import XCTest
@testable import CircuitKit

/// Noise analysis: thermal and shot noise through the linearised circuit, against ngspice's .noise and textbook results
final class NoiseTests: XCTestCase {
    struct Reference: Decodable {
        let ngspice: String
        let noise: [Case]
    }

    struct Case: Decodable {
        let id: String
        let note: String
        let source: String
        let settle: Double
        let part: String
        let terminal: String
        let frequencies: [Double]
        let density: [Double]
        let parts: [Part]
    }

    struct Part: Decodable {
        let kind: String
        let name: String
        let params: [String: Double]
        let connections: [String: String]
    }

    func testNoiseMatchesNgspice() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "spice-ac-reference", withExtension: "json", subdirectory: "Fixtures"))
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        var table = ["Noise against \(reference.ngspice) (largest difference in output density):"]
        for test in reference.noise {
            let parts = try test.parts.map { part -> NetlistPart in
                NetlistPart(kind: try XCTUnwrap(ElementKind(rawValue: part.kind)), name: part.name, params: part.params,
                            connections: part.connections)
            }
            let circuit = try SchematicLayout.layout(parts)
            let source = try XCTUnwrap(circuit.elements.firstIndex { $0.name == test.source }, test.id)
            let simulator = Simulator.settled(circuit, holding: source, duration: test.settle)
            let model = try XCTUnwrap(simulator.smallSignalModel(), test.id)
            let index = try XCTUnwrap(circuit.elements.firstIndex { $0.name == test.part }, test.id)
            let terminal = try XCTUnwrap(circuit.elements[index].kind.terminalNames.firstIndex(of: test.terminal), test.id)
            let node = simulator.nodes(of: index)[terminal]
            let result = try XCTUnwrap(model.noise(plus: node, minus: 0, input: source, sources: simulator.noiseSources(),
                                                    frequencies: test.frequencies), test.id)
            var worst = 0.0
            for (k, density) in result.output.enumerated() {
                let error = 20 * log10(density / test.density[k])
                if abs(error) > abs(worst) { worst = error }
                XCTAssertEqual(error, 0, accuracy: 0.01, "\(test.id) at \(test.frequencies[k]) Hz")
            }
            table.append("  " + test.id.padding(toLength: 22, withPad: " ", startingAt: 0) + String(format: "%9.6f dB", worst))
        }
        print(table.joined(separator: "\n"))
    }

    func testResistorAndCapacitorGiveKTOverC() throws {
        // all of a resistor's noise across a capacitor, over every frequency, is √(kT/C) whatever the resistance
        let circuit = try SchematicLayout.layout([
            NetlistPart(kind: .acVoltage, name: "V1", params: ["amplitude": 1, "frequency": 1000], connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 1000], connections: ["a": "in", "b": "out"]),
            NetlistPart(kind: .capacitor, name: "C1", params: ["capacitance": 1e-9], connections: ["a": "out", "b": "GND"]),
        ])
        let source = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "V1" })
        let simulator = Simulator.settled(circuit, holding: source, duration: 1e-4)
        let model = try XCTUnwrap(simulator.smallSignalModel())
        let node = simulator.nodes(of: try XCTUnwrap(circuit.elements.firstIndex { $0.name == "C1" }))[0]
        let frequencies = FrequencySweep.logarithmic(from: 1, to: 1e10, pointsPerDecade: 200)
        let result = try XCTUnwrap(model.noise(plus: node, minus: 0, input: source, sources: simulator.noiseSources(), frequencies: frequencies))
        let kT = 1.602176634e-19 * Simulator.thermalVoltage
        XCTAssertEqual(result.total, (kT / 1e-9).squareRoot(), accuracy: 0.01 * (kT / 1e-9).squareRoot())
        XCTAssertEqual(result.contributions.first?.label, "R1")
        // in the passband the input-referred noise is the resistor's own, √(4kTR)
        XCTAssertEqual(try XCTUnwrap(result.input?.first), (4 * kT * 1000).squareRoot(), accuracy: 1e-12)
    }

    func testOpAmpInputNoise() throws {
        // a TL072 follower: its 18 nV/√Hz at the output, and the same referred to its input
        let circuit = try SchematicLayout.layout([
            NetlistPart(kind: .acVoltage, name: "VIN", params: ["amplitude": 1, "frequency": 1000], connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .opAmp, name: "U1", params: Examples.model(.opAmp, "TL072"), connections: ["plus": "in", "minus": "out", "out": "out"]),
        ])
        let source = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "VIN" })
        let simulator = Simulator.settled(circuit, holding: source, duration: 1e-3)
        let model = try XCTUnwrap(simulator.smallSignalModel())
        let node = simulator.nodes(of: try XCTUnwrap(circuit.elements.firstIndex { $0.name == "U1" }))[2]
        let result = try XCTUnwrap(model.noise(plus: node, minus: 0, input: source, sources: simulator.noiseSources(), frequencies: [100, 1000]))
        XCTAssertEqual(result.output[1], 18e-9, accuracy: 0.1e-9)
        XCTAssertEqual(try XCTUnwrap(result.input?[1]), 18e-9, accuracy: 0.1e-9)
        XCTAssertEqual(result.contributions.first?.label, "U1")
    }
}
