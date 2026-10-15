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
        XCTAssertEqual(STM32Microcontroller.pinNames(STM32_F103).count, 35)
        XCTAssertEqual(STM32Microcontroller.pinNames(STM32_F103).suffix(3), ["pc13", "pc14", "pc15"])

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
        XCTAssertFalse(simulator.problems.contains { $0.hasPrefix("U2") }, simulator.problems.joined(separator: " "))
    }

    /// A DAC wired where the firmware does not send its frames gets none, and the simulator says why: here the
    /// PCM5102's DIN on PB14, which the firmware has as I2S2's full-duplex input, not on PB15, its data out
    func testAMiswiredDACIsToldOfAndGetsNothing() throws {
        var chip = NetlistPart(kind: .stm32f405, name: "U1", connections: ["pb12": "ws", "pb13": "bck", "pb14": "din"])
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
            if simulator.isFailed { break }
            if simulator.time > 0.1 { lefts.append(simulator.voltageAcross(left)) }
        }
        XCTAssertLessThan(lefts.map(abs).max() ?? 1, 0.001, "no frames reach it")
        let said = simulator.problems.filter { $0.hasPrefix("U2") }
        XCTAssertEqual(said, ["U2 (PCM5102): its DIN is on PB14, which the firmware has as I2S2's full-duplex SD (I2S2ext), not as I2S2's SD."])
    }

    /// The same with its clock on a pin the firmware leaves as an input (PC10, where I2S3 could have its CK)
    func testADACOnAnUnusedClockPinIsToldOf() throws {
        var chip = NetlistPart(kind: .stm32f405, name: "U1", connections: ["pb12": "ws", "pc10": "bck", "pb15": "din"])
        chip.firmware = Data(try firmware())
        let circuit = try SchematicLayout.layout([
            chip,
            NetlistPart(kind: .i2sDac, name: "U2", connections: ["bck": "bck", "din": "din", "lrck": "ws", "outL": "left", "outR": "right"]),
            NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 10_000], connections: ["a": "left", "b": "GND"]),
        ])
        let simulator = Simulator(circuit: circuit, timeStep: 1.0 / 48000)
        while simulator.time < 0.1 && !simulator.isFailed { simulator.step() }
        XCTAssertEqual(simulator.problems.filter { $0.hasPrefix("U2") },
                       ["U2 (PCM5102): its BCK is on PC10, which the firmware has as a GPIO input, not as an I2S port's clock. No data reaches it."])
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
        XCTAssertFalse(simulator.problems.contains { $0.hasPrefix("U2") }, simulator.problems.joined(separator: " "))
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

    /// Mutable Instruments' Tides 2 from its own firmware (built by CI, not kept here) on the STM32F373 part, with its
    /// DAC8564 on I2S2 (SCLK on PA8, DIN on PA10, SYNC on PA11: a 24-bit word in each 32-bit PCM word): its pots (PA0,
    /// PA1, PA6) and CVs (PB0, PB14, PB15, PD8, PE8, PE9) at mid-scale, its buttons (PA2, PA12, PC13) up, and its gate
    /// inputs (PB1, PB2) following its probe (PA9) inverted, as unpatched jacks normalled to it through their input
    /// transistors. It loops as it starts (its looping mode, its audio range): output A swings across half the DAC's
    /// range at 100 Hz.
    func testMutableInstrumentsTides2Loops() throws {
        guard let path = ProcessInfo.processInfo.environment["JSPICE_TIDES2_HEX"] else {
            throw XCTSkip("JSPICE_TIDES2_HEX is not set: CI builds Tides 2's firmware for this test")
        }
        var chip = NetlistPart(kind: .stm32f373, name: "U1",
                               connections: ["pa8": "sclk", "pa10": "din", "pa11": "sync", "pa9": "probe",
                                             "pb1": "normal", "pb2": "normal", "pa2": "high", "pa12": "high", "pc13": "high",
                                             "pa0": "mid", "pa1": "mid", "pa6": "mid", "pb0": "mid", "pb14": "mid",
                                             "pb15": "mid", "pd8": "mid", "pe8": "mid", "pe9": "mid"])
        chip.firmware = try FirmwareFile.decode(try Data(contentsOf: URL(fileURLWithPath: path)))
        let circuit = try SchematicLayout.layout([
            chip,
            NetlistPart(kind: .cvDac, name: "U2", params: ["fullScale": 2.5, "format": 1],
                        connections: ["sclk": "sclk", "din": "din", "sync": "sync", "outA": "out"]),
            NetlistPart(kind: .schmittInverter, name: "U3", params: ["supply": 3.3], connections: ["in": "probe", "out": "normal"]),
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 1.65], connections: ["plus": "mid", "minus": "GND"]),
            NetlistPart(kind: .dcVoltage, name: "V2", params: ["voltage": 3.3], connections: ["plus": "high", "minus": "GND"]),
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
            if simulator.time > 0.3 { out.append(simulator.voltageAcross(probe)) }
        }
        let swing = (out.max() ?? 0) - (out.min() ?? 0)
        XCTAssertEqual(swing, 1.23, accuracy: 0.1, "half the DAC8564's 2.5 V")
        let mean = out.reduce(0, +) / Double(max(out.count, 1))
        let ac = out.map { $0 - mean }
        func amplitude(_ f: Double) -> Double {
            var (re, im) = (0.0, 0.0)
            for (k, x) in ac.enumerated() {
                let phase = 2 * Double.pi * f * Double(k) / 48000
                re += x * cos(phase)
                im += x * sin(phase)
            }
            return (re * re + im * im).squareRoot()
        }
        let strongest = stride(from: 20.0, through: 400, by: 1).max { amplitude($0) < amplitude($1) } ?? 0
        XCTAssertEqual(strongest, 100, accuracy: 3)
    }

    /// Mutable Instruments' Braids from its own firmware (built by CI, not kept here) on the STM32F103 part: its DAC8551
    /// on SPI2 (SCLK on PB13, DIN on PB15, SYNC on PB12), a 24-bit word each sample at 96 kHz, and its MCP3204 on SPI1
    /// (CLK on PA5, DIN on PA7, DOUT on PA6, CS on PB0) reading its four CVs, all at half its reference. Its first shape
    /// (CSAW) plays at 269.5 Hz.
    func testMutableInstrumentsBraidsPlays() throws {
        guard let path = ProcessInfo.processInfo.environment["JSPICE_BRAIDS_HEX"] else {
            throw XCTSkip("JSPICE_BRAIDS_HEX is not set: CI builds Braids' firmware for this test")
        }
        var chip = NetlistPart(kind: .stm32f103, name: "U1",
                               connections: ["pb13": "sclk", "pb15": "din", "pb12": "sync",
                                             "pa5": "aclk", "pa7": "adin", "pa6": "adout", "pb0": "acs"])
        chip.firmware = try FirmwareFile.decode(try Data(contentsOf: URL(fileURLWithPath: path)))
        let circuit = try SchematicLayout.layout([
            chip,
            NetlistPart(kind: .cvDac, name: "U2", params: ["fullScale": 2.5, "format": 3],
                        connections: ["sclk": "sclk", "din": "din", "sync": "sync", "outA": "out"]),
            NetlistPart(kind: .spiAdc, name: "U3", params: ["resolution": 1],
                        connections: ["cs": "acs", "clk": "aclk", "din": "adin", "dout": "adout", "vref": "ref",
                                      "ch0": "mid", "ch1": "mid", "ch2": "mid", "ch3": "mid"]),
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 1.65], connections: ["plus": "mid", "minus": "GND"]),
            NetlistPart(kind: .dcVoltage, name: "V2", params: ["voltage": 3.3], connections: ["plus": "ref", "minus": "GND"]),
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
            if simulator.time > 0.3 { out.append(simulator.voltageAcross(probe)) }
        }
        XCTAssertGreaterThan((out.max() ?? 0) - (out.min() ?? 0), 1, "Braids sounds")
        let mean = out.reduce(0, +) / Double(max(out.count, 1))
        let ac = out.map { $0 - mean }
        func amplitude(_ f: Double) -> Double {
            var (re, im) = (0.0, 0.0)
            for (k, x) in ac.enumerated() {
                let phase = 2 * Double.pi * f * Double(k) / 48000
                re += x * cos(phase)
                im += x * sin(phase)
            }
            return (re * re + im * im).squareRoot()
        }
        let strongest = stride(from: 150.0, through: 400, by: 0.5).max { amplitude($0) < amplitude($1) } ?? 0
        XCTAssertEqual(strongest, 269.5, accuracy: 3)
        XCTAssertFalse(simulator.problems.contains { $0.hasPrefix("U2") || $0.hasPrefix("U3") }, simulator.problems.joined(separator: " "))
    }

    /// A firmware that starts the independent watchdog (its shortest prescaler, its longest reload) and then never
    /// reloads it: the chip resets itself when it runs out, 4 × 4096 ticks of its LSI (0.512 s on the F405's 32 kHz,
    /// 0.41 s on the others' 40 kHz), and says so
    func testTheWatchdogResetsAChipWhoseFirmwareStopsReloadingIt() {
        // KR = 0x5555, PR = 0, KR = 0xCCCC, then a loop
        let firmware: [UInt8] = [
            0x00, 0x10, 0x00, 0x20, 0x09, 0x00, 0x00, 0x08, 0x04, 0x48, 0x45, 0xF2, 0x55, 0x51, 0x01, 0x60, 0x00, 0x21,
            0x41, 0x60, 0x4C, 0xF6, 0xCC, 0x41, 0x01, 0x60, 0xFE, 0xE7, 0x00, 0x30, 0x00, 0x40,
        ]
        for (model, first) in [(STM32_F405, 0.512), (STM32_F373, 0.4096), (STM32_F103, 0.4096)] {
            let chip = STM32Microcontroller(model: model, firmware: firmware)
            run(chip, for: first - 0.01)
            XCTAssertEqual(stm32_watchdog_resets(chip.chip), 0)
            XCTAssertTrue(chip.notices.isEmpty, chip.notices.joined(separator: " "))
            run(chip, for: 0.02)
            XCTAssertEqual(stm32_watchdog_resets(chip.chip), 1)
            XCTAssertEqual(chip.notices, ["its watchdog ran out and reset it once: the firmware stopped reloading it in time."])
        }
    }

    /// A firmware that writes CAN1 (which the model leaves out), reads a reserved address, and asks for a system reset
    /// twice, counting its boots in RAM (which a reset keeps): each is said
    func testWhatTheModelDoesNotRunIsSaid() {
        let firmware: [UInt8] = [
            0x00, 0x10, 0x00, 0x20, 0x09, 0x00, 0x00, 0x08, 0x07, 0x48, 0x01, 0x21, 0x01, 0x60, 0x07, 0x48, 0x01, 0x68,
            0x07, 0x48, 0x07, 0x49, 0x4F, 0xF0, 0x00, 0x52, 0x13, 0x68, 0x01, 0x33, 0x13, 0x60, 0x03, 0x2B, 0x00, 0xDA,
            0x01, 0x60, 0xFE, 0xE7, 0x00, 0x64, 0x00, 0x40, 0x00, 0x60, 0x00, 0x40, 0x0C, 0xED, 0x00, 0xE0, 0x04, 0x00,
            0xFA, 0x05,
        ]
        let chip = STM32Microcontroller(firmware: firmware)
        run(chip, for: 0.01)
        XCTAssertEqual(stm32_software_resets(chip.chip), 2, "the third boot finds its count at 3")
        XCTAssertEqual(chip.notices, [
            "the firmware writes CAN1 (first at 0x40006400, from about 0x0800000C), which the model does not run: it reads 0 there, and what it writes is lost.",
            "the firmware reads 0x40006000 (from about 0x08000010), where the chip has nothing: a bus fault on the chip, 0 here.",
            "its firmware reset it 2 times (SYSRESETREQ).",
        ])
    }

    /// With its buses traced, the chip keeps what goes over them as a logic analyzer would decode it: the test
    /// firmware's "boot" on USART1, its write to a codec's register 6 on I2C2, then I2S2's frames at 48 kHz
    func testTheBusesAreTraced() throws {
        let chip = STM32Microcontroller(firmware: try firmware())
        chip.i2cTarget = STM32Microcontroller.I2CTarget(start: { _, address, _ in address == 0x1A }, write: { _, _ in true },
                                                        read: { _, _ in 0xFF }, stop: { _ in })
        chip.tracesBuses = true
        run(chip, for: 0.05)
        let events = chip.busEvents()
        XCTAssertEqual(events.filter { $0.kind == .usartSend }.prefix(5).map { UInt8($0.a) }, Array("boot\n".utf8))
        XCTAssertEqual(events.filter { $0.bus == "USART1" }.first?.summary, "sends 0x62 'b'")
        XCTAssertEqual(events.filter { $0.bus == "I2C2" }.map(\.summary),
                       ["start 0x1A write, ACK", "write 0x0C, ACK", "write 0x00, ACK", "stop"])
        let frames = events.filter { $0.kind == .i2s && $0.port == 2 }
        let span = (frames.last?.time ?? 0) - (frames.first?.time ?? 0)
        XCTAssertEqual(Double(frames.count - 1) / span, 47_991, accuracy: 50)
        XCTAssertEqual(chip.busEvents(since: events.last!.time).count, 1)
        XCTAssertEqual(chip.pinFunctions.first { $0.pin == "PB13" }?.function, "I2S2's CK")
        XCTAssertEqual(chip.pinFunctions.first { $0.pin == "PB10" }?.function, "I2C2's SCL")
        chip.tracesBuses = false
        XCTAssertTrue(chip.busEvents().isEmpty)
    }

    /// The GDB server's side of the remote protocol, as arm-none-eabi-gdb would drive it: halting, the target
    /// description, registers, memory, stepping, a breakpoint hit as the circuit runs the chip, a write to RAM
    func testTheGDBServerDebugsTheFirmware() throws {
        let image = try firmware()
        let chip = STM32Microcontroller(firmware: image)
        let server = try GDBServer(target: chip, port: 0)
        defer { server.stop() }
        func hex(_ text: String) -> String { GDBServer.hex(Array(text.utf8)) }
        XCTAssertEqual(server.respond(to: "qRcmd," + hex("halt")), "OK")
        XCTAssertTrue(chip.isHalted)
        XCTAssertTrue(server.respond(to: "qSupported:multiprocess+;swbreak+")?.contains("qXfer:features:read+") ?? false)
        XCTAssertTrue(server.respond(to: "qXfer:features:read:target.xml:0,ffff")?.hasPrefix("l<?xml") ?? false)
        XCTAssertEqual(server.respond(to: "?"), "S05")
        // r0-r12, sp, lr, pc, xpsr, d0-d15, fpscr, msp, psp, primask, basepri, faultmask, control
        let registers = try XCTUnwrap(server.respond(to: "g"))
        XCTAssertEqual(registers.count, 2 * (17 * 4 + 16 * 8 + 4 + 6 * 4))
        func pc() -> UInt32 {
            let bytes = GDBServer.bytes(server.respond(to: "pf") ?? "")
            return bytes.count == 4 ? bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } : 0
        }
        XCTAssertEqual(pc(), chip.programCounter)
        // the vector table, as the chip's flash holds it
        XCTAssertEqual(server.respond(to: "m8000000,8"), GDBServer.hex(Array(image.prefix(8))))
        // three steps from reset, each run by the chip as the circuit would run it
        XCTAssertTrue(server.respond(to: "qRcmd," + hex("reset"))?.isEmpty == false)
        let start = pc()
        for _ in 0..<3 {
            XCTAssertEqual(server.respond(to: "s"), "")
            run(chip, for: 1e-5)
            XCTAssertTrue(chip.isHalted)
        }
        let third = pc()
        XCTAssertNotEqual(third, start)
        // from reset again, a breakpoint there: running, the chip halts on it
        _ = server.respond(to: "qRcmd," + hex("reset"))
        XCTAssertEqual(pc(), start)
        XCTAssertEqual(server.respond(to: "Z0,\(String(third, radix: 16)),2"), "OK")
        XCTAssertEqual(server.respond(to: "c"), "")
        XCTAssertFalse(chip.isHalted)
        run(chip, for: 1e-4)
        XCTAssertTrue(chip.isHalted)
        XCTAssertEqual(pc(), third)
        XCTAssertEqual(server.respond(to: "z0,\(String(third, radix: 16)),2"), "OK")
        // RAM written and read back
        XCTAssertEqual(server.respond(to: "M20001000,4:78563412"), "OK")
        XCTAssertEqual(server.respond(to: "m20001000,4"), "78563412")
        XCTAssertEqual(server.respond(to: "qRcmd," + hex("resume")), "OK")
        XCTAssertFalse(chip.isHalted)
    }

    /// A firmware writing 0x3800 (gain 1, on, mid-scale) to an MCP4921 through SPI1 as a master (mode 0, 16 bits,
    /// PA5 SCK, PA7 MOSI), with CS on PA4
    static let spiDACFirmware: [UInt8] = [
        0x00, 0x10, 0x00, 0x20, 0x09, 0x00, 0x00, 0x08, 0x13, 0x48, 0x01, 0x68, 0x41, 0xF0, 0x01, 0x01, 0x01, 0x60,
        0x12, 0x48, 0x01, 0x68, 0x41, 0xF4, 0x80, 0x51, 0x01, 0x60, 0x10, 0x48, 0x01, 0x68, 0x41, 0xF4, 0x09, 0x41,
        0x01, 0x60, 0x0F, 0x49, 0x01, 0x62, 0x10, 0x21, 0x81, 0x61, 0x0E, 0x4A, 0x40, 0xF6, 0x5C, 0x31, 0x11, 0x60,
        0x4F, 0xF4, 0x80, 0x11, 0x81, 0x61, 0x4F, 0xF4, 0x60, 0x51, 0xD1, 0x60, 0x93, 0x68, 0x13, 0xF0, 0x02, 0x0F,
        0xFB, 0xD0, 0x93, 0x68, 0x13, 0xF0, 0x80, 0x0F, 0xFB, 0xD1, 0x10, 0x21, 0x81, 0x61, 0xFE, 0xE7, 0x30, 0x38,
        0x02, 0x40, 0x44, 0x38, 0x02, 0x40, 0x00, 0x00, 0x02, 0x40, 0x00, 0x00, 0x50, 0x50, 0x00, 0x30, 0x01, 0x40,
    ]

    /// A firmware writing 0x08 0x00 (fast mode: on, mid-scale) to an MCP4725 at 0x60 through I2C2 (PB10, PB11)
    static let i2cDACFirmware: [UInt8] = [
        0x00, 0x10, 0x00, 0x20, 0x09, 0x00, 0x00, 0x08, 0x1E, 0x48, 0x01, 0x68, 0x41, 0xF0, 0x02, 0x01, 0x01, 0x60,
        0x1D, 0x48, 0x01, 0x68, 0x41, 0xF4, 0x80, 0x01, 0x01, 0x60, 0x1B, 0x48, 0x01, 0x68, 0x41, 0xF4, 0x20, 0x01,
        0x01, 0x60, 0x41, 0x68, 0x41, 0xF4, 0x40, 0x61, 0x41, 0x60, 0x4F, 0xF4, 0x88, 0x41, 0x41, 0x62, 0x16, 0x4A,
        0x10, 0x21, 0x51, 0x60, 0x50, 0x21, 0xD1, 0x61, 0x01, 0x21, 0x11, 0x60, 0x11, 0x68, 0x41, 0xF4, 0x80, 0x71,
        0x11, 0x60, 0x53, 0x69, 0x13, 0xF0, 0x01, 0x0F, 0xFB, 0xD0, 0xC0, 0x21, 0x11, 0x61, 0x53, 0x69, 0x13, 0xF0,
        0x02, 0x0F, 0xFB, 0xD0, 0x93, 0x69, 0x08, 0x21, 0x11, 0x61, 0x53, 0x69, 0x13, 0xF0, 0x80, 0x0F, 0xFB, 0xD0,
        0x00, 0x21, 0x11, 0x61, 0x53, 0x69, 0x13, 0xF0, 0x04, 0x0F, 0xFB, 0xD0, 0x11, 0x68, 0x41, 0xF4, 0x00, 0x71,
        0x11, 0x60, 0xFE, 0xE7, 0x00, 0x00, 0x30, 0x38, 0x02, 0x40, 0x40, 0x38, 0x02, 0x40, 0x00, 0x04, 0x02, 0x40,
        0x00, 0x58, 0x00, 0x40,
    ]

    /// The SPI port's frames reach a part that takes its bits from the pins edge by edge: the MCP4921 goes to half
    /// its reference
    func testAnSPIDACOnTheChipsSPIPortTakesItsWord() throws {
        let (simulator, out) = try dacCircuit(sdi: "pa7")
        XCTAssertEqual(simulator.voltageAcross(out), 2.048 / 2 * 10_000 / 10_010, accuracy: 0.005)
        XCTAssertFalse(simulator.problems.contains { $0.hasPrefix("U2") }, simulator.problems.joined(separator: " "))
    }

    /// Its SDI on a pin the firmware leaves as an input: it gets nothing, and the simulator says why
    func testAnSPIDACWhoseDataPinIsNotMOSIIsToldOf() throws {
        let (simulator, out) = try dacCircuit(sdi: "pa6")
        XCTAssertEqual(simulator.voltageAcross(out), 0, accuracy: 0.001)
        XCTAssertEqual(simulator.problems.filter { $0.hasPrefix("U2") },
                       ["U2 (MCP4921): its SDI is on PA6, which the firmware has as a GPIO input, not as SPI1's MOSI."])
    }

    func dacCircuit(sdi: String) throws -> (Simulator, Int) {
        var chip = NetlistPart(kind: .stm32f405, name: "U1", connections: ["pa4": "cs", "pa5": "sck", sdi: "sdi"])
        chip.firmware = Data(Self.spiDACFirmware)
        let circuit = try SchematicLayout.layout([
            chip,
            NetlistPart(kind: .dac, name: "U2", params: ["supply": 3.3],
                        connections: ["cs": "cs", "sck": "sck", "sdi": "sdi", "ldac": "GND", "vref": "ref", "out": "out"]),
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 2.048], connections: ["plus": "ref", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 10_000], connections: ["a": "out", "b": "GND"]),
            NetlistPart(kind: .probe, name: "OUT", connections: ["plus": "out", "minus": "GND"]),
        ])
        let simulator = Simulator(circuit: circuit, timeStep: 1.0 / 48000)
        while simulator.time < 0.01 && !simulator.isFailed { simulator.step() }
        return (simulator, try XCTUnwrap(circuit.elements.firstIndex { $0.name == "OUT" }))
    }

    /// An MCP4725 on the chip's I2C2 pins answers its address and takes its code: half its supply
    func testAnI2CDACOnTheChipsI2CBusTakesItsCode() throws {
        var chip = NetlistPart(kind: .stm32f405, name: "U1", connections: ["pb10": "scl", "pb11": "sda"])
        chip.firmware = Data(Self.i2cDACFirmware)
        let circuit = try SchematicLayout.layout([
            chip,
            NetlistPart(kind: .i2cDac, name: "U2", params: ["supply": 3.3],
                        connections: ["scl": "scl", "sda": "sda", "a0": "GND", "out": "out"]),
            NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 10_000], connections: ["a": "out", "b": "GND"]),
            NetlistPart(kind: .probe, name: "OUT", connections: ["plus": "out", "minus": "GND"]),
        ])
        let simulator = Simulator(circuit: circuit, timeStep: 1.0 / 48000)
        while simulator.time < 0.01 && !simulator.isFailed { simulator.step() }
        let out = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "OUT" })
        XCTAssertEqual(simulator.voltageAcross(out), 3.3 / 2 * 10_000 / 10_010, accuracy: 0.005)
        XCTAssertFalse(simulator.problems.contains { $0.hasPrefix("U2") }, simulator.problems.joined(separator: " "))
    }

    /// A firmware loading a 74HC165 (SH/LD low then high on PA4) and reading it through SPI1 (mode 0, 8 bits, PA5
    /// SCK, PA6 MISO) into the word at 0x20000000, over and over
    static let shiftInFirmware: [UInt8] = [
        0x00, 0x10, 0x00, 0x20, 0x09, 0x00, 0x00, 0x08, 0x13, 0x48, 0x01, 0x68, 0x41, 0xF0, 0x01, 0x01, 0x01, 0x60,
        0x12, 0x48, 0x01, 0x68, 0x41, 0xF4, 0x80, 0x51, 0x01, 0x60, 0x10, 0x48, 0x01, 0x68, 0x41, 0xF4, 0x29, 0x41,
        0x01, 0x60, 0x0F, 0x49, 0x01, 0x62, 0x10, 0x21, 0x81, 0x61, 0x0E, 0x4A, 0x4F, 0xF4, 0x57, 0x71, 0x11, 0x60,
        0x4F, 0xF0, 0x00, 0x54, 0x4F, 0xF4, 0x80, 0x11, 0x81, 0x61, 0x10, 0x21, 0x81, 0x61, 0x00, 0x21, 0xD1, 0x60,
        0x93, 0x68, 0x13, 0xF0, 0x01, 0x0F, 0xFB, 0xD0, 0xD1, 0x68, 0x21, 0x60, 0xF1, 0xE7, 0x00, 0x00, 0x30, 0x38,
        0x02, 0x40, 0x44, 0x38, 0x02, 0x40, 0x00, 0x00, 0x02, 0x40, 0x00, 0x00, 0x50, 0x55, 0x00, 0x30, 0x01, 0x40,
    ]

    /// The SPI port reads what a 74HC165 shifts out on its MISO, bit by bit: its eight inputs, D7 first
    func testA74HC165OnTheChipsSPIPortIsRead() throws {
        var chip = NetlistPart(kind: .stm32f405, name: "U1", connections: ["pa4": "load", "pa5": "clk", "pa6": "qh"])
        chip.firmware = Data(Self.shiftInFirmware)
        var connections = ["sh_ld": "load", "clk": "clk", "clk_inh": "GND", "ser": "GND", "qh": "qh"]
        for k in 0...7 { connections["d\(k)"] = 0xA5 >> k & 1 == 1 ? "high" : "GND" }
        let circuit = try SchematicLayout.layout([
            chip,
            NetlistPart(kind: .shiftIn, name: "U2", params: ["supply": 3.3], connections: connections),
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 3.3], connections: ["plus": "high", "minus": "GND"]),
        ])
        let simulator = Simulator(circuit: circuit, timeStep: 1.0 / 48000)
        while simulator.time < 0.01 && !simulator.isFailed { simulator.step() }
        let index = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "U1" })
        let stm32 = try XCTUnwrap(simulator.chip(index) as? STM32Microcontroller)
        XCTAssertEqual(cm4_read(stm32_core(stm32.chip), 0x2000_0000, 4), 0xA5)
        XCTAssertFalse(simulator.problems.contains { $0.hasPrefix("U2") }, simulator.problems.joined(separator: " "))
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
