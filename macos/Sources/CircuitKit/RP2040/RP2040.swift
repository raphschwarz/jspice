import Foundation

/// The RP2040: its Cortex-M0+ core (one of two: the second never starts here), memories and peripherals, on the bus
/// as rp2040.ts lays it out
final class RP2040 {
    static let flashStart: UInt32 = 0x1000_0000, flashEnd: UInt32 = 0x1400_0000
    static let ramStart: UInt32 = 0x2000_0000, dpramStart: UInt32 = 0x5010_0000, sioStart: UInt32 = 0xD000_0000
    static let flashSize = 16 * 1024 * 1024, sramSize = 264 * 1024, dpramSize = 4 * 1024, bootromSize = 16 * 1024

    let clock = RPClock()
    let bootrom: UnsafeMutableRawPointer
    let sram: UnsafeMutableRawPointer
    let flash: UnsafeMutableRawPointer
    let usbDPRAM: UnsafeMutableRawPointer

    var clkSys: Double = 125e6
    var clkPeri: Double = 125e6
    /// The crystal: 12 MHz on the Pico
    var xoscFrequency: Double = 12e6
    /// The ring oscillator (on silicon it varies with voltage and temperature)
    var roscFrequency: Double = 6.5e6
    var interruptNMIMask: UInt32 = 0

    // The parts used at almost every instruction (the core, the system timer's block, SIO, DMA, PWM, the ADC) are held
    // by `owned` and referred to without counting: a counted reference costs a retain and a release at each use.
    private var owned: [AnyObject] = []
    private(set) unowned(unsafe) var core: CortexM0!
    private(set) var pllSys: RPPLL!
    private(set) var pllUSB: RPPLL!
    private(set) var clocks: RPClocks!
    private(set) unowned(unsafe) var ppb: RPPPB!
    private(set) unowned(unsafe) var sio: RPSIO!
    private(set) var uart: [RPUART] = []
    private(set) unowned(unsafe) var pwm: RPPWM!
    private(set) unowned(unsafe) var adc: RPADC!
    private(set) var gpio: [RPGPIOPin] = []
    private(set) var qspi: [RPGPIOPin] = []
    private(set) unowned(unsafe) var dma: RPDMA!
    private(set) var pio: [RPPIO] = []
    private(set) var usbCtrl: RPUSBController!
    private(set) var spi: [RPSPI] = []
    private(set) var i2c: [RPI2C] = []
    /// The peripherals at 0x40000000-0x40FFFFFF (APB) and 0x50000000-0x50FFFFFF (AHB), by address bits 14-23; and the
    /// SSI at 0x18000000
    private var apb = [RPPeripheral?](repeating: nil, count: 1024)
    private var ahb = [RPPeripheral?](repeating: nil, count: 1024)
    private var ssi: RPPeripheral?

