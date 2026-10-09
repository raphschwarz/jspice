import Foundation

/// What a GPIO pin does: rp2040js's GPIOPinState
enum RPPinState: Int {
    case low, high, input, inputPullUp, inputPullDown, inputBusKeeper
}

/// A GPIO pin: its function select and overrides, its pad, its interrupt state, and the level the circuit gives it
final class RPGPIOPin {
    static let functionSPI: UInt32 = 1, functionI2C: UInt32 = 3
    static let functionPWM: UInt32 = 4, functionSIO: UInt32 = 5, functionPIO0: UInt32 = 6, functionPIO1: UInt32 = 7
    static let irqEdgeHigh: UInt32 = 1 << 3, irqEdgeLow: UInt32 = 1 << 2, irqLevelHigh: UInt32 = 1 << 1, irqLevelLow: UInt32 = 1

    unowned(unsafe) let chip: RP2040
    let index: Int
    let qspi: Bool
    private var rawInputValue = false
    // rp2040js works this out before the pin's registers are set, so it starts as a plain input
    private var lastValue: RPPinState = .input
    var ctrl: UInt32 = 0x1F
    var padValue: UInt32 = 0b0110110
    var irqEnableMask: UInt32 = 0
    var irqForceMask: UInt32 = 0
    var irqStatus: UInt32 = 0
    /// Called when the pin's state changes
    var onChange: ((RPPinState) -> Void)?

    init(chip: RP2040, index: Int, qspi: Bool = false) {
        self.chip = chip
        self.index = index
        self.qspi = qspi
    }

    /// Which SPI or I²C instance a GPIO goes to, and as which of its signals
    static func peripheral(_ function: UInt32, _ index: Int) -> (instance: Int, role: Int) {
        function == functionSPI ? ((index >> 3) & 1, index & 3) : ((index >> 1) & 1, index & 1)
    }

    private func applyOverride(_ value: Bool, _ type: UInt32) -> Bool {
        switch type {
        case 1: return !value
        case 2: return false
        case 3: return true
        default: return value
        }
    }

    var rawInterrupt: Bool { (irqStatus & irqEnableMask) | irqForceMask != 0 }
    var pullDownEnabled: Bool { padValue & 4 != 0 }
    var pullUpEnabled: Bool { padValue & 8 != 0 }
    var inputEnable: Bool { padValue & 0x40 != 0 }
    var functionSelect: UInt32 { ctrl & 0x1F }

    var rawOutputEnable: Bool {
        let bit = UInt32(1) << UInt32(index)
        switch functionSelect {
        case RPGPIOPin.functionSPI:
            let (instance, role) = RPGPIOPin.peripheral(RPGPIOPin.functionSPI, index)
            return chip.spi[instance].drives(role: role)
        case RPGPIOPin.functionI2C:
            // open drain: driven only to pull the line low
            let (instance, role) = RPGPIOPin.peripheral(RPGPIOPin.functionI2C, index)
            return chip.i2c[instance].pullsLow(role: role)
        case RPGPIOPin.functionPWM: return chip.pwm.gpioDirection & bit != 0
        case RPGPIOPin.functionSIO: return chip.sio.gpioOutputEnable & bit != 0
        case RPGPIOPin.functionPIO0: return chip.pio[0].pinDirections & bit != 0
        case RPGPIOPin.functionPIO1: return chip.pio[1].pinDirections & bit != 0
        default: return false
        }
    }

    var rawOutputValue: Bool {
        let bit = UInt32(1) << UInt32(index)
        switch functionSelect {
        case RPGPIOPin.functionSPI:
            let (instance, role) = RPGPIOPin.peripheral(RPGPIOPin.functionSPI, index)
            return chip.spi[instance].level(role: role)
        case RPGPIOPin.functionPWM: return chip.pwm.gpioValue & bit != 0
        case RPGPIOPin.functionSIO: return chip.sio.gpioValue & bit != 0
        case RPGPIOPin.functionPIO0: return chip.pio[0].pinValues & bit != 0
        case RPGPIOPin.functionPIO1: return chip.pio[1].pinValues & bit != 0
        default: return false
        }
    }

