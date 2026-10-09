import XCTest
@testable import CircuitKit

/// The converters, bit by bit (an MCP4822 and an MCP3008 on SPI, an MCP4725 on I²C, a PCM5102 on I²S) and with the
/// firmware of their examples; the SSM2166's compression and gate; the THAT4301's scales; the 3PDT footswitch
final class ConverterTests: XCTestCase {
    private static let sqrt2: Double = 2.0.squareRoot()
    /// The PCM5102's full scale, peak
    private static let i2sPeak: Double = 2.1 * ConverterTests.sqrt2

    private func part(_ kind: ElementKind, _ name: String, _ params: [String: Double] = [:], _ connections: [String: String]) -> NetlistPart {
        NetlistPart(kind: kind, name: name, params: params, connections: connections)
    }

    private func r(_ name: String, _ ohms: Double, _ a: String, _ b: String) -> NetlistPart {
        part(.resistor, name, ["resistance": ohms], ["a": a, "b": b])
    }

    private func probe(_ name: String, _ plus: String) -> NetlistPart {
        part(.probe, name, [:], ["plus": plus, "minus": "GND"])
    }

    /// A logic part's state after its inputs take each of `levels` in turn
    private func drive(_ kind: ElementKind, _ levels: [UInt32], from start: LogicState = LogicState()) -> LogicState {
        levels.reduce(start) { Logic.next(kind, $0, inputs: $1) }
    }

    /// SPI mode 0, MSB first, on CS (bit 0), SCK (bit 1) and SDI (bit 2), with `extra` bits always set: each bit set up
    /// with the clock low, then clocked in on the rising edge
    private func spiWord(_ word: UInt32, bits: Int, extra: UInt32 = 0) -> [UInt32] {
        var levels: [UInt32] = [extra | 1, extra]
        for k in (0..<bits).reversed() {
            let sdi: UInt32 = word >> UInt32(k) & 1 != 0 ? 4 : 0
            levels += [extra | sdi, extra | sdi | 2]
        }
        return levels + [extra, extra | 1]
    }

    func testMCP4822WritesEachChannelFromItsWordsBit15() {
        // A: gain 1, on, code 2048; B: gain 2 (bit 13 clear), on, code 1024; LDAC (bit 3) low
        let state = drive(.dualDac, spiWord(0x3000 | 2048, bits: 16) + spiWord(0x9000 | 1024, bits: 16))
        XCTAssertEqual(Logic.dualDacOutput(state.count, channel: 0, supply: 5), 1.024, accuracy: 1e-9)
        XCTAssertEqual(Logic.dualDacOutput(state.count, channel: 1, supply: 5), 1.024, accuracy: 1e-9)
        // with LDAC high the outputs wait for it
        let held = drive(.dualDac, spiWord(0x3000 | 4000, bits: 16, extra: 8), from: state)
        XCTAssertEqual(Logic.dualDacOutput(held.count, channel: 0, supply: 5), 1.024, accuracy: 1e-9)
        let released = drive(.dualDac, [0], from: held)
        XCTAssertEqual(Logic.dualDacOutput(released.count, channel: 0, supply: 5), 2.048 * 4000 / 4096, accuracy: 1e-9)
    }

    func testMCP3008SendsANullBitThenTheTenBitCodeMSBFirst() {
        // the three bytes Arduino code sends: 0x01, 0x80 (single-ended channel 0), 0x00; the code read back is the low
        // two bits of the second reply byte and the third
        var state = drive(.spiAdc, [1, 0])
        var reply: [UInt32] = []
        let bytes: [UInt32] = [0x01, 0x80, 0x00]
        for byte in bytes {
            var received: UInt32 = 0
            for k in (0..<8).reversed() {
                let din: UInt32 = byte >> UInt32(k) & 1 != 0 ? 4 : 0
                state = Logic.next(.spiAdc, state, inputs: din)
                if state.phase >= 0.5 {
                    // the circuit's sample: 0x2A5
                    state.latch = 0x2A5
                    state.phase = 0
                }
                // the master reads DOUT on the rising edge
                received = received << 1 | UInt32(state.count)
                state = Logic.next(.spiAdc, state, inputs: din | 2)
                if state.phase >= 0.5 {
                    state.latch = 0x2A5
                    state.phase = 0
                }
            }
            reply.append(received)
        }
        XCTAssertEqual((reply[1] & 0x03) << 8 | reply[2], 0x2A5)
        // and the null bit before the code
        XCTAssertEqual(reply[1] & 0x04, 0)
        // CS high lets DOUT go and starts over
        state = Logic.next(.spiAdc, state, inputs: 1)
        XCTAssertEqual(state.bits, 0)
        XCTAssertEqual(state.count, 0)
    }

