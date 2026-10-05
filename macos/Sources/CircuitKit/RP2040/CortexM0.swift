import Foundation

/// The RP2040's ARM Cortex-M0+ core: the ARMv6-M Thumb instruction set, exceptions and the NVIC's priorities, ported
/// from rp2040js's cortex-m0-core.ts (instructions are decoded in the same order, cycles counted the same way). Flags
/// follow the ARM architecture where rp2040js is off in corner cases (the carry of a shift by a register holding 0,
/// overflow of ADCS and SBCS when the carry crosses 2^31).
final class CortexM0 {
    static let excNMI = 2, excHardFault = 3, excSVCall = 11, excPendSV = 14, excSysTick = 15
    static let sysmAPSR = 0, sysmIAPSR = 1, sysmEAPSR = 2, sysmXPSR = 3, sysmIPSR = 5, sysmEPSR = 6, sysmIEPSR = 7
    static let sysmMSP = 8, sysmPSP = 9, sysmPRIMASK = 16, sysmCONTROL = 20
    static let lowestPriority = 4
    static let maxHardwareIRQ = 25

    unowned let chip: RP2040

    /// R0-R15 (raw memory rather than an array: the instruction switch reads and writes them all the time)
    let registers: UnsafeMutablePointer<UInt32> = {
        let pointer = UnsafeMutablePointer<UInt32>.allocate(capacity: 16)
        pointer.initialize(repeating: 0, count: 16)
        return pointer
    }()
    var bankedSP: UInt32 = 0xFFFF_FFFC
    var cycles = 0

    var eventRegistered = false
    var waiting = false

    var N = false, C = false, Z = false, V = false
    var PM = false
    /// CONTROL.SPSEL: the process stack in use in thread mode
    var processStack = false
    var nPRIV = false
    var handlerMode = false
    var IPSR: UInt32 = 0
    var pendingInterrupts: UInt32 = 0
    var enabledInterrupts: UInt32 = 0
    var interruptPriorities: [UInt32] = [0xFFFF_FFFF, 0, 0, 0]
    var pendingNMI = false
    var pendingPendSV = false
    var pendingSVCall = false
    var pendingSystick = false
    var interruptsUpdated = false
    var VTOR: UInt32 = 0
    var SHPR2: UInt32 = 0
    var SHPR3: UInt32 = 0
    /// A BKPT or UDF stopped the program (a crash, or the end of a test)
    var breakpoint: UInt32?

    init(chip: RP2040) {
        self.chip = chip
        registers[13] = 0xFFFF_FFFC
    }

    deinit { registers.deallocate() }

    func reset() {
        SP = chip.readUint32(VTOR)
        PC = chip.readUint32(VTOR + 4) & 0xFFFF_FFFE
        cycles = 0
    }

    var SP: UInt32 {
        get { registers[13] }
        set { registers[13] = newValue & ~0x3 }
    }

    var LR: UInt32 {
        get { registers[14] }
        set { registers[14] = newValue }
    }

    var PC: UInt32 {
        get { registers[15] }
        set { registers[15] = newValue }
    }

    var APSR: UInt32 {
        get { (N ? 0x8000_0000 : 0) | (Z ? 0x4000_0000 : 0) | (C ? 0x2000_0000 : 0) | (V ? 0x1000_0000 : 0) }
        set {
            N = newValue & 0x8000_0000 != 0
            Z = newValue & 0x4000_0000 != 0
            C = newValue & 0x2000_0000 != 0
            V = newValue & 0x1000_0000 != 0
        }
    }

    var xPSR: UInt32 {
        get { APSR | IPSR | (1 << 24) }
        set {
            APSR = newValue
            IPSR = newValue & 0x3F
        }
    }

    func checkCondition(_ condition: Int) -> Bool {
        let result: Bool
        switch condition >> 1 {
        case 0: result = Z
        case 1: result = C
        case 2: result = N
        case 3: result = V
        case 4: result = C && !Z
        case 5: result = N == V
        case 6: result = N == V && !Z
        default: result = true
        }
        return condition & 1 != 0 && condition != 0xF ? !result : result
    }

    // MARK: - Stacks and exceptions

    private func switchStack(toProcess: Bool) {
        if processStack != toProcess {
            let temp = SP
            SP = bankedSP
            bankedSP = temp
            processStack = toProcess
        }
    }

    var SPprocess: UInt32 {
        get { processStack ? SP : bankedSP }
        set { if processStack { SP = newValue } else { bankedSP = newValue } }
    }

    var SPmain: UInt32 {
        get { processStack ? bankedSP : SP }
        set { if processStack { bankedSP = newValue } else { SP = newValue } }
    }

