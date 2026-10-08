import Foundation

/// An AVR microcontroller running its firmware: the CPU with its full instruction set and cycle counts, the timers
/// with PWM, the ADC, the I/O ports with pull-ups, external and pin change interrupts, the USARTs and the EEPROM. The
/// chip's layout comes from an `AVRVariant`: the ATmega328P (Arduino Uno), the ATmega2560 (Arduino Mega) or the
/// ATtiny85.
///
/// It was ported from a reference model (tools/avr-reference/avr.py) checked instruction by instruction against simavr
/// on all three chips; where simavr differs from the datasheet (interrupt entry cycles, how long interrupts wait after
/// SEI, the single-buffered transmitter, the ADC flag, OCR double buffering) the datasheet is followed, and
/// `simavrMode()` switches to simavr's behaviour for comparing with it.
///
/// Pins are numbered as on the board: on the Uno 0-7 are D0-D7 (port D), 8-13 are D8-D13 (port B), 14-19 are A0-A5
/// (port C); on the Mega 0-69 are D0-D69 (A0-A15 are 54-69); on the ATtiny85 0-5 are PB0-PB5.
public final class AVR: Microcontroller {
    public typealias PinState = CircuitKit.PinState

    static let SPL = 0x5D, SPH = 0x5E, SREG = 0x5F, RAMPZ = 0x5B, EIND = 0x5C

    // status register bits
    static let flagC: UInt8 = 1, flagZ: UInt8 = 2, flagN: UInt8 = 4, flagV: UInt8 = 8
    static let flagS: UInt8 = 16, flagH: UInt8 = 32, flagT: UInt8 = 64, flagI: UInt8 = 128

    public let variant: AVRVariant
    public var pinCount: Int { variant.pinCount }
    public var clock: Double { variant.clock }

    /// Program memory, in words
    private let flash: UnsafeMutablePointer<UInt16>
    /// Registers, I/O and SRAM
    let data: UnsafeMutablePointer<UInt8>
    private let dataSize: Int
    private let ioEnd: Int
    private let pcMask: Int
    private let threeBytePC: Bool
    public private(set) var eeprom: [UInt8]

    public private(set) var pc = 0
    public private(set) var cycles: Int = 0
    var timers: [AVRTimer] = []
    var usarts: [AVRUSART] = []
    var spi: AVRSPI?
    var twi: AVRTWI?

    /// Pin voltages the chip sees, set by the circuit before it runs; the digital levels follow them with hysteresis
    public var pinVoltages: [Double] {
        didSet {
            updateInputLevels()
            peripheralsTouched()
        }
    }
    public private(set) var pinHigh: [Bool]
    /// Supply and ADC reference voltage
    public var supply = 5.0

    /// Bytes the first USART (the board's serial port) has sent, oldest first, and bytes waiting to be received
    public var serialOutput: [UInt8] { usarts.first?.output ?? [] }
    public var serialInput: [UInt8] {
        get { usarts.first?.input ?? [] }
        set {
            usarts.first?.input = newValue
            peripheralsTouched()
        }
    }

    private var adcDoneAt: Int?
    private var adcFirst = false
    private var interruptDelay = 0
    private var externalPrevious: [Bool]
    private var externalWatch = false
    private var pinChangePrevious: [Int]
    private var pinChangeWatch = false
    /// The interrupt to take next, worked out again when a flag or an enable bit changes
    var interruptsChanged = true
    private var nextInterrupt: Int?

    /// Interrupt sources by priority
    private struct Source {
        let vector: Int
        let mask: Int
        let maskBit: UInt8
        let flag: Int
        let flagBit: UInt8
        let clears: Bool
    }
    private let sources: [Source]

    private enum Handler {
        case plain
        case pin(Int)
        case levels
        case clear
        case mask
        case statusRegister
        case count8(AVRTimer)
        case compare8(AVRTimer, Int)
        case top(AVRTimer)
        case count16Low(AVRTimer), count16High(AVRTimer)
        case compare16Low(AVRTimer, Int), compare16High(AVRTimer, Int)
        case capture16Low(AVRTimer), capture16High(AVRTimer)
        case clockSelect(AVRTimer)
        case usartData(AVRUSART), usartStatus(AVRUSART), usartControl(AVRUSART), usartRate(AVRUSART)
        case adcControl
        case externalControl
        case pinChangeMask
        case eepromControl
        case spiControl, spiStatus, spiData
        case twiControl, twiStatus, twiData
    }
    private var handlers: [Handler] = []
    /// The pin each port bit is bonded to (-1: none), by port
    private let portPins: [[Int]]

    // behaviour that differs between the chip and simavr
    var interruptCycles: Int
    var enableDelay = 1
    var transmitDoubleBuffered = true
    var flagsClearOnWrite = true
    var pwmDoubleBuffered = true

    public init(firmware: [UInt8], variant: AVRVariant = .atmega328p) {
        self.variant = variant
        dataSize = variant.dataSize
        ioEnd = variant.ioEnd
        pcMask = variant.flashWords - 1
        threeBytePC = variant.pcBytes == 3
        interruptCycles = variant.pcBytes == 3 ? 5 : 4
        eeprom = [UInt8](repeating: 0xFF, count: variant.eepromSize)
        pinVoltages = [Double](repeating: 0, count: variant.pinCount)
        pinHigh = [Bool](repeating: false, count: variant.pinCount)
        externalPrevious = [Bool](repeating: false, count: variant.externalInterrupts.count)
        pinChangePrevious = [Int](repeating: 0, count: variant.pinChanges.count)
        flash = UnsafeMutablePointer<UInt16>.allocate(capacity: variant.flashWords)
        flash.initialize(repeating: 0, count: variant.flashWords)
        data = UnsafeMutablePointer<UInt8>.allocate(capacity: variant.dataSize)
        data.initialize(repeating: 0, count: variant.dataSize)
        var i = 0
        while i < min(firmware.count, variant.flashBytes) {
            let low = UInt16(firmware[i])
            let high = i + 1 < firmware.count ? UInt16(firmware[i + 1]) : 0
            flash[i / 2] = low | high << 8
            i += 2
        }
        var ports = [[Int]](repeating: [Int](repeating: -1, count: 8), count: variant.ports.count)
        for (index, pin) in variant.pins.enumerated() { ports[pin.port][pin.bit] = index }
        portPins = ports

        var sources: [Source] = []
        for spec in variant.timers {
            for (unit, vector) in spec.compareVectors.enumerated() {
                sources.append(Source(vector: vector, mask: spec.maskRegister, maskBit: spec.compareBits[unit],
                                      flag: spec.flagRegister, flagBit: spec.compareBits[unit], clears: true))
            }
            sources.append(Source(vector: spec.overflowVector, mask: spec.maskRegister, maskBit: spec.overflowBit,
                                  flag: spec.flagRegister, flagBit: spec.overflowBit, clears: true))
            if spec.captureVector >= 0 {
                sources.append(Source(vector: spec.captureVector, mask: spec.maskRegister, maskBit: spec.captureBit,
                                      flag: spec.flagRegister, flagBit: spec.captureBit, clears: true))
            }
        }
        for spec in variant.usarts {
            sources.append(Source(vector: spec.rxVector, mask: spec.controlB, maskBit: 0x80, flag: spec.statusA, flagBit: 0x80, clears: false))
            sources.append(Source(vector: spec.udreVector, mask: spec.controlB, maskBit: 0x20, flag: spec.statusA, flagBit: 0x20, clears: false))
            sources.append(Source(vector: spec.txVector, mask: spec.controlB, maskBit: 0x40, flag: spec.statusA, flagBit: 0x40, clears: true))
        }
        sources.append(Source(vector: variant.adc.vector, mask: variant.adc.control, maskBit: 0x08,
                              flag: variant.adc.control, flagBit: 0x10, clears: true))
        for spec in variant.externalInterrupts {
            sources.append(Source(vector: spec.vector, mask: spec.mask, maskBit: spec.maskBit, flag: spec.flag,
                                  flagBit: spec.flagBit, clears: true))
        }
        for spec in variant.pinChanges {
            sources.append(Source(vector: spec.vector, mask: spec.control, maskBit: spec.controlBit, flag: spec.flag,
                                  flagBit: spec.flagBit, clears: true))
        }
        if let spec = variant.spi {
            sources.append(Source(vector: spec.vector, mask: spec.control, maskBit: 0x80, flag: spec.status, flagBit: 0x80, clears: true))
        }
        if let spec = variant.twi {
            // TWINT stays set until the program clears it
            sources.append(Source(vector: spec.vector, mask: spec.control, maskBit: 0x01, flag: spec.control, flagBit: 0x80, clears: false))
        }
        self.sources = sources.sorted { $0.vector < $1.vector }

        timers = variant.timers.map { AVRTimer(spec: $0, avr: self) }
        usarts = variant.usarts.map { AVRUSART(spec: $0, avr: self) }
        spi = variant.spi.map { AVRSPI(spec: $0, avr: self) }
        twi = variant.twi.map { AVRTWI(spec: $0, avr: self) }
        handlers = buildHandlers()
        reset()
    }

    deinit {
        flash.deallocate()
        data.deallocate()
    }

