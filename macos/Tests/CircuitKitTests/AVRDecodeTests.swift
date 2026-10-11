import XCTest
@testable import CircuitKit

/// The AVR's instructions dispatched through its decode table do what `execute`'s nested switches have them do
final class AVRDecodeTests: XCTestCase {
    /// Every opcode, from the same registers, pointers into RAM, stack and status, on two chips kept in step (one
    /// decoding each way): the same cycles, program counter, interrupt delay and data space after it
    func testEveryOpcodeDecodesAsTheSwitchesDo() {
        for variant in [AVRVariant.atmega328p, .atmega2560, .attiny85] {
            let switches = AVR(firmware: [], variant: variant)
            let table = AVR(firmware: [], variant: variant)
            let size = variant.dataSize
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            func random() -> UInt8 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return UInt8(truncatingIfNeeded: seed >> 33)
            }
            var failures = 0
            for op in 0..<0x10000 where failures < 5 {
                var registers = (0..<32).map { _ in random() }
                for pointer in [26, 28, 30] { registers[pointer + 1] = 0x02 + random() & 1 }
                let sp = size - 1 - Int(random() & 0x1F)
                let core = [(AVR.SPL, UInt8(truncatingIfNeeded: sp)), (AVR.SPH, UInt8(truncatingIfNeeded: sp >> 8)),
                            (AVR.SREG, random()), (AVR.RAMPZ, random() & 3), (AVR.EIND, random() & 3)]
                for avr in [switches, table] {
                    for (index, value) in registers.enumerated() { avr.data[index] = value }
                    for (address, value) in core { avr.data[address] = value }
                }
                let second: UInt16 = [0x0123, 0x940C, 0x0000, 0x1F80][op & 3]
                let a = switches.executeInstruction((UInt16(op), second), decodedAhead: false)
                let b = table.executeInstruction((UInt16(op), second), decodedAhead: true)
                let same = a == b && switches.pc == table.pc && memcmp(switches.data, table.data, size) == 0
                if !same {
                    failures += 1
                    let address = (0..<size).first { switches.data[$0] != table.data[$0] }
                    XCTFail("\(variant.name) opcode \(String(op, radix: 16)): cycles \(a.cycles)/\(b.cycles), pc \(switches.pc)/"
                                + "\(table.pc), interrupt delay \(a.interruptDelay)/\(b.interruptDelay), data first differs at "
                                + "\(address.map { String($0) } ?? "none")")
                }
            }
        }
    }
}
