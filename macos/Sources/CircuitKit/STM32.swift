import CortexM4
import Foundation

/// An STM32 running a flash image: the Cortex-M4 core and the chip's peripherals in C (Sources/CortexM4), its I/O pins
/// on the circuit, a USART on the serial monitor, and its I²S ports' frames handed to the codec or DAC wired to them.
/// A firmware built for its bootloader's place (Mutable's start at 0x08008000) runs from there when nothing is at the
/// start of flash.
///
/// - The STM32F405 (Mutable Instruments' Rings, Clouds, Elements, Warps and Marbles): 49 pins (PA0–PA15, PB0–PB15,
///   PC0–PC15, PD2), USART1 on the serial monitor.
/// - The STM32F373 (Plaits, Stages, Tides 2): 53 pins (PA0–PA15, PB0–PB15, PC0–PC15, PD8, PE8, PE9, PF6, PF7), with
///   its sigma-delta ADCs' inputs among them; USART3 (Mutable's debug port) on the serial monitor.
/// - The STM32F103 (Braids, Peaks, Frames, Streams): 35 pins (PA0–PA15, PB0–PB15, PC13–PC15), USART1 on the serial
///   monitor; a Cortex-M3, which runs as the M4 does.
public final class STM32Microcontroller: Microcontroller {
    /// The flash image's address: a firmware file's addresses are taken from here
    public static let flashStart = 0x0800_0000

    /// The flash's size
    public static func flashSize(_ model: STM32Model) -> Int {
        model == STM32_F373 ? 0x4_0000 : model == STM32_F103 ? 0x2_0000 : 0x10_0000
    }

    /// The pins' names, in the order of the part's terminals: "pa0" ... "pb15", then the model's others
    public static func pinNames(_ model: STM32Model) -> [String] {
        model == STM32_F373 ? f373Pins : model == STM32_F103 ? f103Pins : f405Pins
    }
    private static let f405Pins = names(STM32_F405)
    private static let f373Pins = names(STM32_F373)
    private static let f103Pins = names(STM32_F103)
    private static func names(_ model: STM32Model) -> [String] {
        (0..<Int(stm32_pin_count(model))).map { index in
            let port = stm32_pin_port(model, Int32(index)), pin = stm32_pin_number(model, Int32(index))
            return "p" + String(UnicodeScalar(UInt8(97 + port))) + String(pin)
        }
    }

    /// The USART the serial monitor shows
    static func serialUSART(_ model: STM32Model) -> Int32 { model == STM32_F373 ? 3 : 1 }

    /// An I²S port's partner (a codec): given each frame the chip sends, it gives back the one the chip receives.
    /// Samples are left-justified in 32 bits.
    public typealias FrameExchange = (_ port: Int, _ left: Int32, _ right: Int32) -> (left: Int32, right: Int32)
    /// An SPI port's partner (a DAC): a frame of `bits` (8 or 16) the chip shifts out as a master, and the frame it
    /// shifts in
    public typealias SPIExchange = (_ port: Int, _ frame: UInt32, _ bits: Int) -> UInt32
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
        var spi: SPIExchange?
        var serialUSART: Int32 = 1
        var i2c: I2CTarget?
        var watched: [Int] = []
        /// The buses' transactions taken from the chip while traced (the last 8192), under `traceLock`: the sound
        /// thread runs the chip, the window reads them
        var tracing = false
        let traceLock = NSLock()
        var trace: [BusEvent] = []
        private var taking = [STM32BusEvent](repeating: STM32BusEvent(), count: 1024)

        /// Moves what the chip has kept of its buses into `trace`
        func takeTrace() {
            guard tracing else { return }
            traceLock.lock()
            defer { traceLock.unlock() }
            while true {
                let count = Int(taking.withUnsafeMutableBufferPointer { stm32_take_bus_events(chip, $0.baseAddress, Int32($0.count)) })
                for k in 0..<count { trace.append(BusEvent(taking[k])) }
                if count < taking.count { break }
            }
            if trace.count > 8192 { trace.removeFirst(trace.count - 8192) }
        }

