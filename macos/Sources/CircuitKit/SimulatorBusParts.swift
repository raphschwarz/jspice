import Foundation

// The parts a microcontroller writes over its buses (a CV DAC, a PCA9685, a TLC5947, an EEPROM, an MCP3008) and the
// chips' I²C, SPI and I²S plumbing around them, moved out of Simulator.swift as they were.

extension Simulator {
    /// What a part written over a bus holds (a CV DAC, a PCA9685, a TLC5947, an EEPROM), all in one, so that whatever
    /// carries a part's state (`load`, `adoptState`, `initialiseState`, a thrown-away substep) carries all of it.
    /// A part has only its own kind's fields filled; the rest stay empty.
    struct BusPartState: Equatable {
        struct Write: Equatable {
            var address: Int
            var byte: UInt8
        }
        /// A CV DAC's outputs' codes, then its input registers'
        var cvDacCodes: [UInt16] = []
        /// A PCA9685's registers, and the one its next byte written goes to
        var pwmRegisters: [UInt8] = []
        var pwmPointer = 0
        /// A TLC5947's shift register's twenty-four 12-bit levels, then its latched ones; and when BLANK last fell
        var sinkLevels: [UInt16] = []
        var sinkStart = 0.0
        /// An EEPROM's memory (made as it is first reached), its address pointer, the bytes of the page write under
        /// way (written at its STOP), and when its write cycle ends
        var eepromData: [UInt8] = []
        var eepromPointer = 0
        var eepromPending: [Write] = []
        var eepromBusy = 0.0

        /// A part of this kind as it comes from the box
        init(_ kind: ElementKind) {
            switch kind {
            case .cvDac: cvDacCodes = [UInt16](repeating: 0, count: 16)
            case .ledDriver: pwmRegisters = Logic.pwmReset()
            case .ledSink: sinkLevels = [UInt16](repeating: 0, count: 48)
            default: break
            }
        }

        init() {}

        /// Takes on `other`'s contents, copied into its own storage where the sizes allow: never sharing `other`'s
        /// (which the simulator on the sound's thread would then have to copy as it next writes), and allocating
        /// nothing once the sizes match
        mutating func copy(from other: BusPartState) {
            Self.copy(&cvDacCodes, other.cvDacCodes)
            Self.copy(&pwmRegisters, other.pwmRegisters)
            pwmPointer = other.pwmPointer
            Self.copy(&sinkLevels, other.sinkLevels)
            sinkStart = other.sinkStart
            Self.copy(&eepromData, other.eepromData)
            eepromPointer = other.eepromPointer
            Self.copy(&eepromPending, other.eepromPending)
            eepromBusy = other.eepromBusy
        }

        @inline(__always) private static func copy<T>(_ target: inout [T], _ source: [T]) {
            if target.count == source.count {
                guard !source.isEmpty else { return }
                Simulator.adopt(&target, source)
            } else {
                target.removeAll(keepingCapacity: true)
                target.append(contentsOf: source)
            }
        }
    }

    /// A TLC5947's grayscale counter now (nil while BLANK is high)
    func sinkCount(_ i: Int) -> Int? {
        guard i < busParts.count, busParts[i].sinkLevels.count == 48 else { return nil }
        return Logic.sinkCount(elapsed: time - busParts[i].sinkStart, frequency: constants[i].frequency,
                               blank: logicStates[i].inputs & 8 != 0)
    }

    /// The current each of a TLC5947's outputs sinks now, with the circuit's voltages `v`
    func sinkCurrents(_ i: Int, _ v: (Int) -> Double) -> [Double] {
        let nodes = topology.elementNodes[i]
        let count = sinkCount(i)
        return (0..<24).map { k in
            guard 4 + k < nodes.count, let count, count < Int(busParts[i].sinkLevels[24 + k]) else { return 0 }
            return Logic.sinkCurrent(v(nodes[4 + k]), full: constants[i].high).current
        }
    }

