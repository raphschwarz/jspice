import XCTest
@testable import CircuitKit

/// The CMOS logic parts: gates, the CD4013 flip-flop, the CD4017 and CD4040 counters and the CD4051 and CD4053
/// multiplexers, each against its datasheet's function table, and the examples built from them
final class LogicTests: XCTestCase {
    private func simulator(_ parts: [NetlistPart], timeStep: Double = 1e-5) throws -> Simulator {
        Simulator(circuit: try SchematicLayout.layout(parts), timeStep: timeStep)
    }

    private func index(_ simulator: Simulator, _ name: String) -> Int {
        simulator.circuit.elements.firstIndex { $0.name == name }!
    }

    private func dc(_ name: String, _ voltage: Double, _ net: String) -> NetlistPart {
        NetlistPart(kind: .dcVoltage, name: name, params: ["voltage": voltage], connections: ["plus": net, "minus": "GND"])
    }

    private func clock(_ frequency: Double) -> NetlistPart {
        NetlistPart(kind: .squareVoltage, name: "CLK", params: ["high": 12, "low": 0, "frequency": frequency],
                    connections: ["plus": "clk", "minus": "GND"])
    }

    private func run(_ simulator: Simulator, until time: Double) {
        while simulator.time < time - 1e-12 { simulator.step() }
    }

    /// Sets a DC source's voltage while the simulation runs
    private func set(_ simulator: Simulator, _ name: String, _ voltage: Double) {
        var circuit = simulator.circuit
        circuit.elements[index(simulator, name)][param: "voltage"] = voltage
        XCTAssertTrue(simulator.updateParameters(circuit))
    }

