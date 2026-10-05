import Foundation

/// An ATmega328P (the chip of the Arduino Uno) running its firmware: the AVR CPU with its full instruction set and
/// cycle counts, the three timers with PWM, the ADC, the I/O ports with pull-ups, the external interrupts, the USART
/// and the EEPROM.
///
/// It was written against a reference model checked instruction by instruction against simavr; where simavr differs
/// from the datasheet (interrupt entry cycles, how long interrupts wait after SEI, the single-buffered transmitter,
/// the ADC flag) the datasheet is followed, and `simavrMode()` switches to simavr's behaviour for comparing with it.
///
/// Pins are numbered as on the Uno: 0-7 are D0-D7 (port D), 8-13 are D8-D13 (port B), 14-19 are A0-A5 (port C).
public final class AVR {
    public static let pinCount = 20
    public static let clock = 16_000_000.0

    // data space addresses
    static let PINB = 0x23, DDRB = 0x24, PORTB = 0x25, PINC = 0x26, DDRC = 0x27, PORTC = 0x28
    static let PIND = 0x29, DDRD = 0x2A, PORTD = 0x2B
    static let TIFR0 = 0x35, TIFR1 = 0x36, TIFR2 = 0x37, PCIFR = 0x3B, EIFR = 0x3C, EIMSK = 0x3D
    static let EECR = 0x3F, EEDR = 0x40, EEARL = 0x41, EEARH = 0x42
    static let TCCR0A = 0x44, TCCR0B = 0x45, TCNT0 = 0x46, OCR0A = 0x47, OCR0B = 0x48
    static let SPL = 0x5D, SPH = 0x5E, SREG = 0x5F
    static let PCICR = 0x68, EICRA = 0x69, TIMSK0 = 0x6E, TIMSK1 = 0x6F, TIMSK2 = 0x70
    static let ADCL = 0x78, ADCH = 0x79, ADCSRA = 0x7A, ADCSRB = 0x7B, ADMUX = 0x7C
    static let TCCR1A = 0x80, TCCR1B = 0x81, TCNT1L = 0x84, TCNT1H = 0x85, ICR1L = 0x86, ICR1H = 0x87
    static let OCR1AL = 0x88, OCR1AH = 0x89, OCR1BL = 0x8A, OCR1BH = 0x8B
    static let TCCR2A = 0xB0, TCCR2B = 0xB1, TCNT2 = 0xB2, OCR2A = 0xB3, OCR2B = 0xB4
    static let UCSR0A = 0xC0, UCSR0B = 0xC1, UCSR0C = 0xC2, UBRR0L = 0xC4, UBRR0H = 0xC5, UDR0 = 0xC6

    // status register bits
    static let flagC: UInt8 = 1, flagZ: UInt8 = 2, flagN: UInt8 = 4, flagV: UInt8 = 8
    static let flagS: UInt8 = 16, flagH: UInt8 = 32, flagT: UInt8 = 64, flagI: UInt8 = 128

    /// Program memory, 16K words
    private let flash: UnsafeMutablePointer<UInt16>
    /// Registers, I/O and SRAM
    let data: UnsafeMutablePointer<UInt8>
    static let dataSize = 0x900
    public private(set) var eeprom = [UInt8](repeating: 0xFF, count: 1024)

    public private(set) var pc = 0
    public private(set) var cycles: Int = 0
    var timers: [AVRTimer] = []
    /// The 16-bit timer's shared high byte (TEMP)
    private var temp16: UInt8 = 0

    /// Pin voltages the chip sees, set by the circuit before it runs; the digital levels follow them with hysteresis
    public var pinVoltages = [Double](repeating: 0, count: AVR.pinCount) {
        didSet { updateInputLevels() }
    }
    public private(set) var pinHigh = [Bool](repeating: false, count: AVR.pinCount)
    /// Supply and ADC reference voltage
    public var supply = 5.0

    /// Bytes the USART has sent, oldest first, and bytes waiting to be received
    public var serialOutput: [UInt8] = []
    public var serialInput: [UInt8] = []
    private var transmitBusyUntil = 0
    private var transmitPending: UInt8?
    private var receiveNext = 0
    private var adcDoneAt: Int?
    private var adcFirst = false
    private var interruptDelay = 0
    private var externalPrevious = [false, false]

