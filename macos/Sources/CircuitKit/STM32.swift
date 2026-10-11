import CortexM4
import Foundation

/// An STM32F405 (the chip of Mutable Instruments' Rings, Clouds, Elements, Warps and Marbles) running a flash image:
/// the Cortex-M4 core and the chip's peripherals in C (Sources/CortexM4), its 49 I/O pins on the circuit (PA0–PA15,
/// PB0–PB15, PC0–PC15, PD2), USART1 on the serial monitor, and its I²S ports' frames handed to the codec wired to them.
/// A firmware built for its bootloader's place (Mutable's start at 0x08008000) runs from there when nothing is at the
/// start of flash.
public final class STM32F405: Microcontroller {
    /// The flash image's address: a firmware file's addresses are taken from here
    public static let flashStart = 0x0800_0000
    public static let flashSize = 0x10_0000

    /// The pins' names, in the order of the part's terminals: "pa0" ... "pc15", "pd2"
    public static let pinNames: [String] = (0..<Int(STM32F4_PIN_COUNT)).map { index in
        let port = stm32f4_pin_port(Int32(index)), pin = stm32f4_pin_number(Int32(index))
        return "p" + String(UnicodeScalar(UInt8(97 + port))) + String(pin)
    }

    /// An I²S port's partner (a codec): given each frame the chip sends, it gives back the one the chip receives.
    /// Samples are left-justified in 32 bits.
    public typealias FrameExchange = (_ port: Int, _ left: Int32, _ right: Int32) -> (left: Int32, right: Int32)
    /// An I²C target on one of the chip's buses (a codec's control port): a start with its address and direction
    /// (true when it acknowledges), a byte written (acknowledged), a byte read, a stop
    public struct I2CTarget {
        public var start: (_ bus: Int, _ address: UInt8, _ read: Bool) -> Bool
        public var write: (_ bus: Int, _ byte: UInt8) -> Bool
        public var read: (_ bus: Int, _ ack: Bool) -> UInt8
        public var stop: (_ bus: Int) -> Void

        public init(start: @escaping (Int, UInt8, Bool) -> Bool, write: @escaping (Int, UInt8) -> Bool,
                    read: @escaping (Int, Bool) -> UInt8, stop: @escaping (Int) -> Void) {
            self.start = start
            self.write = write
            self.read = read
            self.stop = stop
        }
    }

    /// The running chip and what goes with it. The sound thread's STM32 and the window's share one (see `adopt`).
    final class System {
        let chip: OpaquePointer
        var outbox: [UInt8] = []
        var events: [PinEvent] = []
        var takenEvents: [PinEvent] = []
        var onEvent: ((PinEvent) -> Void)?
        var runStart: UInt64 = 0
        var frames: FrameExchange?
        var i2c: I2CTarget?
        var watched: [Int] = []

        init(firmware: [UInt8]) {
            chip = stm32f4_create(8e6)!
            let flash = stm32f4_flash(chip)!
            let offset = STM32F405.placement(of: firmware)
            let count = min(firmware.count, STM32F405.flashSize - offset)
            firmware.withUnsafeBufferPointer { bytes in
                if let base = bytes.baseAddress { (flash + offset).update(from: base, count: count) }
            }
            var devices = STM32F4Devices()
            devices.context = Unmanaged.passUnretained(self).toOpaque()
            devices.i2c_start = { context, bus, address, read in
                let system = Unmanaged<System>.fromOpaque(context!).takeUnretainedValue()
                return system.i2c?.start(Int(bus), address, read) ?? false
            }
            devices.i2c_write = { context, bus, byte in
                let system = Unmanaged<System>.fromOpaque(context!).takeUnretainedValue()
                return system.i2c?.write(Int(bus), byte) ?? false
            }
            devices.i2c_read = { context, bus, ack in
                let system = Unmanaged<System>.fromOpaque(context!).takeUnretainedValue()
                return system.i2c?.read(Int(bus), ack) ?? 0xFF
            }
            devices.i2c_stop = { context, bus in
                let system = Unmanaged<System>.fromOpaque(context!).takeUnretainedValue()
                system.i2c?.stop(Int(bus))
            }
            devices.i2s_frame = { context, port, left, right, inLeft, inRight in
                let system = Unmanaged<System>.fromOpaque(context!).takeUnretainedValue()
                guard let frames = system.frames else {
                    inLeft?.pointee = 0
                    inRight?.pointee = 0
                    return
                }
                let (l, r) = frames(Int(port), left, right)
                inLeft?.pointee = l
                inRight?.pointee = r
            }
            devices.usart_send = { context, usart, byte in
                let system = Unmanaged<System>.fromOpaque(context!).takeUnretainedValue()
                if usart == 1 { system.outbox.append(byte) }
            }
            stm32f4_set_devices(chip, &devices)
            stm32f4_reset(chip)
        }

