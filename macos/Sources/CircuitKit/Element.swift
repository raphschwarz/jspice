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
    case amplifiers = "Amplifiers"
    case synth = "Synth Chips"
    case microcontrollers = "Microcontrollers"
    case timersAndLogic = "Timers & Logic"
    case effects = "Effects"
    case memristors = "Memristors"
    case instruments = "Instruments"

    public var id: String { rawValue }
}

public enum ElementKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case wire, ground, netLabel, resistor, potentiometer, lamp, capacitor, inductor
    case dcVoltage, acVoltage, squareVoltage, noiseVoltage, currentSource, keyboardPitch, keyboardGate
    case toggleSwitch, pushButton
    case diode, zener, led, npn, pnp, nmos, pmos, njfet
    case opAmp, ota, multiplier, comparator
    case vco, vcf, envelope, vca, sampleHold, divider
    case timer555, schmittInverter, analogSwitch
    case logicGate, flipFlop, decadeCounter, binaryCounter, analogMux, analogSelector
    case atmega328p, atmega2560, attiny85, rp2040
    case delayLine, vactrol
    case memristor
    case probe, ammeter, speaker

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

    public init(_ key: String, _ name: String, unit: String, default defaultValue: Double, range: ClosedRange<Double>, log: Bool = true,
                choices: [ParamChoice] = []) {
        self.key = key
        self.name = name
        self.unit = unit
        self.defaultValue = defaultValue
        self.range = range
        self.logarithmic = log
        self.choices = choices
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
        case .vactrol: return "Vactrol"
        case .timer555: return "555 Timer"
        case .atmega328p: return "ATmega328P (Arduino Uno)"
        case .atmega2560: return "ATmega2560 (Arduino Mega)"
        case .attiny85: return "ATtiny85"
        case .rp2040: return "RP2040 (Raspberry Pi Pico)"
        case .schmittInverter: return "Schmitt Inverter"
        case .analogSwitch: return "Analog Switch"
        case .logicGate: return "Logic Gate"
        case .flipFlop: return "D Flip-Flop"
        case .decadeCounter: return "Decade Counter"
        case .binaryCounter: return "Binary Counter"
        case .analogMux: return "Analog Multiplexer"
        case .analogSelector: return "Analog Selector"
        case .memristor: return "Memristor"
        case .probe: return "Voltage Probe"
        case .ammeter: return "Ammeter"
        case .speaker: return "Speaker"
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
        case .currentSource: return "I"
        case .keyboardPitch: return "CV"
        case .keyboardGate: return "GATE"
        case .toggleSwitch, .pushButton: return "S"
        case .diode, .zener: return "D"
        case .led: return "LED"
        case .npn, .pnp, .njfet: return "Q"
        case .nmos, .pmos: return "M"
        case .opAmp, .ota, .multiplier, .comparator, .delayLine, .timer555, .schmittInverter, .analogSwitch, .atmega328p, .atmega2560,
             .attiny85, .rp2040: return "U"
        case .vco, .vcf, .envelope, .vca, .sampleHold, .divider: return "U"
        case .logicGate, .flipFlop, .decadeCounter, .binaryCounter, .analogMux, .analogSelector: return "U"
        case .vactrol: return "VTL"
        case .memristor: return "MR"
        case .probe: return "P"
        case .ammeter: return "A"
        case .speaker: return "SPK"
        }
    }

    public var category: ElementCategory {
        switch self {
        case .wire, .ground, .netLabel, .resistor, .potentiometer, .lamp, .capacitor, .inductor: return .basics
        case .dcVoltage, .acVoltage, .squareVoltage, .noiseVoltage, .currentSource, .keyboardPitch, .keyboardGate: return .sources
        case .toggleSwitch, .pushButton: return .switches
        case .diode, .zener, .led, .npn, .pnp, .nmos, .pmos, .njfet: return .semiconductors
        case .opAmp, .ota, .multiplier, .comparator: return .amplifiers
        case .vco, .vcf, .envelope, .vca, .sampleHold, .divider: return .synth
        case .delayLine, .vactrol: return .effects
        case .timer555, .schmittInverter, .analogSwitch: return .timersAndLogic
        case .logicGate, .flipFlop, .decadeCounter, .binaryCounter, .analogMux, .analogSelector: return .timersAndLogic
        case .atmega328p, .atmega2560, .attiny85, .rp2040: return .microcontrollers
        case .memristor: return .memristors
        case .probe, .ammeter, .speaker: return .instruments
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
        case .keyboardPitch, .keyboardGate, .noiseVoltage: return nil
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
        case .njfet, .ota, .schmittInverter, .analogSwitch, .multiplier, .delayLine, .vactrol: return nil
        case .comparator, .vco, .vcf, .envelope, .vca, .sampleHold, .divider, .atmega328p, .atmega2560, .attiny85, .rp2040: return nil
        case .logicGate, .flipFlop, .decadeCounter, .binaryCounter, .analogMux, .analogSelector: return nil
        case .memristor: return "m"
        case .probe: return "o"
        case .ammeter: return "x"
        case .speaker: return nil
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
        [displayName, category.rawValue] + models.map(\.name)
    }

    /// Three-terminal transistors drawn with their control terminal at `a` and their channel at `b`
    public var isTransistor: Bool { self == .nmos || self == .pmos || self == .npn || self == .pnp || self == .njfet }

    public var isBipolar: Bool { self == .npn || self == .pnp }

    /// Parts whose terminals depend on a direction, which stay horizontal or vertical
    public var isAxisAligned: Bool {
        isTransistor || self == .opAmp || self == .ota || self == .potentiometer || self == .timer555 || self == .analogSwitch
            || self == .multiplier || self == .delayLine || self == .vactrol || isModule || self == .comparator || isMicrocontroller
            || isLogic
    }

    /// Parts that can be mirrored across their axis
    public var canFlip: Bool { isAxisAligned }

    /// Length in grid units of parts whose size is fixed (their terminals sit at set places around the body)
    public var fixedLength: Int? {
        switch self {
        case .nmos, .pmos, .npn, .pnp, .njfet: return 2
        case .ota, .vactrol: return 4
        case .timer555: return 5
        case .atmega328p, .atmega2560, .attiny85, .rp2040: return board?.length
        case .flipFlop, .decadeCounter, .binaryCounter, .analogMux, .analogSelector: return chipPackage?.length
        default: return nil
        }
    }

    /// Names of the terminals, in the order of `Element.posts`, for netlists and automation
    public var terminalNames: [String] {
        switch self {
        case .ground: return ["gnd"]
        case .netLabel: return ["net"]
        case .dcVoltage, .acVoltage, .squareVoltage, .noiseVoltage, .currentSource, .keyboardPitch, .keyboardGate:
            return ["minus", "plus"]
        case .diode, .zener, .led: return ["anode", "cathode"]
        case .probe, .speaker: return ["plus", "minus"]
        case .ammeter: return ["in", "out"]
        case .nmos, .pmos, .njfet: return ["gate", "drain", "source"]
        case .npn, .pnp: return ["base", "collector", "emitter"]
        case .potentiometer: return ["a", "b", "wiper"]
        case .analogSwitch: return ["a", "b", "control"]
        case .opAmp: return ["minus", "plus", "out"]
        case .multiplier: return ["x", "y", "out"]
        case .delayLine: return ["in", "ctrl", "out"]
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
        case .atmega328p, .atmega2560, .attiny85, .rp2040: return board?.terminalNames ?? []
        case .schmittInverter: return ["in", "out"]
        case .logicGate: return ["in1", "in2", "out"]
        case .flipFlop, .decadeCounter, .binaryCounter, .analogMux, .analogSelector: return chipPackage?.terminalNames ?? []
        default: return ["a", "b"]
        }
    }

    /// Parts that switch between discrete states (a 555's flip-flop, a Schmitt trigger's output, CMOS logic)
    public var isDigital: Bool { self == .timer555 || self == .schmittInverter || isLogic }

    public var isVoltageSource: Bool {
        self == .dcVoltage || self == .acVoltage || self == .squareVoltage || self == .noiseVoltage || isKeyboard
    }

    /// Sources played from the computer keyboard or a MIDI keyboard
    public var isKeyboard: Bool { self == .keyboardPitch || self == .keyboardGate }

    public var isSwitch: Bool { self == .toggleSwitch || self == .pushButton }

    /// Parts whose output (the third terminal) is driven like a voltage source to ground: op-amps, multipliers, BBDs,
    /// comparators and the synth chips
    public var drivesOutput: Bool { self == .opAmp || self == .multiplier || self == .delayLine || self == .comparator || isModule }

    /// Synth chips and the delay line: blocks whose output is worked out from their inputs once per step (an oscillator's
    /// phase, an envelope's stage, a held sample), with two inputs either side of `a` and the output at `b`
    public var isModule: Bool {
        switch self {
        case .delayLine, .vco, .vcf, .envelope, .vca, .sampleHold, .divider: return true
        default: return false
        }
    }

    /// Offset of the second point when the element is placed with a single click
    public var defaultOffset: GridPoint {
        switch self {
        case .ground: return GridPoint(0, 1)
        case .netLabel: return GridPoint(1, 0)
        case .nmos, .pmos, .npn, .pnp, .njfet: return GridPoint(2, 0)
        case .timer555: return GridPoint(0, 5)
        case .atmega328p, .atmega2560, .attiny85, .rp2040: return GridPoint(0, board?.length ?? 13)
        case .flipFlop, .decadeCounter, .binaryCounter, .analogMux, .analogSelector: return GridPoint(0, chipPackage?.length ?? 3)
        default: return GridPoint(4, 0)
        }
    }

    public var params: [ParamSpec] {
        switch self {
        case .wire, .ground, .netLabel, .toggleSwitch, .pushButton, .probe, .ammeter:
            return []
        case .speaker:
            return [ParamSpec("fullScale", "Full-scale voltage", unit: "V", default: 5, range: 0.1...50)]
        case .resistor:
            return [ParamSpec("resistance", "Resistance", unit: "Ω", default: 1000, range: 1...10_000_000)]
        case .potentiometer:
            return [
                ParamSpec("resistance", "Resistance", unit: "Ω", default: 10_000, range: 10...10_000_000),
                ParamSpec("position", "Wiper position", unit: "", default: 0.5, range: 0...1, log: false),
                ParamSpec("taper", "Taper (0 linear, 1 audio)", unit: "", default: 0, range: 0...1, log: false),
            ]
        case .zener:
            return [ParamSpec("breakdown", "Breakdown voltage", unit: "V", default: 5.1, range: 1...50, log: false)]
        case .npn, .pnp:
            return [
                ParamSpec("beta", "Current gain", unit: "", default: 100, range: 5...1000),
                ParamSpec("saturationCurrent", "Saturation current", unit: "A", default: 1e-14, range: 1e-17...1e-5),
            ]
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
            ]
        case .vactrol:
            return [
                ParamSpec("ron", "Resistance at the reference current", unit: "Ω", default: 1500, range: 10...1e6),
                ParamSpec("iref", "Reference LED current", unit: "A", default: 0.01, range: 1e-4...0.05),
                ParamSpec("roff", "Dark resistance", unit: "Ω", default: 1e7, range: 1e4...1e9),
                ParamSpec("gamma", "Slope (resistance vs. current)", unit: "", default: 0.75, range: 0.3...1.5, log: false),
                ParamSpec("attack", "Attack time", unit: "s", default: 0.0025, range: 1e-4...1),
                ParamSpec("decay", "Decay time", unit: "s", default: 0.035, range: 1e-3...10),
            ]
        case .opAmp:
            return [
                ParamSpec("gain", "Open-loop gain", unit: "", default: 1_000_000, range: 10...10_000_000),
                ParamSpec("limit", "Output swing", unit: "V", default: 15, range: 1...50, log: false),
                ParamSpec("slewRate", "Slew rate (0: unlimited)", unit: "V/µs", default: 0, range: 0...100, log: false),
                ParamSpec("gbw", "Gain-bandwidth", unit: "Hz", default: 1e9, range: 1e4...1e10),
                ParamSpec("offset", "Input offset", unit: "V", default: 1e-6, range: -0.01...0.01, log: false),
            ]
        case .ota:
            return [
                ParamSpec("supply", "Supply (±)", unit: "V", default: 15, range: 3...18, log: false),
                ParamSpec("biasDrop", "Bias pin junctions", unit: "", default: 2, range: 1...2, log: false),
                ParamSpec("headroom", "Output headroom", unit: "V", default: 1.5, range: 0.1...5, log: false),
            ]
        case .atmega328p, .atmega2560, .attiny85:
            return [
                ParamSpec("supply", "Supply", unit: "V", default: 5, range: 1.8...5.5, log: false),
                ParamSpec("outputResistance", "Pin output resistance", unit: "Ω", default: 25, range: 1...1000),
                ParamSpec("pullUp", "Pull-up resistance", unit: "Ω", default: 35_000, range: 20_000...50_000),
            ]
        case .rp2040:
            // 4 mA drive (the pads' default); pull-ups and pull-downs of about 50 kΩ
            return [
                ParamSpec("supply", "Supply", unit: "V", default: 3.3, range: 1.8...3.6, log: false),
                ParamSpec("outputResistance", "Pin output resistance", unit: "Ω", default: 50, range: 1...1000),
                ParamSpec("pullUp", "Pull-up and pull-down resistance", unit: "Ω", default: 50_000, range: 30_000...80_000),
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
        case .analogMux, .analogSelector:
            return [ParamSpec("onResistance", "On resistance", unit: "Ω", default: 125, range: 1...10_000)]
                + Array(Self.logicParams(upper: 0.52, lower: 0.48).dropLast())
        case .njfet:
            return [
                ParamSpec("pinchOff", "Pinch-off voltage", unit: "V", default: -1.5, range: -8...(-0.2), log: false),
                ParamSpec("idss", "Saturation current (IDSS)", unit: "A", default: 3e-3, range: 1e-5...0.1),
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
            ]
        case .inductor:
            return [ParamSpec("inductance", "Inductance", unit: "H", default: 1, range: 1e-9...100)]
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
            return [ParamSpec("amplitude", "RMS amplitude", unit: "V", default: 1, range: 0.001...10)]
        case .keyboardPitch:
            return [ParamSpec("glide", "Glide", unit: "s", default: 0, range: 0...2, log: false)]
        case .keyboardGate:
            return [ParamSpec("high", "Gate voltage", unit: "V", default: 5, range: 1...15, log: false)]
        case .diode:
            return [
                ParamSpec("saturationCurrent", "Saturation current", unit: "A", default: 1e-14, range: 1e-18...1e-6),
                ParamSpec("emission", "Emission coefficient", unit: "", default: 1, range: 0.5...3, log: false),
            ]
        case .led:
            return [ParamSpec("color", "Color", unit: "", default: 0, range: 0...4, log: false)]
        case .nmos, .pmos:
            return [
                ParamSpec("threshold", "Threshold voltage", unit: "V", default: 1.5, range: 0.1...5, log: false),
                ParamSpec("beta", "Beta", unit: "A/V²", default: 0.02, range: 1e-4...1),
            ]
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
    }

    /// A parameter value, falling back to the kind's default
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
        return kind == .nmos || kind == .npn || kind == .njfet ? (up, down) : (down, up)
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
        return (kind.chipPackage?.pinPlaces ?? []).map { a + d * $0.offset + perpendicular * ($0.second ? 3 : -3) }
    }

    /// Terminal positions: [a, b] for two-terminal parts, [a] for ground, [gate, drain, source] for MOSFETs,
    /// [base, collector, emitter] for bipolar transistors, [a, b, wiper] for potentiometers ([a, b, control] for analog
    /// switches), [−, +, output] for op-amps, [−, +, output, bias] for OTAs and the eight pins of a 555 in pin order
    public var posts: [GridPoint] {
        switch kind {
        case .ground, .netLabel:
            return [a]
        case .nmos, .pmos, .npn, .pnp, .njfet:
            let t = transistorTerminals
            return [a, t.drain, t.source]
        case .potentiometer, .analogSwitch:
            return [a, b, wiper]
        case .opAmp, .multiplier, .comparator, .delayLine, .vco, .vcf, .envelope, .vca, .sampleHold, .divider, .logicGate:
            return [a - perpendicular, a + perpendicular, b]
        case .vactrol:
            return [a - perpendicular, a + perpendicular, b - perpendicular, b + perpendicular]
        case .ota:
            return [a - perpendicular, a + perpendicular, b, biasInput]
        case .timer555:
            return timerPins
        case .atmega328p, .atmega2560, .attiny85, .rp2040, .flipFlop, .decadeCounter, .binaryCounter, .analogMux, .analogSelector:
            return packagePins
        default:
            return [a, b]
        }
    }

    /// All grid points the element occupies at its ends, for moving and bounds
    public var extentPoints: [GridPoint] {
        posts.count > 2 ? posts + [a, b] : [a, b]
    }

    /// Ideal conductors: their ends are the same node
    public var isConductor: Bool {
        kind == .wire || kind == .ammeter || (kind.isSwitch && closed)
    }
}