    /// A byte written to a PCA9685 after its address: the first sets the register written next, the rest are written
    /// there, one register on for each with MODE1's AI set. PRE_SCALE takes a write only while it sleeps; ALL_LED's
    /// registers write every channel's
    func pwmByte(_ i: Int, index: Int, byte: UInt8) {
        guard i < busParts.count, busParts[i].pwmRegisters.count == 256 else { return }
        if index == 0 {
            busParts[i].pwmPointer = Int(byte)
            return
        }
        let register = busParts[i].pwmPointer
        switch register {
        case 0xFE:
            if busParts[i].pwmRegisters[0] & 0x10 != 0 { busParts[i].pwmRegisters[0xFE] = byte }
        case 0xFA...0xFD:
            busParts[i].pwmRegisters[register] = byte
            for k in 0..<16 { busParts[i].pwmRegisters[6 + 4 * k + register - 0xFA] = byte }
        case 0:
            busParts[i].pwmRegisters[0] = byte
            // ALLCALL: whether it answers at 0x70
            if byte & 1 != 0 { logicStates[i].latch |= Logic.i2cAllCall } else { logicStates[i].latch &= ~Logic.i2cAllCall }
        default:
            busParts[i].pwmRegisters[register] = byte
        }
        if busParts[i].pwmRegisters[0] & 0x20 != 0 { busParts[i].pwmPointer = (register + 1) & 0xFF }
    }

    /// A PCA9685's sixteen outputs now (all off while OE is high)
    func pwmOutputs(_ i: Int) -> [Bool] {
        guard i < busParts.count else { return [] }
        return Logic.pwmOutputs(busParts[i].pwmRegisters, time: time, enabled: logicStates[i].inputs & 4 == 0)
    }

    /// An MCP3008's conversion: SGL/DIFF and D2–D0 pick the input (single-ended against ground, or a pair: CH2k and
    /// CH2k+1, either way round), read against VREF as 1024 steps
    func adcCode(_ i: Int, configuration: UInt32) -> UInt32 {
        let nodes = topology.elementNodes[i]
        guard nodes.count >= 13 else { return 0 }
        let channel = Int(configuration & 0x7)
        let reference = voltage(nodes[4])
        let plus = voltage(nodes[5 + channel])
        let minus = configuration & 0x8 != 0 ? 0 : voltage(nodes[5 + (channel ^ 1)])
        guard reference > 1e-6 else { return 0 }
        let levels = constants[i].value >= 12 ? 4096.0 : 1024.0
        let code = ((plus - minus) / reference * levels).rounded(.down)
        return UInt32(min(max(code, 0), levels - 1))
    }

    // MARK: Microcontrollers

    /// The chip of the microcontroller at `index`, if it has firmware
    public func chip(_ index: Int) -> Microcontroller? { chips[index] }

    /// Restarts one chip from its reset vector, the rest of the circuit carrying on
    public func resetChip(_ index: Int) {
        guard let chip = chips[index] else { return }
        chip.reset()
        chipCycleCarry[index] = 0
        chipPinStates[index] = chip.pinStates
        watchChipPins()
        matrixIsCurrent = false
        currentsAreStale = true
    }

    /// Runs each chip for the coming step's clock cycles, its inputs at the voltages of the last step, and notes
    /// whether its pins changed between input and output (which changes the matrix; levels only change currents)
    func runChips() {
        for i in chipIndices {
            // (by element in arrays: the dictionaries' hashing was a fortieth of an Arduino's step)
            guard i < chipAt.count, i < chipCycleCarry.count, let chip = chipAt[i] else { continue }
            let nodes = topology.elementNodes[i]
            let reached = min(chip.pinCount, nodes.count)
            if chip.pinVoltages.count == chip.pinCount {
                // written in place, in one change the chip sees once (a new array at every step otherwise)
                let floating = i < floatingChipPins.count ? floatingChipPins[i] : []
                chip.pinVoltages.withUnsafeMutableBufferPointer { volts in
                    for pin in volts.indices {
                        volts[pin] = pin < floating.count && floating[pin] ? .nan : pin < reached ? voltage(nodes[pin]) : 0
                    }
                }
            } else {
                var volts = [Double](repeating: 0, count: chip.pinCount)
                for pin in 0..<reached { volts[pin] = voltage(nodes[pin]) }
                chip.pinVoltages = volts
            }
            let budget = timeStep * chip.clock + chipCycleCarry[i]
            let whole = max(Int(budget), 0)
            let start = chip.cycles
            // the bus devices wired to it follow its pins as it runs, and answer within the run
            if i < busHandlers.count, let handler = busHandlers[i] { chip.onPinEvent = handler.call }
            // the codecs wired to an STM32 exchange frames with it as it runs
            let linked = i < codecExchanges.count && (codecExchanges[i] != nil || codecTargets[i] != nil || spiExchanges[i] != nil)
            let stm32 = linked ? chip as? STM32Microcontroller : nil
            if let stm32 {
                stm32.frameExchange = codecExchanges[i]
                stm32.i2cTarget = codecTargets[i]
                stm32.spiExchange = spiExchanges[i]
            }
            if whole > 0 { chip.run(cycles: whole) }
            chip.onPinEvent = nil
            if let stm32 {
                stm32.frameExchange = nil
                stm32.i2cTarget = nil
                stm32.spiExchange = nil
            }
            if i < chipNoticeCounts.count, let stm32 = chip as? STM32Microcontroller { noteChip(i, stm32) }
            // the last instruction may run past the budget: the next step has that much less
            chipCycleCarry[i] = budget - Double(chip.cycles - start)
            let states = chip.pinStates
            let (switched, changed, sameCount): (Bool, Bool, Bool)
            do {
                // (the kept states let go before they are written over, below)
                let kept = chipPinStates[i]
                (switched, changed, sameCount) = (!Self.samePinSetup(states, kept), kept != states, kept?.count == states.count)
            }
            if switched { matrixSwitched() }
            if changed {
                // copied into the states kept, in place: holding the chip's own array would have it make a new one
                // the next time its pins change (at every step while its SPI or two-wire interface clocks a byte)
                if sameCount {
                    chipPinStates[i]?.withUnsafeMutableBufferPointer { own in
                        states.withUnsafeBufferPointer { now in
                            for k in own.indices { own[k] = now[k] }
                        }
                    }
                } else {
                    chipPinStates[i] = states
                }
            }
        }
        replayPinEvents()
    }

