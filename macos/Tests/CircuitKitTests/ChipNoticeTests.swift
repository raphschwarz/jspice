import XCTest
@testable import CircuitKit

/// The chips say what their firmware does that the model does not run (sleeping, the watchdog, the comparator, a
/// block the Pico model leaves out, its second core), each once, and the simulator shows it on the chip's part
final class ChipNoticeTests: XCTestCase {
    // MARK: - Hand-assembled AVR programs

    private static func ldi(_ register: Int, _ k: Int) -> [UInt16] {
        [UInt16(0xE000 | (k & 0xF0) << 4 | (register - 16) << 4 | k & 0x0F)]
    }

    /// STS to a data address
    private static func sts(_ address: Int, _ register: Int) -> [UInt16] { [UInt16(0x9200 | register << 4), UInt16(address)] }

    /// OUT to a data address in the I/O space (0x20-0x5F)
    private static func out(_ address: Int, _ register: Int) -> [UInt16] {
        let a = address - 0x20
        return [UInt16(0xB800 | (a & 0x30) << 5 | register << 4 | a & 0x0F)]
    }

    private static let sleep: [UInt16] = [0x9588], wdr: [UInt16] = [0x95A8], spm: [UInt16] = [0x95E8], halt: [UInt16] = [0xCFFF]

    private static func program(_ words: [UInt16]...) -> [UInt8] {
        words.flatMap { $0 }.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    }

    private func keys(_ chip: Microcontroller) -> [String] { chip.unsupportedNotices.map(\.key) }

    // MARK: - AVR

    func testSleepIsNotedOnceWhereSleepIsEnabled() {
        // a SLEEP without SE does nothing on the chip either; with SE set (SMCR), twice, then a loop
        let uno = AVR(firmware: Self.program(Self.sleep, Self.ldi(16, 1), Self.out(0x53, 16), Self.sleep, Self.sleep, Self.halt))
        uno.run(cycles: 1000)
        XCTAssertEqual(keys(uno), ["sleep"])
        XCTAssertEqual(uno.unsupportedNotices.first?.address, 6, "the first SLEEP with SE set")
        XCTAssertEqual(uno.unsupportedNotices.first?.severity, .warning)
        // the ATtiny85's SE is in MCUCR
        let tiny = AVR(firmware: Self.program(Self.ldi(16, 0x20), Self.out(0x55, 16), Self.sleep, Self.halt), variant: .attiny85)
        tiny.run(cycles: 1000)
        XCTAssertEqual(keys(tiny), ["sleep"])
        // and nothing without it
        let idle = AVR(firmware: Self.program(Self.sleep, Self.halt), variant: .attiny85)
        idle.run(cycles: 1000)
        XCTAssertEqual(keys(idle), [])
    }

    func testTheWatchdogIsNotedAndWhereItWouldHaveReset() {
        for variant in [AVRVariant.atmega328p, .atmega2560] {
            // wdt_enable(WDTO_15MS) as avr-libc does it (WDCE | WDE, then WDE), a WDR, then a loop
            let avr = AVR(firmware: Self.program(Self.wdr, Self.ldi(16, 0x18), Self.sts(0x60, 16), Self.ldi(16, 0x08),
                                                 Self.sts(0x60, 16), Self.wdr, Self.halt), variant: variant)
            avr.run(cycles: 1000)
            XCTAssertEqual(keys(avr), ["watchdog"], variant.name)
            // 16 ms later, with no WDR: it would have reset the chip, which runs on
            avr.run(cycles: Int(variant.clock * 0.02))
            XCTAssertEqual(keys(avr), ["watchdog", "watchdog-expired"], variant.name)
            XCTAssertGreaterThan(avr.cycles, Int(variant.clock * 0.02), "not reset")
            XCTAssertTrue(avr.unsupportedNotices[1].message.contains("16 ms"), avr.unsupportedNotices[1].message)
            // wdt_disable(): WDCE | WDE, then 0
            let off = AVR(firmware: Self.program(Self.ldi(16, 0x18), Self.sts(0x60, 16), Self.ldi(16, 0), Self.sts(0x60, 16),
                                                 Self.halt), variant: variant)
            off.run(cycles: Int(variant.clock * 0.05))
            XCTAssertEqual(keys(off), [], variant.name)
        }
        // the ATtiny85's WDTCR, its interrupt alone (as sleep libraries wake up by it)
        let tiny = AVR(firmware: Self.program(Self.ldi(16, 0x40), Self.out(0x41, 16), Self.halt), variant: .attiny85)
        tiny.run(cycles: 1000)
        XCTAssertEqual(keys(tiny), ["watchdog-interrupt"])
    }

