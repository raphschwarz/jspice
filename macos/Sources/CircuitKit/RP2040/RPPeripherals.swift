import Foundation

/// The RP2040's interrupt numbers
enum RPIRQ {
    static let timer0 = 0, pwmWrap = 4, usbctrl = 5, pio0IRQ0 = 7, pio0IRQ1 = 8, pio1IRQ0 = 9, pio1IRQ1 = 10
    static let dmaIRQ0 = 11, dmaIRQ1 = 12, ioBank0 = 13, sioProc0 = 15, uart0 = 20, uart1 = 21, adcFIFO = 22, rtc = 25
}

/// DMA requests
enum RPDREQ {
    static let pio0TX0 = 0, pio0RX0 = 4, pio1TX0 = 8, pio1RX0 = 12, spi0TX = 16, uart0TX = 20, uart0RX = 21
    static let uart1TX = 22, uart1RX = 23, pwmWrap0 = 24, adc = 36, count = 40
}

/// The microsecond timer and its four alarms
final class RPTimerPeripheral: RPPeripheral {
    private final class Alarm {
        let bit: UInt32
        var clockAlarm: RPAlarm!
        var armed = false
        var targetMicros: UInt32 = 0

        init(bit: UInt32) { self.bit = bit }
    }

    private var latchedTimeHigh: UInt32 = 0
    private var alarms: [Alarm] = []
    private var intRaw: UInt32 = 0
    private var intEnable: UInt32 = 0
    private var intForce: UInt32 = 0
    private var paused = false

    override init(chip: RP2040, name: String) {
        super.init(chip: chip, name: name)
        alarms = (0..<4).map { Alarm(bit: 1 << UInt32($0)) }
        for (index, alarm) in alarms.enumerated() {
            alarm.clockAlarm = chip.clock.createAlarm { [unowned self] in self.fireAlarm(index) }
        }
    }

    private var intStatus: UInt32 { (intRaw & intEnable) | intForce }

    override func readUint32(_ offset: UInt32) -> UInt32 {
        let time = chip.clock.nanos / 1000
        switch offset {
        case 0x08: return latchedTimeHigh
        case 0x0C:
            latchedTimeHigh = jsUint32((time / 4_294_967_296).rounded(.down))
            return jsUint32(time)
        case 0x24: return jsUint32((time / 4_294_967_296).rounded(.down))
        case 0x28: return jsUint32(time)
        case 0x10, 0x14, 0x18, 0x1C: return alarms[Int(offset - 0x10) / 4].targetMicros
        case 0x30: return paused ? 1 : 0
        case 0x34: return intRaw
        case 0x38: return intEnable
        case 0x3C: return intForce
        case 0x40: return intStatus
        case 0x20: return alarms.reduce(0) { $0 | ($1.armed ? $1.bit : 0) }
        default: return super.readUint32(offset)
        }
    }

    override func writeUint32(_ offset: UInt32, _ value: UInt32) {
        switch offset {
        case 0x10, 0x14, 0x18, 0x1C:
            let alarm = alarms[Int(offset - 0x10) / 4]
            let delta = jsUint32(Double(value) - chip.clock.nanos / 1000)
            alarm.armed = true
            alarm.targetMicros = value
            alarm.clockAlarm.schedule(Double(delta) * 1000)
        case 0x20:
            for alarm in alarms where rawWriteValue & alarm.bit != 0 { disarm(alarm) }
        case 0x30:
            paused = value & 1 != 0
        case 0x34:
            intRaw &= ~rawWriteValue
            checkInterrupts()
        case 0x38:
            intEnable = value & 0xF
            checkInterrupts()
        case 0x3C:
            intForce = value & 0xF
            checkInterrupts()
        default:
            super.writeUint32(offset, value)
        }
    }

    private func fireAlarm(_ index: Int) {
        let alarm = alarms[index]
        disarm(alarm)
        intRaw |= alarm.bit
        checkInterrupts()
    }

    private func checkInterrupts() {
        let status = intStatus
        for index in 0..<alarms.count { chip.setInterrupt(RPIRQ.timer0 + index, status & (1 << UInt32(index)) != 0) }
    }

    private func disarm(_ alarm: Alarm) {
        alarm.clockAlarm.cancel()
        alarm.armed = false
    }
}

/// The watchdog: a counter that would reset the chip (JSpice notes the reason and carries on)
final class RPWatchdog: RPPeripheral {
    let timer: RPTimer32
    private var alarm: RPTimer32PeriodicAlarm!
    private var scratch = [UInt32](repeating: 0, count: 8)
    private var enable = false
    private var tickEnable = true
    private var reason: UInt32 = 0
    private var pauseDbg0 = true
    private var pauseDbg1 = true
    private var pauseJtag = true

