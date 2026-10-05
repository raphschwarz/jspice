import Foundation

/// Runs a sequence of line changes, waits and samples on the simulation clock: what the SPI and I²C controllers do to
/// their pins, bit by bit
final class RPLineSequencer {
    enum Step {
        /// Changes lines (by index, to driven-low or let-go for I²C, to a level for SPI)
        case set(Int, Bool)
        /// Waits this many nanoseconds
        case wait(Double)
        /// Reads an input into the shift register
        case sample
        /// Calls back with what was sampled
        case finish((UInt32) -> Void)
    }

    unowned(unsafe) let chip: RP2040
    private var steps: [Step] = []
    private var index = 0
    private var alarm: RPAlarm!
    /// Reads the input line
    var input: () -> Bool = { true }
    /// Called when a line changes
    var changed: (Int, Bool) -> Void = { _, _ in }
    private(set) var shift: UInt32 = 0
    var busy: Bool { !steps.isEmpty }

    init(chip: RP2040) {
        self.chip = chip
        alarm = chip.clock.createAlarm { [unowned self] in self.run() }
    }

    func start(_ sequence: [Step]) {
        steps = sequence
        index = 0
        shift = 0
        run()
    }

    func cancel() {
        alarm.cancel()
        steps = []
        index = 0
    }

    private func run() {
        while index < steps.count {
            let step = steps[index]
            index += 1
            switch step {
            case let .set(line, value): changed(line, value)
            case let .wait(nanos):
                alarm.schedule(nanos)
                return
            case .sample: shift = shift << 1 | (input() ? 1 : 0)
            case let .finish(callback):
                // the last step: the callback may start the next sequence, which runs itself
                steps = []
                index = 0
                callback(shift)
                return
            }
        }
        steps = []
        index = 0
    }
}

/// An SPI controller (ARM PL022) as a master, rp2040js's RPSPI made to clock its words out on the pins: SCK at the
/// rate CPSDVSR and SCR set, data on TX, RX sampled, in Motorola mode with either clock polarity and phase
final class RPSPI: RPPeripheral {
    let index: Int
    private let irq: Int
    private let dreqTX: Int
    private let dreqRX: Int
    private var rxFIFO = RPFIFO(8)
    private var txFIFO = RPFIFO(8)
    private var busy = false
    private var control0: UInt32 = 0
    private var control1: UInt32 = 0
    private var dmaControl: UInt32 = 0
    private var clockDivisor: UInt32 = 0
    private var intRaw: UInt32 = 0
    private var intEnable: UInt32 = 0
    /// SCK, TX and chip select as the controller drives them
    private(set) var sck = false
    private(set) var tx = false
    private(set) var selected = false
    private var sequencer: RPLineSequencer!

    init(chip: RP2040, name: String, index: Int, irq: Int, dreqTX: Int, dreqRX: Int) {
        self.index = index
        self.irq = irq
        self.dreqTX = dreqTX
        self.dreqRX = dreqRX
        super.init(chip: chip, name: name)
        sequencer = RPLineSequencer(chip: chip)
        sequencer.input = { [unowned self] in
            self.control1 & 1 != 0 ? self.tx : self.chip.peripheralInput(function: RPGPIOPin.functionSPI, instance: self.index, role: 0)
        }
        sequencer.changed = { [unowned self] line, value in
            switch line {
            case 0: self.sck = value
            case 1: self.tx = value
            default: self.selected = value
            }
            self.chip.peripheralPinsChanged(function: RPGPIOPin.functionSPI)
        }
        updateDMA()
    }

    var enabled: Bool { control1 & 2 != 0 }
    var master: Bool { control1 & 4 == 0 }
    private var dataBits: Int { Int(control0 & 0xF) + 1 }
    private var polarity: Bool { control0 & 0x40 != 0 }
    private var phase: Bool { control0 & 0x80 != 0 }
    private var intStatus: UInt32 { intRaw & intEnable }

    /// Whether the controller drives a pin: SCK (role 2), TX (3) and chip select (1) while it is an enabled master
    func drives(role: Int) -> Bool { enabled && master && role != 0 }

    func level(role: Int) -> Bool {
        switch role {
        case 1: return !selected
        case 2: return busy ? sck : polarity
        default: return tx
        }
    }