    /// I²C as a master puts it on SCL (bit 0) and SDA (bit 1), A0 (bit 2) low; returns the target's state and whether
    /// each byte was acknowledged
    private func i2c(_ bytes: [UInt32], from start: LogicState = LogicState(inputs: 3)) -> (LogicState, [Bool]) {
        var state = start
        func set(scl: Bool, sda: Bool) { state = Logic.next(.i2cDac, state, inputs: (scl ? 1 : 0) | (sda ? 2 : 0)) }
        set(scl: true, sda: true)
        set(scl: true, sda: false)  // START
        set(scl: false, sda: false)
        var acknowledged: [Bool] = []
        for byte in bytes {
            for k in (0..<8).reversed() {
                let bit = byte >> UInt32(k) & 1 != 0
                set(scl: false, sda: bit)
                set(scl: true, sda: bit)
                set(scl: false, sda: bit)
            }
            // the ninth clock: the master lets SDA go and reads it
            set(scl: false, sda: true)
            set(scl: true, sda: true)
            acknowledged.append(Logic.acknowledging(state))
            set(scl: false, sda: true)
        }
        set(scl: false, sda: false)
        set(scl: true, sda: false)
        set(scl: true, sda: true)  // STOP
        return (state, acknowledged)
    }

    func testMCP4725AcknowledgesItsAddressAndTakesBothWriteForms() {
        // the write-DAC command: 0x40, D11–D4, D3–D0 << 4
        let (written, acks) = i2c([0x60 << 1, 0x40, 0xAB, 0xC0])
        XCTAssertEqual(acks, [true, true, true, true])
        XCTAssertEqual(written.count, 0xABC)
        XCTAssertEqual(Logic.i2cDacOutput(written.count, supply: 5), 5.0 * 0xABC / 4096, accuracy: 1e-9)
        XCTAssertFalse(Logic.acknowledging(written))
        // fast mode: 0 0 PD1 PD0 D11–D8, D7–D0
        let (fast, _) = i2c([0x60 << 1, 0x01, 0x23], from: written)
        XCTAssertEqual(fast.count, 0x123)
        // another address, or a read, is left alone
        let (other, otherAcks) = i2c([0x61 << 1, 0x0F, 0xFF], from: fast)
        XCTAssertEqual(otherAcks, [false, false, false])
        XCTAssertEqual(other.count, 0x123)
        let (read, readAcks) = i2c([0x60 << 1 | 1], from: fast)
        XCTAssertEqual(readAcks, [false])
        XCTAssertEqual(read.count, 0x123)
        // powered down (PD bits set): 0 V
        let (off, _) = i2c([0x60 << 1, 0x30, 0x00], from: fast)
        XCTAssertEqual(Logic.i2cDacOutput(off.count, supply: 5), 0)
    }

    func testPCM5102ReadsEachChannelsWordOneBCKAfterLRCK() {
        // BCK (bit 0), DIN (bit 1), LRCK (bit 2): frames of two 16-bit words, left 0x4000, right 0xC000 (−0.5 FS)
        var levels: [UInt32] = []
        func frame(_ left: UInt32, _ right: UInt32) {
            // LRCK changes on a falling edge, a BCK before each word's MSB: the last bit of the previous word is sent with
            // the new LRCK
            var bits: [UInt32] = []
            for k in 0..<16 { bits.append(left >> UInt32(15 - k) & 1) }
            for k in 0..<16 { bits.append(right >> UInt32(15 - k) & 1) }
            for (k, bit) in bits.enumerated() {
                let lr: UInt32 = (k + 1) % 32 >= 16 ? 4 : 0
                let din: UInt32 = bit != 0 ? 2 : 0
                levels += [lr | din, lr | din | 1]
            }
        }
        for _ in 0..<3 { frame(0x4000, 0xC000) }
        let state = drive(.i2sDac, levels)
        XCTAssertEqual(Logic.i2sOutput(Int32(bitPattern: state.latch)), 0.5 * Self.i2sPeak, accuracy: 1e-6)
        XCTAssertEqual(Logic.i2sOutput(Int32(truncatingIfNeeded: state.count)), -0.5 * Self.i2sPeak, accuracy: 1e-6)
    }

    /// Runs `circuit` for `seconds` at `dt`, calling `sample` with the time and the simulator from `from` on
    private func run(_ circuit: Circuit, dt: Double, seconds: Double, from: Double = 0,
                     sample: (Double, Simulator) -> Void, file: StaticString = #filePath, line: UInt = #line) {
        let simulator = Simulator(circuit: circuit, timeStep: dt)
        while simulator.time < seconds {
            simulator.step()
            XCTAssertFalse(simulator.isFailed, simulator.problems.joined(separator: " "), file: file, line: line)
            if simulator.isFailed { return }
            if simulator.time >= from { sample(simulator.time, simulator) }
        }
    }