    override init(chip: RP2040, name: String) {
        timer = RPTimer32(clock: chip.clock, frequency: 2_000_000)
        super.init(chip: chip, name: name)
        timer.mode = .decrement
        timer.enable = false
        alarm = RPTimer32PeriodicAlarm(timer: timer) { [unowned self] in self.reason = 1 }
        alarm.target = 0
        alarm.enable = false
    }

    override func readUint32(_ offset: UInt32) -> UInt32 {
        switch offset {
        case 0x00:
            return (timer.enable ? 1 << 30 : 0) | (pauseDbg0 ? 1 << 25 : 0) | (pauseDbg1 ? 1 << 26 : 0)
                | (pauseJtag ? 1 << 24 : 0) | (timer.counter & 0xFF_FFFF)
        case 0x08: return reason
        case 0x0C...0x28 where offset & 3 == 0: return scratch[Int(offset - 0x0C) >> 2]
        case 0x2C: return tickEnable ? (1 << 10) | (1 << 9) : 0
        default: return super.readUint32(offset)
        }
    }

    override func writeUint32(_ offset: UInt32, _ value: UInt32) {
        switch offset {
        case 0x00:
            if value & (1 << 31) != 0 { reason = 1 << 1 }
            enable = value & (1 << 30) != 0
            timer.enable = enable && tickEnable
            alarm.enable = enable && tickEnable
            pauseDbg0 = value & (1 << 25) != 0
            pauseDbg1 = value & (1 << 26) != 0
            pauseJtag = value & (1 << 24) != 0
        case 0x04:
            timer.set(Double(value & 0xFF_FFFF))
        case 0x0C...0x28 where offset & 3 == 0:
            scratch[Int(offset - 0x0C) >> 2] = value
        case 0x2C:
            tickEnable = value & (1 << 9) != 0
            timer.enable = enable && tickEnable
            alarm.enable = enable && tickEnable
        default:
            super.writeUint32(offset, value)
        }
    }
}

/// The flash interface (enough for the boot stage 2 to set up execute-in-place)
final class RPSSI: RPPeripheral {
    private var dr0: UInt32 = 0
    private var txflr: UInt32 = 0
    private var rxflr: UInt32 = 0
    private var baudr: UInt32 = 0
    private var ctrlr0: UInt32 = 0
    private var ctrlr1: UInt32 = 0
    private var ssienr: UInt32 = 0
    private var spiCtrlr0: UInt32 = 0
    private var rxSampleDelay: UInt32 = 0
    private var txdDriveEdge: UInt32 = 0

    override func readUint32(_ offset: UInt32) -> UInt32 {
        switch offset {
        case 0x20: return txflr
        case 0x24: return rxflr
        case 0x00: return ctrlr0
        case 0x04: return ctrlr1
        case 0x08: return ssienr
        case 0x14: return baudr
        case 0x28: return 0x4 | 0x8 | 0x2
        case 0x58: return 0x5153_5049
        case 0x5C: return 0x3430_312A
        case 0xF0: return rxSampleDelay
        case 0xF8: return txdDriveEdge
        case 0xF4: return spiCtrlr0
        case 0x60: return dr0
        default: return super.readUint32(offset)
        }
    }

    override func writeUint32(_ offset: UInt32, _ value: UInt32) {
        switch offset {
        case 0x20: txflr = value
        case 0x24: rxflr = value
        case 0x00: ctrlr0 = value
        case 0x04: ctrlr1 = value
        case 0x08: ssienr = value
        case 0x14: baudr = value
        case 0xF0: rxSampleDelay = value & 0xFF
        case 0xF8: txdDriveEdge = value & 0xFF
        case 0xF4: spiCtrlr0 = value
        case 0x60: if value == 0x05 { dr0 = 0 }
        default: super.writeUint32(offset, value)
        }
    }
}

