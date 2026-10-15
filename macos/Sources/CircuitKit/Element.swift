import Foundation

/// A point on the drawing grid. Elements connect where their terminals share a grid point.
public struct GridPoint: Hashable, Codable, Sendable {
    public var x: Int
    public var y: Int

    public init(_ x: Int, _ y: Int) {
        self.x = x
        self.y = y
    }

    public static let zero = GridPoint(0, 0)

    public static func + (lhs: GridPoint, rhs: GridPoint) -> GridPoint { GridPoint(lhs.x + rhs.x, lhs.y + rhs.y) }
    public static func - (lhs: GridPoint, rhs: GridPoint) -> GridPoint { GridPoint(lhs.x - rhs.x, lhs.y - rhs.y) }
    public static func * (lhs: GridPoint, rhs: Int) -> GridPoint { GridPoint(lhs.x * rhs, lhs.y * rhs) }

    /// Rotated 90° clockwise on screen (y points down) around `pivot`
    public func rotated(around pivot: GridPoint) -> GridPoint {
        let d = self - pivot
        return pivot + GridPoint(-d.y, d.x)
    }
}

public enum ElementCategory: String, CaseIterable, Sendable, Identifiable {
    case basics = "Basics"
    case sources = "Sources"
    case switches = "Switches"
    case semiconductors = "Semiconductors"
    case tubes = "Tubes & Transformers"
    case amplifiers = "Amplifiers"
    case audio = "Audio"
    case synth = "Synth Chips"
    case microcontrollers = "Microcontrollers"
    case timersAndLogic = "Timers & Logic"
    case effects = "Effects"
    case memristors = "Memristors"
    case instruments = "Instruments"
    case blocks = "Blocks"

    public var id: String { rawValue }
}

public enum ElementKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case wire, ground, netLabel, resistor, potentiometer, lamp, capacitor, inductor
    case dcVoltage, acVoltage, squareVoltage, noiseVoltage, currentSource, keyboardPitch, keyboardGate, audioInput
    case toggleSwitch, pushButton
    case diode, zener, led, npn, pnp, nmos, pmos, njfet, pjfet
    case triode, pentode, transformer
    case opAmp, ota, multiplier, comparator
    case vco, vcf, envelope, vca, sampleHold, divider
    case timer555, schmittInverter, unbufferedInverter, analogSwitch
    case logicGate, flipFlop, decadeCounter, binaryCounter, analogMux, analogSelector, pll, dac, shiftRegister
    /// A 74HC165: eight inputs loaded in parallel, shifted out serially (buttons and switches read over SPI)
    case shiftIn
    /// A PCA9685: sixteen 12-bit PWM outputs on I²C (LEDs, a panel's lights)
    case ledDriver
    /// A TLC5947: twenty-four 12-bit PWM constant-current sinks, their levels shifted in over SPI (a panel's LEDs)
    case ledSink
    /// A 24LC-series EEPROM on I²C: a firmware's saved settings, written a page at a time
    case i2cEeprom
    case atmega328p, atmega2560, attiny85, rp2040
    /// The STM32F405, the chip of Mutable Instruments' Rings, Clouds, Elements, Warps and Marbles (firmware loaded)
    case stm32f405
    /// The STM32F373, the chip of Mutable Instruments' Plaits, Stages and Tides 2 (firmware loaded)
    case stm32f373
    /// The STM32F103, the chip of Mutable Instruments' Braids, Peaks, Frames and Streams (firmware loaded)
    case stm32f103
    case delayLine, digitalDelay, vactrol
    case memristor
    /// A behavioural source (SPICE's B source, and its E, F, G and H sources): a voltage or current set by an expression
    /// of the voltages at its sense pins and the currents through named sources (`code` holds the expression)
    case behavioralSource
    case probe, ammeter
    /// A break in a feedback loop for measuring its loop gain: 0 V from `in` (the side that drives) to `out` (the side
    /// driven), where small-signal analysis injects (see `SmallSignalModel.loopGain`); a link in the built circuit
    case loopProbe
    case speaker
    /// Audio parts: microphones and a pickup, preamp, line and power amp chips, dynamics, tone, metering, a reverb tank
    case microphone, electretMic, pickup, instrumentationAmp, lineReceiver, lineDriver, audioPowerAmp, compander, toneControl
    case levelDetector, springReverb, barGraphDriver, balancedCable, vuMeter
    /// Ring modulators and mixers, and a centre-tapped transformer for diode ring modulators
    case balancedModulator, mixerOscillator, tappedTransformer
    /// Function generator chips (XR2206, ICL8038, LM566) and the LM3900 Norton amplifier
    case functionGenerator, nortonAmp
    /// Bucket-brigade chips and digital reverbs: the MN3101 clock driver, the MN3011 multi-tap BBD, the FV-1 effects
    /// processor and the Belton reverb brick
    case bbdClock, multiTapDelay, effectsProcessor, reverbBrick
    /// Converters a microcontroller drives: the MCP4822 dual SPI DAC, the MCP3008 SPI ADC, the MCP4725 I²C DAC and the
    /// PCM5102 I²S audio DAC
    case dualDac, spiAdc, i2cDac, i2sDac
    /// An audio codec (the WM8731, CS4270, PCM3060, AK4558 or AK4556): a stereo ADC and DAC on I²S, set up over I²C at
    /// its address or by its pins (its frames exchanged with an STM32 on its I²S pins)
    case codec
    /// A CV DAC (the octal DAC8568, the quad DAC8564 and DAC7554, the dual DAC8552, the DAC8551): words of a channel and
    /// a code, given it whole by an STM32's I²S port (Mutable's Stages and Tides 2) or SPI port, framed by its SYNC
    /// (Braids, Peaks, Frames, Streams)
    case cvDac
    /// Dynamics and switching: the SSM2166 mic preamp with compression and gating, the THAT4301 (a VCA, an RMS detector
    /// and an op-amp), and a 3PDT footswitch
    case agcPreamp, analogEngine, footswitch
    /// Eurorack parts: a switched (normalled) jack, and a voltage regulator (78xx, 79xx, LM1117, LM317, LM337)
    case jack, regulator
    /// A block (a circuit used as one part) and the ports that are its pins
    case port, block

    public var id: String { rawValue }
}

/// Describes one editable number of an element, for the inspector and for defaults.
public struct ParamSpec: Sendable, Hashable {
    public let key: String
    public let name: String
    public let unit: String
    public let defaultValue: Double
    /// Range offered by the inspector slider; typed values may go beyond it
    public let range: ClosedRange<Double>
    public let logarithmic: Bool
    /// The values this parameter can take, with their names, when it picks one of a few settings (a waveform)
    public let choices: [ParamChoice]
    /// One of a SPICE model card's many parameters, which a manufacturer's model sets: kept out of the way
    public let advanced: Bool

    public init(_ key: String, _ name: String, unit: String, default defaultValue: Double, range: ClosedRange<Double>, log: Bool = true,
                choices: [ParamChoice] = [], advanced: Bool = false) {
        self.key = key
        self.name = name
        self.unit = unit
        self.defaultValue = defaultValue
        self.range = range
        self.logarithmic = log
        self.choices = choices
        self.advanced = advanced
    }

    /// A parameter that picks one of the named settings, stored as 0, 1, 2…
    static func choice(_ key: String, _ name: String, _ names: [String], default defaultValue: Double = 0) -> ParamSpec {
        ParamSpec(key, name, unit: "", default: defaultValue, range: 0...Double(max(names.count - 1, 1)), log: false,
                  choices: names.enumerated().map { ParamChoice(name: $0.element, value: Double($0.offset)) })
    }
}

/// One of the settings a parameter can pick
public struct ParamChoice: Sendable, Hashable {
    public let name: String
    public let value: Double

    public init(name: String, value: Double) {
        self.name = name
        self.value = value
    }
}

public enum LEDColor: Int, CaseIterable, Sendable {
    case red, green, blue, yellow, white

    public var name: String {
        switch self {
        case .red: return "Red"
        case .green: return "Green"
        case .blue: return "Blue"
        case .yellow: return "Yellow"
        case .white: return "White"
        }
    }

    /// sRGB components of the emitted light
    public var rgb: (Double, Double, Double) {
        switch self {
        case .red: return (1.0, 0.18, 0.12)
        case .green: return (0.2, 0.95, 0.3)
        case .blue: return (0.25, 0.45, 1.0)
        case .yellow: return (1.0, 0.85, 0.1)
        case .white: return (1.0, 1.0, 0.95)
        }
    }

    /// Typical forward voltage at 10 mA
    public var forwardVoltage: Double {
        switch self {
        case .red: return 1.9
        case .yellow: return 2.0
        case .green: return 2.2
        case .blue, .white: return 3.0
        }
    }
}

extension ElementKind {
    public var displayName: String {
        switch self {
        case .wire: return "Wire"
        case .ground: return "Ground"
        case .netLabel: return "Net Label"
        case .resistor: return "Resistor"
        case .potentiometer: return "Potentiometer"
        case .lamp: return "Lamp"
        case .capacitor: return "Capacitor"
        case .inductor: return "Inductor"
        case .dcVoltage: return "DC Voltage"
        case .acVoltage: return "AC Voltage"
        case .squareVoltage: return "Square Wave"
        case .noiseVoltage: return "Noise"
        case .audioInput: return "Audio In"
        case .currentSource: return "Current Source"
        case .keyboardPitch: return "Keyboard Pitch"
        case .keyboardGate: return "Keyboard Gate"
        case .toggleSwitch: return "Switch"
        case .pushButton: return "Push Button"
        case .diode: return "Diode"
        case .zener: return "Zener Diode"
        case .led: return "LED"
        case .npn: return "NPN Transistor"
        case .pnp: return "PNP Transistor"
        case .nmos: return "NMOS Transistor"
        case .pmos: return "PMOS Transistor"
        case .njfet: return "N-JFET"
        case .pjfet: return "P-JFET"
        case .triode: return "Triode"
        case .pentode: return "Pentode"
        case .transformer: return "Transformer"
        case .opAmp: return "Op-Amp"
        case .ota: return "OTA"
        case .multiplier: return "Multiplier"
        case .comparator: return "Comparator"
        case .vco: return "VCO"
        case .vcf: return "VCF (4-Pole Low-Pass)"
        case .envelope: return "Envelope (ADSR)"
        case .vca: return "VCA"
        case .sampleHold: return "Sample & Hold"
        case .divider: return "Clock Divider"
        case .delayLine: return "BBD Delay Line"
        case .digitalDelay: return "Digital Echo"
        case .vactrol: return "Vactrol"
        case .timer555: return "555 Timer"
        case .atmega328p: return "ATmega328P (Arduino Uno)"
        case .atmega2560: return "ATmega2560 (Arduino Mega)"
        case .attiny85: return "ATtiny85"
        case .rp2040: return "RP2040 (Raspberry Pi Pico)"
        case .stm32f405: return "STM32F405"
        case .stm32f373: return "STM32F373"
        case .stm32f103: return "STM32F103"
        case .schmittInverter: return "Schmitt Inverter"
        case .analogSwitch: return "Analog Switch"
        case .logicGate: return "Logic Gate"
        case .flipFlop: return "D Flip-Flop"
        case .decadeCounter: return "Decade Counter"
        case .binaryCounter: return "Binary Counter"
        case .shiftRegister: return "Shift Register"
        case .shiftIn: return "Shift Register (Parallel In)"
        case .ledDriver: return "PWM LED Driver"
        case .ledSink: return "Constant-Current LED Driver"
        case .i2cEeprom: return "I²C EEPROM"
        case .analogMux: return "Analog Multiplexer"
        case .analogSelector: return "Analog Selector"
        case .pll: return "Phase-Locked Loop"
        case .dac: return "SPI DAC"
        case .unbufferedInverter: return "Unbuffered Inverter"
        case .memristor: return "Memristor"
        case .behavioralSource: return "Behavioural Source"
        case .probe: return "Voltage Probe"
        case .ammeter: return "Ammeter"
        case .loopProbe: return "Loop Probe"
        case .speaker: return "Speaker"
        case .microphone: return "Microphone"
        case .electretMic: return "Electret Mic Capsule"
        case .pickup: return "Guitar Pickup"
        case .instrumentationAmp: return "Mic Preamp (In-Amp)"
        case .lineReceiver: return "Balanced Line Receiver"
        case .lineDriver: return "Balanced Line Driver"
        case .audioPowerAmp: return "LM386 Power Amp"
        case .compander: return "Compander"
        case .balancedModulator: return "Balanced Modulator"
        case .mixerOscillator: return "Mixer-Oscillator"
        case .tappedTransformer: return "Centre-Tapped Transformer"
        case .functionGenerator: return "Function Generator"
        case .nortonAmp: return "Norton Amplifier"
        case .bbdClock: return "BBD Clock Driver"
        case .multiTapDelay: return "Multi-Tap BBD"
        case .effectsProcessor: return "Effects DSP"
        case .reverbBrick: return "Reverb Brick"
        case .dualDac: return "Dual SPI DAC"
        case .spiAdc: return "SPI ADC"
        case .i2cDac: return "I²C DAC"
        case .i2sDac: return "I²S Audio DAC"
        case .codec: return "Audio Codec"
        case .cvDac: return "Octal CV DAC"
        case .agcPreamp: return "Mic Preamp with AGC"
        case .analogEngine: return "VCA and RMS Detector"
        case .footswitch: return "3PDT Footswitch"
        case .jack: return "Switched Jack"
        case .regulator: return "Voltage Regulator"
        case .toneControl: return "Tone Control"
        case .levelDetector: return "Level Detector"
        case .springReverb: return "Spring Reverb Tank"
        case .barGraphDriver: return "LED Bar-Graph Driver"
        case .balancedCable: return "Balanced Cable"
        case .vuMeter: return "VU Meter"
        case .port: return "Port"
        case .block: return "Block"
        }
    }

    public var namePrefix: String {
        switch self {
        case .wire: return "W"
        case .ground: return "GND"
        case .netLabel: return "N"
        case .resistor, .potentiometer: return "R"
        case .lamp: return "LMP"
        case .capacitor: return "C"
        case .inductor: return "L"
        case .dcVoltage, .acVoltage, .squareVoltage, .noiseVoltage: return "V"
        case .audioInput: return "IN"
        case .currentSource: return "I"
        case .keyboardPitch: return "CV"
        case .keyboardGate: return "GATE"
        case .toggleSwitch, .pushButton: return "S"
        case .diode, .zener: return "D"
        case .led: return "LED"
        case .npn, .pnp, .njfet, .pjfet: return "Q"
        case .nmos, .pmos: return "M"
        case .triode, .pentode: return "VT"
        case .transformer: return "T"
        case .opAmp, .ota, .multiplier, .comparator, .delayLine, .digitalDelay, .timer555, .schmittInverter, .unbufferedInverter,
             .analogSwitch,
             .atmega328p, .atmega2560,
             .attiny85, .rp2040, .stm32f405, .stm32f373, .stm32f103: return "U"
        case .vco, .vcf, .envelope, .vca, .sampleHold, .divider: return "U"
        case .logicGate, .flipFlop, .decadeCounter, .binaryCounter, .shiftRegister, .shiftIn, .ledDriver, .ledSink, .i2cEeprom, .analogMux, .analogSelector, .pll, .dac, .dualDac, .spiAdc, .i2cDac, .i2sDac, .codec, .cvDac: return "U"
        case .vactrol: return "VTL"
        case .memristor: return "MR"
        case .behavioralSource: return "B"
        case .probe: return "P"
        case .ammeter: return "A"
        case .loopProbe: return "LP"
        case .speaker: return "SPK"
        case .microphone, .electretMic: return "MIC"
        case .pickup: return "PU"
        case .instrumentationAmp, .lineReceiver, .lineDriver, .audioPowerAmp, .compander, .toneControl, .levelDetector,
             .barGraphDriver, .balancedModulator, .mixerOscillator, .functionGenerator, .nortonAmp, .bbdClock, .multiTapDelay,
             .effectsProcessor, .reverbBrick, .agcPreamp, .analogEngine: return "U"
        case .footswitch: return "S"
        case .jack: return "J"
        case .regulator: return "U"
        case .tappedTransformer: return "T"
        case .springReverb: return "RT"
        case .balancedCable: return "CBL"
        case .vuMeter: return "M"
        case .port: return "PORT"
        case .block: return "X"
        }
    }