    private func updateDMA() {
        if txFIFO.full { chip.dma.clearDREQ(dreqTX) } else { chip.dma.setDREQ(dreqTX) }
        if rxFIFO.empty { chip.dma.clearDREQ(dreqRX) } else { chip.dma.setDREQ(dreqRX) }
    }

    private func checkInterrupts() { chip.setInterrupt(irq, intStatus != 0) }

    private func fifosUpdated() {
        let previous = intStatus
        if txFIFO.itemCount <= txFIFO.size / 2 { intRaw |= 1 << 3 } else { intRaw &= ~(1 << 3) }
        if rxFIFO.itemCount >= rxFIFO.size / 2 { intRaw |= 1 << 2 } else { intRaw &= ~(1 << 2) }
        if intStatus != previous { checkInterrupts() }
        updateDMA()
    }

    private func doTX() {
        guard !busy, !txFIFO.empty, enabled, master else { return }
        let value = txFIFO.pull()
        busy = true
        fifosUpdated()
        // half a clock period: clk_peri / (CPSDVSR (1 + SCR)) per bit
        let divisor = Double(max(clockDivisor, 2)) * Double(1 + (control0 >> 8) & 0xFF)
        let half = divisor * 1e9 / chip.clkPeri / 2
        let bits = dataBits
        var steps: [RPLineSequencer.Step] = [.set(2, true), .set(0, polarity)]
        for bit in (0..<bits).reversed() {
            let out = value & (1 << UInt32(bit)) != 0
            if phase {
                // data changes on the leading edge, is sampled on the trailing one
                steps += [.set(0, !polarity), .set(1, out), .wait(half), .set(0, polarity), .sample, .wait(half)]
            } else {
                steps += [.set(1, out), .wait(half), .set(0, !polarity), .sample, .wait(half), .set(0, polarity)]
            }
        }
        steps += [.set(2, false), .finish({ [unowned self] received in self.completeTransmit(received) })]
        sequencer.start(steps)
    }

    private func completeTransmit(_ value: UInt32) {
        busy = false
        if !rxFIFO.full { rxFIFO.push(value & ((1 << UInt32(dataBits)) - 1)) } else { intRaw |= 1 }
        fifosUpdated()
        doTX()
    }

    override func readUint32(_ offset: UInt32) -> UInt32 {
        switch offset {
        case 0x000: return control0
        case 0x004: return control1
        case 0x008:
            guard !rxFIFO.empty else { return 0 }
            let value = rxFIFO.pull()
            fifosUpdated()
            return value
        case 0x00C:
            var status: UInt32 = txFIFO.empty ? 1 : 0
            if !txFIFO.full { status |= 1 << 1 }
            if !rxFIFO.empty { status |= 1 << 2 }
            if rxFIFO.full { status |= 1 << 3 }
            if busy || !txFIFO.empty { status |= 1 << 4 }
            return status
        case 0x010: return clockDivisor
        case 0x014: return intEnable
        case 0x018: return intRaw
        case 0x01C: return intStatus
        case 0x024: return dmaControl
        case 0xFE0: return 0x22
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
        case 0x000:
            control0 = value
        case 0x004:
            control1 = value
            if !enabled {
                sequencer.cancel()
                busy = false
            }
            chip.peripheralPinsChanged(function: RPGPIOPin.functionSPI)
            doTX()
        case 0x008:
            if !txFIFO.full {
                txFIFO.push(value & ((1 << UInt32(dataBits)) - 1))
                doTX()
                fifosUpdated()
            }
        case 0x010:
            clockDivisor = value & 0xFE
        case 0x014:
            intEnable = value
            checkInterrupts()
        case 0x020:
            intRaw &= ~(value & 0x3)
            checkInterrupts()
        case 0x024:
            dmaControl = value
        default:
            super.writeUint32(offset, value)
        }
    }
}

/// An I²C controller (Synopsys DW_apb_i2c) as a master: rp2040js's RPI2C, its START, address, data and STOP sent bit
/// by bit on open-drain SDA and SCL at the high and low counts the SDK sets. Nothing answers on its own: an address is
/// acknowledged only if something in the circuit holds SDA low.
final class RPI2C: RPPeripheral {
    private enum State { case idle, start, connect, connected, stop }

