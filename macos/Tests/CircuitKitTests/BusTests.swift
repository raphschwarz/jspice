import XCTest
@testable import CircuitKit

/// The world outside a microcontroller's SPI and I²C pins, played at the pin level: MISO wired back to MOSI, and an
/// I²C device that answers at one address, reading SDA and SCL and pulling SDA low as a real one would
final class BusHarness {
    /// An I²C device: acknowledges its address and every byte written to it, and sends `replies` when read
    final class Device {
        let address: UInt8
        let replies: [UInt8]
        private(set) var written: [UInt8] = []
        /// Whether the device pulls SDA low
        private(set) var pullsSDA = false
        private enum Mode { case idle, address, write, read }
        private var mode = Mode.idle
        private var bits = 0
        private var byte: UInt8 = 0
        private var acknowledging = false
        private var readNext = false
        private var current: UInt8 = 0
        private var replyIndex = 0
        private var masterAcknowledged = false
        private var lastSCL = true
        private var lastSDA = true

        init(address: UInt8, replies: [UInt8]) {
            self.address = address
            self.replies = replies
        }

        private func reply() -> UInt8 { replyIndex < replies.count ? replies[replyIndex] : 0xFF }

        /// The bus lines as they are now (both pulled up unless something pulls them low)
        func observe(scl: Bool, sda: Bool) {
            defer {
                lastSCL = scl
                lastSDA = sda
            }
            if lastSCL && scl {
                if lastSDA && !sda {
                    // START (or a repeated one)
                    mode = .address
                    bits = 0
                    byte = 0
                    acknowledging = false
                    pullsSDA = false
                } else if !lastSDA && sda {
                    mode = .idle
                    pullsSDA = false
                }
                return
            }
            if !lastSCL && scl { rising(sda) }
            if lastSCL && !scl { falling() }
        }

        private func rising(_ sda: Bool) {
            switch mode {
            case .idle: return
            case .read:
                if acknowledging { masterAcknowledged = !sda }
            case .address, .write:
                if !acknowledging {
                    byte = byte << 1 | (sda ? 1 : 0)
                    bits += 1
                }
            }
        }

        private func startReply() {
            current = reply()
            bits = 1
            pullsSDA = current & 0x80 == 0
        }

        private func falling() {
            switch mode {
            case .idle: return
            case .read:
                if acknowledging {
                    acknowledging = false
                    if masterAcknowledged {
                        replyIndex += 1
                        startReply()
                    } else {
                        pullsSDA = false
                        mode = .idle
                    }
                } else if bits == 8 {
                    pullsSDA = false  // the master acknowledges
                    acknowledging = true
                } else {
                    pullsSDA = current & (0x80 >> bits) == 0
                    bits += 1
                }
            case .address, .write:
                if acknowledging {
                    acknowledging = false
                    pullsSDA = false
                    if mode == .address && readNext {
                        mode = .read
                        startReply()
                    } else {
                        mode = .write
                        bits = 0
                        byte = 0
                    }
                } else if bits == 8 {
                    if mode == .address {
                        guard byte >> 1 == address else {
                            mode = .idle
                            return
                        }
                        readNext = byte & 1 != 0
                    } else {
                        written.append(byte)
                    }
                    pullsSDA = true
                    acknowledging = true
                }
            }
        }
    }

    let chip: Microcontroller
    let sda: Int, scl: Int, mosi: Int, miso: Int
    let device: Device
    /// When SCL rose, in clock cycles
    private(set) var sclRises: [Int] = []

    init(chip: Microcontroller, sda: Int, scl: Int, mosi: Int, miso: Int, device: Device) {
        self.chip = chip
        self.sda = sda
        self.scl = scl
        self.mosi = mosi
        self.miso = miso
        self.device = device
    }

    /// A line is high unless something drives it low (the bus has pull-ups)
    private func released(_ state: PinState) -> Bool { state != .output(high: false) }

