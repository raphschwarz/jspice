import Foundation

/// A memory-mapped block of registers (rp2040js's BasePeripheral): offsets within its 4 KB, and the atomic aliases
/// (XOR, set, clear) at +0x1000, +0x2000, +0x3000 handled by reading and writing back
class RPPeripheral {
    unowned(unsafe) let chip: RP2040
    let name: String
    var rawWriteValue: UInt32 = 0

    init(chip: RP2040, name: String) {
        self.chip = chip
        self.name = name
    }

    func readUint32(_ offset: UInt32) -> UInt32 { 0xFFFF_FFFF }

    func writeUint32(_ offset: UInt32, _ value: UInt32) {}

    func writeUint32Atomic(_ offset: UInt32, _ value: UInt32, _ atomicType: UInt32) {
        rawWriteValue = value
        let newValue: UInt32
        switch atomicType {
        case 1: newValue = readUint32(offset) ^ value
        case 2: newValue = readUint32(offset) | value
        case 3: newValue = readUint32(offset) & ~value
        default: newValue = value
        }
        writeUint32(offset, newValue)
    }
}

/// A block JSpice does not model (reads give all ones, writes are dropped)
final class RPUnimplemented: RPPeripheral {}

final class RPReset: RPPeripheral {
    private var reset: UInt32 = 0
    private var wdsel: UInt32 = 0
    private let resetDone: UInt32 = 0x1FF_FFFF

    override func readUint32(_ offset: UInt32) -> UInt32 {
        switch offset {
        case 0x0: return reset
        case 0x4: return wdsel
        case 0x8: return resetDone
        default: return super.readUint32(offset)
        }
    }

    override func writeUint32(_ offset: UInt32, _ value: UInt32) {
        switch offset {
        case 0x0: reset = value & 0x1FF_FFFF
        case 0x4: wdsel = value & 0x1FF_FFFF
        default: super.writeUint32(offset, value)
        }
    }
}

final class RPPSM: RPPeripheral {
    private static let mask: UInt32 = 0x0001_FFFF
    private var forceOn: UInt32 = 0
    private var forceOff: UInt32 = 0
    private var wdsel: UInt32 = 0

    override func readUint32(_ offset: UInt32) -> UInt32 {
        switch offset {
        case 0x0: return forceOn
        case 0x4: return forceOff
        case 0x8: return wdsel
        case 0xC: return (RPPSM.mask & ~forceOff) | (forceOn & forceOff)
        default: return super.readUint32(offset)
        }
    }

    override func writeUint32(_ offset: UInt32, _ value: UInt32) {
        switch offset {
        case 0x0: forceOn = value & RPPSM.mask
        case 0x4: forceOff = value & RPPSM.mask
        case 0x8: wdsel = value & RPPSM.mask
        default: super.writeUint32(offset, value)
        }
    }
}

/// IO_BANK0: each pin's function select and its interrupts
final class RPIOBank: RPPeripheral {
    private static let lastControl: UInt32 = 0x0EC
    private static let intr0: UInt32 = 0xF0, inte0: UInt32 = 0x100, intf0: UInt32 = 0x110, ints0: UInt32 = 0x120
    private static let ints3: UInt32 = 0x12C

    override func readUint32(_ offset: UInt32) -> UInt32 {
        if offset <= RPIOBank.lastControl {
            return chip.withPin(Int(offset >> 3)) { offset & 0x4 != 0 ? $0.ctrl : $0.status }
        }
        if offset >= RPIOBank.intr0 && offset <= RPIOBank.ints3 {
            let start = Int(offset & 0xF) * 2
            let register = offset & ~0xF
            var result: UInt32 = 0
            for index in stride(from: 7, through: 0, by: -1) {
                guard index + start < chip.gpio.count else { continue }
                let pin = chip.gpio[index + start]
                result <<= 4
                switch register {
                case RPIOBank.intr0: result |= pin.irqStatus
                case RPIOBank.inte0: result |= pin.irqEnableMask
                case RPIOBank.intf0: result |= pin.irqForceMask
                case RPIOBank.ints0: result |= (pin.irqStatus & pin.irqEnableMask) | pin.irqForceMask
                default: break
                }
            }
            return result
        }
        return super.readUint32(offset)
    }

