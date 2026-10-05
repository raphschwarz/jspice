import Foundation

/// A PIO state machine (rp2040js's StateMachine). rp2040js runs PIO from JavaScript timers, apart from simulated time;
/// here each machine runs at clk_sys over its clock divider, its instructions and delays taking their cycles, so
/// what it does on its pins keeps time with the processor.
final class RPPIOMachine {
    enum WaitType { case none, pin, rxFIFO, txFIFO, irq, out }

    unowned let chip: RP2040
    unowned let pio: RPPIO
    let index: Int
    var enabled = false
    var x: UInt32 = 0
    var y: UInt32 = 0
    var pc: UInt32 = 0
    var inputShiftReg: UInt32 = 0
    var inputShiftCount: UInt32 = 0
    var outputShiftReg: UInt32 = 0
    var outputShiftCount: UInt32 = 0
    var cycles = 0
    var execOpcode: UInt32 = 0
    var execValid = false
    var updatePC = true
    var clockDivInt: UInt32 = 1
    var clockDivFrac: UInt32 = 0
    var execCtrl: UInt32 = 0x1F << 12
    var shiftCtrl: UInt32 = 0b11 << 18
    var pinCtrl: UInt32 = 0x5 << 26
    var rxFIFO = RPFIFO(4)
    var txFIFO = RPFIFO(4)
    var waiting = false
    var waitType = WaitType.none
    var waitIndex: UInt32 = 0
    var waitPolarity = false
    var waitDelay = -1
    let dreqRx: Int
    let dreqTx: Int
    /// When the next instruction runs, in simulated nanoseconds
    var nextNanos: Double = 0
    private var stepping = false

    init(chip: RP2040, pio: RPPIO, index: Int) {
        self.chip = chip
        self.pio = pio
        self.index = index
        dreqRx = (pio.index == 0 ? RPDREQ.pio0RX0 : RPDREQ.pio1RX0) + index
        dreqTx = (pio.index == 0 ? RPDREQ.pio0TX0 : RPDREQ.pio1TX0) + index
        updateDMARx()
        updateDMATx()
    }

    /// Nanoseconds per cycle of this machine
    var period: Double {
        let divider = Double(clockDivInt == 0 ? 65_536 : clockDivInt) + Double(clockDivFrac) / 256
        return divider * 1e9 / chip.clkSys
    }

    private func updateDMATx() {
        if txFIFO.full { chip.dma.clearDREQ(dreqTx) } else { chip.dma.setDREQ(dreqTx) }
    }

    private func updateDMARx() {
        if rxFIFO.empty { chip.dma.clearDREQ(dreqRx) } else { chip.dma.setDREQ(dreqRx) }
    }

    func writeFIFO(_ value: UInt32) {
        if txFIFO.full {
            pio.fdebug |= (1 << 16) << UInt32(index)
            return
        }
        txFIFO.push(value)
        pio.txStall &= ~((1 << 24) << UInt32(index))
        updateDMATx()
        checkWait()
        if txFIFO.full { pio.checkInterrupts() }
    }

    func readFIFO() -> UInt32 {
        if rxFIFO.empty {
            pio.fdebug |= (1 << 8) << UInt32(index)
            return 0
        }
        let result = rxFIFO.pull()
        pio.rxStall &= ~(1 << UInt32(index))
        updateDMARx()
        checkWait()
        if rxFIFO.empty { pio.checkInterrupts() }
        return result
    }

    var status: UInt32 {
        let n = Int(execCtrl & 0xF)
        if execCtrl & (1 << 4) != 0 { return rxFIFO.itemCount < n ? 0xFFFF_FFFF : 0 }
        return txFIFO.itemCount < n ? 0xFFFF_FFFF : 0
    }

    func jmpCondition(_ condition: UInt32) -> Bool {
        switch condition {
        case 0b000: return true
        case 0b001: return x == 0
        case 0b010:
            let old = x
            x = x &- 1
            return old != 0
        case 0b011: return y == 0
        case 0b100:
            let old = y
            y = y &- 1
            return old != 0
        case 0b101: return x != y
        case 0b110:
            let pin = Int(jmpPin)
            return pin < chip.gpio.count ? chip.gpio[pin].inputValue : false
        default: return outputShiftCount < pullThreshold
        }
    }