    var inputValue: Bool { applyOverride(rawInputValue && inputEnable, (ctrl >> 16) & 0x3) }
    var irqValue: Bool { applyOverride(rawInterrupt, (ctrl >> 28) & 0x3) }
    var outputEnable: Bool { applyOverride(rawOutputEnable, (ctrl >> 12) & 0x3) }
    var outputValue: Bool { applyOverride(rawOutputValue, (ctrl >> 8) & 0x3) }

    /// The STATUS register
    var status: UInt32 {
        (irqValue ? 1 << 26 : 0) | (rawInterrupt ? 1 << 24 : 0) | (inputValue ? 1 << 19 : 0) | (rawInputValue ? 1 << 17 : 0)
            | (outputEnable ? 1 << 13 : 0) | (rawOutputEnable ? 1 << 12 : 0) | (outputValue ? 1 << 9 : 0)
            | (rawOutputValue ? 1 << 8 : 0)
    }

    var value: RPPinState {
        if outputEnable { return outputValue ? .high : .low }
        if pullDownEnabled && pullUpEnabled { return .inputBusKeeper }
        if pullDownEnabled { return .inputPullDown }
        if pullUpEnabled { return .inputPullUp }
        return .input
    }

    var level: Bool { rawInputValue }

    func setInputValue(_ value: Bool) {
        rawInputValue = value
        let previous = irqValue
        if value && inputEnable {
            irqStatus |= RPGPIOPin.irqEdgeHigh | RPGPIOPin.irqLevelHigh
            irqStatus &= ~RPGPIOPin.irqLevelLow
        } else {
            irqStatus |= RPGPIOPin.irqEdgeLow | RPGPIOPin.irqLevelLow
            irqStatus &= ~RPGPIOPin.irqLevelHigh
        }
        if irqValue != previous { chip.updateIOInterrupt() }
        if functionSelect == RPGPIOPin.functionPWM { chip.pwm.gpioOnInput(index) }
        for pio in chip.pio {
            for machine in pio.machines where machine.enabled && machine.waiting && machine.waitType == .pin
                && machine.waitIndex == index {
                machine.checkWait()
                pio.nextDue = 0
            }
        }
    }

    func checkForUpdates() {
        let current = value
        if current != lastValue {
            lastValue = current
            onChange?(current)
        }
    }

    func refreshInput() { setInputValue(rawInputValue) }

    func updateIRQValue(_ value: UInt32) {
        if value & RPGPIOPin.irqEdgeLow != 0 && irqStatus & RPGPIOPin.irqEdgeLow != 0 {
            irqStatus &= ~RPGPIOPin.irqEdgeLow
            chip.updateIOInterrupt()
        }
        if value & RPGPIOPin.irqEdgeHigh != 0 && irqStatus & RPGPIOPin.irqEdgeHigh != 0 {
            irqStatus &= ~RPGPIOPin.irqEdgeHigh
            chip.updateIOInterrupt()
        }
    }
}

/// One of the two interpolators of the SIO block
final class RPInterpolator {
    private struct Config {
        var shift = 0, maskLSB = 0, maskMSB = 0
        var signed = false, crossInput = false, crossResult = false, addRaw = false
        var forceMSB = 0
        var blend = false, clamp = false, overf0 = false, overf1 = false, overf = false

        init(_ value: UInt32) {
            shift = Int(value & 0x1F)
            maskLSB = Int((value >> 5) & 0x1F)
            maskMSB = Int((value >> 10) & 0x1F)
            signed = (value >> 15) & 1 != 0
            crossInput = (value >> 16) & 1 != 0
            crossResult = (value >> 17) & 1 != 0
            addRaw = (value >> 18) & 1 != 0
            forceMSB = Int((value >> 19) & 0x3)
            blend = (value >> 21) & 1 != 0
            clamp = (value >> 22) & 1 != 0
            overf0 = (value >> 23) & 1 != 0
            overf1 = (value >> 24) & 1 != 0
            overf = (value >> 25) & 1 != 0
        }

        var value: UInt32 {
            func bit(_ flag: Bool, _ at: UInt32) -> UInt32 { flag ? 1 << at : 0 }
            return UInt32(shift & 0x1F) | UInt32(maskLSB & 0x1F) << 5 | UInt32(maskMSB & 0x1F) << 10 | bit(signed, 15)
                | bit(crossInput, 16) | bit(crossResult, 17) | bit(addRaw, 18) | UInt32(forceMSB & 0x3) << 19 | bit(blend, 21)
                | bit(clamp, 22) | bit(overf0, 23) | bit(overf1, 24) | bit(overf, 25)
        }
    }

