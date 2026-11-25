import CortexM4
import Foundation
import XCTest

/// Firmware is untrusted: whatever it writes to the chip's registers, the emulator must neither hang nor overflow its
/// stack nor index past its arrays. These drive the C API directly, the registers poked as the core would write them.
final class STM32HardeningTests: XCTestCase {
    static let dma2: UInt32 = 0x4002_6400
    /// A DMA2 stream's register (CR 0, NDTR 4, PAR 8, M0AR 0x0C, M1AR 0x10, FCR 0x14)
    static func stream(_ s: UInt32, _ offset: UInt32) -> UInt32 { dma2 + 0x10 + 0x18 * s + offset }
    /// An F373 DMA1 channel's register (CCR 0, CNDTR 4, CPAR 8, CMAR 0x0C)
    static func channel(_ c: UInt32, _ offset: UInt32) -> UInt32 { 0x4002_0008 + 20 * c + offset }

    /// Runs `body` on its own thread; false when it has not returned within `seconds` (the thread is left to spin, its
    /// chip leaked, so that a hang fails the test instead of hanging the suite)
    func finishes(within seconds: Double, _ body: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            body()
            done.signal()
        }
        thread.stackSize = 8 << 20
        thread.start()
        return done.wait(timeout: .now() + seconds) == .success
    }

    /// Memory to memory with DBM set: RM0090 has neither double-buffer nor circular mode in memory to memory, so the
    /// transfer ends (EN cleared, TCIF set) instead of reloading NDTR for ever under the chip's lock
    func testAMemoryToMemoryTransferWithDoubleBufferModeEnds() throws {
        let chip = try XCTUnwrap(stm32_create(8e6))
        let core = try XCTUnwrap(stm32_core(chip))
        for k in 0..<4 { cm4_write(core, 0x2000_0000 + 4 * UInt32(k), 0x1111_1111 &* UInt32(k + 1), 4) }
        cm4_write(core, Self.stream(0, 0x04), 4, 4)
        cm4_write(core, Self.stream(0, 0x08), 0x2000_0000, 4)
        cm4_write(core, Self.stream(0, 0x0C), 0x2000_0100, 4)
        cm4_write(core, Self.stream(0, 0x10), 0x2000_0200, 4)
        // EN, memory to memory, PINC, MINC, words, DBM (and CIRC)
        let cr: UInt32 = 1 | 2 << 6 | 1 << 8 | 1 << 9 | 1 << 10 | 2 << 11 | 2 << 13 | 1 << 18
        let pointer = UInt(bitPattern: core)
        let ended = finishes(within: 10) {
            cm4_write(OpaquePointer(bitPattern: pointer), Self.stream(0, 0x00), cr, 4)
        }
        guard ended else { return XCTFail("the memory-to-memory transfer with DBM set never ended") }
        defer { stm32_destroy(chip) }
        XCTAssertEqual(cm4_read(core, Self.stream(0, 0x00), 4) & 1, 0, "EN cleared at the end")
        XCTAssertEqual(cm4_read(core, Self.stream(0, 0x04), 4), 0)
        XCTAssertEqual(cm4_read(core, Self.dma2, 4) & 0x20, 0x20, "TCIF0")
        for k in 0..<4 { XCTAssertEqual(cm4_read(core, 0x2000_0100 + 4 * UInt32(k), 4), 0x1111_1111 &* UInt32(k + 1)) }
        XCTAssertEqual(cm4_read(core, 0x2000_0200, 4), 0, "M1AR's buffer untouched")
    }

    /// Two memory-to-memory streams, each writing the other's CR (off, then on): each enable restarted the other's
    /// transfer inside the one under way, 65535 deep, and overflowed the host's stack. Now a stream a DMA transfer
    /// enables runs after it.
    func testStreamsEnablingEachOtherDoNotNest() throws {
        let chip = try XCTUnwrap(stm32_create(8e6))
        defer { stm32_destroy(chip) }
        let core = try XCTUnwrap(stm32_core(chip))
        let on: UInt32 = 1 | 2 << 6 | 1 << 9 | 2 << 11 | 2 << 13  // EN, memory to memory, PINC, words
        cm4_write(core, 0x2000_0000, 0, 4)
        cm4_write(core, 0x2000_0004, on, 4)
        cm4_write(core, 0x2000_0100, 0, 4)
        cm4_write(core, 0x2000_0104, on, 4)
        for (s, source, other) in [(UInt32(0), UInt32(0x2000_0000), UInt32(1)), (1, 0x2000_0100, 0)] {
            cm4_write(core, Self.stream(s, 0x04), 0xFFFF, 4)
            cm4_write(core, Self.stream(s, 0x08), source, 4)
            cm4_write(core, Self.stream(s, 0x0C), Self.stream(other, 0x00), 4)
        }
        cm4_write(core, Self.stream(0, 0x00), on, 4)
        XCTAssertEqual(cm4_read(core, Self.stream(0, 0x04), 4), 0, "stream 0 ran its 65535 items")
        XCTAssertEqual(cm4_read(core, Self.stream(0, 0x00), 4) & 1, 0)
    }

    /// The same on the F373's channels
    func testChannelsEnablingEachOtherDoNotNest() throws {
        let chip = try XCTUnwrap(stm32_create_model(STM32_F373, 8e6))
        defer { stm32_destroy(chip) }
        let core = try XCTUnwrap(stm32_core(chip))
        let on: UInt32 = 1 | 1 << 4 | 1 << 7 | 2 << 8 | 2 << 10 | 1 << 14  // EN, from memory, MINC, words, MEM2MEM
        cm4_write(core, 0x2000_0000, 0, 4)
        cm4_write(core, 0x2000_0004, on, 4)
        cm4_write(core, 0x2000_0100, 0, 4)
        cm4_write(core, 0x2000_0104, on, 4)
        for (c, source, other) in [(UInt32(0), UInt32(0x2000_0000), UInt32(1)), (1, 0x2000_0100, 0)] {
            cm4_write(core, Self.channel(c, 0x04), 0xFFFF, 4)
            cm4_write(core, Self.channel(c, 0x08), Self.channel(other, 0x00), 4)
            cm4_write(core, Self.channel(c, 0x0C), source, 4)
        }
        cm4_write(core, Self.channel(0, 0x00), on, 4)
        XCTAssertEqual(cm4_read(core, Self.channel(0, 0x04), 4), 0, "channel 1 ran its 65535 items")
    }

    /// An exception return with IPSR holding a number the core has no exception for (IPSR is nine bits; GDB or a
    /// stacked xPSR can put 300 there) is a UsageFault (INVPC), not a write past the 256-entry `active` array (into
    /// `enabled`: IRQ 28 was disabled)
    func testAnExceptionReturnFromAnExceptionNumberPastTheTableFaults() throws {
        let cpu = try XCTUnwrap(cm4_create())
        defer { cm4_destroy(cpu) }
        let flash = try XCTUnwrap(cm4_add_memory(cpu, 0x0800_0000, 0x1_0000, false))
        cm4_alias(cpu, 0, 0x0800_0000)
        _ = try XCTUnwrap(cm4_add_memory(cpu, 0x2000_0000, 0x1_0000, true))
        var vectors = [UInt32](repeating: 0x0800_0101, count: 16)
        vectors[0] = 0x2000_8000
        for (k, word) in vectors.enumerated() { for b in 0..<4 { flash[4 * k + b] = UInt8(truncatingIfNeeded: word >> (8 * b)) } }
        flash[0x100] = 0xFE; flash[0x101] = 0xE7  // b .
        flash[0x200] = 0x70; flash[0x201] = 0x47  // bx lr
        cm4_configure(cpu, 82, 4)
        cm4_reset(cpu)
        cm4_write(cpu, 0xE000_E100, 1 << 28, 4)  // IRQ 28 enabled: exception 44, which active[300] would have been
        cm4_set_reg(cpu, 15, 0x0800_0200)
        cm4_set_reg(cpu, 14, 0xFFFF_FFF1)
        cm4_set_xpsr(cpu, 0x0100_0000 | 300)
        _ = cm4_step(cpu)
        _ = cm4_step(cpu)
        XCTAssertEqual(cm4_read(cpu, 0xE000_ED28, 4) & (1 << 18), 1 << 18, "INVPC")
        XCTAssertEqual(cm4_xpsr(cpu) & 0x1FF, 3, "in HardFault (UsageFault is off)")
        XCTAssertEqual(cm4_read(cpu, 0xE000_E100, 4) & (1 << 28), 1 << 28, "IRQ 28 still enabled")
    }
}