    func testTheComparatorAndOtherUnmodelledRegistersAreNotedOnTheirChips() {
        // ACSR with ACD clear (its interrupt on), on each chip where it is; then ACD set alone: nothing
        for (variant, acsr) in [(AVRVariant.atmega328p, 0x50), (.atmega2560, 0x50), (.attiny85, 0x28)] {
            let on = AVR(firmware: Self.program(Self.ldi(16, 0x08), Self.out(acsr, 16), Self.out(acsr, 16), Self.halt), variant: variant)
            on.run(cycles: 1000)
            XCTAssertEqual(keys(on), ["comparator"], variant.name)
            let off = AVR(firmware: Self.program(Self.ldi(16, 0x80), Self.out(acsr, 16), Self.halt), variant: variant)
            off.run(cycles: 1000)
            XCTAssertEqual(keys(off), [], variant.name)
        }
        // the 328P's SPI as a slave, its TWI given an address, its clock divided, SPM
        let uno = AVR(firmware: Self.program(Self.ldi(16, 0x40), Self.out(0x4C, 16), Self.ldi(16, 0x10), Self.sts(0xBA, 16),
                                             Self.ldi(16, 0x80), Self.sts(0x61, 16), Self.ldi(16, 0x01), Self.sts(0x61, 16),
                                             Self.spm, Self.halt))
        uno.run(cycles: 1000)
        XCTAssertEqual(Set(keys(uno)), ["spi-slave", "i2c-slave", "clock-prescaler", "spm"])
        // the SPI as a master: nothing
        let master = AVR(firmware: Self.program(Self.ldi(16, 0x50), Self.out(0x4C, 16), Self.halt))
        master.run(cycles: 1000)
        XCTAssertEqual(keys(master), [])
        // the ATtiny85's USI; and 0x60, SRAM on it (WDTCSR on the 328P): nothing
        let tiny = AVR(firmware: Self.program(Self.ldi(16, 0x18), Self.out(0x2D, 16), Self.sts(0x60, 16), Self.halt), variant: .attiny85)
        tiny.run(cycles: 1000)
        XCTAssertEqual(keys(tiny), ["usi"])
    }

    func testAResetClearsTheNoticesAndAdoptTakesThem() {
        let firmware = Self.program(Self.ldi(16, 1), Self.out(0x53, 16), Self.sleep, Self.halt)
        let avr = AVR(firmware: firmware)
        var said = 0
        avr.onNoticesChanged = { said += 1 }
        avr.run(cycles: 100)
        avr.run(cycles: 100)
        XCTAssertEqual(said, 1, "once, after the run that slept")
        let copy = AVR(firmware: firmware)
        copy.adopt(avr)
        XCTAssertEqual(keys(copy), ["sleep"])
        avr.reset()
        XCTAssertEqual(keys(avr), [])
        XCTAssertEqual(said, 2, "the reset cleared it")
    }

    // MARK: - Pico