    func run(cycles total: Int, slice: Int) {
        let end = chip.cycles + total
        var lastSCL = true
        while chip.cycles < end {
            let states = chip.pinStates
            let sclLine = released(states[scl])
            device.observe(scl: sclLine, sda: released(states[sda]) && !device.pullsSDA)
            let sdaLine = released(states[sda]) && !device.pullsSDA
            if sclLine && !lastSCL { sclRises.append(chip.cycles) }
            lastSCL = sclLine
            var volts = [Double](repeating: 0, count: chip.pinCount)
            volts[sda] = sdaLine ? chip.supply : 0
            volts[scl] = sclLine ? chip.supply : 0
            volts[miso] = states[mosi] == .output(high: true) ? chip.supply : 0
            chip.pinVoltages = volts
            chip.run(cycles: slice)
        }
    }
}

final class BusTests: XCTestCase {
    private func image(_ name: String) throws -> [UInt8] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "bin", subdirectory: "Fixtures"))
        return [UInt8](try Data(contentsOf: url))
    }

    /// tools/avr-reference/sketches/buses.ino: SPI.transfer with MISO looped back, Wire to three addresses (only 0x42
    /// answers), and a read of two bytes from it
    private func checkAVRBuses(_ firmware: String, variant: AVRVariant, sda: Int, scl: Int, mosi: Int, miso: Int) throws {
        let chip = AVR(firmware: try image(firmware), variant: variant)
        let harness = BusHarness(chip: chip, sda: sda, scl: scl, mosi: mosi, miso: miso,
                                 device: BusHarness.Device(address: 0x42, replies: [0x5A, 0xA5]))
        harness.run(cycles: 16_000 * 30, slice: 2)
        XCTAssertEqual(String(decoding: chip.serialOutput, as: UTF8.self),
                       "spi A5 3C\r\ni2c 41 2\r\ni2c 42 0\r\ni2c 43 2\r\nread 5A A5\r\n")
        XCTAssertEqual(harness.device.written, [0x10])
        // 100 kHz: 160 cycles a clock within a byte
        let gaps = zip(harness.sclRises.dropFirst(), harness.sclRises).map { $0 - $1 }
        XCTAssertEqual(gaps.sorted()[gaps.count / 2], 160, accuracy: 2)
    }

    func testAVRSPIAndI2COnTheUno() throws {
        try checkAVRBuses("avr-buses-uno", variant: .atmega328p, sda: 18, scl: 19, mosi: 11, miso: 12)
    }

    func testAVRSPIAndI2COnTheMega() throws {
        try checkAVRBuses("avr-buses-mega", variant: .atmega2560, sda: 20, scl: 21, mosi: 51, miso: 50)
    }

    /// tools/pico-reference/sketches/buses.ino: the same on the Pico, SPI0 on GP16-19 and Wire on GP4 and GP5. Its
    /// Wire answers 4 for a byte not acknowledged, and the report repeats until USB serial is up.
    func testRP2040SPIAndI2C() throws {
        let pico = Pico(firmware: try image("pico-buses"))
        let harness = BusHarness(chip: pico, sda: 4, scl: 5, mosi: 19, miso: 16,
                                 device: BusHarness.Device(address: 0x42, replies: [0x5A, 0xA5]))
        let report = "spi a5 3c\r\ni2c 41 4\r\ni2c 42 0\r\ni2c 43 4\r\nread 5a a5\r\n"
        for _ in 0..<100 {
            harness.run(cycles: 1_250_000, slice: 25)  // 10 ms
            if String(decoding: pico.serialOutput, as: UTF8.self).contains(report) { break }
        }
        XCTAssertTrue(String(decoding: pico.serialOutput, as: UTF8.self).contains(report),
                      String(decoding: pico.serialOutput, as: UTF8.self))
        XCTAssertEqual(harness.device.written, [0x10])
        // 100 kHz from a 125 MHz clk_sys: 1250 cycles a clock within a byte
        let gaps = zip(harness.sclRises.dropFirst(), harness.sclRises).map { $0 - $1 }
        XCTAssertEqual(gaps.sorted()[gaps.count / 2], 1250, accuracy: 30)
    }
}