    override func writeUint32(_ offset: UInt32, _ value: UInt32) {
        if offset <= RPIOBank.lastControl {
            if offset & 0x4 != 0 {
                chip.withPin(Int(offset >> 3)) { pin in
                    pin.ctrl = value
                    pin.checkForUpdates()
                }
            }
            return
        }
        if offset >= RPIOBank.intr0 && offset <= RPIOBank.ints3 {
            let start = Int(offset & 0xF) * 2
            let register = offset & ~0xF
            for index in 0..<8 where index + start < chip.gpio.count {
                let pin = chip.gpio[index + start]
                let pinValue = (value >> UInt32(index * 4)) & 0xF
                let rawValue = (rawWriteValue >> UInt32(index * 4)) & 0xF
                switch register {
                case RPIOBank.intr0:
                    pin.updateIRQValue(rawValue)
                case RPIOBank.inte0:
                    if pin.irqEnableMask != pinValue {
                        pin.irqEnableMask = pinValue
                        chip.updateIOInterrupt()
                    }
                case RPIOBank.intf0:
                    if pin.irqForceMask != pinValue {
                        pin.irqForceMask = pinValue
                        chip.updateIOInterrupt()
                    }
                default:
                    break
                }
            }
            return
        }
        super.writeUint32(offset, value)
    }
}

/// PADS_BANK0 and PADS_QSPI: pull-ups and pull-downs, input enable, drive strength
final class RPPads: RPPeripheral {
    private let qspi: Bool
    private var voltageSelect: UInt32 = 0
    private let first: UInt32 = 0x4
    private let last: UInt32

    init(chip: RP2040, name: String, qspi: Bool) {
        self.qspi = qspi
        last = qspi ? 0x18 : 0x78
        super.init(chip: chip, name: name)
    }

    /// Works with the pin of a pad's register (a GPIO pin without counting a reference to it)
    @inline(__always) private func withPin<Result>(_ offset: UInt32, _ body: (RPGPIOPin) -> Result) -> Result {
        let index = Int((offset - first) >> 2)
        return qspi ? body(chip.qspi[index]) : chip.withPin(index, body)
    }

    override func readUint32(_ offset: UInt32) -> UInt32 {
        if offset >= first && offset <= last { return withPin(offset) { $0.padValue } }
        if offset == 0 { return voltageSelect }
        return super.readUint32(offset)
    }

    override func writeUint32(_ offset: UInt32, _ value: UInt32) {
        if offset >= first && offset <= last {
            withPin(offset) { gpio in
                let oldInputEnable = gpio.inputEnable
                gpio.padValue = value
                gpio.checkForUpdates()
                if oldInputEnable != gpio.inputEnable { gpio.refreshInput() }
            }
            return
        }
        if offset == 0 {
            voltageSelect = value & 1
            return
        }
        super.writeUint32(offset, value)
    }
}

final class RPSysInfo: RPPeripheral {
    override func readUint32(_ offset: UInt32) -> UInt32 {
        switch offset {
        case 0x0: return 0x1000_2927
        case 0x4: return 0x0000_0002
        case 0x40: return 0xE0C9_12E8
        default: return super.readUint32(offset)
        }
    }
}

final class RPSysCfg: RPPeripheral {
    override func readUint32(_ offset: UInt32) -> UInt32 {
        offset == 0 ? chip.interruptNMIMask : super.readUint32(offset)
    }

    override func writeUint32(_ offset: UInt32, _ value: UInt32) {
        if offset == 0 { chip.interruptNMIMask = value } else { super.writeUint32(offset, value) }
    }
}

final class RPBusControl: RPPeripheral {
    private var perfSel: [UInt32] = [0x1F, 0x1F, 0x1F, 0x1F]

    override func readUint32(_ offset: UInt32) -> UInt32 {
        switch offset {
        case 0x004: return 1
        case 0x008, 0x010, 0x018, 0x020: return 0
        case 0x00C, 0x014, 0x01C, 0x024: return perfSel[Int(offset - 0x00C) / 8]
        default: return super.readUint32(offset)
        }
    }