    var inPins: UInt32 {
        let values = chip.gpioValues
        let base = inBase
        return base != 0 ? (values << (32 - base)) | (values >> base) : values
    }

    func inSourceValue(_ source: UInt32) -> UInt32 {
        switch source {
        case 0b000: return inPins
        case 0b001: return x
        case 0b010: return y
        case 0b101: return status
        case 0b110: return inputShiftReg
        case 0b111: return outputShiftReg
        default: return 0
        }
    }

    func writeOutValue(_ destination: UInt32, _ value: UInt32, _ bitCount: UInt32) {
        switch destination {
        case 0b000: setOutPins(value)
        case 0b001: x = value
        case 0b010: y = value
        case 0b100: setOutPinDirs(value)
        case 0b101:
            pc = value & 0x1F
            updatePC = false
        case 0b110:
            inputShiftReg = value
            inputShiftCount = bitCount
        case 0b111:
            execOpcode = value
            execValid = true
        default: break
        }
    }

    var pushThreshold: UInt32 { let v = (shiftCtrl >> 20) & 0x1F; return v != 0 ? v : 32 }
    var pullThreshold: UInt32 { let v = (shiftCtrl >> 25) & 0x1F; return v != 0 ? v : 32 }
    var sidesetCount: UInt32 { (pinCtrl >> 29) & 0x7 }
    var setCount: UInt32 { (pinCtrl >> 26) & 0x7 }
    var outCount: UInt32 { (pinCtrl >> 20) & 0x3F }
    var inBase: UInt32 { (pinCtrl >> 15) & 0x1F }
    var sidesetBase: UInt32 { (pinCtrl >> 10) & 0x1F }
    var setBase: UInt32 { (pinCtrl >> 5) & 0x1F }
    var outBase: UInt32 { pinCtrl & 0x1F }
    var jmpPin: UInt32 { (execCtrl >> 24) & 0x1F }
    var wrapTop: UInt32 { (execCtrl >> 12) & 0x1F }
    var wrapBottom: UInt32 { (execCtrl >> 7) & 0x1F }

    func setOutPinDirs(_ value: UInt32) { pio.pinDirectionsChanged(value, outBase, outCount) }
    func setOutPins(_ value: UInt32) { pio.pinValuesChanged(value, outBase, outCount) }

    func outInstruction(_ arg: UInt32) {
        let bitCount = arg & 0x1F
        let destination = arg >> 5
        if bitCount == 0 {
            writeOutValue(destination, outputShiftReg, 32)
            outputShiftCount = 32
        } else {
            let value: UInt32
            if shiftCtrl & (1 << 19) != 0 {
                value = outputShiftReg & ((1 << bitCount) - 1)
                outputShiftReg >>= bitCount
            } else {
                value = outputShiftReg >> (32 - bitCount)
                outputShiftReg <<= bitCount
            }
            writeOutValue(destination, value, bitCount)
            outputShiftCount = min(outputShiftCount + bitCount, 32)
        }
    }

    private static func irqIndex(_ irq: UInt32, _ machine: Int) -> UInt32 {
        irq & 0x10 != 0 ? (irq & 0x4) | (((irq & 0x3) + UInt32(machine)) & 0x3) : irq & 0x7
    }