    /// Finds the logic parts' inputs wired to chips' pins, and has the chips log those pins
    func watchChipPins() {
        chipWatches = Array(repeating: [], count: kinds.count)
        busWatches = Array(repeating: [], count: kinds.count)
        busLines = Array(repeating: [], count: kinds.count)
        busHandlers = Array(repeating: nil, count: kinds.count)
        /// pin by pin, as an array long enough for the last pin that has any
        func byPinArray(_ byPin: [Int: [(element: Int, bit: Int)]]) -> [[(element: Int, bit: Int)]] {
            guard let last = byPin.keys.max() else { return [] }
            var table = [[(element: Int, bit: Int)]](repeating: [], count: last + 1)
            for (pin, targets) in byPin { table[pin] = targets }
            return table
        }
        for i in chipIndices {
            guard let chip = chips[i], i < topology.elementNodes.count else { continue }
            let chipNodes = topology.elementNodes[i]
            var byPin: [Int: [(element: Int, bit: Int)]] = [:]
            var busByPin: [Int: [(element: Int, bit: Int)]] = [:]
            for j in kinds.indices where kinds[j].isLogic && j < topology.elementNodes.count {
                let nodes = topology.elementNodes[j]
                let bus = kinds[j].isBusDevice
                for (bit, terminal) in kinds[j].logicInputs.enumerated() where terminal < nodes.count && nodes[terminal] > 0 {
                    for (pin, node) in chipNodes.enumerated() where node == nodes[terminal] {
                        if bus { busByPin[pin, default: []].append((j, bit)) } else { byPin[pin, default: []].append((j, bit)) }
                    }
                }
                // the line a bus device drives back: an ADC's DOUT, an I²C target's SDA
                let line = kinds[j] == .spiAdc ? 3 : kinds[j] == .shiftIn ? 12 : 1
                if bus, line < nodes.count, nodes[line] > 0 {
                    for (pin, node) in chipNodes.enumerated() where node == nodes[line] { busLines[j].append((i, pin)) }
                }
            }
            chip.watchedPins = Set(byPin.keys).union(busByPin.keys).sorted()
            chipWatches[i] = byPinArray(byPin)
            busWatches[i] = byPinArray(busByPin)
            // (called only while the chip runs, within `runChips`: the simulator is there)
            if !busByPin.isEmpty { busHandlers[i] = BusHandler { [unowned(unsafe) self] event in self.busEvent(i, event) } }
        }
        linkCodecs()
    }