    private func buildHandlers() -> [Handler] {
        var h = [Handler](repeating: .plain, count: ioEnd)
        for (port, address) in variant.ports.enumerated() {
            h[address] = .pin(port)
            h[address + 1] = .levels
            h[address + 2] = .levels
        }
        for address in variant.clearOnWrite { h[address] = .clear }
        for address in variant.maskRegisters { h[address] = .mask }
        h[AVR.SREG] = .statusRegister
        for timer in timers {
            let spec = timer.spec
            switch spec.kind {
            case .standard16:
                h[spec.count] = .count16Low(timer)
                h[spec.count + 1] = .count16High(timer)
                for (unit, address) in spec.compare.enumerated() {
                    h[address] = .compare16Low(timer, unit)
                    h[address + 1] = .compare16High(timer, unit)
                }
                h[spec.capture] = .capture16Low(timer)
                h[spec.capture + 1] = .capture16High(timer)
                h[spec.controlB] = .clockSelect(timer)
            case .standard8:
                h[spec.count] = .count8(timer)
                for (unit, address) in spec.compare.enumerated() { h[address] = .compare8(timer, unit) }
                h[spec.controlB] = .clockSelect(timer)
            case .tiny1:
                h[spec.count] = .count8(timer)
                for (unit, address) in spec.compare.enumerated() { h[address] = .compare8(timer, unit) }
                h[spec.controlA] = .clockSelect(timer)  // TCCR1 holds the clock select
                h[spec.top] = .top(timer)
            }
        }
        for usart in usarts {
            let spec = usart.spec
            h[spec.dataRegister] = .usartData(usart)
            h[spec.statusA] = .usartStatus(usart)
            h[spec.controlB] = .usartControl(usart)
            h[spec.rateLow] = .usartRate(usart)
        }
        h[variant.adc.control] = .adcControl
        for spec in variant.externalInterrupts { h[spec.control] = .externalControl }
        for spec in variant.pinChanges { h[spec.mask] = .pinChangeMask }
        h[variant.eepromRegisters.control] = .eepromControl
        if let spec = variant.spi {
            h[spec.control] = .spiControl
            h[spec.status] = .spiStatus
            h[spec.dataRegister] = .spiData
        }
        if let spec = variant.twi {
            h[spec.control] = .twiControl
            h[spec.status] = .twiStatus
            h[spec.dataRegister] = .twiData
        }
        return h
    }

    /// Power-on reset: registers cleared, the program from the start (flash and EEPROM kept)
    public func reset() {
        data.update(repeating: 0, count: dataSize)
        pc = 0
        cycles = 0
        let sp = dataSize - 1
        data[AVR.SPL] = UInt8(truncatingIfNeeded: sp)
        data[AVR.SPH] = UInt8(truncatingIfNeeded: sp >> 8)
        for timer in timers { timer.reset() }
        for usart in usarts {
            usart.reset()
            if !transmitDoubleBuffered { data[usart.spec.controlB] = 0x08 }
        }
        spi?.reset()
        twi?.reset()
        adcDoneAt = nil
        adcFirst = false
        interruptDelay = 0
        externalPrevious = [Bool](repeating: false, count: externalPrevious.count)
        externalWatch = false
        pinChangePrevious = [Int](repeating: 0, count: pinChangePrevious.count)
        pinChangeWatch = false
        interruptsChanged = true
        nextInterrupt = nil
        servicedAt = cycles
        nextService = 0
    }

    /// Behaves as simavr does where it differs from the chip, to compare with it instruction by instruction
    func simavrMode() {
        interruptCycles = 0
        enableDelay = 2
        transmitDoubleBuffered = false
        flagsClearOnWrite = false
        pwmDoubleBuffered = false
        for usart in usarts { data[usart.spec.controlB] = 0x08 }
        peripheralsTouched()
    }

    /// Takes on another chip's whole state (the sound thread's chip, for the window's simulator to show)
    public func adopt(_ other: Microcontroller) {
        guard let other = other as? AVR, other.dataSize == dataSize else { return }
        data.update(from: other.data, count: dataSize)
        eeprom = other.eeprom
        pc = other.pc
        cycles = other.cycles
        for (timer, source) in zip(timers, other.timers) { timer.adopt(source) }
        for (usart, source) in zip(usarts, other.usarts) { usart.adopt(source) }
        if let spi, let source = other.spi { spi.adopt(source) }
        if let twi, let source = other.twi { twi.adopt(source) }
        adcDoneAt = other.adcDoneAt
        adcFirst = other.adcFirst
        servicedAt = other.servicedAt
        nextService = 0
        interruptDelay = other.interruptDelay
        externalPrevious = other.externalPrevious
        externalWatch = other.externalWatch
        pinChangePrevious = other.pinChangePrevious
        pinChangeWatch = other.pinChangeWatch
        pinHigh = other.pinHigh
        pinVoltages = other.pinVoltages
        interruptsChanged = true
    }

    // MARK: - Running

    /// Runs whole instructions until at least `count` more cycles have passed
    public func run(cycles count: Int) {
        runStart = cycles
        let end = cycles + count
        guard !watchedPins.isEmpty else {
            while cycles < end { step() }
            return
        }
        // the watched pins' levels after each instruction that wrote an I/O register (or after every instruction,
        // where a timer may be driving one), and at each SPI and TWI event, logged where they change
        while cycles < end {
            step()
            if ioWritten {
                ioWritten = false
                timerDrivesWatchedPin = watchedPinDrivenByTimer()
                logWatchedPins(at: cycles)
            } else if timerDrivesWatchedPin {
                logWatchedPins(at: cycles)
            }
        }
    }

    /// Set by a write to a register that can change what a pin does (a port, or a timer's, USART's, SPI's or TWI's
    /// control): only those (and the timers, SPI and TWI as they run) do
    private var ioWritten = false
    /// Those registers, by address, while pins are watched (empty otherwise)
    private var pinRegisters: [Bool] = []

    private func findPinRegisters() -> [Bool] {
        var result = [Bool](repeating: false, count: ioEnd)
        func mark(_ address: Int) { if address >= 0 && address < ioEnd { result[address] = true } }
        for base in variant.ports { (0...2).forEach { mark(base + $0) } }
        for timer in timers {
            mark(timer.spec.controlA)
            mark(timer.spec.controlB)
        }
        for usart in usarts { mark(usart.spec.controlB) }
        if let spi {
            mark(spi.spec.control)
            mark(spi.spec.dataRegister)
        }
        if let twi {
            mark(twi.spec.control)
            mark(twi.spec.dataRegister)
        }
        return result
    }
    /// Whether a timer drives a watched pin now (its compare output mode is set), which it does without a register
    /// write; it can only start or stop with one
    private var timerDrivesWatchedPin = false

    private func watchedPinDrivenByTimer() -> Bool {
        for timer in timers {
            for unit in 0..<timer.units where timer.compareOutputMode(unit) != 0 {
                if watchedPins.contains(timer.spec.pins[unit]) { return true }
                if timer.spec.kind == .tiny1, unit < timer.spec.complements.count,
                   watchedPins.contains(timer.spec.complements[unit]) {
                    return true
                }
            }
        }
        return false
    }

    /// Where the present run started, for the pin events' times
    private var runStart = 0

    private func logWatchedPins(at cycle: Int) {
        for k in watchedPins.indices {
            let level = drivenLevel(watchedPins[k])
            guard level != watchedLevels[k] else { continue }
            watchedLevels[k] = level
            if let level { pinEvents.append(PinEvent(cycle: cycle - runStart, pin: watchedPins[k], high: level)) }
        }
    }

    public var watchedPins: [Int] = [] {
        didSet {
            watchedLevels = watchedPins.map { drivenLevel($0) }
            timerDrivesWatchedPin = watchedPinDrivenByTimer()
            pinRegisters = watchedPins.isEmpty ? [] : findPinRegisters()
        }
    }
    private var watchedLevels: [Bool?] = []
    private var pinEvents: [PinEvent] = []

    public func takePinEvents() -> [PinEvent] {
        defer { pinEvents.removeAll(keepingCapacity: true) }
        return pinEvents
    }

    /// The level a pin is driven to, or nil while it is an input: what `pinStates` gives it, worked out for one pin
    func drivenLevel(_ index: Int) -> Bool? {
        guard index >= 0 && index < variant.pins.count else { return nil }
        if let twi, twi.enabled {
            if index == twi.spec.sda { return twi.sdaLow ? false : nil }
            if index == twi.spec.scl { return twi.sclLow ? false : nil }
        }
        let pin = variant.pins[index]
        let address = variant.ports[pin.port]
        let mask = UInt8(1) << pin.bit
        let isOutput = data[address + 1] & mask != 0
        if let spi, spi.master {
            if index == spi.spec.miso { return nil }
            if index == spi.spec.sck { return isOutput ? spi.sck : nil }
            if index == spi.spec.mosi { return isOutput ? spi.mosi : nil }
        }
        for usart in usarts {
            let control = data[usart.spec.controlB]
            if control & 0x10 != 0 && index == usart.spec.rxPin { return nil }
            if control & 0x08 != 0 && index == usart.spec.txPin { return true }
        }
        guard isOutput else { return nil }
        for timer in timers {
            for unit in 0..<timer.units {
                let com = timer.compareOutputMode(unit)
                guard com != 0 else { continue }
                if timer.spec.pins[unit] == index { return timer.output[unit] }
                if timer.spec.kind == .tiny1 && com == 1 && timer.pwmUnit(unit) && timer.spec.complements[unit] == index {
                    return !timer.output[unit]
                }
            }
        }
        return data[address + 2] & mask != 0
    }