    override func writeUint32(_ offset: UInt32, _ value: UInt32) {
        switch offset {
        case 0x008, 0x010, 0x018, 0x020: break
        case 0x00C, 0x014, 0x01C, 0x024: perfSel[Int(offset - 0x00C) / 8] = value & 0x1F
        default: super.writeUint32(offset, value)
        }
    }
}

final class RPTBMAN: RPPeripheral {
    override func readUint32(_ offset: UInt32) -> UInt32 { offset == 0 ? 1 : super.readUint32(offset) }
}

/// The crystal oscillator: stable as soon as it is enabled
final class RPXOSC: RPPeripheral {
    private var ctrl: UInt32 = 0
    private var status: UInt32 = 0
    private var dormant: UInt32 = 0
    private var startup: UInt32 = 0
    private var count: UInt32 = 0
    private var enabled = false
    private var stable = false
    private var isDormant = false

    override func readUint32(_ offset: UInt32) -> UInt32 {
        switch offset {
        case 0x00: return ctrl
        case 0x04: return status | (stable ? 0x8000_0000 : 0) | (enabled ? 0x0000_1000 : 0)
        case 0x08: return dormant
        case 0x0C: return startup
        case 0x1C: return count
        default: return super.readUint32(offset)
        }
    }

    override func writeUint32(_ offset: UInt32, _ value: UInt32) {
        switch offset {
        case 0x00:
            ctrl = value
            let enable = (value & 0x00FF_F000) >> 12
            if enable == 0xFAB {
                if !isDormant {
                    enabled = true
                    stable = true
                }
            } else if enable == 0xD1E {
                enabled = false
                stable = false
            } else if enable != 0 {
                status |= 0x0100_0000
            }
        case 0x04:
            if value & 0x0100_0000 != 0 { status &= ~0x0100_0000 }
        case 0x08:
            if value == 0x636F_6D61 {
                isDormant = true
                stable = false
            } else if value == 0x7761_6B65 {
                isDormant = false
                if enabled { stable = true }
            }
            dormant = value
        case 0x0C:
            startup = value & (0x0010_0000 | 0x0000_3FFF)
        case 0x1C:
            count = value & 0xFF
        default:
            super.writeUint32(offset, value)
        }
    }
}

/// A PLL: always locked; its output frequency follows the dividers
final class RPPLL: RPPeripheral {
    private var cs: UInt32 = 0x1
    private var pwr: UInt32 = 0x2D
    private var fbdivInt: UInt32 = 0
    private var prim: UInt32 = 0x77000

    var frequency: Double {
        let refdiv = cs & 0x3F
        let reference = chip.xoscFrequency / Double(refdiv == 0 ? 1 : refdiv)
        if cs & (1 << 8) != 0 { return reference }
        let post1 = (prim >> 16) & 0x7
        let post2 = (prim >> 12) & 0x7
        let postdiv = Double(post1 == 0 ? 1 : post1) * Double(post2 == 0 ? 1 : post2)
        return reference * Double(fbdivInt & 0xFFF) / postdiv
    }

    override func readUint32(_ offset: UInt32) -> UInt32 {
        switch offset {
        case 0x00: return cs | 0x8000_0000
        case 0x04: return pwr
        case 0x08: return fbdivInt
        case 0x0C: return prim
        default: return super.readUint32(offset)
        }
    }

    override func writeUint32(_ offset: UInt32, _ value: UInt32) {
        switch offset {
        case 0x00: cs = value
        case 0x04: pwr = value
        case 0x08: fbdivInt = value
        case 0x0C: prim = value
        default:
            super.writeUint32(offset, value)
            return
        }
        chip.updateClocks()
    }
}

/// The clock generators: clk_sys and clk_peri follow their sources and dividers
final class RPClocks: RPPeripheral {
    private var gpoutCtrl: [UInt32] = [0, 0, 0, 0]
    private var gpoutDiv: [UInt32] = [0x100, 0x100, 0x100, 0x100]
    private var refCtrl: UInt32 = 0
    private var refDiv: UInt32 = 0x100
    private var periCtrl: UInt32 = 0
    private var periDiv: UInt32 = 0x100
    private var usbCtrl: UInt32 = 0
    private var usbDiv: UInt32 = 0x100
    private var sysCtrl: UInt32 = 0
    private var sysDiv: UInt32 = 0x100
    private var adcCtrl: UInt32 = 0
    private var adcDiv: UInt32 = 0x100
    private var rtcCtrl: UInt32 = 0
    private var rtcDiv: UInt32 = 0x100