    /// Finds the codecs wired to each STM32's I²S ports and I²C buses, and what the chip calls for them while it runs
    private func linkCodecs() {
        codecLinks = Array(repeating: [], count: kinds.count)
        codecBuses = Array(repeating: [], count: kinds.count)
        i2cDevices = Array(repeating: [], count: kinds.count)
        i2cTransfer = Array(repeating: (-1, 0, 0, false), count: kinds.count)
        codecExchanges = Array(repeating: nil, count: kinds.count)
        codecTargets = Array(repeating: nil, count: kinds.count)
        spiLinks = Array(repeating: [], count: kinds.count)
        spiExchanges = Array(repeating: nil, count: kinds.count)
        spiWords = Array(repeating: (0, 0), count: kinds.count)
        spiAdcStates = Array(repeating: (-1, 0, 0), count: kinds.count)
        floatingChipPins = Array(repeating: [], count: kinds.count)
        // (how many terminals each node joins: an STM32's pin alone on its node floats)
        var uses = [Int](repeating: 0, count: topology.nodeCount + 1)
        for nodes in topology.elementNodes { for node in nodes where node < uses.count { uses[node] += 1 } }
        busWirings = Array(repeating: [], count: kinds.count)
        busChips = Array(repeating: nil, count: kinds.count)
        busGenerations = Array(repeating: 0, count: kinds.count)
        busIssues = Array(repeating: nil, count: kinds.count)
        busIssuesPending = Array(repeating: false, count: kinds.count)
        busProblems = []
        // (a chip kept from before says its notices again)
        chipNotices = Array(repeating: [], count: kinds.count)
        chipNoticeCounts = Array(repeating: 0, count: kinds.count)
        let stm32s: Set<ElementKind> = [.stm32f405, .stm32f373, .stm32f103]
        for i in chipIndices where stm32s.contains(kinds[i]) && i < topology.elementNodes.count {
            let chipNodes = topology.elementNodes[i]
            floatingChipPins[i] = chipNodes.map { $0 > 0 && $0 < uses.count && uses[$0] == 1 }
            let wired: Set<ElementKind> = [.codec, .i2sDac, .cvDac, .spiAdc, .dac, .dualDac, .shiftRegister, .shiftIn, .ledDriver, .ledSink, .i2cDac,
                                           .i2cEeprom]
            for j in kinds.indices where wired.contains(kinds[j]) && j < topology.elementNodes.count {
                let pins = topology.elementNodes[j].map { node in node > 0 ? chipNodes.firstIndex(of: node) ?? -1 : -1 }
                if pins.contains(where: { $0 >= 0 }) { busWirings[i].append((j, pins)) }
            }
            guard !busWirings[i].isEmpty else { continue }
            busChips[i] = chips[i] as? STM32Microcontroller
            busGenerations[i] = 0
            if let stm32 = busChips[i] { resolveBuses(i, stm32) }
            // the pins that frame SPI words (a DAC's SYNC, an ADC's CS), whichever port they turn out to be on
            let syncs = busWirings[i].compactMap { wiring -> Int? in
                let part = wiring.part
                let terminal = kinds[part] == .spiAdc ? 0 : kinds[part] == .cvDac && constants[part].high >= 2 ? 2 : -1
                return terminal >= 0 && terminal < wiring.pins.count && wiring.pins[terminal] >= 0 ? wiring.pins[terminal] : nil
            }
            // (called only while the chip runs, within `runChips`: the simulator is there)
            spiExchanges[i] = { [unowned(unsafe) self] port, frame, bits in self.spiFrame(i, port, frame, bits) }
            // its SYNC pins watched: a falling edge starts a word
            if !syncs.isEmpty, let chip = chips[i] {
                chip.watchedPins = Array(Set(chip.watchedPins).union(syncs)).sorted()
                let previous = busHandlers[i]
                busHandlers[i] = BusHandler { [unowned(unsafe) self] event in
                    if !event.high {
                        self.refreshBuses(i)
                        for link in self.spiLinks[i] where link.sync == event.pin {
                            self.spiWords[link.dac] = (0, 0)
                            self.spiAdcStates[link.dac] = (-1, 0, 0)
                        }
                    }
                    previous?.call(event)
                }
            }
            codecExchanges[i] = { [unowned(unsafe) self] port, left, right in self.codecFrame(i, port, left, right) }
            if busWirings[i].contains(where: { [.codec, .i2cDac, .ledDriver, .i2cEeprom].contains(kinds[$0.part]) }) {
                codecTargets[i] = STM32Microcontroller.I2CTarget(
                    start: { [unowned(unsafe) self] bus, address, read in self.i2cStart(i, bus, address, read) },
                    write: { [unowned(unsafe) self] _, byte in self.i2cWrite(i, byte) },
                    read: { [unowned(unsafe) self] _, _ in self.i2cRead(i) },
                    stop: { [unowned(unsafe) self] _ in self.i2cStop(i) })
            }
        }
    }