    init() {
        bootrom = .allocate(byteCount: RP2040.bootromSize, alignment: 4)
        sram = .allocate(byteCount: RP2040.sramSize + 4, alignment: 4)
        flash = .allocate(byteCount: RP2040.flashSize + 4, alignment: 4)
        usbDPRAM = .allocate(byteCount: RP2040.dpramSize + 4, alignment: 4)
        sram.initializeMemory(as: UInt8.self, repeating: 0, count: RP2040.sramSize + 4)
        usbDPRAM.initializeMemory(as: UInt8.self, repeating: 0, count: RP2040.dpramSize + 4)
        flash.initializeMemory(as: UInt8.self, repeating: 0xFF, count: RP2040.flashSize + 4)
        RPBootrom.b1.withUnsafeBytes { bootrom.copyMemory(from: $0.baseAddress!, byteCount: RP2040.bootromSize) }

        // the same order as rp2040.ts, which matters where one peripheral uses another as it is made
        let newCore = CortexM0(chip: self)
        owned.append(newCore)
        core = newCore
        pllSys = RPPLL(chip: self, name: "PLL_SYS_BASE")
        pllUSB = RPPLL(chip: self, name: "PLL_USB_BASE")
        clocks = RPClocks(chip: self, name: "CLOCKS_BASE")
        let newPpb = RPPPB(chip: self, name: "PPB")
        owned.append(newPpb)
        ppb = newPpb
        let newSio = RPSIO(chip: self)
        owned.append(newSio)
        sio = newSio
        uart = [RPUART(chip: self, name: "UART0", irq: RPIRQ.uart0, dreqTX: RPDREQ.uart0TX),
                RPUART(chip: self, name: "UART1", irq: RPIRQ.uart1, dreqTX: RPDREQ.uart1TX)]
        i2c = [RPI2C(chip: self, name: "I2C0", index: 0, irq: RPIRQ.i2c0),
               RPI2C(chip: self, name: "I2C1", index: 1, irq: RPIRQ.i2c1)]
        let newPwm = RPPWM(chip: self, name: "PWM_BASE")
        owned.append(newPwm)
        pwm = newPwm
        let newAdc = RPADC(chip: self, name: "ADC")
        owned.append(newAdc)
        adc = newAdc
        gpio = (0..<30).map { RPGPIOPin(chip: self, index: $0) }
        qspi = (0..<6).map { RPGPIOPin(chip: self, index: $0, qspi: true) }
        let newDma = RPDMA(chip: self, name: "DMA")
        owned.append(newDma)
        dma = newDma
        pio = [RPPIO(chip: self, name: "PIO0", firstIRQ: RPIRQ.pio0IRQ0, index: 0),
               RPPIO(chip: self, name: "PIO1", firstIRQ: RPIRQ.pio1IRQ0, index: 1)]
        usbCtrl = RPUSBController(chip: self, name: "USB")
        spi = [RPSPI(chip: self, name: "SPI0", index: 0, irq: RPIRQ.spi0, dreqTX: RPDREQ.spi0TX, dreqRX: RPDREQ.spi0RX),
               RPSPI(chip: self, name: "SPI1", index: 1, irq: RPIRQ.spi1, dreqTX: RPDREQ.spi1TX, dreqRX: RPDREQ.spi1RX)]
        let table: [UInt32: RPPeripheral] = [
            0x18000: RPSSI(chip: self, name: "SSI"),
            0x40000: RPSysInfo(chip: self, name: "SYSINFO_BASE"),
            0x40004: RPSysCfg(chip: self, name: "SYSCFG"),
            0x40008: clocks,
            0x4000C: RPReset(chip: self, name: "RESETS_BASE"),
            0x40010: RPPSM(chip: self, name: "PSM_BASE"),
            0x40014: RPIOBank(chip: self, name: "IO_BANK0_BASE"),
            0x40018: RPUnimplemented(chip: self, name: "IO_QSPI_BASE"),
            0x4001C: RPPads(chip: self, name: "PADS_BANK0_BASE", qspi: false),
            0x40020: RPPads(chip: self, name: "PADS_QSPI_BASE", qspi: true),
            0x40024: RPXOSC(chip: self, name: "XOSC_BASE"),
            0x40028: pllSys,
            0x4002C: pllUSB,
            0x40030: RPBusControl(chip: self, name: "BUSCTRL_BASE"),
            0x40034: uart[0],
            0x40038: uart[1],
            0x4003C: spi[0],
            0x40040: spi[1],
            0x40044: i2c[0],
            0x40048: i2c[1],
            0x4004C: adc,
            0x40050: pwm,
            0x40054: RPTimerPeripheral(chip: self, name: "TIMER_BASE"),
            0x40058: RPWatchdog(chip: self, name: "WATCHDOG_BASE"),
            0x4005C: RPRTC(chip: self, name: "RTC_BASE"),
            0x40060: RPUnimplemented(chip: self, name: "ROSC_BASE"),
            0x40064: RPUnimplemented(chip: self, name: "VREG_AND_CHIP_RESET_BASE"),
            0x4006C: RPTBMAN(chip: self, name: "TBMAN_BASE"),
            0x50000: dma,
            0x50110: usbCtrl,
            0x50200: pio[0],
            0x50300: pio[1],
        ]
        // rp2040.ts looks them up by (address >>> 14) << 2, the keys of this table
        for (key, peripheral) in table {
            let block = Int((key >> 2) & 0x3FF)
            switch key >> 12 {
            case 0x40: apb[block] = peripheral
            case 0x50: ahb[block] = peripheral
            default: ssi = peripheral
            }
        }
        reset()
    }

    deinit {
        bootrom.deallocate()
        sram.deallocate()
        flash.deallocate()
        usbDPRAM.deallocate()
    }

    func reset() {
        core.reset()
        pwm.reset()
        flash.initializeMemory(as: UInt8.self, repeating: 0xFF, count: RP2040.flashSize)
    }

    /// Puts a flash image (as linked at 0x10000000, boot stage 2 first) in flash
    func loadFlash(_ image: [UInt8]) {
        image.withUnsafeBytes { flash.copyMemory(from: $0.baseAddress!, byteCount: min(image.count, RP2040.flashSize)) }
    }

    // MARK: - Clocks

    /// clk_sys and clk_peri follow the PLL and CLOCKS registers; until the firmware sets them up each keeps its value
    func updateClocks() {
        let sys = clocks.sysFrequency
        if sys != 0 && sys != clkSys {
            clkSys = sys
            ppb.systickTimer.frequency = sys
            pwm.clockChanged()
        }
        let peri = clocks.periFrequency
        if peri != 0 && peri != clkPeri {
            clkPeri = peri
            for port in uart { port.clkPeriChanged() }
        }
    }