    func testGatesFollowTheirTruthTables() throws {
        // outputs for inputs 00, 01, 10, 11
        let tables: [String: [Bool]] = [
            "NAND": [true, true, true, false], "NOR": [true, false, false, false], "AND": [false, false, false, true],
            "OR": [false, true, true, true], "XOR": [false, true, true, false], "XNOR": [true, false, false, true],
        ]
        for (function, name) in Logic.gateFunctions.enumerated() {
            for (row, expected) in try XCTUnwrap(tables[name]).enumerated() {
                let simulator = try simulator([
                    dc("VA", row & 2 != 0 ? 12 : 0, "a"), dc("VB", row & 1 != 0 ? 12 : 0, "b"),
                    NetlistPart(kind: .logicGate, name: "U1",
                                params: Examples.model(.logicGate, "CD4011").merging(["function": Double(function)]) { $1 },
                                connections: ["in1": "a", "in2": "b", "out": "y"]),
                    NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 100_000], connections: ["a": "y", "b": "GND"]),
                ])
                for _ in 0..<3 { simulator.step() }
                // 400 Ω of output resistance into the 100 kΩ load
                XCTAssertEqual(simulator.voltageAcross(index(simulator, "U1")), expected ? 12 * 100_000 / 100_400 : 0, accuracy: 1e-3,
                               "\(name) row \(row)")
                XCTAssertEqual(simulator.isHigh(index(simulator, "U1")), expected, "\(name) row \(row)")
            }
        }
    }

    func testSchmittNANDOscillatesAtItsRCFrequency() throws {
        // charging from VT- to VT+ and back through 100 kΩ (and the 400 Ω output) into 10 nF
        let parts = Examples.gatedOscillator(1, resistance: 100_000, capacitance: 10e-9, enable: "VCC", cap: "cap", out: "out")
            + [dc("V1", 12, "VCC")]
        let simulator = try simulator(parts, timeStep: 1e-6)
        let gate = index(simulator, "U1")
        var rises: [Double] = []
        var was = simulator.isHigh(gate)
        while simulator.time < 0.02 {
            simulator.step()
            let high = simulator.isHigh(gate)
            if high && !was { rises.append(simulator.time) }
            was = high
        }
        let periods = zip(rises.dropFirst(), rises).map { $0 - $1 }
        XCTAssertGreaterThan(periods.count, 10)
        let mean = periods.reduce(0, +) / Double(periods.count)
        let expected = 100_400 * 10e-9 * log((1 - 0.39) / (1 - 0.59) * 0.59 / 0.39)
        XCTAssertEqual(mean, expected, accuracy: expected * 0.01)
    }

    func testDecadeCounterCountsInhibitsResetsAndCarries() throws {
        let simulator = try simulator([
            clock(1000), dc("VINH", 0, "inh"), dc("VRST", 0, "rst"),
            NetlistPart(kind: .decadeCounter, name: "U1", params: Examples.model(.decadeCounter, "CD4017"),
                        connections: ["clock": "clk", "inhibit": "inh", "reset": "rst"]),
        ])
        let counter = index(simulator, "U1")
        func outputs() -> [Bool] { simulator.terminalVoltages(counter)[3...].map { $0 > 6 } }
        // rising edges at 0, 1, …, 5 ms
        run(simulator, until: 5.5e-3)
        XCTAssertEqual(simulator.logicCount(counter), 6)
        XCTAssertEqual(outputs(), (0...9).map { $0 == 6 } + [false])
        // inhibited, it holds its count
        set(simulator, "VINH", 12)
        run(simulator, until: 8.5e-3)
        XCTAssertEqual(simulator.logicCount(counter), 6)
        // and counts on again, eleven edges later round past 9
        set(simulator, "VINH", 0)
        run(simulator, until: 19.5e-3)
        XCTAssertEqual(simulator.logicCount(counter), 7)
        XCTAssertEqual(outputs(), (0...9).map { $0 == 7 } + [false])
        // reset holds it at 0, carry out high
        set(simulator, "VRST", 12)
        run(simulator, until: 22.5e-3)
        XCTAssertEqual(simulator.logicCount(counter), 0)
        XCTAssertEqual(outputs(), (0...9).map { $0 == 0 } + [true])
    }

    func testBinaryCounterCountsFallingEdges() throws {
        let simulator = try simulator([
            clock(1000), dc("VRST", 0, "rst"),
            NetlistPart(kind: .binaryCounter, name: "U1", params: Examples.model(.binaryCounter, "CD4040"),
                        connections: ["clock": "clk", "reset": "rst"]),
        ])
        let counter = index(simulator, "U1")
        // falling edges at 0.5, 1.5, …, 9.5 ms: ten of them
        run(simulator, until: 10.2e-3)
        XCTAssertEqual(simulator.logicCount(counter), 10)
        XCTAssertEqual(simulator.terminalVoltages(counter)[2...].map { $0 > 6 }, (0..<12).map { 10 & (1 << $0) != 0 })
        set(simulator, "VRST", 12)
        run(simulator, until: 11e-3)
        XCTAssertEqual(simulator.logicCount(counter), 0)
    }

    func testFlipFlopTogglesAndObeysSetAndReset() throws {
        let simulator = try simulator([
            clock(1000), dc("VS", 0, "s"), dc("VR", 0, "r"),
            NetlistPart(kind: .flipFlop, name: "U1", params: Examples.model(.flipFlop, "CD4013"),
                        connections: ["clock": "clk", "d": "qbar", "qbar": "qbar", "q": "q", "set": "s", "reset": "r"]),
        ])
        let flipFlop = index(simulator, "U1")
        // Q̄ into D: Q changes on every rising edge, at half the clock's frequency
        var rises = 0
        var was = false
        while simulator.time < 20e-3 - 1e-12 {
            simulator.step()
            let q = simulator.logicOutputs(flipFlop)[0]
            if q && !was { rises += 1 }
            was = q
        }
        XCTAssertEqual(rises, 10)
        // set and reset act whatever the clock does; both together make Q and Q̄ high
        set(simulator, "VS", 12)
        run(simulator, until: 23.3e-3)
        XCTAssertEqual(simulator.logicOutputs(flipFlop), [true, false])
        set(simulator, "VS", 0)
        set(simulator, "VR", 12)
        run(simulator, until: 26.3e-3)
        XCTAssertEqual(simulator.logicOutputs(flipFlop), [false, true])
        set(simulator, "VS", 12)
        run(simulator, until: 26.6e-3)
        XCTAssertEqual(simulator.logicOutputs(flipFlop), [true, true])
    }

    func testMultiplexerConnectsTheSelectedChannel() throws {
        for channel in 0...8 {
            var parts = [
                dc("VA", channel & 1 != 0 ? 12 : 0, "sa"), dc("VB", channel & 2 != 0 ? 12 : 0, "sb"), dc("VC", channel & 4 != 0 ? 12 : 0, "sc"),
                dc("VINH", channel == 8 ? 12 : 0, "inh"),
                NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 10_000], connections: ["a": "x", "b": "GND"]),
            ]
            var connections = ["a": "sa", "b": "sb", "c": "sc", "inhibit": "inh", "x": "x"]
            for k in 0...7 {
                parts.append(dc("V\(k)", Double(k + 1), "x\(k)"))
                connections["x\(k)"] = "x\(k)"
            }
            parts.append(NetlistPart(kind: .analogMux, name: "U1", params: Examples.model(.analogMux, "CD4051"), connections: connections))
            parts.append(NetlistPart(kind: .probe, name: "PX", connections: ["plus": "x", "minus": "GND"]))
            let simulator = try simulator(parts)
            for _ in 0..<3 { simulator.step() }
            // channel 8 stands for inhibited: nothing connected, the load pulls X to 0 V
            let expected = channel == 8 ? 0 : Double(channel + 1) * 10_000 / 10_125
            XCTAssertEqual(simulator.voltageAcross(index(simulator, "PX")), expected, accuracy: 1e-4, "channel \(channel)")
            XCTAssertEqual(simulator.logicCount(index(simulator, "U1")), channel == 8 ? -1 : channel)
        }
    }

    func testSelectorSwitchesBetweenItsTwoChannels() throws {
        for select in [false, true] {
            let simulator = try simulator([
                dc("V0", 2, "x0"), dc("V1", 5, "x1"), dc("VS", select ? 12 : 0, "sel"),
                NetlistPart(kind: .analogSelector, name: "U1", params: Examples.model(.analogSelector, "CD4053"),
                            connections: ["x0": "x0", "x1": "x1", "select": "sel", "inhibit": "GND", "x": "x"]),
                NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 10_000], connections: ["a": "x", "b": "GND"]),
                NetlistPart(kind: .probe, name: "PX", connections: ["plus": "x", "minus": "GND"]),
            ])
            for _ in 0..<3 { simulator.step() }
            XCTAssertEqual(simulator.voltageAcross(index(simulator, "PX")), (select ? 5 : 2) * 10_000 / 10_125, accuracy: 1e-4)
        }
    }

    /// The CV's levels in turn, each held for at least `minimum` steps
    private func plateaus(_ simulator: Simulator, probe: String, until time: Double, minimum: Int = 20) -> [Double] {
        let p = index(simulator, probe)
        var result: [Double] = []
        var current = simulator.voltageAcross(p)
        var held = 0
        while simulator.time < time {
            simulator.step()
            let v = simulator.voltageAcross(p)
            if abs(v - current) > 0.01 {
                current = v
                held = 0
            } else {
                held += 1
                if held == minimum { result.append(current) }
            }
        }
        return result
    }

    func testSequencerPlaysItsEightKnobsInTurn() throws {
        let example = try XCTUnwrap(Examples.example("cmos-sequencer"))
        let simulator = Simulator(circuit: example.circuit, timeStep: 1e-4)
        let levels = plateaus(simulator, probe: "CV", until: 3)
        let expected = Examples.sequencerSteps.map { 2 * $0 }
        // from the first step (the count starts at 0, on the first knob)
        XCTAssertGreaterThanOrEqual(levels.count, 9, "\(levels)")
        for (k, level) in levels.prefix(9).enumerated() {
            XCTAssertEqual(level, expected[k % 8], accuracy: 0.005, "step \(k): \(levels)")
        }
        XCTAssertFalse(simulator.isFailed)
    }

    func testBabyTenRepeatsEveryFourSteps() throws {
        let example = try XCTUnwrap(Examples.example("baby10"))
        let simulator = Simulator(circuit: example.circuit, timeStep: 1e-4)
        let levels = plateaus(simulator, probe: "CV", until: 3)
        XCTAssertGreaterThanOrEqual(levels.count, 9, "\(levels)")
        // four different levels, then the same again
        XCTAssertEqual(Set(levels.prefix(4).map { ($0 * 100).rounded() }).count, 4, "\(levels)")
        for k in 4..<levels.count {
            XCTAssertEqual(levels[k], levels[k - 4], accuracy: 0.01, "\(levels)")
        }
    }

    func testDroneDividesItsFirstOscillatorByTwo() throws {
        let example = try XCTUnwrap(Examples.example("cmos-drone"))
        let simulator = Simulator(circuit: example.circuit, timeStep: 1e-5)
        let oscillator = index(simulator, "U1")
        let flipFlop = index(simulator, "U4")
        let speaker = index(simulator, "SPK1")
        var (oscillatorRises, subRises) = (0, 0)
        var (oscillatorWas, subWas) = (false, false)
        var peak = 0.0
        while simulator.time < 0.2 {
            simulator.step()
            let high = simulator.isHigh(oscillator)
            let sub = simulator.logicOutputs(flipFlop)[0]
            if high && !oscillatorWas { oscillatorRises += 1 }
            if sub && !subWas { subRises += 1 }
            (oscillatorWas, subWas) = (high, sub)
            if simulator.time > 0.05 { peak = max(peak, abs(simulator.voltageAcross(speaker))) }
        }
        XCTAssertGreaterThan(oscillatorRises, 50)
        XCTAssertEqual(Double(subRises), Double(oscillatorRises) / 2, accuracy: 1)
        XCTAssertGreaterThan(peak, 0.5)
        XCTAssertFalse(simulator.isFailed)
    }
}