        init(model: STM32Model, firmware: [UInt8]) {
            chip = stm32_create_model(model, 8e6)!
            let flash = stm32_flash(chip)!
            let size = STM32Microcontroller.flashSize(model)
            let offset = STM32Microcontroller.placement(of: firmware, flashSize: size)
            let count = min(firmware.count, size - offset)
            firmware.withUnsafeBufferPointer { bytes in
                if let base = bytes.baseAddress { (flash + offset).update(from: base, count: count) }
            }
            var devices = STM32Devices()
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
            devices.spi_exchange = { context, port, frame, bits in
                let system = Unmanaged<System>.fromOpaque(context!).takeUnretainedValue()
                return system.spi?(Int(port), frame, Int(bits)) ?? 0xFFFF
            }
            serialUSART = STM32Microcontroller.serialUSART(model)
            devices.usart_send = { context, usart, byte in
                let system = Unmanaged<System>.fromOpaque(context!).takeUnretainedValue()
                if usart == system.serialUSART { system.outbox.append(byte) }
            }
            stm32_set_devices(chip, &devices)
            stm32_reset(chip)
        }

        /// Watches the pins (the circuit's indices), each change to their driven level logged and forwarded
        func watch(_ pins: [Int]) {
            watched = pins
            let context = Unmanaged.passUnretained(self).toOpaque()
            pins.map { Int32($0) }.withUnsafeBufferPointer { indices in
                stm32_watch_pins(chip, indices.baseAddress, Int32(indices.count), { context, cycle, index, high in
                    let system = Unmanaged<System>.fromOpaque(context!).takeUnretainedValue()
                    let event = PinEvent(cycle: Int(cycle &- system.runStart), pin: Int(index), high: high)
                    system.events.append(event)
                    system.onEvent?(event)
                }, context)
            }
        }