    func exceptionEntry(_ number: Int) {
        var frame: UInt32
        let align: UInt32
        if processStack && !handlerMode {
            align = SPprocess & 0b100 != 0 ? 1 : 0
            SPprocess = (SPprocess &- 0x20) & ~0b100
            frame = SPprocess
        } else {
            align = SPmain & 0b100 != 0 ? 1 : 0
            SPmain = (SPmain &- 0x20) & ~0b100
            frame = SPmain
        }
        chip.writeUint32(frame, registers[0])
        chip.writeUint32(frame &+ 0x4, registers[1])
        chip.writeUint32(frame &+ 0x8, registers[2])
        chip.writeUint32(frame &+ 0xC, registers[3])
        chip.writeUint32(frame &+ 0x10, registers[12])
        chip.writeUint32(frame &+ 0x14, LR)
        chip.writeUint32(frame &+ 0x18, PC & ~1)
        chip.writeUint32(frame &+ 0x1C, (xPSR & ~(1 << 9)) | (align << 9))
        frame = 0
        if handlerMode {
            LR = 0xFFFF_FFF1
        } else {
            LR = processStack ? 0xFFFF_FFFD : 0xFFFF_FFF9
        }
        handlerMode = true
        IPSR = UInt32(number)
        switchStack(toProcess: false)
        eventRegistered = true
        PC = chip.readUint32(VTOR &+ 4 * UInt32(number))
    }

    func exceptionReturn(_ excReturn: UInt32) {
        var frame = SPmain
        switch excReturn & 0xF {
        case 0b0001:
            handlerMode = true
            switchStack(toProcess: false)
        case 0b1001:
            handlerMode = false
            switchStack(toProcess: false)
        case 0b1101:
            frame = SPprocess
            handlerMode = false
            switchStack(toProcess: true)
        default:
            break
        }
        registers[0] = chip.readUint32(frame)
        registers[1] = chip.readUint32(frame &+ 0x4)
        registers[2] = chip.readUint32(frame &+ 0x8)
        registers[3] = chip.readUint32(frame &+ 0xC)
        registers[12] = chip.readUint32(frame &+ 0x10)
        LR = chip.readUint32(frame &+ 0x14)
        PC = chip.readUint32(frame &+ 0x18)
        let psr = chip.readUint32(frame &+ 0x1C)
        let align: UInt32 = psr & (1 << 9) != 0 ? 0b100 : 0
        switch excReturn & 0xF {
        case 0b0001, 0b1001: SPmain = (SPmain &+ 0x20) | align
        case 0b1101: SPprocess = (SPprocess &+ 0x20) | align
        default: break
        }
        APSR = psr & 0xF000_0000
        let forceThread = !handlerMode && nPRIV
        IPSR = forceThread ? 0 : psr & 0x3F
        interruptsUpdated = true
        eventRegistered = true
    }

    var pendSVPriority: Int { Int((SHPR3 >> 22) & 0x3) }
    var svCallPriority: Int { Int(SHPR2 >> 30) }
    var systickPriority: Int { Int(SHPR3 >> 30) }

    func exceptionPriority(_ n: Int) -> Int {
        switch n {
        case 1: return -3
        case CortexM0.excNMI: return -2
        case CortexM0.excHardFault: return -1
        case CortexM0.excSVCall: return svCallPriority
        case CortexM0.excPendSV: return pendSVPriority
        case CortexM0.excSysTick: return systickPriority
        default:
            if n < 16 { return CortexM0.lowestPriority }
            let interrupt = n - 16
            for priority in 0..<4 where interruptPriorities[priority] & (1 << UInt32(interrupt & 31)) != 0 { return priority }
            return CortexM0.lowestPriority
        }
    }

    var vectPending: Int {
        if pendingNMI { return CortexM0.excNMI }
        for priority in 0..<CortexM0.lowestPriority {
            let level = pendingInterrupts & interruptPriorities[priority]
            if pendingSVCall && priority == svCallPriority { return CortexM0.excSVCall }
            if pendingPendSV && priority == pendSVPriority { return CortexM0.excPendSV }
            if pendingSystick && priority == systickPriority { return CortexM0.excSysTick }
            if level != 0 {
                for interrupt in 0..<32 where level & (1 << UInt32(interrupt)) != 0 { return 16 + interrupt }
            }
        }
        return 0
    }

    func setInterrupt(_ irq: Int, _ value: Bool) {
        let bit = UInt32(1) << UInt32(irq)
        if value && pendingInterrupts & bit == 0 {
            pendingInterrupts |= bit
            interruptsUpdated = true
            if waiting && checkForInterrupts() { waiting = false }
        } else if !value {
            pendingInterrupts &= ~bit
        }
    }