    // behaviour that differs between the chip and simavr
    var interruptCycles = 4
    var enableDelay = 1
    var transmitDoubleBuffered = true
    var flagsClearOnWrite = true
    private var simTransmitCount = 0
    private var simPumpAt: Int?
    private var simCyclesPerByte = 1600

    public init(firmware: [UInt8]) {
        flash = UnsafeMutablePointer<UInt16>.allocate(capacity: 16_384)
        flash.initialize(repeating: 0, count: 16_384)
        data = UnsafeMutablePointer<UInt8>.allocate(capacity: AVR.dataSize)
        data.initialize(repeating: 0, count: AVR.dataSize)
        var i = 0
        while i < min(firmware.count, 32_768) {
            let low = UInt16(firmware[i])
            let high = i + 1 < firmware.count ? UInt16(firmware[i + 1]) : 0
            flash[i / 2] = low | high << 8
            i += 2
        }
        timers = [
            AVRTimer(index: 0, bits: 8, tccra: AVR.TCCR0A, tccrb: AVR.TCCR0B, timsk: AVR.TIMSK0, tifr: AVR.TIFR0,
                     prescalers: [0, 1, 8, 64, 256, 1024, 0, 0], pins: (6, 5)),
            AVRTimer(index: 1, bits: 16, tccra: AVR.TCCR1A, tccrb: AVR.TCCR1B, timsk: AVR.TIMSK1, tifr: AVR.TIFR1,
                     prescalers: [0, 1, 8, 64, 256, 1024, 0, 0], pins: (9, 10)),
            AVRTimer(index: 2, bits: 8, tccra: AVR.TCCR2A, tccrb: AVR.TCCR2B, timsk: AVR.TIMSK2, tifr: AVR.TIFR2,
                     prescalers: [0, 1, 8, 32, 64, 128, 256, 1024], pins: (11, 3)),
        ]
        reset()
    }

    deinit {
        flash.deallocate()
        data.deallocate()
    }

    /// Power-on reset: registers cleared, the program from the start (flash and EEPROM kept)
    public func reset() {
        data.update(repeating: 0, count: AVR.dataSize)
        pc = 0
        cycles = 0
        data[AVR.SPL] = 0xFF
        data[AVR.SPH] = 0x08
        data[AVR.UCSR0A] = 0x20
        data[AVR.UCSR0C] = 0x06
        for timer in timers { timer.reset() }
        temp16 = 0
        serialOutput = []
        transmitBusyUntil = 0
        transmitPending = nil
        receiveNext = 0
        adcDoneAt = nil
        adcFirst = false
        interruptDelay = 0
        externalPrevious = [false, false]
        simTransmitCount = 0
        simPumpAt = nil
        simCyclesPerByte = 1600
        if !transmitDoubleBuffered { data[AVR.UCSR0B] = 0x08 }
    }

    /// Behaves as simavr does where it differs from the chip, to compare with it instruction by instruction
    func simavrMode() {
        interruptCycles = 0
        enableDelay = 2
        transmitDoubleBuffered = false
        flagsClearOnWrite = false
        data[AVR.UCSR0B] = 0x08
    }

    /// Takes on another chip's whole state (the sound thread's chip, for the window's simulator to show)
    public func adopt(_ other: AVR) {
        data.update(from: other.data, count: AVR.dataSize)
        eeprom = other.eeprom
        pc = other.pc
        cycles = other.cycles
        for (timer, source) in zip(timers, other.timers) { timer.adopt(source) }
        temp16 = other.temp16
        pinVoltages = other.pinVoltages
        pinHigh = other.pinHigh
        serialOutput = other.serialOutput
        transmitBusyUntil = other.transmitBusyUntil
        transmitPending = other.transmitPending
        receiveNext = other.receiveNext
        adcDoneAt = other.adcDoneAt
        adcFirst = other.adcFirst
        interruptDelay = other.interruptDelay
        externalPrevious = other.externalPrevious
    }

    // MARK: - Running

    /// Runs whole instructions until at least `count` more cycles have passed
    public func run(cycles count: Int) {
        let end = cycles + count
        while cycles < end { step() }
    }

