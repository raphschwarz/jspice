import CortexM4
import XCTest

/// The Cortex-M4 core (Sources/CortexM4). Its instructions are checked one by one against QEMU's Cortex-M4 where it is
/// developed (tools/arm-reference/fuzz.py); here it runs a self-test program (tools/arm-reference/selftest) that also
/// exercises what QEMU cannot check that way: SysTick, the NVIC, SVC and PendSV, priorities, the process stack, and
/// an interrupt that uses the FPU in the middle of the code it interrupted using it.
final class CortexM4Tests: XCTestCase {
    /// The self-test's results, in the order it writes them at the start of RAM, with their values computed apart
    /// (tools/arm-reference/selftest/run.py)
    static let expected: [(name: String, value: UInt32)] = [
        ("marker", 0x00C0FFEE), ("crc", 0x414FA339), ("harmonic", 0x40EF890A), ("sqrt", 0x3FB504F3),
        ("fma", 0x403B851F), ("div64_lo", 0x45F5207D), ("div64_hi", 0x0000060A), ("series", 0x40F9080A),
        ("ticks_ok", 0x00000001), ("handler_float", 0x40200000), ("svc", 0x00000023), ("pendsv", 0x00000050),
        ("basepri", 0x00000003), ("bitband", 0x00000120), ("exclusive", 0x0000002A), ("dsp", 0xABAE53DE),
        ("bits", 0x80002208), ("psp", 0x0001002D), ("convert", 0x0000000D), ("udiv0", 0x00000000),
        ("irq_order", 0x00002103), ("saturate", 0x77FFFF80), ("done", 0x0000D0D0),
    ]

    func testSelfTest() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "cm4-selftest", withExtension: "bin", subdirectory: "Fixtures"))
        let image = try Data(contentsOf: url)
        let cpu = try XCTUnwrap(cm4_create())
        defer { cm4_destroy(cpu) }
        let flash = try XCTUnwrap(cm4_add_memory(cpu, 0x0800_0000, 0x10_0000, false))
        cm4_alias(cpu, 0, 0x0800_0000)
        let ram = try XCTUnwrap(cm4_add_memory(cpu, 0x2000_0000, 0x2_0000, true))
        image.withUnsafeBytes { flash.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: image.count) }
        cm4_configure(cpu, 82, 4)
        cm4_reset(cpu)

        var stop = CM4_RAN
        for _ in 0..<1000 {
            stop = cm4_run(cpu, 100_000)
            if stop != CM4_RAN && stop != CM4_SLEEPING { break }
        }
        XCTAssertEqual(stop, CM4_BREAKPOINT, "the self-test ends on BKPT")
        let results = UnsafeRawPointer(ram).bindMemory(to: UInt32.self, capacity: 32)
        for (index, result) in Self.expected.enumerated() {
            XCTAssertEqual(results[index], result.value, "\(result.name): \(String(results[index], radix: 16))")
        }
    }

    func testRegistersAndMemoryFromTheHost() throws {
        let cpu = try XCTUnwrap(cm4_create())
        defer { cm4_destroy(cpu) }
        let flash = try XCTUnwrap(cm4_add_memory(cpu, 0x0800_0000, 0x1000, false))
        cm4_alias(cpu, 0, 0x0800_0000)
        _ = cm4_add_memory(cpu, 0x2000_0000, 0x1000, true)
        // vectors: SP at the top of RAM, reset at 0x08000009 (Thumb); there: movs r0, #42; adds r0, r0, r0; bkpt
        let words: [UInt32] = [0x2000_1000, 0x0800_0009]
        for (i, word) in words.enumerated() { (flash + 4 * i).withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee = word } }
        let code: [UInt8] = [0x2A, 0x20, 0x00, 0x18, 0x00, 0xBE]
        for (i, byte) in code.enumerated() { flash[8 + i] = byte }
        cm4_reset(cpu)
        XCTAssertEqual(cm4_reg(cpu, 13), 0x2000_1000)
        XCTAssertEqual(cm4_reg(cpu, 15), 0x0800_0008)
        XCTAssertEqual(cm4_run(cpu, 100), CM4_BREAKPOINT)
        XCTAssertEqual(cm4_reg(cpu, 0), 84)
        XCTAssertEqual(cm4_instructions(cpu), 3)
        cm4_write(cpu, 0x2000_0010, 0xDEAD_BEEF, 4)
        XCTAssertEqual(cm4_read(cpu, 0x2000_0012, 2), 0xDEAD)
        // flash is not written from the core's side
        cm4_write(cpu, 0x0800_0000, 0, 4)
        XCTAssertEqual(cm4_read(cpu, 0, 4), 0x2000_1000)
    }
}
