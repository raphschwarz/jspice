import Foundation

/// The Cortex-M0+'s private peripheral bus: the NVIC, the SysTick timer and the system control block
final class RPPPB: RPPeripheral {
    private static let cpuid: UInt32 = 0xD00, icsr: UInt32 = 0xD04, vtor: UInt32 = 0xD08
    private static let shpr2: UInt32 = 0xD1C, shpr3: UInt32 = 0xD20
    private static let systCSR: UInt32 = 0x010, systRVR: UInt32 = 0x014, systCVR: UInt32 = 0x018, systCalib: UInt32 = 0x01C
    private static let nvicISER: UInt32 = 0x100, nvicICER: UInt32 = 0x180, nvicISPR: UInt32 = 0x200, nvicICPR: UInt32 = 0x280
    private static let nvicIPR0: UInt32 = 0x400, nvicIPR7: UInt32 = 0x41C
    private static let nmiPendSet: UInt32 = 1 << 31, pendSVSet: UInt32 = 1 << 28, pendSVClr: UInt32 = 1 << 27
    private static let pendSTSet: UInt32 = 1 << 26, pendSTClr: UInt32 = 1 << 25, isrPending: UInt32 = 1 << 22

    private var systickCountFlag = false
    private var systickClockSource = false
    private var systickIntEnable = false
    private var systickReload: UInt32 = 0
    let systickTimer: RPTimer32
    private var systickAlarm: RPTimer32PeriodicAlarm!

    override init(chip: RP2040, name: String) {
        systickTimer = RPTimer32(clock: chip.clock, frequency: chip.clkSys)
        super.init(chip: chip, name: name)
        systickAlarm = RPTimer32PeriodicAlarm(timer: systickTimer) { [unowned self] in
            self.systickCountFlag = true
            if self.systickIntEnable {
                self.chip.core.pendingSystick = true
                self.chip.core.interruptsUpdated = true
            }
            self.systickTimer.set(Double(self.systickReload))
        }
        systickTimer.top = 0xFF_FFFF
        systickTimer.mode = .decrement
        systickAlarm.target = 0
        systickAlarm.enable = true
        reset()
    }

    func reset() {
        writeUint32(RPPPB.systCSR, 0)
        writeUint32(RPPPB.systRVR, 0xFF_FFFF)
        systickTimer.set(0xFF_FFFF)
    }

    override func readUint32(_ offset: UInt32) -> UInt32 {
        let core: CortexM0 = chip.core
        switch offset {
        case RPPPB.cpuid:
            return 0x410C_C601
        case RPPPB.icsr:
            let pending = core.pendingInterrupts != 0 || core.pendingPendSV || core.pendingSystick || core.pendingSVCall
            return (core.pendingNMI ? RPPPB.nmiPendSet : 0) | (core.pendingPendSV ? RPPPB.pendSVSet : 0)
                | (core.pendingSystick ? RPPPB.pendSTSet : 0) | (pending ? RPPPB.isrPending : 0)
                | UInt32(truncatingIfNeeded: core.vectPending << 12) | (core.IPSR & 0x1FF)
        case RPPPB.vtor:
            return core.VTOR
        case RPPPB.nvicISPR, RPPPB.nvicICPR:
            return core.pendingInterrupts
        case RPPPB.nvicISER, RPPPB.nvicICER:
            return core.enabledInterrupts
        case RPPPB.nvicIPR0...RPPPB.nvicIPR7 where offset & 3 == 0:
            let regIndex = (offset - RPPPB.nvicIPR0) >> 2
            var result: UInt32 = 0
            for byteIndex in 0..<UInt32(4) {
                let interrupt = regIndex * 4 + byteIndex
                for (priority, mask) in core.interruptPriorities.enumerated() where mask & (1 << interrupt) != 0 {
                    result |= UInt32(priority) << (8 * byteIndex + 6)
                }
            }
            return result
        case RPPPB.shpr2:
            return core.SHPR2
        case RPPPB.shpr3:
            return core.SHPR3
        case RPPPB.systCSR:
            let value = (systickCountFlag ? UInt32(1) << 16 : 0) | (systickClockSource ? 1 << 2 : 0)
                | (systickIntEnable ? 1 << 1 : 0) | (systickTimer.enable ? 1 : 0)
            systickCountFlag = false
            return value
        case RPPPB.systCVR:
            return systickTimer.counter
        case RPPPB.systRVR:
            return systickReload
        case RPPPB.systCalib:
            return 0x0000_270F
        default:
            return super.readUint32(offset)
        }
    }

    override func writeUint32(_ offset: UInt32, _ value: UInt32) {
        let core: CortexM0 = chip.core
        let hardwareInterruptMask = (UInt32(1) << UInt32(CortexM0.maxHardwareIRQ)) - 1
        switch offset {
        case RPPPB.icsr:
            if value & RPPPB.nmiPendSet != 0 {
                core.pendingNMI = true
                core.interruptsUpdated = true
            }
            if value & RPPPB.pendSVSet != 0 {
                core.pendingPendSV = true
                core.interruptsUpdated = true
            }
            if value & RPPPB.pendSVClr != 0 { core.pendingPendSV = false }
            if value & RPPPB.pendSTSet != 0 {
                core.pendingSystick = true
                core.interruptsUpdated = true
            }
            if value & RPPPB.pendSTClr != 0 { core.pendingSystick = false }
        case RPPPB.vtor:
            core.VTOR = value
        case RPPPB.nvicISPR:
            core.pendingInterrupts |= value
            core.interruptsUpdated = true
        case RPPPB.nvicICPR:
            core.pendingInterrupts &= ~value | hardwareInterruptMask
        case RPPPB.nvicISER:
            core.enabledInterrupts |= value
            core.interruptsUpdated = true
        case RPPPB.nvicICER:
            core.enabledInterrupts &= ~value
        case RPPPB.nvicIPR0...RPPPB.nvicIPR7 where offset & 3 == 0:
            let regIndex = (offset - RPPPB.nvicIPR0) >> 2
            for byteIndex in 0..<UInt32(4) {
                let interrupt = regIndex * 4 + byteIndex
                let newPriority = Int((value >> (8 * byteIndex + 6)) & 0x3)
                for priority in core.interruptPriorities.indices { core.interruptPriorities[priority] &= ~(1 << interrupt) }
                core.interruptPriorities[newPriority] |= 1 << interrupt
            }
            core.interruptsUpdated = true
        case RPPPB.shpr2:
            core.SHPR2 = value
        case RPPPB.shpr3:
            core.SHPR3 = value
        case RPPPB.systCSR:
            systickClockSource = value & (1 << 2) != 0
            systickIntEnable = value & (1 << 1) != 0
            systickTimer.enable = value & 1 != 0
        case RPPPB.systCVR:
            systickTimer.set(0)
        case RPPPB.systRVR:
            systickReload = value
        default:
            super.writeUint32(offset, value)
        }
    }
}
