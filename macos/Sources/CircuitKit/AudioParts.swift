import Foundation

// The audio parts: microphones and a guitar pickup, mic preamp, balanced line and power amp chips, a compander, a tone
// control, a level detector, a spring reverb tank, LED bar-graph drivers, a balanced cable and a VU meter.
//
// Most of them are simulated as small circuits of the parts the simulator already models (see `Circuit.expandModels`):
// an instrumentation amplifier as its three op-amps and their resistors, a microphone as its sound and its output
// impedance, an LM386 as its input stage, gain network and output stage. The level detector and the spring tank are
// modules worked out once per step; the VU meter only watches.

extension ElementKind {
    /// Parts simulated as a small circuit of other parts, put in by `Circuit.expandModels`
    public var isExpandedPart: Bool {
        switch self {
        case .microphone, .electretMic, .pickup, .instrumentationAmp, .lineReceiver, .lineDriver, .audioPowerAmp, .compander,
             .toneControl, .barGraphDriver, .balancedCable:
            return true
        default:
            return false
        }
    }

    /// Parts that play a sound into the circuit (a clip, the guitar riff, a voice, or the Mac's live input)
    public var playsClip: Bool { self == .audioInput || self == .microphone || self == .electretMic || self == .pickup }

    /// How the audio chips are drawn: a box with their pins down its sides, inputs on the second side
    public var audioChipPackage: ChipPackage? {
        func first(_ offset: Int) -> Board.PinPlace { Board.PinPlace(second: false, offset: offset) }
        func second(_ offset: Int) -> Board.PinPlace { Board.PinPlace(second: true, offset: offset) }
        switch self {
        case .microphone:
            return ChipPackage(name: "MIC", terminalNames: ["gnd", "hot", "cold"], pinLabels: ["1 GND", "2 HOT", "3 COLD"],
                               pinPlaces: [first(2), first(0), first(1)], length: 2)
        case .instrumentationAmp:
            return ChipPackage(name: "SSM2019", terminalNames: ["minus", "plus", "rg1", "rg2", "ref", "out"],
                               pinLabels: ["−IN", "+IN", "RG1", "RG2", "REF", "OUT"],
                               pinPlaces: [second(0), second(1), second(2), second(3), first(3), first(0)], length: 3)
        case .lineReceiver:
            return ChipPackage(name: "INA134", terminalNames: ["minus", "plus", "ref", "out"], pinLabels: ["−IN", "+IN", "REF", "OUT"],
                               pinPlaces: [second(0), second(1), first(2), first(0)], length: 2)
        case .lineDriver:
            return ChipPackage(name: "DRV134", terminalNames: ["in", "outPlus", "outMinus"], pinLabels: ["IN", "+OUT", "−OUT"],
                               pinPlaces: [second(0), first(0), first(1)], length: 2)
        case .audioPowerAmp:
            return ChipPackage(name: "LM386", terminalNames: ["minus", "plus", "gain1", "gain8", "bypass", "out"],
                               pinLabels: ["−IN", "+IN", "GAIN 1", "GAIN 8", "BYPASS", "OUT"],
                               pinPlaces: [second(0), second(1), second(3), first(3), second(2), first(0)], length: 3)
        case .compander:
            return ChipPackage(name: "NE570", terminalNames: ["rectIn", "rectCap", "gainIn", "invIn", "r3", "out"],
                               pinLabels: ["RECT IN", "RECT CAP", "ΔG IN", "INV IN", "R3", "OUT"],
                               pinPlaces: [second(0), second(3), second(1), first(1), first(2), first(0)], length: 3)
        case .toneControl:
            return ChipPackage(name: "LM1036", terminalNames: ["in", "volume", "bass", "treble", "ref", "out"],
                               pinLabels: ["IN", "VOL", "BASS", "TREBLE", "REF", "OUT"],
                               pinPlaces: [second(0), second(1), second(2), second(3), first(3), first(0)], length: 3)
        case .barGraphDriver:
            return ChipPackage(name: "LM3915", terminalNames: ["sig", "rlo", "rhi", "refOut", "refAdj"] + (1...10).map { "led\($0)" },
                               pinLabels: ["SIG", "RLO", "RHI", "REF OUT", "REF ADJ"] + (1...10).map { "LED\($0)" },
                               pinPlaces: (0...4).map(second) + (1...10).map { first(10 - $0) }, length: 9)
        case .balancedCable:
            return ChipPackage(name: "XLR", terminalNames: ["gnd1", "hot1", "cold1", "gnd2", "hot2", "cold2"],
                               pinLabels: ["1 GND", "2 HOT", "3 COLD", "1 GND", "2 HOT", "3 COLD"],
                               pinPlaces: [second(2), second(0), second(1), first(2), first(0), first(1)], length: 2)
        default:
            return nil
        }
    }