    private func index(_ circuit: Circuit, _ name: String) throws -> Int {
        try XCTUnwrap(circuit.elements.firstIndex { $0.name == name }, name)
    }

    func testArduinoReadsTheMCP3008AndWritesTheMCP4725() throws {
        let circuit = Examples.arduinoADCToDAC.circuit
        let dac = try index(circuit, "DAC")
        let arduino = try index(circuit, "U1")
        var last = 0.0
        var serial = ""
        // (the sketch prints every 200 ms, the first time at 200 ms)
        run(circuit, dt: 1e-5, seconds: 0.21, from: 0.2) { _, simulator in
            last = simulator.voltageAcross(dac)
            serial = String(decoding: simulator.chip(arduino)?.serialOutput ?? [], as: UTF8.self)
        }
        // the knob at 0.6: 3 V, read as 614 of 1024 and written as 2456 of 4096
        XCTAssertTrue(serial.contains("CH0: 614"), serial)
        let code: Double = 2456
        let divider: Double = 10_000.0 / 10_010.0
        XCTAssertEqual(last, 5.0 * code / 4096 * divider, accuracy: 0.01)
    }

    func testArduinoWritesBothHalvesOfTheMCP4822() throws {
        let circuit = Examples.arduinoDualDAC.circuit
        let a = try index(circuit, "OUTA")
        let b = try index(circuit, "OUTB")
        var range = (aLow: Double.infinity, aHigh: -Double.infinity, bLow: Double.infinity, bHigh: -Double.infinity)
        run(circuit, dt: 1e-4, seconds: 0.6, from: 0.05) { _, simulator in
            let (va, vb) = (simulator.voltageAcross(a), simulator.voltageAcross(b))
            range = (min(range.aLow, va), max(range.aHigh, va), min(range.bLow, vb), max(range.bHigh, vb))
        }
        // about 2.048 × (2048 ± 2000) / 4096: 0.02 to 2.02 V
        XCTAssertEqual(range.aHigh, 2.02, accuracy: 0.05)
        XCTAssertEqual(range.aLow, 0.02, accuracy: 0.05)
        XCTAssertEqual(range.bHigh, 2.02, accuracy: 0.05)
        XCTAssertEqual(range.bLow, 0.02, accuracy: 0.05)
    }

    func testPicoPlaysASineThroughThePCM5102() throws {
        let circuit = Examples.picoI2S.circuit
        let speaker = try index(circuit, "SPK1")
        var crossings: [Double] = []
        var peak = 0.0
        var last = 0.0
        run(circuit, dt: 1 / 48_000, seconds: 0.12, from: 0.06) { t, simulator in
            let v = simulator.voltageAcross(speaker)
            if last < 0 && v >= 0 { crossings.append(t) }
            last = v
            peak = max(peak, abs(v))
        }
        XCTAssertGreaterThan(crossings.count, 5)
        if let first = crossings.first, let final = crossings.last, crossings.count > 1 {
            XCTAssertEqual(Double(crossings.count - 1) / (final - first), 440, accuracy: 10)
        }
        // 16 000 of 32 768: about 1.45 V
        let fraction: Double = 16_000.0 / 32_768.0
        let divider: Double = 10_000.0 / 10_100.0
        XCTAssertEqual(peak, fraction * Self.i2sPeak * divider, accuracy: 0.1)
    }

    /// The SSM2166's output for a 1 kHz sine of `amplitude` into it, once its detector has settled
    private func agcOutput(amplitude: Double, ratio: Double = 3) throws -> Double {
        let circuit = try SchematicLayout.layout([
            part(.acVoltage, "VS", ["amplitude": amplitude, "frequency": 1000], ["plus": "in", "minus": "GND"]),
            part(.agcPreamp, "U1", Examples.model(.agcPreamp, "SSM2166").merging(["ratio": ratio, "limit": 20]) { $1 },
                 ["in": "in", "gnd": "GND", "out": "out"]),
            r("RL", 10_000, "out", "GND"),
            probe("OUT", "out"),
        ])
        let out = try index(circuit, "OUT")
        var peak = 0.0
        run(circuit, dt: 1e-5, seconds: 0.2, from: 0.18) { _, simulator in peak = max(peak, abs(simulator.voltageAcross(out))) }
        return peak
    }