/// The real-time clock, counting from 1 January 2021 (in UTC)
final class RPRTC: RPPeripheral {
    private var setup0: UInt32 = 0
    private var setup1: UInt32 = 0
    private var ctrl: UInt32 = 0
    private var baseline: Date = RPRTC.calendar.date(from: DateComponents(year: 2021, month: 1, day: 1))!
    private var baselineNanos: Double = 0

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    override func readUint32(_ offset: UInt32) -> UInt32 {
        let date = baseline.addingTimeInterval((chip.clock.nanos - baselineNanos) / 1e9)
        let parts = RPRTC.calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute, .second], from: date)
        switch offset {
        case 0x04: return setup0
        case 0x08: return setup1
        case 0x0C: return ctrl
        case 0x10: return 0
        case 0x18:
            return (UInt32(parts.year ?? 0) & 0xFFF) << 12 | (UInt32(parts.month ?? 0) & 0xF) << 8 | (UInt32(parts.day ?? 0) & 0x1F)
        case 0x1C:
            return (UInt32((parts.weekday ?? 1) - 1) & 0x7) << 24 | (UInt32(parts.hour ?? 0) & 0x1F) << 16
                | (UInt32(parts.minute ?? 0) & 0x3F) << 8 | (UInt32(parts.second ?? 0) & 0x3F)
        default: return super.readUint32(offset)
        }
    }

    override func writeUint32(_ offset: UInt32, _ value: UInt32) {
        switch offset {
        case 0x04: setup0 = value
        case 0x08: setup1 = value
        case 0x0C:
            if value & 0x10 != 0 { ctrl |= 0x10 }
            if value & 0x01 != 0 {
                ctrl |= 0x01 | 0x02
                if ctrl & 0x10 != 0 {
                    var parts = DateComponents()
                    parts.year = Int((setup0 >> 12) & 0xFFF)
                    parts.month = Int((setup0 >> 8) & 0xF)
                    parts.day = Int(setup0 & 0x1F)
                    parts.hour = Int((setup1 >> 16) & 0x1F)
                    parts.minute = Int((setup1 >> 8) & 0x3F)
                    parts.second = Int(setup1 & 0x3F)
                    baseline = RPRTC.calendar.date(from: parts) ?? baseline
                    baselineNanos = chip.clock.nanos
                    ctrl &= ~0x10
                }
            } else {
                ctrl &= ~(0x01 | 0x02)
            }
        default:
            super.writeUint32(offset, value)
        }
    }
}

/// A UART (PL011): bytes written go to `output`; `feed` delivers received ones
final class RPUART: RPPeripheral {
    private let irq: Int
    private let dreqTX: Int
    private var ctrlRegister: UInt32 = (1 << 9) | (1 << 8)
    private var lineCtrlRegister: UInt32 = 0
    private var rxFIFO = RPFIFO(32)
    private var interruptMask: UInt32 = 0
    private var interruptStatus: UInt32 = 0
    private var intDivisor: UInt32 = 0
    private var fracDivisor: UInt32 = 0
    var output: [UInt8] = []

    init(chip: RP2040, name: String, irq: Int, dreqTX: Int) {
        self.irq = irq
        self.dreqTX = dreqTX
        super.init(chip: chip, name: name)
    }

    var enabled: Bool { ctrlRegister & 1 != 0 }

    var baudRate: Double {
        let divider = Double(intDivisor) + Double(fracDivisor) / 64
        return jsRound(chip.clkPeri / (divider * 16))
    }

    func clkPeriChanged() {}

    private var flags: UInt32 { (rxFIFO.full ? 1 << 6 : 0) | (rxFIFO.empty ? 1 << 4 : 0) | (1 << 7) }

    private func checkInterrupts() {
        interruptStatus |= 1 << 5
        chip.setInterrupt(irq, interruptStatus & interruptMask != 0)
    }

    func feedByte(_ value: UInt8) {
        rxFIFO.push(UInt32(value))
        interruptStatus |= 1 << 4
        checkInterrupts()
    }

    override func readUint32(_ offset: UInt32) -> UInt32 {
        switch offset {
        case 0x0:
            let value = rxFIFO.pull()
            if !rxFIFO.empty { interruptStatus |= 1 << 4 } else { interruptStatus &= ~(1 << 4) }
            checkInterrupts()
            return value
        case 0x18: return flags
        case 0x24: return intDivisor
        case 0x28: return fracDivisor
        case 0x2C: return lineCtrlRegister
        case 0x30: return ctrlRegister
        case 0x38: return interruptMask
        case 0x3C: return interruptStatus
        case 0x40: return interruptStatus & interruptMask
        case 0xFE0: return 0x11
        case 0xFE4: return 0x10
        case 0xFE8: return 0x34
        case 0xFEC: return 0x00
        case 0xFF0: return 0x0D
        case 0xFF4: return 0xF0
        case 0xFF8: return 0x05
        case 0xFFC: return 0xB1
        default: return super.readUint32(offset)
        }
    }

    override func writeUint32(_ offset: UInt32, _ value: UInt32) {
        switch offset {
        case 0x0:
            output.append(UInt8(value & 0xFF))
            if output.count > 32_768 { output.removeFirst(output.count - 16_384) }
        case 0x24: intDivisor = value & 0xFFFF
        case 0x28: fracDivisor = value & 0x3F
        case 0x2C: lineCtrlRegister = value
        case 0x30:
            ctrlRegister = value
            if enabled { chip.dma.setDREQ(dreqTX) } else { chip.dma.clearDREQ(dreqTX) }
        case 0x38:
            interruptMask = value & 0x7FF
            checkInterrupts()
        case 0x44:
            interruptStatus &= ~rawWriteValue
            checkInterrupts()
        default:
            super.writeUint32(offset, value)
        }
    }
}

