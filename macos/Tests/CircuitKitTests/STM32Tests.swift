@testable import CircuitKit
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
    func run(_ chip: STM32F405, for seconds: Double) {
        var left = seconds
        while left > 0 {
            let step = min(left, 1e-3)
            chip.run(cycles: max(Int(step * chip.clock), 1))
            left -= step
        }
    }

    func testTheTestFirmwareRuns() throws {
        let chip = STM32F405(firmware: try firmware())
        XCTAssertEqual(chip.pinCount, 49)
        XCTAssertEqual(STM32F405.pinNames.first, "pa0")
        XCTAssertEqual(STM32F405.pinNames[45], "pc13")
        XCTAssertEqual(STM32F405.pinNames.last, "pd2")

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
        chip.i2cTarget = STM32F405.I2CTarget(start: { _, address, _ in addressed.append(address); return address == 0x1A },
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

    func testResetStartsOver() throws {
        let chip = STM32F405(firmware: try firmware())
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