    @discardableResult
    func checkForInterrupts() -> Bool {
        let current = waiting
            ? (PM ? exceptionPriority(Int(IPSR)) : CortexM0.lowestPriority)
            : min(exceptionPriority(Int(IPSR)), PM ? 0 : CortexM0.lowestPriority)
        let set = pendingInterrupts & enabledInterrupts
        if pendingNMI {
            pendingNMI = false
            exceptionEntry(CortexM0.excNMI)
            return true
        }
        var priority = 0
        while priority < current {
            let level = set & interruptPriorities[priority]
            if pendingSVCall && priority == svCallPriority {
                pendingSVCall = false
                exceptionEntry(CortexM0.excSVCall)
                return true
            }
            if pendingPendSV && priority == pendSVPriority {
                pendingPendSV = false
                exceptionEntry(CortexM0.excPendSV)
                return true
            }
            if pendingSystick && priority == systickPriority {
                pendingSystick = false
                exceptionEntry(CortexM0.excSysTick)
                return true
            }
            if level != 0 {
                for interrupt in 0..<32 where level & (1 << UInt32(interrupt)) != 0 {
                    if interrupt > CortexM0.maxHardwareIRQ { pendingInterrupts &= ~(1 << UInt32(interrupt)) }
                    exceptionEntry(16 + interrupt)
                    return true
                }
            }
            priority += 1
        }
        interruptsUpdated = false
        return false
    }

    func readSpecialRegister(_ sysm: Int) -> UInt32 {
        switch sysm {
        case CortexM0.sysmAPSR: return APSR
        case CortexM0.sysmXPSR: return xPSR
        case CortexM0.sysmIPSR: return IPSR
        case CortexM0.sysmPRIMASK: return PM ? 1 : 0
        case CortexM0.sysmMSP: return SPmain
        case CortexM0.sysmPSP: return SPprocess
        case CortexM0.sysmCONTROL: return (processStack ? 2 : 0) | (nPRIV ? 1 : 0)
        default: return 0
        }
    }

    func writeSpecialRegister(_ sysm: Int, _ value: UInt32) {
        switch sysm {
        case CortexM0.sysmAPSR: APSR = value
        case CortexM0.sysmXPSR: xPSR = value
        case CortexM0.sysmIPSR: IPSR = value
        case CortexM0.sysmPRIMASK:
            PM = value & 1 != 0
            interruptsUpdated = true
        case CortexM0.sysmMSP: SPmain = value
        case CortexM0.sysmPSP: SPprocess = value
        case CortexM0.sysmCONTROL:
            nPRIV = value & 1 != 0
            if !handlerMode { switchStack(toProcess: value & 2 != 0) }
        default: break
        }
    }

    private func bxWritePC(_ address: UInt32) {
        if handlerMode && address >> 28 == 0b1111 {
            exceptionReturn(address & 0x0FFF_FFFF)
        } else {
            PC = address & ~1
        }
    }

    // MARK: - Flags

    @inline(__always) private func subtract(_ a: UInt32, _ b: UInt32, borrow: UInt32 = 0) -> UInt32 {
        // a - b - borrow, as a + ~b + (1 - borrow)
        let notB = ~b
        let wide = UInt64(a) + UInt64(notB) + UInt64(1 - borrow)
        let result = UInt32(truncatingIfNeeded: wide)
        N = result & 0x8000_0000 != 0
        Z = result == 0
        C = wide > 0xFFFF_FFFF
        let signedWide = Int64(Int32(bitPattern: a)) + Int64(Int32(bitPattern: notB)) + Int64(1 - borrow)
        V = signedWide != Int64(Int32(bitPattern: result))
        return result
    }

    @inline(__always) private func add(_ a: UInt32, _ b: UInt32, carry: UInt32 = 0) -> UInt32 {
        let wide = UInt64(a) + UInt64(b) + UInt64(carry)
        let result = UInt32(truncatingIfNeeded: wide)
        N = result & 0x8000_0000 != 0
        Z = result == 0
        C = wide > 0xFFFF_FFFF
        let signedWide = Int64(Int32(bitPattern: a)) + Int64(Int32(bitPattern: b)) + Int64(carry)
        V = signedWide != Int64(Int32(bitPattern: result))
        return result
    }

    @inline(__always) private func logicFlags(_ result: UInt32) {
        N = result & 0x8000_0000 != 0
        Z = result == 0
    }

    private func cyclesIO(_ address: UInt32, write: Bool = false) -> Int {
        if address >= 0xD000_0000 && address < 0xE000_0000 { return 0 }
        if address >= 0x4000_0000 && address < 0x5000_0000 { return write ? 4 : 3 }
        return 1
    }

    // MARK: - Decoding

    enum Op: UInt8 {
        case unknown, adcs, addSPImmToReg, addSPImm, addsImm3, addsImm8, addsReg, addReg, adr, ands, asrsImm, asrsReg
        case bCond, b, bics, bkpt, blx, bx, cmn, cmpImm, cmpReg, cmpRegHigh, cpsid, cpsie, eors, ldmia, ldrImm
        case ldrSP, ldrLiteral, ldrReg, ldrbImm, ldrbReg, ldrhImm, ldrhReg, ldrsb, ldrsh, lslsImm, lslsReg, lsrsImm
        case lsrsReg, mov, movs, muls, mvns, orrs, pop, push, rev, rev16, revsh, ror, negs, nop, sbcs, sev, stmia
        case strImm, strSP, strReg, strbImm, strbReg, strhImm, strhReg, subSPImm, subsImm3, subsImm8, subsReg, svc
        case sxtb, sxth, tst, udf, uxtb, uxth, wfe, wfi, yield, wide
    }