/// The ADC: inputs 0-3 are GP26-GP29, 4 the temperature sensor; each conversion takes 2 µs
final class RPADC: RPPeripheral {
    static let resolution = 12
    private let sampleTime = 2.0
    /// What each channel reads, 0-4095, set by the circuit
    var channelValues: [UInt32] = [0, 0, 0, 0, 0]
    private var fifo = RPFIFO(4)
    private var cs: UInt32 = 0
    private var fcs: UInt32 = 0
    private var clockDiv: UInt32 = 0
    private var intEnable: UInt32 = 0
    private var intForce: UInt32 = 0
    private var result: UInt32 = 0
    private var busy = false
    private var currentChannel = 0
    private var sampleAlarm: RPAlarm!
    private var multiShotAlarm: RPAlarm!

    override init(chip: RP2040, name: String) {
        super.init(chip: chip, name: name)
        sampleAlarm = chip.clock.createAlarm { [unowned self] in self.completeRead(self.channelValues[self.currentChannel], error: false) }
        multiShotAlarm = chip.clock.createAlarm { [unowned self] in if self.cs & (1 << 3) != 0 { self.startRead() } }
    }

    private var divider: Double { 1 + Double((clockDiv >> 8) & 0xFFFF) + Double(clockDiv & 0xFF) / 256 }
    private var intRaw: UInt32 { fifo.itemCount >= Int((fcs >> 24) & 0xF) ? 1 : 0 }
    private var intStatus: UInt32 { (intRaw & intEnable) | intForce }

    private var activeChannel: Int {
        get { Int((cs >> 12) & 0x7) }
        set {
            cs &= ~(0x7 << 12)
            cs |= (UInt32(newValue) & 12) << 12  // as rp2040js: masked with the shift, not the mask
        }
    }

    private func checkInterrupts() { chip.setInterrupt(RPIRQ.adcFIFO, intStatus != 0) }

    private func startRead() {
        busy = true
        currentChannel = activeChannel
        sampleAlarm.schedule(sampleTime * 1000)
    }

    private func updateDMA() {
        guard fcs & (1 << 3) != 0 else { return }
        if fifo.itemCount >= Int((fcs >> 24) & 0xF) { chip.dma.setDREQ(RPDREQ.adc) } else { chip.dma.clearDREQ(RPDREQ.adc) }
    }

    private func completeRead(_ sample: UInt32, error: Bool) {
        busy = false
        result = sample
        if error { cs |= (1 << 10) | (1 << 9) } else { cs &= ~(1 << 9) }
        if fcs & 1 != 0 {
            if fifo.full {
                fcs |= 1 << 11
            } else {
                var value = sample & 0xFFF
                if fcs & (1 << 1) != 0 { value >>= 4 }
                if error && fcs & (1 << 2) != 0 { value |= 1 << 15 }
                fifo.push(value)
                updateDMA()
                checkInterrupts()
            }
        }
        let round = Int((cs >> 16) & 0x1F)
        if round != 0 {
            var channel = activeChannel + 1
            while round & (1 << channel) == 0 { channel = (channel + 1) % 5 }
            activeChannel = channel
        }
        if cs & (1 << 3) != 0 {
            let sampleTicks = 48 * sampleTime
            if divider > sampleTicks {
                multiShotAlarm.schedule((divider - sampleTicks) / 48 * 1000)
            } else {
                startRead()
            }
        }
    }

    override func readUint32(_ offset: UInt32) -> UInt32 {
        switch offset {
        case 0x00: return cs | (busy ? 0 : 1 << 8)
        case 0x04: return result
        case 0x08:
            return fcs | (UInt32(fifo.itemCount) & 0xF) << 16 | (fifo.full ? 1 << 9 : 0) | (fifo.empty ? 1 << 8 : 0)
        case 0x0C:
            if fifo.empty {
                fcs |= 1 << 10
                return 0
            }
            let value = fifo.pull()
            updateDMA()
            return value
        case 0x10: return clockDiv
        case 0x14: return intRaw
        case 0x18: return intEnable
        case 0x1C: return intForce
        case 0x20: return intStatus
        default: return super.readUint32(offset)
        }
    }