    /// An STM32 addressing a target on one of its I²C buses: a codec at its address (a WM8731 at 0x1A), an MCP4725 at 0x60
    /// or 0x61 (its A0 pin), a PCA9685, an EEPROM; whether one acknowledges
    private func i2cStart(_ i: Int, _ bus: Int, _ address: UInt8, _ read: Bool) -> Bool {
        refreshBuses(i)
        i2cTransfer[i] = (-1, 0, 0, false)
        // a codec at its address (the WM8731's 0x1A or 0x1B, a CS4270's 0x48...)
        if codecBuses[i].contains(where: { $0.bus == bus && Int(constants[$0.codec].high) == Int(address) }) { return true }
        for device in i2cDevices[i] where device.bus == bus {
            let nodes = topology.elementNodes[device.part]
            func high(_ terminal: Int) -> Bool { nodes.count > terminal && voltage(nodes[terminal]) > constants[device.part].supply / 2 }
            if kinds[device.part] == .i2cEeprom {
                // at 0x50 + A2-A0; a 24LC04 to 24LC16 takes the block of 256 bytes in those bits instead
                let size = Int(constants[device.part].value)
                let blockBits = size > 256 && size <= 2048 ? Int(log2(Double(size / 256))) : 0
                let blocks = (1 << blockBits) - 1
                let pins = (0...2).reduce(0) { $0 | (high(3 + $1) ? 1 << $1 : 0) }
                guard Int(address) & ~blocks == (0x50 | pins) & ~blocks else { continue }
                // in its write cycle it answers nothing: a firmware polls for its acknowledge until it does
                if time < busParts[device.part].eepromBusy { return false }
                if busParts[device.part].eepromData.count != size { busParts[device.part].eepromData = [UInt8](repeating: 0xFF, count: size) }
                busParts[device.part].eepromPending = []
                i2cTransfer[i].part = device.part
                i2cTransfer[i].data = UInt32(Int(address) & blocks)
                return true
            }
            if kinds[device.part] == .ledDriver {
                // a PCA9685 at 0x40 + A5-A0, or 0x70 while its all-call is on
                let pins = (0...5).reduce(0) { $0 | (high(3 + $1) ? 1 << $1 : 0) }
                let allCall = logicStates[device.part].latch & Logic.i2cAllCall != 0
                if Int(address) == 0x40 | pins || (allCall && address == 0x70) {
                    i2cTransfer[i].part = device.part
                    // (a read starts at the register written last)
                    if read { i2cTransfer[i].index = 1 }
                    return true
                }
            } else if address == 0x60 | (high(2) ? 1 : 0) {
                if !read { i2cTransfer[i].part = device.part }
                return true
            }
        }
        return false
    }

    /// A byte the chip reads from the target it addressed: a PCA9685's register (the next one with MODE1's AI set), an
    /// EEPROM's next byte (on through its whole memory, round to the start)
    private func i2cRead(_ i: Int) -> UInt8 {
        let part = i2cTransfer[i].part
        if part >= 0, kinds[part] == .i2cEeprom, !busParts[part].eepromData.isEmpty {
            let at = busParts[part].eepromPointer % busParts[part].eepromData.count
            busParts[part].eepromPointer = (at + 1) % busParts[part].eepromData.count
            return busParts[part].eepromData[at]
        }
        guard part >= 0, kinds[part] == .ledDriver, part < busParts.count, busParts[part].pwmRegisters.count == 256 else { return 0xFF }
        let register = busParts[part].pwmPointer
        let byte = busParts[part].pwmRegisters[register]
        if busParts[part].pwmRegisters[0] & 0x20 != 0 { busParts[part].pwmPointer = (register + 1) & 0xFF }
        return byte
    }

