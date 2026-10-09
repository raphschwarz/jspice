import XCTest
@testable import CircuitKit

/// Part stress: rated parts against their ratings over a run
final class PartStressTests: XCTestCase {
    /// 12 V across 100 Ω is 1.44 W: 576 % of a quarter-watt resistor, 72 % of a 2 W one; 12 V on a 6.3 V capacitor is
    /// 190 % of its rating, on an unrated one not checked; a diode with a 100 V breakdown reversed by 12 V is at 12 %
    func testRatedPartsAgainstTheirRatings() throws {
        let parts = [
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 12], connections: ["plus": "a", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 100], connections: ["a": "a", "b": "GND"]),
            NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 100, "ratedPower": 2], connections: ["a": "a", "b": "GND"]),
            NetlistPart(kind: .capacitor, name: "C1", params: ["capacitance": 1e-9, "ratedVoltage": 6.3], connections: ["a": "a", "b": "GND"]),
            NetlistPart(kind: .capacitor, name: "C2", params: ["capacitance": 1e-9], connections: ["a": "a", "b": "GND"]),
            NetlistPart(kind: .diode, name: "D1", params: ["bv": 100], connections: ["anode": "GND", "cathode": "a"]),
        ]
        let circuit = try SchematicLayout.layout(parts)
        // (the capacitors straight across the source would have it take the smallest steps)
        let (stress, simulator) = PartStress.run(circuit, duration: 1e-3, maxSteps: 2_000)
        XCTAssertFalse(simulator.isFailed, "\(simulator.problems)")
        let findings = Dictionary(uniqueKeysWithValues: stress.findings.map { ($0.part, $0) })
        XCTAssertEqual(try XCTUnwrap(findings["R1"]).load, 5.76, accuracy: 1e-3)
        XCTAssertEqual(try XCTUnwrap(findings["R2"]).load, 0.72, accuracy: 1e-3)
        XCTAssertEqual(try XCTUnwrap(findings["C1"]).load, 12 / 6.3, accuracy: 1e-3)
        XCTAssertNil(findings["C2"], "an unrated capacitor is not checked")
        let diode = try XCTUnwrap(findings["D1"])
        XCTAssertEqual(diode.quantity, "reverse voltage")
        XCTAssertEqual(diode.load, 0.12, accuracy: 1e-3)
        XCTAssertEqual(stress.overstressed.map(\.part), ["R1", "C1"])
        XCTAssertEqual(stress.findings.first?.part, "R1", "the most loaded first")
        // the hottest parts: the two resistors, 1.44 W each (the source delivers it)
        let hottest = stress.hottest(2)
        XCTAssertEqual(Set(hottest.map { circuit.elements[$0.index].name }), ["R1", "R2"])
        XCTAssertEqual(hottest[0].power, 1.44, accuracy: 1e-3)
    }
}