    /// Runs one instruction, or enters an interrupt
    @discardableResult
    func step() -> Int {
        if interruptDelay == 0 && data[AVR.SREG] & AVR.flagI != 0, let index = pendingInterrupt() {
            let source = sources[index]
            if source.clears { data[source.flag] &= ~source.flagBit }
            interruptsChanged = true
            // an interrupt on a low level asks again for as long as the pin stays low
            if externalWatch { externalInterrupts() }
            pushPC(pc)
            data[AVR.SREG] &= ~AVR.flagI
            pc = source.vector * variant.vectorWords
            tick(interruptCycles)
            return interruptCycles
        }
        if interruptDelay > 0 { interruptDelay -= 1 }
        let used = execute()
        tick(used)
        return used
    }

    /// True when an interrupt will be entered before the next instruction (for comparing with simavr, which enters it
    /// together with the instruction before)
    var interruptReady: Bool {
        interruptDelay == 0 && data[AVR.SREG] & AVR.flagI != 0 && pendingInterrupt() != nil
    }

    // The peripherals are looked at only when one of them has something to do: a timer's next tick, a USART's next
    // byte, the ADC's result, an SPI or TWI clock edge. In between, an instruction only counts its cycles (looking at
    // every peripheral after every instruction made the chip run at little more than real time). A write to an I/O
    // register brings them up to date first and has them looked at after the instruction, as before.

    /// The cycle at which a peripheral next needs looking at (0: after the next instruction)
    private var nextService = 0
    /// The cycle the timers' prescalers were last brought up to
    private var servicedAt = 0

    @inline(__always) private func tick(_ count: Int) {
        cycles += count
        if cycles >= nextService { service() }
    }

    /// Brings the timers' prescalers up to now (no timer is due to tick before then), and has the peripherals looked at
    /// after this instruction: called before an I/O register is written, and when something outside changes the chip
    func peripheralsTouched() {
        let elapsed = cycles - servicedAt
        if elapsed > 0 {
            for timer in timers where timer.prescale != 0 { timer.advance(elapsed) }
        }
        servicedAt = cycles
        nextService = 0
    }

    private func service() {
        let elapsed = cycles - servicedAt
        servicedAt = cycles
        if elapsed > 0 {
            for timer in timers where timer.prescale != 0 { timer.advance(elapsed) }
        }
        for usart in usarts where usart.needsUpdate { usart.update() }
        if let done = adcDoneAt, cycles >= done { adcFinish() }
        // at 8 MHz the SPI clock changes every cycle, more than once within an instruction: watched pins are logged at
        // each of its events
        if let spi {
            while cycles >= spi.nextEvent {
                let at = spi.nextEvent
                spi.advance()
                if !watchedPins.isEmpty { logWatchedPins(at: at) }
            }
        }
        if let twi {
            while cycles >= twi.nextEvent {
                let at = twi.nextEvent
                twi.advance()
                if !watchedPins.isEmpty { logWatchedPins(at: at) }
            }
        }
        var next = Int.max
        for timer in timers where timer.prescale != 0 { next = min(next, cycles + timer.prescale - timer.accumulator) }
        for usart in usarts { next = min(next, usart.nextUpdate) }
        if let done = adcDoneAt { next = min(next, done) }
        if let spi { next = min(next, spi.nextEvent) }
        if let twi { next = min(next, twi.nextEvent) }
        nextService = next
    }

    /// A pin's digital level as the circuit gives it
    func pinLevel(_ pin: Int) -> Bool { pin >= 0 && pin < pinHigh.count && pinHigh[pin] }

    // MARK: - Pins

    private func updateInputLevels() {
        for i in 0..<min(pinVoltages.count, pinHigh.count) {
            let v = pinVoltages[i]
            // CMOS input: high above 0.6 of the supply, low below 0.3, otherwise as it was
            if v > 0.6 * supply {
                pinHigh[i] = true
            } else if v < 0.3 * supply {
                pinHigh[i] = false
            }
        }
        levelsChanged()
    }

    /// What each pin does: driven high or low (by its port, a timer's PWM output or a USART), or an input
    public var pinStates: [PinState] {
        var overrides = [Bool?](repeating: nil, count: pinCount)
        for timer in timers {
            for unit in 0..<timer.units {
                let com = timer.compareOutputMode(unit)
                let pin = timer.spec.pins[unit]
                guard com != 0, pin >= 0 else { continue }
                overrides[pin] = timer.output[unit]
                if timer.spec.kind == .tiny1 && com == 1 && timer.pwmUnit(unit) {
                    overrides[timer.spec.complements[unit]] = !timer.output[unit]
                }
            }
        }
        var result: [PinState] = []
        result.reserveCapacity(pinCount)
        for (index, pin) in variant.pins.enumerated() {
            let address = variant.ports[pin.port]
            let mask = UInt8(1) << pin.bit
            let level = data[address + 2] & mask != 0
            if data[address + 1] & mask != 0 {
                result.append(.output(high: overrides[index] ?? level))
            } else {
                result.append(.input(pullUp: level))
            }
        }
        for usart in usarts {
            let control = data[usart.spec.controlB]
            if control & 0x08 != 0 { result[usart.spec.txPin] = .output(high: true) }  // the transmitter idles high
            if control & 0x10 != 0 {
                let pin = variant.pins[usart.spec.rxPin]
                result[usart.spec.rxPin] = .input(pullUp: data[variant.ports[pin.port] + 2] & (1 << pin.bit) != 0)
            }
        }
        if let spi, spi.master {
            // the SPI drives SCK and MOSI (where they are outputs) and reads MISO
            let spec = spi.spec
            if case .output = result[spec.sck] { result[spec.sck] = .output(high: spi.sck) }
            if case .output = result[spec.mosi] { result[spec.mosi] = .output(high: spi.mosi) }
            result[spec.miso] = .input(pullUp: portBit(spec.miso))
        }
        if let twi, twi.enabled {
            // open drain: pulled low, or let go (to the pull-up, if the port has it on)
            for (pin, low) in [(twi.spec.sda, twi.sdaLow), (twi.spec.scl, twi.sclLow)] {
                result[pin] = low ? .output(high: false) : .input(pullUp: portBit(pin))
            }
        }
        return result
    }

    /// The PORTx bit of a pin (its output level, or its pull-up)
    private func portBit(_ pin: Int) -> Bool {
        let bit = variant.pins[pin]
        return data[variant.ports[bit.port] + 2] & (1 << bit.bit) != 0
    }

    private func pinRegister(_ port: Int) -> UInt8 {
        let address = variant.ports[port]
        var value: UInt8 = 0
        for (bit, pin) in portPins[port].enumerated() where pin >= 0 && pinHigh[pin] { value |= 1 << bit }
        // driven pins read back what they drive
        let ddr = data[address + 1]
        let out = data[address + 2]
        return value & ~ddr | out & ddr
    }

    // MARK: - Data space

    func read(_ address: Int) -> UInt8 {
        if address < 0x20 || address >= ioEnd { return address < dataSize ? data[address] : 0 }
        switch handlers[address] {
        case .pin(let port): return pinRegister(port)
        case .count8(let timer): return UInt8(truncatingIfNeeded: timer.count)
        case .compare8(let timer, let unit): return UInt8(truncatingIfNeeded: timer.ocrBuffer[unit])
        case .top(let timer): return UInt8(truncatingIfNeeded: timer.topC)
        case .count16Low(let timer):
            timer.temp = UInt8(truncatingIfNeeded: timer.count >> 8)
            return UInt8(truncatingIfNeeded: timer.count)
        case .capture16Low(let timer):
            timer.temp = UInt8(truncatingIfNeeded: timer.icr >> 8)
            return UInt8(truncatingIfNeeded: timer.icr)
        case .count16High(let timer), .capture16High(let timer): return timer.temp
        case .compare16Low(let timer, let unit): return UInt8(truncatingIfNeeded: timer.ocrBuffer[unit])
        case .compare16High(let timer, let unit): return UInt8(truncatingIfNeeded: timer.ocrBuffer[unit] >> 8)
        case .usartData(let usart): return usart.readData()
        case .spiStatus: return spi?.readStatus() ?? data[address]
        case .spiData: return spi?.readData() ?? data[address]
        case .twiStatus: return twi?.readStatus() ?? data[address]
        default: return data[address]
        }
    }