    // MARK: - The bus

    @inline(__always) private func findPeripheral(_ address: UInt32) -> RPPeripheral? {
        switch address >> 24 {
        case 0x40: return apb[Int((address >> 14) & 0x3FF)]
        case 0x50: return ahb[Int((address >> 14) & 0x3FF)]
        default: return address >> 14 == 0x6000 ? ssi : nil
        }
    }

    func readUint32(_ address: UInt32) -> UInt32 {
        if address < UInt32(RP2040.bootromSize) {
            return bootrom.load(fromByteOffset: Int(address & ~3), as: UInt32.self)
        } else if address >= RP2040.flashStart && address < RP2040.flashEnd {
            return flash.loadUnaligned(fromByteOffset: Int(address & 0x00FF_FFFF), as: UInt32.self)
        } else if address >= RP2040.ramStart && address < RP2040.ramStart + UInt32(RP2040.sramSize) {
            return sram.loadUnaligned(fromByteOffset: Int(address - RP2040.ramStart), as: UInt32.self)
        } else if address >= RP2040.dpramStart && address < RP2040.dpramStart + UInt32(RP2040.dpramSize) {
            return usbDPRAM.loadUnaligned(fromByteOffset: Int(address - RP2040.dpramStart), as: UInt32.self)
        } else if address >> 12 == 0xE000E {
            return ppb.readUint32(address & 0xFFF)
        } else if address >= RP2040.sioStart && address < 0xE000_0000 {
            return sio.readUint32(address - RP2040.sioStart)
        }
        if let peripheral = findPeripheral(address) { return peripheral.readUint32(address & 0x3FFF) }
        return 0xFFFF_FFFF
    }

    func readUint16(_ address: UInt32) -> UInt16 {
        if address >= RP2040.flashStart && address < RP2040.flashStart + UInt32(RP2040.flashSize) {
            return flash.loadUnaligned(fromByteOffset: Int(address - RP2040.flashStart), as: UInt16.self)
        } else if address >= RP2040.ramStart && address < RP2040.ramStart + UInt32(RP2040.sramSize) {
            return sram.loadUnaligned(fromByteOffset: Int(address - RP2040.ramStart), as: UInt16.self)
        }
        let value = readUint32(address & 0xFFFF_FFFC)
        return UInt16(truncatingIfNeeded: address & 0x2 != 0 ? value >> 16 : value)
    }

    func readUint8(_ address: UInt32) -> UInt8 {
        if address >= RP2040.flashStart && address < RP2040.flashStart + UInt32(RP2040.flashSize) {
            return flash.load(fromByteOffset: Int(address - RP2040.flashStart), as: UInt8.self)
        } else if address >= RP2040.ramStart && address < RP2040.ramStart + UInt32(RP2040.sramSize) {
            return sram.load(fromByteOffset: Int(address - RP2040.ramStart), as: UInt8.self)
        }
        let value = readUint16(address & 0xFFFF_FFFE)
        return UInt8(truncatingIfNeeded: address & 0x1 != 0 ? value >> 8 : value)
    }

    func writeUint32(_ address: UInt32, _ value: UInt32) {
        if let peripheral = findPeripheral(address) {
            peripheral.writeUint32Atomic(address & 0xFFF, value, (address & 0x3000) >> 12)
        } else if address < UInt32(RP2040.bootromSize) {
            // ROM: a stray write (a null pointer in a sketch) changes nothing, as on the chip
        } else if address >= RP2040.flashStart && address < RP2040.flashStart + UInt32(RP2040.flashSize) {
            flash.storeBytes(of: value, toByteOffset: Int(address - RP2040.flashStart), as: UInt32.self)
        } else if address >= RP2040.ramStart && address < RP2040.ramStart + UInt32(RP2040.sramSize) {
            sram.storeBytes(of: value, toByteOffset: Int(address - RP2040.ramStart), as: UInt32.self)
        } else if address >= RP2040.dpramStart && address < RP2040.dpramStart + UInt32(RP2040.dpramSize) {
            let offset = Int(address - RP2040.dpramStart)
            usbDPRAM.storeBytes(of: value, toByteOffset: offset, as: UInt32.self)
            usbCtrl.dpramUpdated(offset, value)
        } else if address >= RP2040.sioStart && address < 0xE000_0000 {
            sio.writeUint32(address - RP2040.sioStart, value)
        } else if address >> 12 == 0xE000E {
            ppb.writeUint32(address & 0xFFF, value)
        }
    }