    public var category: ElementCategory {
        switch self {
        case .wire, .ground, .netLabel, .resistor, .potentiometer, .lamp, .capacitor, .inductor: return .basics
        case .dcVoltage, .acVoltage, .squareVoltage, .noiseVoltage, .currentSource, .keyboardPitch, .keyboardGate, .audioInput: return .sources
        case .toggleSwitch, .pushButton: return .switches
        case .diode, .zener, .led, .npn, .pnp, .nmos, .pmos, .njfet, .pjfet: return .semiconductors
        case .triode, .pentode, .transformer: return .tubes
        case .opAmp, .ota, .multiplier, .comparator: return .amplifiers
        case .vco, .vcf, .envelope, .vca, .sampleHold, .divider: return .synth
        case .delayLine, .digitalDelay, .vactrol: return .effects
        case .timer555, .schmittInverter, .unbufferedInverter, .analogSwitch: return .timersAndLogic
        case .logicGate, .flipFlop, .decadeCounter, .binaryCounter, .shiftRegister, .shiftIn, .ledDriver, .ledSink, .i2cEeprom, .analogMux, .analogSelector, .pll, .dac, .dualDac, .spiAdc, .i2cDac, .i2sDac, .codec, .cvDac: return .timersAndLogic
        case .atmega328p, .atmega2560, .attiny85, .rp2040, .stm32f405, .stm32f373, .stm32f103: return .microcontrollers
        case .memristor: return .memristors
        case .behavioralSource: return .sources
        case .probe, .ammeter, .loopProbe, .speaker, .vuMeter: return .instruments
        case .microphone, .electretMic, .pickup, .instrumentationAmp, .lineReceiver, .lineDriver, .audioPowerAmp, .compander,
             .toneControl, .levelDetector, .springReverb, .agcPreamp, .barGraphDriver, .balancedCable, .balancedModulator, .mixerOscillator,
             .tappedTransformer: return .audio
        case .functionGenerator: return .synth
        case .nortonAmp: return .amplifiers
        case .bbdClock, .multiTapDelay, .effectsProcessor, .reverbBrick: return .effects
        case .analogEngine: return .audio
        case .footswitch, .jack: return .switches
        case .regulator: return .sources
        case .port, .block: return .blocks
        }
    }

    /// Single-key shortcut that selects this tool on the canvas
    public var shortcut: Character? {
        switch self {
        case .wire: return "w"
        case .ground: return "g"
        case .netLabel: return "h"
        case .resistor: return "r"
        case .potentiometer: return "t"
        case .lamp: return "y"
        case .capacitor: return "c"
        case .inductor: return "l"
        case .dcVoltage: return "v"
        case .acVoltage: return "a"
        case .squareVoltage: return "q"
        case .currentSource: return "i"
        case .keyboardPitch, .keyboardGate, .noiseVoltage, .audioInput: return nil
        case .toggleSwitch: return "s"
        case .pushButton: return "b"
        case .diode: return "d"
        case .zener: return "z"
        case .led: return "e"
        case .npn: return "j"
        case .pnp: return "k"
        case .nmos: return "n"
        case .pmos: return "p"
        case .opAmp: return "u"
        case .timer555: return "5"
        case .njfet, .pjfet, .ota, .schmittInverter, .unbufferedInverter, .analogSwitch, .multiplier, .delayLine, .digitalDelay, .vactrol,
             .triode, .pentode, .transformer:
            return nil
        case .comparator, .vco, .vcf, .envelope, .vca, .sampleHold, .divider, .atmega328p, .atmega2560, .attiny85, .rp2040, .stm32f405, .stm32f373, .stm32f103: return nil
        case .logicGate, .flipFlop, .decadeCounter, .binaryCounter, .shiftRegister, .shiftIn, .ledDriver, .ledSink, .i2cEeprom, .analogMux, .analogSelector, .pll, .dac, .dualDac, .spiAdc, .i2cDac, .i2sDac, .codec, .cvDac: return nil
        case .memristor: return "m"
        case .behavioralSource: return nil
        case .probe: return "o"
        case .ammeter: return "x"
        case .loopProbe, .speaker, .port, .block: return nil
        case .microphone, .electretMic, .pickup, .instrumentationAmp, .lineReceiver, .lineDriver, .audioPowerAmp, .compander,
             .toneControl, .levelDetector, .springReverb, .agcPreamp, .barGraphDriver, .balancedCable, .vuMeter, .balancedModulator,
             .mixerOscillator, .tappedTransformer, .functionGenerator, .nortonAmp, .bbdClock, .multiTapDelay, .effectsProcessor,
             .reverbBrick, .analogEngine, .footswitch, .jack, .regulator: return nil
        }
    }

    /// Shortcut with ⇧ for the parts without a single-key one, so every part can be picked from the keyboard
    public var shiftShortcut: Character? {
        switch self {
        case .njfet: return "j"
        case .ota: return "u"
        case .schmittInverter: return "i"
        case .analogSwitch: return "s"
        case .speaker: return "o"
        case .keyboardPitch: return "k"
        case .keyboardGate: return "g"
        case .noiseVoltage: return "n"
        case .audioInput: return "p"
        case .multiplier: return "x"
        case .delayLine: return "d"
        case .vactrol: return "v"
        case .vco: return "w"
        case .vcf: return "l"
        case .envelope: return "e"
        case .vca: return "a"
        case .sampleHold: return "h"
        case .comparator: return "c"
        case .divider: return "f"
        case .atmega328p: return "m"
        case .logicGate: return "b"
        case .decadeCounter: return "t"
        case .triode: return "q"
        case .transformer: return "r"
        default: return nil
        }
    }

    /// The shortcut as shown in menus and the library: "R", or "⇧U"
    public var shortcutLabel: String? {
        if let key = shortcut { return String(key).uppercased() }
        if let key = shiftShortcut { return "⇧" + String(key).uppercased() }
        return nil
    }

    /// Words a search for this part should find: its name, category and the real parts it models
    public var searchTerms: [String] {
        [displayName, category.rawValue] + models.flatMap { [$0.name] + $0.aliases }
    }

    /// The model with this name or one of its aliases, in any case
    public func model(named name: String) -> PartModel? {
        let name = name.lowercased()
        return models.first { $0.name.lowercased() == name } ?? models.first { $0.aliases.contains { $0.lowercased() == name } }
    }

    /// Three-terminal transistors drawn with their control terminal at `a` and their channel at `b`
    public var isTransistor: Bool { self == .nmos || self == .pmos || self == .npn || self == .pnp || isJFET }

    /// Junction field-effect transistors, N- and P-channel
    public var isJFET: Bool { self == .njfet || self == .pjfet }

    /// Vacuum tubes: drawn like a transistor (control grid at `a`, plate above `b` and cathode below it), in a glass
    /// envelope; a pentode's screen grid comes out at `b`
    public var isTube: Bool { self == .triode || self == .pentode }

    public var isBipolar: Bool { self == .npn || self == .pnp }
    /// A junction diode: a diode, a Zener diode or an LED (SPICE's diode)
    public var isDiode: Bool { self == .diode || self == .zener || self == .led }
    public var isMOSFET: Bool { self == .nmos || self == .pmos }

    /// Parts whose terminals depend on a direction, which stay horizontal or vertical
    public var isAxisAligned: Bool {
        isTransistor || self == .opAmp || self == .ota || self == .potentiometer || self == .timer555 || self == .analogSwitch
            || self == .multiplier || self == .delayLine || self == .vactrol || isModule || self == .comparator || isMicrocontroller
            || isLogic || self == .block || isTube || self == .transformer || audioChipPackage != nil
    }

    /// Parts offered in the library and the quick-add palette: a block is placed from the blocks the user has saved
    /// (a behavioural source comes from a netlist, with its expression, until one can be typed in)
    public var isPlaceable: Bool { self != .block && self != .behavioralSource }

    /// Parts that can be mirrored across their axis
    public var canFlip: Bool { isAxisAligned }

    /// Length in grid units of parts whose size is fixed (their terminals sit at set places around the body)
    public var fixedLength: Int? {
        switch self {
        case .nmos, .pmos, .npn, .pnp, .njfet, .pjfet, .triode, .pentode: return 2
        case .ota, .vactrol, .transformer: return 4
        case .timer555: return 5
        case .atmega328p, .atmega2560, .attiny85, .rp2040, .stm32f405, .stm32f373, .stm32f103: return board?.length
        case .flipFlop, .decadeCounter, .binaryCounter, .shiftRegister, .shiftIn, .ledDriver, .ledSink, .i2cEeprom, .analogMux, .analogSelector, .pll, .dac, .dualDac, .spiAdc, .i2cDac, .i2sDac, .codec, .cvDac: return chipPackage?.length
        default: return audioChipPackage?.length
        }
    }

    /// Names of the terminals, in the order of `Element.posts`, for netlists and automation
    public var terminalNames: [String] {
        switch self {
        case .ground: return ["gnd"]
        case .netLabel, .port: return ["net"]
        case .block: return []
        case .dcVoltage, .acVoltage, .squareVoltage, .noiseVoltage, .currentSource, .keyboardPitch, .keyboardGate, .audioInput:
            return ["minus", "plus"]
        case .diode, .zener, .led: return ["anode", "cathode"]
        case .probe, .speaker: return ["plus", "minus"]
        case .ammeter, .loopProbe: return ["in", "out"]
        case .nmos, .pmos, .njfet, .pjfet: return ["gate", "drain", "source"]
        case .triode: return ["grid", "plate", "cathode"]
        case .pentode: return ["grid", "plate", "cathode", "screen"]
        case .transformer: return ["p1", "p2", "s1", "s2"]
        case .npn, .pnp: return ["base", "collector", "emitter"]
        case .potentiometer: return ["a", "b", "wiper"]
        case .analogSwitch: return ["a", "b", "control"]
        case .opAmp: return ["minus", "plus", "out"]
        case .multiplier: return ["x", "y", "out"]
        case .delayLine: return ["in", "ctrl", "out"]
        case .digitalDelay: return ["in", "time", "out"]
        case .comparator: return ["minus", "plus", "out"]
        case .vco: return ["cv", "pw", "out"]
        case .vcf: return ["in", "cv", "out"]
        case .envelope: return ["gate", "trig", "out"]
        case .vca: return ["in", "cv", "out"]
        case .sampleHold: return ["in", "trig", "out"]
        case .divider: return ["clock", "reset", "out"]
        case .vactrol: return ["anode", "cathode", "a", "b"]
        case .ota: return ["minus", "plus", "out", "bias"]
        case .timer555: return ["gnd", "trig", "out", "reset", "ctrl", "thr", "dis", "vcc"]
        case .atmega328p, .atmega2560, .attiny85, .rp2040, .stm32f405, .stm32f373, .stm32f103: return board?.terminalNames ?? []
        case .schmittInverter, .unbufferedInverter: return ["in", "out"]
        case .logicGate: return ["in1", "in2", "out"]
        case .flipFlop, .decadeCounter, .binaryCounter, .shiftRegister, .shiftIn, .ledDriver, .ledSink, .i2cEeprom, .analogMux, .analogSelector, .pll, .dac, .dualDac, .spiAdc, .i2cDac, .i2sDac, .codec, .cvDac: return chipPackage?.terminalNames ?? []
        case .electretMic: return ["out", "gnd"]
        case .pickup: return ["hot", "gnd"]
        case .vuMeter: return ["plus", "minus"]
        case .levelDetector: return ["in", "ref", "out"]
        case .springReverb, .agcPreamp: return ["in", "gnd", "out"]
        default: return audioChipPackage?.terminalNames ?? ["a", "b"]
        }
    }

    /// Parts that switch between discrete states (a 555's flip-flop, a Schmitt trigger's output, CMOS logic)
    public var isDigital: Bool { self == .timer555 || self == .schmittInverter || isLogic }

    public var isVoltageSource: Bool {
        self == .dcVoltage || self == .acVoltage || self == .squareVoltage || self == .noiseVoltage || isKeyboard || self == .audioInput
    }

    /// Sources played from the computer keyboard or a MIDI keyboard
    public var isKeyboard: Bool { self == .keyboardPitch || self == .keyboardGate }

    public var isSwitch: Bool { self == .toggleSwitch || self == .pushButton || self == .footswitch || self == .jack }

    /// Parts whose output (the third terminal) is driven like a voltage source to ground: op-amps, multipliers, BBDs,
    /// comparators and the synth chips
    public var drivesOutput: Bool { self == .opAmp || self == .multiplier || self == .delayLine || self == .comparator || isModule }

    /// Synth chips and the delay line: blocks whose output is worked out from their inputs once per step (an oscillator's
    /// phase, an envelope's stage, a held sample), with two inputs either side of `a` and the output at `b`
    public var isModule: Bool {
        switch self {
        case .delayLine, .digitalDelay, .vco, .vcf, .envelope, .vca, .sampleHold, .divider, .levelDetector, .springReverb, .agcPreamp: return true
        default: return false
        }
    }

    /// Koren's constants for a tube, then the capacitances between its electrodes
    static func tubeParams(mu: Double, ex: Double, kg1: Double, kg2: Double?, kp: Double, kvb: Double, rgi: Double,
                           cgk: Double, cgp: Double, cpk: Double) -> [ParamSpec] {
        var specs = [
            ParamSpec("mu", "Amplification factor (µ)", unit: "", default: mu, range: 1...200),
            ParamSpec("ex", "Exponent", unit: "", default: ex, range: 1...2, log: false),
            ParamSpec("kg1", "Plate current constant (kg1)", unit: "", default: kg1, range: 10...10_000),
        ]
        if let kg2 { specs.append(ParamSpec("kg2", "Screen current constant (kg2)", unit: "", default: kg2, range: 10...100_000)) }
        specs += [
            ParamSpec("kp", "Knee constant (kp)", unit: "", default: kp, range: 1...2000),
            ParamSpec("kvb", "Knee voltage constant (kvb)", unit: "V²", default: kvb, range: 0.1...10_000),
            ParamSpec("rgi", "Grid current resistance", unit: "Ω", default: rgi, range: 100...100_000),
            ParamSpec("cgk", "Grid–cathode capacitance", unit: "F", default: cgk, range: 0...1e-10, log: false),
            ParamSpec("cgp", "Grid–plate capacitance (Miller)", unit: "F", default: cgp, range: 0...1e-10, log: false),
            ParamSpec("cpk", "Plate–cathode capacitance", unit: "F", default: cpk, range: 0...1e-10, log: false),
        ]
        return specs
    }

    /// Offset of the second point when the element is placed with a single click
    public var defaultOffset: GridPoint {
        switch self {
        case .ground: return GridPoint(0, 1)
        case .netLabel, .port: return GridPoint(1, 0)
        case .nmos, .pmos, .npn, .pnp, .njfet, .pjfet, .triode, .pentode: return GridPoint(2, 0)
        case .timer555: return GridPoint(0, 5)
        case .atmega328p, .atmega2560, .attiny85, .rp2040, .stm32f405, .stm32f373, .stm32f103: return GridPoint(0, board?.length ?? 13)
        case .flipFlop, .decadeCounter, .binaryCounter, .shiftRegister, .shiftIn, .ledDriver, .ledSink, .i2cEeprom, .analogMux, .analogSelector, .pll, .dac, .dualDac, .spiAdc, .i2cDac, .i2sDac, .codec, .cvDac: return GridPoint(0, chipPackage?.length ?? 3)
        default: return audioChipPackage.map { GridPoint(0, $0.length) } ?? GridPoint(4, 0)
        }
    }