    /// The 16-bit instruction each halfword is, in rp2040js's order of matching (32-bit ones are `wide`)
    static let decodeTable: UnsafeMutablePointer<Op> = {
        let table = UnsafeMutablePointer<Op>.allocate(capacity: 65_536)
        for opcode in 0..<65_536 { (table + opcode).initialize(to: classify(opcode)) }
        return table
    }()
    /// The table, kept here so each instruction does not go through the static's lazy initialization
    private let decode = CortexM0.decodeTable

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func classify(_ o: Int) -> Op {
        if o >> 12 == 0b1111 || o >> 11 == 0b11101 { return .wide }
        if o >> 6 == 0b0100000101 { return .adcs }
        if o >> 11 == 0b10101 { return .addSPImmToReg }
        if o >> 7 == 0b101100000 { return .addSPImm }
        if o >> 9 == 0b0001110 { return .addsImm3 }
        if o >> 11 == 0b00110 { return .addsImm8 }
        if o >> 9 == 0b0001100 { return .addsReg }
        if o >> 8 == 0b01000100 { return .addReg }
        if o >> 11 == 0b10100 { return .adr }
        if o >> 6 == 0b0100000000 { return .ands }
        if o >> 11 == 0b00010 { return .asrsImm }
        if o >> 6 == 0b0100000100 { return .asrsReg }
        if o >> 12 == 0b1101 && (o >> 9) & 0x7 != 0b111 { return .bCond }
        if o >> 11 == 0b11100 { return .b }
        if o >> 6 == 0b0100001110 { return .bics }
        if o >> 8 == 0b10111110 { return .bkpt }
        if o >> 7 == 0b010001111 && o & 0x7 == 0 { return .blx }
        if o >> 7 == 0b010001110 && o & 0x7 == 0 { return .bx }
        if o >> 6 == 0b0100001011 { return .cmn }
        if o >> 11 == 0b00101 { return .cmpImm }
        if o >> 6 == 0b0100001010 { return .cmpReg }
        if o >> 8 == 0b01000101 { return .cmpRegHigh }
        if o == 0xB672 { return .cpsid }
        if o == 0xB662 { return .cpsie }
        if o >> 6 == 0b0100000001 { return .eors }
        if o >> 11 == 0b11001 { return .ldmia }
        if o >> 11 == 0b01101 { return .ldrImm }
        if o >> 11 == 0b10011 { return .ldrSP }
        if o >> 11 == 0b01001 { return .ldrLiteral }
        if o >> 9 == 0b0101100 { return .ldrReg }
        if o >> 11 == 0b01111 { return .ldrbImm }
        if o >> 9 == 0b0101110 { return .ldrbReg }
        if o >> 11 == 0b10001 { return .ldrhImm }
        if o >> 9 == 0b0101101 { return .ldrhReg }
        if o >> 9 == 0b0101011 { return .ldrsb }
        if o >> 9 == 0b0101111 { return .ldrsh }
        if o >> 11 == 0b00000 { return .lslsImm }
        if o >> 6 == 0b0100000010 { return .lslsReg }
        if o >> 11 == 0b00001 { return .lsrsImm }
        if o >> 6 == 0b0100000011 { return .lsrsReg }
        if o >> 8 == 0b01000110 { return .mov }
        if o >> 11 == 0b00100 { return .movs }
        if o >> 6 == 0b0100001101 { return .muls }
        if o >> 6 == 0b0100001111 { return .mvns }
        if o >> 6 == 0b0100001100 { return .orrs }
        if o >> 9 == 0b1011110 { return .pop }
        if o >> 9 == 0b1011010 { return .push }
        if o >> 6 == 0b1011101000 { return .rev }
        if o >> 6 == 0b1011101001 { return .rev16 }
        if o >> 6 == 0b1011101011 { return .revsh }
        if o >> 6 == 0b0100000111 { return .ror }
        if o >> 6 == 0b0100001001 { return .negs }
        if o == 0b1011111100000000 { return .nop }
        if o >> 6 == 0b0100000110 { return .sbcs }
        if o == 0b1011111101000000 { return .sev }
        if o >> 11 == 0b11000 { return .stmia }
        if o >> 11 == 0b01100 { return .strImm }
        if o >> 11 == 0b10010 { return .strSP }
        if o >> 9 == 0b0101000 { return .strReg }
        if o >> 11 == 0b01110 { return .strbImm }
        if o >> 9 == 0b0101010 { return .strbReg }
        if o >> 11 == 0b10000 { return .strhImm }
        if o >> 9 == 0b0101001 { return .strhReg }
        if o >> 7 == 0b101100001 { return .subSPImm }
        if o >> 9 == 0b0001111 { return .subsImm3 }
        if o >> 11 == 0b00111 { return .subsImm8 }
        if o >> 9 == 0b0001101 { return .subsReg }
        if o >> 8 == 0b11011111 { return .svc }
        if o >> 6 == 0b1011001001 { return .sxtb }
        if o >> 6 == 0b1011001000 { return .sxth }
        if o >> 6 == 0b0100001000 { return .tst }
        if o >> 8 == 0b11011110 { return .udf }
        if o >> 6 == 0b1011001011 { return .uxtb }
        if o >> 6 == 0b1011001010 { return .uxth }
        if o == 0b1011111100100000 { return .wfe }
        if o == 0b1011111100110000 { return .wfi }
        if o == 0b1011111100010000 { return .yield }
        return .unknown
    }

