import XCTest
@testable import CircuitKit

/// The chips between analog and logic: the CD4069UB unbuffered inverter as an amplifier, and the CD4046 phase-locked loop
final class AnalogChipTests: XCTestCase {
    private func simulator(_ parts: [NetlistPart], timeStep: Double = 1e-5) throws -> Simulator {
        Simulator(circuit: try SchematicLayout.layout(parts), timeStep: timeStep)
    }

    private func index(_ simulator: Simulator, _ name: String) -> Int {
        simulator.circuit.elements.firstIndex { $0.name == name }!
    }

    private func inverterOutput(input: Double) throws -> Double {
        let simulator = try simulator([
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": input], connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .unbufferedInverter, name: "U1", params: Examples.model(.unbufferedInverter, "CD4069UB"),
                        connections: ["in": "in", "out": "out"]),
        ])
        for _ in 0..<3 { simulator.step() }
        XCTAssertFalse(simulator.isFailed)
        return simulator.voltageAcross(index(simulator, "U1"))
    }

    func testUnbufferedInverterTransferCurve() throws {
        // rail to rail at either end, half the supply in the middle (its transistors match), and a gain of about 25 there:
        // gm / gds = 2 (1 + λ Vds) / (λ (Vdd/2 - VT)) with λ = 0.03, VT = 1.5 V at 9 V
        XCTAssertEqual(try inverterOutput(input: 0), 9, accuracy: 0.01)
        XCTAssertEqual(try inverterOutput(input: 9), 0, accuracy: 0.01)
        XCTAssertEqual(try inverterOutput(input: 4.5), 4.5, accuracy: 0.01)
        let gain = (try inverterOutput(input: 4.45) - inverterOutput(input: 4.55)) / 0.1
        XCTAssertEqual(gain, 25, accuracy: 3)
    }

    func testUnbufferedInverterAmplifiesWithFeedback() throws {
        // 1 MΩ of feedback over 100 kΩ: an inverting gain of 10 / (1 + 11 / A), about 7 with A = 25, biased at 4.5 V
        let simulator = try simulator([
            NetlistPart(kind: .acVoltage, name: "VIN", params: ["amplitude": 0.05, "frequency": 1000], connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .capacitor, name: "C1", params: ["capacitance": 1e-6], connections: ["a": "in", "b": "a"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 100_000], connections: ["a": "a", "b": "x"]),
            NetlistPart(kind: .unbufferedInverter, name: "U1", params: Examples.model(.unbufferedInverter, "CD4069UB"),
                        connections: ["in": "x", "out": "y"]),
            NetlistPart(kind: .resistor, name: "RF", params: ["resistance": 1_000_000], connections: ["a": "y", "b": "x"]),
        ])
        let inverter = index(simulator, "U1")
        while simulator.time < 0.5 { simulator.step() }
        var (low, high) = (Double.infinity, -Double.infinity)
        while simulator.time < 0.51 {
            simulator.step()
            let v = simulator.voltageAcross(inverter)
            (low, high) = (min(low, v), max(high, v))
        }
        XCTAssertEqual((low + high) / 2, 4.5, accuracy: 0.1)
        XCTAssertEqual((high - low) / 2 / 0.05, 10 / (1 + 11 / 25.0), accuracy: 0.8)
    }

    /// Rising edges of a PLL's VCO between two times
    private func vcoRises(_ simulator: Simulator, _ pll: Int, from start: Double, to end: Double) -> Int {
        var rises = 0
        var was = simulator.logicOutputs(pll).first ?? false
        while simulator.time < end - 1e-12 {
            simulator.step()
            let high = simulator.logicOutputs(pll).first ?? false
            if high && !was && simulator.time > start { rises += 1 }
            was = high
        }
        return rises
    }

    func testPLLVCOFollowsItsControlVoltage() throws {
        // half the supply: halfway from 100 Hz to 2 kHz
        let simulator = try simulator([
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 6], connections: ["plus": "vc", "minus": "GND"]),
            NetlistPart(kind: .pll, name: "U1", params: Examples.model(.pll, "CD4046").merging(["fMin": 100, "fMax": 2000]) { $1 },
                        connections: ["signal": "GND", "comparator": "GND", "vcoIn": "vc", "inhibit": "GND", "vcoOut": "vco"]),
        ], timeStep: 2e-5)
        let rises = vcoRises(simulator, index(simulator, "U1"), from: 0.1, to: 0.3)
        XCTAssertEqual(Double(rises), 1050 * 0.2, accuracy: 2)
    }

    func testPLLLocksAnOctaveUp() throws {
        let example = try XCTUnwrap(Examples.example("pll-octave"))
        let simulator = Simulator(circuit: example.circuit, timeStep: 2e-5)
        let pll = index(simulator, "U1")
        let rises = vcoRises(simulator, pll, from: 1.5, to: 2)
        // locked: twice the 220 Hz input
        XCTAssertEqual(Double(rises), 440 * 0.5, accuracy: 2)
        XCTAssertEqual(simulator.voltageAcross(index(simulator, "VC")), 12 * (440 - 100) / 1900.0, accuracy: 0.3)
        XCTAssertFalse(simulator.isFailed)
    }

    func testCMOSFuzzClips() throws {
        let example = try XCTUnwrap(Examples.example("cmos-fuzz"))
        let simulator = Simulator(circuit: example.circuit, timeStep: 1e-5)
        let output = index(simulator, "U2")
        while simulator.time < 0.2 { simulator.step() }
        var (low, high) = (Double.infinity, -Double.infinity)
        while simulator.time < 0.25 {
            simulator.step()
            let v = simulator.voltageAcross(output)
            (low, high) = (min(low, v), max(high, v))
        }
        // a 0.2 V input driven most of the way to the rails, around half the supply
        XCTAssertGreaterThan(high - low, 6)
        XCTAssertEqual((low + high) / 2, 4.5, accuracy: 1)
        XCTAssertFalse(simulator.isFailed)
    }
}