    /// Runs one instruction, or enters an interrupt
    @discardableResult
    func step() -> Int {
        if interruptDelay == 0 && data[AVR.SREG] & AVR.flagI != 0, let pending = pendingInterrupt() {
            let (vector, flagRegister, flagBit) = pending
            if flagRegister >= 0 { data[flagRegister] &= ~flagBit }
            pushPC(pc)
            data[AVR.SREG] &= ~AVR.flagI
            pc = vector * 2
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

    private func tick(_ count: Int) {
        cycles += count
        for timer in timers { timer.advance(count, self) }
        if transmitBusyUntil != 0 || simPumpAt != nil || (!serialInput.isEmpty && data[AVR.UCSR0B] & 0x10 != 0) { serialUpdate() }
        if let done = adcDoneAt, cycles >= done { adcFinish() }
        if data[AVR.EICRA] != 0 { externalInterrupts() }
    }

    // MARK: - Pins

    /// The PINx register and bit of each pin
    private static let pinPorts: [(pin: Int, bit: Int)] = {
        var ports: [(pin: Int, bit: Int)] = []
        for bit in 0..<8 { ports.append((pin: AVR.PIND, bit: bit)) }
        for bit in 0..<6 { ports.append((pin: AVR.PINB, bit: bit)) }
        for bit in 0..<6 { ports.append((pin: AVR.PINC, bit: bit)) }
        return ports
    }()

    private func updateInputLevels() {
        for i in 0..<AVR.pinCount {
            let v = pinVoltages[i]
            // CMOS input: high above 0.6 of the supply, low below 0.3, otherwise as it was
            if v > 0.6 * supply {
                pinHigh[i] = true
            } else if v < 0.3 * supply {
                pinHigh[i] = false
            }
        }
    }

    public enum PinState: Equatable {
        case input(pullUp: Bool)
        case output(high: Bool)
    }

    /// What each pin does: driven high or low (by its port, or by a timer's PWM output), or an input
    public var pinStates: [PinState] {
        var result: [PinState] = []
        result.reserveCapacity(AVR.pinCount)
        for (index, port) in AVR.pinPorts.enumerated() {
            let mask = UInt8(1) << port.bit
            let driven = data[port.pin + 1] & mask != 0
            let level = data[port.pin + 2] & mask != 0
            if driven {
                var high = level
                for timer in timers {
                    if timer.pins.0 == index && timer.compareOutputMode(0, self) != 0 { high = timer.output.0 }
                    if timer.pins.1 == index && timer.compareOutputMode(1, self) != 0 { high = timer.output.1 }
                }
                result.append(.output(high: high))
            } else {
                result.append(.input(pullUp: level))
            }
        }
        return result
    }

    private func pinRegister(_ address: Int) -> UInt8 {
        let first = address == AVR.PIND ? 0 : (address == AVR.PINB ? 8 : 14)
        let count = address == AVR.PIND ? 8 : 6
        var value: UInt8 = 0
        for bit in 0..<count where pinHigh[first + bit] { value |= 1 << bit }
        let ddr = data[address + 1]
        let out = data[address + 2]
        return value & ~ddr | out & ddr
    }

    // MARK: - Data space

    func read(_ address: Int) -> UInt8 {
        if address < 0x20 || address >= 0x100 { return address < AVR.dataSize ? data[address] : 0 }
        switch address {
        case AVR.PINB, AVR.PINC, AVR.PIND: return pinRegister(address)
        case AVR.TCNT0: return UInt8(truncatingIfNeeded: timers[0].count)
        case AVR.TCNT2: return UInt8(truncatingIfNeeded: timers[2].count)
        case AVR.TCNT1L:
            let count = timers[1].count
            temp16 = UInt8(truncatingIfNeeded: count >> 8)
            return UInt8(truncatingIfNeeded: count)
        case AVR.TCNT1H: return temp16
        case AVR.OCR0A: return UInt8(truncatingIfNeeded: timers[0].ocrBuffer.0)
        case AVR.OCR0B: return UInt8(truncatingIfNeeded: timers[0].ocrBuffer.1)
        case AVR.OCR2A: return UInt8(truncatingIfNeeded: timers[2].ocrBuffer.0)
        case AVR.OCR2B: return UInt8(truncatingIfNeeded: timers[2].ocrBuffer.1)
        case AVR.UDR0:
            let value = data[AVR.UDR0]
            data[AVR.UCSR0A] &= ~0x80
            return value
        default: return data[address]
        }
    }

    func write(_ address: Int, _ value: UInt8) {
        let d = data
        if address < 0x20 || address >= 0x100 {
            if address < AVR.dataSize { d[address] = value }
            return
        }
        switch address {
        case AVR.PINB, AVR.PINC, AVR.PIND:
            d[address + 2] ^= value  // writing 1 to PINx toggles PORTx
        case AVR.TIFR0, AVR.TIFR1, AVR.TIFR2, AVR.EIFR, AVR.PCIFR:
            d[address] &= ~value  // writing 1 clears a flag
        case AVR.SREG:
            if value & AVR.flagI != 0 && d[AVR.SREG] & AVR.flagI == 0 { interruptDelay = enableDelay }
            d[AVR.SREG] = value
        case AVR.TCNT0: timers[0].count = Int(value)
        case AVR.TCNT2: timers[2].count = Int(value)
        case AVR.OCR0A: timers[0].writeCompare(0, Int(value), self)
        case AVR.OCR0B: timers[0].writeCompare(1, Int(value), self)
        case AVR.OCR2A: timers[2].writeCompare(0, Int(value), self)
        case AVR.OCR2B: timers[2].writeCompare(1, Int(value), self)
        case AVR.TCNT1H, AVR.OCR1AH, AVR.OCR1BH, AVR.ICR1H:
            temp16 = value
        case AVR.TCNT1L, AVR.OCR1AL, AVR.OCR1BL, AVR.ICR1L:
            let full = Int(temp16) << 8 | Int(value)
            if address == AVR.TCNT1L {
                timers[1].count = full
            } else if address == AVR.OCR1AL {
                timers[1].writeCompare(0, full, self)
            } else if address == AVR.OCR1BL {
                timers[1].writeCompare(1, full, self)
            } else {
                timers[1].icr = full
            }
        case AVR.TCCR0B, AVR.TCCR1B, AVR.TCCR2B:
            let timer = timers[address == AVR.TCCR0B ? 0 : (address == AVR.TCCR1B ? 1 : 2)]
            // the prescaler starts over when the clock changes
            if (d[address] ^ value) & 7 != 0 { timer.accumulator = 0 }
            d[address] = value
        case AVR.UDR0:
            serialWrite(value)
        case AVR.UCSR0A:
            // only U2X and MPCM are written; writing 1 to TXC clears it
            d[AVR.UCSR0A] = (d[AVR.UCSR0A] & ~0x03 | value & 0x03) & ~(value & 0x40)
        case AVR.UCSR0B where !transmitDoubleBuffered:
            simavrControlWrite(value)
        case AVR.UBRR0L where !transmitDoubleBuffered:
            d[address] = value
            let rate = Int(d[AVR.UBRR0H]) << 8 | Int(value)
            simCyclesPerByte = ((rate & 0xFFF) + 1) * (d[AVR.UCSR0A] & 0x02 != 0 ? 8 : 16) * 11
        case AVR.ADCSRA:
            adcControlWrite(value)
        case AVR.EICRA:
            // edges are watched from now on: start from the present levels
            d[AVR.EICRA] = value
            for k in 0..<2 { externalPrevious[k] = externalLevel(k) }
        case AVR.EECR:
            d[AVR.EECR] = value
            let cell = (Int(d[AVR.EEARH]) << 8 | Int(d[AVR.EEARL])) & 0x3FF
            if value & 0x01 != 0 {
                d[AVR.EEDR] = eeprom[cell]
                d[AVR.EECR] &= ~0x01
            }
            if value & 0x02 != 0 {
                eeprom[cell] = d[AVR.EEDR]
                d[AVR.EECR] &= ~0x06
            }
        default:
            d[address] = value
        }
    }

    private func writeBit(_ address: Int, _ bit: Int, _ value: Bool) {
        let mask = UInt8(1) << bit
        switch address {
        case AVR.PINB, AVR.PINC, AVR.PIND:
            if value { data[address + 2] ^= mask }
        case AVR.TIFR0, AVR.TIFR1, AVR.TIFR2, AVR.EIFR, AVR.PCIFR:
            if value { data[address] &= ~mask }
        default:
            let current = read(address)
            write(address, value ? current | mask : current & ~mask)
        }
    }

    // MARK: - USART

    private func frameCycles() -> Int {
        let rate = (Int(data[AVR.UBRR0H]) << 8 | Int(data[AVR.UBRR0L])) & 0xFFF
        return (data[AVR.UCSR0A] & 0x02 != 0 ? 8 : 16) * (rate + 1) * 10
    }

    private func serialWrite(_ value: UInt8) {
        let d = data
        if !transmitDoubleBuffered {
            d[AVR.UCSR0A] &= ~0x20
            if d[AVR.UCSR0B] & 0x08 != 0 {
                appendOutput(value)
                simTransmitCount += 1
                if simPumpAt == nil { simPumpAt = cycles + simCyclesPerByte }
            }
            return
        }
        if transmitBusyUntil > cycles {
            transmitPending = value
            d[AVR.UCSR0A] &= ~0x20
        } else {
            appendOutput(value)
            transmitBusyUntil = cycles + frameCycles()
            d[AVR.UCSR0A] |= 0x20
        }
        d[AVR.UCSR0A] &= ~0x40
    }

    private func appendOutput(_ value: UInt8) {
        serialOutput.append(value)
        // keep the last 16 KB
        if serialOutput.count > 32_768 { serialOutput.removeFirst(serialOutput.count - 16_384) }
    }

    private func serialUpdate() {
        let d = data
        if !transmitDoubleBuffered {
            while let at = simPumpAt, cycles >= at { simavrPump() }
        } else if transmitBusyUntil != 0 && cycles >= transmitBusyUntil {
            if let pending = transmitPending {
                appendOutput(pending)
                transmitPending = nil
                transmitBusyUntil += frameCycles()
                d[AVR.UCSR0A] |= 0x20
            } else {
                transmitBusyUntil = 0
                d[AVR.UCSR0A] |= 0x40
            }
        }
        if !serialInput.isEmpty && d[AVR.UCSR0B] & 0x10 != 0 && cycles >= receiveNext && d[AVR.UCSR0A] & 0x80 == 0 {
            d[AVR.UDR0] = serialInput.removeFirst()
            d[AVR.UCSR0A] |= 0x80
            receiveNext = cycles + frameCycles()
        }
    }

    // simavr's transmitter: UDRE raised once per byte time (11 bits) while bytes are queued or UDRIE is on
    private func simavrPump() {
        let d = data
        guard let when = simPumpAt else { return }
        simPumpAt = nil
        if simTransmitCount > 0 {
            if simTransmitCount == 1 { d[AVR.UCSR0A] |= 0x40 }
            simTransmitCount -= 1
        }
        if simTransmitCount > 0 {
            d[AVR.UCSR0A] &= ~0x20
            simPumpAt = when + simCyclesPerByte
        } else if d[AVR.UCSR0B] & 0x08 != 0 {
            d[AVR.UCSR0A] |= 0x20
            if d[AVR.UCSR0B] & 0x20 != 0 { simPumpAt = when + simCyclesPerByte }
        }
    }

    private func simavrControlWrite(_ value: UInt8) {
        let d = data
        let old = d[AVR.UCSR0B]
        d[AVR.UCSR0B] = value
        if old & 0x20 == 0 && value & 0x20 != 0 && value & 0x08 != 0 && simPumpAt == nil { d[AVR.UCSR0A] |= 0x20 }
        if old & 0x08 != 0 && value & 0x08 == 0 { d[AVR.UCSR0A] &= ~0x20 }
    }

    // MARK: - ADC

    private func adcControlWrite(_ value: UInt8) {
        let d = data
        let old = d[AVR.ADCSRA]
        var new = value & ~0x10 | old & 0x10
        if value & 0x10 != 0 && flagsClearOnWrite { new &= ~0x10 }  // writing 1 clears ADIF
        if old & 0x40 != 0 { new |= 0x40 }  // a conversion in progress cannot be stopped by writing 0 to ADSC
        // the first conversion after enabling takes 25 ADC clocks, not 13
        if old & 0x80 == 0 && new & 0x80 != 0 { adcFirst = true }
        if old & 0x80 != 0 && new & 0x80 == 0 {
            adcDoneAt = nil
            new &= ~0x40
        }
        d[AVR.ADCSRA] = new
        if old & 0x40 == 0 && new & 0x40 != 0 && new & 0x80 != 0 {
            let prescale = [2, 2, 4, 8, 16, 32, 64, 128][Int(new & 7)]
            adcDoneAt = cycles + (adcFirst ? 25 : 13) * prescale
        }
    }

    private func adcFinish() {
        let d = data
        let channel = Int(d[AVR.ADMUX] & 0x0F)
        let volts = channel < 6 ? pinVoltages[14 + channel] : (channel == 14 ? 1.1 : 0)
        var value = max(0, min(1023, Int((volts / max(supply, 0.1) * 1024).rounded(.down))))
        if d[AVR.ADMUX] & 0x20 != 0 { value <<= 6 }  // left adjusted
        d[AVR.ADCL] = UInt8(truncatingIfNeeded: value)
        d[AVR.ADCH] = UInt8(truncatingIfNeeded: value >> 8)
        d[AVR.ADCSRA] = d[AVR.ADCSRA] & ~0x40 | 0x10
        adcDoneAt = nil
        adcFirst = false
    }

    // MARK: - Interrupts

    /// The level of INT0 (pin 2) or INT1 (pin 3): what drives it, or what the pin is driven to
    private func externalLevel(_ k: Int) -> Bool {
        let pin = 2 + k
        return data[AVR.DDRD] >> pin & 1 == 0 ? pinHigh[pin] : data[AVR.PORTD] >> pin & 1 != 0
    }

    private func externalInterrupts() {
        let d = data
        for k in 0..<2 {
            let level = externalLevel(k)
            let sense = Int(d[AVR.EICRA]) >> (2 * k) & 3
            let previous = externalPrevious[k]
            if (sense == 1 && level != previous) || (sense == 2 && previous && !level) || (sense == 3 && level && !previous) {
                d[AVR.EIFR] |= UInt8(1) << k
            }
            externalPrevious[k] = level
        }
    }

    /// The highest-priority interrupt that is enabled and flagged: its vector and the flag entering it clears (-1:
    /// none, the flag goes when its cause does)
    private func pendingInterrupt() -> (Int, Int, UInt8)? {
        let d = data
        if d[AVR.EIMSK] & 1 != 0 && d[AVR.EIFR] & 1 != 0 { return (1, AVR.EIFR, 1) }
        if d[AVR.EIMSK] & 2 != 0 && d[AVR.EIFR] & 2 != 0 { return (2, AVR.EIFR, 2) }
        let timerChecks: [(Int, Int, UInt8, Int)] = [
            (AVR.TIMSK2, AVR.TIFR2, 2, 7), (AVR.TIMSK2, AVR.TIFR2, 4, 8), (AVR.TIMSK2, AVR.TIFR2, 1, 9),
            (AVR.TIMSK1, AVR.TIFR1, 2, 11), (AVR.TIMSK1, AVR.TIFR1, 4, 12), (AVR.TIMSK1, AVR.TIFR1, 1, 13),
            (AVR.TIMSK0, AVR.TIFR0, 2, 14), (AVR.TIMSK0, AVR.TIFR0, 4, 15), (AVR.TIMSK0, AVR.TIFR0, 1, 16),
        ]
        for (mask, flags, bit, vector) in timerChecks where d[mask] & bit != 0 && d[flags] & bit != 0 {
            return (vector, flags, bit)
        }
        let b = d[AVR.UCSR0B]
        let a = d[AVR.UCSR0A]
        if b & 0x80 != 0 && a & 0x80 != 0 { return (18, -1, 0) }
        if b & 0x20 != 0 && a & 0x20 != 0 { return (19, -1, 0) }
        if b & 0x40 != 0 && a & 0x40 != 0 { return (20, AVR.UCSR0A, 0x40) }
        if d[AVR.ADCSRA] & 0x18 == 0x18 { return (21, AVR.ADCSRA, 0x10) }
        return nil
    }

    // MARK: - Stack

    private func push(_ value: UInt8) {
        let sp = Int(data[AVR.SPL]) | Int(data[AVR.SPH]) << 8
        if sp < AVR.dataSize { data[sp] = value }
        let next = (sp - 1) & 0xFFFF
        data[AVR.SPL] = UInt8(truncatingIfNeeded: next)
        data[AVR.SPH] = UInt8(truncatingIfNeeded: next >> 8)
    }

    private func pop() -> UInt8 {
        let sp = ((Int(data[AVR.SPL]) | Int(data[AVR.SPH]) << 8) + 1) & 0xFFFF
        data[AVR.SPL] = UInt8(truncatingIfNeeded: sp)
        data[AVR.SPH] = UInt8(truncatingIfNeeded: sp >> 8)
        return sp < AVR.dataSize ? data[sp] : 0
    }

    private func pushPC(_ value: Int) {
        push(UInt8(truncatingIfNeeded: value))
        push(UInt8(truncatingIfNeeded: value >> 8))
    }

    private func popPC() -> Int {
        let high = Int(pop())
        let low = Int(pop())
        return (high << 8 | low) & 0x3FFF
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
        pc = (pc + words) & 0x3FFF
        return 1 + words
    }

    @inline(__always) private func pointer(_ register: Int) -> Int { Int(data[register]) | Int(data[register + 1]) << 8 }

    @inline(__always) private func setPointer(_ register: Int, _ value: Int) {
        data[register] = UInt8(truncatingIfNeeded: value)
        data[register + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func programByte(_ z: Int) -> UInt8 {
        let word = flash[(z >> 1) & 0x3FFF]
        return UInt8(truncatingIfNeeded: z & 1 != 0 ? word >> 8 : word)
    }

    // MARK: - Instructions

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func execute() -> Int {
        let d = data
        let op = Int(flash[pc])
        pc = (pc + 1) & 0x3FFF
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
            pc = (pc + k) & 0x3FFF
            return 2
        case 0xD:  // RCALL
            var k = op & 0x0FFF
            if k & 0x800 != 0 { k -= 0x1000 }
            pushPC(pc)
            pc = (pc + k) & 0x3FFF
            return 3
        case 0xE:  // LDI
            d[rdHigh] = UInt8(k8)
            return 1
        default:  // 0xF
            if op & 0xF800 == 0xF000 || op & 0xF800 == 0xF400 {  // BRBS / BRBC
                let bit = UInt8(1) << (op & 7)
                var k = (op >> 3) & 0x7F
                if k & 0x40 != 0 { k -= 0x80 }
                if (flags & bit != 0) == (op & 0x0400 == 0) {
                    pc = (pc + k) & 0x3FFF
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
                pc = (pc + 1) & 0x3FFF
                if store { write(address, d[rd]) } else { d[rd] = read(address) }
                return 2
            case 0x4, 0x5, 0x6, 0x7:  // LPM Rd, Z(+) (and ELPM: there is no RAMPZ on this chip)
                if store { return 1 }  // XCH, LAS, LAC, LAT are not on this chip
                let z = pointer(30)
                d[rd] = programByte(z)
                if mode & 1 != 0 { setPointer(30, (z + 1) & 0xFFFF) }
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
                return 1  // XCH, LAS, LAC, LAT are not on this chip
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
                pc = k & 0x3FFF
                return 3
            case 0xE, 0xF:  // CALL
                let k = Int(flash[pc]) | ((op & 0x01F0) << 13) | ((op & 1) << 16)
                pushPC((pc + 1) & 0x3FFF)
                pc = k & 0x3FFF
                return 4
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
                return 4
            case 0x9518:  // RETI
                pc = popPC()
                d[AVR.SREG] |= AVR.flagI
                interruptDelay = enableDelay
                return 4
            case 0x95C8:  // LPM (R0)
                d[0] = programByte(pointer(30))
                return 3
            case 0x9409:  // IJMP
                pc = pointer(30) & 0x3FFF
                return 2
            case 0x9509:  // ICALL
                pushPC(pc)
                pc = pointer(30) & 0x3FFF
                return 3
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

/// One of the ATmega328P's timer/counters (two 8-bit, one 16-bit), each with two compare units that can drive a pin
final class AVRTimer {
    enum Kind { case normal, ctc, fast, phase }
    enum TopSource { case fixed, ocra, icr }

    let index: Int
    let bits: Int
    let tccra: Int
    let tccrb: Int
    let timsk: Int
    let tifr: Int
    let prescalers: [Int]
    /// The pins of the A and B compare outputs
    let pins: (Int, Int)

    var count = 0
    var down = false
    var accumulator = 0
    /// Compare values in use, and as written (copied over at TOP or BOTTOM in PWM modes)
    var ocr = (0, 0)
    var ocrBuffer = (0, 0)
    var icr = 0
    /// Compare output pin states, A and B
    var output = (false, false)

    init(index: Int, bits: Int, tccra: Int, tccrb: Int, timsk: Int, tifr: Int, prescalers: [Int], pins: (Int, Int)) {
        self.index = index
        self.bits = bits
        self.tccra = tccra
        self.tccrb = tccrb
        self.timsk = timsk
        self.tifr = tifr
        self.prescalers = prescalers
        self.pins = pins
    }

    func reset() {
        count = 0
        down = false
        accumulator = 0
        ocr = (0, 0)
        ocrBuffer = (0, 0)
        icr = 0
        output = (false, false)
    }

    func adopt(_ other: AVRTimer) {
        count = other.count
        down = other.down
        accumulator = other.accumulator
        ocr = other.ocr
        ocrBuffer = other.ocrBuffer
        icr = other.icr
        output = other.output
    }

    private var maximum: Int { bits == 8 ? 0xFF : 0xFFFF }

    /// The waveform mode: its TOP, its kind and where TOP comes from
    func mode(_ avr: AVR) -> (top: Int, kind: Kind, source: TopSource) {
        let a = Int(avr.data[tccra])
        let b = Int(avr.data[tccrb])
        let wgm = (a & 3) | ((b >> 1) & (bits == 16 ? 0xC : 0x4))
        let found: (Int, Kind, TopSource)
        if bits == 8 {
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
        let top = source == .ocra ? ocr.0 : (source == .icr ? icr : fixedTop)
        return (top, kind, source)
    }

    func writeCompare(_ unit: Int, _ value: Int, _ avr: AVR) {
        if unit == 0 { ocrBuffer.0 = value } else { ocrBuffer.1 = value }
        let kind = mode(avr).kind
        if kind == .normal || kind == .ctc { ocr = ocrBuffer }
    }

    /// COMxA1:COMxA0 (bits 7:6) or COMxB1:COMxB0 (bits 5:4)
    func compareOutputMode(_ unit: Int, _ avr: AVR) -> Int {
        (Int(avr.data[tccra]) >> (6 - 2 * unit)) & 3
    }

    private func setOutput(_ unit: Int, _ value: Bool) {
        if unit == 0 { output.0 = value } else { output.1 = value }
    }

    private func outputValue(_ unit: Int) -> Bool { unit == 0 ? output.0 : output.1 }

    private func compareValue(_ unit: Int) -> Int { unit == 0 ? ocr.0 : ocr.1 }

    /// What a compare match does to the pin
    private func match(_ unit: Int, _ kind: Kind, _ source: TopSource, _ avr: AVR) {
        let com = compareOutputMode(unit, avr)
        guard com != 0 else { return }
        switch kind {
        case .normal, .ctc:
            setOutput(unit, com == 1 ? !outputValue(unit) : com == 3)
        case .fast:
            if com == 2 {
                setOutput(unit, false)
            } else if com == 3 {
                setOutput(unit, true)
            } else if unit == 0 && source == .ocra {
                setOutput(0, !output.0)
            }
        case .phase:
            // non-inverting: cleared counting up, set counting down
            if com == 2 {
                setOutput(unit, down)
            } else if com == 3 {
                setOutput(unit, !down)
            } else if unit == 0 && source == .ocra {
                setOutput(0, !output.0)
            }
        }
    }

    private func flag(_ bit: UInt8, _ avr: AVR) { avr.data[tifr] |= bit }

    private func tick(_ avr: AVR) {
        let (top, kind, source) = mode(avr)
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
                    flag(1, avr)  // overflow at BOTTOM
                }
            }
            for unit in 0..<2 where count == compareValue(unit) {
                flag(2 << unit, avr)
                match(unit, kind, source, avr)
            }
            return
        }
        let old = count
        var wrapped = false
        if count == top && (kind == .ctc || kind == .fast) {
            count = 0
            wrapped = true
            if kind == .fast { flag(1, avr) }
        } else if count == maximum {
            count = 0
            wrapped = true
            flag(1, avr)
        } else {
            count += 1
        }
        if kind == .fast {
            // the pin changes a timer clock after the counter equals OCR (duty (OCR + 1) / (TOP + 1)), and the change
            // at BOTTOM comes after it: OCR = TOP stays high, OCR = 0 gives a one-clock spike
            for unit in 0..<2 where old == compareValue(unit) { match(unit, kind, source, avr) }
            if wrapped {
                ocr = ocrBuffer
                for unit in 0..<2 {
                    let com = compareOutputMode(unit, avr)
                    if com == 2 { setOutput(unit, true) } else if com == 3 { setOutput(unit, false) }
                }
            }
            for unit in 0..<2 where count == compareValue(unit) { flag(2 << unit, avr) }
            return
        }
        for unit in 0..<2 where count == compareValue(unit) {
            flag(2 << unit, avr)
            match(unit, kind, source, avr)
        }
    }

    @inline(__always) func advance(_ cycles: Int, _ avr: AVR) {
        let prescale = prescalers[Int(avr.data[tccrb] & 7)]
        guard prescale != 0 else { return }
        accumulator += cycles
        while accumulator >= prescale {
            accumulator -= prescale
            tick(avr)
        }
    }
}