    let index: Int
    private let irq: Int
    private var state = State.idle
    private var busy = false
    private var stop = false
    private var pendingRestart = false
    private var firstByte = false
    private var rxFIFO = RPFIFO(16)
    private var txFIFO = RPFIFO(16)
    private var enable: UInt32 = 0
    private var rxThreshold: UInt32 = 0
    private var txThreshold: UInt32 = 0
    private var control: UInt32 = (1 << 6) | (1 << 5) | (2 << 1) | 1
    private var ssHigh: UInt32 = 0x28, ssLow: UInt32 = 0x2F, fsHigh: UInt32 = 0x06, fsLow: UInt32 = 0x0D
    private var targetAddress: UInt32 = 0x55
    private var slaveAddress: UInt32 = 0x55
    private var abortSource: UInt32 = 0
    private var intRaw: UInt32 = 0
    private var intEnable: UInt32 = 0
    private var spikeLength: UInt32 = 0x07
    /// Whether the controller pulls SDA (line 0) and SCL (line 1) low
    private(set) var sdaLow = false
    private(set) var sclLow = false
    private var sequencer: RPLineSequencer!

    // the interrupt bits
    private static let startDetected: UInt32 = 1 << 10, stopDetected: UInt32 = 1 << 9, txAbort: UInt32 = 1 << 6
    private static let txEmpty: UInt32 = 1 << 4, txOver: UInt32 = 1 << 3, rxFull: UInt32 = 1 << 2, rxOver: UInt32 = 1 << 1
    private static let rxUnder: UInt32 = 1

    init(chip: RP2040, name: String, index: Int, irq: Int) {
        self.index = index
        self.irq = irq
        super.init(chip: chip, name: name)
        sequencer = RPLineSequencer(chip: chip)
        sequencer.input = { [unowned self] in
            !self.sdaLow && self.chip.peripheralInput(function: RPGPIOPin.functionI2C, instance: self.index, role: 0)
        }
        sequencer.changed = { [unowned self] line, low in
            if line == 0 { self.sdaLow = low } else { self.sclLow = low }
            self.chip.peripheralPinsChanged(function: RPGPIOPin.functionI2C)
        }
    }

    private var intStatus: UInt32 { intRaw & intEnable }
    private var standardSpeed: Bool { (control >> 1) & 3 == 1 }
    /// SCL's low and high times, in nanoseconds
    private var lowTime: Double { Double(max(standardSpeed ? ssLow : fsLow, 1)) * 1e9 / chip.clkSys }
    private var highTime: Double { Double(max(standardSpeed ? ssHigh : fsHigh, 1)) * 1e9 / chip.clkSys }

    /// Whether the controller pulls a line low (role 0 SDA, 1 SCL)
    func pullsLow(role: Int) -> Bool { role == 0 ? sdaLow : sclLow }

    private func checkInterrupts() { chip.setInterrupt(irq, intStatus != 0) }

    @discardableResult private func clearInterrupts(_ mask: UInt32) -> UInt32 {
        guard intRaw & mask != 0 else { return 0 }
        intRaw &= ~mask
        checkInterrupts()
        return 1
    }

    private func setInterrupts(_ mask: UInt32) {
        guard intRaw & mask == 0 else { return }
        intRaw |= mask
        checkInterrupts()
    }

    private func abort(_ reason: UInt32) {
        abortSource &= ~(0x1FF << 23)
        abortSource |= reason | UInt32(txFIFO.itemCount) << 23
        txFIFO.reset()
        setInterrupts(RPI2C.txAbort)
    }

    /// With TX_EMPTY_CTRL (as the SDK sets it), TX_EMPTY also waits for the last command to be done
    private func transmitDone() {
        if UInt32(txFIFO.itemCount) <= txThreshold { setInterrupts(RPI2C.txEmpty) }
    }

    private func nextCommand() {
        guard !txFIFO.empty, !busy, enable & (1 << 2) == 0, enable & 1 != 0 else { return }
        busy = true
        let restart = txFIFO.peek() & (1 << 10) != 0 && !pendingRestart && !stop
        if state == .idle || restart {
            pendingRestart = restart
            stop = false
            state = .start
            sendStart(repeated: restart)
            return
        }
        pendingRestart = false
        let command = txFIFO.pull()
        stop = command & (1 << 9) != 0
        if command & (1 << 8) != 0 { receiveByte(acknowledge: !stop) } else { sendByte(command & 0xFF) }
        if control & (1 << 8) == 0 && UInt32(txFIFO.itemCount) <= txThreshold { setInterrupts(RPI2C.txEmpty) }
    }