    private static func divisor(_ div: UInt32) -> Double {
        let integer = div >> 8
        return integer != 0 ? Double(integer) + Double(div & 0xFF) / 256 : 0x10000
    }

    var refFrequency: Double { refSourceFrequency / RPClocks.divisor(refDiv & 0x300) }
    var sysFrequency: Double { sysSourceFrequency / RPClocks.divisor(sysDiv) }

    var periFrequency: Double {
        if periCtrl & (1 << 11) == 0 || periCtrl & (1 << 10) != 0 { return 0 }
        switch (periCtrl >> 5) & 0x7 {
        case 0: return sysFrequency
        case 1: return chip.pllSys.frequency
        case 2: return chip.pllUSB.frequency
        case 3: return chip.roscFrequency
        case 4: return chip.xoscFrequency
        default: return 0
        }
    }

    private var refSourceFrequency: Double {
        switch refCtrl & 0x3 {
        case 0: return chip.roscFrequency
        case 2: return chip.xoscFrequency
        case 1: return (refCtrl >> 5) & 0x3 == 0 ? chip.pllUSB.frequency : 0
        default: return 0
        }
    }

    private var sysSourceFrequency: Double {
        if sysCtrl & 0x1 == 0 { return refFrequency }
        switch (sysCtrl >> 5) & 0x7 {
        case 0: return chip.pllSys.frequency
        case 1: return chip.pllUSB.frequency
        case 2: return chip.roscFrequency
        case 3: return chip.xoscFrequency
        default: return 0
        }
    }

    override func readUint32(_ offset: UInt32) -> UInt32 {
        switch offset {
        case 0x00, 0x0C, 0x18, 0x24: return gpoutCtrl[Int(offset / 0xC)] & 0b100110001110111100000
        case 0x04, 0x10, 0x1C, 0x28: return gpoutDiv[Int(offset / 0xC)]
        case 0x08, 0x14, 0x20, 0x2C: return 1
        case 0x30: return refCtrl & 0b000001100011
        case 0x34: return refDiv & 0x30
        case 0x38: return 1 << (refCtrl & 0x03)
        case 0x3C: return sysCtrl & 0b000011100001
        case 0x40: return sysDiv
        case 0x44: return 1 << (sysCtrl & 0x01)
        case 0x48: return periCtrl & 0b110011100000
        case 0x4C: return periDiv
        case 0x50: return 1
        case 0x54: return usbCtrl & 0b100110000110011100000
        case 0x58: return usbDiv
        case 0x5C: return 1
        case 0x60: return adcCtrl & 0b100110000110011100000
        case 0x64: return adcDiv & 0x30
        case 0x68: return 1
        case 0x6C: return rtcCtrl & 0b100110000110011100000
        case 0x70: return rtcDiv & 0x30
        case 0x74: return 1
        case 0x78: return 0xFF
        case 0x7C: return 0
        default: return super.readUint32(offset)
        }
    }

    override func writeUint32(_ offset: UInt32, _ value: UInt32) {
        switch offset {
        case 0x00, 0x0C, 0x18, 0x24: gpoutCtrl[Int(offset / 0xC)] = value
        case 0x04, 0x10, 0x1C, 0x28: gpoutDiv[Int(offset / 0xC)] = value
        case 0x30:
            refCtrl = value
            chip.updateClocks()
        case 0x34:
            refDiv = value
            chip.updateClocks()
        case 0x3C:
            sysCtrl = value
            chip.updateClocks()
        case 0x40:
            sysDiv = value
            chip.updateClocks()
        case 0x48:
            periCtrl = value
            chip.updateClocks()
        case 0x4C: periDiv = value
        case 0x54: usbCtrl = value
        case 0x58: usbDiv = value
        case 0x60: adcCtrl = value
        case 0x64: adcDiv = value
        case 0x6C: rtcCtrl = value
        case 0x70: rtcDiv = value
        case 0x78: return
        default: super.writeUint32(offset, value)
        }
    }
}