    func writeUint8(_ address: UInt32, _ value: UInt8) {
        if address >= RP2040.ramStart && address < RP2040.ramStart + UInt32(RP2040.sramSize) {
            sram.storeBytes(of: value, toByteOffset: Int(address - RP2040.ramStart), as: UInt8.self)
            return
        }
        let aligned = address & 0xFFFF_FFFC
        let byte = UInt32(value)
        if let peripheral = findPeripheral(address) {
            peripheral.writeUint32Atomic(aligned & 0xFFF, byte | byte << 8 | byte << 16 | byte << 24, (aligned & 0x3000) >> 12)
            return
        }
        let shift = (address & 0x3) * 8
        let original = readUint32(aligned)
        writeUint32(aligned, (original & ~(0xFF << shift)) | (byte << shift))
    }

    func writeUint16(_ address: UInt32, _ value: UInt16) {
        if address >= RP2040.ramStart && address < RP2040.ramStart + UInt32(RP2040.sramSize) {
            sram.storeBytes(of: value, toByteOffset: Int(address - RP2040.ramStart), as: UInt16.self)
            return
        }
        let aligned = address & 0xFFFF_FFFC
        let half = UInt32(value)
        if let peripheral = findPeripheral(address) {
            peripheral.writeUint32Atomic(aligned & 0xFFF, half | half << 16, (aligned & 0x3000) >> 12)
            return
        }
        let original = readUint32(aligned)
        writeUint32(aligned, address & 0x2 != 0 ? (original & 0xFFFF) | half << 16 : (original & 0xFFFF_0000) | half)
    }

    // MARK: - GPIO and interrupts

    var gpioValues: UInt32 {
        var result: UInt32 = 0
        for (index, pin) in gpio.enumerated() where pin.inputValue { result |= 1 << UInt32(index) }
        return result
    }

    func setInterrupt(_ irq: Int, _ value: Bool) { core.setInterrupt(irq, value) }

    /// The level on the pin given to a peripheral's input (SPI: instance (GPIO >> 3) & 1, role GPIO & 3, 0 being RX;
    /// I²C: instance (GPIO >> 1) & 1, role GPIO & 1, 0 being SDA), high if no pin is (as a pulled-up bus would be)
    func peripheralInput(function: UInt32, instance: Int, role: Int) -> Bool {
        for pin in gpio where pin.functionSelect == function {
            let signal = RPGPIOPin.peripheral(function, pin.index)
            if signal.instance == instance && signal.role == role { return pin.inputValue }
        }
        return true
    }

    /// A peripheral changed what it drives: the pins given to it follow
    func peripheralPinsChanged(function: UInt32) {
        for pin in gpio where pin.functionSelect == function { pin.checkForUpdates() }
    }

    func updateIOInterrupt() {
        setInterrupt(RPIRQ.ioBank0, gpio.contains { $0.irqValue })
    }

    // MARK: - Running

    /// Nanoseconds per cycle: rp2040js counts the core's cycles at 125 MHz whatever clk_sys is
    static let cycleNanos = 1e9 / 125e6

    /// Runs one instruction (or, while the core waits for an event, lets time pass to the next alarm, but no further
    /// than `limit`); then the PIO state machines catch up
    func step(limit: Double) {
        if core.waiting {
            var target = limit
            if clock.hasAlarm { target = min(target, clock.nanos + clock.nanosToNextAlarm) }
            // running state machines can wake the core: let them run in small steps
            if pioRunning { target = min(target, clock.nanos + 1000) }
            clock.tick(max(target - clock.nanos, 0))
        } else {
            let cycles = core.executeInstruction()
            clock.tick(Double(cycles) * RP2040.cycleNanos)
        }
        if pioRunning {
            for block in pio where block.running { block.run(until: clock.nanos) }
        }
    }

    private var pioRunning: Bool { pio[0].running || pio[1].running }

    /// Steps until `end` (nanoseconds): `step(limit:)` in a loop, with what it looks up each time looked up once
    func run(until end: Double) {
        let core: CortexM0 = self.core
        let clock = self.clock
        let pio0 = pio[0], pio1 = pio[1]
        while clock.nanos < end {
            if core.waiting {
                step(limit: end)
                continue
            }
            let cycles = core.executeInstruction()
            clock.tick(Double(cycles) * RP2040.cycleNanos)
            if pio0.running || pio1.running {
                // only once an instruction is due: the busy processor would otherwise visit them after its every one
                let now = clock.nanos
                if pio0.running && now >= pio0.nextDue { pio0.run(until: now) }
                if pio1.running && now >= pio1.nextDue { pio1.run(until: now) }
            }
        }
    }
}