    public var params: [ParamSpec] {
        switch self {
        case .wire, .ground, .netLabel, .toggleSwitch, .pushButton, .probe, .ammeter, .loopProbe, .block:
            return []
        case .port:
            return [.choice("side", "Side of the block", ["Where it is drawn", "Left (input)", "Right (output)"])]
        case .speaker:
            return [ParamSpec("fullScale", "Full-scale voltage", unit: "V", default: 5, range: 0.1...50)] + ElementKind.loudspeakerParams
        case .microphone, .electretMic, .pickup, .instrumentationAmp, .lineReceiver, .lineDriver, .audioPowerAmp, .compander,
             .toneControl, .levelDetector, .springReverb, .agcPreamp, .barGraphDriver, .balancedCable, .vuMeter, .balancedModulator,
             .mixerOscillator, .tappedTransformer, .functionGenerator, .nortonAmp, .bbdClock, .multiTapDelay, .effectsProcessor,
             .reverbBrick, .analogEngine, .footswitch, .jack, .regulator:
            return audioParams
        case .resistor:
            return [
                ParamSpec("resistance", "Resistance", unit: "Ω", default: 1000, range: 1...10_000_000),
                // a macromodel's resistors that stand for no real resistor (PSpice's T_ABS=-273.15, ngspice's noisy=0)
                ParamSpec("noiseless", "Thermal noise", unit: "", default: 0, range: 0...1, log: false,
                          choices: [ParamChoice(name: "Noisy", value: 0), ParamChoice(name: "Noiseless", value: 1)], advanced: true),
                // what part stress checks its average power against
                ParamSpec("ratedPower", "Rated power", unit: "W", default: 0.25, range: 0.0625...100),
            ]
        case .potentiometer:
            return [
                ParamSpec("resistance", "Resistance", unit: "Ω", default: 10_000, range: 10...10_000_000),
                ParamSpec("position", "Wiper position", unit: "", default: 0.5, range: 0...1, log: false),
                ParamSpec("taper", "Taper (0 linear, 1 audio)", unit: "", default: 0, range: 0...1, log: false),
            ]
        case .zener:
            return [
                ParamSpec("breakdown", "Breakdown voltage (BV)", unit: "V", default: 5.1, range: 1...50, log: false),
                ParamSpec("cj0", "Junction capacitance at 0 V (CJO)", unit: "F", default: 1e-12, range: 0...1e-9, log: false),
                ParamSpec("saturationCurrent", "Saturation current (IS)", unit: "A", default: 1e-14, range: 1e-18...1e-6, advanced: true),
                ParamSpec("emission", "Emission coefficient (N)", unit: "", default: 1, range: 0.5...3, log: false, advanced: true),
                ParamSpec("tt", "Transit time (TT)", unit: "s", default: 0, range: 0...1e-4, log: false, advanced: true),
                ParamSpec("ibv", "Current at the breakdown voltage (IBV)", unit: "A", default: 5e-3, range: 1e-9...1, advanced: true),
            ] + Self.diodeCardParams
        case .npn, .pnp:
            return [
                ParamSpec("beta", "Current gain (BF)", unit: "", default: 100, range: 5...1000),
                ParamSpec("saturationCurrent", "Saturation current (IS)", unit: "A", default: 1e-14, range: 1e-17...1e-5),
                ParamSpec("cje", "Base–emitter capacitance at 0 V (CJE)", unit: "F", default: 1e-12, range: 0...1e-9, log: false),
                ParamSpec("cjc", "Base–collector capacitance at 0 V (CJC)", unit: "F", default: 1e-12, range: 0...1e-9, log: false),
                ParamSpec("tf", "Forward transit time (TF)", unit: "s", default: 0, range: 0...1e-6, log: false),
            ] + Self.gummelPoonParams
        case .multiplier:
            return [
                ParamSpec("scale", "Scale (out = scale · x · y)", unit: "1/V", default: 0.1, range: 0.01...1),
                ParamSpec("limit", "Output swing", unit: "V", default: 11, range: 1...15, log: false),
            ]
        case .comparator:
            return [
                ParamSpec("high", "Output high", unit: "V", default: 5, range: -15...15, log: false),
                ParamSpec("low", "Output low", unit: "V", default: 0.1, range: -15...15, log: false),
                ParamSpec("hysteresis", "Hysteresis", unit: "V", default: 0.01, range: 0...1, log: false),
            ]
        case .vco:
            return [
                .choice("waveform", "Waveform", ["Saw", "Triangle", "Pulse", "Sine"]),
                ParamSpec("frequency", "Frequency at 0 V", unit: "Hz", default: 65.406, range: 0.1...20_000),
                ParamSpec("amplitude", "Amplitude (peak)", unit: "V", default: 5, range: 0.1...12, log: false),
                .choice("response", "Control", ["1 V/octave from CV, pulse width from PW", "Linear: Hz per volt from CV to PW"]),
                ParamSpec("hzPerVolt", "Linear: frequency per volt", unit: "Hz/V", default: 1000, range: 1e-3...1e9),
            ]
        case .vcf:
            return [
                ParamSpec("cutoff", "Cutoff at 0 V", unit: "Hz", default: 200, range: 5...20_000),
                ParamSpec("resonance", "Resonance (1: self-oscillates)", unit: "", default: 0.3, range: 0...1.1, log: false),
                ParamSpec("drive", "Input level for soft clipping", unit: "V", default: 5, range: 0.5...20),
            ]
        case .envelope:
            return [
                ParamSpec("attack", "Attack time", unit: "s", default: 0.005, range: 1e-4...10),
                ParamSpec("decay", "Decay time", unit: "s", default: 0.3, range: 1e-3...20),
                ParamSpec("sustain", "Sustain level", unit: "", default: 0.5, range: 0...1, log: false),
                ParamSpec("release", "Release time", unit: "s", default: 0.4, range: 1e-3...20),
                ParamSpec("peak", "Peak voltage", unit: "V", default: 5, range: 0.5...12, log: false),
            ]
        case .vca:
            return [
                .choice("response", "Response", ["Exponential", "Linear"]),
                ParamSpec("dbPerVolt", "Exponential: dB per volt", unit: "dB/V", default: -30.3, range: -100...100, log: false),
                ParamSpec("unity", "Linear: control for unity gain", unit: "V", default: 5, range: 0.5...12, log: false),
                ParamSpec("limit", "Output swing", unit: "V", default: 12, range: 1...15, log: false),
                ParamSpec("cvOffset", "Control offset (the control voltage for unity gain, exponential)", unit: "V", default: 0,
                          range: -10...10, log: false),
            ]
        case .sampleHold:
            return [
                .choice("mode", "Mode", ["Sample on each rising edge", "Track while high, hold while low"]),
                ParamSpec("droop", "Droop", unit: "V/s", default: 0, range: 0...10, log: false),
            ]
        case .divider:
            let divisions: [Double] = [2, 3, 4, 5, 6, 8, 10, 16]
            return [
                ParamSpec("division", "Divide by", unit: "", default: 2, range: 2...16, log: false,
                          choices: divisions.map { ParamChoice(name: "÷\(Int($0))", value: $0) }),
                ParamSpec("supply", "Supply (output high)", unit: "V", default: 5, range: 3...18, log: false),
            ]
        case .delayLine:
            return [
                ParamSpec("stages", "Stages", unit: "", default: 1024, range: 64...8192),
                ParamSpec("clock", "Clock at 0 V", unit: "Hz", default: 40_000, range: 1000...200_000),
                ParamSpec("clockPerVolt", "Clock per volt of control", unit: "Hz", default: 10_000, range: 0...100_000, log: false),
                ParamSpec("gain", "Gain", unit: "", default: 1, range: 0...2, log: false),
                .choice("clocking", "Clock", ["Its own, set by the control voltage",
                                              "From its clock pin (an MN3101 or other clock driver on CTRL)"]),
            ]
        case .digitalDelay:
            return [
                ParamSpec("shortest", "Delay with pin 6 at 0 Ω", unit: "s", default: 0.0242, range: 0.005...0.2),
                ParamSpec("delayPerKilohm", "Delay per kΩ from pin 6 to ground", unit: "s", default: 0.0115, range: 0.001...0.1),
                ParamSpec("gain", "Echo level", unit: "", default: 1, range: 0...2, log: false),
                ParamSpec("limit", "Output swing", unit: "V", default: 2, range: 0.5...6, log: false),
                ParamSpec("noise", "Converter noise at 100 ms (RMS)", unit: "V", default: 0.002, range: 0...0.05, log: false),
            ]
        case .vactrol:
            return [
                ParamSpec("ron", "Resistance at the reference current", unit: "Ω", default: 1500, range: 10...1e6),
                ParamSpec("iref", "Reference LED current", unit: "A", default: 0.01, range: 1e-4...0.05),
                ParamSpec("roff", "Dark resistance", unit: "Ω", default: 1e7, range: 1e4...1e9),
                ParamSpec("gamma", "Slope (resistance vs. current)", unit: "", default: 0.75, range: 0.3...1.5, log: false),
                ParamSpec("attack", "Attack time", unit: "s", default: 0.0025, range: 1e-6...1),
                ParamSpec("decay", "Decay time", unit: "s", default: 0.035, range: 1e-6...10),
            ]
        case .opAmp:
            return [
                ParamSpec("gain", "Open-loop gain", unit: "", default: 1_000_000, range: 10...10_000_000),
                ParamSpec("limit", "Output swing", unit: "V", default: 15, range: 1...50, log: false),
                ParamSpec("slewRate", "Slew rate (0: unlimited)", unit: "V/µs", default: 0, range: 0...100, log: false),
                ParamSpec("gbw", "Gain-bandwidth", unit: "Hz", default: 1e9, range: 1e4...1e10),
                ParamSpec("offset", "Input offset", unit: "V", default: 1e-6, range: -0.01...0.01, log: false),
                ParamSpec("noise", "Input noise voltage", unit: "V/√Hz", default: 0, range: 0...1e-6, log: false),
                ParamSpec("midpoint", "Middle of the output swing (a single supply's half)", unit: "V", default: 0, range: -25...25, log: false),
            ]
        case .ota:
            return [
                ParamSpec("supply", "Supply (±)", unit: "V", default: 15, range: 3...18, log: false),
                ParamSpec("biasDrop", "Bias pin junctions", unit: "", default: 2, range: 1...2, log: false),
                ParamSpec("headroom", "Output headroom", unit: "V", default: 1.5, range: 0.1...5, log: false),
            ]
        case .atmega328p:
            // (the chips the Uno's socket takes: the 328P, or the 168 and 88, with less memory)
            return Self.avrParams + [
                ParamSpec.choice("chip", "Chip", ["ATmega328P", "ATmega168", "ATmega88"]),
                ParamSpec("clock", "Clock (16 MHz on an Uno, 20 MHz in Mutable Instruments' modules)", unit: "Hz", default: 16e6,
                          range: 1e6...20e6),
            ]
        case .atmega2560, .attiny85:
            return Self.avrParams
        case .rp2040:
            // 4 mA drive (the pads' default); pull-ups and pull-downs of about 50 kΩ
            return [
                ParamSpec("supply", "Supply", unit: "V", default: 3.3, range: 1.8...3.6, log: false),
                ParamSpec("outputResistance", "Pin output resistance", unit: "Ω", default: 50, range: 1...1000),
                ParamSpec("pullUp", "Pull-up and pull-down resistance", unit: "Ω", default: 50_000, range: 30_000...80_000),
            ]
        case .stm32f405, .stm32f373, .stm32f103:
            // its pads' drive at 3.3 V (8 mA within 0.4 V); pull-ups and pull-downs of about 40 kΩ
            return [
                ParamSpec("supply", "Supply", unit: "V", default: 3.3, range: 1.8...3.6, log: false),
                ParamSpec("outputResistance", "Pin output resistance", unit: "Ω", default: 40, range: 1...1000),
                ParamSpec("pullUp", "Pull-up and pull-down resistance", unit: "Ω", default: 40_000, range: 30_000...50_000),
            ]
        case .timer555:
            return [
                ParamSpec("highDrop", "Output high drop", unit: "V", default: 1.7, range: 0...3, log: false),
                ParamSpec("outputResistance", "Output resistance", unit: "Ω", default: 10, range: 1...1000),
                ParamSpec("dischargeResistance", "Discharge resistance", unit: "Ω", default: 15, range: 1...1000),
            ]
        case .schmittInverter:
            return [
                ParamSpec("supply", "Supply", unit: "V", default: 12, range: 2...18, log: false),
                ParamSpec("upper", "Upper threshold", unit: "× supply", default: 0.6, range: 0.3...0.9, log: false),
                ParamSpec("lower", "Lower threshold", unit: "× supply", default: 0.38, range: 0.1...0.7, log: false),
                ParamSpec("outputResistance", "Output resistance", unit: "Ω", default: 400, range: 1...10_000),
            ]
        case .analogSwitch:
            return [
                ParamSpec("onResistance", "On resistance", unit: "Ω", default: 125, range: 1...10_000),
                ParamSpec("supply", "Logic supply", unit: "V", default: 12, range: 2...18, log: false),
            ]
        case .logicGate:
            return [ParamSpec.choice("function", "Function", Logic.gateFunctions)] + Self.logicParams(upper: 0.59, lower: 0.39)
        case .flipFlop, .decadeCounter, .binaryCounter:
            return Self.logicParams(upper: 0.52, lower: 0.48)
        case .ledDriver:
            return [
                ParamSpec("supply", "Supply (VDD)", unit: "V", default: 3.3, range: 2.3...5.5, log: false),
                ParamSpec("upper", "Input rising threshold", unit: "× supply", default: 0.7, range: 0.3...0.9, log: false),
                ParamSpec("lower", "Input falling threshold", unit: "× supply", default: 0.3, range: 0.1...0.7, log: false),
                ParamSpec("outputResistance", "Output resistance", unit: "Ω", default: 25, range: 1...10_000),
            ]
        case .i2cEeprom:
            return [
                ParamSpec("supply", "Supply (VCC)", unit: "V", default: 3.3, range: 1.7...5.5, log: false),
                ParamSpec("size", "Size", unit: "B", default: 32768, range: 256...131_072),
                ParamSpec("page", "Page size", unit: "B", default: 64, range: 8...256),
                ParamSpec("writeTime", "Write cycle time", unit: "s", default: 0.005, range: 0...0.02, log: false),
            ]
        case .ledSink:
            return [
                ParamSpec("supply", "Supply (VCC)", unit: "V", default: 3.3, range: 3...5.5, log: false),
                ParamSpec("upper", "Input rising threshold", unit: "× supply", default: 0.7, range: 0.3...0.9, log: false),
                ParamSpec("lower", "Input falling threshold", unit: "× supply", default: 0.3, range: 0.1...0.7, log: false),
                ParamSpec("outputResistance", "SOUT output resistance", unit: "Ω", default: 50, range: 1...10_000),
                ParamSpec("iref", "IREF resistor (each output sinks 41 × 1.2 V over it)", unit: "Ω", default: 3300, range: 1640...25_000),
            ]
        case .shiftIn:
            return [
                ParamSpec("supply", "Supply", unit: "V", default: 3.3, range: 2...6, log: false),
                ParamSpec("upper", "Input rising threshold", unit: "× supply", default: 0.7, range: 0.3...0.9, log: false),
                ParamSpec("lower", "Input falling threshold", unit: "× supply", default: 0.3, range: 0.1...0.7, log: false),
                ParamSpec("outputResistance", "Output resistance", unit: "Ω", default: 50, range: 1...10_000),
            ]
        case .shiftRegister:
            return [.choice("type", "Chip", ["CD4015 (one half): four stages, reset high",
                                             "74HC595: eight stages and a latch, clear low, outputs on while OE is low"])]
                + Self.logicParams(upper: 0.52, lower: 0.48)
        case .pll:
            return [
                ParamSpec("fMin", "VCO frequency at 0 V", unit: "Hz", default: 100, range: 0.1...1_000_000),
                ParamSpec("fMax", "VCO frequency at the supply", unit: "Hz", default: 2000, range: 1...2_000_000),
            ] + Self.logicParams(upper: 0.52, lower: 0.48)
        case .dac, .dualDac, .spiAdc, .i2cDac:
            let converter = [
                ParamSpec("supply", "Supply (VDD)", unit: "V", default: 5, range: 2.7...5.5, log: false),
                ParamSpec("upper", "Input rising threshold", unit: "× supply", default: 0.7, range: 0.3...0.9, log: false),
                ParamSpec("lower", "Input falling threshold", unit: "× supply", default: 0.2, range: 0.1...0.7, log: false),
                ParamSpec("outputResistance", "Output resistance", unit: "Ω", default: 10, range: 0.1...1000),
            ]
            // (the MCP3008's ten bits, or the MCP3204's and MCP3208's twelve, in the same frame)
            return self == .spiAdc ? converter + [ParamSpec.choice("resolution", "Resolution", ["10 bits (MCP3008)", "12 bits (MCP3204, MCP3208)"])]
                                   : converter
        case .i2sDac:
            return [
                ParamSpec("supply", "Supply (DVDD)", unit: "V", default: 3.3, range: 1.6...3.6, log: false),
                ParamSpec("upper", "Input rising threshold", unit: "× supply", default: 0.7, range: 0.3...0.9, log: false),
                ParamSpec("lower", "Input falling threshold", unit: "× supply", default: 0.3, range: 0.1...0.7, log: false),
                ParamSpec("outputResistance", "Output resistance", unit: "Ω", default: 100, range: 0.1...1000),
            ]
        case .cvDac:
            return [
                ParamSpec("supply", "Supply (AVDD)", unit: "V", default: 5, range: 2.7...5.5, log: false),
                ParamSpec("fullScale", "Full scale", unit: "V", default: 5, range: 0.5...5.5, log: false),
                ParamSpec("outputResistance", "Output resistance", unit: "Ω", default: 1, range: 0.1...1000),
                ParamSpec.choice("format", "Word format", ["DAC8568 (I²S: 32-bit words, one each frame's left half)", "DAC8564 (I²S: 24-bit words, every word)",
                                                           "DAC8552 (SPI: 24-bit words)", "DAC8551 (SPI: 24-bit words)", "DAC7554 (SPI: 16-bit words, 12-bit codes)"]),
            ]
        case .codec:
            // its line outputs and inputs about VMID (half its analog supply), as a module's board AC-couples them
            return [
                ParamSpec("supply", "Supply (AVDD)", unit: "V", default: 3.3, range: 2.7...5.5, log: false),
                ParamSpec("fullScale", "Line level at full scale", unit: "V RMS", default: 1, range: 0.1...2, log: false),
                ParamSpec("outputResistance", "Line output resistance", unit: "Ω", default: 100, range: 0.1...10_000),
                ParamSpec("address", "I²C address of its control port (0: set up by its pins)", unit: "", default: 0x1A, range: 0...127,
                          log: false),
            ]
        case .unbufferedInverter:
            return [
                ParamSpec("supply", "Supply", unit: "V", default: 9, range: 3...18, log: false),
                ParamSpec("threshold", "Transistor threshold", unit: "V", default: 1.5, range: 0.5...3, log: false),
                ParamSpec("beta", "Transistor beta", unit: "A/V²", default: 4e-4, range: 1e-5...0.01),
                ParamSpec("lambda", "Channel-length modulation (sets the gain)", unit: "1/V", default: 0.03, range: 0.001...0.2),
            ]
        case .analogMux, .analogSelector:
            return [ParamSpec("onResistance", "On resistance", unit: "Ω", default: 125, range: 1...10_000)]
                + Array(Self.logicParams(upper: 0.52, lower: 0.48).dropLast())
        case .njfet, .pjfet:
            return [
                ParamSpec("pinchOff", "Pinch-off voltage (VTO)", unit: "V", default: -1.5, range: -8...(-0.2), log: false),
                ParamSpec("idss", "Drain current with the gate at the source (IDSS)", unit: "A", default: 3e-3, range: 1e-5...0.1),
                ParamSpec("lambda", "Channel-length modulation (LAMBDA)", unit: "1/V", default: 0.01, range: 0...0.2, log: false),
                ParamSpec("cgs", "Gate-source capacitance at 0 V (CGS)", unit: "F", default: 0, range: 0...1e-10, log: false),
                ParamSpec("cgd", "Gate-drain capacitance at 0 V (CGD)", unit: "F", default: 0, range: 0...1e-10, log: false),
            ] + Self.jfetCardParams
        case .triode:
            return Self.tubeParams(mu: 100, ex: 1.4, kg1: 1060, kg2: nil, kp: 600, kvb: 300, rgi: 2000, cgk: 2.3e-12, cgp: 2.4e-12, cpk: 0.9e-12)
        case .pentode:
            return Self.tubeParams(mu: 8.7, ex: 1.35, kg1: 1460, kg2: 4500, kp: 48, kvb: 12, rgi: 1000, cgk: 14e-12, cgp: 0.85e-12, cpk: 12e-12)
        case .transformer:
            return [
                ParamSpec("inductance", "Primary inductance", unit: "H", default: 20, range: 1e-6...1000),
                ParamSpec("ratio", "Turns ratio (secondary ÷ primary)", unit: "", default: 0.0316228, range: 0.001...1000),
                ParamSpec("coupling", "Coupling (1: no leakage)", unit: "", default: 0.998, range: 0.5...1, log: false),
                ParamSpec("rp", "Primary winding resistance", unit: "Ω", default: 200, range: 0...100_000, log: false),
                ParamSpec("rs", "Secondary winding resistance", unit: "Ω", default: 0.4, range: 0...100_000, log: false),
                ParamSpec("saturation", "Core saturation: primary volt-seconds, Vpeak ÷ 2πf (0: never)", unit: "V·s", default: 0,
                          range: 0...100, log: false),
                ParamSpec("saturatedFraction", "Magnetising inductance left when saturated (fraction)", unit: "", default: 0.002,
                          range: 1e-5...1, advanced: true),
            ]
        case .lamp:
            return [
                ParamSpec("resistance", "Resistance", unit: "Ω", default: 100, range: 1...100_000),
                ParamSpec("ratedPower", "Rated power", unit: "W", default: 0.25, range: 0.001...100),
            ]
        case .capacitor:
            return [
                ParamSpec("capacitance", "Capacitance", unit: "F", default: 10e-6, range: 1e-12...1),
                ParamSpec("initialVoltage", "Initial voltage", unit: "V", default: 0, range: -50...50, log: false),
                // what part stress checks its voltage against (0: unrated, not checked)
                ParamSpec("ratedVoltage", "Rated voltage (0: not checked)", unit: "V", default: 0, range: 0...1000, log: false),
            ]
        case .inductor:
            return [
                ParamSpec("inductance", "Inductance", unit: "H", default: 1, range: 1e-9...100),
                ParamSpec("saturationCurrent", "Current where its core saturates (0: never)", unit: "A", default: 0, range: 0...100, log: false),
                ParamSpec("saturatedFraction", "Inductance left when saturated (fraction)", unit: "", default: 0.002, range: 1e-5...1,
                          advanced: true),
            ]
        case .dcVoltage:
            return [ParamSpec("voltage", "Voltage", unit: "V", default: 5, range: -24...24, log: false)]
        case .acVoltage:
            return [
                ParamSpec("amplitude", "Amplitude", unit: "V", default: 5, range: 0.001...1000),
                ParamSpec("frequency", "Frequency", unit: "Hz", default: 50, range: 0.01...1_000_000),
                ParamSpec("offset", "DC offset", unit: "V", default: 0, range: -24...24, log: false),
                ParamSpec("phase", "Phase", unit: "°", default: 0, range: 0...360, log: false),
            ]
        case .squareVoltage:
            return [
                ParamSpec("high", "High voltage", unit: "V", default: 5, range: -24...24, log: false),
                ParamSpec("low", "Low voltage", unit: "V", default: 0, range: -24...24, log: false),
                ParamSpec("frequency", "Frequency", unit: "Hz", default: 10, range: 0.01...1_000_000),
                ParamSpec("duty", "Duty cycle", unit: "", default: 0.5, range: 0.01...0.99, log: false),
            ]
        case .currentSource:
            return [ParamSpec("current", "Current", unit: "A", default: 0.01, range: 1e-6...10)]
        case .noiseVoltage:
            return [
                ParamSpec("amplitude", "RMS amplitude", unit: "V", default: 1, range: 0.001...10),
                .choice("type", "Kind", ["White (Gaussian)", "MM5837: digital, pseudo-random"]),
            ]
        case .audioInput:
            return [
                .choice("input", "Input", ["Sound file", "Live input (with sound on)"]),
                ParamSpec("level", "Peak voltage at full scale", unit: "V", default: 0.5, range: 0.001...10),
                .choice("loop", "Playback", ["Once", "Loop"], default: 1),
                ParamSpec("offset", "Offset", unit: "V", default: 0, range: -15...15, log: false),
            ]
        case .keyboardPitch:
            return [ParamSpec("glide", "Glide", unit: "s", default: 0, range: 0...2, log: false)]
        case .keyboardGate:
            return [ParamSpec("high", "Gate voltage", unit: "V", default: 5, range: 1...15, log: false)]
        case .diode:
            return [
                ParamSpec("saturationCurrent", "Saturation current (IS)", unit: "A", default: 1e-14, range: 1e-18...1e-6),
                ParamSpec("emission", "Emission coefficient (N)", unit: "", default: 1, range: 0.5...3, log: false),
                ParamSpec("cj0", "Junction capacitance at 0 V (CJO)", unit: "F", default: 1e-12, range: 0...1e-9, log: false),
                ParamSpec("tt", "Transit time, stored charge (TT)", unit: "s", default: 0, range: 0...1e-4, log: false),
                ParamSpec("bv", "Reverse breakdown voltage (BV, 0: none)", unit: "V", default: 0, range: 0...1000, log: false, advanced: true),
                ParamSpec("ibv", "Current at the breakdown voltage (IBV)", unit: "A", default: 1e-3, range: 1e-12...1, advanced: true),
            ] + Self.diodeCardParams
        case .led:
            return [
                ParamSpec("color", "Color", unit: "", default: 0, range: 0...4, log: false),
                ParamSpec("cj0", "Junction capacitance at 0 V (CJO)", unit: "F", default: 1e-12, range: 0...1e-9, log: false),
                ParamSpec("saturationCurrent", "Saturation current (IS, 0: from the color)", unit: "A", default: 0, range: 0...1e-6, log: false, advanced: true),
                ParamSpec("emission", "Emission coefficient (N)", unit: "", default: 2, range: 0.5...5, log: false, advanced: true),
                ParamSpec("tt", "Transit time (TT)", unit: "s", default: 0, range: 0...1e-4, log: false, advanced: true),
                ParamSpec("bv", "Reverse breakdown voltage (BV, 0: none)", unit: "V", default: 0, range: 0...100, log: false, advanced: true),
                ParamSpec("ibv", "Current at the breakdown voltage (IBV)", unit: "A", default: 1e-3, range: 1e-12...1, advanced: true),
            ] + Self.diodeCardParams
        case .nmos, .pmos:
            return [
                ParamSpec("threshold", "Threshold voltage (VTO)", unit: "V", default: 1.5, range: 0.1...5, log: false),
                ParamSpec("beta", "Beta (KP × W / L)", unit: "A/V²", default: 0.02, range: 1e-4...1),
                ParamSpec("lambda", "Channel-length modulation (LAMBDA)", unit: "1/V", default: 0.01, range: 0...0.2, log: false),
                ParamSpec("cgs", "Gate-source overlap capacitance (CGSO × W)", unit: "F", default: 0, range: 0...1e-8, log: false),
                ParamSpec("cgd", "Gate-drain overlap capacitance (CGDO × W)", unit: "F", default: 0, range: 0...1e-8, log: false),
            ] + Self.mosfetCardParams
        case .behavioralSource:
            return [ParamSpec("mode", "Sets (0: a current, 1: a voltage)", unit: "", default: 1, range: 0...1, log: false)]
        case .memristor:
            return [
                ParamSpec("ron", "On resistance", unit: "Ω", default: 1000, range: 1...10_000_000),
                ParamSpec("roff", "Off resistance", unit: "Ω", default: 10_000, range: 1...10_000_000),
                ParamSpec("von", "On threshold", unit: "V", default: 0.3, range: 0.01...10, log: false),
                ParamSpec("voff", "Off threshold", unit: "V", default: 0.3, range: 0.01...10, log: false),
                ParamSpec("tau", "Switching time", unit: "s", default: 0.05, range: 1e-7...100),
                ParamSpec("initialState", "Initial state", unit: "", default: 0, range: 0...1, log: false),
            ]
        }
    }
}