    /// A byte the chip writes to the target it addressed: an MCP4725 takes its code from them (fast mode: pairs of
    /// bytes, PD1 PD0 and the code's top four bits, then its low eight; or a write command, then the code's top eight
    /// bits, then its low four), as its bit-level model does
    private func i2cWrite(_ i: Int, _ byte: UInt8) -> Bool {
        var transfer = i2cTransfer[i]
        guard transfer.part >= 0 else { return true }  // (a codec's register writes)
        if kinds[transfer.part] == .ledDriver {
            pwmByte(transfer.part, index: transfer.index, byte: byte)
            i2cTransfer[i].index += 1
            return true
        }
        if kinds[transfer.part] == .i2cEeprom {
            eepromByte(transfer.part, index: transfer.index, block: Int(transfer.data), byte: byte)
            i2cTransfer[i].index += 1
            return true
        }
        let value = UInt32(byte)
        if transfer.index == 0 {
            transfer.command = value >> 6 != 0
            transfer.data = value
        } else if !transfer.command {
            if transfer.index % 2 == 0 {
                transfer.data = value
            } else {
                logicStates[transfer.part].count = Int((transfer.data >> 4 & 0x3) << 12 | (transfer.data & 0xF) << 8 | value)
            }
        } else if transfer.index == 1 {
            transfer.data = transfer.data << 8 | value
        } else if transfer.index == 2 {
            let command = transfer.data >> 8
            logicStates[transfer.part].count = Int((command >> 1 & 0x3) << 12 | (transfer.data & 0xFF) << 4 | value >> 4)
        }
        transfer.index += 1
        i2cTransfer[i] = transfer
        return true
    }

    /// A byte written to an EEPROM after its address: its memory address first (two bytes, high first; or one, with the
    /// block from the device address), then the page write's data, the address wrapping round within its page
    private func eepromByte(_ part: Int, index: Int, block: Int, byte: UInt8) {
        let size = Int(constants[part].value), page = Int(constants[part].high)
        let addressBytes = size > 2048 ? 2 : 1
        if index < addressBytes {
            if addressBytes == 2 && index == 0 {
                busParts[part].eepromPointer = Int(byte) << 8
            } else {
                busParts[part].eepromPointer = ((addressBytes == 2 ? busParts[part].eepromPointer : block << 8) | Int(byte)) % size
            }
            return
        }
        let at = busParts[part].eepromPointer
        busParts[part].eepromPending.append(BusPartState.Write(address: at, byte: byte))
        busParts[part].eepromPointer = at / page * page + (at + 1) % page
    }

    /// A STOP on an STM32's I²C bus: an EEPROM written to starts its write cycle, its page written as it ends (unless
    /// WP is high: then nothing is written, and it is ready at once)
    private func i2cStop(_ i: Int) {
        let part = i2cTransfer[i].part
        i2cTransfer[i].part = -1
        guard part >= 0, kinds[part] == .i2cEeprom, !busParts[part].eepromPending.isEmpty else { return }
        let pending = busParts[part].eepromPending
        busParts[part].eepromPending = []
        let nodes = topology.elementNodes[part]
        if nodes.count > 2 && voltage(nodes[2]) > constants[part].supply / 2 { return }
        for write in pending where write.address < busParts[part].eepromData.count {
            busParts[part].eepromData[write.address] = write.byte
        }
        busParts[part].eepromBusy = time + constants[part].frequency
    }

    /// What a bus part holds now, and putting something in it as its bus would (for tests)
    func busPartState(_ i: Int) -> BusPartState {
        busParts[i]
    }

    func setBusPartState(_ i: Int, _ state: BusPartState) {
        busParts[i] = state
    }

    /// What an EEPROM holds (nil for another part, or one nothing has reached yet: every byte still 0xFF)
    public func eepromContents(_ index: Int) -> [UInt8]? {
        guard index < busParts.count, index < kinds.count, kinds[index] == .i2cEeprom, !busParts[index].eepromData.isEmpty else { return nil }
        return busParts[index].eepromData
    }

    /// A frame an STM32 sends on an I²S port: the codecs (and PCM5102s) on it take it for their outputs, both kept
    /// left-justified (the left in `latch`, the right in `count`), and the first codec gives back what its line inputs
    /// read
    private func codecFrame(_ chip: Int, _ port: Int, _ left: Int32, _ right: Int32) -> (left: Int32, right: Int32) {
        refreshBuses(chip)
        if busIssuesPending[chip] { reportBusIssues(chip) }
        var input: (left: Int32, right: Int32) = (0, 0)
        var first = true
        for link in codecLinks[chip] where link.port == port {
            let j = link.codec
            if kinds[j] == .cvDac {
                // a DAC8568's SYNC is the frame's left half: a word each frame; a DAC8564's, each PCM word
                let format = Int(constants[j].high)
                guard format < 2 else { continue }
                Logic.cvDacWord(UInt32(bitPattern: left), format: format, codes: &busParts[j].cvDacCodes)
                if format == 1 { Logic.cvDacWord(UInt32(bitPattern: right), format: 1, codes: &busParts[j].cvDacCodes) }
                continue
            }
            logicStates[j].latch = UInt32(bitPattern: left)
            logicStates[j].count = Int(right)
            if first && kinds[j] == .codec {
                first = false
                let nodes = topology.elementNodes[j]
                input = (codecSample(j, nodes, 10), codecSample(j, nodes, 11))
            }
        }
        return input
    }