    func testPicoNotesTheBlocksItLeavesOutTheSecondCoreAndFlashWrites() {
        // (a firmware of one instruction: B to itself)
        let pico = Pico(firmware: [0xFE, 0xE7])
        let chip = pico.rp2040
        var said = 0
        pico.onNoticesChanged = { said += 1 }
        // what the flash routines do at every boot (the flash's unique id): IO_QSPI's chip select, XIP_CTRL's flush, the
        // SSI's commands; and boot stage 2's write enable and status write
        chip.writeUint32(0x4001_800C, 0x300)
        chip.writeUint32(0x1400_0004, 1)
        for byte: UInt32 in [0x4B, 0, 0, 0, 0, 0x06, 0x01, 0x00, 0x02, 0x05] { chip.writeUint32(0x1800_0060, byte) }
        XCTAssertEqual(keys(pico), [])
        // ROSC read, VREG written, twice; nothing at 0x40068000
        _ = chip.readUint32(0x4006_0000)
        chip.writeUint32(0x4006_4000, 1)
        _ = chip.readUint32(0x4006_0004)
        chip.writeUint32(0x4006_4000, 1)
        _ = chip.readUint32(0x4006_8000)
        XCTAssertEqual(keys(pico), ["block-ROSC", "block-VREG_AND_CHIP_RESET", "unmapped"])
        XCTAssertTrue(pico.unsupportedNotices[2].message.contains("0x40068000"), pico.unsupportedNotices[2].message)
        // multicore_reset_core1() (PSM's FRC_OFF, through its set alias) and the FIFO: core 1, once, an error
        chip.writeUint32(0x4001_2004, 0x1_0000)
        chip.writeUint32(0xD000_0054, 0)
        _ = chip.readUint32(0xD000_0050)
        XCTAssertEqual(keys(pico).filter { $0 == "core1" }.count, 1)
        XCTAssertEqual(pico.unsupportedNotices.first { $0.key == "core1" }?.severity, .error)
        // flash_range_erase: a write enable, then a sector erase; get_bootsel_button(); the watchdog
        chip.writeUint32(0x1800_0060, 0x06)
        chip.writeUint32(0x1800_0060, 0x20)
        chip.writeUint32(0x4001_800C, 2 << 12)
        chip.writeUint32(0x4005_8004, 2_000_000)
        chip.writeUint32(0x4005_8000, 1 << 30)
        XCTAssertEqual(Array(keys(pico).suffix(3)), ["flash-write", "bootsel", "watchdog"])
        // said once, after the run
        XCTAssertEqual(said, 0)
        pico.run(cycles: 100)
        pico.run(cycles: 100)
        XCTAssertEqual(said, 1)
        // the window's Pico takes the sound thread's chip, notices and all, without saying them again
        let window = Pico(firmware: [0xFE, 0xE7])
        var windowSaid = 0
        window.onNoticesChanged = { windowSaid += 1 }
        window.adopt(pico)
        XCTAssertEqual(keys(window), keys(pico))
        window.run(cycles: 100)
        XCTAssertEqual(windowSaid, 0)
        pico.reset()
        XCTAssertEqual(keys(pico), [])
        XCTAssertEqual(said, 2, "the reset cleared them")
    }