    func write(_ address: Int, _ value: UInt8) {
        let d = data
        if address < 0x20 || address >= ioEnd {
            if address < dataSize { d[address] = value }
            return
        }
        peripheralsTouched()
        if address < pinRegisters.count && pinRegisters[address] { ioWritten = true }
        switch handlers[address] {
        case .plain:
            d[address] = value
        case .pin:
            d[address + 2] ^= value  // writing 1 to PINx toggles PORTx
            levelsChanged()
        case .levels:
            d[address] = value
            levelsChanged()
        case .clear:
            d[address] &= ~value  // writing 1 clears a flag
            interruptsChanged = true
        case .mask:
            d[address] = value
            interruptsChanged = true
            // an interrupt on a low level enabled while the pin is low
            if externalWatch { externalInterrupts() }
        case .statusRegister:
            if value & AVR.flagI != 0 && d[AVR.SREG] & AVR.flagI == 0 { interruptDelay = enableDelay }
            d[AVR.SREG] = value
        case .count8(let timer):
            timer.count = Int(value)
        case .compare8(let timer, let unit):
            timer.writeCompare(unit, Int(value))
        case .top(let timer):
            timer.topC = Int(value)
        case .count16High(let timer), .compare16High(let timer, _), .capture16High(let timer):
            timer.temp = value
        case .count16Low(let timer):
            timer.count = Int(timer.temp) << 8 | Int(value)
        case .compare16Low(let timer, let unit):
            timer.writeCompare(unit, Int(timer.temp) << 8 | Int(value))
        case .capture16Low(let timer):
            timer.icr = Int(timer.temp) << 8 | Int(value)
        case .clockSelect(let timer):
            let mask: UInt8 = timer.spec.kind == .tiny1 ? 0x0F : 7
            // the prescaler starts over when the clock changes
            if (d[address] ^ value) & mask != 0 { timer.accumulator = 0 }
            d[address] = value
            timer.updatePrescale()
        case .usartData(let usart):
            usart.writeData(value)
        case .usartStatus(let usart):
            usart.writeStatus(value)
        case .usartControl(let usart):
            usart.writeControl(value)
        case .usartRate(let usart):
            if transmitDoubleBuffered { d[address] = value } else { usart.writeRateLow(value) }
        case .adcControl:
            adcControlWrite(value)
        case .externalControl:
            d[address] = value
            // edges are watched from now on, starting from the present levels; a low level (sense 0) is watched too
            externalWatch = !variant.externalInterrupts.isEmpty
            for (k, spec) in variant.externalInterrupts.enumerated() { externalPrevious[k] = externalLevel(spec.pin) }
            externalInterrupts()
        case .pinChangeMask:
            d[address] = value
            pinChangeWatch = false
            for (k, spec) in variant.pinChanges.enumerated() {
                pinChangePrevious[k] = pinChangeLevels(spec.pins)
                if d[spec.mask] != 0 { pinChangeWatch = true }
            }
        case .eepromControl:
            eepromControlWrite(value)
        case .spiControl:
            spi?.writeControl(value)
        case .spiStatus:
            spi?.writeStatus(value)
        case .spiData:
            spi?.writeData(value)
        case .twiControl:
            twi?.writeControl(value)
        case .twiStatus:
            twi?.writeStatus(value)
        case .twiData:
            twi?.writeData(value)
        }
    }

    private func writeBit(_ address: Int, _ bit: Int, _ value: Bool) {
        peripheralsTouched()
        let mask = UInt8(1) << bit
        switch handlers[address] {
        case .pin:
            if value {
                data[address + 2] ^= mask
                levelsChanged()
            }
        case .clear:
            if value {
                data[address] &= ~mask
                interruptsChanged = true
            }
        default:
            let current = read(address)
            write(address, value ? current | mask : current & ~mask)
        }
    }

    // MARK: - EEPROM

    private func eepromControlWrite(_ value: UInt8) {
        let d = data
        let registers = variant.eepromRegisters
        d[registers.control] = value
        let cell = (Int(d[registers.high]) << 8 | Int(d[registers.low])) & (eeprom.count - 1)
        if value & 0x01 != 0 {
            d[registers.data] = eeprom[cell]
            d[registers.control] &= ~0x01
        }
        if value & 0x02 != 0 {
            eeprom[cell] = d[registers.data]
            d[registers.control] &= ~0x06
        }
    }

    // MARK: - ADC

    private func adcControlWrite(_ value: UInt8) {
        let d = data
        let control = variant.adc.control
        let old = d[control]
        var new = value & ~0x10 | old & 0x10
        if value & 0x10 != 0 && flagsClearOnWrite { new &= ~0x10 }  // writing 1 clears ADIF
        if old & 0x40 != 0 { new |= 0x40 }  // a conversion in progress cannot be stopped by writing 0 to ADSC
        // the first conversion after enabling takes 25 ADC clocks, not 13
        if old & 0x80 == 0 && new & 0x80 != 0 { adcFirst = true }
        if old & 0x80 != 0 && new & 0x80 == 0 {
            adcDoneAt = nil
            new &= ~0x40
        }
        d[control] = new
        interruptsChanged = true
        if old & 0x40 == 0 && new & 0x40 != 0 && new & 0x80 != 0 {
            let prescale = [2, 2, 4, 8, 16, 32, 64, 128][Int(new & 7)]
            adcDoneAt = cycles + (adcFirst ? 25 : 13) * prescale
        }
    }

    private func adcFinish() {
        let d = data
        let adc = variant.adc
        let admux = Int(d[adc.multiplexer])
        var mux = admux & adc.muxMask
        let refs: Int
        if adc.tiny {
            refs = (admux >> 6) & 3 | ((admux >> 4) & 1) << 2
        } else {
            if adc.mux5 && d[adc.controlB] & 0x08 != 0 { mux |= 0x20 }
            refs = (admux >> 6) & 3
        }
        let source = adc.channels[mux]
        let volts = source == AVRVariant.adcGround ? 0 : (source == AVRVariant.adcBandgap ? 1.1 : pinVoltages[source])
        let reference = adc.references[refs] == 0 ? supply : adc.references[refs]
        var value = max(0, min(1023, Int((volts / max(reference, 0.1) * 1024).rounded(.down))))
        if admux & 0x20 != 0 { value <<= 6 }  // left adjusted
        d[adc.low] = UInt8(truncatingIfNeeded: value)
        d[adc.high] = UInt8(truncatingIfNeeded: value >> 8)
        let control = d[adc.control]
        if control & 0x80 != 0 && control & 0x20 != 0 && d[adc.controlB] & 0x07 == 0 {
            // auto trigger in free-running mode: the next conversion starts at once
            d[adc.control] = control | 0x10
            adcDoneAt = cycles + 13 * [2, 2, 4, 8, 16, 32, 64, 128][Int(control & 7)]
        } else {
            d[adc.control] = control & ~0x40 | 0x10
            adcDoneAt = nil
        }
        adcFirst = false
        interruptsChanged = true
    }

    // MARK: - Interrupts

    /// Pin levels may have changed (an input voltage, PORT or DDR): look for edges
    private func levelsChanged() {
        if externalWatch { externalInterrupts() }
        if pinChangeWatch { pinChangeInterrupts() }
    }

    /// What an interrupt pin sees: the circuit's level, or what the pin drives
    private func externalLevel(_ pin: Int) -> Bool {
        let place = variant.pins[pin]
        let address = variant.ports[place.port]
        if data[address + 1] >> place.bit & 1 != 0 { return data[address + 2] >> place.bit & 1 != 0 }
        return pinHigh[pin]
    }

    private func externalInterrupts() {
        let d = data
        for (k, spec) in variant.externalInterrupts.enumerated() {
            let level = externalLevel(spec.pin)
            let sense = Int(d[spec.control]) >> spec.shift & 3
            let previous = externalPrevious[k]
            if sense == 0 {
                // a low level asks while it lasts (when the interrupt is enabled), with no edge needed
                let asking = !level && d[spec.mask] & spec.maskBit != 0
                if asking != (d[spec.flag] & spec.flagBit != 0) {
                    if asking { d[spec.flag] |= spec.flagBit } else { d[spec.flag] &= ~spec.flagBit }
                    interruptsChanged = true
                }
            } else if (sense == 1 && level != previous) || (sense == 2 && previous && !level) || (sense == 3 && level && !previous) {
                d[spec.flag] |= spec.flagBit
                interruptsChanged = true
            }
            externalPrevious[k] = level
        }
    }

    private func pinChangeLevels(_ pins: [Int]) -> Int {
        var value = 0
        for (bit, pin) in pins.enumerated() where pin >= 0 && externalLevel(pin) { value |= 1 << bit }
        return value
    }

    private func pinChangeInterrupts() {
        let d = data
        for (k, spec) in variant.pinChanges.enumerated() {
            let levels = pinChangeLevels(spec.pins)
            if (levels ^ pinChangePrevious[k]) & Int(d[spec.mask]) != 0 {
                d[spec.flag] |= spec.flagBit
                interruptsChanged = true
            }
            pinChangePrevious[k] = levels
        }
    }

    /// The highest-priority interrupt that is enabled and flagged (an index into the sources)
    private func pendingInterrupt() -> Int? {
        if interruptsChanged {
            let d = data
            nextInterrupt = nil
            for (index, source) in sources.enumerated()
            where d[source.mask] & source.maskBit != 0 && d[source.flag] & source.flagBit != 0 {
                nextInterrupt = index
                break
            }
            interruptsChanged = false
        }
        return nextInterrupt
    }

    // MARK: - Stack