        /// Watches the pins (the circuit's indices), each change to their driven level logged and forwarded
        func watch(_ pins: [Int]) {
            watched = pins
            let context = Unmanaged.passUnretained(self).toOpaque()
            pins.map { Int32($0) }.withUnsafeBufferPointer { indices in
                stm32f4_watch_pins(chip, indices.baseAddress, Int32(indices.count), { context, cycle, index, high in
                    let system = Unmanaged<System>.fromOpaque(context!).takeUnretainedValue()
                    let event = PinEvent(cycle: Int(cycle &- system.runStart), pin: Int(index), high: high)
                    system.events.append(event)
                    system.onEvent?(event)
                }, context)
            }
        }

        deinit { stm32f4_destroy(chip) }
    }

    /// Where in flash a raw image goes: at its start, unless it is an application linked to run behind a bootloader
    /// (Mutable Instruments' at 0x08008000), whose vectors then all point within it placed there. A HEX file's image
    /// is placed by its addresses already, and starts at the flash's start.
    static func placement(of image: [UInt8]) -> Int {
        guard image.count >= 64 else { return 0 }
        func word(_ k: Int) -> Int {
            Int(image[4 * k]) | Int(image[4 * k + 1]) << 8 | Int(image[4 * k + 2]) << 16 | Int(image[4 * k + 3]) << 24
        }
        // the reset, NMI and hard fault handlers, as flash addresses
        let handlers = (1...3).map { word($0) & ~1 }
        guard handlers.allSatisfy({ $0 >= flashStart && $0 < flashStart + flashSize }) else { return 0 }
        if handlers.allSatisfy({ $0 - flashStart < image.count }) { return 0 }
        for offset in [0x4000, 0x8000, 0xC000, 0x10000, 0x20000, 0x40000] where offset + image.count <= flashSize {
            if handlers.allSatisfy({ $0 - flashStart >= offset && $0 - flashStart < offset + image.count }) { return offset }
        }
        return 0
    }

    private let firmware: [UInt8]
    private var system: System
    private var shownStates: [PinState]
    private var shownCycles = 0
    private var serial: [UInt8] = []
    private var stateCodes: [UInt8]

    public init(firmware: [UInt8]) {
        self.firmware = firmware
        system = System(firmware: firmware)
        shownStates = [PinState](repeating: .input(pullUp: false), count: STM32F405.pinNames.count)
        stateCodes = [UInt8](repeating: 0, count: STM32F405.pinNames.count)
        pinVoltages = [Double](repeating: 0, count: STM32F405.pinNames.count)
        publish()
    }

    /// The chip in C (for tests)
    var chip: OpaquePointer { system.chip }

    public var pinCount: Int { STM32F405.pinNames.count }
    /// The core's clock as the firmware has set it up: 16 MHz from reset, 168 MHz once it has started its PLL
    public var clock: Double { stm32f4_hclk(system.chip) }
    public var cycles: Int { shownCycles }
    public var supply = 3.3
    public var pinStates: [PinState] { shownStates }
    public var serialOutput: [UInt8] { serial }