    /// A watchdog enabled with nothing loaded has run out at once: it is noted, and the chip's run comes back (the
    /// alarm on a counter standing at its target used to go off without end)
    func testAPicoWatchdogEnabledWithNothingLoadedIsNotedAndDoesNotHang() {
        let pico = Pico(firmware: [0xFE, 0xE7])
        let chip = pico.rp2040
        chip.writeUint32(0x4005_8004, 0)
        chip.writeUint32(0x4005_8000, 1 << 30)
        XCTAssertEqual(keys(pico), ["watchdog", "watchdog-expired"])
        let done = expectation(description: "the run returns")
        DispatchQueue.global().async {
            pico.run(cycles: 10_000)
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        XCTAssertEqual(chip.readUint32(0x4005_8008), 1, "the reason it would have reset: the timer")
    }

    /// A watchdog that runs out while the sketch runs is noted once and the run goes on; fed again, it counts again
    func testAPicoWatchdogRunningOutIsNotedAndTheRunGoesOn() {
        let pico = Pico(firmware: [0xFE, 0xE7])
        let chip = pico.rp2040
        // 2000 counts at the watchdog's 2 MHz: a millisecond, 125,000 cycles of the chip's clock
        chip.writeUint32(0x4005_8004, 2000)
        chip.writeUint32(0x4005_8000, 1 << 30)
        XCTAssertEqual(keys(pico), ["watchdog"])
        let done = expectation(description: "the runs return")
        DispatchQueue.global().async {
            pico.run(cycles: 400_000)
            // fed, it runs out again a millisecond later, and that too comes back
            chip.writeUint32(0x4005_8004, 2000)
            pico.run(cycles: 400_000)
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(keys(pico), ["watchdog", "watchdog-expired"])
        XCTAssertEqual(chip.readUint32(0x4005_8008), 1)
    }

    // MARK: - The built-in examples

    private static let stm32Kinds: Set<ElementKind> = [.stm32f405, .stm32f373, .stm32f103]

    /// The examples' sketches (the AVRs' and the Picos', their firmware embedded) do nothing the models do not run
    func testTheBuiltInExamplesRaiseNone() {
        var looked = 0
        for example in Examples.all {
            let circuit = example.circuit
            let chips = circuit.elements.indices.filter {
                circuit.elements[$0].kind.isMicrocontroller && !Self.stm32Kinds.contains(circuit.elements[$0].kind)
                    && circuit.elements[$0].firmware != nil
            }
            guard !chips.isEmpty else { continue }
            looked += 1
            let simulator = Simulator(circuit: circuit, timeStep: 1e-4)
            simulator.errorControl = false
            let start = Date()
            let seconds = circuit.elements.contains { $0.kind == .rp2040 } ? 0.3 : 0.5
            while simulator.time < seconds && !simulator.isFailed { simulator.step() }
            for i in chips {
                let notices = simulator.chip(i)?.unsupportedNotices ?? []
                XCTAssertEqual(notices.map(\.key), [], "\(example.id): \(notices.map(\.message))")
            }
            let ids = Set(chips.map { circuit.elements[$0].id })
            let said = simulator.diagnostics.filter { $0.id.hasPrefix("chip-") && !ids.isDisjoint(with: $0.elements) }
            XCTAssertEqual(said.map(\.message), [], example.id)
            print("\(example.id): \(simulator.time) s in \(Date().timeIntervalSince(start)) s")
        }
        XCTAssertGreaterThan(looked, 5)
    }

    // MARK: - In the simulator

    private func sleepingUno() -> (Circuit, UUID, Int) {
        var circuit = Examples.arduinoBlink.circuit
        let index = circuit.elements.firstIndex { $0.kind.isMicrocontroller }!
        let id = circuit.elements[index].id
        circuit.update(id) { $0.firmware = Data(Self.program(Self.ldi(16, 1), Self.out(0x53, 16), Self.sleep, Self.halt)) }
        return (circuit, id, index)
    }

    private func run(_ simulator: Simulator, for seconds: Double) {
        let end = simulator.time + seconds
        while simulator.time < end && !simulator.isFailed { simulator.step() }
    }

    func testANoticeReachesTheDiagnosticsOnTheChipsPartAndGoesWithAReset() {
        let (circuit, id, index) = sleepingUno()
        let simulator = Simulator(circuit: circuit, timeStep: 1e-4)
        XCTAssertFalse(simulator.diagnostics.contains { $0.id.hasPrefix("chip-") })
        run(simulator, for: 0.01)
        let said = simulator.diagnostics.filter { $0.id.hasPrefix("chip-") }
        XCTAssertEqual(said.map(\.id), ["chip-sleep:" + id.uuidString])
        XCTAssertEqual(said.first?.elements, [id])
        XCTAssertEqual(said.first?.severity, .warning)
        XCTAssertTrue(said.first?.message.hasPrefix(circuit.elements[index].name + ": The sketch puts the chip to sleep") == true,
                      said.first?.message ?? "")
        XCTAssertTrue(simulator.problems.contains { $0.contains("sleep") })
        // the same, frame after frame
        run(simulator, for: 0.01)
        XCTAssertEqual(simulator.diagnostics.filter { $0.id.hasPrefix("chip-") }.map(\.id), said.map(\.id))
        // an edit elsewhere keeps the chip running, and its notice
        var edited = circuit
        edited.add(Element(kind: .resistor, a: GridPoint(80, 80), b: GridPoint(84, 80)))
        simulator.load(edited)
        XCTAssertEqual(simulator.diagnostics.filter { $0.id.hasPrefix("chip-") }.map(\.id), said.map(\.id))
        // the sound thread's copy: the window takes what it said
        let sound = Simulator(circuit: edited, timeStep: 1e-4)
        sound.adoptState(of: simulator)
        sound.reset()
        let window = Simulator(circuit: edited, timeStep: 1e-4)
        run(sound, for: 0.01)
        window.adoptState(of: sound)
        XCTAssertEqual(window.diagnostics.filter { $0.id.hasPrefix("chip-") }.map(\.id), said.map(\.id))
        XCTAssertEqual(window.chip(index)?.unsupportedNotices.map(\.key), ["sleep"])
        // a reset clears it (until the sketch sleeps again)
        simulator.reset()
        XCTAssertFalse(simulator.diagnostics.contains { $0.id.hasPrefix("chip-") })
        XCTAssertEqual(simulator.chip(index)?.unsupportedNotices.count, 0)
        run(simulator, for: 0.01)
        XCTAssertEqual(simulator.diagnostics.filter { $0.id.hasPrefix("chip-") }.count, 1)
        simulator.resetChip(index)
        XCTAssertFalse(simulator.diagnostics.contains { $0.id.hasPrefix("chip-") })
        // new firmware, a new chip: none
        run(simulator, for: 0.01)
        edited.update(id) { $0.firmware = Examples.arduinoBlink.circuit.elements[index].firmware }
        simulator.load(edited)
        run(simulator, for: 0.01)
        XCTAssertFalse(simulator.diagnostics.contains { $0.id.hasPrefix("chip-") })
    }
}