        deinit { stm32_destroy(chip) }
    }

    /// Where in flash a raw image goes: at its start, unless it is an application linked to run behind a bootloader
    /// (Mutable Instruments' at 0x08008000), whose vectors then all point within it placed there. A HEX file's image
    /// is placed by its addresses already, and starts at the flash's start.
    static func placement(of image: [UInt8], flashSize: Int = 0x10_0000) -> Int {
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

    /// Which chip it is
    public let model: STM32Model
    private let firmware: [UInt8]
    private var system: System
    private var shownStates: [PinState]
    private var shownCycles = 0
    private var serial: [UInt8] = []
    private var stateCodes: [UInt8]

    public init(model: STM32Model = STM32_F405, firmware: [UInt8]) {
        self.model = model
        self.firmware = firmware
        system = System(model: model, firmware: firmware)
        let count = STM32Microcontroller.pinNames(model).count
        shownStates = [PinState](repeating: .input(pullUp: false), count: count)
        stateCodes = [UInt8](repeating: 0, count: count)
        pinVoltages = [Double](repeating: 0, count: count)
        publish()
    }

    /// The chip in C (for tests)
    var chip: OpaquePointer { system.chip }

    /// What the firmware has reached that the model does not run (a peripheral it leaves out, one whose registers it
    /// keeps without running them, an address where the chip has nothing), and how often the chip has reset itself
    /// (its watchdog running out, its firmware asking): a firmware that does any of it does not run here as on the chip,
    /// or does not run well there
    public var notices: [String] {
        let chip = system.chip
        var said: [String] = []
        for k in 0..<Int(stm32_unmodelled_count(chip)) {
            var u = STM32Unmodelled()
            guard stm32_unmodelled(chip, Int32(k), &u) else { continue }
            let what = u.reads > 0 && u.writes > 0 ? "reads and writes" : u.writes > 0 ? "writes" : "reads"
            let at = String(format: "0x%08X, from about 0x%08X", u.first_address, u.pc)
            if let name = u.name.map({ String(cString: $0) }) {
                said.append(u.kept
                    ? "the firmware \(what) \(name) (first at \(at)), whose registers the model keeps without running them: nothing it asks of them happens."
                    : "the firmware \(what) \(name) (first at \(at)), which the model does not run: it reads 0 there, and what it writes is lost.")
            } else {
                said.append("the firmware \(what) \(String(format: "0x%08X", u.first_address)) (from about \(String(format: "0x%08X", u.pc))), where the chip has nothing: a bus fault on the chip, 0 here.")
            }
        }
        let watchdog = Int(stm32_watchdog_resets(chip)), software = Int(stm32_software_resets(chip))
        if watchdog > 0 {
            said.append("its watchdog ran out and reset it \(watchdog == 1 ? "once" : "\(watchdog) times"): the firmware stopped reloading it in time.")
        }
        if software > 0 {
            said.append("its firmware reset it \(software == 1 ? "once" : "\(software) times") (SYSRESETREQ).")
        }
        return said
    }

    /// Whether the chip keeps its buses' transactions (`busEvents`), as a logic analyzer on its pins would decode them
    public var tracesBuses: Bool {
        get { system.tracing }
        set {
            guard newValue != system.tracing else { return }
            system.traceLock.lock()
            system.tracing = newValue
            system.trace = []
            system.traceLock.unlock()
            stm32_trace_buses(system.chip, newValue)
        }
    }

    /// The buses' transactions kept since tracing began (the last 8192), oldest first, from `time` on
    public func busEvents(since time: Double = -.infinity) -> [BusEvent] {
        system.traceLock.lock()
        defer { system.traceLock.unlock() }
        guard let first = system.trace.firstIndex(where: { $0.time >= time }) else { return [] }
        return Array(system.trace[first...])
    }

    /// What each pin carries now, as the firmware has set it up ("SPI2's SCK", "a GPIO output"), by the pin's alternate
    /// function and ST's pin data
    public var pinFunctions: [(pin: String, function: String)] {
        let names = STM32Microcontroller.pinNames(model)
        let check = STM32BusCheck(chip: self, pinNames: names)
        return names.indices.map { (names[$0].uppercased(), check.describe($0)) }
    }

    /// Changes whenever `notices` gains one (not as their counts grow)
    var noticeCount: Int {
        let chip = system.chip
        return Int(stm32_unmodelled_count(chip)) + Int(stm32_watchdog_resets(chip)) + Int(stm32_software_resets(chip))
    }

    public var pinCount: Int { pinVoltages.count }
    /// The core's clock as the firmware has set it up: the F405's 16 MHz from reset (168 MHz once it has started its
    /// PLL), the F373's 8 MHz (72 MHz)
    public var clock: Double { stm32_hclk(system.chip) }
    public var cycles: Int { shownCycles }
    public var supply = 3.3
    public var pinStates: [PinState] { shownStates }
    public var serialOutput: [UInt8] { serial }

    public var serialInput: [UInt8] {
        get { [] }
        set {
            newValue.withUnsafeBufferPointer { bytes in
                stm32_usart_input(system.chip, system.serialUSART, bytes.baseAddress, Int32(bytes.count))
            }
        }
    }

    /// What each I²S port sends goes to this, which gives back what it receives (a codec wired to it)
    public var frameExchange: FrameExchange? {
        get { system.frames }
        set { system.frames = newValue }
    }

    /// What each SPI port sends as a master goes to this, which gives back what it receives (a DAC wired to it)
    public var spiExchange: SPIExchange? {
        get { system.spi }
        set { system.spi = newValue }
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
            stm32_set_pin_voltages(system.chip, volts.baseAddress, Int32(volts.count), supply)
        }
    }

    public func pinVoltage(_ pin: Int) -> Double { pin >= 0 && pin < pinVoltages.count ? pinVoltages[pin] : 0 }

    public func setPinVoltage(_ pin: Int, _ volts: Double) {
        guard pin >= 0 && pin < pinVoltages.count else { return }
        settingOnePin = true
        pinVoltages[pin] = volts
        settingOnePin = false
        stm32_set_pin_voltage(system.chip, Int32(pin), volts, supply)
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
        system.runStart = cm4_cycles(stm32_core(chip))
        if count > 0 { _ = stm32_run(chip, UInt64(count)) }
        publish()
    }

    public func reset() {
        let voltages = pinVoltages, frames = system.frames, spi = system.spi, i2c = system.i2c, watched = system.watched
        let onEvent = system.onEvent, tracing = system.tracing
        system = System(model: model, firmware: firmware)
        if tracing { tracesBuses = true }
        system.frames = frames
        system.spi = spi
        system.i2c = i2c
        system.onEvent = onEvent
        if !watched.isEmpty { system.watch(watched) }
        serial = []
        pinVoltages = voltages
        publish()
    }

    /// Takes on the other STM32's chip itself, not a copy of it: the two then share it (as the Pico does)
    public func adopt(_ other: Microcontroller) {
        guard let other = other as? STM32Microcontroller, other !== self, other.model == model else { return }
        system = other.system
        shownStates = other.shownStates
        shownCycles = other.shownCycles
        serial = other.serial
        pinVoltages = other.pinVoltages
    }

    private func publish() {
        let chip = system.chip
        shownCycles = Int(cm4_cycles(stm32_core(chip)))
        system.takeTrace()
        if !system.outbox.isEmpty {
            serial += system.outbox
            system.outbox = []
            if serial.count > 32_768 { serial.removeFirst(serial.count - 16_384) }
        }
        stateCodes.withUnsafeMutableBufferPointer { codes in
            stm32_pin_states(chip, codes.baseAddress, Int32(codes.count))
        }
        for index in stateCodes.indices {
            let state: PinState
            switch Int(stateCodes[index]) {
            case Int(STM32_DRIVEN_HIGH): state = .output(high: true)
            case Int(STM32_DRIVEN_LOW): state = .output(high: false)
            case Int(STM32_PULLED_UP): state = .input(pullUp: true)
            case Int(STM32_PULLED_DOWN): state = .inputPullDown
            default: state = .input(pullUp: false)
            }
            if shownStates[index] != state { shownStates[index] = state }
        }
    }
}