    /// A frame an STM32 shifts out on an SPI port: each CV DAC on it takes its bits, a word when it has them all since
    /// its SYNC fell (without a SYNC wired, a word each time it has them); it shifts nothing back
    private func spiFrame(_ chip: Int, _ port: Int, _ frame: UInt32, _ bits: Int) -> UInt32 {
        refreshBuses(chip)
        if busIssuesPending[chip] { reportBusIssues(chip) }
        guard spiLinks[chip].contains(where: { $0.port == port }) else { return 0xFFFF }
        var reply: UInt32 = 0
        for link in spiLinks[chip] where link.port == port {
            let j = link.dac
            if kinds[j] == .spiAdc {
                reply |= spiAdcFrame(j, frame, bits)
                continue
            }
            let format = Int(constants[j].high), wordBits = Logic.cvDacWordBits(format: format)
            var (shift, count) = spiWords[j]
            guard count < wordBits else { continue }
            shift = (shift << UInt64(bits)) | UInt64(frame & (bits >= 32 ? 0xFFFF_FFFF : (1 << UInt32(bits)) - 1))
            count += bits
            if count >= wordBits {
                let word = UInt32(truncatingIfNeeded: (shift >> UInt64(count - wordBits)) & ((1 << UInt64(wordBits)) - 1))
                Logic.cvDacWord(word, format: format, codes: &busParts[j].cvDacCodes)
                // the bits past it wait for the next SYNC; with none wired, they start the next word
                if link.sync < 0 {
                    count -= wordBits
                    shift &= (1 << UInt64(count)) - 1
                } else {
                    count = wordBits
                }
            }
            spiWords[j] = (shift, count)
        }
        return reply
    }

    /// An SPI ADC (the MCP3008, MCP3204, MCP3208) answering a frame an STM32 shifts out, bit by bit since its CS fell:
    /// a start bit, SGL and D2-D0 (the channel), then a clock for the sample and the null bit, then its result MSB
    /// first (10 or 12 bits), the input's voltage against VREF's
    private func spiAdcFrame(_ j: Int, _ frame: UInt32, _ bits: Int) -> UInt32 {
        let resolution = Int(constants[j].value) >= 12 ? 12 : 10
        var state = spiAdcStates[j]
        var count = spiWords[j].bits
        var out: UInt32 = 0
        for k in 0..<bits {
            let bit = (frame >> UInt32(bits - 1 - k)) & 1
            var outBit: UInt32 = 0
            if state.start < 0 {
                if bit == 1 { state.start = count }
            } else {
                let at = count - state.start
                if at >= 1 && at <= 4 {
                    state.config = state.config << 1 | bit
                    if at == 4 { state.code = spiAdcCode(j, channel: Int(state.config & 7), resolution: resolution) }
                }
                if at >= 7 && at < 7 + resolution { outBit = UInt32((state.code >> (resolution - 1 - (at - 7))) & 1) }
                if at >= 6 + resolution { state = (-1, 0, 0) }
            }
            out = out << 1 | outBit
            count += 1
        }
        spiAdcStates[j] = state
        spiWords[j].bits = count
        return out
    }

    /// An SPI ADC's result for a channel: 2^bits × its input / VREF, kept within its range
    private func spiAdcCode(_ j: Int, channel: Int, resolution: Int) -> Int {
        let nodes = topology.elementNodes[j]
        guard nodes.count > 5 + channel else { return 0 }
        let reference = max(voltage(nodes[4]), 1e-3)
        let code = (voltage(nodes[5 + channel]) / reference * Double(1 << resolution)).rounded(.down)
        return Int(min(max(code, 0), Double((1 << resolution) - 1)))
    }

