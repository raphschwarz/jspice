@testable import CircuitKit
import XCTest

/// What the parts an STM32 writes over its buses hold (a CV DAC's codes, a PCA9685's registers, a TLC5947's levels, an
/// EEPROM's memory) is kept as the rest of a part's state is: through an edit of the circuit (the chip keeps running, so
/// a firmware that set its part up once in `setup()` would otherwise run on against a part that has forgotten it), into
/// the other simulator the sound runs, and back to where it was when a substep is thrown away; a part removed and put
/// back starts afresh, and `reset` clears it.
final class BusPartStateTests: XCTestCase {
    /// A circuit with its bus part named U2, and what to measure of it (run on for a while): what it should be
    struct Rig {
        var circuit: Circuit
        var timeStep: Double
        var expected: Double
        var accuracy: Double
        var observe: (Simulator, Circuit) -> Double
        /// For a part no firmware fixture here writes: what to put in it, as its bus would
        var setUp: ((Simulator, Int) -> Void)?
    }

    func stm32(_ firmware: [UInt8], _ connections: [String: String]) -> NetlistPart {
        var chip = NetlistPart(kind: .stm32f405, name: "U1", connections: connections)
        chip.firmware = Data(firmware)
        return chip
    }

    func index(_ circuit: Circuit, _ name: String) -> Int {
        circuit.elements.firstIndex { $0.name == name } ?? -1
    }

    func run(_ simulator: Simulator, for seconds: Double) {
        let end = simulator.time + seconds
        while simulator.time < end && !simulator.isFailed { simulator.step() }
    }

