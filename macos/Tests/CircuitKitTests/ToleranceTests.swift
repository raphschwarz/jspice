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

/// The optimizer and standard values
final class OptimizerTests: XCTestCase {
    func testFindsTheBottomOfAValley() {
        // Rosenbrock's banana valley, scaled into the unit square: least at (0.75, 0.75)
        let result = Optimizer.minimize({ p in
            let x = p[0] * 4 - 2, y = p[1] * 4 - 2
            return (1 - x) * (1 - x) + 100 * (y - x * x) * (y - x * x)
        }, start: [0.2, 0.8], evaluations: 2000, tolerance: 1e-14)
        XCTAssertEqual(result.point[0], 0.75, accuracy: 0.01)
        XCTAssertEqual(result.point[1], 0.75, accuracy: 0.01)
        // and stays in the cube when the least is outside it
        let edge = Optimizer.minimize({ p in -p[0] }, start: [0.5], evaluations: 100)
        XCTAssertEqual(edge.point[0], 1, accuracy: 1e-6)
    }

    func testStandardValues() throws {
        let e12 = try XCTUnwrap(ESeries.around(1590, series: 12))
        XCTAssertEqual(e12.nearest, 1500, accuracy: 1e-9)
        XCTAssertEqual(e12.below, 1200, accuracy: 1e-9)
        XCTAssertEqual(e12.above, 1800, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(ESeries.around(0.000_000_159, series: 24)).nearest, 160e-9, accuracy: 1e-15)
        XCTAssertEqual(try XCTUnwrap(ESeries.around(9.9, series: 12)).nearest, 10, accuracy: 1e-9)
        XCTAssertEqual(ESeries.mantissas(96)?.count, 96)
        XCTAssertEqual(try XCTUnwrap(ESeries.around(4990, series: 96)).nearest, 4990, accuracy: 1e-9)
        XCTAssertNil(ESeries.around(100, series: 7))
    }
}
