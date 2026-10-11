import XCTest
@testable import CircuitKit

/// The RP2040 emulator against rp2040js, which it ports: arduino-pico sketches (tools/pico-reference/sketches, built
/// with tools/pico-reference/build.py into Fixtures) run with the same inputs at the same moments, the summaries from
/// tools/pico-reference/trace.ts (the instructions and cycles run, every change on the watched pins to the
/// nanosecond, the registers at the end, everything sent over USB serial)
final class PicoTests: XCTestCase {
    private func image(_ name: String) throws -> [UInt8] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "bin", subdirectory: "Fixtures"))
        return [UInt8](try Data(contentsOf: url))
    }

    private enum Event {
        case pin(Int, Bool)
        case adc(Int, UInt32)
        case serial(String)
    }

    private static func bits(_ x: Double) -> String { String(x.bitPattern, radix: 16) }

    /// trace.ts's loop, line for line
    private func trace(_ image: [UInt8], seconds: Double, pins: [Int], events: [(Double, Event)] = []) -> (String, String) {
        let chip = RP2040()
        let cdc = RPUSBCDC(usb: chip.usbCtrl)
        var serial = ""
        cdc.onSerialData = { bytes in serial += String(bytes.map { Character(Unicode.Scalar($0)) }) }
        chip.loadFlash(image)
        var counts = [Int: Int](), sums = [Int: Double](), last = [Int: [String]]()
        for pin in pins {
            counts[pin] = 0
            sums[pin] = 0
            last[pin] = []
            chip.gpio[pin].onChange = { state in
                counts[pin]! += 1
                sums[pin]! += chip.clock.nanos
                last[pin]!.append("\(PicoTests.bits(chip.clock.nanos)):\(state.rawValue)")
                if last[pin]!.count > 3 { last[pin]!.removeFirst() }
            }
        }
        chip.core.PC = RP2040.flashStart
        let end = seconds * 1e9
        var instructions = 0
        var next = 0
        while chip.clock.nanos < end {
            while next < events.count && chip.clock.nanos >= events[next].0 {
                switch events[next].1 {
                case let .pin(gpio, high): chip.gpio[gpio].setInputValue(high)
                case let .adc(channel, value): chip.adc.channelValues[channel] = value
                case let .serial(text): for byte in text.utf8 { cdc.sendSerialByte(byte) }
                }
                next += 1
            }
            if chip.core.waiting {
                chip.clock.tick(chip.clock.nanosToNextAlarm)
            } else {
                let cycles = chip.core.executeInstruction()
                instructions += 1
                chip.clock.tick(Double(cycles) * RP2040.cycleNanos)
            }
        }
        var lines = ["instructions \(instructions) cycles \(chip.core.cycles) nanos \(PicoTests.bits(chip.clock.nanos))"]
        for pin in pins {
            lines.append("GP\(pin) \(counts[pin]!) \(PicoTests.bits(sums[pin]!)) \(last[pin]!.joined(separator: " "))")
        }
        lines.append("registers " + (0..<16).map { String(chip.core.registers[$0], radix: 16) }.joined(separator: " "))
        return (lines.joined(separator: "\n"), serial)
    }

    func testBlinkMatchesRP2040js() throws {
        let (summary, serial) = trace(try image("pico-blink"), seconds: 1, pins: [25, 15])
        XCTAssertEqual(summary, """
            instructions 1622811 cycles 2793878 nanos 41cdd0029c000000
            GP25 11 41f0ce0b8e000000 41c4e74478000000:1 41c7e34e4c000000:0 41cadf59f8000000:1
            GP15 13 41f0e4ec3b800000 41c4e745ac000000:1 41c7e34f84000000:0 41cadf5b2c000000:1
            registers d0000128 0 0 d0000128 f4963 0 f4969 0 0 0 0 0 0 20041f78 fffffff9 1000491d
            """)
        XCTAssertEqual(serial, (1...9).map { "count \($0)\r\n" }.joined())
    }

    func testKitchenSinkMatchesRP2040js() throws {
        // a falling-edge interrupt on GP2, the ADC on GP26, PWM on GP4, USB serial both ways, float and 64-bit maths
        let events: [(Double, Event)] = [
            (0, .pin(2, true)), (0, .adc(0, 1000)), (60_000_000, .pin(2, false)), (70_000_000, .pin(2, true)),
            (90_000_000, .pin(2, false)), (95_000_000, .pin(2, true)), (120_000_000, .adc(0, 3071)),
            (150_000_000, .serial("hi!")), (200_000_000, .adc(0, 4095)), (210_000_000, .pin(2, false)),
        ]
        let (summary, serial) = trace(try image("pico-kitchen"), seconds: 0.3, pins: [2, 3, 4, 25], events: events)
        XCTAssertEqual(summary, """
            instructions 1488280 cycles 2521401 nanos 41b1e2a4c9000000
            GP2 2 412f60c000000000 411f5e6000000000:4 411f632000000000:3
            GP3 13 41d9bbb934000000 41ac1addd0000000:1 41af39d080000000:0 41b12c61e8000000:1
            GP4 839 423490c8d84a0000 41a8fb248c000000:1 41a90692ba000000:0 41a90a673a000000:1
            GP25 0 0 
            registers d0000128 0 0 d0000128 4cbb6 0 4cbbc 0 0 0 0 0 0 20041f78 100057cf 100057f6
            """)
        let lines = serial.components(separatedBy: "\r\n")
        XCTAssertEqual(lines.first, "r=1 adc=250 v=0.806 sqrt=1.3440 big=130853 q=62504 edges=0")
        XCTAssertEqual(Array(lines[6...8]), ["echo H", "echo I", "echo !"])
        XCTAssertEqual(lines[lines.count - 2], "r=11 adc=1023 v=3.300 sqrt=2.0736 big=397979 q=73072 edges=3")
        XCTAssertEqual(serial, """
            r=1 adc=250 v=0.806 sqrt=1.3440 big=130853 q=62504 edges=0\r
            r=2 adc=250 v=0.806 sqrt=1.3440 big=449648 q=50003 edges=0\r
            r=3 adc=250 v=0.806 sqrt=1.3440 big=104683 q=41669 edges=1\r
            r=4 adc=250 v=0.806 sqrt=1.3440 big=276985 q=35716 edges=2\r
            r=5 adc=767 v=2.474 sqrt=1.8639 big=227639 q=95877 edges=2\r
            r=6 adc=767 v=2.474 sqrt=1.8639 big=287052 q=85224 edges=2\r
            echo H\r
            echo I\r
            echo !\r
            r=7 adc=767 v=2.474 sqrt=1.8639 big=480834 q=76701 edges=2\r
            r=8 adc=1023 v=3.300 sqrt=2.0736 big=277575 q=93001 edges=3\r
            r=9 adc=1023 v=3.300 sqrt=2.0736 big=947728 q=85251 edges=3\r
            r=10 adc=1023 v=3.300 sqrt=2.0736 big=715508 q=78693 edges=3\r
            r=11 adc=1023 v=3.300 sqrt=2.0736 big=397979 q=73072 edges=3\r

            """)
    }

    func testPicoOnItsPins() throws {
        // the Microcontroller face: the LED and GP15 follow the sketch, Serial reaches serialOutput
        let pico = Pico(firmware: try image("pico-blink"))
        var ledChanges = 0
        var wasOn = pico.ledOn
        for _ in 0..<1000 {
            pico.run(cycles: 125_000)  // 1 ms
            if pico.ledOn != wasOn {
                ledChanges += 1
                wasOn = pico.ledOn
            }
        }
        XCTAssertEqual(ledChanges, 9)
        XCTAssertEqual(pico.pinStates[15], .output(high: wasOn))
        XCTAssertEqual(pico.pinStates[14], .inputPullDown)
        XCTAssertTrue(String(decoding: pico.serialOutput, as: UTF8.self).hasPrefix("count 1\r\ncount 2\r\n"))
        XCTAssertGreaterThanOrEqual(pico.cycles, 125_000_000)
        XCTAssertLessThan(pico.cycles, 125_010_000)
    }

    func testToneRunsOnPIOInSimulatedTime() throws {
        // arduino-pico's tone() loops on a PIO state machine (rp2040js runs PIO apart from simulated time, so there is
        // nothing to compare with): 440 Hz, then 1 kHz, to a few parts per million
        let pico = Pico(firmware: try image("pico-tone"))
        var rising: [Double] = []
        var wasHigh = false
        let step = 1250  // 10 µs
        // timed by the chip's own count: a run can end an instruction past its budget (the simulator carries that over)
        while pico.cycles < 112_500_000 {
            pico.run(cycles: step)
            let high = pico.pinStates[5] == .output(high: true)
            if high && !wasHigh { rising.append(Double(pico.cycles) / 125e6) }
            wasHigh = high
        }
        func frequency(from start: Double, to end: Double) -> Double {
            let edges = rising.filter { $0 > start && $0 < end }
            return Double(edges.count - 1) / (edges.last! - edges.first!)
        }
        // the delay loop of tone2.pio: a period of 2 * ((125 MHz + f) / 2f) cycles
        XCTAssertEqual(frequency(from: 0.05, to: 0.45), 125e6 / (2 * Double((125_000_000 + 440) / 880)), accuracy: 0.05)
        XCTAssertEqual(frequency(from: 0.55, to: 0.9), 125e6 / (2 * Double((125_000_000 + 1000) / 2000)), accuracy: 0.2)
    }

    /// Busy-waits counted at once (a sketch waiting on PIO's FIFO, on the ADC, on its loop) leave the Pico where it
    /// would have been: the same circuit, step for step, to the bit
    func testSkippedBusyWaitsLeaveThePicoWhereRunningWould() {
        defer { RP2040.skipsBusyWaits = true }
        for id in ["pico-pcm5102", "pico-knob", "pico-melody"] {
            let circuit = Examples.example(id)!.circuit
            var runs: [(voltages: [Double], registers: [UInt32], cycles: Int, serial: [UInt8], skipped: Double)] = []
            for skipping in [false, true] {
                RP2040.skipsBusyWaits = skipping
                let simulator = Simulator(circuit: circuit, timeStep: 1 / 48_000)
                simulator.errorControl = false
                let elements = simulator.circuit.elements
                let chipIndex = elements.firstIndex { $0.kind == .rp2040 }!
                var voltages: [Double] = []
                for _ in 0..<4_800 {
                    simulator.step()
                    for i in elements.indices where [.probe, .led, .speaker].contains(elements[i].kind) {
                        voltages.append(simulator.voltageAcross(i))
                    }
                }
                let pico = simulator.chip(chipIndex) as! Pico
                let core = pico.rp2040.core!
                runs.append((voltages, (0..<16).map { core.registers[$0] }, pico.cycles, pico.serialOutput, core.skippedNanos))
            }
            XCTAssertEqual(runs[0].skipped, 0, id)
            // (pio_sm_put_blocking waits on FSTAT, analogRead on the ADC's READY)
            if ["pico-pcm5102", "pico-knob"].contains(id) { XCTAssertGreaterThan(runs[1].skipped, 0, id) }
            XCTAssertEqual(runs[0].registers, runs[1].registers, id)
            XCTAssertEqual(runs[0].cycles, runs[1].cycles, id)
            XCTAssertEqual(runs[0].serial, runs[1].serial, id)
            XCTAssertEqual(runs[0].voltages.count, runs[1].voltages.count, id)
            XCTAssertTrue(runs[0].voltages.elementsEqual(runs[1].voltages) { $0.bitPattern == $1.bitPattern }, id)
            print("\(id): \(runs[1].skipped / 1e6) ms of \(Double(runs[1].cycles) / 125e3) ms counted at once")
        }
    }

    /// Instructions taken in stretches, the clock ticked once for each, leave the Pico where ticking it after every
    /// instruction would: the same circuits step for step, the same pin events, registers, cycles and time, to the bit
    func testStretchesLeaveThePicoWhereTickingEachInstructionWould() throws {
        defer { RP2040.runsStretches = true }
        try assertSameRuns { RP2040.runsStretches = $0 }
    }

    /// Stretches that go on past a register, from the clock brought up to it, leave the Pico where ending them there
    /// and starting the next would
    func testStretchesPastRegistersLeaveThePicoWhereEndingThemWould() throws {
        defer { RP2040.stretchesPastRegisters = true }
        try assertSameRuns { RP2040.stretchesPastRegisters = $0 }
    }

    /// Flash decoded once leaves the Pico where decoding every instruction as it runs would
    func testFlashDecodedOnceLeavesThePicoWhereDecodingEachWould() throws {
        defer { CortexM0.decodesFlashOnce = true }
        try assertSameRuns { CortexM0.decodesFlashOnce = $0 }
    }

    /// PIO delay loops' turns taken directly, where they only count down, leave the Pico where stepping each would
    func testQuietPIOTurnsLeaveThePicoWhereSteppingEachWould() throws {
        defer { RPPIOMachine.takesQuietTurns = true }
        try assertSameRuns { RPPIOMachine.takesQuietTurns = $0 }
    }

    /// Runs the Pico examples and the reference sketches with a setting off and on, and compares them to the bit
    private func assertSameRuns(_ setting: (Bool) -> Void, file: StaticString = #filePath, line: UInt = #line) throws {
        for id in ["pico-pcm5102", "pico-knob", "pico-melody"] {
            let circuit = Examples.example(id)!.circuit
            var runs: [(voltages: [Double], registers: [UInt32], cycles: Int, nanos: Double, serial: [UInt8])] = []
            for on in [false, true] {
                setting(on)
                let simulator = Simulator(circuit: circuit, timeStep: 1 / 48_000)
                simulator.errorControl = false
                let elements = simulator.circuit.elements
                let chipIndex = elements.firstIndex { $0.kind == .rp2040 }!
                var voltages: [Double] = []
                for _ in 0..<4_800 {
                    simulator.step()
                    for i in elements.indices where [.probe, .led, .speaker].contains(elements[i].kind) {
                        voltages.append(simulator.voltageAcross(i))
                    }
                }
                let pico = simulator.chip(chipIndex) as! Pico
                let core = pico.rp2040.core!
                runs.append((voltages, (0..<16).map { core.registers[$0] }, pico.cycles, pico.rp2040.clock.nanos,
                             pico.serialOutput))
            }
            XCTAssertEqual(runs[0].registers, runs[1].registers, id, file: file, line: line)
            XCTAssertEqual(runs[0].cycles, runs[1].cycles, id, file: file, line: line)
            XCTAssertEqual(runs[0].nanos.bitPattern, runs[1].nanos.bitPattern, id, file: file, line: line)
            XCTAssertEqual(runs[0].serial, runs[1].serial, id, file: file, line: line)
            XCTAssertEqual(runs[0].voltages.count, runs[1].voltages.count, id, file: file, line: line)
            XCTAssertTrue(runs[0].voltages.elementsEqual(runs[1].voltages) { $0.bitPattern == $1.bitPattern }, id,
                          file: file, line: line)
        }
        // and sketches on their own (timer interrupts, PWM, the ADC, USB serial, PIO, SPI and I2C), every pin watched
        for name in ["pico-kitchen", "pico-tone", "pico-buses", "pico-blink"] {
            let firmware = try image(name)
            var runs: [(events: [PinEvent], states: [[PinState]], registers: [UInt32], cycles: Int, nanos: Double,
                        serial: [UInt8])] = []
            for on in [false, true] {
                setting(on)
                let pico = Pico(firmware: firmware)
                pico.watchedPins = Array(0..<pico.pinCount)
                var events: [PinEvent] = []
                var states: [[PinState]] = []
                for _ in 0..<2_000 {
                    pico.run(cycles: 12_500)  // 100 µs
                    events += pico.takePinEvents()
                    states.append(pico.pinStates)
                }
                let core = pico.rp2040.core!
                runs.append((events, states, (0..<16).map { core.registers[$0] }, pico.cycles, pico.rp2040.clock.nanos,
                             pico.serialOutput))
            }
            XCTAssertGreaterThan(runs[1].events.count, 0, name, file: file, line: line)
            XCTAssertEqual(runs[0].events, runs[1].events, name, file: file, line: line)
            XCTAssertEqual(runs[0].states, runs[1].states, name, file: file, line: line)
            XCTAssertEqual(runs[0].registers, runs[1].registers, name, file: file, line: line)
            XCTAssertEqual(runs[0].cycles, runs[1].cycles, name, file: file, line: line)
            XCTAssertEqual(runs[0].nanos.bitPattern, runs[1].nanos.bitPattern, name, file: file, line: line)
            XCTAssertEqual(runs[0].serial, runs[1].serial, name, file: file, line: line)
        }
    }

    /// Compiles a sketch end to end when arduino-pico is installed (CI installs it through Chip Support)
    func testCompilesAndRunsAPicoSketchWhenAToolchainIsInstalled() throws {
        guard let toolchain = PicoToolchain.find() else {
            if ProcessInfo.processInfo.environment["JSPICE_REQUIRE_TOOLCHAIN"] != nil { XCTFail("no Pico toolchain found") }
            throw XCTSkip("no Pico toolchain installed")
        }
        let failed = SketchBuilder.build("void setup() { undefinedThing(); }\nvoid loop() {}\n", toolchain: toolchain)
        XCTAssertFalse(failed.succeeded)
        XCTAssertEqual(failed.errors.first?.line, 1, failed.log)
        let result = SketchBuilder.build(PicoSketches.knobCode, toolchain: toolchain)
        let firmware = try XCTUnwrap(result.firmware, result.log)
        let pico = Pico(firmware: [UInt8](firmware))
        var volts = [Double](repeating: 0, count: pico.pinCount)
        volts[23] = 1.65  // GP26
        pico.pinVoltages = volts
        pico.run(cycles: 125_000 * 450)
        XCTAssertTrue(String(decoding: pico.serialOutput, as: UTF8.self).hasPrefix("A0: 2048  (1.65 V)\r\n"),
                      String(decoding: pico.serialOutput, as: UTF8.self))
    }
}