    /// A DAC7554 (format 4) given the word 0x3800 (write and update all four channels at mid-scale). No firmware here
    /// sends a CV DAC its words (the ones that do, Tides 2 and Braids, are built by CI), and the bus's own path is
    /// tested in STM32Tests: the word is handed to the part as its SPI frame would.
    func cvDacRig() throws -> Rig {
        let circuit = try SchematicLayout.layout([
            NetlistPart(kind: .cvDac, name: "U2", params: ["fullScale": 2.5, "format": 4], connections: ["outA": "out"]),
            NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 10_000], connections: ["a": "out", "b": "GND"]),
            NetlistPart(kind: .probe, name: "OUT", connections: ["plus": "out", "minus": "GND"]),
        ])
        var rig = Rig(circuit: circuit, timeStep: 1.0 / 48000, expected: 1.25, accuracy: 0.02) { simulator, circuit in
            self.run(simulator, for: 1e-3)
            return simulator.voltageAcross(self.index(circuit, "OUT"))
        }
        rig.setUp = { simulator, part in
            var state = simulator.busPartState(part)
            Logic.cvDacWord(0x3800, format: 4, codes: &state.cvDacCodes)
            simulator.setBusPartState(part, state)
        }
        return rig
    }

    /// A PCA9685 set up once: LED0 at half duty
    func ledDriverRig() throws -> Rig {
        var connections = ["scl": "scl", "sda": "sda", "oe": "GND", "led0": "led"]
        for k in 0...5 { connections["a\(k)"] = "GND" }
        let circuit = try SchematicLayout.layout([
            stm32(STM32Tests.pwmFirmware, ["pb10": "scl", "pb11": "sda"]),
            NetlistPart(kind: .ledDriver, name: "U2", params: ["supply": 3.3], connections: connections),
            NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 10_000], connections: ["a": "led", "b": "GND"]),
            NetlistPart(kind: .probe, name: "LED", connections: ["plus": "led", "minus": "GND"]),
        ])
        return Rig(circuit: circuit, timeStep: 1.0 / 96000, expected: 0.5, accuracy: 0.05) { simulator, circuit in
            let led = self.index(circuit, "LED")
            var (high, samples) = (0, 0)
            let end = simulator.time + 0.02
            while simulator.time < end && !simulator.isFailed {
                simulator.step()
                if simulator.voltageAcross(led) > 1.65 { high += 1 }
                samples += 1
            }
            return Double(high) / Double(max(samples, 1))
        }
    }

    /// A TLC5947 sent its 288 bits once: OUT1 sinks its full current all the time
    func ledSinkRig() throws -> Rig {
        let circuit = try SchematicLayout.layout([
            stm32(STM32Tests.ledSinkFirmware, ["pa4": "xlat", "pa5": "sclk", "pa7": "sin"]),
            NetlistPart(kind: .ledSink, name: "U2", params: ["supply": 3.3, "iref": 3300],
                        connections: ["sin": "sin", "sclk": "sclk", "xlat": "xlat", "blank": "GND", "out1": "k1"]),
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 5], connections: ["plus": "vled", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 100], connections: ["a": "vled", "b": "a1"]),
            NetlistPart(kind: .led, name: "D1", connections: ["anode": "a1", "cathode": "k1"]),
            NetlistPart(kind: .probe, name: "I1", connections: ["plus": "vled", "minus": "a1"]),
        ])
        let full = 41 * 1.2 / 3300
        return Rig(circuit: circuit, timeStep: 1.0 / 96000, expected: 1, accuracy: 0.02) { simulator, circuit in
            let probe = self.index(circuit, "I1")
            var (on, samples) = (0, 0)
            let end = simulator.time + 0.005
            while simulator.time < end && !simulator.isFailed {
                simulator.step()
                if simulator.voltageAcross(probe) / 100 > full / 2 { on += 1 }
                samples += 1
            }
            return Double(on) / Double(max(samples, 1))
        }
    }

    /// A 24LC256 written once: 0x11 at 0x003E
    func eepromRig() throws -> Rig {
        let circuit = try SchematicLayout.layout([
            stm32(STM32Tests.eepromFirmware, ["pb10": "scl", "pb11": "sda"]),
            NetlistPart(kind: .i2cEeprom, name: "U2", params: ["supply": 3.3],
                        connections: ["scl": "scl", "sda": "sda", "wp": "GND", "a0": "GND", "a1": "GND", "a2": "GND"]),
        ])
        return Rig(circuit: circuit, timeStep: 1.0 / 48000, expected: 0x11, accuracy: 0) { simulator, circuit in
            self.run(simulator, for: 1e-3)
            return Double(simulator.eepromContents(self.index(circuit, "U2"))?[0x3E] ?? 0xFF)
        }
    }

    /// The firmware sets the part up; then an edit, the sound's simulator, a removal and an undo, a reset
    func check(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        let simulator = Simulator(circuit: rig.circuit, timeStep: rig.timeStep)
        let part = index(rig.circuit, "U2")
        let fresh = Simulator(circuit: rig.circuit, timeStep: rig.timeStep).busPartState(part)
        run(simulator, for: 0.01)
        rig.setUp?(simulator, part)
        XCTAssertFalse(simulator.isFailed, simulator.problems.joined(separator: " "), file: file, line: line)
        XCTAssertEqual(rig.observe(simulator, rig.circuit), rig.expected, accuracy: rig.accuracy, "set up", file: file, line: line)
        let before = simulator.busPartState(part)
        XCTAssertNotEqual(before, fresh, "the firmware has written to the part", file: file, line: line)

        // a resistor added out of the way: the chip keeps running, and so does what it set up
        var edited = rig.circuit
        edited.add(Element(kind: .resistor, a: GridPoint(400, 400), b: GridPoint(404, 400)))
        simulator.load(edited)
        XCTAssertEqual(simulator.busPartState(part), before, "kept through an edit", file: file, line: line)
        XCTAssertEqual(rig.observe(simulator, edited), rig.expected, accuracy: rig.accuracy, "after an edit", file: file, line: line)

        // the sound's simulator takes the window's state, and goes on from it
        let other = Simulator(circuit: edited, timeStep: rig.timeStep)
        other.adoptState(of: simulator)
        XCTAssertEqual(other.busPartState(part), simulator.busPartState(part), "adopted", file: file, line: line)
        XCTAssertEqual(rig.observe(other, edited), rig.expected, accuracy: rig.accuracy, "adopted", file: file, line: line)
        // (and again, now that both hold it: copied in place)
        simulator.adoptState(of: other)
        XCTAssertEqual(simulator.busPartState(part), other.busPartState(part), "adopted back", file: file, line: line)

        // removed, then put back (an undo: the same element): a part fresh from the box
        let element = edited.elements[part]
        var without = edited
        without.remove([element.id])
        simulator.load(without)
        var back = without
        back.elements.append(element)
        simulator.load(back)
        XCTAssertEqual(simulator.busPartState(back.elements.count - 1), fresh, "put back afresh", file: file, line: line)

        // reset: every part at rest
        other.reset()
        XCTAssertEqual(other.busPartState(part), fresh, "reset", file: file, line: line)
    }

    func testACVDACKeepsItsCodes() throws { check(try cvDacRig()) }
    func testAPCA9685KeepsItsRegisters() throws { check(try ledDriverRig()) }
    func testATLC5947KeepsItsLevels() throws { check(try ledSinkRig()) }
    func testAnEEPROMKeepsItsMemory() throws { check(try eepromRig()) }

    /// A TLC5947 clocked by the circuit, not a chip: SIN held high, SCLK a 1 kHz square whose edges, through an RC,
    /// make the error control throw substeps away. Each rising edge shifts one bit in, kept or not: as many ones in
    /// its register as without error control (where no substep is thrown away), one for each edge.
    func testATLC5947ClockedInARejectedSubstepShiftsOnce() throws {
        func ones(errorControl: Bool) throws -> (ones: Int, rejected: Int) {
            let circuit = try SchematicLayout.layout([
                NetlistPart(kind: .squareVoltage, name: "V1", params: ["high": 3.3, "low": 0, "frequency": 1000],
                            connections: ["plus": "sclk", "minus": "GND"]),
                NetlistPart(kind: .dcVoltage, name: "V2", params: ["voltage": 3.3], connections: ["plus": "high", "minus": "GND"]),
                NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 1000], connections: ["a": "sclk", "b": "rc"]),
                NetlistPart(kind: .capacitor, name: "C1", params: ["capacitance": 1e-7], connections: ["a": "rc", "b": "GND"]),
                NetlistPart(kind: .ledSink, name: "U2", params: ["supply": 3.3],
                            connections: ["sin": "high", "sclk": "sclk", "xlat": "GND", "blank": "GND"]),
            ])
            let simulator = Simulator(circuit: circuit, timeStep: 1e-5)
            simulator.errorControl = errorControl
            run(simulator, for: 0.0405)
            XCTAssertFalse(simulator.isFailed, simulator.problems.joined(separator: " "))
            let levels = simulator.busPartState(index(circuit, "U2")).sinkLevels
            XCTAssertEqual(levels.count, 48)
            return (levels.prefix(24).reduce(0) { $0 + $1.nonzeroBitCount }, simulator.rejectedSubsteps)
        }
        let controlled = try ones(errorControl: true)
        let plain = try ones(errorControl: false)
        XCTAssertGreaterThan(controlled.rejected, 0, "substeps were thrown away")
        XCTAssertEqual(Double(plain.ones), 41, accuracy: 1, "one bit for each rising edge, at 0, 1 ms ... 40 ms")
        XCTAssertEqual(controlled.ones, plain.ones)
    }
}