    private func push(_ value: UInt8) {
        let sp = Int(data[AVR.SPL]) | Int(data[AVR.SPH]) << 8
        if sp < dataSize { data[sp] = value }
        let next = (sp - 1) & 0xFFFF
        data[AVR.SPL] = UInt8(truncatingIfNeeded: next)
        data[AVR.SPH] = UInt8(truncatingIfNeeded: next >> 8)
    }

    private func pop() -> UInt8 {
        let sp = ((Int(data[AVR.SPL]) | Int(data[AVR.SPH]) << 8) + 1) & 0xFFFF
        data[AVR.SPL] = UInt8(truncatingIfNeeded: sp)
        data[AVR.SPH] = UInt8(truncatingIfNeeded: sp >> 8)
        return sp < dataSize ? data[sp] : 0
    }

    private func pushPC(_ value: Int) {
        push(UInt8(truncatingIfNeeded: value))
        push(UInt8(truncatingIfNeeded: value >> 8))
        if threeBytePC { push(UInt8(truncatingIfNeeded: value >> 16)) }
    }

    private func popPC() -> Int {
        var value = Int(pop())
        value = value << 8 | Int(pop())
        if threeBytePC { value = value << 8 | Int(pop()) }
        return value & pcMask
    }

    // MARK: - Flags

    @inline(__always) private func setFlags(_ mask: UInt8, _ values: UInt8) {
        data[AVR.SREG] = data[AVR.SREG] & ~mask | values
    }

    /// Flags of an 8-bit addition a + b (+ carry) giving `result`; returns the 8-bit result
    @inline(__always) private func flagsAdd(_ a: Int, _ b: Int, _ result: Int) -> UInt8 {
        let r = result & 0xFF
        let carries = (a & b) | (b & ~r) | (~r & a)
        let overflow = ((a & b & ~r) | (~a & ~b & r)) & 0x80 != 0
        let negative = r & 0x80 != 0
        var f: UInt8 = 0
        if carries & 0x80 != 0 { f |= AVR.flagC }
        if r == 0 { f |= AVR.flagZ }
        if negative { f |= AVR.flagN }
        if overflow { f |= AVR.flagV }
        if carries & 0x08 != 0 { f |= AVR.flagH }
        if negative != overflow { f |= AVR.flagS }
        setFlags(AVR.flagC | AVR.flagZ | AVR.flagN | AVR.flagV | AVR.flagS | AVR.flagH, f)
        return UInt8(r)
    }

    /// Flags of a - b (- carry) giving `result`; with `keepZ` (SBC, SBCI, CPC) Z only stays set if it was
    @inline(__always) private func flagsSubtract(_ a: Int, _ b: Int, _ result: Int, keepZ: Bool = false) -> UInt8 {
        let r = result & 0xFF
        let borrows = (~a & b) | (b & r) | (r & ~a)
        let overflow = ((a & ~b & ~r) | (~a & b & r)) & 0x80 != 0
        let negative = r & 0x80 != 0
        var f: UInt8 = 0
        if borrows & 0x80 != 0 { f |= AVR.flagC }
        if negative { f |= AVR.flagN }
        if overflow { f |= AVR.flagV }
        if borrows & 0x08 != 0 { f |= AVR.flagH }
        if negative != overflow { f |= AVR.flagS }
        if r == 0 && (!keepZ || data[AVR.SREG] & AVR.flagZ != 0) { f |= AVR.flagZ }
        setFlags(AVR.flagC | AVR.flagZ | AVR.flagN | AVR.flagV | AVR.flagS | AVR.flagH, f)
        return UInt8(r)
    }

    @inline(__always) private func flagsLogic(_ value: Int) -> UInt8 {
        let r = value & 0xFF
        let negative = r & 0x80 != 0
        setFlags(AVR.flagZ | AVR.flagN | AVR.flagV | AVR.flagS,
                 (r == 0 ? AVR.flagZ : 0) | (negative ? AVR.flagN | AVR.flagS : 0))
        return UInt8(r)
    }

    @inline(__always) private func shiftFlags(_ register: Int, _ a: Int, _ result: Int) -> Int {
        let r = result & 0xFF
        let carry = a & 1 != 0
        let negative = r & 0x80 != 0
        let overflow = negative != carry
        setFlags(AVR.flagC | AVR.flagZ | AVR.flagN | AVR.flagV | AVR.flagS,
                 (carry ? AVR.flagC : 0) | (r == 0 ? AVR.flagZ : 0) | (negative ? AVR.flagN : 0) | (overflow ? AVR.flagV : 0)
                     | (negative != overflow ? AVR.flagS : 0))
        data[register] = UInt8(r)
        return 1
    }

    private func multiplyResult(_ product: Int, fractional: Bool) -> Int {
        let carry = (product >> 15) & 1
        let result = (fractional ? product << 1 : product) & 0xFFFF
        data[0] = UInt8(truncatingIfNeeded: result)
        data[1] = UInt8(truncatingIfNeeded: result >> 8)
        setFlags(AVR.flagC | AVR.flagZ, (carry != 0 ? AVR.flagC : 0) | (result == 0 ? AVR.flagZ : 0))
        return 2
    }

    @inline(__always) private func signed(_ value: UInt8) -> Int { Int(Int8(bitPattern: value)) }

    private static func instructionWords(_ op: Int) -> Int {
        // LDS, STS, JMP and CALL take two words
        (op & 0xFE0F == 0x9000 || op & 0xFE0F == 0x9200 || op & 0xFE0E == 0x940C || op & 0xFE0E == 0x940E) ? 2 : 1
    }

    private func skip() -> Int {
        let words = AVR.instructionWords(Int(flash[pc]))
        pc = (pc + words) & pcMask
        return 1 + words
    }

    @inline(__always) private func pointer(_ register: Int) -> Int { Int(data[register]) | Int(data[register + 1]) << 8 }