    var audioParams: [ParamSpec] {
        let input = ParamSpec.choice("input", "Input", ["Sound file", "Live input (with sound on)"])
        let loop = ParamSpec.choice("loop", "Playback", ["Once", "Loop"], default: 1)
        func supply(_ volts: Double) -> ParamSpec { ParamSpec("supply", "Supply (±)", unit: "V", default: volts, range: 4...18, log: false) }
        switch self {
        case .microphone:
            return [
                input,
                ParamSpec("level", "Peak voltage at full scale", unit: "V", default: 0.01, range: 1e-4...1),
                loop,
                .choice("type", "Type", ["Dynamic", "Condenser (on 48 V phantom power)"]),
                ParamSpec("impedance", "Output impedance", unit: "Ω", default: 300, range: 50...2000),
                ParamSpec("phantomLoad", "Condenser: each leg's DC load", unit: "Ω", default: 15_000, range: 2000...100_000),
            ]
        case .electretMic:
            return [
                input,
                ParamSpec("level", "Peak gate voltage at full scale", unit: "V", default: 0.005, range: 1e-4...0.1),
                loop,
                ParamSpec("idss", "Its JFET's saturation current (IDSS)", unit: "A", default: 0.3e-3, range: 1e-5...5e-3),
                ParamSpec("pinchOff", "Its JFET's pinch-off voltage", unit: "V", default: -0.5, range: -3...(-0.1), log: false),
            ]
        case .pickup:
            return [
                input,
                ParamSpec("level", "Peak voltage at full scale", unit: "V", default: 0.2, range: 0.01...2),
                loop,
                ParamSpec("resistance", "Coil resistance", unit: "Ω", default: 6000, range: 1000...20_000),
                ParamSpec("inductance", "Coil inductance", unit: "H", default: 2.5, range: 0.5...15),
                ParamSpec("capacitance", "Coil and cable capacitance", unit: "F", default: 100e-12, range: 10e-12...2e-9),
            ]
        case .instrumentationAmp:
            return [
                supply(15),
                ParamSpec("rf", "Internal gain resistors (gain 1 + 2 Rf / RG)", unit: "Ω", default: 5000, range: 1000...50_000),
                ParamSpec("noise", "Input noise voltage", unit: "V/√Hz", default: 1e-9, range: 0...1e-7, log: false),
                ParamSpec("gbw", "Gain-bandwidth of its op-amps", unit: "Hz", default: 20e6, range: 1e5...1e9),
                ParamSpec("slewRate", "Slew rate", unit: "V/µs", default: 16, range: 0...100, log: false),
            ]
        case .lineReceiver:
            return [
                supply(15),
                ParamSpec("resistance", "Input resistors", unit: "Ω", default: 25_000, range: 1000...100_000),
                ParamSpec("gain", "Gain", unit: "", default: 1, range: 0.1...10),
                ParamSpec("gbw", "Gain-bandwidth", unit: "Hz", default: 3.1e6, range: 1e5...1e9),
                ParamSpec("slewRate", "Slew rate", unit: "V/µs", default: 14, range: 0...100, log: false),
                ParamSpec("noise", "Op-amp input noise voltage", unit: "V/√Hz", default: 10e-9, range: 0...1e-7, log: false),
            ]
        case .lineDriver:
            return [
                supply(15),
                ParamSpec("outputResistance", "Output resistance (each side)", unit: "Ω", default: 50, range: 0...1000, log: false),
                ParamSpec("gbw", "Gain-bandwidth", unit: "Hz", default: 1.5e6, range: 1e5...1e9),
                ParamSpec("slewRate", "Slew rate", unit: "V/µs", default: 15, range: 0...100, log: false),
            ]
        case .audioPowerAmp:
            return [
                ParamSpec("supply", "Supply", unit: "V", default: 9, range: 4...18, log: false),
                ParamSpec("gbw", "Gain-bandwidth", unit: "Hz", default: 6e6, range: 1e5...1e8),
            ]
        case .compander:
            return [supply(15)]
        case .toneControl:
            return [
                supply(15),
                ParamSpec("bassTurnover", "Bass turnover", unit: "Hz", default: 250, range: 50...1000),
                ParamSpec("trebleTurnover", "Treble turnover", unit: "Hz", default: 2000, range: 500...10_000),
                ParamSpec("range", "Boost and cut", unit: "dB", default: 15, range: 3...24, log: false),
            ]
        case .levelDetector:
            return [
                .choice("mode", "Detects", ["RMS level, in dB", "Average level", "Peak level", "Absolute value"]),
                ParamSpec("attack", "Attack time", unit: "s", default: 0.035, range: 0...2, log: false),
                ParamSpec("release", "Release time", unit: "s", default: 0.035, range: 0...5, log: false),
                ParamSpec("scale", "RMS: output per dB", unit: "V", default: 0.0061, range: 0.001...0.1),
                ParamSpec("reference", "RMS: input for 0 V out", unit: "V", default: 0.775, range: 0.001...10),
            ]
        case .springReverb:
            return [
                ParamSpec("decay", "Decay time (−60 dB)", unit: "s", default: 2.75, range: 0.5...6),
                ParamSpec("delay", "Spring delay", unit: "s", default: 0.0335, range: 0.01...0.08),
                ParamSpec("gain", "Output for each volt in", unit: "", default: 0.05, range: 0.001...1),
                ParamSpec("inputResistance", "Input coil resistance", unit: "Ω", default: 8, range: 1...5000),
                ParamSpec("dispersion", "Dispersion (the drip)", unit: "", default: 0.62, range: 0...0.9, log: false),
            ]
        case .barGraphDriver:
            return [
                .choice("scale", "Scale", ["Linear (LM3914)", "Log, 3 dB steps (LM3915)", "VU (LM3916)"], default: 1),
                ParamSpec("ledCurrent", "LED current", unit: "A", default: 0.01, range: 1e-3...0.03),
                ParamSpec("supply", "Supply", unit: "V", default: 12, range: 3...25, log: false),
            ]
        case .balancedCable:
            return [
                ParamSpec("length", "Length", unit: "m", default: 10, range: 0.5...100),
                ParamSpec("hum", "Hum induced in each conductor (peak)", unit: "V", default: 0.05, range: 0...1, log: false),
                ParamSpec("frequency", "Mains frequency", unit: "Hz", default: 50, range: 50...60, log: false,
                          choices: [ParamChoice(name: "50 Hz", value: 50), ParamChoice(name: "60 Hz", value: 60)]),
                ParamSpec("imbalance", "Imbalance (cold conductor's share less)", unit: "", default: 0.02, range: 0...1, log: false),
            ]
        case .vuMeter:
            return [
                .choice("mode", "Ballistics", ["VU (300 ms)", "Peak programme meter"]),
                ParamSpec("reference", "RMS level for 0 dB", unit: "V", default: 1.228, range: 0.01...10),
            ]
        default:
            return []
        }
    }