    private let index: Int
    var accum0: UInt32 = 0, accum1: UInt32 = 0
    var base0: UInt32 = 0, base1: UInt32 = 0, base2: UInt32 = 0
    var ctrl0: UInt32 = 0, ctrl1: UInt32 = 0
    private(set) var result0: UInt32 = 0, result1: UInt32 = 0, result2: UInt32 = 0
    private(set) var smresult0: UInt32 = 0, smresult1: UInt32 = 0

    init(index: Int) {
        self.index = index
        update()
    }

    @inline(__always) private static func s32(_ x: Int64) -> Int64 { Int64(Int32(truncatingIfNeeded: x)) }
    @inline(__always) private static func u32(_ x: Int64) -> Int64 { Int64(UInt32(truncatingIfNeeded: x)) }

    func update() {
        var c0 = Config(ctrl0)
        var c1 = Config(ctrl1)
        let doClamp = c0.clamp && index == 1
        let doBlend = c0.blend && index == 0
        c0.clamp = doClamp
        c0.blend = doBlend
        c1.clamp = false
        c1.blend = false
        c1.overf0 = false
        c1.overf1 = false
        c1.overf = false
        let input0 = UInt32(truncatingIfNeeded: c0.crossInput ? accum1 : accum0)
        let input1 = UInt32(truncatingIfNeeded: c1.crossInput ? accum0 : accum1)
        let msbMask0: UInt32 = c0.maskMSB == 31 ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: (Int64(1) << (c0.maskMSB + 1)) - 1)
        let msbMask1: UInt32 = c1.maskMSB == 31 ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: (Int64(1) << (c1.maskMSB + 1)) - 1)
        let mask0 = msbMask0 & ~UInt32(truncatingIfNeeded: (Int64(1) << c0.maskLSB) - 1)
        let mask1 = msbMask1 & ~UInt32(truncatingIfNeeded: (Int64(1) << c1.maskLSB) - 1)
        let uresult0 = (input0 >> UInt32(c0.shift)) & mask0
        let uresult1 = (input1 >> UInt32(c1.shift)) & mask1
        let overf0 = (input0 >> UInt32(c0.shift)) & ~msbMask0 != 0
        let overf1 = (input1 >> UInt32(c1.shift)) & ~msbMask1 != 0
        let sext0: UInt32 = uresult0 & (1 << UInt32(c0.maskMSB)) != 0 ? 0xFFFF_FFFF << UInt32(c0.maskMSB) : 0
        let sext1: UInt32 = uresult1 & (1 << UInt32(c1.maskMSB)) != 0 ? 0xFFFF_FFFF << UInt32(c1.maskMSB) : 0
        let r0 = Int64(Int32(bitPattern: c0.signed ? uresult0 | sext0 : uresult0))
        let r1 = Int64(Int32(bitPattern: c1.signed ? uresult1 | sext1 : uresult1))
        let result0 = c0.signed ? r0 : Int64(uresult0)
        let result1 = c1.signed ? r1 : Int64(uresult1)
        let s32Input0 = Int64(Int32(bitPattern: input0))
        let s32Input1 = Int64(Int32(bitPattern: input1))
        let add0 = Int64(base0) + (c0.addRaw ? s32Input0 : result0)
        let add1 = Int64(base1) + (c1.addRaw ? s32Input1 : result1)
        let add2 = Int64(base2) + result0 + (doBlend ? 0 : result1)
        let uclamp0: Int64 = RPInterpolator.u32(result0) < Int64(base0) ? Int64(base0)
            : (RPInterpolator.u32(result0) > Int64(base1) ? Int64(base1) : result0)
        let sclamp0: Int64 = RPInterpolator.s32(result0) < RPInterpolator.s32(Int64(base0)) ? Int64(base0)
            : (RPInterpolator.s32(result0) > RPInterpolator.s32(Int64(base1)) ? Int64(base1) : result0)
        let clamp0 = c0.signed ? sclamp0 : uclamp0
        let alpha1 = result1 & 0xFF
        let ublend1 = Int64(base0) + RPInterpolator.s32(Int64((Double(alpha1 * (Int64(base1) - Int64(base0))) / 256).rounded(.down)))
        let sblend1 = RPInterpolator.s32(Int64(base0))
            + RPInterpolator.s32(Int64((Double(alpha1 * (RPInterpolator.s32(Int64(base1)) - RPInterpolator.s32(Int64(base0)))) / 256).rounded(.down)))
        let blend1 = c1.signed ? sblend1 : ublend1
        smresult0 = UInt32(truncatingIfNeeded: result0)
        smresult1 = UInt32(truncatingIfNeeded: result1)
        let force = Int64(c0.forceMSB) << 28
        self.result0 = UInt32(truncatingIfNeeded: doBlend ? alpha1 : ((doClamp ? clamp0 : add0) | force))
        self.result1 = UInt32(truncatingIfNeeded: (doBlend ? blend1 : add1) | force)
        self.result2 = UInt32(truncatingIfNeeded: add2)
        c0.overf0 = overf0
        c0.overf1 = overf1
        c0.overf = overf0 || overf1
        ctrl0 = c0.value
        ctrl1 = c1.value
    }

    func writeback() {
        let c0 = Config(ctrl0)
        let c1 = Config(ctrl1)
        accum0 = c0.crossResult ? result1 : result0
        accum1 = c1.crossResult ? result0 : result1
        update()
    }

    func setBase01(_ value: UInt32) {
        let c0 = Config(ctrl0)
        let c1 = Config(ctrl1)
        let doBlend = c0.blend && index == 0
        let input0 = value & 0xFFFF
        let input1 = (value >> 16) & 0xFFFF
        let sext0: UInt32 = input0 & (1 << 15) != 0 ? 0xFFFF_8000 : 0
        let sext1: UInt32 = input1 & (1 << 15) != 0 ? 0xFFFF_8000 : 0
        base0 = (doBlend ? c1.signed : c0.signed) ? input0 | sext0 : input0
        base1 = c1.signed ? input1 | sext1 : input1
        update()
    }
}