    private static func bitReverse(_ value: UInt32) -> UInt32 {
        var result: UInt32 = 0
        var v = value
        for _ in 0..<32 {
            result = (result << 1) | (v & 1)
            v >>= 1
        }
        return result
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func executeInstruction(_ opcode: UInt32) {
        let arg = opcode & 0xFF
        switch opcode >> 13 {
        case 0b000:
            if jmpCondition(arg >> 5) {
                pc = arg & 0x1F
                updatePC = false
            }
        case 0b001:
            let polarity = arg & 0x80 != 0
            let index = arg & 0x1F
            switch (arg >> 5) & 0x3 {
            case 0b00: wait(.pin, polarity, index)
            case 0b01: wait(.pin, polarity, (index + inBase) % 32)
            case 0b10: wait(.irq, polarity, RPPIOMachine.irqIndex(index, self.index))
            default: break
            }
        case 0b010:
            let bitCount = arg & 0x1F
            var source = inSourceValue(arg >> 5)
            if bitCount == 0 {
                inputShiftReg = source
                inputShiftCount = 32
            } else {
                source &= (1 << bitCount) - 1
                if shiftCtrl & (1 << 18) != 0 {
                    inputShiftReg >>= bitCount
                    inputShiftReg |= source << (32 - bitCount)
                } else {
                    inputShiftReg <<= bitCount
                    inputShiftReg |= source
                }
                inputShiftCount = min(inputShiftCount + bitCount, 32)
            }
            if shiftCtrl & (1 << 16) != 0 && inputShiftCount >= pushThreshold {
                if !rxFIFO.full {
                    rxFIFO.push(inputShiftReg)
                    updateDMARx()
                    pio.checkInterrupts()
                } else {
                    pio.rxStall |= 1 << UInt32(self.index)
                    pio.fdebug |= pio.rxStall
                    wait(.rxFIFO, false, inputShiftReg)
                }
                inputShiftCount = 0
                inputShiftReg = 0
            }
        case 0b011:
            if shiftCtrl & (1 << 17) != 0 && outputShiftCount >= pullThreshold {
                outputShiftCount = 0
                if !txFIFO.empty {
                    outputShiftReg = txFIFO.pull()
                    updateDMATx()
                    pio.checkInterrupts()
                } else {
                    pio.txStall |= (1 << 24) << UInt32(self.index)
                    pio.fdebug |= pio.txStall
                    wait(.out, false, arg)
                }
            }
            if !waiting { outInstruction(arg) }
        case 0b100:
            let block = arg & (1 << 5) != 0
            let ifFullOrEmpty = arg & (1 << 6) != 0
            if arg & 0x1F != 0 { break }
            if arg & 0x80 != 0 {
                if ifFullOrEmpty && shiftCtrl & (1 << 17) != 0 && outputShiftCount < pullThreshold { break }
                if !txFIFO.empty {
                    outputShiftReg = txFIFO.pull()
                    updateDMATx()
                    pio.checkInterrupts()
                } else {
                    pio.txStall |= (1 << 24) << UInt32(self.index)
                    pio.fdebug |= pio.txStall
                    if block { wait(.txFIFO, false, 0) } else { outputShiftReg = x }
                }
                outputShiftCount = 0
            } else {
                if ifFullOrEmpty && shiftCtrl & (1 << 16) != 0 && inputShiftCount < pushThreshold { break }
                if !rxFIFO.full {
                    rxFIFO.push(inputShiftReg)
                    updateDMARx()
                    pio.checkInterrupts()
                } else {
                    pio.rxStall |= 1 << UInt32(self.index)
                    pio.fdebug |= pio.rxStall
                    if block { wait(.rxFIFO, false, inputShiftReg) }
                }
                inputShiftReg = 0
                inputShiftCount = 0
            }
        case 0b101:
            let value = inSourceValue(arg & 0x7)
            let transformed: UInt32
            switch (arg >> 3) & 0x3 {
            case 0b01: transformed = ~value
            case 0b10: transformed = RPPIOMachine.bitReverse(value)
            default: transformed = value
            }
            setMovDestination((arg >> 5) & 0x7, transformed)
        case 0b110:
            if arg & 0x80 != 0 { break }
            let irq = RPPIOMachine.irqIndex(arg & 0x1F, self.index)
            if arg & 0x40 != 0 {
                pio.irq &= ~(1 << irq)
                pio.irqUpdated()
            } else {
                pio.irq |= 1 << irq
                pio.irqUpdated()
                if arg & 0x20 != 0 { wait(.irq, false, irq) }
            }
        default:
            let data = arg & 0x1F
            switch arg >> 5 {
            case 0b000: setSetPins(data)
            case 0b001: x = data
            case 0b010: y = data
            case 0b100: setSetPinDirs(data)
            default: break
            }
        }

        cycles += 1
        let count = sidesetCount
        let delaySideset = (opcode >> 8) & 0x1F
        let sideEnable = execCtrl & (1 << 30) != 0
        let delayBits = UInt32(max(5 - Int(count), 0))
        let delay = Int(delaySideset & ((1 << delayBits) - 1))
        if count != 0 && (!sideEnable || delaySideset & 0x10 != 0) {
            setSideset(delaySideset >> delayBits, sideEnable ? count - 1 : count)
        }
        if execValid {
            execValid = false
            executeInstruction(execOpcode)
        } else if waiting {
            if waitDelay < 0 { waitDelay = delay }
            checkWait()
        } else {
            cycles += delay
        }
    }

    func wait(_ type: WaitType, _ polarity: Bool, _ index: UInt32) {
        waiting = true
        waitType = type
        waitPolarity = polarity
        waitIndex = index
        waitDelay = -1
        updatePC = false
    }

    func nextPC() {
        if pc == wrapTop { pc = wrapBottom } else { pc = (pc + 1) & 0x1F }
    }

    func step() {
        if waiting {
            checkWait()
            if waiting { return }
        }
        updatePC = true
        executeInstruction(pio.instructions[Int(pc)])
        if updatePC { nextPC() }
    }

    /// Runs the instructions due by `now` (nanoseconds)
    func run(until now: Double) {
        let period = self.period
        stepping = true
        defer { stepping = false }
        while enabled && !waiting && nextNanos <= now {
            skipDelayLoop(until: now, period: period)
            guard nextNanos <= now else { break }
            let before = cycles
            step()
            nextNanos += Double(cycles - before) * period
        }
    }

    /// A `jmp x--` or `jmp y--` to itself only counts down: runs the turns due by `now` at once (all but the last,
    /// which falls through)
    private func skipDelayLoop(until now: Double, period: Double) {
        guard !execValid else { return }
        let opcode = pio.instructions[Int(pc)]
        guard opcode >> 13 == 0, opcode & 0x1F == pc else { return }
        let condition = (opcode >> 5) & 0x7
        guard condition == 0b010 || condition == 0b100 else { return }
        let count = sidesetCount
        let delay = Double(((opcode >> 8) & 0x1F) & ((1 << UInt32(max(5 - Int(count), 0))) - 1))
        let turn = (1 + delay) * period
        let due = ((now - nextNanos) / turn).rounded(.down)
        let remaining = condition == 0b010 ? x : y
        guard due >= 2, remaining >= 2 else { return }
        // the first turn runs as usual, so its side-set is applied
        let skip = UInt32(min(due - 1, Double(remaining - 1)))
        guard skip >= 1 else { return }
        step()
        nextNanos += turn
        let more = skip - 1
        guard more > 0, !waiting, pc == opcode & 0x1F else { return }
        if condition == 0b010 { x -= more } else { y -= more }
        cycles += Int(more) * Int(1 + delay)
        nextNanos += Double(more) * turn
    }

    func setSetPinDirs(_ value: UInt32) { pio.pinDirectionsChanged(value, setBase, setCount) }
    func setSetPins(_ value: UInt32) { pio.pinValuesChanged(value, setBase, setCount) }

    func setSideset(_ value: UInt32, _ count: UInt32) {
        if execCtrl & (1 << 29) != 0 {
            pio.pinDirectionsChanged(value, sidesetBase, count)
        } else {
            pio.pinValuesChanged(value, sidesetBase, count)
        }
    }

    func setMovDestination(_ destination: UInt32, _ value: UInt32) {
        switch destination {
        case 0b000: setOutPins(value)
        case 0b001: x = value
        case 0b010: y = value
        case 0b100:
            execOpcode = value
            execValid = true
        case 0b101:
            pc = value & 0x1F
            updatePC = false
        case 0b110:
            inputShiftReg = value
            inputShiftCount = 0
        case 0b111:
            outputShiftReg = value
            outputShiftCount = 0
        default: break
        }
    }

    func readUint32(_ offset: UInt32) -> UInt32 {
        switch offset {
        case 0x00: return (clockDivInt << 16) | (clockDivFrac << 8)
        case 0x04: return execCtrl
        case 0x08: return shiftCtrl
        case 0x0C: return pc
        case 0x10: return pio.instructions[Int(pc)]
        case 0x14: return pinCtrl
        default: return 0
        }
    }

    func writeUint32(_ offset: UInt32, _ value: UInt32) {
        switch offset {
        case 0x00:
            clockDivFrac = (value >> 8) & 0xFF
            clockDivInt = value >> 16
        case 0x04:
            execCtrl = (value & 0x7FFF_FFFF) | (execCtrl & 0x8000_0000)
        case 0x08:
            shiftCtrl = value
        case 0x10:
            executeInstruction(value & 0xFFFF)
            if waiting { execCtrl |= 1 << 31 }
        case 0x14:
            pinCtrl = value
        default:
            break
        }
    }

    var fifoStat: UInt32 {
        let result: UInt32 = (txFIFO.empty ? 1 << 24 : 0) | (txFIFO.full ? 1 << 16 : 0) | (rxFIFO.empty ? 1 << 8 : 0)
            | (rxFIFO.full ? 1 : 0)
        return result << UInt32(index)
    }

    func restart() {
        cycles = 0
        inputShiftCount = 0
        outputShiftCount = 32
        inputShiftReg = 0
        waiting = false
    }

    func checkWait() {
        guard waiting else { return }
        switch waitType {
        case .irq:
            let value = pio.irq & (1 << waitIndex) != 0
            if value == waitPolarity {
                waiting = false
                if value { pio.irq &= ~(1 << waitIndex) }
            }
        case .pin:
            if Int(waitIndex) < chip.gpio.count && chip.gpio[Int(waitIndex)].inputValue == waitPolarity { waiting = false }
        case .rxFIFO:
            if !rxFIFO.full {
                rxFIFO.push(waitIndex)
                waiting = false
                updateDMARx()
                pio.checkInterrupts()
            }
        case .txFIFO:
            if !txFIFO.empty {
                outputShiftReg = txFIFO.pull()
                waiting = false
                updateDMATx()
                pio.checkInterrupts()
            }
        case .out:
            if !txFIFO.empty {
                outputShiftReg = txFIFO.pull()
                outInstruction(waitIndex)
                waiting = false
                updateDMATx()
                pio.checkInterrupts()
            }
        case .none:
            break
        }
        if !waiting {
            nextPC()
            cycles += waitDelay
            execCtrl &= ~(1 << 31)
            // woken by the processor or a pin: the machine carries on from now
            if !stepping {
                nextNanos = max(nextNanos, chip.clock.nanos) + Double(max(waitDelay, 0)) * period
            }
        }
    }
}

/// A PIO block: four state machines sharing 32 instructions
final class RPPIO: RPPeripheral {
    let index: Int
    private let firstIRQ: Int
    var instructions = [UInt32](repeating: 0, count: 32)
    private(set) var machines: [RPPIOMachine] = []
    var fdebug: UInt32 = 0
    var txStall: UInt32 = 0
    var rxStall: UInt32 = 0
    private var inputSyncBypass: UInt32 = 0
    var irq: UInt32 = 0
    var pinValues: UInt32 = 0
    var pinDirections: UInt32 = 0
    private var oldPinValues: UInt32 = 0
    private var oldPinDirections: UInt32 = 0
    private var irq0IntEnable: UInt32 = 0
    private var irq0IntForce: UInt32 = 0
    private var irq1IntEnable: UInt32 = 0
    private var irq1IntForce: UInt32 = 0