/// A real part whose behaviour a generic symbol can take on: its parameter values.
public struct PartModel: Sendable, Hashable {
    public let name: String
    public let summary: String
    public let values: [String: Double]
}

extension ElementKind {
    /// Real parts this symbol can behave like, chosen in the inspector; the first one matches the parameter defaults
    public var models: [PartModel] {
        switch self {
        case .opAmp:
            return [
                PartModel(name: "Ideal", summary: "Very high gain and bandwidth, no slew limit",
                          values: ["gain": 1e6, "limit": 15, "slewRate": 0, "gbw": 1e9, "offset": 1e-6]),
                PartModel(name: "TL072", summary: "JFET input, the synth workhorse: 13 V/µs, 3 MHz",
                          values: ["gain": 2e5, "limit": 13.5, "slewRate": 13, "gbw": 3e6, "offset": 1e-3]),
                PartModel(name: "LM358", summary: "Low power, slow: 0.3 V/µs, 1 MHz",
                          values: ["gain": 1e5, "limit": 13.5, "slewRate": 0.3, "gbw": 1e6, "offset": 2e-3]),
                PartModel(name: "NE5532", summary: "Low noise audio: 9 V/µs, 10 MHz",
                          values: ["gain": 1e5, "limit": 13, "slewRate": 9, "gbw": 10e6, "offset": 0.5e-3]),
                PartModel(name: "LM741", summary: "The classic: 0.5 V/µs, 1 MHz",
                          values: ["gain": 2e5, "limit": 13, "slewRate": 0.5, "gbw": 1e6, "offset": 1e-3]),
            ]
        case .ota:
            return [
                PartModel(name: "LM13700", summary: "One half of the dual OTA; bias pin two junctions above V−",
                          values: ["supply": 15, "biasDrop": 2, "headroom": 1.5]),
                PartModel(name: "CA3080", summary: "The original OTA; bias pin one junction above V−",
                          values: ["supply": 15, "biasDrop": 1, "headroom": 1.5]),
            ]
        case .atmega328p:
            return [
                PartModel(name: "ATmega328P", summary: "The Arduino Uno's chip at 16 MHz: write a sketch, upload it, and it runs",
                          values: ["supply": 5]),
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
                    "function": function, "supply": hc ? 5 : 12, "upper": schmitt ? (hc ? 0.53 : 0.59) : 0.52,
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
                gate("74HC132", "One gate of the fast quad Schmitt NAND, at 5 V", 0, schmitt: true, hc: true),
                gate("74HC00", "One gate of the fast quad NAND, at 5 V", 0, hc: true),
                gate("74HC86", "One gate of the fast quad XOR, at 5 V", 4, hc: true),
            ]
        case .flipFlop:
            return [
                PartModel(name: "CD4013", summary: "One half of the dual D flip-flop, with set and reset; Q̄ to D makes it divide by two",
                          values: ["supply": 12, "upper": 0.52, "lower": 0.48, "outputResistance": 400]),
            ]
        case .decadeCounter:
            return [
                PartModel(name: "CD4017", summary: "Decade counter with ten decoded outputs: step sequencers (the Baby 10), dividers",
                          values: ["supply": 12, "upper": 0.52, "lower": 0.48, "outputResistance": 400]),
                PartModel(name: "74HC4017", summary: "The fast decade counter, at 5 V",
                          values: ["supply": 5, "upper": 0.52, "lower": 0.48, "outputResistance": 50]),
            ]
        case .binaryCounter:
            return [
                PartModel(name: "CD4040", summary: "Twelve-stage binary counter, counting on the falling edge: octave dividers",
                          values: ["supply": 12, "upper": 0.52, "lower": 0.48, "outputResistance": 400]),
                PartModel(name: "74HC4040", summary: "The fast twelve-stage binary counter, at 5 V",
                          values: ["supply": 5, "upper": 0.52, "lower": 0.48, "outputResistance": 50]),
            ]
        case .analogMux:
            return [
                PartModel(name: "CD4051", summary: "Eight-channel analog multiplexer: A, B and C pick the channel X connects to",
                          values: ["onResistance": 125, "supply": 12, "upper": 0.52, "lower": 0.48]),
                PartModel(name: "74HC4051", summary: "The fast eight-channel multiplexer, at 5 V",
                          values: ["onResistance": 70, "supply": 5, "upper": 0.52, "lower": 0.48]),
            ]
        case .analogSelector:
            return [
                PartModel(name: "CD4053", summary: "One switch of the triple two-channel multiplexer: SEL picks X0 or X1",
                          values: ["onResistance": 125, "supply": 12, "upper": 0.52, "lower": 0.48]),
                PartModel(name: "74HC4053", summary: "One switch of the fast triple two-channel multiplexer, at 5 V",
                          values: ["onResistance": 70, "supply": 5, "upper": 0.52, "lower": 0.48]),
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
                          values: ["saturationCurrent": 1e-14, "emission": 1]),
                PartModel(name: "1N4148", summary: "Small-signal switching diode: the usual clipping diode",
                          values: ["saturationCurrent": 2.52e-9, "emission": 1.752]),
                PartModel(name: "1N4001", summary: "Rectifier", values: ["saturationCurrent": 14.1e-9, "emission": 1.984]),
                PartModel(name: "1N34A", summary: "Germanium: soft, low-voltage clipping for vintage fuzz",
                          values: ["saturationCurrent": 2.6e-6, "emission": 1.6]),
                PartModel(name: "BAT41", summary: "Schottky: low forward voltage", values: ["saturationCurrent": 2.8e-8, "emission": 1.06]),
            ]
        case .npn:
            return [
                PartModel(name: "Generic", summary: "A plain silicon NPN", values: ["beta": 100, "saturationCurrent": 1e-14]),
                PartModel(name: "2N3904", summary: "General purpose", values: ["beta": 300, "saturationCurrent": 6.7e-15]),
                PartModel(name: "BC547C", summary: "High gain, low noise", values: ["beta": 500, "saturationCurrent": 1.8e-14]),
                PartModel(name: "2N5088", summary: "Very high gain: fuzz and distortion pedals", values: ["beta": 800, "saturationCurrent": 2e-14]),
                PartModel(name: "BC108", summary: "Silicon Fuzz Face", values: ["beta": 300, "saturationCurrent": 1.8e-14]),
            ]
        case .pnp:
            return [
                PartModel(name: "Generic", summary: "A plain silicon PNP", values: ["beta": 100, "saturationCurrent": 1e-14]),
                PartModel(name: "2N3906", summary: "General purpose", values: ["beta": 200, "saturationCurrent": 1.4e-15]),
                PartModel(name: "AC128", summary: "Germanium: the original Fuzz Face", values: ["beta": 90, "saturationCurrent": 5e-8]),
            ]
        case .multiplier:
            return [
                PartModel(name: "AD633", summary: "Four-quadrant multiplier: out = x · y / 10 V, for ring modulators and VCAs",
                          values: ["scale": 0.1, "limit": 11]),
            ]
        case .delayLine:
            return [
                PartModel(name: "MN3207", summary: "1024-stage bucket brigade: chorus and flanger (12.8 ms at 40 kHz)",
                          values: ["stages": 1024, "clock": 40_000]),
                PartModel(name: "MN3008", summary: "2048 stages: longer chorus, short echo", values: ["stages": 2048, "clock": 40_000]),
                PartModel(name: "MN3005", summary: "4096 stages: echo (102 ms at 20 kHz)", values: ["stages": 4096, "clock": 20_000]),
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
            ]
        case .envelope:
            return [
                PartModel(name: "AS3310", summary: "The CEM3310 ADSR: a gate opens it, a trigger restarts the attack; 0 to 5 V",
                          values: ["peak": 5]),
            ]
        case .vca:
            return [
                PartModel(name: "SSM2164", summary: "One cell of the quad exponential VCA: −33 mV per dB, unity gain at 0 V",
                          values: ["response": 0, "dbPerVolt": -30.3]),
                PartModel(name: "Linear", summary: "Gain in proportion to the control: unity at 5 V, silent at 0 V and below",
                          values: ["response": 1, "unity": 5]),
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
        case .vactrol:
            return [
                PartModel(name: "VTL5C3", summary: "Fast, low-glow: lowpass gates, filters (about 2.5 ms on, 35 ms off)",
                          values: ["ron": 1500, "iref": 0.01, "roff": 1e7, "gamma": 0.75, "attack": 0.0025, "decay": 0.035]),
                PartModel(name: "NSL-32", summary: "Slow release: compressors and opto tremolo",
                          values: ["ron": 500, "iref": 0.02, "roff": 5e5, "gamma": 0.8, "attack": 0.005, "decay": 0.25]),
            ]
        case .njfet:
            return [
                PartModel(name: "2N5457", summary: "General purpose", values: ["pinchOff": -1.5, "idss": 3e-3]),
                PartModel(name: "J201", summary: "Low pinch-off, for phasers and VCAs", values: ["pinchOff": -0.8, "idss": 0.6e-3]),
                PartModel(name: "2N3819", summary: "Higher current", values: ["pinchOff": -3, "idss": 10e-3]),
            ]
        default:
            return []
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