/// The single-cycle IO block: GPIO output and output enable, the hardware divider, the spinlocks and the interpolators
final class RPSIO {
    unowned(unsafe) let chip: RP2040
    var gpioValue: UInt32 = 0
    var gpioOutputEnable: UInt32 = 0
    var qspiGpioValue: UInt32 = 0
    var qspiGpioOutputEnable: UInt32 = 0
    private var divDividend: UInt32 = 0
    private var divDivisor: UInt32 = 1
    private var divQuotient: UInt32 = 0
    private var divRemainder: UInt32 = 0
    private var divCSR: UInt32 = 0
    private var spinLock: UInt32 = 0
    let interp0 = RPInterpolator(index: 0)
    let interp1 = RPInterpolator(index: 1)

    init(chip: RP2040) { self.chip = chip }

    private func updateDivider(signed: Bool) {
        if divDivisor == 0 {
            divQuotient = divDividend > 0 ? 0xFFFF_FFFF : 1
            divRemainder = divDividend
        } else if signed {
            let dividend = Int64(Int32(bitPattern: divDividend))
            let divisor = Int64(Int32(bitPattern: divDivisor))
            divQuotient = UInt32(truncatingIfNeeded: dividend / divisor)
            divRemainder = UInt32(truncatingIfNeeded: dividend % divisor)
        } else {
            divQuotient = divDividend / divDivisor
            divRemainder = divDividend % divDivisor
        }
        divCSR = 0b11
        chip.core.cycles += 8
    }

    private func interpolator(_ offset: UInt32) -> RPInterpolator { offset < 0x0C0 ? interp0 : interp1 }