    var audioModels: [PartModel] {
        switch self {
        case .microphone:
            return [
                PartModel(name: "Dynamic vocal mic", summary: "A moving-coil stage mic (SM58 type): about 10 mV peaks from a voice, 300 Ω",
                          values: ["type": 0, "level": 0.01, "impedance": 300]),
                PartModel(name: "Dynamic broadcast mic", summary: "A low-output moving-coil mic (SM7B type): needs 60 dB of gain",
                          values: ["type": 0, "level": 0.003, "impedance": 150]),
                PartModel(name: "Large-diaphragm condenser", summary: "A studio condenser mic: 48 V phantom power through 6.81 kΩ per leg",
                          values: ["type": 1, "level": 0.05, "impedance": 200, "phantomLoad": 15_000]),
                PartModel(name: "Small-diaphragm condenser", summary: "A pencil condenser mic on 48 V phantom power",
                          values: ["type": 1, "level": 0.03, "impedance": 150, "phantomLoad": 12_000]),
            ]
        case .electretMic:
            return [
                PartModel(name: "Electret capsule", summary: "A two-wire capsule with a JFET inside (WM-61A type): bias it with 2.2 kΩ to 3-10 V",
                          values: ["level": 0.005, "idss": 0.3e-3, "pinchOff": -0.5]),
                PartModel(name: "Sensitive electret capsule", summary: "A hotter capsule with a bigger JFET",
                          values: ["level": 0.01, "idss": 0.5e-3, "pinchOff": -0.7]),
            ]
        case .pickup:
            return [
                PartModel(name: "Single coil", summary: "A Strat-type single coil: bright, 6 kΩ and 2.5 H",
                          values: ["level": 0.2, "resistance": 6000, "inductance": 2.5, "capacitance": 100e-12]),
                PartModel(name: "Humbucker", summary: "A vintage humbucker: 8 kΩ and 4.5 H, warmer and louder",
                          values: ["level": 0.4, "resistance": 8000, "inductance": 4.5, "capacitance": 150e-12]),
                PartModel(name: "P-90", summary: "A fat single coil: 8 kΩ and 7 H",
                          values: ["level": 0.35, "resistance": 8000, "inductance": 7, "capacitance": 120e-12]),
                PartModel(name: "Hot humbucker", summary: "An overwound humbucker: 15 kΩ and 8 H, dark and loud",
                          values: ["level": 0.8, "resistance": 15_000, "inductance": 8, "capacitance": 180e-12]),
            ]
        case .instrumentationAmp:
            return [
                PartModel(name: "SSM2019", summary: "Mic preamp: gain 1 + 10 kΩ / RG, 1 nV/√Hz",
                          values: ["rf": 5000, "noise": 1e-9, "gbw": 20e6, "slewRate": 16]),
                PartModel(name: "THAT1510", summary: "Mic preamp: gain 1 + 5 kΩ / RG, 1 nV/√Hz",
                          values: ["rf": 2500, "noise": 1e-9, "gbw": 20e6, "slewRate": 19]),
                PartModel(name: "THAT1512", summary: "Mic preamp: gain 1 + 5 kΩ / RG, 2 nV/√Hz, for higher source impedances",
                          values: ["rf": 2500, "noise": 2e-9, "gbw": 20e6, "slewRate": 19]),
                PartModel(name: "INA217", summary: "Mic preamp: gain 1 + 10 kΩ / RG, 1.3 nV/√Hz",
                          values: ["rf": 5000, "noise": 1.3e-9, "gbw": 20e6, "slewRate": 15]),
            ]
        case .lineReceiver:
            return [
                PartModel(name: "INA134", summary: "Balanced line receiver: unity gain, 25 kΩ resistors trimmed for 90 dB of CMRR",
                          values: ["resistance": 25_000, "gain": 1, "gbw": 3.1e6, "slewRate": 14, "noise": 10e-9]),
                PartModel(name: "THAT1240", summary: "Balanced line receiver: unity gain, 9 kΩ",
                          values: ["resistance": 9000, "gain": 1, "gbw": 8e6, "slewRate": 12, "noise": 8e-9]),
                PartModel(name: "THAT1246", summary: "Balanced line receiver: −6 dB, for +4 dBu levels into converters",
                          values: ["resistance": 10_000, "gain": 0.5, "gbw": 8e6, "slewRate": 12, "noise": 8e-9]),
            ]
        case .lineDriver:
            return [
                PartModel(name: "DRV134", summary: "Balanced line driver: each output ±1 × the input (6 dB balanced), 50 Ω",
                          values: ["outputResistance": 50, "gbw": 1.5e6, "slewRate": 15]),
                PartModel(name: "THAT1646", summary: "Balanced line driver: 6 dB, faster",
                          values: ["outputResistance": 50, "gbw": 10e6, "slewRate": 15]),
            ]
        case .audioPowerAmp:
            return [
                PartModel(name: "LM386N-1", summary: "Half a watt into 8 Ω on 9 V: gain 20, or 200 with 10 µF from pin 1 to pin 8",
                          values: ["supply": 9]),
                PartModel(name: "LM386N-4", summary: "One watt into 32 Ω on 16 V", values: ["supply": 16]),
            ]
        case .compander:
            return [
                PartModel(name: "NE570", summary: "Compander: a full-wave rectifier, a ΔG gain cell and an op-amp (one channel of two)",
                          values: ["supply": 15]),
                PartModel(name: "SA571", summary: "The NE570 for a wider temperature range", values: ["supply": 12]),
            ]
        case .toneControl:
            return [
                PartModel(name: "LM1036", summary: "DC-controlled volume, bass and treble (one channel of two): 0-5.4 V controls",
                          values: ["bassTurnover": 250, "trebleTurnover": 2000, "range": 15]),
            ]
        case .levelDetector:
            return [
                PartModel(name: "THAT2252", summary: "RMS level detector: +6.1 mV per dB, the THAT2180 VCA's control scale",
                          values: ["mode": 0, "attack": 0.035, "release": 0.035, "scale": 0.0061, "reference": 0.775]),
                PartModel(name: "Peak detector", summary: "Fast attack, slow release: for limiters and noise gates",
                          values: ["mode": 2, "attack": 0.001, "release": 0.3]),
                PartModel(name: "Average detector", summary: "Rectified and smoothed: the NE570's and the VU meter's measure",
                          values: ["mode": 1, "attack": 0.065, "release": 0.065]),
            ]
        case .springReverb:
            return [
                PartModel(name: "Long tank, 8 Ω input", summary: "Two long springs, 2.75 s: the Fender amp reverb's tank, driven by a transistor or transformer",
                          values: ["decay": 2.75, "delay": 0.0335, "inputResistance": 8]),
                PartModel(name: "Long tank, 1475 Ω input", summary: "A long tank for an op-amp or tube driver without a transformer",
                          values: ["decay": 2.75, "delay": 0.0335, "inputResistance": 1475]),
                PartModel(name: "Short tank, 150 Ω input", summary: "A short tank, 1.2 s",
                          values: ["decay": 1.2, "delay": 0.0235, "inputResistance": 150]),
            ]
        case .barGraphDriver:
            return [
                PartModel(name: "LM3915", summary: "Ten LEDs in 3 dB steps over 30 dB: an audio level meter", values: ["scale": 1]),
                PartModel(name: "LM3914", summary: "Ten LEDs in equal steps: a voltmeter", values: ["scale": 0]),
                PartModel(name: "LM3916", summary: "Ten LEDs on a VU scale, −20 to +3 dB", values: ["scale": 2]),
            ]
        case .balancedCable:
            return [
                PartModel(name: "Mic cable, 50 Hz mains", summary: "10 m of balanced cable near mains wiring (Europe)",
                          values: ["length": 10, "frequency": 50]),
                PartModel(name: "Mic cable, 60 Hz mains", summary: "10 m of balanced cable near mains wiring (Americas)",
                          values: ["length": 10, "frequency": 60]),
            ]
        case .vuMeter:
            return [
                PartModel(name: "VU meter, +4 dBu", summary: "0 VU at 1.228 V rms, the professional line level", values: ["mode": 0, "reference": 1.228]),
                PartModel(name: "VU meter, −10 dBV", summary: "0 VU at 0.316 V rms, the consumer line level", values: ["mode": 0, "reference": 0.316]),
                PartModel(name: "Peak programme meter", summary: "Fast rise, slow fall: shows peaks a VU meter misses",
                          values: ["mode": 1, "reference": 1.228]),
            ]
        default:
            return []
        }
    }