    init(chip: RP2040, name: String, firstIRQ: Int, index: Int) {
        self.index = index
        self.firstIRQ = firstIRQ
        super.init(chip: chip, name: name)
        machines = (0..<4).map { RPPIOMachine(chip: chip, pio: self, index: $0) }
    }

    /// Whether any state machine runs
    private(set) var running = false

    var intRaw: UInt32 {
        var result = (irq & 0xF) << 8
        for (i, machine) in machines.enumerated() {
            if !machine.txFIFO.full { result |= 0x10 << UInt32(i) }
            if !machine.rxFIFO.empty { result |= 0x01 << UInt32(i) }
        }
        return result
    }

    private var irq0IntStatus: UInt32 { (intRaw & irq0IntEnable) | irq0IntForce }
    private var irq1IntStatus: UInt32 { (intRaw & irq1IntEnable) | irq1IntForce }

    override func readUint32(_ offset: UInt32) -> UInt32 {
        if offset >= 0xC8 && offset <= 0x124 {
            let machine = Int(offset - 0xC8) / 0x18
            return machines[machine].readUint32(offset - 0xC8 - UInt32(machine) * 0x18)
        }
        switch offset {
        case 0x000: return machines.enumerated().reduce(0) { $0 | ($1.element.enabled ? 1 << UInt32($1.offset) : 0) }
        case 0x004: return machines.reduce(0) { $0 | $1.fifoStat }
        case 0x008: return fdebug
        case 0x00C:
            return machines.enumerated().reduce(0) {
                $0 | (UInt32($1.element.txFIFO.itemCount & 0xF) << UInt32($1.offset * 8))
                    | (UInt32($1.element.rxFIFO.itemCount & 0xF) << UInt32($1.offset * 8 + 4))
            }
        case 0x020, 0x024, 0x028, 0x02C: return machines[Int(offset - 0x020) / 4].readFIFO()
        case 0x030: return irq
        case 0x034: return 0
        case 0x038: return inputSyncBypass
        case 0x03C: return pinValues
        case 0x040: return pinDirections
        case 0x044: return 0x200404
        case 0x128: return intRaw
        case 0x12C: return irq0IntEnable
        case 0x130: return irq0IntForce
        case 0x134: return irq0IntStatus
        case 0x138: return irq1IntEnable
        case 0x13C: return irq1IntForce
        case 0x140: return irq1IntStatus
        default: return super.readUint32(offset)
        }
    }