    override func writeUint32(_ offset: UInt32, _ value: UInt32) {
        let csWriteMask: UInt32 = (0x1F << 16) | (0x7 << 12) | (1 << 3) | (1 << 2) | (1 << 1) | 1
        let fcsWriteMask: UInt32 = (0xF << 24) | (1 << 3) | (1 << 2) | (1 << 1) | 1
        switch offset {
        case 0x00:
            fcs &= ~(value & (1 << 10))
            cs = (cs & ~csWriteMask) | (value & csWriteMask)
            if value & 1 != 0 && !busy && (value & (1 << 2) != 0 || value & (1 << 3) != 0) { startRead() }
        case 0x08:
            fcs &= ~(value & ((1 << 11) | (1 << 10)))
            fcs = (fcs & ~fcsWriteMask) | (value & fcsWriteMask)
            checkInterrupts()
        case 0x10:
            clockDiv = value
        case 0x18:
            intEnable = value & 1
            checkInterrupts()
        case 0x1C:
            intForce = value & 1
            checkInterrupts()
        default:
            super.writeUint32(offset, value)
        }
    }
}

/// The PWM block: eight slices, each driving two pins (A and B) from a counter that runs from clk_sys
final class RPPWM: RPPeripheral {
    final class Channel {
        unowned(unsafe) let pwm: RPPWM
        let index: Int
        let timer: RPTimer32
        var alarmA: RPTimer32PeriodicAlarm!
        var alarmB: RPTimer32PeriodicAlarm!
        var alarmBottom: RPTimer32PeriodicAlarm!
        var csr: UInt32 = 0
        var div: UInt32 = 0
        var cc: UInt32 = 0
        var top: UInt32 = 0
        var lastBValue = false
        var ccUpdated = false
        var topUpdated = false
        var tickCounter: Double = 0
        var divMode = 0
        let pinA1: Int, pinB1: Int, pinA2: Int, pinB2: Int

        init(pwm: RPPWM, index: Int) {
            self.pwm = pwm
            self.index = index
            timer = RPTimer32(clock: pwm.chip.clock, frequency: pwm.chip.clkSys)
            pinA1 = index * 2
            pinB1 = index * 2 + 1
            pinA2 = index < 7 ? 16 + index * 2 : -1
            pinB2 = index < 7 ? 16 + index * 2 + 1 : -1
            alarmA = RPTimer32PeriodicAlarm(timer: timer) { [unowned self] in self.setA(false) }
            alarmB = RPTimer32PeriodicAlarm(timer: timer) { [unowned self] in self.setB(false) }
            alarmBottom = RPTimer32PeriodicAlarm(timer: timer) { [unowned self] in self.wrap() }
            alarmA.enable = true
            alarmB.enable = true
            alarmBottom.enable = true
        }

        func readRegister(_ offset: UInt32) -> UInt32 {
            switch offset {
            case 0x00: return csr
            case 0x04: return div
            case 0x08: return timer.counter
            case 0x0C: return cc
            case 0x10: return top
            default: return 0
            }
        }

        func writeRegister(_ offset: UInt32, _ value: UInt32) {
            switch offset {
            case 0x00:
                if value & 1 != 0 && csr & 1 == 0 { updateDoubleBuffered() }
                csr = value & ~((1 << 7) | (1 << 6))
                if value & 1 != 0 {
                    if value & (1 << 7) != 0 { timer.advance(1) }
                    if value & (1 << 6) != 0 { timer.advance(-1) }
                }
                divMode = Int((csr >> 4) & 0x3)
                setBDirection(divMode == 0)
                updateEnable()
                lastBValue = gpioBValue
                timer.mode = value & (1 << 1) != 0 ? .zigZag : .increment
            case 0x04:
                div = value & 0x000F_FFFF
                let integer = (value >> 4) & 0xFF
                timer.prescaler = Double(integer != 0 ? integer : 256) + Double(value & 0xF) / 16
            case 0x08:
                timer.set(Double(value & 0xFFFF))
            case 0x0C:
                cc = value
                ccUpdated = true
            case 0x10:
                top = value & 0xFFFF
                topUpdated = true
            default:
                break
            }
        }

        func reset() {
            writeRegister(0x00, 0)
            writeRegister(0x04, 0x01 << 4)
            writeRegister(0x08, 0)
            writeRegister(0x0C, 0)
            writeRegister(0x10, 0xFFFF)
            timer.enable = false
            timer.reset()
        }

        private func updateDoubleBuffered() {
            if ccUpdated {
                alarmB.target = Double(cc >> 16)
                alarmA.target = Double(cc & 0xFFFF)
                ccUpdated = false
            }
            if topUpdated {
                timer.top = Double(top)
                topUpdated = false
            }
        }

        private func wrap() {
            pwm.channelInterrupt(index)
            updateDoubleBuffered()
            if csr & (1 << 1) == 0 {
                setA(alarmA.target > 0)
                setB(alarmB.target > 0)
            }
        }

