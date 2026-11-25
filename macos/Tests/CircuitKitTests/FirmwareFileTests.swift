@testable import CircuitKit
import XCTest

/// A firmware file is untrusted: a HEX file whose records lie far apart must be refused with a reason, before an
/// image as large as the space between them is made, while every real toolchain's output still loads.
final class FirmwareFileTests: XCTestCase {
    /// An Intel HEX record
    func record(_ type: UInt8, _ address: Int, _ bytes: [UInt8]) -> String {
        let fields = [UInt8(bytes.count), UInt8(address >> 8 & 0xFF), UInt8(address & 0xFF), type] + bytes
        let sum = UInt8(truncatingIfNeeded: 0x100 - Int(fields.reduce(UInt8(0)) { $0 &+ $1 }))
        return ":" + (fields + [sum]).map { String(format: "%02X", $0) }.joined()
    }

    /// Records of `bytes` at each address (32-bit, through extended linear address records), then the end record
    func hex(_ placed: [(Int, [UInt8])]) -> Data {
        var lines: [String] = []
        for (address, bytes) in placed {
            lines.append(record(4, 0, [UInt8(address >> 24 & 0xFF), UInt8(address >> 16 & 0xFF)]))
            lines.append(record(0, address & 0xFFFF, bytes))
        }
        lines.append(":00000001FF")
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    func assertTooLarge(_ data: Data, mentions: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try FirmwareFile.decode(data), file: file, line: line) { error in
            guard case .tooLarge = error as? FirmwareFile.DecodeError else {
                return XCTFail("\(error)", file: file, line: line)
            }
            let text = "\(error)"
            for word in mentions + ["spans", "EEPROM", "option-byte"] {
                XCTAssertTrue(text.contains(word), "\(text) does not mention \(word)", file: file, line: line)
            }
        }
    }

    func testAHexFileWithRecordsFarPastTheFlashIsRefused() {
        // avr-objcopy without -R .eeprom -R .fuse: the EEPROM's data at 0x810000, the fuses at 0x820000
        assertTooLarge(hex([(0, [0x0C, 0x94, 0x34, 0x00]), (0x81_0000, [1, 2]), (0x82_0000, [0xFF, 0xDE, 0xFD])]),
                       mentions: ["0x00000000 to 0x00820002", "8.1 MB"])
        // an STM32's image with its option bytes
        assertTooLarge(hex([(0x0800_0000, [0, 0x10, 0, 0x20]), (0x1FFF_C000, [0xAA, 0xEF])]),
                       mentions: ["0x08000000 to 0x1FFFC001"])
        // a stray record at the top of the 4 GB space (this made a 4 GB image)
        assertTooLarge(hex([(0, [1]), (0xFFFF_FFF0, [2])]), mentions: ["4096.0 MB", "0xFFFFFFF0"])
    }

    func testRealToolchainsLayoutsStillLoad() throws {
        // an ATmega2560's sketch with its bootloader at the top of its 256 KB
        let mega = try FirmwareFile.decode(hex([(0, [0x0C, 0x94]), (0x3_E000, [0x11, 0x24])]))
        XCTAssertEqual(mega.count, 0x3_E002)
        XCTAssertEqual(Array(mega.suffix(2)), [0x11, 0x24])
        // an Uno's with Optiboot at 0x7E00
        XCTAssertEqual(try FirmwareFile.decode(hex([(0, [0x0C]), (0x7FFE, [0x01, 0x02])])).count, 0x8000)
        // an STM32F405's whole 1 MB, from 0x08000000
        let stm32 = try FirmwareFile.decode(hex([(0x0800_0000, [0, 0x10, 0, 0x20]), (0x080F_FFFC, [1, 2, 3, 4])]))
        XCTAssertEqual(stm32.count, 0x10_0000)
        // a Pico's 2 MB, from 0x10000000
        XCTAssertEqual(try FirmwareFile.decode(hex([(0x1000_0000, [0]), (0x101F_FFFF, [1])])).count, 0x20_0000)
        // as large as allowed
        XCTAssertEqual(try FirmwareFile.decode(hex([(0, [0]), (FirmwareFile.maximumSpan - 1, [1])])).count, FirmwareFile.maximumSpan)
        assertTooLarge(hex([(0, [0]), (FirmwareFile.maximumSpan, [1])]), mentions: [])
    }
}
