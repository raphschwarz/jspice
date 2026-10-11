import Foundation

/// A firmware image read from a file a toolchain wrote, for a microcontroller part to run: an Intel HEX file (as
/// avr-objcopy writes, and as Mutable Instruments' and 4ms' makefiles leave for their AVR modules), or a raw image
/// from the start of flash (a .bin).
public enum FirmwareFile {
    public enum DecodeError: Error, CustomStringConvertible, Equatable {
        case badRecord(line: Int)
        case badChecksum(line: Int)
        case empty

        public var description: String {
            switch self {
            case .badRecord(let line): return "line \(line) is not an Intel HEX record"
            case .badChecksum(let line): return "line \(line)'s checksum does not match"
            case .empty: return "the file holds no firmware"
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

    /// Intel HEX: data (00), end of file (01), and the extended segment (02) and linear (04) address records that
    /// place data past 64 KB; start address records (03, 05) are left out. An image placed in the RP2040's flash is
    /// taken from the flash's start.
    static func decodeHex(_ text: String) throws -> Data {
        var chunks: [(address: Int, bytes: ArraySlice<UInt8>)] = []
        var base = 0
        func image() throws -> Data {
            guard let lowest = chunks.map(\.address).min() else { throw DecodeError.empty }
            let origin = lowest >= picoFlash ? picoFlash : 0
            var image: [UInt8] = []
            for chunk in chunks {
                let at = chunk.address - origin
                if image.count < at + chunk.bytes.count { image += [UInt8](repeating: 0xFF, count: at + chunk.bytes.count - image.count) }
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