        func setA(_ value: Bool) {
            let level = csr & (1 << 2) != 0 ? !value : value
            pwm.gpioSet(pinA1, level)
            if pinA2 >= 0 { pwm.gpioSet(pinA2, level) }
        }

        func setB(_ value: Bool) {
            let level = csr & (1 << 3) != 0 ? !value : value
            pwm.gpioSet(pinB1, level)
            if pinB2 >= 0 { pwm.gpioSet(pinB2, level) }
        }

        var gpioBValue: Bool { pwm.gpioRead(pinB1) || (pinB2 > 0 ? pwm.gpioRead(pinB2) : false) }

        func setBDirection(_ output: Bool) {
            pwm.gpioSetDirection(pinB1, output)
            if pinB2 >= 0 { pwm.gpioSetDirection(pinB2, output) }
        }

        func gpioBChanged() {
            let value = gpioBValue
            guard value != lastBValue else { return }
            lastBValue = value
            switch divMode {
            case 1: updateEnable()
            case 2: if value { tickCounter += 1 }
            case 3: if !value { tickCounter += 1 }
            default: break
            }
            if tickCounter >= timer.prescaler {
                timer.advance(1)
                tickCounter -= timer.prescaler
            }
        }

        func updateEnable() {
            timer.enable = csr & 1 != 0 && (divMode == 0 || (divMode == 1 && gpioBValue))
        }

        func setEnabled(_ on: Bool) {
            if on && csr & 1 == 0 { updateDoubleBuffered() }
            if on { csr |= 1 } else { csr &= ~1 }
            updateEnable()
        }
    }

    private(set) var channels: [Channel] = []
    private var intRaw: UInt32 = 0
    private var intEnable: UInt32 = 0
    private var intForce: UInt32 = 0
    var gpioValue: UInt32 = 0
    var gpioDirection: UInt32 = 0

    override init(chip: RP2040, name: String) {
        super.init(chip: chip, name: name)
        channels = (0..<8).map { Channel(pwm: self, index: $0) }
    }

    private var intStatus: UInt32 { (intRaw & intEnable) | intForce }

    override func readUint32(_ offset: UInt32) -> UInt32 {
        if offset < 0xA0 { return channels[Int(offset / 0x14)].readRegister(offset % 0x14) }
        switch offset {
        case 0xA0: return channels.enumerated().reduce(0) { $0 | ($1.element.csr & 1) << UInt32($1.offset) }
        case 0xA4: return intRaw
        case 0xA8: return intEnable
        case 0xAC: return intForce
        case 0xB0: return intStatus
        default: return super.readUint32(offset)
        }
    }

    override func writeUint32(_ offset: UInt32, _ value: UInt32) {
        if offset < 0xA0 {
            channels[Int(offset / 0x14)].writeRegister(offset % 0x14, value)
            return
        }
        switch offset {
        case 0xA0:
            for index in stride(from: 7, through: 0, by: -1) { channels[index].setEnabled(value & (1 << UInt32(index)) != 0) }
        case 0xA4:
            intRaw &= ~(value & 0xFF)
            checkInterrupts()
        case 0xA8:
            intEnable = value & 0xFF
            checkInterrupts()
        case 0xAC:
            intForce = value & 0xFF
            checkInterrupts()
        default:
            super.writeUint32(offset, value)
        }
    }

    func channelInterrupt(_ index: Int) {
        intRaw |= 1 << UInt32(index)
        checkInterrupts()
        chip.dma.setDREQ(RPDREQ.pwmWrap0 + index)
    }

    private func checkInterrupts() { chip.setInterrupt(RPIRQ.pwmWrap, intStatus != 0) }

    func gpioSet(_ index: Int, _ value: Bool) {
        let bit = UInt32(1) << UInt32(index)
        let new = value ? gpioValue | bit : gpioValue & ~bit
        if gpioValue != new {
            gpioValue = new
            chip.gpio[index].checkForUpdates()
        }
    }

    func gpioSetDirection(_ index: Int, _ output: Bool) {
        let bit = UInt32(1) << UInt32(index)
        let new = output ? gpioDirection | bit : gpioDirection & ~bit
        if gpioDirection != new {
            gpioDirection = new
            chip.gpio[index].checkForUpdates()
        }
    }

    func gpioRead(_ index: Int) -> Bool { chip.gpio[index].inputValue }

    func gpioOnInput(_ index: Int) {
        if gpioDirection & (1 << UInt32(index)) != 0 { return }
        for channel in channels where channel.pinB1 == index || channel.pinB2 == index { channel.gpioBChanged() }
    }

    func reset() {
        gpioDirection = 0xFFFF_FFFF
        for channel in channels { channel.reset() }
    }