extension ElementKind {
    /// A CMOS part's supply, input thresholds and output resistance. Plain CMOS inputs switch at half the supply (with a
    /// little hysteresis, so noise on a slow edge does not make them chatter); Schmitt inputs further apart.
    static func logicParams(upper: Double, lower: Double) -> [ParamSpec] {
        [
            ParamSpec("supply", "Supply", unit: "V", default: 12, range: 3...18, log: false),
            ParamSpec("upper", "Input rising threshold", unit: "× supply", default: upper, range: 0.3...0.9, log: false),
            ParamSpec("lower", "Input falling threshold", unit: "× supply", default: lower, range: 0.1...0.7, log: false),
            ParamSpec("outputResistance", "Output resistance", unit: "Ω", default: 400, range: 1...10_000),
        ]
    }
}

/// One component on the schematic. Two-terminal parts run from `a` to `b`; a ground's terminal is `a` and `b` sets its
/// direction; a transistor's gate is at `a`, its channel at `b`, with drain and source two grid units either side of `b`.
public struct Element: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: ElementKind
    public var name: String
    public var a: GridPoint
    public var b: GridPoint
    public var params: [String: Double]
    /// Switch state
    public var closed: Bool
    /// Mirrored across its axis (transistors, op-amps, potentiometers)
    public var flipped: Bool
    /// A microcontroller's program: its source (an Arduino sketch) and the firmware compiled from it
    public var code: String?
    public var firmware: Data?
    /// A block part's circuit
    public var block: BlockDefinition?
    /// An audio input part's sound
    public var audio: AudioClip?

    public init(id: UUID = UUID(), kind: ElementKind, name: String = "", a: GridPoint, b: GridPoint,
                params: [String: Double] = [:], closed: Bool = false, flipped: Bool = false) {
        self.id = id
        self.kind = kind
        self.name = name
        self.a = a
        self.b = b
        self.params = params
        self.closed = closed
        self.flipped = flipped
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decode(ElementKind.self, forKey: .kind)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        a = try container.decode(GridPoint.self, forKey: .a)
        b = try container.decode(GridPoint.self, forKey: .b)
        params = try container.decodeIfPresent([String: Double].self, forKey: .params) ?? [:]
        closed = try container.decodeIfPresent(Bool.self, forKey: .closed) ?? false
        flipped = try container.decodeIfPresent(Bool.self, forKey: .flipped) ?? false
        code = try container.decodeIfPresent(String.self, forKey: .code)
        firmware = try container.decodeIfPresent(Data.self, forKey: .firmware)
        block = try container.decodeIfPresent(BlockDefinition.self, forKey: .block)
        audio = try container.decodeIfPresent(AudioClip.self, forKey: .audio)
    }

    /// How the part is drawn as a box with pins down its sides: a chip's, or a block's from its ports
    public var chipPackage: ChipPackage? {
        kind == .block ? block?.chipPackage : kind.chipPackage
    }

    /// Names of the terminals, in the order of `posts`: the kind's, or a block's ports'
    public var terminalNames: [String] {
        kind == .block ? (block?.terminalNames ?? []) : kind.terminalNames
    }

    /// Length in grid units of a part whose size is fixed
    public var fixedLength: Int? {
        kind == .block ? chipPackage?.length : kind.fixedLength
    }

    /// A parameter value, falling back to the kind's default
    /// Nodes of its own the part has, past its terminals: a bipolar transistor's internal base, collector and emitter,
    /// a diode's internal anode, and a JFET's or MOSFET's internal drain and source, behind their resistances
    var internalNodeCount: Int {
        kind.isBipolar ? GummelPoon.internalNodes(self) : kind.isDiode ? SpiceDiode.internalNodes(self)
            : kind.isJFET ? SpiceJFET.internalNodes(self) : kind.isMOSFET ? SpiceMOSFET.internalNodes(self) : 0
    }

    /// An op-amp that runs its maker's model, the block it carries (`MakerModelCatalog`), in place of JSpice's own
    /// equations: the block in its place, on ideal supplies (see `Circuit.flattened` and `MakerModels.rails`)
    public var runsMakerModel: Bool {
        kind == .opAmp && self[param: "makerModel"] >= 0.5 && block.flatMap(MakerModels.opAmpRoles) != nil
    }

    public subscript(param key: String) -> Double {
        get { params[key] ?? kind.params.first(where: { $0.key == key })?.defaultValue ?? 0 }
        set { params[key] = newValue }
    }

    /// Unit direction from `a` to `b` along the dominant axis
    var axisDirection: GridPoint {
        let dx = b.x - a.x
        let dy = b.y - a.y
        if dx == 0 && dy == 0 { return GridPoint(1, 0) }
        return abs(dx) >= abs(dy) ? GridPoint(dx.signum(), 0) : GridPoint(0, dy.signum())
    }

    /// Unit vector at right angles to the element's axis: "below" a left-to-right part, or "above" it when flipped
    public var perpendicular: GridPoint {
        let d = axisDirection
        let p = GridPoint(-d.y, d.x)
        return flipped ? p * -1 : p
    }

    /// Drain and source (collector and emitter) terminals of a transistor. N-type devices have their drain or collector
    /// on the side opposite `perpendicular`, P-type devices on the same side.
    public var transistorTerminals: (drain: GridPoint, source: GridPoint) {
        let up = b - perpendicular * 2
        let down = b + perpendicular * 2
        return kind == .nmos || kind == .npn || kind == .njfet || kind.isTube ? (up, down) : (down, up)
    }

    /// The potentiometer's wiper, two grid units to the side of its middle; also an analog switch's control input
    public var wiper: GridPoint {
        GridPoint((a.x + b.x) / 2, (a.y + b.y) / 2) - perpendicular * 2
    }

    /// The OTA's bias current input (I_abc), below the middle of its triangle
    public var biasInput: GridPoint {
        GridPoint((a.x + b.x) / 2, (a.y + b.y) / 2) + perpendicular * 2
    }

    /// A 555's pins, in pin-number order (GND, TRIG, OUT, RESET, CTRL, THR, DIS, VCC). The chip runs from `a` to `b`;
    /// DIS, THR, TRIG and CTRL are on the side of `perpendicular`, VCC, RESET, OUT and GND on the other.
    public var timerPins: [GridPoint] {
        let d = axisDirection
        func left(_ k: Int) -> GridPoint { a + d * k + perpendicular * 3 }
        func right(_ k: Int) -> GridPoint { a + d * k - perpendicular * 3 }
        return [right(4), left(3), right(3), right(2), left(4), left(2), left(1), right(1)]
    }

    /// A microcontroller's or logic chip's pins, down its two sides from `a` (the Uno's D0-D13 on the side opposite
    /// `perpendicular`, A0-A5 on the other)
    public var packagePins: [GridPoint] {
        let d = axisDirection
        return (chipPackage?.pinPlaces ?? []).map { a + d * $0.offset + perpendicular * ($0.second ? 3 : -3) }
    }

    /// Terminal positions: [a, b] for two-terminal parts, [a] for ground, [gate, drain, source] for MOSFETs,
    /// [base, collector, emitter] for bipolar transistors, [a, b, wiper] for potentiometers ([a, b, control] for analog
    /// switches), [−, +, output] for op-amps, [−, +, output, bias] for OTAs and the eight pins of a 555 in pin order
    public var posts: [GridPoint] {
        switch kind {
        case .ground, .netLabel, .port:
            return [a]
        case .nmos, .pmos, .npn, .pnp, .njfet, .pjfet, .triode:
            let t = transistorTerminals
            return [a, t.drain, t.source]
        case .pentode:
            let t = transistorTerminals
            return [a, t.drain, t.source, b]
        case .potentiometer, .analogSwitch:
            return [a, b, wiper]
        case .opAmp, .multiplier, .comparator, .delayLine, .digitalDelay, .vco, .vcf, .envelope, .vca, .sampleHold, .divider,
             .logicGate, .levelDetector, .springReverb, .agcPreamp:
            return [a - perpendicular, a + perpendicular, b]
        case .vactrol, .transformer:
            return [a - perpendicular, a + perpendicular, b - perpendicular, b + perpendicular]
        case .ota:
            return [a - perpendicular, a + perpendicular, b, biasInput]
        case .timer555:
            return timerPins
        case .atmega328p, .atmega2560, .attiny85, .rp2040, .stm32f405, .stm32f373, .stm32f103, .flipFlop, .decadeCounter, .binaryCounter, .shiftRegister, .shiftIn, .ledDriver, .ledSink, .i2cEeprom, .analogMux, .analogSelector, .pll, .dac, .dualDac, .spiAdc, .i2cDac, .i2sDac,
             .codec, .cvDac, .block:
            return packagePins
        default:
            return kind.audioChipPackage != nil ? packagePins : [a, b]
        }
    }

    /// All grid points the element occupies at its ends, for moving and bounds
    public var extentPoints: [GridPoint] {
        posts.count > 2 ? posts + [a, b] : [a, b]
    }

    /// An inductor whose core saturates (a nonlinear part: its current a function of its flux)
    public var saturates: Bool { kind == .inductor && self[param: "saturationCurrent"] > 0 }

    /// A behavioural source that sets a voltage (it has a current unknown of its own, as a voltage source does)
    public var setsBehavioralVoltage: Bool { kind == .behavioralSource && self[param: "mode"] >= 0.5 }

    /// The ideal transformer a transformer part is simulated with (see `Circuit.expandModels`)
    public var isTransformerCore: Bool { kind == .transformer && self[param: "core"] == 1 }

    /// Ideal conductors: their ends are the same node
    public var isConductor: Bool {
        kind == .wire || kind == .ammeter || (kind.isSwitch && kind != .footswitch && kind != .jack && closed)
    }

    /// The terminals that are one node: a conductor's two ends, each pole of a footswitch with the throw it is set to
    /// (the second, the effect, when pressed in; the first, the bypass, otherwise), or a jack's tip with the plug's
    /// tip when a cable is plugged in and with its normal lug when not
    public var joinedTerminals: [(Int, Int)] {
        if kind == .footswitch { return (0..<3).map { (3 * $0, 3 * $0 + (closed ? 2 : 1)) } }
        if kind == .jack { return [(0, closed ? 3 : 1)] }
        return isConductor ? [(0, 1)] : []
    }
}

