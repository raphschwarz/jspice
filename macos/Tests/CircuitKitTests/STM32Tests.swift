@testable import CircuitKit
import CortexM4
import XCTest

/// The STM32F405 as a microcontroller part runs it: tools/arm-reference/stm32test/stm32test.c, a firmware written
/// register by register that sets up the PLL, SysTick, GPIO, USART1, I2C2, I2S2 with DMA both ways, ADC1 and flash
/// programming, and reports on its serial port
final class STM32Tests: XCTestCase {
    func firmware() throws -> [UInt8] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "stm32-test", withExtension: "bin", subdirectory: "Fixtures"))
        return [UInt8](try Data(contentsOf: url))
    }

    /// Runs the chip for `seconds` of its time, a step's cycles at a time as the simulator does
    func run(_ chip: STM32Microcontroller, for seconds: Double) {
        var left = seconds
        while left > 0 {
            let step = min(left, 1e-3)
            chip.run(cycles: max(Int(step * chip.clock), 1))
            left -= step
        }
    }

    func testTheTestFirmwareRuns() throws {
        let chip = STM32Microcontroller(firmware: try firmware())
        XCTAssertEqual(chip.pinCount, 49)
        XCTAssertEqual(STM32Microcontroller.pinNames(STM32_F405).first, "pa0")
        XCTAssertEqual(STM32Microcontroller.pinNames(STM32_F405)[45], "pc13")
        XCTAssertEqual(STM32Microcontroller.pinNames(STM32_F405).last, "pd2")
        XCTAssertEqual(STM32Microcontroller.pinNames(STM32_F373).count, 53)
        XCTAssertEqual(STM32Microcontroller.pinNames(STM32_F373).suffix(5), ["pd8", "pe8", "pe9", "pf6", "pf7"])

        // PA0 at half the reference, PC13 high
        var volts = [Double](repeating: 0, count: chip.pinCount)
        volts[0] = 1.65
        volts[45] = 3.3
        chip.pinVoltages = volts
        chip.watchedPins = [5, 6]

        // a codec on I2S2 and I2C2: what it is sent kept, a 440 Hz sine into its left input
        var sent: [(left: Int32, right: Int32)] = []
        var frame = 0
        chip.frameExchange = { port, left, right in
            XCTAssertEqual(port, 2)
            sent.append((left, right))
            frame += 1
            let sine = Int32(16000 * sin(2 * Double.pi * 440 * Double(frame) / 48000)) << 16
            return (sine, 0)
        }
        var written: [UInt8] = []
        var addressed: [UInt8] = []
        chip.i2cTarget = STM32Microcontroller.I2CTarget(start: { _, address, _ in addressed.append(address); return address == 0x1A },
                                                        write: { _, byte in written.append(byte); return true },
                                                        read: { _, _ in 0xFF }, stop: { _ in })

        run(chip, for: 0.25)
        XCTAssertEqual(chip.clock, 168e6, "the firmware has started the PLL")
        chip.serialInput = Array("hello\n".utf8)
        var events = chip.takePinEvents()
        run(chip, for: 0.1)
        events += chip.takePinEvents()

        let text = String(decoding: chip.serialOutput, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("boot\ni2c ack\nflash 12345678\n"), text)
        XCTAssertTrue(text.contains("adc 2048\n"), text)
        // TIM2's compare interrupt once a millisecond
        XCTAssertTrue((97...101).contains { text.contains("cc \($0)\n") }, text)
        XCTAssertTrue(text.contains("HELLO\n"), text)
        XCTAssertEqual(addressed, [0x1A])
        XCTAssertEqual(written, [6 << 1, 0])

        // PA5 toggled every millisecond (from SysTick), PA6 following PC13 (high)
        let toggles = events.filter { $0.pin == 5 }
        XCTAssertGreaterThan(toggles.count, 50)
        XCTAssertEqual(chip.pinStates[6], .output(high: true))
        chip.setPinVoltage(45, 0)
        run(chip, for: 0.01)
        XCTAssertEqual(chip.pinStates[6], .output(high: false))

        // I2S at 48 kHz: left a 1 kHz square of +-8192, right the left input halved
        XCTAssertEqual(Double(sent.count) / 0.36, 47_990, accuracy: 1500)
        let settled = sent.suffix(2000)
        XCTAssertEqual(Set(settled.map { $0.left >> 16 }), [-8192, 8192])
        let right = settled.map { $0.right >> 16 }
        XCTAssertEqual(Double(right.max() ?? 0), 8000, accuracy: 100)
        XCTAssertEqual(Double(right.min() ?? 0), -8000, accuracy: 100)
    }

    /// The chip in a circuit with a WM8731 on its I²S2 and I²C2 pins: the codec's line outputs carry what the firmware
    /// sends (a 1 kHz square on the left, the left input halved on the right), about half its supply
    func testTheChipPlaysThroughACodecInACircuit() throws {
        var chip = NetlistPart(kind: .stm32f405, name: "U1",
                               connections: ["pb12": "ws", "pb13": "bclk", "pb15": "dacdat", "pb14": "adcdat", "pc6": "mclk",
                                             "pb10": "scl", "pb11": "sda", "pa0": "knob"])
        chip.firmware = Data(try firmware())
        let circuit = try SchematicLayout.layout([
            chip,
            NetlistPart(kind: .codec, name: "U2",
                        connections: ["mclk": "mclk", "bclk": "bclk", "dacdat": "dacdat", "daclrc": "ws", "adcdat": "adcdat",
                                      "adclrc": "ws", "sclk": "scl", "sdin": "sda", "lout": "left", "rout": "right",
                                      "linl": "in", "linr": "vmid"]),
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 1.65], connections: ["plus": "vmid", "minus": "GND"]),
            NetlistPart(kind: .dcVoltage, name: "V2", params: ["voltage": 1.65], connections: ["plus": "knob", "minus": "GND"]),
            NetlistPart(kind: .acVoltage, name: "VIN", params: ["amplitude": 0.5, "frequency": 440, "offset": 1.65],
                        connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 10_000], connections: ["a": "left", "b": "GND"]),
            NetlistPart(kind: .resistor, name: "RR", params: ["resistance": 10_000], connections: ["a": "right", "b": "GND"]),
            NetlistPart(kind: .probe, name: "LEFT", connections: ["plus": "left", "minus": "GND"]),
            NetlistPart(kind: .probe, name: "RIGHT", connections: ["plus": "right", "minus": "GND"]),
        ])
        let simulator = Simulator(circuit: circuit, timeStep: 1.0 / 48000)
        let left = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "LEFT" })
        let right = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "RIGHT" })
        var lefts: [Double] = [], rights: [Double] = []
        while simulator.time < 0.3 {
            simulator.step()
            XCTAssertFalse(simulator.isFailed, simulator.problems.joined(separator: " "))
            if simulator.isFailed { break }
            if simulator.time > 0.2 {
                lefts.append(simulator.voltageAcross(left))
                rights.append(simulator.voltageAcross(right))
            }
        }
        // full scale is 1 V RMS: 8192 of 32768 is 0.354 V of peak, through 100 Ω into 10 kΩ
        let swing = 0.25 * 2.squareRoot() * 10_000 / 10_100
        XCTAssertEqual(lefts.max() ?? 0, 1.65 * 10_000 / 10_100 + swing, accuracy: 0.01)
        XCTAssertEqual(lefts.min() ?? 0, 1.65 * 10_000 / 10_100 - swing, accuracy: 0.01)
        // the square's period: 48 frames
        let crossings = zip(lefts, lefts.dropFirst()).filter { $0 < 1.6 && $1 >= 1.6 }.count
        XCTAssertEqual(Double(crossings), 100, accuracy: 3)
        // the input's 0.5 V peak is half the ADC's full scale at 0.354 of it; halved, and back out: 0.25 V
        XCTAssertEqual((rights.max() ?? 0) - 1.65 * 10_000 / 10_100, 0.25 * 10_000 / 10_100, accuracy: 0.01)
    }

    /// A PCM5102 on the chip's I²S2 pins takes its frames too: the left output's square at 2.1 V RMS full scale
    func testThePCM5102TakesTheChipsFrames() throws {
        var chip = NetlistPart(kind: .stm32f405, name: "U1", connections: ["pb12": "ws", "pb13": "bck", "pb15": "din"])
        chip.firmware = Data(try firmware())
        let circuit = try SchematicLayout.layout([
            chip,
            NetlistPart(kind: .i2sDac, name: "U2", connections: ["bck": "bck", "din": "din", "lrck": "ws", "outL": "left", "outR": "right"]),
            NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 10_000], connections: ["a": "left", "b": "GND"]),
            NetlistPart(kind: .probe, name: "LEFT", connections: ["plus": "left", "minus": "GND"]),
        ])
        let simulator = Simulator(circuit: circuit, timeStep: 1.0 / 48000)
        let left = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "LEFT" })
        var lefts: [Double] = []
        while simulator.time < 0.2 {
            simulator.step()
            XCTAssertFalse(simulator.isFailed, simulator.problems.joined(separator: " "))
            if simulator.isFailed { break }
            if simulator.time > 0.1 { lefts.append(simulator.voltageAcross(left)) }
        }
        let peak = 0.25 * 2.1 * 2.squareRoot() * 10_000 / 10_100
        XCTAssertEqual(lefts.max() ?? 0, peak, accuracy: 0.01)
        XCTAssertEqual(lefts.min() ?? 0, -peak, accuracy: 0.01)
    }

    /// Mutable Instruments' Rings from its own firmware (GPL-3.0, so CI builds it from Mutable's repository and it is
    /// not kept here) on the STM32 part, with its WM8731: its pots and CVs at mid-scale, its input normalled to its
    /// probe (PC8, through 1 MΩ into 10 kΩ, as an unpatched jack's normal carries it), strummed twice a second on its
    /// trigger input (PA2, active low). Its resonator rings at 380 Hz, the FREQUENCY pot's middle.
    func testMutableInstrumentsRingsRingsInACircuit() throws {
        guard let path = ProcessInfo.processInfo.environment["JSPICE_RINGS_HEX"] else {
            throw XCTSkip("JSPICE_RINGS_HEX is not set: CI builds Rings' firmware for this test")
        }
        var chip = NetlistPart(kind: .stm32f405, name: "U1",
                               connections: ["pb12": "ws", "pb13": "bclk", "pb15": "dacdat", "pb14": "adcdat", "pc6": "mclk",
                                             "pb10": "scl", "pb11": "sda", "pa2": "strum", "pc8": "probe",
                                             "pa0": "mid", "pa1": "mid", "pa4": "mid", "pa5": "mid", "pa6": "mid", "pa7": "mid",
                                             "pc1": "mid", "pc2": "mid", "pc3": "mid"])
        chip.firmware = try FirmwareFile.decode(try Data(contentsOf: URL(fileURLWithPath: path)))
        let circuit = try SchematicLayout.layout([
            chip,
            NetlistPart(kind: .codec, name: "U2",
                        connections: ["mclk": "mclk", "bclk": "bclk", "dacdat": "dacdat", "daclrc": "ws", "adcdat": "adcdat",
                                      "adclrc": "ws", "sclk": "scl", "sdin": "sda", "lout": "out", "rout": "aux",
                                      "linl": "mid", "linr": "in"]),
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 1.65], connections: ["plus": "mid", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 1e6], connections: ["a": "probe", "b": "in"]),
            NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 10_000], connections: ["a": "mid", "b": "in"]),
            NetlistPart(kind: .squareVoltage, name: "STRUM", params: ["high": 3.3, "low": 0, "frequency": 2, "duty": 0.98],
                        connections: ["plus": "strum", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 10_000], connections: ["a": "out", "b": "GND"]),
            NetlistPart(kind: .probe, name: "OUT", connections: ["plus": "out", "minus": "GND"]),
        ])
        let simulator = Simulator(circuit: circuit, timeStep: 1.0 / 48000)
        let probe = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "OUT" })
        var out: [Double] = []
        while simulator.time < 0.7 {
            simulator.step()
            XCTAssertFalse(simulator.isFailed, simulator.problems.joined(separator: " "))
            if simulator.isFailed { break }
            if simulator.time > 0.3 { out.append(simulator.voltageAcross(probe)) }
        }
        let mean = out.reduce(0, +) / Double(max(out.count, 1))
        let ac = out.map { $0 - mean }
        let rms = (ac.map { $0 * $0 }.reduce(0, +) / Double(max(ac.count, 1))).squareRoot()
        XCTAssertGreaterThan(rms, 0.01, "Rings sounds")
        // the strongest frequency between 200 and 600 Hz
        func amplitude(_ f: Double) -> Double {
            var (re, im) = (0.0, 0.0)
            for (k, x) in ac.enumerated() {
                let phase = 2 * Double.pi * f * Double(k) / 48000
                re += x * cos(phase)
                im += x * sin(phase)
            }
            return (re * re + im * im).squareRoot()
        }
        let strongest = stride(from: 200.0, through: 600, by: 5).max { amplitude($0) < amplitude($1) } ?? 0
        XCTAssertEqual(strongest, 380, accuracy: 10)
    }

    /// Mutable Instruments' Plaits from its own firmware (GPL-3.0: built by CI from Mutable's repository, not kept here)
    /// on the STM32F373 part, with its PCM5100 on I2S2 (BCK on PA8, LRCK on PA11, data on PA10): its pots at
    /// mid-scale, its buttons (PB6, PB7) up, V/OCT (PB14) where 0 V puts it, and the inputs an unpatched jack normals to
    /// its probe (PA9) following the probe inverted, as its input stages invert it: FM (PE9), TIMBRE (PB2), MORPH (PB15),
    /// TRIGGER (PB0) and LEVEL (PE8). Unpatched, it drones on its first model at middle C (at the chip's I2S rate, 72
    /// MHz over 47 × 32, 47 872 frames a second: 260.9 Hz).
    func testMutableInstrumentsPlaitsPlaysMiddleC() throws {
        guard let path = ProcessInfo.processInfo.environment["JSPICE_PLAITS_HEX"] else {
            throw XCTSkip("JSPICE_PLAITS_HEX is not set: CI builds Plaits' firmware for this test")
        }
        var chip = NetlistPart(kind: .stm32f373, name: "U1",
                               connections: ["pa8": "bck", "pa10": "din", "pa11": "lrck", "pa9": "probe",
                                             "pe9": "normal", "pb2": "normal", "pb15": "normal", "pb0": "normal", "pe8": "normal",
                                             "pb6": "high", "pb7": "high", "pb14": "voct", "pb1": "mid", "pd8": "mid",
                                             "pa0": "mid", "pa1": "mid", "pa2": "mid", "pa3": "mid", "pa4": "mid", "pa5": "mid",
                                             "pa6": "mid"])
        chip.firmware = try FirmwareFile.decode(try Data(contentsOf: URL(fileURLWithPath: path)))
        let circuit = try SchematicLayout.layout([
            chip,
            NetlistPart(kind: .i2sDac, name: "U2", connections: ["bck": "bck", "din": "din", "lrck": "lrck", "outL": "out", "outR": "aux"]),
            NetlistPart(kind: .schmittInverter, name: "U3", params: ["supply": 3.3], connections: ["in": "probe", "out": "normal"]),
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 1.65], connections: ["plus": "mid", "minus": "GND"]),
            NetlistPart(kind: .dcVoltage, name: "V2", params: ["voltage": 3.3], connections: ["plus": "high", "minus": "GND"]),
            NetlistPart(kind: .dcVoltage, name: "V3", params: ["voltage": 2.36], connections: ["plus": "voct", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 10_000], connections: ["a": "out", "b": "GND"]),
            NetlistPart(kind: .probe, name: "OUT", connections: ["plus": "out", "minus": "GND"]),
        ])
        let simulator = Simulator(circuit: circuit, timeStep: 1.0 / 48000)
        let probe = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "OUT" })
        var out: [Double] = []
        while simulator.time < 0.6 {
            simulator.step()
            XCTAssertFalse(simulator.isFailed, simulator.problems.joined(separator: " "))
            if simulator.isFailed { break }
            if simulator.time > 0.35 { out.append(simulator.voltageAcross(probe)) }
        }
        let mean = out.reduce(0, +) / Double(max(out.count, 1))
        let ac = out.map { $0 - mean }
        let rms = (ac.map { $0 * $0 }.reduce(0, +) / Double(max(ac.count, 1))).squareRoot()
        XCTAssertGreaterThan(rms, 0.05, "Plaits sounds")
        func amplitude(_ f: Double) -> Double {
            var (re, im) = (0.0, 0.0)
            for (k, x) in ac.enumerated() {
                let phase = 2 * Double.pi * f * Double(k) / 48000
                re += x * cos(phase)
                im += x * sin(phase)
            }
            return (re * re + im * im).squareRoot()
        }
        let strongest = stride(from: 150.0, through: 400, by: 2).max { amplitude($0) < amplitude($1) } ?? 0
        XCTAssertEqual(strongest, 261, accuracy: 4)
    }

    func testResetStartsOver() throws {
        let chip = STM32Microcontroller(firmware: try firmware())
        run(chip, for: 0.05)
        XCTAssertTrue(String(decoding: chip.serialOutput, as: UTF8.self).hasPrefix("boot\n"))
        chip.reset()
        XCTAssertEqual(chip.cycles, 0)
        XCTAssertEqual(chip.clock, 16e6, "from reset, on its internal oscillator")
        XCTAssertTrue(chip.serialOutput.isEmpty)
        run(chip, for: 0.05)
        XCTAssertTrue(String(decoding: chip.serialOutput, as: UTF8.self).hasPrefix("boot\n"))
    }
}