    /// clk_sys changed: the counters run at the new rate
    func clockChanged() {
        for channel in channels { channel.timer.frequency = chip.clkSys }
    }
}

/// The DMA controller: twelve channels, each moving data paced by a request (a peripheral, a timer, or none)
final class RPDMA: RPPeripheral {
    final class Channel {
        unowned(unsafe) let dma: RPDMA
        let index: Int
        private(set) var ctrl: UInt32 = 0
        private var readAddress: UInt32 = 0
        private var writeAddress: UInt32 = 0
        private var transCount: UInt32 = 0
        private var dreqCounter: UInt32 = 0
        private var transCountReload: UInt32 = 0
        private(set) var treq = 0
        private var dataSize: UInt32 = 1
        private var chainTo = 0
        private var ringMask: UInt32 = 0
        private var transferAlarm: RPAlarm!

        init(dma: RPDMA, index: Int) {
            self.dma = dma
            self.index = index
            transferAlarm = dma.chip.clock.createAlarm { [unowned self] in self.transfer() }
            reset()
        }

        var active: Bool { ctrl & 1 != 0 && ctrl & (1 << 24) != 0 }

        func start() {
            if ctrl & 1 == 0 || ctrl & (1 << 24) != 0 { return }
            ctrl |= 1 << 24
            transCount = transCountReload
            if transCount != 0 { scheduleTransfer() }
        }

        private func move() {
            let chip = dma.chip
            switch dataSize {
            case 2:
                let input = chip.readUint16(readAddress)
                chip.writeUint16(writeAddress, ctrl & (1 << 22) != 0 ? input.byteSwapped : input)
            case 4:
                let input = chip.readUint32(readAddress)
                chip.writeUint32(writeAddress, ctrl & (1 << 22) != 0 ? input.byteSwapped : input)
            default:
                chip.writeUint8(writeAddress, chip.readUint8(readAddress))
            }
        }

        private func transfer() {
            let control = ctrl
            move()
            if control & (1 << 4) != 0 {
                if ringMask != 0 && control & (1 << 10) == 0 {
                    readAddress = (readAddress & ~ringMask) | ((readAddress &+ dataSize) & ringMask)
                } else {
                    readAddress = readAddress &+ dataSize
                }
            }
            if control & (1 << 5) != 0 {
                if ringMask != 0 && control & (1 << 10) != 0 {
                    writeAddress = (writeAddress & ~ringMask) | ((writeAddress &+ dataSize) & ringMask)
                } else {
                    writeAddress = writeAddress &+ dataSize
                }
            }
            transCount = transCount &- 1
            if transCount > 0 && transCount != UInt32.max {
                scheduleTransfer()
            } else {
                ctrl &= ~(1 << 24)
                if ctrl & (1 << 21) == 0 {
                    dma.intRaw |= 1 << UInt32(index)
                    dma.checkInterrupts()
                }
                if chainTo != index && chainTo < dma.channels.count { dma.channels[chainTo].start() }
            }
        }

        func scheduleTransfer() {
            if dma.dreq[treq] || treq == 0x3F {
                transferAlarm.schedule(0)
            } else {
                let delay = dma.timerMicros(treq)
                if delay != 0 { transferAlarm.schedule(delay * 1000) }
            }
        }

        func abort() {
            ctrl &= ~(1 << 24)
            transferAlarm.cancel()
        }

        func readUint32(_ offset: UInt32) -> UInt32 {
            switch offset {
            case 0x000, 0x014, 0x028, 0x03C: return readAddress
            case 0x004, 0x018, 0x02C, 0x034: return writeAddress
            case 0x008, 0x01C, 0x024, 0x038: return transCount
            case 0x00C, 0x010, 0x020, 0x030: return ctrl
            case 0x800: return dreqCounter
            case 0x804: return transCountReload
            default: return 0
            }
        }

        func writeUint32(_ offset: UInt32, _ value: UInt32) {
            switch offset {
            case 0x000, 0x014, 0x028, 0x03C:
                readAddress = value
            case 0x004, 0x018, 0x02C, 0x034:
                writeAddress = value
            case 0x008, 0x01C, 0x024, 0x038:
                transCountReload = value
            case 0x00C, 0x010, 0x020, 0x030:
                ctrl = (ctrl & ~0xFF_FFFF) | (value & 0xFF_FFFF)
                ctrl &= ~(value & ((1 << 30) | (1 << 29)))
                treq = Int((ctrl >> 15) & 0x3F)
                chainTo = Int((ctrl >> 11) & 0xF)
                let ringSize = (ctrl >> 6) & 0xF
                ringMask = ringSize != 0 ? (1 << ringSize) - 1 : 0
                switch (ctrl >> 2) & 0x3 {
                case 1: dataSize = 2
                case 2: dataSize = 4
                default: dataSize = 1
                }
                if ctrl & 1 != 0 && ctrl & (1 << 24) != 0 { scheduleTransfer() }
                if ctrl & 1 == 0 { transferAlarm.cancel() }
            case 0x800:
                dreqCounter = 0
            default:
                break
            }
            if offset == 0x03C || offset == 0x02C || offset == 0x01C || offset == 0x00C {
                if value != 0 {
                    start()
                } else if ctrl & (1 << 21) != 0 {
                    dma.intRaw |= 1 << UInt32(index)
                    dma.checkInterrupts()
                }
            }
        }