    func readUint32(_ offset: UInt32) -> UInt32 {
        if offset >= 0x100 && offset <= 0x17C {
            let bit = UInt32(1) << ((offset - 0x100) / 4)
            if spinLock & bit != 0 { return 0 }
            spinLock |= bit
            return bit
        }
        switch offset {
        case 0x004: return chip.gpioValues
        case 0x008:
            var result: UInt32 = 0
            for (index, pin) in chip.qspi.enumerated() where pin.inputValue { result |= 1 << UInt32(index) }
            return result
        case 0x010: return gpioValue
        case 0x020: return gpioOutputEnable
        case 0x030: return qspiGpioValue
        case 0x040: return qspiGpioOutputEnable
        case 0x014, 0x018, 0x01C, 0x024, 0x028, 0x02C, 0x034, 0x038, 0x03C, 0x044, 0x048, 0x04C: return 0
        case 0x000: return 0
        case 0x05C: return spinLock
        case 0x060, 0x068: return divDividend
        case 0x064, 0x06C: return divDivisor
        case 0x070:
            divCSR &= ~0b10
            return divQuotient
        case 0x074: return divRemainder
        case 0x078: return divCSR
        case 0x080...0x0FC:
            let interp = interpolator(offset)
            switch offset & 0x3F {
            case 0x00: return interp.accum0
            case 0x04: return interp.accum1
            case 0x08: return interp.base0
            case 0x0C: return interp.base1
            case 0x10: return interp.base2
            case 0x14:
                let value = interp.result0
                interp.writeback()
                return value
            case 0x18:
                let value = interp.result1
                interp.writeback()
                return value
            case 0x1C:
                let value = interp.result2
                interp.writeback()
                return value
            case 0x20: return interp.result0
            case 0x24: return interp.result1
            case 0x28: return interp.result2
            case 0x2C: return interp.ctrl0
            case 0x30: return interp.ctrl1
            case 0x34: return interp.smresult0
            case 0x38: return interp.smresult1
            default: return 0xFFFF_FFFF
            }
        default:
            return 0xFFFF_FFFF
        }
    }

    func writeUint32(_ offset: UInt32, _ value: UInt32) {
        if offset >= 0x100 && offset <= 0x17C {
            spinLock &= ~(UInt32(1) << ((offset - 0x100) / 4))
            return
        }
        let mask: UInt32 = 0x3FFF_FFFF
        let previousValue = gpioValue
        let previousEnable = gpioOutputEnable
        switch offset {
        case 0x010: gpioValue = value & mask
        case 0x014: gpioValue |= value & mask
        case 0x018: gpioValue &= ~value
        case 0x01C: gpioValue ^= value & mask
        case 0x020: gpioOutputEnable = value & mask
        case 0x024: gpioOutputEnable |= value & mask
        case 0x028: gpioOutputEnable &= ~value
        case 0x02C: gpioOutputEnable ^= value & mask
        case 0x030: qspiGpioValue = value & mask
        case 0x034: qspiGpioValue |= value & mask
        case 0x038: qspiGpioValue &= ~value
        case 0x03C: qspiGpioValue ^= value & mask
        case 0x040: qspiGpioOutputEnable = value & mask
        case 0x044: qspiGpioOutputEnable |= value & mask
        case 0x048: qspiGpioOutputEnable &= ~value
        case 0x04C: qspiGpioOutputEnable ^= value & mask
        case 0x060:
            divDividend = value
            updateDivider(signed: false)
        case 0x068:
            divDividend = value
            updateDivider(signed: true)
        case 0x064:
            divDivisor = value
            updateDivider(signed: false)
        case 0x06C:
            divDivisor = value
            updateDivider(signed: true)
        case 0x070:
            divQuotient = value
            divCSR = 0b11
        case 0x074:
            divRemainder = value
            divCSR = 0b11
        case 0x080...0x0FC:
            let interp = interpolator(offset)
            switch offset & 0x3F {
            case 0x00: interp.accum0 = value
            case 0x04: interp.accum1 = value
            case 0x08: interp.base0 = value
            case 0x0C: interp.base1 = value
            case 0x10: interp.base2 = value
            case 0x2C: interp.ctrl0 = value
            case 0x30: interp.ctrl1 = value
            case 0x34: interp.accum0 = interp.accum0 &+ value
            case 0x38: interp.accum1 = interp.accum1 &+ value
            case 0x3C:
                interp.setBase01(value)
                return
            default: return
            }
            interp.update()
        default:
            break
        }
        let changed = (gpioValue ^ previousValue) | (gpioOutputEnable ^ previousEnable)
        if changed != 0 {
            for (index, pin) in chip.gpio.enumerated() where changed & (1 << UInt32(index)) != 0 { pin.checkForUpdates() }
        }
    }
}