    /// A codec's line input as its ADC reads it: about half its supply, full scale at its line level's peak,
    /// left-justified in 32 bits
    private func codecSample(_ j: Int, _ nodes: [Int], _ terminal: Int) -> Int32 {
        guard terminal < nodes.count else { return 0 }
        let c = constants[j]
        let x = (voltage(nodes[terminal]) - c.supply / 2) / (c.value * 2.squareRoot())
        let clamped = min(max(x, -1), 1 - 1 / 2_147_483_648)
        return Int32((clamped * 2_147_483_648).rounded(.down))
    }

    /// A watched pin changing as a chip runs, for the bus devices that follow it: they move on at once, and what they
    /// drive back on the chip's pins (an ADC's DOUT bit, an I²C target's acknowledge) is what the chip reads from then
    private func busEvent(_ chipIndex: Int, _ event: PinEvent) {
        guard chipIndex < busWatches.count, event.pin >= 0, event.pin < busWatches[chipIndex].count else { return }
        for target in busWatches[chipIndex][event.pin] {
            let old = logicStates[target.element]
            let mask = UInt32(1) << UInt32(target.bit)
            let inputs = event.high ? old.inputs | mask : old.inputs & ~mask
            guard inputs != old.inputs else { continue }
            let next = advanceLogic(target.element, old, inputs: inputs)
            for line in busLines[target.element] {
                guard line.chip < chipAt.count, let chip = chipAt[line.chip], line.pin < chip.pinCount else { continue }
                let volts: Double
                switch kinds[target.element] {
                case .spiAdc:
                    // DOUT while CS is low; let go, it stays as the circuit last had it
                    guard next.inputs & 1 == 0 else { continue }
                    volts = next.count != 0 ? chip.supply : 0
                case .shiftIn:
                    // QH, the last stage, always driven
                    volts = next.shift & 0x80 != 0 ? chip.supply : 0
                default:
                    // SDA held low while it acknowledges, else pulled up
                    volts = Logic.acknowledging(next) ? 0 : chip.supply
                }
                // (that pin alone: setting the chip's voltages would look at every pin again)
                if chip.pinVoltage(line.pin) != volts { chip.setPinVoltage(line.pin, volts) }
            }
        }
    }

    /// Plays what the chips did on the watched pins during their run into the logic parts wired to them, in the order
    /// it happened: an SPI word clocked out within one step reaches a DAC bit by bit
    private func replayPinEvents() {
        stepPinEvents.removeAll(keepingCapacity: true)
        var sources = 0
        // (one chip's events are in order already, and are replayed as they are: an I²S stream's are hundreds a step)
        var first: (chip: Int, clock: Double, events: [PinEvent]) = (-1, 0, [])
        for i in chipIndices where i < chipWatches.count && (!chipWatches[i].isEmpty || !busWatches[i].isEmpty) {
            guard let chip = chips[i] else { continue }
            // (the bus devices had theirs as the chip ran)
            let taken = chip.takePinEvents()
            guard !chipWatches[i].isEmpty, !taken.isEmpty else { continue }
            sources += 1
            if sources == 1 {
                first = (i, chip.clock, taken)
                continue
            }
            if sources == 2 {
                for event in first.events {
                    stepPinEvents.append((Double(event.cycle) / first.clock, stepPinEvents.count, first.chip, event))
                }
            }
            for event in taken {
                stepPinEvents.append((Double(event.cycle) / chip.clock, stepPinEvents.count, i, event))
            }
        }
        if sources == 1 {
            let watches = chipWatches[first.chip]
            for event in first.events where event.pin >= 0 && event.pin < watches.count {
                for target in watches[event.pin] { replayPinEvent(target, high: event.high) }
            }
            return
        }
        guard sources > 1 else { return }
        stepPinEvents.sort { ($0.time, $0.order) < ($1.time, $1.order) }
        for (_, _, i, event) in stepPinEvents where event.pin >= 0 && event.pin < chipWatches[i].count {
            for target in chipWatches[i][event.pin] { replayPinEvent(target, high: event.high) }
        }
    }

    /// A chip's pin going high or low, into a logic part's input wired to it
    @inline(__always) private func replayPinEvent(_ target: (element: Int, bit: Int), high: Bool) {
        let old = logicStates[target.element]
        let mask = UInt32(1) << UInt32(target.bit)
        let inputs = high ? old.inputs | mask : old.inputs & ~mask
        guard inputs != old.inputs else { return }
        advanceLogic(target.element, old, inputs: inputs)
    }
}