        func reset() { writeUint32(0x00C, UInt32(index) << 11) }
    }

    private(set) var channels: [Channel] = []
    var intRaw: UInt32 = 0
    private var intEnable0: UInt32 = 0
    private var intForce0: UInt32 = 0
    private var intEnable1: UInt32 = 0
    private var intForce1: UInt32 = 0
    private var timers: [UInt32] = [0, 0, 0, 0]
    fileprivate var dreq = [Bool](repeating: false, count: RPDREQ.count)

    override init(chip: RP2040, name: String) {
        super.init(chip: chip, name: name)
        channels = (0..<12).map { Channel(dma: self, index: $0) }
    }

    private var intStatus0: UInt32 { (intRaw & intEnable0) | intForce0 }
    private var intStatus1: UInt32 { (intRaw & intEnable1) | intForce1 }

    override func readUint32(_ offset: UInt32) -> UInt32 {
        if offset & 0x7FF < 12 * 0x40 { return channels[Int((offset & 0x7FF) >> 6)].readUint32(offset & 0x83F) }
        switch offset {
        case 0x420, 0x424, 0x428, 0x42C: return timers[Int(offset - 0x420) / 4]
        case 0x400: return intRaw
        case 0x404: return intEnable0
        case 0x408: return intForce0
        case 0x40C: return intStatus0
        case 0x414: return intEnable1
        case 0x418: return intForce1
        case 0x41C: return intStatus1
        case 0x448: return UInt32(channels.count)
        default: return super.readUint32(offset)
        }
    }

    override func writeUint32(_ offset: UInt32, _ value: UInt32) {
        if offset & 0x7FF < 12 * 0x40 {
            channels[Int((offset & 0x7FF) >> 6)].writeUint32(offset & 0x83F, value)
            return
        }
        switch offset {
        case 0x420, 0x424, 0x428, 0x42C:
            timers[Int(offset - 0x420) / 4] = value
        case 0x400, 0x40C, 0x41C:
            intRaw &= ~rawWriteValue
            checkInterrupts()
        case 0x404:
            intEnable0 = value & 0xFFFF
            checkInterrupts()
        case 0x408:
            intForce0 = value & 0xFFFF
            checkInterrupts()
        case 0x414:
            intEnable1 = value & 0xFFFF
            checkInterrupts()
        case 0x418:
            intForce1 = value & 0xFFFF
            checkInterrupts()
        case 0x430:
            for channel in channels where value & (1 << UInt32(channel.index)) != 0 { channel.start() }
        case 0x444:
            for channel in channels where value & (1 << UInt32(channel.index)) != 0 { channel.abort() }
        default:
            super.writeUint32(offset, value)
        }
    }

    func setDREQ(_ channel: Int) {
        guard channel >= 0 && channel < dreq.count, !dreq[channel] else { return }
        dreq[channel] = true
        for dmaChannel in channels where dmaChannel.treq == channel && dmaChannel.active { dmaChannel.scheduleTransfer() }
    }

    func clearDREQ(_ channel: Int) {
        guard channel >= 0 && channel < dreq.count else { return }
        dreq[channel] = false
    }

    /// Microseconds per cycle of a pacing timer (0: off)
    fileprivate func timerMicros(_ treq: Int) -> Double {
        var dividend: Double = 0
        var divisor: Double = 1
        switch treq {
        case 0x3F:
            dividend = 1
        case 0x3B, 0x3C, 0x3D:
            let timer = timers[treq - 0x3B]
            dividend = Double(timer >> 16)
            divisor = Double(timer & 0xFFFF)
        case 0x3E:
            dividend = Double(timers[3] >> 4)  // as rp2040js, which shifts by 36 (that is, 4)
            divisor = Double(timers[3] & 0xFFFF)
        default:
            break
        }
        if divisor == 0 { return 0 }
        return dividend / divisor * 1e6 / chip.clkSys
    }

    func checkInterrupts() {
        chip.setInterrupt(RPIRQ.dmaIRQ0, intStatus0 != 0)
        chip.setInterrupt(RPIRQ.dmaIRQ1, intStatus1 != 0)
    }
}
