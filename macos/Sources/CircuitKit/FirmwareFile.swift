import Foundation

/// A firmware image read from a file a toolchain wrote, for a microcontroller part to run: an Intel HEX file (as
/// avr-objcopy writes, and as Mutable Instruments' and 4ms' makefiles leave for their modules), or a raw image from the
/// start of flash (a .bin).
public enum FirmwareFile {
    public enum DecodeError: Error, CustomStringConvertible, Equatable {
        case badRecord(line: Int)
        case badChecksum(line: Int)
        case empty
        /// Data from `lowest` up to `end` (exclusive), more than `maximumSpan` from the flash's start
        case tooLarge(lowest: Int, end: Int)

        public var description: String {
            switch self {
            case .badRecord(let line): return "line \(line) is not an Intel HEX record"
            case .badChecksum(let line): return "line \(line)'s checksum does not match"
            case .empty: return "the file holds no firmware"
            case .tooLarge(let lowest, let end):
                let megabytes = (Double(end - lowest) / 1_048_576 * 10).rounded() / 10
                func hex(_ address: Int) -> String {
                    let digits = String(address, radix: 16, uppercase: true)
                    return "0x" + String(repeating: "0", count: max(0, 8 - digits.count)) + digits
                }
                return "this HEX file spans \(megabytes) MB from \(hex(lowest)) to \(hex(end - 1)); it may include EEPROM, fuse or option-byte records (an AVR's EEPROM at 0x810000, an STM32's"
                    + " option bytes at 0x1FFFC000 or 0x1FFFF800), which are not flash: build the HEX file from the"
                    + " flash sections only"
            }
        }
    }

    /// The flash image the file holds: a HEX file's data records at their addresses (gaps erased, 0xFF), or the
    /// file's bytes as they are
    public static func decode(_ data: Data) throws -> Data {
        guard !data.isEmpty else { throw DecodeError.empty }
        // a HEX file is text whose first non-blank character is a colon
        let start = data.firstIndex { ![0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF].contains($0) }
        guard let start, data[start] == UInt8(ascii: ":"), let text = String(data: data, encoding: .ascii) ?? String(data: data, encoding: .utf8) else {
            return data
        }
        return try decodeHex(text)
    }

    /// Where the RP2040's flash appears in its address space: a Pico's HEX file places its image there
    static let picoFlash = 0x1000_0000
    /// Where an STM32's flash does
    static let stm32Flash = 0x0800_0000
    /// The most a HEX file's image may span, from the flash's start (or its lowest record) to its highest record's end:
    /// twice the largest flash a part has (the Pico's 2 MB; an STM32F405's is 1 MB, an ATmega2560's 256 KB with its
    /// bootloader at the top), so that a file with records far past the flash (an AVR's EEPROM, fuses and lock bits,
    /// at 0x810000-0x830000 in the ELF's address space; an STM32's option bytes) is refused before an image as large
    /// as the space between is made
    public static let maximumSpan = 0x40_0000

    /// Intel HEX: data (00), end of file (01), and the extended segment (02) and linear (04) address records that
    /// place data past 64 KB; start address records (03, 05) are left out. An image placed in the RP2040's or an
    /// STM32's flash is taken from the flash's start.
    static func decodeHex(_ text: String) throws -> Data {
        var chunks: [(address: Int, bytes: ArraySlice<UInt8>)] = []
        var base = 0
        func image() throws -> Data {
            guard let lowest = chunks.map(\.address).min(), let end = chunks.map({ $0.address + $0.bytes.count }).max() else {
                throw DecodeError.empty
            }
            let origin = lowest >= picoFlash ? picoFlash : lowest >= stm32Flash ? stm32Flash : 0
            guard end - origin <= maximumSpan else { throw DecodeError.tooLarge(lowest: lowest, end: end) }
            var image = [UInt8](repeating: 0xFF, count: end - origin)
            for chunk in chunks {
                let at = chunk.address - origin
                image.replaceSubrange(at..<(at + chunk.bytes.count), with: chunk.bytes)
            }
            return Data(image)
        }
        for (number, raw) in text.split(whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard line.hasPrefix(":"), line.count >= 11, line.count % 2 == 1 else { throw DecodeError.badRecord(line: number + 1) }
            var bytes: [UInt8] = []
            var index = line.index(after: line.startIndex)
            while index < line.endIndex {
                let next = line.index(index, offsetBy: 2)
                guard let byte = UInt8(line[index..<next], radix: 16) else { throw DecodeError.badRecord(line: number + 1) }
                bytes.append(byte)
                index = next
            }
            let count = Int(bytes[0])
            guard bytes.count == count + 5 else { throw DecodeError.badRecord(line: number + 1) }
            guard bytes.reduce(0, { ($0 + Int($1)) & 0xFF }) == 0 else { throw DecodeError.badChecksum(line: number + 1) }
            let address = Int(bytes[1]) << 8 | Int(bytes[2])
            let payload = bytes[4..<(4 + count)]
            switch bytes[3] {
            case 0x00:
                if count > 0 { chunks.append((base + address, payload)) }
            case 0x01:
                return try image()
            case 0x02 where count == 2:
                base = (Int(payload[payload.startIndex]) << 8 | Int(payload[payload.startIndex + 1])) << 4
            case 0x04 where count == 2:
                base = (Int(payload[payload.startIndex]) << 8 | Int(payload[payload.startIndex + 1])) << 16
            case 0x03, 0x05:
                break
            default:
                throw DecodeError.badRecord(line: number + 1)
            }
        }
        return try image()
    }
}