    func testSSM2166CompressesAboveItsRotationPointAndGatesBelowItsThreshold() throws {
        // the preamp's ×10 puts these 20 dB apart at 0.28 and 2.8 V peak (0.2 and 2 V RMS), both above the 0.1 V rotation
        // point: out of a 3:1 compressor they come out 20/3 dB apart
        let soft = try agcOutput(amplitude: 0.028)
        let loud = try agcOutput(amplitude: 0.28)
        XCTAssertEqual(20 * log10(loud / soft), 20.0 / 3, accuracy: 0.5)
        // between the gate and the rotation point: gain 10
        XCTAssertEqual(try agcOutput(amplitude: 0.005), 0.05, accuracy: 0.003)
        // 6 dB below the 2 mV gate (preamp out 1 mV RMS), the gain falls by 6 dB more
        let quiet = try agcOutput(amplitude: 0.0001 * Self.sqrt2)
        XCTAssertEqual(20 * log10(quiet / (0.001 * Self.sqrt2)), -6, accuracy: 0.5)
    }

    func testTHAT4301ScalesAre6Point1MillivoltsPerDB() throws {
        let circuit = try SchematicLayout.layout([
            part(.dcVoltage, "VP", ["voltage": 15], ["plus": "+15V", "minus": "GND"]),
            part(.acVoltage, "VS", ["amplitude": 0.775 * Self.sqrt2 / 10, "frequency": 1000], ["plus": "in", "minus": "GND"]),
            part(.dcVoltage, "VEC", ["voltage": 0.061], ["plus": "ec", "minus": "GND"]),
            part(.analogEngine, "U1", Examples.model(.analogEngine, "THAT4301"),
                 ["in": "in", "ec": "ec", "out": "out", "rmsIn": "in", "rmsOut": "rms", "oaMinus": "oo", "oaPlus": "GND", "oaOut": "oo"]),
            r("RL", 10_000, "out", "GND"),
            probe("OUT", "out"),
            probe("RMS", "rms"),
        ])
        let (out, rms) = (try index(circuit, "OUT"), try index(circuit, "RMS"))
        var peak = 0.0
        var level = 0.0
        run(circuit, dt: 1e-5, seconds: 0.5, from: 0.48) { _, simulator in
            peak = max(peak, abs(simulator.voltageAcross(out)))
            level = simulator.voltageAcross(rms)
        }
        // −20 dB under 0.775 V RMS: the detector at −122 mV; EC− at 61 mV: −10 dB through the VCA
        XCTAssertEqual(level, -0.122, accuracy: 0.01)
        XCTAssertEqual(20 * log10(peak / (0.0775 * Self.sqrt2)), -10, accuracy: 0.3)
    }

    func testFootswitchRoutesEachPoleToItsThrow() throws {
        func voltages(pressed: Bool) throws -> (bypass: Double, effect: Double, led: Double) {
            var circuit = try SchematicLayout.layout([
                part(.dcVoltage, "VS", ["voltage": 1], ["plus": "in", "minus": "GND"]),
                part(.footswitch, "SW1", [:], ["c1": "in", "a1": "byp", "b1": "fx", "c2": "out", "a2": "byp", "b2": "ret",
                                              "c3": "k", "a3": "open", "b3": "GND"]),
                r("R1", 1000, "byp", "GND"),
                r("R2", 1000, "fx", "GND"),
                r("R3", 1000, "ret", "GND"),
                r("R4", 1000, "out", "GND"),
                part(.dcVoltage, "VL", ["voltage": 5], ["plus": "v5", "minus": "GND"]),
                r("R5", 1000, "v5", "k"),
                r("R6", 1000, "open", "GND"),
                probe("BYP", "byp"),
                probe("FX", "fx"),
                probe("K", "k"),
            ])
            let switchIndex = try index(circuit, "SW1")
            circuit.elements[switchIndex].closed = pressed
            let simulator = Simulator(circuit: circuit, timeStep: 1e-4)
            simulator.step()
            XCTAssertTrue(simulator.problems.isEmpty, simulator.problems.joined(separator: " "))
            return (simulator.voltageAcross(try index(circuit, "BYP")), simulator.voltageAcross(try index(circuit, "FX")),
                    simulator.voltageAcross(try index(circuit, "K")))
        }
        let bypassed = try voltages(pressed: false)
        XCTAssertEqual(bypassed.bypass, 1, accuracy: 1e-9)
        XCTAssertEqual(bypassed.effect, 0, accuracy: 1e-9)
        // (less what the 3PDT's contact resistance takes)
        XCTAssertEqual(bypassed.led, 2.5, accuracy: 1e-6)
        let engaged = try voltages(pressed: true)
        XCTAssertEqual(engaged.bypass, 0, accuracy: 1e-9)
        XCTAssertEqual(engaged.effect, 1, accuracy: 1e-9)
        XCTAssertEqual(engaged.led, 0, accuracy: 1e-9)
    }
}
