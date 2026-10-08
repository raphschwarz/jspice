import XCTest
@testable import CircuitKit

/// Tolerance analysis: copies of a circuit with their values drawn within tolerance
final class ToleranceTests: XCTestCase {
    private func divider() throws -> Circuit {
        try SchematicLayout.layout([
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 10], connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 1000], connections: ["a": "in", "b": "out"]),
            NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 1000], connections: ["a": "out", "b": "GND"]),
            NetlistPart(kind: .capacitor, name: "C1", params: ["capacitance": 1e-6], connections: ["a": "out", "b": "GND"]),
        ])
    }

    func testVariantsAreRepeatableAndWithinTolerance() throws {
        let circuit = try divider()
        let tolerances = Tolerances()
        XCTAssertEqual(tolerances.variant(of: circuit, seed: 7, run: 0), circuit, "run 0 is the nominal circuit")
        XCTAssertEqual(tolerances.variant(of: circuit, seed: 7, run: 3), tolerances.variant(of: circuit, seed: 7, run: 3))
        XCTAssertNotEqual(tolerances.variant(of: circuit, seed: 7, run: 3), tolerances.variant(of: circuit, seed: 7, run: 4))
        let r1 = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "R1" })
        let c1 = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "C1" })
        var resistances: [Double] = []
        var capacitances: [Double] = []
        for run in 1...2000 {
            let variant = tolerances.variant(of: circuit, seed: 1, run: run)
            resistances.append(variant.elements[r1][param: "resistance"])
            capacitances.append(variant.elements[c1][param: "capacitance"])
            // the source is not a part with a tolerance
            XCTAssertEqual(variant.elements[0][param: "voltage"], circuit.elements[0][param: "voltage"])
        }
        let r = try XCTUnwrap(Tolerances.summary(resistances))
        XCTAssertGreaterThanOrEqual(r.minimum, 950)
        XCTAssertLessThanOrEqual(r.maximum, 1050)
        // three standard deviations at the tolerance
        XCTAssertEqual(r.mean, 1000, accuracy: 1)
        XCTAssertEqual(r.standardDeviation, 1000 * 0.05 / 3, accuracy: 1)
        let c = try XCTUnwrap(Tolerances.summary(capacitances))
        XCTAssertEqual(c.standardDeviation, 1e-6 * 0.10 / 3, accuracy: 0.1e-6 * 0.1)
        // one part held to its own tolerance
        var tight = tolerances
        tight.parts[circuit.elements[r1].id] = 0.001
        let held = (1...200).map { tight.variant(of: circuit, seed: 1, run: $0).elements[r1][param: "resistance"] }
        XCTAssertLessThanOrEqual(held.map { abs($0 - 1000) }.max() ?? 1, 1.0001)
    }

    func testSummaryAndSweepValues() throws {
        let summary = try XCTUnwrap(Tolerances.summary(Array(1...101).map(Double.init)))
        XCTAssertEqual(summary.mean, 51)
        XCTAssertEqual(summary.low, 6, accuracy: 1e-9)
        XCTAssertEqual(summary.high, 96, accuracy: 1e-9)
        XCTAssertNil(Tolerances.summary([.nan]))
        XCTAssertEqual(Sweep.values(from: 1, to: 100, count: 3, logarithmic: true), [1, 10, 100])
        XCTAssertEqual(Sweep.values(from: 0, to: 10, count: 3, logarithmic: false), [0, 5, 10])
    }
}