    override func writeUint32(_ offset: UInt32, _ value: UInt32) {
        if offset >= 0x48 && offset <= 0xC4 {
            instructions[Int(offset - 0x48) >> 2] = value & 0xFFFF
            return
        }
        if offset >= 0xC8 && offset <= 0x124 {
            let machine = Int(offset - 0xC8) / 0x18
            machines[machine].writeUint32(offset - 0xC8 - UInt32(machine) * 0x18, value)
            // an instruction run from here (as pio_sm_set_consecutive_pindirs does) can set pins
            checkChangedPins()
            return
        }
        switch offset {
        case 0x000:
            for (i, machine) in machines.enumerated() {
                let enable = value & (1 << UInt32(i)) != 0
                if enable && !machine.enabled { machine.nextNanos = chip.clock.nanos }
                machine.enabled = enable
                if value & (1 << UInt32(4 + i)) != 0 { machine.restart() }
            }
            running = value & 0xF != 0
        case 0x008:
            fdebug &= ~rawWriteValue
            fdebug |= txStall | rxStall
        case 0x010, 0x014, 0x018, 0x01C:
            machines[Int(offset - 0x010) / 4].writeFIFO(value)
        case 0x030:
            irq &= ~rawWriteValue
            irqUpdated()
        case 0x038:
            inputSyncBypass = value
        case 0x034:
            irq |= value
            irqUpdated()
        case 0x12C:
            irq0IntEnable = value & 0xFFF
            checkInterrupts()
        case 0x130:
            irq0IntForce = value & 0xFFF
            checkInterrupts()
        case 0x138:
            irq1IntEnable = value & 0xFFF
            checkInterrupts()
        case 0x13C:
            irq1IntForce = value & 0xFFF
            checkInterrupts()
        default:
            super.writeUint32(offset, value)
        }
    }