/// A real part whose behaviour a generic symbol can take on: its parameter values.
public struct PartModel: Sendable, Hashable {
    public let name: String
    public let summary: String
    public let values: [String: Double]
    /// The same part under other names (another maker's, a newer grade, the quad of a dual; not a surface-mount
    /// version of a part named for its leaded one): found by them as by its name, which is the one kept
    public var aliases: [String] = []

    /// The name with the others it goes by: "TL072 / TL082"
    public var title: String { ([name] + aliases).joined(separator: " / ") }
}

extension ElementKind {
    /// The rest of a bipolar transistor's SPICE model card (the Gummel-Poon model): at their defaults, an Ebers-Moll
    /// transistor with a reverse gain of 1
    static let gummelPoonParams: [ParamSpec] = [
        ParamSpec("nf", "Forward emission coefficient (NF)", unit: "", default: 1, range: 0.5...3, log: false, advanced: true),
        ParamSpec("vaf", "Forward Early voltage (VAF, 0: none)", unit: "V", default: 0, range: 0...500, log: false, advanced: true),
        ParamSpec("ikf", "Forward knee current (IKF, 0: none)", unit: "A", default: 0, range: 0...10, log: false, advanced: true),
        ParamSpec("ise", "Base–emitter leakage current (ISE)", unit: "A", default: 0, range: 0...1e-6, log: false, advanced: true),
        ParamSpec("ne", "Base–emitter leakage emission (NE)", unit: "", default: 1.5, range: 1...4, log: false, advanced: true),
        ParamSpec("br", "Reverse current gain (BR)", unit: "", default: 1, range: 0.01...100, advanced: true),
        ParamSpec("nr", "Reverse emission coefficient (NR)", unit: "", default: 1, range: 0.5...3, log: false, advanced: true),
        ParamSpec("var", "Reverse Early voltage (VAR, 0: none)", unit: "V", default: 0, range: 0...500, log: false, advanced: true),
        ParamSpec("ikr", "Reverse knee current (IKR, 0: none)", unit: "A", default: 0, range: 0...10, log: false, advanced: true),
        ParamSpec("isc", "Base–collector leakage current (ISC)", unit: "A", default: 0, range: 0...1e-6, log: false, advanced: true),
        ParamSpec("nc", "Base–collector leakage emission (NC)", unit: "", default: 2, range: 1...4, log: false, advanced: true),
        ParamSpec("nkf", "High-injection exponent (NKF)", unit: "", default: 0.5, range: 0.1...1, log: false, advanced: true),
        ParamSpec("rb", "Base resistance (RB)", unit: "Ω", default: 0, range: 0...1000, log: false, advanced: true),
        ParamSpec("irb", "Current where the base resistance is halfway to RBM (IRB, 0: none)", unit: "A", default: 0, range: 0...1, log: false, advanced: true),
        ParamSpec("rbm", "Base resistance at high current (RBM, 0: RB)", unit: "Ω", default: 0, range: 0...1000, log: false, advanced: true),
        ParamSpec("re", "Emitter resistance (RE)", unit: "Ω", default: 0, range: 0...100, log: false, advanced: true),
        ParamSpec("rc", "Collector resistance (RC)", unit: "Ω", default: 0, range: 0...100, log: false, advanced: true),
        ParamSpec("vje", "Base–emitter junction potential (VJE)", unit: "V", default: 0.75, range: 0.3...1.2, log: false, advanced: true),
        ParamSpec("mje", "Base–emitter grading (MJE)", unit: "", default: 0.33, range: 0.1...0.9, log: false, advanced: true),
        ParamSpec("xtf", "Transit time bias coefficient (XTF)", unit: "", default: 0, range: 0...1000, log: false, advanced: true),
        ParamSpec("vtf", "Transit time dependence on VBC (VTF, 0: none)", unit: "V", default: 0, range: 0...100, log: false, advanced: true),
        ParamSpec("itf", "Transit time high-current knee (ITF)", unit: "A", default: 0, range: 0...10, log: false, advanced: true),
        ParamSpec("vjc", "Base–collector junction potential (VJC)", unit: "V", default: 0.75, range: 0.3...1.2, log: false, advanced: true),
        ParamSpec("mjc", "Base–collector grading (MJC)", unit: "", default: 0.33, range: 0.1...0.9, log: false, advanced: true),
        ParamSpec("xcjc", "Fraction of CJC at the internal base (XCJC)", unit: "", default: 1, range: 0...1, log: false, advanced: true),
        ParamSpec("tr", "Reverse transit time (TR)", unit: "s", default: 0, range: 0...1e-5, log: false, advanced: true),
        ParamSpec("fc", "Forward-bias depletion coefficient (FC)", unit: "", default: 0.5, range: 0...0.95, log: false, advanced: true),
        ParamSpec("xtb", "Gain temperature exponent (XTB)", unit: "", default: 0, range: 0...3, log: false, advanced: true),
        ParamSpec("eg", "Band gap (EG)", unit: "eV", default: 1.11, range: 0.5...1.5, log: false, advanced: true),
        ParamSpec("xti", "Saturation current temperature exponent (XTI)", unit: "", default: 3, range: 0...6, log: false, advanced: true),
        ParamSpec("kf", "Flicker noise coefficient (KF)", unit: "", default: 0, range: 0...1e-12, log: false, advanced: true),
        ParamSpec("af", "Flicker noise exponent (AF)", unit: "", default: 1, range: 0.5...2, log: false, advanced: true),
    ]

    /// The rest of a MOSFET's SPICE model card (level 1)
    static let mosfetCardParams: [ParamSpec] = [
        ParamSpec("rd", "Drain resistance (RD)", unit: "Ω", default: 0, range: 0...100, log: false, advanced: true),
        ParamSpec("rs", "Source resistance (RS)", unit: "Ω", default: 0, range: 0...100, log: false, advanced: true),
        ParamSpec("saturationCurrent", "Bulk junction saturation current (IS)", unit: "A", default: 1e-14, range: 1e-18...1e-6, advanced: true),
        ParamSpec("cbd", "Bulk-drain capacitance at 0 V (CBD)", unit: "F", default: 0, range: 0...1e-8, log: false, advanced: true),
        ParamSpec("cbs", "Bulk-source capacitance at 0 V (CBS)", unit: "F", default: 0, range: 0...1e-8, log: false, advanced: true),
        ParamSpec("pb", "Bulk junction potential (PB)", unit: "V", default: 0.8, range: 0.2...1.5, log: false, advanced: true),
        ParamSpec("mj", "Bulk junction grading coefficient (MJ)", unit: "", default: 0.5, range: 0.1...0.9, log: false, advanced: true),
        ParamSpec("fc", "Forward-bias depletion coefficient (FC)", unit: "", default: 0.5, range: 0...0.95, log: false, advanced: true),
        ParamSpec("cgb", "Gate-bulk overlap capacitance (CGBO × L)", unit: "F", default: 0, range: 0...1e-8, log: false, advanced: true),
        ParamSpec("cox", "Gate oxide capacitance, Meyer's model (from TOX, W and L)", unit: "F", default: 0, range: 0...1e-8, log: false, advanced: true),
        ParamSpec("gamma", "Body effect (GAMMA)", unit: "√V", default: 0, range: 0...3, log: false, advanced: true),
        ParamSpec("phi", "Surface potential (PHI)", unit: "V", default: 0.6, range: 0.2...1.2, log: false, advanced: true),
        ParamSpec("kf", "Flicker noise coefficient (KF)", unit: "", default: 0, range: 0...1e-12, log: false, advanced: true),
        ParamSpec("af", "Flicker noise exponent (AF)", unit: "", default: 1, range: 0.5...2, log: false, advanced: true),
    ]

    /// The rest of a JFET's SPICE model card
    static let jfetCardParams: [ParamSpec] = [
        ParamSpec("rd", "Drain resistance (RD)", unit: "Ω", default: 0, range: 0...1000, log: false, advanced: true),
        ParamSpec("rs", "Source resistance (RS)", unit: "Ω", default: 0, range: 0...1000, log: false, advanced: true),
        ParamSpec("saturationCurrent", "Gate saturation current (IS)", unit: "A", default: 1e-14, range: 1e-18...1e-6, advanced: true),
        ParamSpec("b", "Doping tail parameter (B)", unit: "", default: 1, range: 0.1...2, log: false, advanced: true),
        ParamSpec("pb", "Gate junction potential (PB)", unit: "V", default: 1, range: 0.2...1.5, log: false, advanced: true),
        ParamSpec("fc", "Forward-bias depletion coefficient (FC)", unit: "", default: 0.5, range: 0...0.95, log: false, advanced: true),
        ParamSpec("tcv", "Threshold temperature coefficient (TCV)", unit: "V/K", default: 0, range: -0.01...0.01, log: false, advanced: true),
        ParamSpec("bex", "Transconductance temperature exponent (BEX)", unit: "", default: 0, range: -3...3, log: false, advanced: true),
        ParamSpec("betatce", "Transconductance temperature coefficient (BETATCE)", unit: "%/K", default: 0, range: -2...2, log: false, advanced: true),
        ParamSpec("xti", "Gate saturation current temperature exponent (XTI)", unit: "", default: 0, range: 0...6, log: false, advanced: true),
        ParamSpec("eg", "Band gap (EG)", unit: "eV", default: 1.11, range: 0.5...3.5, log: false, advanced: true),
        ParamSpec("kf", "Flicker noise coefficient (KF)", unit: "", default: 0, range: 0...1e-12, log: false, advanced: true),
        ParamSpec("af", "Flicker noise exponent (AF)", unit: "", default: 1, range: 0.5...2, log: false, advanced: true),
    ]

    /// The rest of a diode's SPICE model card (diodes, Zener diodes and LEDs alike)
    static let avrParams: [ParamSpec] = [
        ParamSpec("supply", "Supply", unit: "V", default: 5, range: 1.8...5.5, log: false),
        ParamSpec("outputResistance", "Pin output resistance", unit: "Ω", default: 25, range: 1...1000),
        ParamSpec("pullUp", "Pull-up resistance", unit: "Ω", default: 35_000, range: 20_000...50_000),
    ]