    @inline(__always) private func signExtend8(_ value: UInt32) -> UInt32 { UInt32(bitPattern: Int32(Int8(truncatingIfNeeded: value))) }
    @inline(__always) private func signExtend16(_ value: UInt32) -> UInt32 { UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: value))) }

    // MARK: - Execution

    /// Runs one instruction (entering a pending exception first); returns its cycles
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func executeInstruction() -> Int {
        if interruptsUpdated && checkForInterrupts() { waiting = false }
        let opcodePC = PC & ~1
        let opcode = Int(chip.readUint16(opcodePC))
        var delta = 1
        let file = registers
        @inline(__always) func r(_ index: Int) -> UInt32 { file[index] }
        PC = PC &+ 2
        switch decode[opcode] {
        case .adcs:
            let rm = (opcode >> 3) & 7, rdn = opcode & 7
            registers[rdn] = add(r(rm), r(rdn), carry: C ? 1 : 0)
        case .addSPImmToReg:
            registers[(opcode >> 8) & 7] = SP &+ UInt32((opcode & 0xFF) << 2)
        case .addSPImm:
            SP = SP &+ UInt32((opcode & 0x7F) << 2)
        case .addsImm3:
            registers[opcode & 7] = add(r((opcode >> 3) & 7), UInt32((opcode >> 6) & 7))
        case .addsImm8:
            let rdn = (opcode >> 8) & 7
            registers[rdn] = add(r(rdn), UInt32(opcode & 0xFF))
        case .addsReg:
            registers[opcode & 7] = add(r((opcode >> 3) & 7), r((opcode >> 6) & 7))
        case .addReg:
            let rm = (opcode >> 3) & 0xF
            let rdn = ((opcode & 0x80) >> 4) | (opcode & 7)
            let left = rdn == 15 ? PC &+ 2 : r(rdn)
            let right = rm == 15 ? PC &+ 2 : r(rm)
            let result = left &+ right
            if rdn == 15 {
                registers[15] = result & ~1
                delta += 1
            } else if rdn == 13 {
                registers[13] = result & ~3
            } else {
                registers[rdn] = result
            }
        case .adr:
            registers[(opcode >> 8) & 7] = (opcodePC & 0xFFFF_FFFC) &+ 4 &+ UInt32((opcode & 0xFF) << 2)
        case .ands:
            let rdn = opcode & 7
            let result = r(rdn) & r((opcode >> 3) & 7)
            registers[rdn] = result
            logicFlags(result)
        case .asrsImm:
            let imm5 = (opcode >> 6) & 0x1F
            let input = r((opcode >> 3) & 7)
            let shift = imm5 == 0 ? 32 : imm5
            let result = shift < 32 ? UInt32(bitPattern: Int32(bitPattern: input) >> Int32(shift))
                : (input & 0x8000_0000 != 0 ? 0xFFFF_FFFF : 0)
            registers[opcode & 7] = result
            logicFlags(result)
            C = (Int64(Int32(bitPattern: input)) >> Int64(shift - 1)) & 1 != 0
        case .asrsReg:
            let rdn = opcode & 7
            let input = r(rdn)
            let amount = Int(r((opcode >> 3) & 7) & 0xFF)
            if amount == 0 {
                logicFlags(input)
            } else {
                let shift = min(amount, 32)
                let result = shift < 32 ? UInt32(bitPattern: Int32(bitPattern: input) >> Int32(shift))
                    : (input & 0x8000_0000 != 0 ? 0xFFFF_FFFF : 0)
                registers[rdn] = result
                logicFlags(result)
                C = (Int64(Int32(bitPattern: input)) >> Int64(shift - 1)) & 1 != 0
            }
        case .bCond:
            var imm = (opcode & 0xFF) << 1
            if imm & (1 << 8) != 0 { imm = (imm & 0x1FF) - 0x200 }
            if checkCondition((opcode >> 8) & 0xF) {
                PC = PC &+ UInt32(bitPattern: Int32(imm + 2))
                delta += 1
            }
        case .b:
            var imm = (opcode & 0x7FF) << 1
            if imm & (1 << 11) != 0 { imm = (imm & 0x7FF) - 0x800 }
            PC = PC &+ UInt32(bitPattern: Int32(imm + 2))
            delta += 1
        case .bics:
            let rdn = opcode & 7
            let result = r(rdn) & ~r((opcode >> 3) & 7)
            registers[rdn] = result
            logicFlags(result)
        case .bkpt:
            breakpoint = UInt32(opcode & 0xFF)
        case .blx:
            let rm = (opcode >> 3) & 0xF
            let target = r(rm)
            LR = PC | 1
            PC = target & ~1
            delta += 1
        case .bx:
            bxWritePC(r((opcode >> 3) & 0xF))
            delta += 1
        case .cmn:
            _ = add(r(opcode & 7), r((opcode >> 3) & 7))
        case .cmpImm:
            _ = subtract(r((opcode >> 8) & 7), UInt32(opcode & 0xFF))
        case .cmpReg:
            _ = subtract(r(opcode & 7), r((opcode >> 3) & 7))
        case .cmpRegHigh:
            let rm = (opcode >> 3) & 0xF
            let rn = ((opcode >> 4) & 0x8) | (opcode & 7)
            _ = subtract(r(rn), r(rm))
        case .cpsid:
            PM = true
        case .cpsie:
            PM = false
            interruptsUpdated = true
        case .eors:
            let rdn = opcode & 7
            let result = r((opcode >> 3) & 7) ^ r(rdn)
            registers[rdn] = result
            logicFlags(result)
        case .ldmia:
            let rn = (opcode >> 8) & 7
            let list = opcode & 0xFF
            var address = r(rn)
            for i in 0..<8 where list & (1 << i) != 0 {
                registers[i] = chip.readUint32(address)
                address = address &+ 4
                delta += 1
            }
            if list & (1 << rn) == 0 { registers[rn] = address }
        case .ldrImm:
            let address = r((opcode >> 3) & 7) &+ UInt32(((opcode >> 6) & 0x1F) << 2)
            delta += cyclesIO(address)
            registers[opcode & 7] = chip.readUint32(address)
        case .ldrSP:
            let address = SP &+ UInt32((opcode & 0xFF) << 2)
            delta += cyclesIO(address)
            registers[(opcode >> 8) & 7] = chip.readUint32(address)
        case .ldrLiteral:
            let address = ((PC &+ 2) & 0xFFFF_FFFC) &+ UInt32((opcode & 0xFF) << 2)
            delta += cyclesIO(address)
            registers[(opcode >> 8) & 7] = chip.readUint32(address)
        case .ldrReg:
            let address = r((opcode >> 6) & 7) &+ r((opcode >> 3) & 7)
            delta += cyclesIO(address)
            registers[opcode & 7] = chip.readUint32(address)
        case .ldrbImm:
            let address = r((opcode >> 3) & 7) &+ UInt32((opcode >> 6) & 0x1F)
            delta += cyclesIO(address)
            registers[opcode & 7] = UInt32(chip.readUint8(address))
        case .ldrbReg:
            let address = r((opcode >> 6) & 7) &+ r((opcode >> 3) & 7)
            delta += cyclesIO(address)
            registers[opcode & 7] = UInt32(chip.readUint8(address))
        case .ldrhImm:
            let address = r((opcode >> 3) & 7) &+ UInt32(((opcode >> 6) & 0x1F) << 1)
            delta += cyclesIO(address)
            registers[opcode & 7] = UInt32(chip.readUint16(address))
        case .ldrhReg:
            let address = r((opcode >> 6) & 7) &+ r((opcode >> 3) & 7)
            delta += cyclesIO(address)
            registers[opcode & 7] = UInt32(chip.readUint16(address))
        case .ldrsb:
            let address = r((opcode >> 6) & 7) &+ r((opcode >> 3) & 7)
            delta += cyclesIO(address)
            registers[opcode & 7] = signExtend8(UInt32(chip.readUint8(address)))
        case .ldrsh:
            let address = r((opcode >> 6) & 7) &+ r((opcode >> 3) & 7)
            delta += cyclesIO(address)
            registers[opcode & 7] = signExtend16(UInt32(chip.readUint16(address)))
        case .lslsImm:
            let imm5 = (opcode >> 6) & 0x1F
            let input = r((opcode >> 3) & 7)
            let result = input << UInt32(imm5)
            registers[opcode & 7] = result
            logicFlags(result)
            if imm5 != 0 { C = (input >> UInt32(32 - imm5)) & 1 != 0 }
        case .lslsReg:
            let rdn = opcode & 7
            let input = r(rdn)
            let shift = Int(r((opcode >> 3) & 7) & 0xFF)
            let result = shift >= 32 ? 0 : input << UInt32(shift)
            registers[rdn] = result
            logicFlags(result)
            if shift != 0 { C = shift <= 32 ? (input >> UInt32(32 - shift)) & 1 != 0 : false }
        case .lsrsImm:
            let imm5 = (opcode >> 6) & 0x1F
            let input = r((opcode >> 3) & 7)
            let result = imm5 != 0 ? input >> UInt32(imm5) : 0
            registers[opcode & 7] = result
            logicFlags(result)
            C = (input >> UInt32(imm5 != 0 ? imm5 - 1 : 31)) & 1 != 0
        case .lsrsReg:
            let rdn = opcode & 7
            let shift = Int(r((opcode >> 3) & 7) & 0xFF)
            let input = r(rdn)
            let result = shift < 32 ? input >> UInt32(shift) : 0
            registers[rdn] = result
            logicFlags(result)
            if shift != 0 { C = shift <= 32 ? (input >> UInt32(shift - 1)) & 1 != 0 : false }
        case .mov:
            let rm = (opcode >> 3) & 0xF
            let rd = ((opcode >> 4) & 0x8) | (opcode & 7)
            var value = rm == 15 ? PC &+ 2 : r(rm)
            if rd == 15 {
                delta += 1
                value &= ~1
            } else if rd == 13 {
                value &= ~3
            }
            registers[rd] = value
        case .movs:
            let value = UInt32(opcode & 0xFF)
            registers[(opcode >> 8) & 7] = value
            logicFlags(value)
        case .muls:
            let rdm = opcode & 7
            let result = r((opcode >> 3) & 7) &* r(rdm)
            registers[rdm] = result
            logicFlags(result)
        case .mvns:
            let result = ~r((opcode >> 3) & 7)
            registers[opcode & 7] = result
            logicFlags(result)
        case .orrs:
            let rdn = opcode & 7
            let result = r(rdn) | r((opcode >> 3) & 7)
            registers[rdn] = result
            logicFlags(result)
        case .pop:
            var address = SP
            for i in 0...7 where opcode & (1 << i) != 0 {
                registers[i] = chip.readUint32(address)
                address = address &+ 4
                delta += 1
            }
            if (opcode >> 8) & 1 != 0 {
                SP = address &+ 4
                bxWritePC(chip.readUint32(address))
                delta += 2
            } else {
                SP = address
            }
        case .push:
            var count: UInt32 = 0
            for i in 0...8 where opcode & (1 << i) != 0 { count += 1 }
            var address = SP &- 4 * count
            for i in 0...7 where opcode & (1 << i) != 0 {
                chip.writeUint32(address, registers[i])
                delta += 1
                address = address &+ 4
            }
            if opcode & (1 << 8) != 0 { chip.writeUint32(address, registers[14]) }
            SP = SP &- 4 * count
        case .rev:
            registers[opcode & 7] = r((opcode >> 3) & 7).byteSwapped
        case .rev16:
            let input = r((opcode >> 3) & 7)
            registers[opcode & 7] = ((input >> 16) & 0xFF) << 24 | ((input >> 24) & 0xFF) << 16 | (input & 0xFF) << 8
                | ((input >> 8) & 0xFF)
        case .revsh:
            let input = r((opcode >> 3) & 7)
            registers[opcode & 7] = signExtend16(((input & 0xFF) << 8) | ((input >> 8) & 0xFF))
        case .ror:
            let rdn = opcode & 7
            let input = r(rdn)
            let amount = r((opcode >> 3) & 7) & 0xFF
            let shift = amount % 32
            let result = (input >> shift) | (input << ((32 - shift) & 31))
            let rotated = shift == 0 ? input : result
            registers[rdn] = rotated
            logicFlags(rotated)
            if amount != 0 { C = rotated & 0x8000_0000 != 0 }
        case .negs:
            registers[opcode & 7] = subtract(0, r((opcode >> 3) & 7))
        case .nop, .sev, .yield:
            break
        case .sbcs:
            let rdn = opcode & 7
            registers[rdn] = subtract(r(rdn), r((opcode >> 3) & 7), borrow: C ? 0 : 1)
        case .stmia:
            let rn = (opcode >> 8) & 7
            let list = opcode & 0xFF
            var address = r(rn)
            for i in 0..<8 where list & (1 << i) != 0 {
                chip.writeUint32(address, registers[i])
                address = address &+ 4
                delta += 1
            }
            if list & (1 << rn) == 0 { registers[rn] = address }
        case .strImm:
            let address = r((opcode >> 3) & 7) &+ UInt32(((opcode >> 6) & 0x1F) << 2)
            delta += cyclesIO(address, write: true)
            chip.writeUint32(address, r(opcode & 7))
        case .strSP:
            let address = SP &+ UInt32((opcode & 0xFF) << 2)
            delta += cyclesIO(address, write: true)
            chip.writeUint32(address, r((opcode >> 8) & 7))
        case .strReg:
            let address = r((opcode >> 6) & 7) &+ r((opcode >> 3) & 7)
            delta += cyclesIO(address, write: true)
            chip.writeUint32(address, r(opcode & 7))
        case .strbImm:
            let address = r((opcode >> 3) & 7) &+ UInt32((opcode >> 6) & 0x1F)
            delta += cyclesIO(address, write: true)
            chip.writeUint8(address, UInt8(truncatingIfNeeded: r(opcode & 7)))
        case .strbReg:
            let address = r((opcode >> 6) & 7) &+ r((opcode >> 3) & 7)
            delta += cyclesIO(address, write: true)
            chip.writeUint8(address, UInt8(truncatingIfNeeded: r(opcode & 7)))
        case .strhImm:
            let address = r((opcode >> 3) & 7) &+ UInt32(((opcode >> 6) & 0x1F) << 1)
            delta += cyclesIO(address, write: true)
            chip.writeUint16(address, UInt16(truncatingIfNeeded: r(opcode & 7)))
        case .strhReg:
            let address = r((opcode >> 6) & 7) &+ r((opcode >> 3) & 7)
            delta += cyclesIO(address, write: true)
            chip.writeUint16(address, UInt16(truncatingIfNeeded: r(opcode & 7)))
        case .subSPImm:
            SP = SP &- UInt32((opcode & 0x7F) << 2)
        case .subsImm3:
            registers[opcode & 7] = subtract(r((opcode >> 3) & 7), UInt32((opcode >> 6) & 7))
        case .subsImm8:
            let rdn = (opcode >> 8) & 7
            registers[rdn] = subtract(r(rdn), UInt32(opcode & 0xFF))
        case .subsReg:
            registers[opcode & 7] = subtract(r((opcode >> 3) & 7), r((opcode >> 6) & 7))
        case .svc:
            pendingSVCall = true
            interruptsUpdated = true
        case .sxtb:
            registers[opcode & 7] = signExtend8(r((opcode >> 3) & 7))
        case .sxth:
            registers[opcode & 7] = signExtend16(r((opcode >> 3) & 7))
        case .tst:
            logicFlags(r(opcode & 7) & r((opcode >> 3) & 7))
        case .udf:
            breakpoint = UInt32(opcode & 0xFF)
        case .uxtb:
            registers[opcode & 7] = r((opcode >> 3) & 7) & 0xFF
        case .uxth:
            registers[opcode & 7] = r((opcode >> 3) & 7) & 0xFFFF
        case .wfe:
            delta += 1
            if eventRegistered { eventRegistered = false } else { waiting = true }
        case .wfi:
            delta += 1
            waiting = true
        case .wide:
            delta = executeWide(opcode, Int(chip.readUint16(opcodePC &+ 2)))
        case .unknown:
            break
        }
        cycles += delta
        return delta
    }

    /// 32-bit instructions: BL, the barriers, MRS, MSR and UDF
    private func executeWide(_ opcode: Int, _ opcode2: Int) -> Int {
        var delta = 1
        if opcode >> 11 == 0b11110 && opcode2 >> 14 == 0b11 && (opcode2 >> 12) & 1 == 1 {  // BL
            let imm11 = opcode2 & 0x7FF
            let j2 = (opcode2 >> 11) & 1
            let j1 = (opcode2 >> 13) & 1
            let imm10 = opcode & 0x3FF
            let s = (opcode >> 10) & 1
            let i1 = 1 - (s ^ j1)
            let i2 = 1 - (s ^ j2)
            let imm32 = Int32(bitPattern: UInt32((s != 0 ? 0xFF : 0) << 24 | i1 << 23 | i2 << 22 | imm10 << 12 | imm11 << 1))
            LR = (PC &+ 2) | 1
            PC = PC &+ 2 &+ UInt32(bitPattern: imm32)
            delta += 2
        } else if opcode == 0xF3BF && opcode2 & 0xFFF0 == 0x8F50 {  // DMB
            PC = PC &+ 2
            delta += 2
        } else if opcode == 0xF3BF && opcode2 & 0xFFF0 == 0x8F40 {  // DSB
            PC = PC &+ 2
            delta += 2
        } else if opcode == 0xF3BF && opcode2 & 0xFFF0 == 0x8F60 {  // ISB
            PC = PC &+ 2
            delta += 2
        } else if opcode == 0b1111001111101111 && opcode2 >> 12 == 0b1000 {  // MRS
            registers[(opcode2 >> 8) & 0xF] = readSpecialRegister(opcode2 & 0xFF)
            PC = PC &+ 2
            delta += 2
        } else if opcode >> 4 == 0b111100111000 && opcode2 >> 8 == 0b10001000 {  // MSR
            writeSpecialRegister(opcode2 & 0xFF, registers[opcode & 0xF])
            PC = PC &+ 2
            delta += 2
        } else if opcode >> 4 == 0b111101111111 && opcode2 >> 12 == 0b1010 {  // UDF (T2)
            breakpoint = UInt32(((opcode & 0xF) << 12) | (opcode2 & 0xFFF))
            PC = PC &+ 2
        }
        return delta
    }
}