    @inline(__always) private func setPointer(_ register: Int, _ value: Int) {
        data[register] = UInt8(truncatingIfNeeded: value)
        data[register + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func programByte(_ z: Int) -> UInt8 {
        let word = flash[(z >> 1) & pcMask]
        return UInt8(truncatingIfNeeded: z & 1 != 0 ? word >> 8 : word)
    }

    /// RAMPZ:Z for ELPM (Z alone on chips without RAMPZ)
    private func extendedZ() -> Int {
        threeBytePC ? pointer(30) | Int(data[AVR.RAMPZ]) << 16 : pointer(30)
    }

    // MARK: - Instructions

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func execute() -> Int {
        let d = data
        let op = Int(flash[pc])
        pc = (pc + 1) & pcMask
        let rd = (op >> 4) & 0x1F
        let rr = (op & 0x0F) | ((op >> 5) & 0x10)
        let rdHigh = 16 + ((op >> 4) & 0x0F)
        let k8 = (op & 0x0F) | ((op >> 4) & 0xF0)
        let flags = d[AVR.SREG]

        switch op >> 12 {
        case 0x0:
            if op == 0 { return 1 }  // NOP
            switch op & 0xFC00 {
            case 0x0C00:  // ADD
                let a = Int(d[rd]), b = Int(d[rr])
                d[rd] = flagsAdd(a, b, a + b)
                return 1
            case 0x0800:  // SBC
                let a = Int(d[rd]), b = Int(d[rr]), c = Int(flags & AVR.flagC)
                d[rd] = flagsSubtract(a, b, a - b - c, keepZ: true)
                return 1
            case 0x0400:  // CPC
                let a = Int(d[rd]), b = Int(d[rr]), c = Int(flags & AVR.flagC)
                _ = flagsSubtract(a, b, a - b - c, keepZ: true)
                return 1
            default:
                break
            }
            switch op & 0xFF00 {
            case 0x0100:  // MOVW
                let to = ((op >> 4) & 0x0F) * 2, from = (op & 0x0F) * 2
                d[to] = d[from]
                d[to + 1] = d[from + 1]
                return 1
            case 0x0200:  // MULS
                return multiplyResult(signed(d[16 + ((op >> 4) & 0x0F)]) * signed(d[16 + (op & 0x0F)]), fractional: false)
            default:
                break
            }
            let a = d[16 + ((op >> 4) & 7)], b = d[16 + (op & 7)]
            switch op & 0xFF88 {
            case 0x0300: return multiplyResult(signed(a) * Int(b), fractional: false)  // MULSU
            case 0x0308: return multiplyResult(Int(a) * Int(b), fractional: true)  // FMUL
            case 0x0380: return multiplyResult(signed(a) * signed(b), fractional: true)  // FMULS
            case 0x0388: return multiplyResult(signed(a) * Int(b), fractional: true)  // FMULSU
            default: return 1
            }
        case 0x1:
            switch op & 0xFC00 {
            case 0x1C00:  // ADC
                let a = Int(d[rd]), b = Int(d[rr]), c = Int(flags & AVR.flagC)
                d[rd] = flagsAdd(a, b, a + b + c)
            case 0x1800:  // SUB
                let a = Int(d[rd]), b = Int(d[rr])
                d[rd] = flagsSubtract(a, b, a - b)
            case 0x1400:  // CP
                let a = Int(d[rd]), b = Int(d[rr])
                _ = flagsSubtract(a, b, a - b)
            default:  // CPSE
                if d[rd] == d[rr] { return skip() }
            }
            return 1
        case 0x2:
            switch op & 0xFC00 {
            case 0x2000: d[rd] = flagsLogic(Int(d[rd] & d[rr]))  // AND
            case 0x2400: d[rd] = flagsLogic(Int(d[rd] ^ d[rr]))  // EOR
            case 0x2800: d[rd] = flagsLogic(Int(d[rd] | d[rr]))  // OR
            default: d[rd] = d[rr]  // MOV
            }
            return 1
        case 0x3:  // CPI
            let a = Int(d[rdHigh])
            _ = flagsSubtract(a, k8, a - k8)
            return 1
        case 0x4:  // SBCI
            let a = Int(d[rdHigh]), c = Int(flags & AVR.flagC)
            d[rdHigh] = flagsSubtract(a, k8, a - k8 - c, keepZ: true)
            return 1
        case 0x5:  // SUBI
            let a = Int(d[rdHigh])
            d[rdHigh] = flagsSubtract(a, k8, a - k8)
            return 1
        case 0x6:  // ORI
            d[rdHigh] = flagsLogic(Int(d[rdHigh]) | k8)
            return 1
        case 0x7:  // ANDI
            d[rdHigh] = flagsLogic(Int(d[rdHigh]) & k8)
            return 1
        case 0x8, 0xA:  // LDD / STD with displacement from Y or Z (LD / ST Y and Z too)
            let q = (op & 0x07) | ((op >> 7) & 0x18) | ((op >> 8) & 0x20)
            let address = pointer(op & 0x08 != 0 ? 28 : 30) + q
            if op & 0x0200 != 0 {
                write(address, d[rd])
            } else {
                d[rd] = read(address)
            }
            return 2
        case 0x9:
            return execute9(op, rd, rr)
        case 0xB:  // IN / OUT
            let address = (((op >> 5) & 0x30) | (op & 0x0F)) + 0x20
            if op & 0x0800 != 0 {
                write(address, d[rd])
            } else {
                d[rd] = read(address)
            }
            return 1
        case 0xC:  // RJMP
            var k = op & 0x0FFF
            if k & 0x800 != 0 { k -= 0x1000 }
            pc = (pc + k) & pcMask
            return 2
        case 0xD:  // RCALL
            var k = op & 0x0FFF
            if k & 0x800 != 0 { k -= 0x1000 }
            pushPC(pc)
            pc = (pc + k) & pcMask
            return threeBytePC ? 4 : 3
        case 0xE:  // LDI
            d[rdHigh] = UInt8(k8)
            return 1
        default:  // 0xF
            if op & 0xF800 == 0xF000 || op & 0xF800 == 0xF400 {  // BRBS / BRBC
                let bit = UInt8(1) << (op & 7)
                var k = (op >> 3) & 0x7F
                if k & 0x40 != 0 { k -= 0x80 }
                if (flags & bit != 0) == (op & 0x0400 == 0) {
                    pc = (pc + k) & pcMask
                    return 2
                }
                return 1
            }
            let bit = op & 7
            switch op & 0xFE08 {
            case 0xF800:  // BLD
                if flags & AVR.flagT != 0 { d[rd] |= UInt8(1) << bit } else { d[rd] &= ~(UInt8(1) << bit) }
                return 1
            case 0xFA00:  // BST
                setFlags(AVR.flagT, d[rd] >> bit & 1 != 0 ? AVR.flagT : 0)
                return 1
            case 0xFC00:  // SBRC
                return d[rd] >> bit & 1 == 0 ? skip() : 1
            case 0xFE00:  // SBRS
                return d[rd] >> bit & 1 != 0 ? skip() : 1
            default:
                return 1
            }
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func execute9(_ op: Int, _ rd: Int, _ rr: Int) -> Int {
        let d = data
        if op & 0xFC00 == 0x9C00 {  // MUL
            return multiplyResult(Int(d[rd]) * Int(d[rr]), fractional: false)
        }
        if op & 0xFE00 == 0x9000 || op & 0xFE00 == 0x9200 {
            let store = op & 0x0200 != 0
            let mode = op & 0x0F
            switch mode {
            case 0x0:  // LDS / STS
                let address = Int(flash[pc])
                pc = (pc + 1) & pcMask
                if store { write(address, d[rd]) } else { d[rd] = read(address) }
                return 2
            case 0x4, 0x5:  // LPM Rd, Z(+)
                if store { return 1 }  // XCH, LAS are not on these chips
                let z = pointer(30)
                d[rd] = programByte(z)
                if mode == 0x5 { setPointer(30, (z + 1) & 0xFFFF) }
                return 3
            case 0x6, 0x7:  // ELPM Rd, Z(+)
                if store { return 1 }  // LAC, LAT are not on these chips
                let z = extendedZ()
                d[rd] = programByte(z)
                if mode == 0x7 {
                    setPointer(30, (z + 1) & 0xFFFF)
                    if threeBytePC { d[AVR.RAMPZ] = UInt8(truncatingIfNeeded: (z + 1) >> 16) }
                }
                return 3
            case 0xF:  // PUSH / POP
                if store { push(d[rd]) } else { d[rd] = pop() }
                return 2
            case 0x1, 0x2, 0x9, 0xA, 0xC, 0xD, 0xE:
                let base = mode == 0x1 || mode == 0x2 ? 30 : (mode == 0x9 || mode == 0xA ? 28 : 26)
                let change = mode == 0xC ? 0 : (mode == 0x2 || mode == 0xA || mode == 0xE ? -1 : 1)
                var p = pointer(base)
                if change < 0 { p = (p - 1) & 0xFFFF }
                if store { write(p, d[rd]) } else { d[rd] = read(p) }
                if change > 0 { p = (p + 1) & 0xFFFF }
                setPointer(base, p)
                return 2
            default:
                return 1
            }
        }
        if op & 0xFE00 == 0x9400 {
            switch op & 0x0F {
            case 0x0:  // COM
                let r = ~d[rd]
                let negative = r & 0x80 != 0
                setFlags(AVR.flagC | AVR.flagZ | AVR.flagN | AVR.flagV | AVR.flagS,
                         AVR.flagC | (r == 0 ? AVR.flagZ : 0) | (negative ? AVR.flagN | AVR.flagS : 0))
                d[rd] = r
                return 1
            case 0x1:  // NEG
                let a = d[rd]
                let r = 0 &- a
                let overflow = r == 0x80
                let negative = r & 0x80 != 0
                var f: UInt8 = 0
                if r != 0 { f |= AVR.flagC } else { f |= AVR.flagZ }
                if negative { f |= AVR.flagN }
                if overflow { f |= AVR.flagV }
                if (r | a) & 0x08 != 0 { f |= AVR.flagH }
                if negative != overflow { f |= AVR.flagS }
                setFlags(AVR.flagC | AVR.flagZ | AVR.flagN | AVR.flagV | AVR.flagS | AVR.flagH, f)
                d[rd] = r
                return 1
            case 0x2:  // SWAP
                let a = d[rd]
                d[rd] = a << 4 | a >> 4
                return 1
            case 0x3:  // INC
                let r = d[rd] &+ 1
                let overflow = r == 0x80
                let negative = r & 0x80 != 0
                setFlags(AVR.flagZ | AVR.flagN | AVR.flagV | AVR.flagS,
                         (r == 0 ? AVR.flagZ : 0) | (negative ? AVR.flagN : 0) | (overflow ? AVR.flagV : 0)
                             | (negative != overflow ? AVR.flagS : 0))
                d[rd] = r
                return 1
            case 0x5:  // ASR
                let a = Int(d[rd])
                return shiftFlags(rd, a, (a >> 1) | (a & 0x80))
            case 0x6:  // LSR
                let a = Int(d[rd])
                return shiftFlags(rd, a, a >> 1)
            case 0x7:  // ROR
                let a = Int(d[rd])
                return shiftFlags(rd, a, (a >> 1) | (d[AVR.SREG] & AVR.flagC != 0 ? 0x80 : 0))
            case 0xA:  // DEC
                let r = d[rd] &- 1
                let overflow = r == 0x7F
                let negative = r & 0x80 != 0
                setFlags(AVR.flagZ | AVR.flagN | AVR.flagV | AVR.flagS,
                         (r == 0 ? AVR.flagZ : 0) | (negative ? AVR.flagN : 0) | (overflow ? AVR.flagV : 0)
                             | (negative != overflow ? AVR.flagS : 0))
                d[rd] = r
                return 1
            case 0xC, 0xD:  // JMP
                let k = Int(flash[pc]) | ((op & 0x01F0) << 13) | ((op & 1) << 16)
                pc = k & pcMask
                return 3
            case 0xE, 0xF:  // CALL
                let k = Int(flash[pc]) | ((op & 0x01F0) << 13) | ((op & 1) << 16)
                pushPC((pc + 1) & pcMask)
                pc = k & pcMask
                return threeBytePC ? 5 : 4
            default:
                break
            }
            if op & 0xFF8F == 0x9408 {  // BSET (SEI, SEC…)
                let bit = (op >> 4) & 7
                d[AVR.SREG] |= UInt8(1) << bit
                if bit == 7 { interruptDelay = enableDelay }
                return 1
            }
            if op & 0xFF8F == 0x9488 {  // BCLR
                d[AVR.SREG] &= ~(UInt8(1) << ((op >> 4) & 7))
                return 1
            }
            switch op {
            case 0x9508:  // RET
                pc = popPC()
                return threeBytePC ? 5 : 4
            case 0x9518:  // RETI
                pc = popPC()
                d[AVR.SREG] |= AVR.flagI
                interruptDelay = enableDelay
                return threeBytePC ? 5 : 4
            case 0x95C8:  // LPM (R0)
                d[0] = programByte(pointer(30))
                return 3
            case 0x95D8:  // ELPM (R0)
                d[0] = programByte(extendedZ())
                return 3
            case 0x9409:  // IJMP
                pc = pointer(30) & pcMask
                return 2
            case 0x9419:  // EIJMP
                pc = (pointer(30) | (threeBytePC ? Int(d[AVR.EIND]) << 16 : 0)) & pcMask
                return 2
            case 0x9509:  // ICALL
                pushPC(pc)
                pc = pointer(30) & pcMask
                return threeBytePC ? 4 : 3
            case 0x9519:  // EICALL
                pushPC(pc)
                pc = (pointer(30) | (threeBytePC ? Int(d[AVR.EIND]) << 16 : 0)) & pcMask
                return threeBytePC ? 4 : 3
            default:
                return 1  // SLEEP, WDR, BREAK, SPM
            }
        }
        if op & 0xFE00 == 0x9600 {  // ADIW / SBIW
            let register = 24 + ((op >> 3) & 0x06)
            let k = (op & 0x0F) | ((op >> 2) & 0x30)
            let a = pointer(register)
            let r: Int
            let overflow: Bool
            let carry: Bool
            if op & 0x0100 == 0 {
                r = (a + k) & 0xFFFF
                overflow = ~a & r & 0x8000 != 0
                carry = ~r & a & 0x8000 != 0
            } else {
                r = (a - k) & 0xFFFF
                overflow = a & ~r & 0x8000 != 0
                carry = r & ~a & 0x8000 != 0
            }
            let negative = r & 0x8000 != 0
            setFlags(AVR.flagC | AVR.flagZ | AVR.flagN | AVR.flagV | AVR.flagS,
                     (carry ? AVR.flagC : 0) | (r == 0 ? AVR.flagZ : 0) | (negative ? AVR.flagN : 0) | (overflow ? AVR.flagV : 0)
                         | (negative != overflow ? AVR.flagS : 0))
            setPointer(register, r)
            return 2
        }
        if op & 0xFC00 == 0x9800 {  // CBI, SBIC, SBI, SBIS
            let address = 0x20 + ((op >> 3) & 0x1F)
            let bit = op & 7
            switch op & 0x0300 {
            case 0x0000:
                writeBit(address, bit, false)
                return 2
            case 0x0200:
                writeBit(address, bit, true)
                return 2
            case 0x0100:
                return read(address) >> bit & 1 == 0 ? skip() : 1
            default:
                return read(address) >> bit & 1 != 0 ? skip() : 1
            }
        }
        return 1
    }

    // MARK: - Inspection

    /// General purpose registers r0-r31
    public var registers: [UInt8] { (0..<32).map { data[$0] } }
    public var statusRegister: UInt8 { data[AVR.SREG] }
    public var stackPointer: Int { Int(data[AVR.SPL]) | Int(data[AVR.SPH]) << 8 }
}

/// One of the chip's timer/counters (8 or 16 bits), each with two or three compare units that can drive a pin; or the
/// ATtiny85's timer 1, which counts to OCR1C
final class AVRTimer {
    enum Kind { case normal, ctc, fast, phase }
    enum TopSource { case fixed, ocra, icr, ocrc }

    let spec: AVRVariant.Timer
    let units: Int
    unowned(unsafe) let avr: AVR

    var count = 0
    var down = false
    var accumulator = 0
    /// The clock division in use (0: stopped), from the clock select bits
    private(set) var prescale = 0
    /// Compare values in use, and as written (copied over at TOP or BOTTOM in PWM modes)
    var ocr: [Int]
    var ocrBuffer: [Int]
    var icr = 0
    /// tiny1: OCR1C
    var topC = 0xFF
    /// Compare output pin states
    var output: [Bool]
    /// The 16-bit registers' shared high byte (TEMP)
    var temp: UInt8 = 0

    init(spec: AVRVariant.Timer, avr: AVR) {
        self.spec = spec
        self.avr = avr
        units = spec.compare.count
        ocr = [Int](repeating: 0, count: units)
        ocrBuffer = ocr
        output = [Bool](repeating: false, count: units)
    }

    func reset() {
        count = 0
        down = false
        accumulator = 0
        prescale = 0
        ocr = [Int](repeating: 0, count: units)
        ocrBuffer = ocr
        icr = 0
        topC = 0xFF
        output = [Bool](repeating: false, count: units)
        temp = 0
    }

    func adopt(_ other: AVRTimer) {
        count = other.count
        down = other.down
        accumulator = other.accumulator
        prescale = other.prescale
        ocr = other.ocr
        ocrBuffer = other.ocrBuffer
        icr = other.icr
        topC = other.topC
        output = other.output
        temp = other.temp
    }

    func updatePrescale() {
        let select = spec.kind == .tiny1 ? Int(avr.data[spec.controlA] & 0x0F) : Int(avr.data[spec.controlB] & 7)
        prescale = spec.prescalers[select]
    }

    private var maximum: Int { spec.kind == .standard16 ? 0xFFFF : 0xFF }

    /// The waveform mode: its TOP, its kind and where TOP comes from
    func mode() -> (top: Int, kind: Kind, source: TopSource) {
        let a = Int(avr.data[spec.controlA])
        let b = Int(avr.data[spec.controlB])
        if spec.kind == .tiny1 {
            if a & 0x40 != 0 || b & 0x40 != 0 { return (topC, .fast, .ocrc) }  // PWM1A or PWM1B
            if a & 0x80 != 0 { return (topC, .ctc, .ocrc) }  // CTC1
            return (0xFF, .normal, .fixed)
        }
        let wgm = (a & 3) | ((b >> 1) & (spec.kind == .standard16 ? 0xC : 0x4))
        let found: (Int, Kind, TopSource)
        if spec.kind == .standard8 {
            switch wgm {
            case 1: found = (0xFF, .phase, .fixed)
            case 2: found = (0, .ctc, .ocra)
            case 3: found = (0xFF, .fast, .fixed)
            case 5: found = (0, .phase, .ocra)
            case 7: found = (0, .fast, .ocra)
            default: found = (0xFF, .normal, .fixed)
            }
        } else {
            switch wgm {
            case 1: found = (0xFF, .phase, .fixed)
            case 2: found = (0x1FF, .phase, .fixed)
            case 3: found = (0x3FF, .phase, .fixed)
            case 4: found = (0, .ctc, .ocra)
            case 5: found = (0xFF, .fast, .fixed)
            case 6: found = (0x1FF, .fast, .fixed)
            case 7: found = (0x3FF, .fast, .fixed)
            case 8, 10: found = (0, .phase, .icr)
            case 9, 11: found = (0, .phase, .ocra)
            case 12: found = (0, .ctc, .icr)
            case 14: found = (0, .fast, .icr)
            case 15: found = (0, .fast, .ocra)
            default: found = (0xFFFF, .normal, .fixed)
            }
        }
        let (fixedTop, kind, source) = found
        let top = source == .ocra ? ocr[0] : (source == .icr ? icr : fixedTop)
        return (top, kind, source)
    }

    func writeCompare(_ unit: Int, _ value: Int) {
        ocrBuffer[unit] = value
        let kind = mode().kind
        if kind == .normal || kind == .ctc || spec.kind == .tiny1 || !avr.pwmDoubleBuffered { ocr[unit] = value }
    }

    /// COMnx1:COMnx0: A in bits 7:6, B in 5:4, C in 3:2 of TCCRnA (tiny1: A in TCCR1 5:4, B in GTCCR 5:4)
    func compareOutputMode(_ unit: Int) -> Int {
        if spec.kind == .tiny1 { return Int(avr.data[unit == 0 ? spec.controlA : spec.controlB]) >> 4 & 3 }
        return Int(avr.data[spec.controlA]) >> (6 - 2 * unit) & 3
    }

    /// tiny1: whether the unit is in PWM mode (PWM1A, PWM1B)
    func pwmUnit(_ unit: Int) -> Bool {
        avr.data[unit == 0 ? spec.controlA : spec.controlB] & 0x40 != 0
    }

    private func flag(_ bit: UInt8) {
        avr.data[spec.flagRegister] |= bit
        avr.interruptsChanged = true
    }

    /// What a compare match does to the pin
    private func match(_ unit: Int, _ kind: Kind, _ source: TopSource) {
        let com = compareOutputMode(unit)
        guard com != 0 else { return }
        if spec.kind == .tiny1 {
            if pwmUnit(unit) {
                output[unit] = com == 3  // cleared on match (set at BOTTOM); COM 3 inverted
            } else if com == 1 {
                output[unit].toggle()
            } else {
                output[unit] = com == 3
            }
            return
        }
        switch kind {
        case .normal, .ctc:
            if com == 1 { output[unit].toggle() } else { output[unit] = com == 3 }
        case .fast:
            if com == 2 {
                output[unit] = false
            } else if com == 3 {
                output[unit] = true
            } else if unit == 0 && source == .ocra {
                output[0].toggle()
            }
        case .phase:
            // non-inverting: cleared counting up, set counting down
            if com == 2 {
                output[unit] = down
            } else if com == 3 {
                output[unit] = !down
            } else if unit == 0 && source == .ocra {
                output[0].toggle()
            }
        }
    }

    private func tickTiny1() {
        let (top, kind, _) = mode()
        let old = count
        if count == top && kind != .normal {
            count = 0
            if kind == .fast {
                flag(spec.overflowBit)
                for unit in 0..<units {
                    let com = compareOutputMode(unit)
                    if com != 0 && pwmUnit(unit) { output[unit] = com != 3 }
                }
            }
        } else if count == 0xFF {
            count = 0
            flag(spec.overflowBit)
        } else {
            count += 1
        }
        for unit in 0..<units where old == ocr[unit] {
            flag(spec.compareBits[unit])
            match(unit, kind, .ocrc)
        }
    }

    private func tick() {
        if spec.kind == .tiny1 {
            tickTiny1()
            return
        }
        let (top, kind, source) = mode()
        if kind == .phase {
            if !down {
                count += 1
                if count >= top {
                    count = top
                    down = true
                    // double-buffered compare values are updated at TOP
                    ocr = ocrBuffer
                }
            } else {
                count -= 1
                if count <= 0 {
                    count = 0
                    down = false
                    flag(spec.overflowBit)  // overflow at BOTTOM
                }
            }
            for unit in 0..<units where count == ocr[unit] {
                flag(spec.compareBits[unit])
                match(unit, kind, source)
            }
            return
        }
        let old = count
        var wrapped = false
        if count == top && (kind == .ctc || kind == .fast) {
            count = 0
            wrapped = true
            if kind == .fast { flag(spec.overflowBit) }
        } else if count == maximum {
            count = 0
            wrapped = true
            flag(spec.overflowBit)
        } else {
            count += 1
        }
        // the flag (and the pin) change on the timer clock after the counter equals OCR: in fast PWM the duty is
        // (OCR + 1) / (TOP + 1), and the change at BOTTOM comes after it (OCR = TOP stays high, OCR = 0 gives a
        // one-clock spike)
        for unit in 0..<units where old == ocr[unit] {
            flag(spec.compareBits[unit])
            match(unit, kind, source)
        }
        if kind == .fast && wrapped {
            ocr = ocrBuffer
            for unit in 0..<units {
                let com = compareOutputMode(unit)
                if com == 2 { output[unit] = true } else if com == 3 { output[unit] = false }
            }
        }
    }

    @inline(__always) func advance(_ cycles: Int) {
        accumulator += cycles
        while accumulator >= prescale {
            accumulator -= prescale
            tick()
        }
    }
}

/// A USART: the transmitter (double-buffered, as on the chip) and the receiver, at the rate UBRR sets
final class AVRUSART {
    let spec: AVRVariant.USART
    unowned(unsafe) let avr: AVR

    var output: [UInt8] = []
    var input: [UInt8] = []
    private var busyUntil = 0
    private var pending: UInt8?
    private var receiveNext = 0
    // simavr's transmitter (see AVR.simavrMode)
    private var simCount = 0
    private var simPumpAt: Int?
    private var simCyclesPerByte = 1600

    init(spec: AVRVariant.USART, avr: AVR) {
        self.spec = spec
        self.avr = avr
    }

    func reset() {
        avr.data[spec.statusA] = 0x20  // the transmit buffer starts empty
        avr.data[spec.controlC] = 0x06
        output = []
        // what was typed before a reset is not received after it
        input = []
        busyUntil = 0
        pending = nil
        receiveNext = 0
        simCount = 0
        simPumpAt = nil
        simCyclesPerByte = 1600
    }

    func adopt(_ other: AVRUSART) {
        output = other.output
        input = other.input
        busyUntil = other.busyUntil
        pending = other.pending
        receiveNext = other.receiveNext
    }

    private func frameCycles() -> Int {
        let d = avr.data
        let rate = (Int(d[spec.rateHigh]) << 8 | Int(d[spec.rateLow])) & 0xFFF
        return (d[spec.statusA] & 0x02 != 0 ? 8 : 16) * (rate + 1) * 10
    }

    private func append(_ value: UInt8) {
        output.append(value)
        // keep the last 16 KB
        if output.count > 32_768 { output.removeFirst(output.count - 16_384) }
    }

    func writeData(_ value: UInt8) {
        let d = avr.data
        avr.interruptsChanged = true
        if !avr.transmitDoubleBuffered {
            d[spec.statusA] &= ~0x20
            if d[spec.controlB] & 0x08 != 0 {
                append(value)
                simCount += 1
                if simPumpAt == nil { simPumpAt = avr.cycles + simCyclesPerByte }
            }
            return
        }
        if busyUntil > avr.cycles {
            pending = value
            d[spec.statusA] &= ~0x20  // UDRE: the buffer is full
        } else {
            append(value)
            busyUntil = avr.cycles + frameCycles()
            d[spec.statusA] |= 0x20
        }
        d[spec.statusA] &= ~0x40
    }

    func readData() -> UInt8 {
        let d = avr.data
        let value = d[spec.dataRegister]
        d[spec.statusA] &= ~0x80
        avr.interruptsChanged = true
        return value
    }

    func writeStatus(_ value: UInt8) {
        let d = avr.data
        // only U2X and MPCM are written; writing 1 to TXC clears it
        d[spec.statusA] = (d[spec.statusA] & ~0x03 | value & 0x03) & ~(value & 0x40)
        avr.interruptsChanged = true
    }

    func writeControl(_ value: UInt8) {
        let d = avr.data
        let old = d[spec.controlB]
        d[spec.controlB] = value
        avr.interruptsChanged = true
        guard !avr.transmitDoubleBuffered else { return }
        if old & 0x20 == 0 && value & 0x20 != 0 && value & 0x08 != 0 && simPumpAt == nil { d[spec.statusA] |= 0x20 }
        if old & 0x08 != 0 && value & 0x08 == 0 { d[spec.statusA] &= ~0x20 }
    }

    func writeRateLow(_ value: UInt8) {
        let d = avr.data
        d[spec.rateLow] = value
        let rate = (Int(d[spec.rateHigh]) << 8 | Int(value)) & 0xFFF
        simCyclesPerByte = (rate + 1) * (d[spec.statusA] & 0x02 != 0 ? 8 : 16) * 11
    }

    var needsUpdate: Bool {
        busyUntil != 0 || simPumpAt != nil || (!input.isEmpty && avr.data[spec.controlB] & 0x10 != 0)
    }

    /// The cycle `update` next has something to do at (0: after the next instruction; Int.max: nothing to do)
    var nextUpdate: Int {
        var next = Int.max
        if !avr.transmitDoubleBuffered {
            if let at = simPumpAt { next = at }
        } else if busyUntil != 0 {
            next = busyUntil
        }
        if !input.isEmpty && avr.data[spec.controlB] & 0x10 != 0 {
            // a byte is received once the last one has been read (a read the chip is not told of): until then, looked
            // at after every instruction
            next = min(next, avr.data[spec.statusA] & 0x80 == 0 ? receiveNext : 0)
        }
        return next
    }

    func update() {
        let d = avr.data
        let cycles = avr.cycles
        if !avr.transmitDoubleBuffered {
            while let at = simPumpAt, cycles >= at { simavrPump() }
        } else if busyUntil != 0 && cycles >= busyUntil {
            if let next = pending {
                append(next)
                pending = nil
                busyUntil += frameCycles()
                d[spec.statusA] |= 0x20
            } else {
                busyUntil = 0
                d[spec.statusA] |= 0x40  // TXC
            }
            avr.interruptsChanged = true
        }
        if !input.isEmpty && d[spec.controlB] & 0x10 != 0 && cycles >= receiveNext && d[spec.statusA] & 0x80 == 0 {
            d[spec.dataRegister] = input.removeFirst()
            d[spec.statusA] |= 0x80
            receiveNext = cycles + frameCycles()
            avr.interruptsChanged = true
        }
    }

    // simavr's transmitter: UDRE raised once per byte time (11 bits) while bytes are queued or UDRIE is on
    private func simavrPump() {
        let d = avr.data
        guard let when = simPumpAt else { return }
        simPumpAt = nil
        if simCount > 0 {
            if simCount == 1 { d[spec.statusA] |= 0x40 }
            simCount -= 1
        }
        if simCount > 0 {
            d[spec.statusA] &= ~0x20
            simPumpAt = when + simCyclesPerByte
        } else if d[spec.controlB] & 0x08 != 0 {
            d[spec.statusA] |= 0x20
            if d[spec.controlB] & 0x20 != 0 { simPumpAt = when + simCyclesPerByte }
        }
        avr.interruptsChanged = true
    }
}