    /// A speaker's load: none (it only listens, as a line output does), or a loudspeaker's electrical impedance from its
    /// Thiele-Small parameters: the voice coil's resistance and inductance, and the cone's resonance seen from the coil
    static let loudspeakerParams: [ParamSpec] = [
        .choice("load", "Load", ["None: a line output", "Loudspeaker or headphones"]),
        ParamSpec("re", "Voice-coil resistance", unit: "Ω", default: 6.4, range: 1...600),
        ParamSpec("le", "Voice-coil inductance", unit: "H", default: 0.3e-3, range: 1e-6...5e-3),
        ParamSpec("fs", "Resonance", unit: "Hz", default: 90, range: 15...2000),
        ParamSpec("qms", "Mechanical Q", unit: "", default: 3, range: 0.5...20),
        ParamSpec("qes", "Electrical Q", unit: "", default: 0.6, range: 0.1...10),
    ]

    static let loudspeakerModels: [PartModel] = [
        PartModel(name: "Line output", summary: "Listens without loading the circuit, like a line output or an amp's input", values: ["load": 0]),
        PartModel(name: "Full-range 4\" 8 Ω", summary: "A small full-range speaker: resonance at 90 Hz",
                  values: ["load": 1, "re": 6.4, "le": 0.3e-3, "fs": 90, "qms": 3, "qes": 0.6]),
        PartModel(name: "Guitar 12\" 8 Ω", summary: "A guitar amp speaker: resonance at 85 Hz, rising impedance above",
                  values: ["load": 1, "re": 6.5, "le": 0.9e-3, "fs": 85, "qms": 6, "qes": 0.9]),
        PartModel(name: "Woofer 8\" 4 Ω", summary: "A hi-fi woofer: resonance at 45 Hz",
                  values: ["load": 1, "re": 3.4, "le": 0.6e-3, "fs": 45, "qms": 4, "qes": 0.4]),
        PartModel(name: "Headphones 32 Ω", summary: "Portable headphones", values: ["load": 1, "re": 30, "le": 30e-6, "fs": 100, "qms": 1.5, "qes": 3]),
        PartModel(name: "Headphones 300 Ω", summary: "Studio headphones", values: ["load": 1, "re": 290, "le": 100e-6, "fs": 100, "qms": 1.5, "qes": 4]),
    ]
}

extension Element {
    /// Whether the simulator sees this part as a small circuit of others (see `Circuit.expandModels`)
    public var expandsIntoParts: Bool {
        kind.isExpandedPart || (kind == .speaker && self[param: "load"] >= 0.5)
    }
}