    public var serialInput: [UInt8] {
        get { [] }
        set {
            newValue.withUnsafeBufferPointer { bytes in
                stm32f4_usart_input(system.chip, 1, bytes.baseAddress, Int32(bytes.count))
            }
        }
    }

    /// What each I²S port sends goes to this, which gives back what it receives (a codec wired to it)
    public var frameExchange: FrameExchange? {
        get { system.frames }
        set { system.frames = newValue }
    }

    /// The I²C target on its buses (a codec's control port)
    public var i2cTarget: I2CTarget? {
        get { system.i2c }
        set { system.i2c = newValue }
    }

    /// The circuit's voltages on the pins: each one's level follows with hysteresis (high above 0.6 of the supply, low
    /// below 0.3), and the ADCs read them against 3.3 V
    public var pinVoltages: [Double] {
        didSet { if !settingOnePin { applyVoltages() } }
    }
    private var settingOnePin = false

    private func applyVoltages() {
        pinVoltages.withUnsafeBufferPointer { volts in
            stm32f4_set_pin_voltages(system.chip, volts.baseAddress, Int32(volts.count), supply)
        }
    }

    public func pinVoltage(_ pin: Int) -> Double { pin >= 0 && pin < pinVoltages.count ? pinVoltages[pin] : 0 }

    public func setPinVoltage(_ pin: Int, _ volts: Double) {
        guard pin >= 0 && pin < pinVoltages.count else { return }
        settingOnePin = true
        pinVoltages[pin] = volts
        settingOnePin = false
        stm32f4_set_pin_voltage(system.chip, Int32(pin), volts, supply)
    }

    public var watchedPins: [Int] {
        get { system.watched }
        set { system.watch(newValue) }
    }

    public func takePinEvents() -> [PinEvent] {
        let system = self.system
        swap(&system.events, &system.takenEvents)
        system.events.removeAll(keepingCapacity: true)
        return system.takenEvents
    }

    public var onPinEvent: ((PinEvent) -> Void)? {
        get { system.onEvent }
        set { system.onEvent = newValue }
    }

    public func run(cycles count: Int) {
        let chip = system.chip
        system.runStart = cm4_cycles(stm32f4_core(chip))
        if count > 0 { _ = stm32f4_run(chip, UInt64(count)) }
        publish()
    }

    public func reset() {
        let voltages = pinVoltages, frames = system.frames, i2c = system.i2c, watched = system.watched
        let onEvent = system.onEvent
        system = System(firmware: firmware)
        system.frames = frames
        system.i2c = i2c
        system.onEvent = onEvent
        if !watched.isEmpty { system.watch(watched) }
        serial = []
        pinVoltages = voltages
        publish()
    }

    /// Takes on the other STM32's chip itself, not a copy of it: the two then share it (as the Pico does)
    public func adopt(_ other: Microcontroller) {
        guard let other = other as? STM32F405, other !== self else { return }
        system = other.system
        shownStates = other.shownStates
        shownCycles = other.shownCycles
        serial = other.serial
        pinVoltages = other.pinVoltages
    }

    private func publish() {
        let chip = system.chip
        shownCycles = Int(cm4_cycles(stm32f4_core(chip)))
        if !system.outbox.isEmpty {
            serial += system.outbox
            system.outbox = []
            if serial.count > 32_768 { serial.removeFirst(serial.count - 16_384) }
        }
        stateCodes.withUnsafeMutableBufferPointer { codes in
            stm32f4_pin_states(chip, codes.baseAddress, Int32(codes.count))
        }
        for index in stateCodes.indices {
            let state: PinState
            switch Int(stateCodes[index]) {
            case Int(STM32F4_DRIVEN_HIGH): state = .output(high: true)
            case Int(STM32F4_DRIVEN_LOW): state = .output(high: false)
            case Int(STM32F4_PULLED_UP): state = .input(pullUp: true)
            case Int(STM32F4_PULLED_DOWN): state = .inputPullDown
            default: state = .input(pullUp: false)
            }
            if shownStates[index] != state { shownStates[index] = state }
        }
    }
}