    private func pushRX(_ value: UInt32) {
        if rxFIFO.full {
            setInterrupts(RPI2C.rxOver)
            return
        }
        rxFIFO.push(value)
        if UInt32(rxFIFO.itemCount) > rxThreshold { setInterrupts(RPI2C.rxFull) }
    }

    // MARK: - On the lines

    private func sendStart(repeated: Bool) {
        var steps: [RPLineSequencer.Step] = []
        if repeated {
            steps += [.set(0, false), .wait(lowTime / 2), .set(1, false), .wait(highTime)]
        }
        steps += [.set(0, true), .wait(highTime), .set(1, true), .wait(lowTime / 2),
                  .finish({ [unowned self] _ in self.completeStart() })]
        sequencer.start(steps)
    }

    /// Eight bits out, then the ninth clock with SDA let go: sampled for the acknowledge
    private func byteSteps(_ value: UInt32) -> [RPLineSequencer.Step] {
        var steps: [RPLineSequencer.Step] = []
        for bit in (0..<8).reversed() {
            steps += [.set(0, value & (1 << UInt32(bit)) == 0), .wait(lowTime / 2), .set(1, false), .wait(highTime),
                      .set(1, true), .wait(lowTime / 2)]
        }
        steps += [.set(0, false), .wait(lowTime / 2), .set(1, false), .wait(highTime / 2), .sample, .wait(highTime / 2),
                  .set(1, true), .wait(lowTime / 2)]
        return steps
    }

    private func sendAddress(_ address: UInt32, read: Bool) {
        sequencer.start(byteSteps(address << 1 | (read ? 1 : 0)) + [.finish({ [unowned self] bit in
            self.completeConnect(acknowledged: bit & 1 == 0)
        })])
    }

    private func sendByte(_ value: UInt32) {
        sequencer.start(byteSteps(value) + [.finish({ [unowned self] bit in self.completeWrite(acknowledged: bit & 1 == 0) })])
    }

    private func receiveByte(acknowledge: Bool) {
        var steps: [RPLineSequencer.Step] = []
        for _ in 0..<8 {
            steps += [.set(0, false), .wait(lowTime / 2), .set(1, false), .wait(highTime / 2), .sample, .wait(highTime / 2),
                      .set(1, true), .wait(lowTime / 2)]
        }
        steps += [.set(0, acknowledge), .wait(lowTime / 2), .set(1, false), .wait(highTime), .set(1, true), .wait(lowTime / 2),
                  .finish({ [unowned self] value in self.completeRead(value & 0xFF) })]
        sequencer.start(steps)
    }

    private func sendStop() {
        sequencer.start([.set(0, true), .wait(lowTime / 2), .set(1, false), .wait(highTime), .set(0, false), .wait(lowTime),
                         .finish({ [unowned self] _ in self.completeStop() })])
    }

    // MARK: - The state machine (as rp2040js)

    private func completeStart() {
        if txFIFO.empty || state != .start || stop {
            sendStop()
            return
        }
        let read = txFIFO.peek() & (1 << 8) != 0
        state = .connect
        setInterrupts(RPI2C.startDetected)
        sendAddress(targetAddress & 0x7F, read: read)
    }

    private func completeConnect(acknowledged: Bool) {
        if !acknowledged || stop {
            if !acknowledged { abort(targetAddress == 0 ? 1 << 4 : 1) }
            state = .stop
            sendStop()
            return
        }
        state = .connected
        busy = false
        firstByte = true
        nextCommand()
    }

    private func completeWrite(acknowledged: Bool) {
        if !acknowledged || stop {
            if !acknowledged { abort(1 << 3) }
            state = .stop
            transmitDone()
            sendStop()
            return
        }
        busy = false
        transmitDone()
        nextCommand()
    }

    private func completeRead(_ value: UInt32) {
        pushRX(value | (firstByte ? 1 << 11 : 0))
        if stop {
            state = .stop
            transmitDone()
            sendStop()
            return
        }
        firstByte = false
        busy = false
        transmitDone()
        nextCommand()
    }

    private func completeStop() {
        state = .idle
        setInterrupts(RPI2C.stopDetected)
        busy = false
        pendingRestart = false
        transmitDone()
        if enable & 2 != 0 {
            enable &= ~2
        } else {
            nextCommand()
        }
    }

