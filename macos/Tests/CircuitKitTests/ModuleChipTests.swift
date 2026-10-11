import XCTest
@testable import CircuitKit

/// The chips of Eurorack modules' AVR firmware: the ATmega168 and 88 (less memory than the 328P; the 88's interrupt
/// vectors a word each) and the 328P at Mutable Instruments' 20 MHz, and firmware files loaded as a programmer flashes
/// them (Intel HEX, or a raw image)
final class ModuleChipTests: XCTestCase {
    /// Timer 2's compare match A interrupt every 16 000 cycles (CTC, /64, OCR2A 249) toggles D13 and counts; the main
    /// loop shows the count's low six bits on D2-D7 (tools: avr-gcc 7.3, -Os, built for each chip)
    static let tickSource = """
        ISR(TIMER2_COMPA_vect) { PINB = _BV(PB5); ++ticks; }
        int main(void) {
            DDRB = _BV(PB5); DDRD = 0xFC; TCCR2A = _BV(WGM21); TCCR2B = _BV(CS22); OCR2A = 249; TIMSK2 = _BV(OCIE2A); sei();
            for (;;) { unsigned int t; cli(); t = ticks; sei(); PORTD = (unsigned char)(t << 2); }
        }
        """

    /// For the ATmega88, as avr-objcopy -O ihex wrote it
    static let tick88Hex = """
        :1000000019C028C027C026C025C024C023C023C0D3
        :1000100021C020C01FC01EC01DC01CC01BC01AC0F4
        :1000200019C018C017C016C015C014C013C012C024
        :1000300011C010C011241FBECFEFD4E0DEBFCDBF72
        :1000400021E0A0E0B1E001C01D92A230B207E1F7CB
        :100050001BD034C0D5CF1F920F920FB60F92112430
        :100060008F939F9380E283B9809100019091010169
        :10007000019690930101809300019F918F910F90C1
        :100080000FBE0F901F90189580E284B98CEF8AB94B
        :1000900082E08093B00094E09093B10099EF909348
        :1000A000B300809370007894F8948091000190914F
        :1000B00001017894880F880F8BB9F6CFF894FFCFA1
        :00000001FF
        """

    static let tick168 = """
        DJQ0AAyURgAMlEYADJRGAAyURgAMlEYADJRGAAyUSAAMlEYADJRGAAyURgAMlEYADJRGAAyURgAMlEYADJRGAAyURgAMlEYA
        DJRGAAyURgAMlEYADJRGAAyURgAMlEYADJRGAAyURgARJB++z+/U4N6/zb8h4KDgseABwB2SojCyB+H3DpRhAAyUewAMlAAA
        H5IPkg+2D5IRJI+Tn5OA4oO5gJEAAZCRAQEBlpCTAQGAkwABn5GPkQ+QD74PkB+QGJWA4oS5jO+KuYLggJOwAJTgkJOxAJnv
        kJOzAICTcAB4lPiUgJEAAZCRAQF4lIgPiA+LufbP+JT/zw==
        """

    static let tick328 = """
        DJQ0AAyURgAMlEYADJRGAAyURgAMlEYADJRGAAyUSAAMlEYADJRGAAyURgAMlEYADJRGAAyURgAMlEYADJRGAAyURgAMlEYA
        DJRGAAyURgAMlEYADJRGAAyURgAMlEYADJRGAAyURgARJB++z+/Y4N6/zb8h4KDgseABwB2SojCyB+H3DpRhAAyUewAMlAAA
        H5IPkg+2D5IRJI+Tn5OA4oO5gJEAAZCRAQEBlpCTAQGAkwABn5GPkQ+QD74PkB+QGJWA4oS5jO+KuYLggJOwAJTgkJOxAJnv
        kJOzAICTcAB4lPiUgJEAAZCRAQF4lIgPiA+LufbP+JT/zw==
        """