/// The circuit a part is simulated as: its parts placed far off, each joined to the part's pins by wires, their ids made
/// from the part's (so they keep their state while the circuit is edited) and their names the part's, a dot and theirs
struct PartExpansion {
    let owner: Element
    let pins: [GridPoint]
    private let origin: GridPoint
    private(set) var elements: [Element] = []
    private var role = 0
    private var places = 0

    init(owner: Element, copy: Int) {
        self.owner = owner
        pins = owner.posts
        origin = GridPoint(-1_000_000 * copy, 2_000_000)
    }

    /// A point of its own, for a node inside the part
    mutating func node() -> GridPoint {
        places += 1
        return origin + GridPoint(10 * places, 0)
    }

    /// A place of its own for a part with terminals around it
    private mutating func place() -> GridPoint {
        places += 1
        return origin + GridPoint(10 * places, 100)
    }

    @discardableResult
    mutating func add(_ kind: ElementKind, _ a: GridPoint, _ b: GridPoint, _ suffix: String, _ params: [String: Double] = [:]) -> Element {
        role += 1
        var element = Element(kind: kind, name: owner.name.isEmpty ? "" : owner.name + "." + suffix, a: a, b: b, params: params)
        element.id = UUID.combining(owner.id, UUID(uuid: (0xA0, UInt8(role >> 8), UInt8(role & 0xFF), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
        elements.append(element)
        return element
    }

    mutating func resistor(_ a: GridPoint, _ b: GridPoint, _ ohms: Double, _ suffix: String) {
        add(.resistor, a, b, suffix, ["resistance": max(ohms, 1e-6)])
    }

    mutating func capacitor(_ a: GridPoint, _ b: GridPoint, _ farads: Double, _ suffix: String) {
        add(.capacitor, a, b, suffix, ["capacitance": farads])
    }

    mutating func inductor(_ a: GridPoint, _ b: GridPoint, _ henries: Double, _ suffix: String) {
        add(.inductor, a, b, suffix, ["inductance": max(henries, 1e-12)])
    }

    mutating func ground(_ p: GridPoint) {
        add(.ground, p, p + GridPoint(0, 1), "GND")
    }

    /// A part drawn like an op-amp (two inputs either side of `a`, the output at `b`), wired to the given points
    mutating func threeTerminal(_ kind: ElementKind, _ in0: GridPoint, _ in1: GridPoint, _ out: GridPoint, _ suffix: String,
                                _ params: [String: Double]) {
        let a = place()
        let part = add(kind, a, a + GridPoint(4, 0), suffix, params)
        let posts = part.posts
        add(.wire, posts[0], in0, suffix + "w0")
        add(.wire, posts[1], in1, suffix + "w1")
        add(.wire, posts[2], out, suffix + "w2")
    }

    mutating func opAmp(minus: GridPoint, plus: GridPoint, out: GridPoint, _ suffix: String, _ params: [String: Double]) {
        threeTerminal(.opAmp, minus, plus, out, suffix, params)
    }

    mutating func njfet(gate: GridPoint, drain: GridPoint, source: GridPoint, _ suffix: String, _ params: [String: Double]) {
        let a = place()
        let part = add(.njfet, a, a + GridPoint(2, 0), suffix, params)
        let posts = part.posts
        add(.wire, posts[0], gate, suffix + "g")
        add(.wire, posts[1], drain, suffix + "d")
        add(.wire, posts[2], source, suffix + "s")
    }

    /// The sound the part plays: an audio input between `minus` and `plus` with the part's clip and settings
    mutating func sound(minus: GridPoint, plus: GridPoint, default clip: AudioClip) {
        var params: [String: Double] = [:]
        for key in ["input", "level", "loop"] { params[key] = owner[param: key] }
        role += 1
        var element = Element(kind: .audioInput, name: owner.name.isEmpty ? "" : owner.name + ".SOUND", a: minus, b: plus, params: params)
        element.id = UUID.combining(owner.id, UUID(uuid: (0xA0, UInt8(role >> 8), UInt8(role & 0xFF), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
        element.audio = owner.audio ?? clip
        elements.append(element)
    }

    /// An op-amp inside a chip: its swing a volt and a half inside the supply
    func amplifier(supply: Double, gbw: Double, slew: Double, noise: Double = 0, midpoint: Double = 0) -> [String: Double] {
        ["gain": 1e6, "limit": max(supply - 1.5, 0.5), "gbw": gbw, "slewRate": slew, "offset": 0, "noise": noise, "midpoint": midpoint]
    }
}

extension PartExpansion {
    /// The circuit a netlist part of an expanded kind is simulated as, with a port at each of its pins: for SPICE export
    static func block(for part: NetlistPart) -> BlockDefinition? {
        guard part.kind.isExpandedPart else { return nil }
        let length = part.kind.audioChipPackage?.length
        var owner = Element(kind: part.kind, name: "U", a: .zero, b: length.map { GridPoint(0, $0) } ?? GridPoint(4, 0), params: part.params)
        owner.audio = part.audio
        let pins = owner.posts
        var circuit = Circuit()
        for (k, terminal) in part.kind.terminalNames.enumerated() where k < pins.count {
            circuit.elements.append(Element(kind: .port, name: terminal, a: pins[k], b: pins[k] + GridPoint(1, 0)))
        }
        circuit.elements += parts(of: owner, copy: 1)
        let name = Element(kind: part.kind, a: .zero, b: GridPoint(4, 0), params: part.params).model?.name ?? part.kind.displayName
        return BlockDefinition(name: name, circuit: circuit)
    }

    /// The parts `owner` is simulated as
    static func parts(of owner: Element, copy: Int) -> [Element] {
        var x = PartExpansion(owner: owner, copy: copy)
        x.build()
        return x.elements
    }

    private mutating func build() {
        let p = pins
        func param(_ key: String) -> Double { owner[param: key] }
        switch owner.kind {
        case .microphone where p.count == 3:
            // the capsule's sound between two inner points, each behind half the output impedance; a dynamic mic floats
            // (held only by a very large resistance), a condenser's electronics draw their current from the phantom feed
            let (gnd, hot, cold) = (p[0], p[1], p[2])
            let (plus, minus) = (node(), node())
            sound(minus: minus, plus: plus, default: .speech)
            resistor(plus, hot, param("impedance") / 2, "Zhot")
            resistor(minus, cold, param("impedance") / 2, "Zcold")
            if param("type") >= 0.5 {
                resistor(plus, gnd, param("phantomLoad"), "Lhot")
                resistor(minus, gnd, param("phantomLoad"), "Lcold")
            } else {
                resistor(minus, gnd, 1e8, "Float")
            }
        case .electretMic where p.count == 2:
            // the capsule's charge moves its JFET's gate; the JFET's drain is the output, its source the ground wire
            let (out, gnd) = (p[0], p[1])
            let gate = node()
            sound(minus: gnd, plus: gate, default: .speech)
            njfet(gate: gate, drain: out, source: gnd, "J", ["idss": param("idss"), "pinchOff": param("pinchOff")])
        case .pickup where p.count == 2:
            // the strings' voltage induced in the coil, behind its resistance and inductance, its capacitance across
            let (hot, gnd) = (p[0], p[1])
            let (e, f) = (node(), node())
            sound(minus: gnd, plus: e, default: .guitarRiff)
            resistor(e, f, param("resistance"), "R")
            inductor(f, hot, param("inductance"), "L")
            capacitor(hot, gnd, param("capacitance"), "C")
        case .instrumentationAmp where p.count == 6:
            // three op-amps: each input followed into its gain resistor RG by an op-amp with Rf in its feedback, then a
            // difference stage of four equal resistors: gain 1 + 2 Rf / RG
            let (minus, plus, rg1, rg2, ref, out) = (p[0], p[1], p[2], p[3], p[4], p[5])
            let supply = param("supply")
            let input = amplifier(supply: supply, gbw: param("gbw"), slew: param("slewRate"), noise: param("noise") / 2.0.squareRoot())
            let (n1, n2, m3, p3) = (node(), node(), node(), node())
            opAmp(minus: rg1, plus: plus, out: n1, "A1", input)
            resistor(n1, rg1, param("rf"), "RF1")
            opAmp(minus: rg2, plus: minus, out: n2, "A2", input)
            resistor(n2, rg2, param("rf"), "RF2")
            resistor(n1, p3, 10_000, "R1")
            resistor(p3, ref, 10_000, "R2")
            resistor(n2, m3, 10_000, "R3")
            resistor(m3, out, 10_000, "R4")
            opAmp(minus: m3, plus: p3, out: out, "A3", amplifier(supply: supply, gbw: param("gbw"), slew: param("slewRate")))
        case .lineReceiver where p.count == 4:
            // a difference amplifier: out = REF + gain × (+IN − −IN)
            let (minus, plus, ref, out) = (p[0], p[1], p[2], p[3])
            let r = param("resistance"), rf = param("resistance") * param("gain")
            let (m, n) = (node(), node())
            resistor(minus, m, r, "R1")
            resistor(m, out, rf, "R2")
            resistor(plus, n, r, "R3")
            resistor(n, ref, rf, "R4")
            opAmp(minus: m, plus: n, out: out, "A", amplifier(supply: param("supply"), gbw: param("gbw"), slew: param("slewRate"),
                                                               noise: param("noise")))
        case .lineDriver where p.count == 3:
            // the input buffered to +OUT and inverted to −OUT, each through its output resistance
            let (input, outPlus, outMinus) = (p[0], p[1], p[2])
            let op = amplifier(supply: param("supply"), gbw: param("gbw"), slew: param("slewRate"))
            let (o1, o2, m, g) = (node(), node(), node(), node())
            ground(g)
            opAmp(minus: o1, plus: input, out: o1, "A1", op)
            resistor(o1, outPlus, param("outputResistance"), "RO1")
            resistor(input, m, 10_000, "R1")
            resistor(m, o2, 10_000, "R2")
            opAmp(minus: m, plus: g, out: o2, "A2", op)
            resistor(o2, outMinus, param("outputResistance"), "RO2")
        case .audioPowerAmp where p.count == 6:
            // inputs to ground through 50 kΩ; BYPASS is the bias point, half the supply behind 7.5 kΩ; a difference stage
            // makes GAIN 8 the bias point less twice the input; the output stage, with 15 kΩ from OUT to its − input and
            // 150 Ω + 1.35 kΩ from there through GAIN 1 to GAIN 8, gives 20 (200 with GAIN 1 and 8 bypassed)
            let (minus, plus, gain1, gain8, bypass, out) = (p[0], p[1], p[2], p[3], p[4], p[5])
            let supply = param("supply")
            let (g, vs, half, dm, dp, f) = (node(), node(), node(), node(), node(), node())
            ground(g)
            add(.dcVoltage, g, vs, "VS", ["voltage": supply])
            resistor(vs, bypass, 15_000, "RB1")
            resistor(bypass, g, 15_000, "RB2")
            // the difference stage refers to an internal half supply, so it does not pull BYPASS off half the supply
            add(.dcVoltage, g, half, "VH", ["voltage": supply / 2])
            resistor(plus, g, 100_000, "RIN1")
            resistor(minus, g, 100_000, "RIN2")
            resistor(plus, dm, 100_000, "RD1")
            resistor(dm, gain8, 200_000, "RD2")
            resistor(minus, dp, 100_000, "RD3")
            resistor(dp, half, 200_000, "RD4")
            let stage = ["gain": 1e6, "limit": max(supply / 2 - 0.3, 0.5), "gbw": 50e6, "slewRate": 0, "offset": 0, "noise": 0,
                         "midpoint": supply / 2]
            opAmp(minus: dm, plus: dp, out: gain8, "AD", stage)
            resistor(out, f, 15_000, "RF")
            resistor(f, gain1, 150, "R150")
            resistor(gain1, gain8, 1350, "R1350")
            opAmp(minus: f, plus: bypass, out: out, "AO", ["gain": 1e5, "limit": max(supply / 2 - 0.7, 0.5), "gbw": param("gbw"),
                                                           "slewRate": 0, "offset": 0, "noise": 0, "midpoint": supply / 2])
        case .compander where p.count == 6:
            // the rectifier: |RECT IN| through 10 kΩ into RECT CAP, which an inner 10 kΩ discharges (the cap averages); the
            // ΔG cell: ΔG IN times the gain the averaged level sets (unity at 0 dBu) into INV IN as a current through
            // 20 kΩ; R3 (20 kΩ) from its pin to INV IN; the op-amp from INV IN to OUT
            let (rectIn, rectCap, gainIn, invIn, r3, out) = (p[0], p[1], p[2], p[3], p[4], p[5])
            let (g, d, v) = (node(), node(), node())
            ground(g)
            threeTerminal(.levelDetector, rectIn, g, d, "RECT", ["mode": 3, "attack": 0, "release": 0])
            resistor(d, rectCap, 10_000, "R1")
            resistor(rectCap, g, 10_000, "RD")
            // a 0 dBu sine (0.775 V rms) averages 0.698 V rectified, half of it on the cap
            threeTerminal(.vca, gainIn, rectCap, v, "DG", ["response": 1, "unity": 0.349, "limit": 12])
            resistor(v, invIn, 20_000, "R2")
            resistor(r3, invIn, 20_000, "R3")
            opAmp(minus: invIn, plus: g, out: out, "A", amplifier(supply: param("supply"), gbw: 3e6, slew: 6))
        case .toneControl where p.count == 6:
            // out = volume × (in + (gb − 1) × LP(in) + (gt − 1) × HP(in)): a low-pass for the bass and a high-pass for the
            // treble, each through a VCA whose gain the control sets (flat at half the reference), summed with the input
            let (input, volume, bass, treble, ref, out) = (p[0], p[1], p[2], p[3], p[4], p[5])
            let op = amplifier(supply: param("supply"), gbw: 5e6, slew: 5)
            let (g, rv) = (node(), node())
            ground(g)
            add(.dcVoltage, g, rv, "VREF", ["voltage": 5.4])
            resistor(rv, ref, 100, "RREF")
            resistor(input, g, 30_000, "RIN")
            let (lp, lpb, hp, hpb, inb) = (node(), node(), node(), node(), node())
            resistor(input, lp, 10_000, "RB")
            capacitor(lp, g, 1 / (2 * .pi * 10_000 * param("bassTurnover")), "CB")
            opAmp(minus: lpb, plus: lp, out: lpb, "AB", op)
            capacitor(input, hp, 1 / (2 * .pi * 10_000 * param("trebleTurnover")), "CT")
            resistor(hp, g, 10_000, "RT")
            opAmp(minus: hpb, plus: hp, out: hpb, "AT", op)
            opAmp(minus: inb, plus: input, out: inb, "AI", op)
            let dbPerVolt = 2 * param("range") / 5.4
            let (lg, hg) = (node(), node())
            threeTerminal(.vca, lpb, bass, lg, "VB", ["response": 0, "dbPerVolt": dbPerVolt, "cvOffset": 2.7, "limit": 12])
            threeTerminal(.vca, hpb, treble, hg, "VT", ["response": 0, "dbPerVolt": dbPerVolt, "cvOffset": 2.7, "limit": 12])
            // −(inb + lg + hg) + (lpb + hpb): inverting inputs through 10 kΩ, the others into + with 5 kΩ to ground
            let (sm, sp, sum) = (node(), node(), node())
            resistor(inb, sm, 10_000, "RS1")
            resistor(lg, sm, 10_000, "RS2")
            resistor(hg, sm, 10_000, "RS3")
            resistor(sm, sum, 10_000, "RSF")
            resistor(lpb, sp, 10_000, "RS4")
            resistor(hpb, sp, 10_000, "RS5")
            resistor(sp, g, 5000, "RS6")
            opAmp(minus: sm, plus: sp, out: sum, "AS", op)
            // volume: 0 dB at 5.4 V, −75 dB at 0 V; then inverted back
            let (v, im) = (node(), node())
            threeTerminal(.vca, sum, volume, v, "VV", ["response": 0, "dbPerVolt": 75 / 5.4, "cvOffset": 5.4, "limit": 12])
            resistor(v, im, 10_000, "RO1")
            resistor(im, out, 10_000, "RO2")
            opAmp(minus: im, plus: g, out: out, "AO", op)
        case .barGraphDriver where p.count == 15:
            // a string of resistors from RLO to RHI with a comparator at each tap; LED k lights (its output sinks the LED
            // current, a JFET set to it) while SIG is above tap k. The reference: 1.25 V from REF ADJ up to REF OUT.
            let (sig, rlo, rhi, refOut, refAdj) = (p[0], p[1], p[2], p[3], p[4])
            let g = node()
            ground(g)
            add(.dcVoltage, refAdj, refOut, "VREF", ["voltage": 1.25])
            let fractions = Self.barGraphTaps(Int(param("scale").rounded()))
            var previous = rlo
            var below = 0.0
            for k in 1...10 {
                let tap = k == 10 ? rhi : node()
                resistor(previous, tap, max(10_000 * (fractions[k - 1] - below), 1), "R\(k)")
                let c = node()
                threeTerminal(.comparator, tap, sig, c, "C\(k)", ["high": 0, "low": -10, "hysteresis": 0.003])
                njfet(gate: c, drain: p[4 + k], source: g, "Q\(k)", ["idss": param("ledCurrent"), "pinchOff": -2])
                previous = tap
                below = fractions[k - 1]
            }
        case .balancedCable where p.count == 6:
            // each conductor's resistance, with the hum a mains field induces in it in series (the cold conductor's a
            // little less, by the imbalance); the capacitance between them; the shield joins the two ends' grounds
            let (gnd1, hot1, cold1, gnd2, hot2, cold2) = (p[0], p[1], p[2], p[3], p[4], p[5])
            let length = param("length")
            let r = 0.08 * length
            let (h, c) = (node(), node())
            resistor(hot1, h, r, "RH")
            add(.acVoltage, h, hot2, "HUMH", ["amplitude": max(param("hum"), 1e-12), "frequency": param("frequency")])
            resistor(cold1, c, r, "RC")
            add(.acVoltage, c, cold2, "HUMC", ["amplitude": max(param("hum") * (1 - param("imbalance")), 1e-12),
                                               "frequency": param("frequency")])
            resistor(gnd1, gnd2, r / 2, "RS")
            capacitor(hot2, cold2, 100e-12 * length, "C")
        case .speaker where p.count == 2:
            // the voice coil (Re, Le) and the cone's resonance seen from it: Res, Lces and Cmes in parallel
            let (plus, minus) = (p[0], p[1])
            let re = max(param("re"), 0.01), fs = max(param("fs"), 1)
            let qms = max(param("qms"), 0.01), qes = max(param("qes"), 0.01)
            let res = re * qms / qes
            let cmes = qes / (2 * .pi * fs * re)
            let lces = 1 / (pow(2 * .pi * fs, 2) * cmes)
            let (x, y) = (node(), node())
            resistor(plus, x, re, "RE")
            inductor(x, y, max(param("le"), 1e-9), "LE")
            resistor(y, minus, res, "RES")
            inductor(y, minus, lces, "LCES")
            capacitor(y, minus, cmes, "CMES")
        default:
            break
        }
    }

    /// Where the bar-graph driver's comparators switch, as fractions of RHI over RLO, LED 1 to LED 10: equal steps for the
    /// LM3914, 3 dB steps for the LM3915, the VU scale (−20, −10, −7, −5, −3, −1, 0, +1, +2, +3 dB) for the LM3916
    static func barGraphTaps(_ scale: Int) -> [Double] {
        switch scale {
        case 1: return (1...10).map { pow(10, -3 * Double(10 - $0) / 20) }
        case 2: return [-20, -10, -7, -5, -3, -1, 0, 1, 2, 3].map { pow(10, ($0 - 3) / 20) }
        default: return (1...10).map { Double($0) / 10 }
        }
    }
}

/// A spring reverb tank's springs: each a delay with dispersion (a chain of all-pass filters, which makes the chirp of a
/// spring) and damping in its feedback. Worked out at its own rate, whatever the simulation's step.
struct SpringTank {
    static let rate = 32_000.0
    static let springs = 3
    static let stages = 10

    private var lines: [[Double]] = []
    private var positions: [Int] = []
    private var allpass: [[Double]] = []
    private var damping: [Double] = []
    private var highpassInput = 0.0
    private var highpassOutput = 0.0
    private var phase = 0.0
    private var previous = 0.0
    private var current = 0.0
    private var delay = 0.0

    /// One step of `dt` seconds with input `x`; the tank's output, before its gain
    mutating func process(_ x: Double, dt: Double, decay: Double, delay springDelay: Double, dispersion: Double) -> Double {
        if lines.isEmpty || springDelay != delay {
            delay = springDelay
            // three springs of slightly different lengths, so their echoes do not line up
            let lengths = [1.0, 1.13, 0.87].map { max(Int($0 * springDelay * Self.rate), 8) }
            lines = lengths.map { [Double](repeating: 0, count: $0) }
            positions = [Int](repeating: 0, count: Self.springs)
            allpass = [[Double]](repeating: [Double](repeating: 0, count: Self.stages), count: Self.springs)
            damping = [Double](repeating: 0, count: Self.springs)
        }
        phase += dt * Self.rate
        while phase >= 1 {
            phase -= 1
            previous = current
            current = sample(x, decay: decay, dispersion: dispersion)
        }
        return previous + (current - previous) * phase
    }

    private mutating func sample(_ x: Double, decay: Double, dispersion a: Double) -> Double {
        var sum = 0.0
        // damping: a one-pole low-pass at about 4.5 kHz in each spring's loop
        let pole = exp(-2 * Double.pi * 4500 / Self.rate)
        for s in 0..<Self.springs {
            let length = lines[s].count
            let out = lines[s][positions[s]]
            // dispersion: the echo's high frequencies arrive before its low ones (a spring's "drip")
            var y = out
            for k in 0..<Self.stages {
                let z = allpass[s][k]
                let v = -a * y + z
                allpass[s][k] = y + a * v
                y = v
            }
            damping[s] = (1 - pole) * y + pole * damping[s]
            let feedback = pow(10, -3 * Double(length) / Self.rate / max(decay, 0.05))
            lines[s][positions[s]] = x + feedback * damping[s]
            positions[s] = (positions[s] + 1) % length
            sum += y
        }
        // the transducers pass little below 100 Hz
        let r = exp(-2 * Double.pi * 100 / Self.rate)
        let output = sum / Double(Self.springs) - highpassInput + r * highpassOutput
        highpassInput = sum / Double(Self.springs)
        highpassOutput = output
        return output
    }
}