    // MARK: - Registers

    override func readUint32(_ offset: UInt32) -> UInt32 {
        switch offset {
        case 0x00: return control
        case 0x04: return targetAddress
        case 0x08: return slaveAddress
        case 0x10:
            guard !rxFIFO.empty else {
                setInterrupts(RPI2C.rxUnder)
                return 0
            }
            clearInterrupts(RPI2C.rxFull)
            return rxFIFO.pull()
        case 0x14: return ssHigh
        case 0x18: return ssLow
        case 0x1C: return fsHigh
        case 0x20: return fsLow
        case 0x2C: return intStatus
        case 0x30: return intEnable
        case 0x34: return intRaw
        case 0x38: return rxThreshold
        case 0x3C: return txThreshold
        case 0x40:
            abortSource &= 1 << 9
            return clearInterrupts(0x7EF)
        case 0x44: return clearInterrupts(RPI2C.rxUnder)
        case 0x48: return clearInterrupts(RPI2C.rxOver)
        case 0x4C: return clearInterrupts(RPI2C.txOver)
        case 0x50: return clearInterrupts(1 << 5)
        case 0x54:
            abortSource &= 1 << 9
            return clearInterrupts(RPI2C.txAbort)
        case 0x58: return clearInterrupts(1 << 7)
        case 0x5C: return clearInterrupts(1 << 8)
        case 0x60: return clearInterrupts(RPI2C.stopDetected)
        case 0x64: return clearInterrupts(RPI2C.startDetected)
        case 0x68: return clearInterrupts(1 << 11)
        case 0x6C: return enable
        case 0x70:
            var status: UInt32 = state != .idle ? (1 << 5) | 1 : 0
            if !txFIFO.full { status |= 1 << 1 }
            if txFIFO.empty { status |= 1 << 2 }
            if !rxFIFO.empty { status |= 1 << 3 }
            if rxFIFO.full { status |= 1 << 4 }
            return status
        case 0x74: return UInt32(txFIFO.itemCount)
        case 0x78: return UInt32(rxFIFO.itemCount)
        case 0x7C: return 0x01
        case 0x80:
            let value = abortSource
            abortSource &= 1 << 9
            return value
        case 0x9C: return enable & 1
        case 0xA0: return spikeLength & 0xFF
        case 0xF4: return 0
        case 0xF8: return 0x3230_312A
        case 0xFC: return 0x4457_0140
        default: return super.readUint32(offset)
        }
    }

    override func writeUint32(_ offset: UInt32, _ value: UInt32) {
        switch offset {
        case 0x00:
            control = (value >> 1) & 3 == 0 ? value & ~(3 << 1) | (3 << 1) : value
        case 0x04: targetAddress = value & 0x3FF
        case 0x08: slaveAddress = value & 0x3FF
        case 0x10:
            if txFIFO.full {
                setInterrupts(RPI2C.txOver)
            } else {
                txFIFO.push(value)
                clearInterrupts(RPI2C.txEmpty)
                nextCommand()
            }
        case 0x14: ssHigh = value & 0xFFFF
        case 0x18: ssLow = value & 0xFFFF
        case 0x1C: fsHigh = value & 0xFFFF
        case 0x20: fsLow = value & 0xFFFF
        case 0x30:
            intEnable = value
            checkInterrupts()
        case 0x38: rxThreshold = min(value & 0xFF, 16)
        case 0x3C: txThreshold = min(value & 0xFF, 16)
        case 0x6C:
            var newValue = value | enable & 2
            if newValue & 2 != 0 {
                if state == .idle {
                    newValue &= ~2
                } else {
                    abort(1 << 16)
                    stop = true
                }
            }
            if newValue & 1 == 0 {
                txFIFO.reset()
                rxFIFO.reset()
                sequencer.cancel()
                busy = false
                state = .idle
                sdaLow = false
                sclLow = false
                chip.peripheralPinsChanged(function: RPGPIOPin.functionI2C)
            }
            enable = newValue
            nextCommand()
        case 0xA0:
            if value & 1 == 0 && value > 0 { spikeLength = value }
        case 0x7C, 0x88, 0x8C, 0x90, 0x94, 0x98, 0x84:
            break
        default:
            super.writeUint32(offset, value)
        }
    }
}