    private func image(_ base64: String) -> Data {
        Data(base64Encoded: base64.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: " ", with: ""))!
    }

    /// The count on D2-D7, as the chip drives them
    private func shownCount(_ chip: AVR) -> Int {
        (2...7).reduce(0) { count, pin in
            if case .output(high: true) = chip.pinStates[pin] { return count | 1 << (pin - 2) }
            return count
        }
    }

    func testIntelHexDecodesToTheImageItsRecordsPlace() throws {
        // two records, the second past a gap, with an extended linear address of 0 and the end record
        let text = ":020000040000FA\n:0400000001020304F2\n:02000800AABB91\n:00000001FF\n"
        XCTAssertEqual(try FirmwareFile.decode(Data(text.utf8)), Data([1, 2, 3, 4, 0xFF, 0xFF, 0xFF, 0xFF, 0xAA, 0xBB]))
        // a Pico's image, placed at its flash (0x10000000), from the flash's start
        let pico = ":020000041000EA\n:020000000102FB\n:00000001FF\n"
        XCTAssertEqual(try FirmwareFile.decode(Data(pico.utf8)), Data([1, 2]))
        XCTAssertThrowsError(try FirmwareFile.decode(Data(":0400000001020304F3\n".utf8))) { error in
            XCTAssertEqual(error as? FirmwareFile.DecodeError, .badChecksum(line: 1))
        }
        // anything else is a raw image
        XCTAssertEqual(try FirmwareFile.decode(Data([0x0C, 0x94, 0x34, 0x00])), Data([0x0C, 0x94, 0x34, 0x00]))
        // avr-objcopy's HEX holds the same image as its binary
        let fromHex = try FirmwareFile.decode(Data(Self.tick88Hex.utf8))
        XCTAssertEqual(fromHex.count, 192)
        XCTAssertEqual(Array(fromHex.prefix(4)), [0x19, 0xC0, 0x28, 0xC0], "an RJMP to the startup code, then the vectors'")
    }

    func testATmega88TakesItsInterruptsFromOneWordVectors() throws {
        let chip = AVR(firmware: [UInt8](try FirmwareFile.decode(Data(Self.tick88Hex.utf8))), variant: .atmega88)
        // its 1 KB of RAM ends at 0x4FF, where the startup code puts the stack
        chip.run(cycles: 1_601_000)
        XCTAssertEqual(shownCount(chip), 100 % 64, "a hundred interrupts in 1.6 million cycles")
        XCTAssertEqual(AVRVariant.atmega88.flashBytes, 8192)
        XCTAssertEqual(AVRVariant.atmega168.flashBytes, 16_384)
    }

    func testATmega168RunsFirmwareBuiltForIt() {
        let chip = AVR(firmware: [UInt8](image(Self.tick168)), variant: .atmega168)
        chip.run(cycles: 1_601_000)
        XCTAssertEqual(shownCount(chip), 100 % 64)
    }

    func testAnUnosChipRunsAtThePartsClock() throws {
        // D13 toggles every 16 000 cycles: every millisecond at 16 MHz, every 0.8 ms at 20 MHz
        func toggles(clock: Double?, chip: Double = 0, firmware: String = ModuleChipTests.tick328) throws -> Int {
            var params: [String: Double] = ["chip": chip]
            if let clock { params["clock"] = clock }
            var part = NetlistPart(kind: .atmega328p, name: "U1", params: params, connections: ["d13": "led"])
            part.firmware = image(firmware)
            let circuit = try SchematicLayout.layout([
                part,
                NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 10_000], connections: ["a": "led", "b": "GND"]),
                NetlistPart(kind: .probe, name: "P1", connections: ["plus": "led", "minus": "GND"]),
            ])
            let simulator = Simulator(circuit: circuit, timeStep: 2e-5)
            let probe = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "P1" })
            var high = false
            var count = 0
            while simulator.time < 0.02 {
                simulator.step()
                XCTAssertFalse(simulator.isFailed, simulator.problems.joined(separator: " "))
                if simulator.isFailed { break }
                let now = simulator.voltageAcross(probe) > 2.5
                if now != high { count += 1 }
                high = now
            }
            return count
        }
        XCTAssertEqual(Double(try toggles(clock: nil)), 20, accuracy: 1)
        XCTAssertEqual(Double(try toggles(clock: 20e6)), 25, accuracy: 1)
        // the part set to an ATmega168 runs its own firmware
        XCTAssertEqual(Double(try toggles(clock: nil, chip: 1, firmware: ModuleChipTests.tick168)), 20, accuracy: 1)
        let element = Element(kind: .atmega328p, a: .zero, b: GridPoint(0, 13), params: ["chip": 2, "clock": 20e6])
        XCTAssertEqual(element.model?.name, "ATmega88")
        XCTAssertEqual(Board.uno.avrVariant(for: element)?.name, "ATmega88")
        XCTAssertEqual(Board.uno.avrVariant(for: element)?.clock, 20e6)
        XCTAssertEqual(Board.uno.flashSize(for: element), 8192)
    }
}