    static let diodeCardParams: [ParamSpec] = [
        ParamSpec("rs", "Series resistance (RS)", unit: "Ω", default: 0, range: 0...100, log: false, advanced: true),
        ParamSpec("vj", "Junction potential (VJ)", unit: "V", default: 1, range: 0.2...1.5, log: false, advanced: true),
        ParamSpec("m", "Grading coefficient (M)", unit: "", default: 0.5, range: 0.1...0.9, log: false, advanced: true),
        ParamSpec("fc", "Forward-bias depletion coefficient (FC)", unit: "", default: 0.5, range: 0...0.95, log: false, advanced: true),
        ParamSpec("nbv", "Breakdown emission coefficient (NBV, 0: N)", unit: "", default: 0, range: 0...10, log: false, advanced: true),
        ParamSpec("ikf", "Forward knee current (IKF, 0: none)", unit: "A", default: 0, range: 0...100, log: false, advanced: true),
        ParamSpec("ikr", "Reverse knee current (IKR, 0: none)", unit: "A", default: 0, range: 0...100, log: false, advanced: true),
        ParamSpec("eg", "Band gap (EG)", unit: "eV", default: 1.11, range: 0.5...3.5, log: false, advanced: true),
        ParamSpec("xti", "Saturation current temperature exponent (XTI)", unit: "", default: 3, range: 0...6, log: false, advanced: true),
        ParamSpec("kf", "Flicker noise coefficient (KF)", unit: "", default: 0, range: 0...1e-12, log: false, advanced: true),
        ParamSpec("af", "Flicker noise exponent (AF)", unit: "", default: 1, range: 0.5...2, log: false, advanced: true),
    ]

