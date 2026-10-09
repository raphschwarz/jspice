import Foundation

/// A Raspberry Pi Pico: an RP2040 running a flash image, its pins GP0–GP22 and GP26–GP28 on the circuit, its USB serial
/// port (the firmware's CDC device, enumerated by a simulated computer) on the serial monitor, and the board's LED on
/// GP25
public final class Pico: Microcontroller {
    /// The GPIO behind each pin the circuit reaches
    public static let gpioOfPin: [Int] = Array(0...22) + [26, 27, 28]
    public static let ledGPIO = 25

    /// The running chip and what goes with it. The sound thread's Pico and the window's share one (see `adopt`).
    private final class System {
        let chip = RP2040()
        let cdc: RPUSBCDC
        var outbox: [UInt8] = []
        var levels = [Bool](repeating: false, count: 30)
        var pinsChanged = true
        /// The watched pins by GPIO, the changes to their driven levels, and when the present run started
        var watched: [Int: Int] = [:]
        var events: [PinEvent] = []
        var onEvent: ((PinEvent) -> Void)?
        var runStart = 0.0

        init(firmware: [UInt8]) {
            cdc = RPUSBCDC(usb: chip.usbCtrl)
            chip.loadFlash(firmware)
            // as rp2040js's demos do: straight into the flash image's boot stage 2, which sets up XIP and jumps on
            chip.core.PC = RP2040.flashStart
            cdc.onSerialData = { [unowned self] bytes in self.outbox += bytes }
            for pin in chip.gpio {
                let gpio = pin.index
                pin.onChange = { [unowned self] state in
                    self.pinsChanged = true
                    guard let watchedPin = self.watched[gpio] else { return }
                    let high: Bool
                    switch state {
                    case .high: high = true
                    case .low: high = false
                    // an I²C line let go: the bus is pulled up
                    case _ where self.chip.gpio[gpio].functionSelect == RPGPIOPin.functionI2C: high = true
                    default: return
                    }
                    let cycle = Int((self.chip.clock.nanos - self.runStart) / RP2040.cycleNanos)
                    let event = PinEvent(cycle: cycle, pin: watchedPin, high: high)
                    self.events.append(event)
                    self.onEvent?(event)
                }
            }
            // VBUS present (GP24), and the ADC's own inputs: VSYS/3 (5 V from USB) and the temperature sensor at 27 °C
            chip.gpio[24].setInputValue(true)
            levels[24] = true
            chip.adc.channelValues[3] = 2068
            chip.adc.channelValues[4] = 876
        }
    }

    private let firmware: [UInt8]
    private var system: System
    private var shownStates: [PinState]
    private var shownLED = false
    private var shownCycles = 0
    private var serial: [UInt8] = []

    public init(firmware: [UInt8]) {
        self.firmware = firmware
        system = System(firmware: firmware)
        shownStates = [PinState](repeating: .inputPullDown, count: Pico.gpioOfPin.count)
        pinVoltages = [Double](repeating: 0, count: Pico.gpioOfPin.count)
        publish()
    }

    public var pinCount: Int { Pico.gpioOfPin.count }
    public var clock: Double { 125e6 }
    public var cycles: Int { shownCycles }
    public var supply = 3.3
    public var pinStates: [PinState] { shownStates }
    /// The board's LED
    public var ledOn: Bool { shownLED }
    public var serialOutput: [UInt8] { serial }

    public var serialInput: [UInt8] {
        get { system.cdc.pendingInput }
        set { system.cdc.setPendingInput(newValue) }
    }

    /// The circuit's voltages on the pins: the digital level of each follows with hysteresis (high above 0.6 of the
    /// supply, low below 0.3), and the ADC reads GP26–GP28 against the supply
    public var pinVoltages: [Double] {
        didSet { applyVoltages() }
    }

    private func applyVoltages() {
        let chip = system.chip
        for (pin, gpio) in Pico.gpioOfPin.enumerated() where pin < pinVoltages.count {
            let v = pinVoltages[pin]
            var level = system.levels[gpio]
            if v > 0.6 * supply { level = true } else if v < 0.3 * supply { level = false }
            if level != system.levels[gpio] {
                system.levels[gpio] = level
                chip.gpio[gpio].setInputValue(level)
            }
            if gpio >= 26 {
                let code = (v / max(supply, 0.1) * 4095).rounded()
                chip.adc.channelValues[gpio - 26] = UInt32(min(max(code, 0), 4095))
            }
        }
    }

    public var watchedPins: [Int] {
        get { system.watched.sorted { $0.key < $1.key }.map(\.value) }
        set {
            system.watched = [:]
            for pin in newValue where pin >= 0 && pin < Pico.gpioOfPin.count { system.watched[Pico.gpioOfPin[pin]] = pin }
        }
    }

    public func takePinEvents() -> [PinEvent] {
        defer { system.events.removeAll(keepingCapacity: true) }
        return system.events
    }

    public var onPinEvent: ((PinEvent) -> Void)? {
        get { system.onEvent }
        set { system.onEvent = newValue }
    }

    public func run(cycles count: Int) {
        let chip = system.chip
        system.runStart = chip.clock.nanos
        let end = chip.clock.nanos + Double(count) * RP2040.cycleNanos
        chip.run(until: end)
        publish()
    }

    public func reset() {
        let voltages = pinVoltages
        system = System(firmware: firmware)
        serial = []
        pinVoltages = voltages
        publish()
    }

    /// Takes on the other Pico's chip itself, not a copy of it: the two then share it, and whichever runs it next
    /// carries on from where the other left it (the sound thread runs it while sound plays, the window's then shows
    /// what it published; when sound stops the window's runs it on). Only `run` and `reset` touch the chip; what
    /// the pins, LED and serial port show is published at the end of each.
    public func adopt(_ other: Microcontroller) {
        guard let other = other as? Pico, other !== self else { return }
        system = other.system
        shownStates = other.shownStates
        shownLED = other.shownLED
        shownCycles = other.shownCycles
        serial = other.serial
        pinVoltages = other.pinVoltages
    }

    private func publish() {
        let chip = system.chip
        shownCycles = Int(chip.clock.nanos / RP2040.cycleNanos)
        if !system.outbox.isEmpty {
            serial += system.outbox
            system.outbox = []
            if serial.count > 32_768 { serial.removeFirst(serial.count - 16_384) }
        }
        guard system.pinsChanged else { return }
        system.pinsChanged = false
        shownStates = Pico.gpioOfPin.map { Pico.state(chip.gpio[$0].value) }
        shownLED = chip.gpio[Pico.ledGPIO].value == .high
    }

    private static func state(_ value: RPPinState) -> PinState {
        switch value {
        case .high: return .output(high: true)
        case .low: return .output(high: false)
        case .inputPullUp: return .input(pullUp: true)
        case .inputPullDown: return .inputPullDown
        case .input, .inputBusKeeper: return .input(pullUp: false)
        }
    }
}