/// A transaction on one of an STM32's buses, as a logic analyzer on its pins would decode it
public struct BusEvent: Equatable, Sendable {
    public enum Kind: Int, Sendable {
        case spi, i2s, i2cStart, i2cWrite, i2cRead, i2cStop, usartSend, usartReceive
    }
    /// Seconds of the chip's time
    public let time: Double
    public let kind: Kind
    /// SPI1 1, I2C2 2, USART3 3...
    public let port: Int
    public let bits: Int
    /// SPI: shifted out, shifted in. I²S: sent left and right, received left and right (left-justified in 32 bits).
    /// I²C: the address, 1 to read, 1 if acknowledged; a byte and whether it was acknowledged. USART: the byte.
    public let a: UInt32, b: UInt32, c: UInt32, d: UInt32

    init(_ e: STM32BusEvent) {
        time = e.time
        kind = Kind(rawValue: Int(e.kind)) ?? .spi
        port = Int(e.port)
        bits = Int(e.bits)
        (a, b, c, d) = (e.a, e.b, e.c, e.d)
    }

    public init(time: Double, kind: Kind, port: Int, bits: Int, a: UInt32, b: UInt32 = 0, c: UInt32 = 0, d: UInt32 = 0) {
        (self.time, self.kind, self.port, self.bits) = (time, kind, port, bits)
        (self.a, self.b, self.c, self.d) = (a, b, c, d)
    }

    /// "SPI2", "I2C1", "USART3"
    public var bus: String {
        switch kind {
        case .spi: return "SPI\(port)"
        case .i2s: return "I2S\(port)"
        case .i2cStart, .i2cWrite, .i2cRead, .i2cStop: return "I2C\(port)"
        case .usartSend, .usartReceive: return "USART\(port)"
        }
    }

    /// What happened, as a logic analyzer's decoder shows it: "→ 0x6E00 ← 0x0123", "start 0x1A write, ACK"
    public var summary: String {
        func hex(_ v: UInt32, _ bits: Int) -> String { String(format: "0x%0\((bits + 3) / 4)X", v) }
        func ack(_ v: UInt32) -> String { v != 0 ? "ACK" : "NACK" }
        switch kind {
        case .spi: return "→ \(hex(a, bits)) ← \(hex(b, bits))"
        case .i2s: return "→ L \(hex(a, 32)) R \(hex(b, 32))   ← L \(hex(c, 32)) R \(hex(d, 32))"
        case .i2cStart: return "start \(hex(a, 7)) \(b != 0 ? "read" : "write"), \(ack(c))"
        case .i2cWrite: return "write \(hex(a, 8)), \(ack(b))"
        case .i2cRead: return "read \(hex(a, 8)), \(ack(b))"
        case .i2cStop: return "stop"
        case .usartSend, .usartReceive:
            let character = a >= 0x20 && a < 0x7F ? " '\(Character(UnicodeScalar(UInt8(a))))'" : ""
            return "\(kind == .usartSend ? "sends" : "receives") \(hex(a, 8))\(character)"
        }
    }
}