    /// Real parts this symbol can behave like, chosen in the inspector; the first one matches the parameter defaults
    public var models: [PartModel] {
        switch self {
        case .opAmp:
            return [
                PartModel(name: "Ideal", summary: "Very high gain and bandwidth, no slew limit",
                          values: ["gain": 1e6, "limit": 15, "slewRate": 0, "gbw": 1e9, "offset": 1e-6, "noise": 0]),
                PartModel(name: "TL072", summary: "JFET input, the synth workhorse: 13 V/µs, 3 MHz",
                          values: ["gain": 2e5, "limit": 13.5, "slewRate": 13, "gbw": 3e6, "offset": 1e-3, "noise": 18e-9], aliases: ["TL082"]),
                PartModel(name: "LM358", summary: "Low power, slow: 0.3 V/µs, 1 MHz",
                          values: ["gain": 1e5, "limit": 13.5, "slewRate": 0.3, "gbw": 1e6, "offset": 2e-3, "noise": 40e-9]),
                PartModel(name: "NE5532", summary: "Low noise audio: 9 V/µs, 10 MHz",
                          values: ["gain": 1e5, "limit": 13, "slewRate": 9, "gbw": 10e6, "offset": 0.5e-3, "noise": 5e-9]),
                PartModel(name: "LM741", summary: "The classic: 0.5 V/µs, 1 MHz",
                          values: ["gain": 2e5, "limit": 13, "slewRate": 0.5, "gbw": 1e6, "offset": 1e-3, "noise": 20e-9]),
                PartModel(name: "NE5534", summary: "The single low-noise audio op-amp: 3.5 nV/√Hz, 13 V/µs, 10 MHz",
                          values: ["gain": 1e5, "limit": 13, "slewRate": 13, "gbw": 10e6, "offset": 0.5e-3, "noise": 3.5e-9]),
                PartModel(name: "OPA1612", summary: "Very low noise and distortion: 1.1 nV/√Hz, 27 V/µs, 40 MHz (dual)",
                          values: ["gain": 3e6, "limit": 13.5, "slewRate": 27, "gbw": 40e6, "offset": 0.1e-3, "noise": 1.1e-9]),
                PartModel(name: "LM4562", summary: "Audiophile dual: 2.7 nV/√Hz, 20 V/µs, 55 MHz",
                          values: ["gain": 1e7, "limit": 13.5, "slewRate": 20, "gbw": 55e6, "offset": 0.1e-3, "noise": 2.7e-9], aliases: ["LME49720"]),
                PartModel(name: "NJM4556", summary: "Headphone driver dual: 70 mA out, 3 V/µs, 8 MHz",
                          values: ["gain": 1e5, "limit": 13, "slewRate": 3, "gbw": 8e6, "offset": 0.5e-3, "noise": 8e-9]),
                PartModel(name: "TPA6120", summary: "Current-feedback headphone amp: 1300 V/µs, very wide band (SMD only)",
                          values: ["gain": 1e5, "limit": 13, "slewRate": 1300, "gbw": 250e6, "offset": 1e-3, "noise": 2.9e-9]),
                PartModel(name: "TDA2030", summary: "14 W power amp on ±16 V (Pentawatt, on a heat sink): 8 V/µs",
                          values: ["gain": 3e4, "limit": 14, "slewRate": 8, "gbw": 3e6, "offset": 2e-3, "noise": 10e-9]),
                PartModel(name: "LM1875", summary: "20 W power amp on ±25 V (TO-220, on a heat sink): 8 V/µs",
                          values: ["gain": 3e4, "limit": 23, "slewRate": 8, "gbw": 5.5e6, "offset": 1e-3, "noise": 3e-9]),
                PartModel(name: "LM3886", summary: "68 W Overture power amp on ±35 V (on a heat sink): 19 V/µs",
                          values: ["gain": 5e5, "limit": 32, "slewRate": 19, "gbw": 8e6, "offset": 1e-3, "noise": 2e-9]),
                PartModel(name: "JRC4558", summary: "Dual, the Tube Screamer's chip: bipolar, 1.7 V/µs, 3 MHz, a warm early roll-off",
                          values: ["gain": 1e5, "limit": 13, "slewRate": 1.7, "gbw": 3e6, "offset": 0.5e-3, "noise": 8e-9], aliases: ["NJM4558", "RC4558"]),
                PartModel(name: "LM308", summary: "Single, the ProCo RAT's chip: with 30 pF from pin 1 to 8 it slews at 0.3 V/µs, which is the RAT's grit",
                          values: ["gain": 3e5, "limit": 13, "slewRate": 0.3, "gbw": 1e6, "offset": 2e-3, "noise": 35e-9]),
                PartModel(name: "CA3130", summary: "Single CMOS op-amp, rail to rail on a single supply up to 16 V: fuzzes and synth envelopes",
                          values: ["gain": 3.2e5, "limit": 7, "slewRate": 10, "gbw": 15e6, "offset": 8e-3, "noise": 40e-9]),
                PartModel(name: "CA3140", summary: "Single MOSFET-input op-amp: near-zero input current, 9 V/µs, 4.5 MHz",
                          values: ["gain": 1e5, "limit": 13, "slewRate": 9, "gbw": 4.5e6, "offset": 5e-3, "noise": 40e-9]),
                PartModel(name: "TL074", summary: "Quad TL072: four JFET op-amps in one package, for filters and mixers",
                          values: ["gain": 2e5, "limit": 13.5, "slewRate": 13, "gbw": 3e6, "offset": 3e-3, "noise": 18e-9], aliases: ["TL084"]),
                PartModel(name: "TL064", summary: "Low-power quad JFET op-amp: 0.2 mA each, 3.5 V/µs, 1 MHz",
                          values: ["gain": 6e3, "limit": 13.5, "slewRate": 3.5, "gbw": 1e6, "offset": 3e-3, "noise": 42e-9]),
                PartModel(name: "OPA2134", summary: "Dual audio FET-input op-amp: 8 nV/√Hz, 20 V/µs, 8 MHz, very low distortion",
                          values: ["gain": 1e6, "limit": 13.5, "slewRate": 20, "gbw": 8e6, "offset": 0.5e-3, "noise": 8e-9]),
                PartModel(name: "LM833", summary: "Dual low-noise audio op-amp: 4.5 nV/√Hz, 7 V/µs, 15 MHz",
                          values: ["gain": 3e5, "limit": 13.5, "slewRate": 7, "gbw": 15e6, "offset": 0.3e-3, "noise": 4.5e-9]),
                PartModel(name: "OPA1656", summary: "CMOS audio dual, rail to rail out: 4.3 nV/√Hz, 24 V/µs, 53 MHz, very low distortion",
                          values: ["gain": 5e7, "limit": 14.75, "slewRate": 24, "gbw": 53e6, "offset": 0.5e-3, "noise": 4.3e-9]),
                PartModel(name: "OPA1642", summary: "JFET-input audio dual: 5.1 nV/√Hz, 20 V/µs, 11 MHz",
                          values: ["gain": 2e6, "limit": 14.65, "slewRate": 20, "gbw": 11e6, "offset": 1e-3, "noise": 5.1e-9], aliases: ["OPA1641", "OPA1644"]),
                PartModel(name: "OPA1678", summary: "Low-noise audio dual on 2 mA: 4.5 nV/√Hz, 9 V/µs, 16 MHz",
                          values: ["gain": 5e5, "limit": 14.2, "slewRate": 9, "gbw": 16e6, "offset": 0.5e-3, "noise": 4.5e-9], aliases: ["OPA1679"]),
                PartModel(name: "NJM2068", summary: "Low-noise audio dual, pin for pin a quieter 4558: 6 V/µs, 27 MHz (4ms's modules use it throughout)",
                          values: ["gain": 3e5, "limit": 13.5, "slewRate": 6, "gbw": 27e6, "offset": 0.3e-3, "noise": 3.3e-9]),
                PartModel(name: "OPA1652", summary: "CMOS audio dual, rail to rail out: 4.5 nV/√Hz, 10 V/µs, 18 MHz (the OPA1654 is the quad)",
                          values: ["gain": 1e6, "limit": 14.8, "slewRate": 10, "gbw": 18e6, "offset": 0.5e-3, "noise": 4.5e-9],
                          aliases: ["OPA1654"]),
                PartModel(name: "OPA2171", summary: "36 V dual, rail to rail out: 3 MHz, 1.5 V/µs, 0.25 mV; Mutable's modules buffer their CV outputs with it (the OPA4171 is the quad)",
                          values: ["gain": 3e6, "limit": 14.85, "slewRate": 1.5, "gbw": 3e6, "offset": 0.25e-3, "noise": 14e-9],
                          aliases: ["OPA171", "OPA4171"]),
                PartModel(name: "MCP6002", summary: "Rail-to-rail CMOS dual for 1.8 to 6 V, here on 3.3 V (its midpoint 1.65 V): 1 MHz, 0.6 V/µs. Mutable's modules scale their CV inputs into the microcontroller's ADC with it, its output kept within the 3.3 V rails (the MCP6004 is the quad)",
                          values: ["gain": 4e5, "limit": 1.625, "slewRate": 0.6, "gbw": 1e6, "offset": 1e-3, "noise": 28e-9, "midpoint": 1.65],
                          aliases: ["MCP6001", "MCP6004"]),
                PartModel(name: "LMV358", summary: "Low-voltage dual, rail to rail out, here on 3.3 V (its midpoint 1.65 V): 1 MHz, 1 V/µs (the LMV324 is the quad)",
                          values: ["gain": 1e5, "limit": 1.6, "slewRate": 1, "gbw": 1e6, "offset": 1.7e-3, "noise": 39e-9, "midpoint": 1.65],
                          aliases: ["LMV321", "LMV324"]),
            ]
        case .ota:
            return [
                PartModel(name: "LM13700", summary: "One half of the dual OTA; bias pin two junctions above V− (the NE5517 and LM13600 behave the same)",
                          values: ["supply": 15, "biasDrop": 2, "headroom": 1.5]),
                PartModel(name: "CA3080", summary: "The original OTA; bias pin one junction above V−",
                          values: ["supply": 15, "biasDrop": 1, "headroom": 1.5]),
            ]
        case .atmega328p:
            return [
                PartModel(name: "ATmega328P", summary: "The Arduino Uno's chip at 16 MHz: write a sketch, upload it, and it runs (Mutable Instruments' Grids runs one at 20 MHz)",
                          values: ["supply": 5, "chip": 0]),
                PartModel(name: "ATmega168", summary: "The 328P with 16 KB of flash and 1 KB of RAM (the Arduino Diecimila's chip; the 4ms Rotating Clock Divider's)",
                          values: ["supply": 5, "chip": 1]),
                PartModel(name: "ATmega88", summary: "The 328P with 8 KB of flash and 1 KB of RAM, its interrupt vectors a word each (Mutable Instruments' Branches)",
                          values: ["supply": 5, "chip": 2]),
            ]
        case .atmega2560:
            return [
                PartModel(name: "ATmega2560", summary: "The Arduino Mega's chip at 16 MHz: 70 pins, four serial ports, six timers",
                          values: ["supply": 5]),
            ]
        case .attiny85:
            return [
                PartModel(name: "ATtiny85", summary: "Eight pins and 8 KB at 8 MHz: six I/O pins, four analog inputs",
                          values: ["supply": 5]),
            ]
        case .rp2040:
            return [
                PartModel(name: "Raspberry Pi Pico", summary: "The RP2040 at 125 MHz with 2 MB of flash: 26 pins, three analog inputs, USB serial",
                          values: ["supply": 3.3]),
            ]
        case .stm32f103:
            return [
                PartModel(name: "STM32F103CB", summary: "Cortex-M3 at 72 MHz, 128 KB of flash and 20 KB of RAM: 35 pins, two 12-bit ADCs, two SPI ports, USART1 as its serial port; runs firmware built with its maker's tools",
                          values: ["supply": 3.3], aliases: ["STM32F103", "STM32F103C8", "STM32F103RB", "STM32F103RC"]),
            ]
        case .stm32f373:
            return [
                PartModel(name: "STM32F373RC", summary: "Cortex-M4 with its FPU at 72 MHz, 256 KB of flash and 32 KB of RAM: 53 pins, a 12-bit ADC and three 16-bit sigma-delta ADCs, I²S on SPI2 and SPI3, USART3 as its serial port; runs firmware built with its maker's tools",
                          values: ["supply": 3.3], aliases: ["STM32F373", "STM32F373CC", "STM32F373RB", "STM32F373CB"]),
            ]
        case .stm32f405:
            return [
                PartModel(name: "STM32F405RG", summary: "Cortex-M4 with its FPU at 168 MHz, 1 MB of flash and 192 KB of RAM: 49 pins, three 12-bit ADCs, two I²S ports, USART1 as its serial port; runs firmware built with its maker's tools",
                          values: ["supply": 3.3], aliases: ["STM32F405", "STM32F407"]),
            ]
        case .timer555:
            return [
                PartModel(name: "NE555", summary: "Bipolar: output high about 1.7 V below VCC",
                          values: ["highDrop": 1.7, "outputResistance": 10, "dischargeResistance": 15]),
                PartModel(name: "TLC555", summary: "CMOS: rail-to-rail output, weaker drive",
                          values: ["highDrop": 0.05, "outputResistance": 50, "dischargeResistance": 30]),
            ]
        case .schmittInverter:
            return [
                PartModel(name: "CD40106", summary: "One gate of the hex CMOS Schmitt inverter",
                          values: ["supply": 12, "upper": 0.6, "lower": 0.38, "outputResistance": 400]),
                PartModel(name: "74HC14", summary: "One gate of the fast CMOS hex Schmitt inverter",
                          values: ["supply": 5, "upper": 0.54, "lower": 0.32, "outputResistance": 50]),
            ]
        case .logicGate:
            func gate(_ name: String, _ summary: String, _ function: Double, schmitt: Bool = false, hc: Bool = false) -> PartModel {
                PartModel(name: name, summary: summary, values: [
                    "function": function, "upper": schmitt ? (hc ? 0.53 : 0.59) : 0.52,
                    "lower": schmitt ? (hc ? 0.31 : 0.39) : 0.48, "outputResistance": hc ? 50 : 400,
                ])
            }
            return [
                gate("CD4093", "One gate of the quad Schmitt NAND: gated oscillators, noise boxes, drones", 0, schmitt: true),
                gate("CD4011", "One gate of the quad NAND", 0),
                gate("CD4001", "One gate of the quad NOR", 1),
                gate("CD4081", "One gate of the quad AND", 2),
                gate("CD4071", "One gate of the quad OR", 3),
                gate("CD4070", "One gate of the quad XOR: octave-up and ring-modulator-like effects", 4),
                gate("CD4077", "One gate of the quad XNOR", 5),
                gate("74HC132", "One gate of the fast quad Schmitt NAND, for 2 to 6 V supplies", 0, schmitt: true, hc: true),
                gate("74HC00", "One gate of the fast quad NAND, for 2 to 6 V supplies", 0, hc: true),
                gate("74HC86", "One gate of the fast quad XOR, for 2 to 6 V supplies", 4, hc: true),
            ]
        case .pll:
            return [
                PartModel(name: "CD4046", summary: "Phase-locked loop: a VCO and two phase comparators. Lock it to a signal through a divider to multiply its frequency (octave-up and harmonizer effects)",
                          values: ["upper": 0.52, "lower": 0.48, "outputResistance": 400]),
                PartModel(name: "74HC4046", summary: "The fast phase-locked loop, for 2 to 6 V supplies",
                          values: ["upper": 0.52, "lower": 0.48, "outputResistance": 50]),
            ]
        case .dac:
            return [
                PartModel(name: "MCP4921", summary: "12-bit DAC on SPI: write 0x3000 + code (gain 1, on) with CS low, and OUT goes to VREF × code / 4096",
                          values: ["upper": 0.7, "lower": 0.2, "outputResistance": 10]),
            ]
        case .dualDac:
            return [
                PartModel(name: "MCP4822", summary: "Two 12-bit DACs on SPI with a 2.048 V reference inside: write 0x3000 + code for A, 0xB000 + code for B (gain 1, on), up to 2.048 V; clear bit 13 to double it",
                          values: ["upper": 0.7, "lower": 0.2, "outputResistance": 10]),
            ]
        case .spiAdc:
            return [
                PartModel(name: "MCP3008", summary: "Eight-channel 10-bit ADC on SPI: send 0x01, then 0x80 + channel × 16 (single-ended), then any byte; the code is the low 2 bits of the second reply and the third, CHn / VREF × 1024",
                          values: ["upper": 0.7, "lower": 0.2, "outputResistance": 10, "resolution": 0]),
                PartModel(name: "MCP3208", summary: "Eight-channel 12-bit ADC on SPI (the MCP3204 has four), as Mutable Instruments' Braids and Edges read their CVs: send 0x06 + channel / 4 (start, single-ended), then (channel % 4) × 64, then any byte; the code is the low 4 bits of the second reply and the third, CHn / VREF × 4096",
                          values: ["upper": 0.7, "lower": 0.2, "outputResistance": 10, "resolution": 1], aliases: ["MCP3204"]),
            ]
        case .i2cDac:
            return [
                PartModel(name: "MCP4725", summary: "12-bit DAC on I²C at address 0x60 (0x61 with A0 high): fast mode writes the code in two bytes, or command 0x40 in three; the output is VDD × code / 4096",
                          values: ["upper": 0.7, "lower": 0.2, "outputResistance": 10]),
            ]
        case .i2sDac:
            return [
                PartModel(name: "PCM5102", summary: "Stereo audio DAC on I²S (the PCM5102A): 16 to 32 bits a sample, 2.1 V RMS at full scale about ground from its own negative supply; it makes its own clocks from BCK",
                          values: ["upper": 0.7, "lower": 0.3, "outputResistance": 100], aliases: ["PCM5102A", "PCM5101", "PCM5100"]),
            ]
        case .cvDac:
            return [
                PartModel(name: "DAC8568", summary: "Eight 16-bit DACs with a 2.5 V reference at gain 2 (0 to 5 V): 32-bit words, each a command (write, update, or both), a channel and a code",
                          values: ["supply": 5, "fullScale": 5, "outputResistance": 1, "format": 0]),
                PartModel(name: "DAC8564", summary: "Four 16-bit DACs with a 2.5 V reference (0 to 2.5 V): 24-bit words, each its load bits, a channel and a code",
                          values: ["supply": 5, "fullScale": 2.5, "outputResistance": 1, "format": 1]),
                PartModel(name: "DAC8552", summary: "Two 16-bit DACs on SPI (outputs A and B), full scale at VREF: 24-bit words after SYNC falls, each its load bits, a buffer and a code",
                          values: ["supply": 5, "fullScale": 2.5, "outputResistance": 1, "format": 2]),
                PartModel(name: "DAC8551", summary: "One 16-bit DAC on SPI (output A), full scale at VREF: 24-bit words after SYNC falls",
                          values: ["supply": 5, "fullScale": 2.5, "outputResistance": 1, "format": 3]),
                PartModel(name: "DAC7554", summary: "Four 12-bit DACs on SPI (outputs A-D), full scale at VREF: 16-bit words after SYNC falls, each a channel, a command and a code",
                          values: ["supply": 5, "fullScale": 2.5, "outputResistance": 1, "format": 4]),
            ]
        case .codec:
            return [
                PartModel(name: "WM8731", summary: "Stereo audio codec (Mutable Instruments' Rings, Clouds, Elements and Warps): 16 to 32 bits on I²S both ways, set up over I²C at 0x1A (0x1B with CSB high: set the address); line in and out at 1 V RMS full scale about half its supply",
                          values: ["supply": 3.3, "fullScale": 1, "outputResistance": 100, "address": 0x1A], aliases: ["WM8731L", "WM8731S"]),
                PartModel(name: "CS4270", summary: "Stereo 24-bit codec (the CS4271 is its 192 kHz sibling; 4ms modules use it): I²S or left-justified both ways from its master clock, set up over I²C at 0x48 + AD2–AD0; on 5 V, about 1.2 V RMS full scale",
                          values: ["supply": 5, "fullScale": 1.24, "outputResistance": 100, "address": 0x48], aliases: ["CS4271"]),
                PartModel(name: "PCM3060", summary: "Stereo 24-bit codec: I²S or left-justified both ways from its system clock, set up over I²C at 0x46 (0x47 with ADR high); on 5 V, about 1.4 V RMS out at full scale",
                          values: ["supply": 5, "fullScale": 1.41, "outputResistance": 100, "address": 0x46]),
                PartModel(name: "AK4558", summary: "Stereo 32-bit codec: I²S, left- or right-justified both ways from its master clock, set up over I²C at 0x10 + CAD1–CAD0; on 3.3 V, about 1 V RMS full scale",
                          values: ["supply": 3.3, "fullScale": 1.0, "outputResistance": 100, "address": 0x10]),
                PartModel(name: "AK4556", summary: "Stereo 24-bit codec set up by its pins alone (no control port): I²S or left-justified both ways from its master clock; on 3.3 V, about 0.7 V RMS full scale",
                          values: ["supply": 3.3, "fullScale": 0.7, "outputResistance": 100, "address": 0]),
            ]
        case .unbufferedInverter:
            return [
                PartModel(name: "CD4069UB", summary: "One unbuffered inverter, biased as an amplifier: a gain of about 20 that clips softly (CMOS fuzz and preamps)",
                          values: ["threshold": 1.5, "beta": 4e-4, "lambda": 0.03]),
                PartModel(name: "CD4049UB", summary: "One unbuffered inverting buffer: the same, with four times the drive (the Red Llama)",
                          values: ["threshold": 1.5, "beta": 1.6e-3, "lambda": 0.03]),
            ]
        case .flipFlop:
            return [
                PartModel(name: "CD4013", summary: "One half of the dual D flip-flop, with set and reset; Q̄ to D makes it divide by two",
                          values: ["upper": 0.52, "lower": 0.48, "outputResistance": 400]),
            ]
        case .decadeCounter:
            return [
                PartModel(name: "CD4017", summary: "Decade counter with ten decoded outputs: step sequencers (the Baby 10), dividers",
                          values: ["upper": 0.52, "lower": 0.48, "outputResistance": 400]),
                PartModel(name: "74HC4017", summary: "The fast decade counter, for 2 to 6 V supplies",
                          values: ["upper": 0.52, "lower": 0.48, "outputResistance": 50]),
            ]
        case .ledDriver:
            return [
                PartModel(name: "PCA9685", summary: "Sixteen-channel 12-bit PWM driver on I²C at 0x40 + A5–A0 (and 0x70, all call): each output on from its ON count to its OFF count of 4096, at 25 MHz / 4096 / (PRE_SCALE + 1) (200 Hz from reset); it wakes asleep, MODE1's SLEEP bit set, its outputs off until cleared; OE high turns them off",
                          values: ["supply": 3.3, "upper": 0.7, "lower": 0.3, "outputResistance": 25]),
            ]
        case .i2cEeprom:
            // (the write cycle the datasheets' longest: a firmware has to wait for it, or poll for the acknowledge)
            return [
                PartModel(name: "24LC256", summary: "32 KB EEPROM on I²C at 0x50 + A2–A0: a two-byte address, then 64-byte page writes (the address wrapping round within the page), each taking up to 5 ms after the STOP, the chip answering nothing meanwhile; reads run on through the whole memory; WP high protects it",
                          values: ["size": 32768, "page": 64, "writeTime": 0.005], aliases: ["24AA256", "24FC256", "AT24C256"]),
                PartModel(name: "24LC512", summary: "64 KB EEPROM on I²C at 0x50 + A2–A0: as the 24LC256, with 128-byte pages",
                          values: ["size": 65536, "page": 128, "writeTime": 0.005], aliases: ["24AA512", "24FC512", "AT24C512"]),
                PartModel(name: "24LC64", summary: "8 KB EEPROM on I²C at 0x50 + A2–A0: a two-byte address, 32-byte pages, 5 ms writes",
                          values: ["size": 8192, "page": 32, "writeTime": 0.005], aliases: ["24AA64", "AT24C64"]),
                PartModel(name: "24LC32A", summary: "4 KB EEPROM on I²C at 0x50 + A2–A0: a two-byte address, 32-byte pages, 5 ms writes",
                          values: ["size": 4096, "page": 32, "writeTime": 0.005], aliases: ["24LC32", "24AA32A", "AT24C32"]),
                PartModel(name: "24LC16B", summary: "2 KB EEPROM on I²C: eight 256-byte blocks at 0x50 to 0x57 (its A pins unused), a one-byte address, 16-byte pages, 5 ms writes",
                          values: ["size": 2048, "page": 16, "writeTime": 0.005], aliases: ["24LC16", "24AA16"]),
                PartModel(name: "24LC02B", summary: "256-byte EEPROM on I²C at 0x50 (its A pins unused on the 24LC02B): a one-byte address, 8-byte pages, 5 ms writes",
                          values: ["size": 256, "page": 8, "writeTime": 0.005], aliases: ["24LC02", "24AA02", "AT24C02"]),
            ]
        case .ledSink:
            return [
                PartModel(name: "TLC5947", summary: "Twenty-four-channel 12-bit PWM constant-current LED driver: 288 bits shifted in on SIN at SCLK's rising edges, OUT23's MSB first, taken by XLAT's rising edge; each output sinks 41 × 1.2 V / IREF (2 to 30 mA) for its grayscale count of 4096 at its 4 MHz oscillator (976 Hz), all off while BLANK is high; SOUT carries the register's last bit on to the next one",
                          values: ["supply": 3.3, "upper": 0.7, "lower": 0.3, "outputResistance": 50]),
            ]
        case .shiftIn:
            return [
                PartModel(name: "74HC165", summary: "Eight-stage parallel-in shift register: SH/LD low loads D0–D7, each rising CLK (CLK INH low) shifts them out on QH, D7 first, SER coming in behind (buttons and switches read on an SPI port's MISO)",
                          values: ["supply": 3.3, "upper": 0.7, "lower": 0.3, "outputResistance": 50], aliases: ["SN74HC165", "CD74HC165"]),
            ]
        case .shiftRegister:
            return [
                PartModel(name: "CD4015", summary: "One half of the dual four-stage shift register: DATA moves along Q1–Q4 on each rising clock (Klee-style sequencers, delays of logic)",
                          values: ["type": 0, "upper": 0.52, "lower": 0.48, "outputResistance": 400]),
                PartModel(name: "74HC595", summary: "Eight-stage shift register with a latch: SER shifts in on SRCLK, RCLK copies the stages to Q0–Q7 (microcontrollers' extra outputs, LED rows)",
                          values: ["type": 1, "upper": 0.52, "lower": 0.48, "outputResistance": 50, "supply": 5]),
            ]
        case .binaryCounter:
            return [
                PartModel(name: "CD4040", summary: "Twelve-stage binary counter, counting on the falling edge: octave dividers",
                          values: ["upper": 0.52, "lower": 0.48, "outputResistance": 400]),
                PartModel(name: "74HC4040", summary: "The fast twelve-stage binary counter, for 2 to 6 V supplies",
                          values: ["upper": 0.52, "lower": 0.48, "outputResistance": 50]),
            ]
        case .analogMux:
            return [
                PartModel(name: "CD4051", summary: "Eight-channel analog multiplexer: A, B and C pick the channel X connects to",
                          values: ["onResistance": 125, "upper": 0.52, "lower": 0.48]),
                PartModel(name: "74HC4051", summary: "The fast eight-channel multiplexer, for 2 to 6 V supplies",
                          values: ["onResistance": 70, "upper": 0.52, "lower": 0.48]),
            ]
        case .analogSelector:
            return [
                PartModel(name: "CD4053", summary: "One switch of the triple two-channel multiplexer: SEL picks X0 or X1",
                          values: ["onResistance": 125, "upper": 0.52, "lower": 0.48]),
                PartModel(name: "74HC4053", summary: "One switch of the fast triple two-channel multiplexer, for 2 to 6 V supplies",
                          values: ["onResistance": 70, "upper": 0.52, "lower": 0.48]),
            ]
        case .analogSwitch:
            return [
                PartModel(name: "CD4066", summary: "One switch of the quad CMOS bilateral switch",
                          values: ["onResistance": 125, "supply": 12]),
                PartModel(name: "DG411", summary: "One switch of the low-resistance analog switch",
                          values: ["onResistance": 25, "supply": 12]),
            ]
        case .diode:
            return [
                PartModel(name: "Generic silicon", summary: "An ideal silicon junction",
                          values: ["saturationCurrent": 1e-14, "emission": 1, "cj0": 1e-12, "tt": 0]),
                PartModel(name: "1N4148", summary: "Small-signal switching diode: the usual clipping diode (the 1N914 is the same)",
                          values: ["saturationCurrent": 2.52e-9, "emission": 1.752, "cj0": 4e-12, "tt": 20e-9], aliases: ["1N914"]),
                PartModel(name: "1N4001", summary: "Rectifier: slow to let go of its stored charge",
                          values: ["saturationCurrent": 14.1e-9, "emission": 1.984, "cj0": 25.9e-12, "tt": 5.7e-6]),
                PartModel(name: "1N34A", summary: "Germanium: soft, low-voltage clipping for vintage fuzz",
                          values: ["saturationCurrent": 2.6e-6, "emission": 1.6, "cj0": 0.5e-12, "tt": 0]),
                PartModel(name: "BAT41", summary: "Schottky: low forward voltage, no stored charge",
                          values: ["saturationCurrent": 2.8e-8, "emission": 1.06, "cj0": 2e-12, "tt": 0]),
                PartModel(name: "1N5817", summary: "Schottky rectifier, 1 A: about 0.18 V at 1 mA; reverse-polarity protection and soft clipping",
                          values: ["saturationCurrent": 1e-6, "emission": 1.0, "cj0": 110e-12, "tt": 0]),
                PartModel(name: "OA90", summary: "Germanium point-contact: the softest, lowest clipping (vintage fuzz and ring modulators)",
                          values: ["saturationCurrent": 1e-6, "emission": 1.5, "cj0": 1e-12, "tt": 0]),
                PartModel(name: "1N5819", summary: "Schottky rectifier, 40 V, 1 A: about 0.22 V at 1 mA, 0.5 V at 1 A; Eurorack modules' reverse-polarity protection",
                          values: ["saturationCurrent": 3e-7, "emission": 1.03, "cj0": 100e-12, "tt": 0, "rs": 0.1, "bv": 40, "ibv": 1e-3]),
                PartModel(name: "BAT54", summary: "Small Schottky, 30 V: about 0.29 V at 1 mA. The BAT54S is two in series (anode, middle, cathode): an input's middle pin clamped between the ADC's rails",
                          values: ["saturationCurrent": 1e-7, "emission": 1.2, "cj0": 10e-12, "tt": 0, "rs": 2, "bv": 30, "ibv": 1e-4],
                          aliases: ["BAT54S", "BAT54A", "BAT54C"]),
            ]
        case .zener:
            // (a shunt reference: its voltage at 100 µA, its dynamic impedance as RS and its knee as a small breakdown
            // emission, within about 10 mV from its least current to 15 mA)
            func reference(_ name: String, _ volts: Double, _ summary: String, aliases: [String]) -> PartModel {
                PartModel(name: name, summary: summary, values: [
                    "breakdown": volts, "ibv": 100e-6, "nbv": 0.02, "rs": 0.3, "cj0": 1e-12, "saturationCurrent": 1e-14, "emission": 1, "tt": 0,
                ], aliases: aliases)
            }
            return [
                PartModel(name: "Generic 5.1 V", summary: "A plain Zener diode: 5.1 V at 5 mA",
                          values: ["breakdown": 5.1, "ibv": 5e-3, "cj0": 1e-12, "saturationCurrent": 1e-14, "emission": 1, "tt": 0]),
                reference("LM4040-2.5", 2.5, "Precision shunt reference: 2.500 V at 100 µA, within 10 mV from 45 µA to 15 mA; the ADC reference of Mutable's modules. Feed it through a resistor, its cathode the reference",
                          aliases: ["LM4040A25", "LM4040-2.5V"]),
                reference("LM4040-10", 10, "Precision shunt reference: 10.00 V at 100 µA, within 10 mV up to 15 mA; the top of Mutable's pots and offsets. Feed it through a resistor from +12 V",
                          aliases: ["LM4040A100", "LM4040-10V"]),
            ]
        case .npn:
            return [
                PartModel(name: "Generic", summary: "A plain silicon NPN",
                          values: ["beta": 100, "saturationCurrent": 1e-14, "cje": 1e-12, "cjc": 1e-12, "tf": 0]),
                PartModel(name: "2N3904", summary: "General purpose",
                          values: ["beta": 300, "saturationCurrent": 6.7e-15, "cje": 4.5e-12, "cjc": 3.6e-12, "tf": 300e-12]),
                PartModel(name: "BC547C", summary: "High gain, low noise",
                          values: ["beta": 500, "saturationCurrent": 1.8e-14, "cje": 11.5e-12, "cjc": 5.25e-12, "tf": 410e-12]),
                PartModel(name: "2N5088", summary: "Very high gain: fuzz and distortion pedals",
                          values: ["beta": 800, "saturationCurrent": 2e-14, "cje": 6e-12, "cjc": 4e-12, "tf": 450e-12]),
                PartModel(name: "BC108", summary: "Silicon Fuzz Face",
                          values: ["beta": 300, "saturationCurrent": 1.8e-14, "cje": 12e-12, "cjc": 5e-12, "tf": 500e-12]),
                PartModel(name: "2N5089", summary: "The highest-gain small NPN: boosts, fuzzes, the Big Muff's cousins",
                          values: ["beta": 1000, "saturationCurrent": 3e-14, "cje": 6e-12, "cjc": 3.5e-12, "tf": 450e-12]),
                PartModel(name: "MPSA18", summary: "Very high gain, low noise: clean boosts (the LPB-1) and preamps",
                          values: ["beta": 900, "saturationCurrent": 3.3e-14, "cje": 7e-12, "cjc": 3e-12, "tf": 1e-9]),
                PartModel(name: "2N2222", summary: "Switching and general purpose, more current (600 mA): drivers, the Big Muff",
                          values: ["beta": 200, "saturationCurrent": 1.43e-14, "cje": 22e-12, "cjc": 7.3e-12, "tf": 411e-12]),
                PartModel(name: "BC549C", summary: "The low-noise BC547C: first stages of preamps",
                          values: ["beta": 520, "saturationCurrent": 2.4e-14, "cje": 11.5e-12, "cjc": 5.25e-12, "tf": 410e-12]),
                PartModel(name: "SSM2212", summary: "One of a matched, low-noise NPN pair in one package: exponential converters, log amps, preamps (use both halves for the pair)",
                          values: ["beta": 605, "saturationCurrent": 1.1e-14, "cje": 20e-12, "cjc": 10e-12, "tf": 1e-9]),
                PartModel(name: "CA3046", summary: "One of the five NPNs of the transistor array, matched and at one temperature: expo converters, differential pairs",
                          values: ["beta": 110, "saturationCurrent": 1.3e-14, "cje": 0.6e-12, "cjc": 0.58e-12, "tf": 0.5e-9]),
            ]
        case .pnp:
            return [
                PartModel(name: "Generic", summary: "A plain silicon PNP",
                          values: ["beta": 100, "saturationCurrent": 1e-14, "cje": 1e-12, "cjc": 1e-12, "tf": 0]),
                PartModel(name: "2N3906", summary: "General purpose",
                          values: ["beta": 200, "saturationCurrent": 1.4e-15, "cje": 8e-12, "cjc": 4.5e-12, "tf": 510e-12]),
                PartModel(name: "AC128", summary: "Germanium: the original Fuzz Face, slow (about 1 MHz)",
                          values: ["beta": 90, "saturationCurrent": 5e-8, "cje": 60e-12, "cjc": 30e-12, "tf": 150e-9]),
                PartModel(name: "NKT275", summary: "Germanium: the 1966 Fuzz Face, gain about 80, leaky (bias it by ear)",
                          values: ["beta": 80, "saturationCurrent": 1e-7, "cje": 50e-12, "cjc": 25e-12, "tf": 100e-9]),
                PartModel(name: "OC44", summary: "Germanium, faster (15 MHz): the Tone Bender MkI",
                          values: ["beta": 100, "saturationCurrent": 3e-7, "cje": 15e-12, "cjc": 10e-12, "tf": 10e-9]),
                PartModel(name: "SSM2220", summary: "One of a matched PNP pair in one package: the classic 1 V/octave exponential converter (use both halves)",
                          values: ["beta": 165, "saturationCurrent": 1.5e-14, "cje": 25e-12, "cjc": 12e-12, "tf": 1e-9]),
            ]
        case .multiplier:
            return [
                PartModel(name: "AD633", summary: "Four-quadrant multiplier: out = x · y / 10 V, for ring modulators and VCAs",
                          values: ["scale": 0.1, "limit": 11]),
                PartModel(name: "MPY634", summary: "Precision four-quadrant multiplier: out = x · y / 10 V, more accurate and ten times faster (10 MHz)",
                          values: ["scale": 0.1, "limit": 12]),
            ]
        case .delayLine:
            return [
                PartModel(name: "MN3207", summary: "1024-stage bucket brigade: chorus and flanger (12.8 ms at 40 kHz); the MN3007 is its 15 V forerunner",
                          values: ["stages": 1024, "clock": 40_000]),
                PartModel(name: "MN3008", summary: "2048 stages: longer chorus, short echo", values: ["stages": 2048, "clock": 40_000]),
                PartModel(name: "MN3005", summary: "4096 stages: echo (102 ms at 20 kHz); the MN3205 is its 9 V version",
                          values: ["stages": 4096, "clock": 20_000]),
            ]
        case .comparator:
            return [
                PartModel(name: "LM393", summary: "Dual comparator, its open-collector output pulled up to 5 V",
                          values: ["high": 5, "low": 0.1]),
                PartModel(name: "LM311", summary: "Output pulled up to +12 V, emitter at −12 V", values: ["high": 12, "low": -12]),
            ]
        case .vco:
            return [
                PartModel(name: "AS3340", summary: "The CEM3340 VCO chip: one volt per octave, exact tracking; pulse width set by PW (±5 V)",
                          values: ["amplitude": 5]),
            ]
        case .vcf:
            return [
                PartModel(name: "AS3320", summary: "The CEM3320 four-pole (24 dB/octave) ladder-style low-pass: one volt per octave",
                          values: ["drive": 5]),
                PartModel(name: "SSM2044", summary: "Four-pole low-pass, softer and driven harder (Korg Polysix, Mono/Poly)",
                          values: ["drive": 2]),
                PartModel(name: "IR3109", summary: "Roland's four-pole OTA filter (Juno-6, 60 and 106, Jupiter-8): smooth, driven gently",
                          values: ["drive": 3.5]),
            ]
        case .envelope:
            return [
                PartModel(name: "AS3310", summary: "The CEM3310 ADSR: a gate opens it, a trigger restarts the attack; 0 to 5 V",
                          values: ["peak": 5]),
            ]
        case .vca:
            return [
                PartModel(name: "SSM2164", summary: "One cell of the quad exponential VCA: −33 mV per dB, unity gain at 0 V (the V2164 is its clone)",
                          values: ["response": 0, "dbPerVolt": -30.3], aliases: ["V2164"]),
                PartModel(name: "Linear", summary: "Gain in proportion to the control: unity at 5 V, silent at 0 V and below",
                          values: ["response": 1, "unity": 5]),
                PartModel(name: "THAT2180", summary: "Blackmer VCA for compressors and faders: −6.1 mV per dB at its EC− control",
                          values: ["response": 0, "dbPerVolt": -163.9]),
            ]
        case .sampleHold:
            return [
                PartModel(name: "Clocked", summary: "Samples the input on each rising edge of the trigger and holds it until the next",
                          values: ["mode": 0, "droop": 0]),
                PartModel(name: "LF398", summary: "Tracks the input while the logic input is high, holds it while low",
                          values: ["mode": 1, "droop": 0.003]),
            ]
        case .divider:
            return [
                PartModel(name: "CD4013", summary: "A D flip-flop wired to toggle: half the clock's frequency (a sub-oscillator)",
                          values: ["division": 2]),
                PartModel(name: "CD4017", summary: "Decade counter's carry out: one cycle every ten clocks", values: ["division": 10]),
                PartModel(name: "CD4040", summary: "Binary counter, Q4 output: one cycle every sixteen clocks", values: ["division": 16]),
            ]
        case .digitalDelay:
            return [
                PartModel(name: "PT2399", summary: "The echo chip: the resistance from pin 6 to ground sets the delay (about 30 ms to 340 ms); longer delays are darker and noisier",
                          values: ["shortest": 0.0242, "delayPerKilohm": 0.0115, "gain": 1, "limit": 2, "noise": 0.002]),
            ]
        case .vactrol:
            return [
                PartModel(name: "VTL5C3", summary: "Fast, low-glow: lowpass gates, filters (about 2.5 ms on, 35 ms off)",
                          values: ["ron": 1500, "iref": 0.01, "roff": 1e7, "gamma": 0.75, "attack": 0.0025, "decay": 0.035]),
                PartModel(name: "NSL-32", summary: "Slow release: compressors and opto tremolo",
                          values: ["ron": 500, "iref": 0.02, "roff": 5e5, "gamma": 0.8, "attack": 0.005, "decay": 0.25]),
                PartModel(name: "H11F1", summary: "Photo-FET optocoupler: a FET channel instead of a cell, under 200 Ω at 16 mA, very linear for small signals and fast (tens of µs); 6-pin DIP",
                          values: ["ron": 150, "iref": 0.016, "roff": 3e8, "gamma": 1, "attack": 2.5e-5, "decay": 2.5e-5]),
            ]
        case .triode:
            func tube(_ name: String, _ summary: String, _ mu: Double, _ ex: Double, _ kg1: Double, _ kp: Double,
                      _ cgk: Double, _ cgp: Double, _ cpk: Double) -> PartModel {
                PartModel(name: name, summary: summary, values: [
                    "mu": mu, "ex": ex, "kg1": kg1, "kp": kp, "kvb": 300, "rgi": 2000, "cgk": cgk, "cgp": cgp, "cpk": cpk,
                ])
            }
            return [
                tube("12AX7", "ECC83: high gain (µ 100), the preamp tube of guitar amps", 100, 1.4, 1060, 600, 2.3e-12, 2.4e-12, 0.9e-12),
                tube("12AT7", "ECC81: medium gain (µ 60), reverb drivers and phase inverters", 60, 1.35, 460, 300, 2.3e-12, 2.2e-12, 1.0e-12),
                tube("12AU7", "ECC82: low gain (µ 21.5), more current: cathode followers, drivers", 21.5, 1.3, 1180, 84, 2.3e-12, 2.2e-12, 1.0e-12),
                tube("ECC88", "6DJ8: low noise, high transconductance, hi-fi preamps", 28, 1.3, 330, 320, 3.3e-12, 1.4e-12, 1.8e-12),
            ]
        case .pentode:
            return [
                PartModel(name: "6L6GC", summary: "Beam power tube of American amps (Fender): about 30 W a pair", values: [
                    "mu": 8.7, "ex": 1.35, "kg1": 1460, "kg2": 4500, "kp": 48, "kvb": 12, "rgi": 1000,
                    "cgk": 14e-12, "cgp": 0.85e-12, "cpk": 12e-12,
                ]),
                PartModel(name: "EL34", summary: "Power pentode of British amps (Marshall): about 50 W a pair", values: [
                    "mu": 11, "ex": 1.35, "kg1": 650, "kg2": 4200, "kp": 60, "kvb": 24, "rgi": 1000,
                    "cgk": 15e-12, "cgp": 1.1e-12, "cpk": 8e-12,
                ]),
            ]
        case .transformer:
            return [
                PartModel(name: "Output 8 kΩ : 8 Ω", summary: "A single-ended output transformer: 20 H primary, 1 kΩ of plate load for each ohm of speaker",
                          values: ["inductance": 20, "ratio": 0.0316228, "coupling": 0.998, "rp": 200, "rs": 0.4]),
                PartModel(name: "Mains 230 V : 12 V", summary: "A small power transformer for a 12 V supply",
                          values: ["inductance": 5, "ratio": 0.0521739, "coupling": 0.995, "rp": 30, "rs": 0.5]),
                PartModel(name: "Interstage 1 : 2", summary: "Steps a signal up twice: coupling and phase splitting",
                          values: ["inductance": 30, "ratio": 2, "coupling": 0.995, "rp": 500, "rs": 1500]),
            ]
        case .njfet:
            return [
                PartModel(name: "2N5457", summary: "General purpose", values: ["pinchOff": -1.5, "idss": 3e-3]),
                PartModel(name: "J201", summary: "Low pinch-off, for phasers and VCAs", values: ["pinchOff": -0.8, "idss": 0.6e-3]),
                PartModel(name: "2N3819", summary: "Higher current", values: ["pinchOff": -3, "idss": 10e-3]),
                PartModel(name: "J113", summary: "Switch and booster, low resistance when on", values: ["pinchOff": -1.2, "idss": 5e-3]),
                PartModel(name: "2SK30A", summary: "Low-noise JFET of boosters and compressors (GR grade)", values: ["pinchOff": -0.8, "idss": 3.5e-3]),
            ]
        case .nmos:
            return [
                PartModel(name: "Generic", summary: "A plain N-channel MOSFET", values: ["threshold": 1.5, "beta": 0.02]),
                PartModel(name: "2N7000", summary: "Small N-MOSFET, 200 mA: switches, LED drivers, MOSFET boosters",
                          values: ["threshold": 2.1, "beta": 0.05]),
                PartModel(name: "BS170", summary: "Small N-MOSFET, 500 mA", values: ["threshold": 2.0, "beta": 0.12]),
            ]
        case .pjfet:
            return [PartModel(name: "Generic", summary: "A plain P-channel JFET", values: ["pinchOff": -1.5, "idss": 3e-3])]
        case .pmos:
            return [
                PartModel(name: "Generic", summary: "A plain P-channel MOSFET", values: ["threshold": 1.5, "beta": 0.02]),
                PartModel(name: "BS250", summary: "Small P-MOSFET, 250 mA: reverse-polarity protection, high-side switches",
                          values: ["threshold": 2.4, "beta": 0.04]),
            ]
        case .noiseVoltage:
            return [
                PartModel(name: "White", summary: "Gaussian white noise", values: ["type": 0, "amplitude": 1]),
                PartModel(name: "MM5837", summary: "The digital noise chip of drum machines and synths: a 17-stage shift register's pseudo-random bits, about 2.5 V from peak to peak, repeating every few seconds",
                          values: ["type": 1, "amplitude": 1.25]),
            ]
        case .speaker:
            return ElementKind.loudspeakerModels
        default:
            return audioModels
        }
    }
}

extension Element {
    /// The model whose values the parameters still have, if any
    public var model: PartModel? {
        // relative tolerance: saturation currents of 1e-14 A must not match 6.7e-15 A
        kind.models.first { model in
            model.values.allSatisfy { abs(self[param: $0.key] - $0.value) <= 1e-9 * abs($0.value) + 1e-300 }
        }
    }
}
