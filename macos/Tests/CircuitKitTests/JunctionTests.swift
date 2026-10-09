import XCTest
@testable import CircuitKit

/// Junction capacitances, stored charge and temperature
final class JunctionTests: XCTestCase {
    /// A diode with 1 mA through it from a source through a resistor; its forward voltage at `celsius`
    private func forwardVoltage(at celsius: Double) throws -> Double {
        var circuit = try SchematicLayout.layout([
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 10.655], connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 10_000], connections: ["a": "in", "b": "a"]),
            NetlistPart(kind: .diode, name: "D1", connections: ["anode": "a", "cathode": "GND"]),
        ])
        circuit.settings.temperature = celsius
        let simulator = Simulator(circuit: circuit, timeStep: 1e-4)
        for _ in 0..<10 { simulator.step() }
        return simulator.voltageAcross(try XCTUnwrap(circuit.elements.firstIndex { $0.name == "D1" }))
    }

    func testJunctionsDropLessWhenHot() throws {
        let nominal = try forwardVoltage(at: 27)
        // Is = 1e-14 A at 1 mA: kT/q ln(1e11)
        XCTAssertEqual(nominal, Simulator.thermalVoltage * log(1e-3 / 1e-14), accuracy: 2e-3)
        let hot = try forwardVoltage(at: 77)
        let cold = try forwardVoltage(at: -23)
        // about 1.8 mV less per degree hotter, as silicon does
        XCTAssertEqual((hot - nominal) / 50, -1.8e-3, accuracy: 0.3e-3)
        XCTAssertEqual((nominal - cold) / 50, -1.8e-3, accuracy: 0.4e-3)
    }

    func testReverseBiasedJunctionIsACapacitor() throws {
        // 10 kΩ into a diode held 3 V in reverse (100 pF at 0 V: 50 pF at 3 V with a junction potential of 1 V and
        // grading 0.5): a low-pass at 1 / (2π · 10 kΩ · 50 pF), 318 kHz
        let circuit = try SchematicLayout.layout([
            NetlistPart(kind: .acVoltage, name: "V1", params: ["amplitude": 0.01, "offset": -3, "frequency": 1000],
                        connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 10_000], connections: ["a": "in", "b": "k"]),
            NetlistPart(kind: .diode, name: "D1", params: ["cj0": 100e-12], connections: ["anode": "k", "cathode": "GND"]),
        ])
        let source = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "V1" })
        let simulator = Simulator.settled(circuit, holding: source, duration: 1e-3)
        let model = try XCTUnwrap(simulator.smallSignalModel())
        let node = simulator.nodes(of: try XCTUnwrap(circuit.elements.firstIndex { $0.name == "D1" }))[0]
        let corner = 1 / (2 * Double.pi * 10_000 * 50e-12)
        let response = try XCTUnwrap(model.solve(input: source, frequencies: [corner / 100, corner, corner * 10]))
        XCTAssertEqual(response[0][node].magnitude, 1, accuracy: 1e-3)
        XCTAssertEqual(20 * log10(response[1][node].magnitude), -3.01, accuracy: 0.05)
        XCTAssertEqual(response[2][node].magnitude, 1 / sqrt(101), accuracy: 0.005)
    }

    /// The diode's current just after a square wave turns it from forward to reverse
    private func reverseRecovery(transitTime: Double) throws -> Double {
        let circuit = try SchematicLayout.layout([
            NetlistPart(kind: .squareVoltage, name: "V1", params: ["high": 5, "low": -5, "frequency": 10_000, "duty": 0.5],
                        connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 1000], connections: ["a": "in", "b": "a"]),
            NetlistPart(kind: .diode, name: "D1", params: ["tt": transitTime, "cj0": 0], connections: ["anode": "a", "cathode": "GND"]),
        ])
        let simulator = Simulator(circuit: circuit, timeStep: 1e-7)
        let diode = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "D1" })
        // the falling edge is at 50 µs; a microsecond after it
        while simulator.time < 51e-6 - 1e-12 { simulator.step() }
        return simulator.current(diode)
    }

    func testStoredChargeLetsCurrentBack() throws {
        // 4.3 mA forward stores 5 µs × 4.3 mA; reversed, the diode conducts backwards (about −5.7 mA) until it is gone
        XCTAssertLessThan(try reverseRecovery(transitTime: 5e-6), -4e-3)
        // without stored charge it blocks at once
        XCTAssertEqual(try reverseRecovery(transitTime: 0), 0, accuracy: 1e-5)
    }

    func testRealPartsCarryTheirCapacitances() {
        let bc108 = ElementKind.npn.models.first { $0.name == "BC108" }!
        XCTAssertGreaterThan(bc108.values["cjc"] ?? 0, 1e-12)
        let rectifier = ElementKind.diode.models.first { $0.name == "1N4001" }!
        XCTAssertEqual(rectifier.values["tt"] ?? 0, 5.7e-6, accuracy: 1e-9)
        // the depletion charge's slope is its capacitance, on both sides of half the junction potential
        for v in [-5.0, -0.5, 0.2, 0.49, 0.51, 0.8] {
            let d = 1e-7
            let c = Simulator.depletion(v, cj: 1e-12, vj: 1, m: 0.5)
            let slope = (Simulator.depletion(v + d, cj: 1e-12, vj: 1, m: 0.5).charge - Simulator.depletion(v - d, cj: 1e-12, vj: 1, m: 0.5).charge) / (2 * d)
            XCTAssertEqual(c.capacitance, slope, accuracy: 1e-6 * c.capacitance, "at \(v) V")
        }
    }
}