    func pinValuesChanged(_ value: UInt32, _ firstPin: UInt32, _ count: UInt32) {
        let mask: UInt32 = count > 31 ? 0xFFFF_FFFF : ((1 << count) - 1) << firstPin
        pinValues = ((pinValues & ~mask) | ((value << firstPin) & mask)) & 0x3FFF_FFFF
    }

    func pinDirectionsChanged(_ value: UInt32, _ firstPin: UInt32, _ count: UInt32) {
        let mask: UInt32 = count > 31 ? 0xFFFF_FFFF : ((1 << count) - 1) << firstPin
        pinDirections = ((pinDirections & ~mask) | ((value << firstPin) & mask)) & 0x3FFF_FFFF
    }

    func checkInterrupts() {
        chip.setInterrupt(firstIRQ, irq0IntStatus != 0)
        chip.setInterrupt(firstIRQ + 1, irq1IntStatus != 0)
    }

    func irqUpdated() {
        for machine in machines { machine.checkWait() }
        checkInterrupts()
    }

    func checkChangedPins() {
        let changed = (oldPinDirections ^ pinDirections) | (oldPinValues ^ pinValues)
        guard changed != 0 else { return }
        oldPinDirections = pinDirections
        oldPinValues = pinValues
        for (i, pin) in chip.gpio.enumerated() where changed & (1 << UInt32(i)) != 0 { pin.checkForUpdates() }
    }

    /// Runs the state machines up to `now` (nanoseconds)
    func run(until now: Double) {
        for machine in machines where machine.enabled { machine.run(until: now) }
        checkChangedPins()
    }
}
