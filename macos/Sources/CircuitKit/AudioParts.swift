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
             .toneControl, .barGraphDriver, .balancedCable, .balancedModulator, .mixerOscillator, .tappedTransformer,
             .functionGenerator, .nortonAmp, .bbdClock, .multiTapDelay, .reverbBrick, .analogEngine:
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
        case .behavioralSource:
            // the output across + and −, and the nets the expression reads down the other side
            return ChipPackage(name: "B", terminalNames: ["plus", "minus"] + (1...8).map { "in\($0)" },
                               pinLabels: ["+", "−"] + (1...8).map { "\($0)" },
                               pinPlaces: [first(0), first(1)] + (0..<8).map { second($0) }, length: 7)
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
        case .balancedModulator:
            return ChipPackage(name: "MC1496", terminalNames: ["sigPlus", "sigMinus", "carPlus", "carMinus", "bias", "gain1", "gain2",
                                                               "outPlus", "outMinus"],
                               pinLabels: ["SIG+", "SIG−", "CAR+", "CAR−", "BIAS", "GAIN", "GAIN", "OUT+", "OUT−"],
                               pinPlaces: [second(0), second(1), second(2), second(3), second(4), first(3), first(4), first(0), first(1)],
                               length: 5)
        case .mixerOscillator:
            return ChipPackage(name: "SA612", terminalNames: ["inA", "inB", "oscBase", "oscEmitter", "outA", "outB"],
                               pinLabels: ["IN A", "IN B", "OSC B", "OSC E", "OUT A", "OUT B"],
                               pinPlaces: [second(0), second(1), second(2), second(3), first(0), first(1)], length: 4)
        case .functionGenerator:
            return ChipPackage(name: "XR2206", terminalNames: ["timing", "control", "out", "square"],
                               pinLabels: ["TIMING", "CONTROL", "OUT", "SQUARE"],
                               pinPlaces: [second(0), second(1), first(0), first(1)], length: 2)
        case .nortonAmp:
            return ChipPackage(name: "LM3900", terminalNames: ["minus", "plus", "out"], pinLabels: ["−IN", "+IN", "OUT"],
                               pinPlaces: [second(0), second(1), first(0)], length: 2)
        case .bbdClock:
            return ChipPackage(name: "MN3101", terminalNames: ["rx", "cp1", "cp2", "vgg"], pinLabels: ["RX", "CP1", "CP2", "VGG"],
                               pinPlaces: [second(0), first(0), first(1), first(2)], length: 2)
        case .multiTapDelay:
            return ChipPackage(name: "MN3011", terminalNames: ["in", "cp"] + (1...6).map { "out\($0)" },
                               pinLabels: ["IN", "CP"] + (1...6).map { "OUT\($0)" },
                               pinPlaces: [second(0), second(1)] + (0...5).map(first), length: 5)
        case .effectsProcessor:
            return ChipPackage(name: "FV-1", terminalNames: ["in", "pot0", "pot1", "pot2", "outL", "outR"],
                               pinLabels: ["IN", "POT0", "POT1", "POT2", "OUT L", "OUT R"],
                               pinPlaces: [second(0), second(1), second(2), second(3), first(0), first(1)], length: 3)
        case .reverbBrick:
            return ChipPackage(name: "BTDR-2H", terminalNames: ["in", "gnd", "out1", "out2"], pinLabels: ["IN", "GND", "OUT 1", "OUT 2"],
                               pinPlaces: [second(0), second(2), first(0), first(1)], length: 2)
        case .analogEngine:
            return ChipPackage(name: "THAT4301", terminalNames: ["in", "ec", "out", "rmsIn", "rmsOut", "oaMinus", "oaPlus", "oaOut"],
                               pinLabels: ["VCA IN", "EC−", "VCA OUT", "RMS IN", "RMS OUT", "OA −IN", "OA +IN", "OA OUT"],
                               pinPlaces: [second(0), second(1), first(0), second(3), first(3), second(5), second(6), first(5)], length: 6)
        case .footswitch:
            return ChipPackage(name: "3PDT", terminalNames: ["c1", "a1", "b1", "c2", "a2", "b2", "c3", "a3", "b3"],
                               pinLabels: ["1 COM", "1 BYPASS", "1 EFFECT", "2 COM", "2 BYPASS", "2 EFFECT", "3 COM", "3 BYPASS", "3 EFFECT"],
                               pinPlaces: [second(0), first(0), first(1), second(2), first(2), first(3), second(4), first(4), first(5)], length: 5)
        case .tappedTransformer:
            return ChipPackage(name: "CT", terminalNames: ["a1", "a2", "b1", "ct", "b2"], pinLabels: ["A1", "A2", "B1", "CT", "B2"],
                               pinPlaces: [second(0), second(2), first(0), first(1), first(2)], length: 2)
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
        case .balancedModulator:
            return [
                ParamSpec("supply", "Negative supply (pin 14)", unit: "V", default: 8, range: 3...15, log: false),
                ParamSpec("beta", "Its transistors' current gain", unit: "", default: 100, range: 20...500),
            ]
        case .mixerOscillator:
            return [
                ParamSpec("supply", "Supply (pin 8)", unit: "V", default: 6, range: 4.5...8, log: false),
                ParamSpec("tail", "Mixer current", unit: "A", default: 1e-3, range: 1e-4...5e-3),
            ]
        case .functionGenerator:
            return [
                .choice("family", "Chip", ["XR2206: timing resistor to ground, AM on CONTROL",
                                           "ICL8038: timing resistor to V+, frequency sweep on CONTROL",
                                           "LM566: timing resistor to V+, frequency control on CONTROL"]),
                ParamSpec("supply", "Supply", unit: "V", default: 12, range: 5...26, log: false),
                ParamSpec("capacitance", "Timing capacitor (fitted on its C pins)", unit: "F", default: 10e-9, range: 1e-12...1e-3),
                .choice("waveform", "OUT", ["Sine", "Triangle"]),
                ParamSpec("amplitude", "XR2206: OUT's peak (set by pin 3's resistor)", unit: "V", default: 2, range: 0.01...6),
            ]
        case .nortonAmp:
            return [ParamSpec("supply", "Supply", unit: "V", default: 15, range: 4...32, log: false)]
        case .bbdClock:
            return [
                ParamSpec("supply", "Supply (VDD): the clocks swing from 0 V to it", unit: "V", default: 15, range: 4...18, log: false),
                ParamSpec("capacitance", "Timing capacitor (CX)", unit: "F", default: 100e-12, range: 10e-12...10e-9),
            ]
        case .multiTapDelay:
            return [ParamSpec("gain", "Gain", unit: "", default: 1, range: 0...2, log: false)]
        case .effectsProcessor:
            return [
                .choice("program", "Program (S0–S2)", EffectsProcessor.programs, default: 6),
                ParamSpec("supply", "Supply: the POT inputs read from 0 V to it", unit: "V", default: 3.3, range: 3...3.6, log: false),
            ]
        case .agcPreamp:
            return [
                ParamSpec("gain", "Preamp gain", unit: "", default: 10, range: 1...100),
                ParamSpec("ratio", "Compression ratio above the rotation point", unit: "", default: 3, range: 1...15),
                ParamSpec("rotation", "Rotation point (RMS out of the preamp)", unit: "V", default: 0.1, range: 0.01...1),
                ParamSpec("gate", "Noise gate threshold (RMS out of the preamp)", unit: "V", default: 0.002, range: 1e-4...0.1),
                ParamSpec("averaging", "Detector averaging time", unit: "s", default: 0.01, range: 1e-3...1),
                ParamSpec("limit", "Output swing", unit: "V", default: 2, range: 0.5...5, log: false),
            ]
        case .analogEngine:
            return [
                ParamSpec("supply", "Supply (±)", unit: "V", default: 15, range: 5...18, log: false),
                ParamSpec("averaging", "RMS detector's time constant (its timing capacitor)", unit: "s", default: 0.035, range: 1e-3...1),
            ]
        case .reverbBrick:
            return [
                ParamSpec("decay", "Decay time (−60 dB)", unit: "s", default: 2.5, range: 0.5...6),
                ParamSpec("level", "Output for each volt in", unit: "", default: 0.5, range: 0.05...2),
            ]
        case .tappedTransformer:
            return [
                ParamSpec("inductance", "Inductance of winding A", unit: "H", default: 1.5, range: 1e-3...100),
                ParamSpec("ratio", "Turns of the whole tapped winding ÷ winding A", unit: "", default: 1, range: 0.01...100),
                ParamSpec("coupling", "Coupling (1: no leakage)", unit: "", default: 0.995, range: 0.5...1, log: false),
                ParamSpec("ra", "Winding A resistance", unit: "Ω", default: 40, range: 0...100_000, log: false),
                ParamSpec("rb", "Tapped winding resistance (whole)", unit: "Ω", default: 40, range: 0...100_000, log: false),
            ]
        default:
            return []
        }
    }

    var audioModels: [PartModel] {
        switch self {
        case .balancedModulator:
            return [
                PartModel(name: "MC1496", summary: "Balanced modulator: a Gilbert cell, the classic ring modulator chip (the LM1496 is the same). Bias it with about 1 mA into pin 5",
                          values: ["supply": 8, "beta": 100]),
            ]
        case .mixerOscillator:
            return [
                PartModel(name: "SA612", summary: "Double-balanced mixer with its own oscillator (the NE602 and NE612): 1.5 kΩ inputs and outputs, on 4.5 to 8 V",
                          values: ["supply": 6, "tail": 1e-3]),
            ]
        case .functionGenerator:
            return [
                PartModel(name: "XR2206", summary: "Function generator: sine (or triangle) and square at 1 / (R C), R from TIMING (pin 7) to ground; amplitude modulation on CONTROL (pin 1)",
                          values: ["family": 0]),
                PartModel(name: "ICL8038", summary: "Function generator: sine (or triangle) and square at 0.15 / (R C), R from TIMING (pins 4 and 5) to V+; lowering CONTROL (pin 8) raises the frequency",
                          values: ["family": 1]),
                PartModel(name: "LM566", summary: "VCO: triangle and square at 2 (V+ − CONTROL) / (R C V+), R from TIMING (pin 6) to V+",
                          values: ["family": 2]),
            ]
        case .bbdClock:
            return [
                PartModel(name: "MN3101", summary: "Two-phase clock driver for the MN3000 bucket brigades (MN3005, MN3007, MN3008, MN3011): CP1 and CP2 in antiphase at about 1 / (2.2 R C), R from RX to ground (an LFO through a resistor into RX sweeps it), and VGG at 14/15 of the supply",
                          values: ["supply": 15]),
                PartModel(name: "MN3102", summary: "The MN3101 for the 9 V MN3200 bucket brigades (MN3205, MN3207): the clock driver of most chorus and delay pedals",
                          values: ["supply": 9]),
            ]
        case .multiTapDelay:
            return [
                PartModel(name: "MN3011", summary: "3328-stage bucket brigade with six outputs, at 396, 662, 1194, 1726, 2790 and 3328 stages: no delay a multiple of another, for BBD reverbs and multi-head echoes. Clock it from an MN3101",
                          values: ["gain": 1]),
            ]
        case .effectsProcessor:
            return [
                PartModel(name: "FV-1", summary: "Spin's effects DSP: eight programs in ROM (reverbs, chorus, flanger, tremolo, pitch), three pots, stereo out, at 32.768 kHz on 3.3 V. Its programs here are rewritten, not Spin's code",
                          values: ["supply": 3.3]),
            ]
        case .reverbBrick:
            return [
                PartModel(name: "BTDR-2H", summary: "Belton reverb brick (Accutronics): a spring reverb's sound from delay chips, wet only, on 5 V; the brick of most reverb pedals",
                          values: ["decay": 2.5, "level": 0.5]),
            ]
        case .agcPreamp:
            return [
                PartModel(name: "SSM2166", summary: "Mic preamp with a VCA, an RMS detector and a gain computer: compression from 1:1 to 15:1 above an adjustable rotation point and a noise gate below an adjustable threshold, on one 5 V supply (its output rides at half the supply; here about 0 V)",
                          values: ["gain": 10, "ratio": 3, "rotation": 0.1, "gate": 0.002, "averaging": 0.01, "limit": 2]),
                PartModel(name: "SSM2167", summary: "Its 3 V sibling with a fixed preamp: ratio and gate set as on the SSM2166, a smaller swing",
                          values: ["gain": 5, "ratio": 3, "rotation": 0.1, "gate": 0.002, "averaging": 0.01, "limit": 1]),
            ]
        case .analogEngine:
            return [
                PartModel(name: "THAT4301", summary: "THAT's Analog Engine: a 2180-type VCA (−6.1 mV per dB at EC−), a 2252-type RMS detector (+6.1 mV per dB, 0 V at 0.775 V RMS) and a spare op-amp: compressors, limiters and gates",
                          values: ["supply": 15, "averaging": 0.035]),
            ]
        case .nortonAmp:
            return [
                PartModel(name: "LM3900", summary: "One of four Norton (current-differencing) amplifiers: its inputs are junctions at 0.5 V, and it amplifies the difference of their currents. Single supply, 2.5 MHz, 0.5 V/µs",
                          values: ["supply": 15]),
            ]
        case .tappedTransformer:
            return [
                PartModel(name: "600 Ω : 600 Ω CT", summary: "A small audio transformer, its secondary centre-tapped: the diode ring modulator's",
                          values: ["inductance": 1.5, "ratio": 1, "coupling": 0.995, "ra": 40, "rb": 40]),
                PartModel(name: "10 kΩ : 10 kΩ CT", summary: "A high-impedance interstage transformer with a centre tap: phase splitting",
                          values: ["inductance": 25, "ratio": 1, "coupling": 0.995, "ra": 500, "rb": 500]),
            ]
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

    mutating func npn(base: GridPoint, collector: GridPoint, emitter: GridPoint, _ suffix: String, _ params: [String: Double]) {
        let a = place()
        let part = add(.npn, a, a + GridPoint(2, 0), suffix, params)
        let posts = part.posts
        add(.wire, posts[0], base, suffix + "b")
        add(.wire, posts[1], collector, suffix + "c")
        add(.wire, posts[2], emitter, suffix + "e")
    }

    /// An ideal transformer core (the voltage across s1–s2 `ratio` times that across p1–p2), wired to the given points
    mutating func core(_ p1: GridPoint, _ p2: GridPoint, _ s1: GridPoint, _ s2: GridPoint, ratio: Double, _ suffix: String) {
        let a = place()
        let part = add(.transformer, a, a + GridPoint(4, 0), suffix, ["core": 1, "ratio": ratio])
        let posts = part.posts
        for (k, point) in [p1, p2, s1, s2].enumerated() where k < posts.count { add(.wire, posts[k], point, suffix + "w\(k)") }
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
        case .balancedModulator where p.count == 9:
            // the MC1496's Gilbert cell, transistor by transistor: the signal pair Q5–Q6 (its emitters at the gain pins,
            // a resistor between them setting its gain), each fed by a current source mirrored from the bias pin (a
            // diode and 500 Ω to V− like theirs), and the carrier's quad Q1–Q4 switching their currents between the
            // outputs. The outputs need load resistors to a positive supply.
            let (sigPlus, sigMinus, carPlus, carMinus, bias, gain1, gain2, outPlus, outMinus) =
                (p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8])
            let (g, vee, c5, c6, ed, e7, e8) = (node(), node(), node(), node(), node(), node(), node())
            ground(g)
            add(.dcVoltage, vee, g, "VEE", ["voltage": param("supply")])
            let q = ["beta": param("beta"), "saturationCurrent": 1e-15, "cje": 0.5e-12, "cjc": 0.3e-12, "tf": 0.3e-9]
            npn(base: bias, collector: bias, emitter: ed, "QD", q)
            resistor(ed, vee, 500, "RD")
            npn(base: bias, collector: gain1, emitter: e7, "Q7", q)
            resistor(e7, vee, 500, "R7")
            npn(base: bias, collector: gain2, emitter: e8, "Q8", q)
            resistor(e8, vee, 500, "R8")
            npn(base: sigPlus, collector: c5, emitter: gain1, "Q5", q)
            npn(base: sigMinus, collector: c6, emitter: gain2, "Q6", q)
            npn(base: carPlus, collector: outPlus, emitter: c5, "Q1", q)
            npn(base: carMinus, collector: outMinus, emitter: c5, "Q2", q)
            npn(base: carMinus, collector: outPlus, emitter: c6, "Q3", q)
            npn(base: carPlus, collector: outMinus, emitter: c6, "Q4", q)
        case .mixerOscillator where p.count == 6:
            // the SA612: its inputs biased at 1.6 V through 1.5 kΩ each into the signal pair (100 Ω of degeneration each,
            // a current source below), its outputs 1.5 kΩ each from the supply; the oscillator transistor's base at pin 6
            // (biased through 20 kΩ), its emitter at pin 7 with 0.25 mA below it, drives one side of the switching quad
            // against a matched transistor's emitter, so a carrier on pin 6 (or a crystal or LC tank across pins 6 and 7)
            // switches the mixer
            let (inA, inB, oscBase, oscEmitter, outA, outB) = (p[0], p[1], p[2], p[3], p[4], p[5])
            let (g, vcc, vin, vosc, reference, ea, eb, tail, ca, cb) = (node(), node(), node(), node(), node(), node(), node(),
                                                                        node(), node(), node())
            ground(g)
            let supply = param("supply")
            add(.dcVoltage, g, vcc, "VCC", ["voltage": supply])
            add(.dcVoltage, g, vin, "VIN", ["voltage": 1.6])
            add(.dcVoltage, g, vosc, "VOSC", ["voltage": min(4, supply - 0.8)])
            let q = ["beta": 120, "saturationCurrent": 1e-15, "cje": 0.3e-12, "cjc": 0.2e-12, "tf": 0.1e-9]
            resistor(inA, vin, 1500, "RA")
            resistor(inB, vin, 1500, "RB")
            npn(base: inA, collector: ca, emitter: ea, "Q5", q)
            npn(base: inB, collector: cb, emitter: eb, "Q6", q)
            resistor(ea, tail, 100, "REA")
            resistor(eb, tail, 100, "REB")
            add(.currentSource, tail, g, "IT", ["current": param("tail")])
            resistor(oscBase, vosc, 20_000, "RO")
            npn(base: oscBase, collector: vcc, emitter: oscEmitter, "QO", q)
            add(.currentSource, oscEmitter, g, "IO", ["current": 0.25e-3])
            npn(base: vosc, collector: vcc, emitter: reference, "QR", q)
            add(.currentSource, reference, g, "IR", ["current": 0.25e-3])
            npn(base: oscEmitter, collector: outA, emitter: ca, "Q1", q)
            npn(base: reference, collector: outB, emitter: ca, "Q2", q)
            npn(base: reference, collector: outA, emitter: cb, "Q3", q)
            npn(base: oscEmitter, collector: outB, emitter: cb, "Q4", q)
            resistor(vcc, outA, 1500, "RLA")
            resistor(vcc, outB, 1500, "RLB")
        case .functionGenerator where p.count == 4:
            // a timing current sensed across 10 Ω sets two oscillators running in step (OUT's sine or triangle and the
            // square), its frequency in proportion to the current, as the chip charges its capacitor with it
            let (timing, control, out, square) = (p[0], p[1], p[2], p[3])
            let supply = param("supply")
            let c = max(param("capacitance"), 1e-15)
            let sense = 10.0
            let (g, vcc, a, b, osc, sq, mid, sqm) = (node(), node(), node(), node(), node(), node(), node(), node())
            ground(g)
            add(.dcVoltage, g, vcc, "VCC", ["voltage": supply])
            let family = Int(param("family").rounded())
            // the timing current in amps per volt across the sense resistor, times the frequency each amp makes
            let hertzPerAmp: Double
            if family == 0 {
                // XR2206: pin 7 held at 3 V, the current out through R to ground; f = 1 / (R C) = I / (3 V × C)
                add(.dcVoltage, g, a, "VREF", ["voltage": 3])
                resistor(a, timing, sense, "RS")
                add(.wire, timing, b, "WS")
                hertzPerAmp = 1 / (3 * c)
            } else {
                // ICL8038 and LM566: the timing pin follows CONTROL, the current in from V+ through R; ICL8038
                // f = 0.15 / (R C) with CONTROL at 0.8 V+, LM566 f = 2 (V+ − CONTROL) / (R C V+)
                let (bias, buffered) = (node(), node())
                add(.dcVoltage, g, bias, "VBIAS", ["voltage": (family == 1 ? 0.8 : 0.85) * supply])
                resistor(control, bias, family == 1 ? 10_000 : 1e6, "RBIAS")
                opAmp(minus: buffered, plus: control, out: buffered, "AB", amplifier(supply: supply, gbw: 10e6, slew: 10))
                resistor(timing, buffered, sense, "RS")
                add(.wire, timing, a, "WS")
                add(.wire, buffered, b, "WB")
                hertzPerAmp = (family == 1 ? 0.75 : 2) / (supply * c)
            }
            let hzPerVolt = hertzPerAmp / sense
            let sine = family != 2 && param("waveform") < 0.5
            let peak: Double = family == 0 ? 1 : family == 1 ? (sine ? 0.22 : 0.33) * supply : 1.2
            threeTerminal(.vco, a, b, osc, "OSC", ["waveform": sine ? 3 : 1, "amplitude": peak, "response": 1, "hzPerVolt": hzPerVolt])
            threeTerminal(.vco, a, b, sq, "SQ", ["waveform": 2, "amplitude": family == 2 ? 2.7 : supply / 2, "response": 1,
                                                 "hzPerVolt": hzPerVolt])
            if family == 0 {
                // XR2206's amplitude modulation: OUT in proportion to CONTROL's distance from half the supply (full
                // amplitude with CONTROL at V+, where 100 kΩ inside holds it when left open)
                let am = node()
                resistor(control, vcc, 100_000, "RAM")
                add(.dcVoltage, am, control, "VAM", ["voltage": supply / 2])
                let product = node()
                threeTerminal(.multiplier, osc, am, product, "AM", ["scale": param("amplitude") / (supply / 2), "limit": supply / 2])
                add(.dcVoltage, product, mid, "VOFF", ["voltage": supply / 2])
            } else {
                add(.dcVoltage, osc, mid, "VOFF", ["voltage": supply / 2])
            }
            resistor(mid, out, family == 0 ? 600 : 1000, "RO")
            add(.dcVoltage, sq, sqm, "VSQ", ["voltage": supply / 2])
            resistor(sqm, square, family == 2 ? 50 : 1000, "RSQ")
        case .nortonAmp where p.count == 3:
            // the LM3900's Norton amplifier, transistor by transistor: the + input's current mirrored out of the − input
            // node, the − input the base of a common-emitter stage loaded by 200 µA, an emitter follower out with 1.3 mA
            // below it, and 470 pF of compensation from the gain stage back to the − input
            let (minus, plus, out) = (p[0], p[1], p[2])
            let (g, vcc, gain) = (node(), node(), node())
            ground(g)
            add(.dcVoltage, g, vcc, "VCC", ["voltage": param("supply")])
            let q = ["beta": 200, "saturationCurrent": 1e-14, "cje": 0.5e-12, "cjc": 0.3e-12, "tf": 0.5e-9]
            npn(base: plus, collector: plus, emitter: g, "Q1", q)
            npn(base: plus, collector: minus, emitter: g, "Q2", q)
            npn(base: minus, collector: gain, emitter: g, "Q3", q)
            add(.currentSource, vcc, gain, "ILOAD", ["current": 200e-6])
            capacitor(minus, gain, 470e-12, "CC")
            npn(base: gain, collector: vcc, emitter: out, "Q4", q)
            add(.currentSource, out, g, "IOUT", ["current": 1.3e-3])
        case .bbdClock where p.count == 4:
            // the clock: two oscillators in step on the current drawn from RX (held at 1 V behind 1 kΩ), in proportion
            // to it as an RC oscillator's frequency goes with 1 / R, so f = 1 / (2.2 C (R + 1 kΩ)); their square waves
            // lifted to swing from 0 V to VDD, CP2 the inverse of CP1. A bucket brigade clocked from either counts the
            // oscillator's cycles exactly, however coarse the steps.
            let (rx, cp1, cp2, vgg) = (p[0], p[1], p[2], p[3])
            let supply = param("supply")
            let c = max(param("capacitance"), 1e-15)
            let (g, ref, sq1, sq2) = (node(), node(), node(), node())
            ground(g)
            add(.dcVoltage, g, ref, "VREF", ["voltage": 1])
            resistor(ref, rx, 1000, "RINT")
            let hzPerVolt = 1 / (2.2 * c * 1000)
            threeTerminal(.vco, ref, rx, sq1, "OSC1", ["waveform": 2, "amplitude": supply / 2, "response": 1, "hzPerVolt": hzPerVolt])
            threeTerminal(.vco, ref, rx, sq2, "OSC2", ["waveform": 2, "amplitude": -supply / 2, "response": 1, "hzPerVolt": hzPerVolt])
            add(.dcVoltage, sq1, cp1, "VCP1", ["voltage": supply / 2])
            add(.dcVoltage, sq2, cp2, "VCP2", ["voltage": supply / 2])
            add(.dcVoltage, g, vgg, "VGG", ["voltage": supply * 14 / 15])
        case .multiTapDelay where p.count == 8:
            // six bucket brigades on the same input and clock, one per output, each as long as its tap is far along
            let taps: [Double] = [396, 662, 1194, 1726, 2790, 3328]
            for (k, stages) in taps.enumerated() {
                threeTerminal(.delayLine, p[0], p[1], p[2 + k], "BBD\(k + 1)", ["stages": stages, "clocking": 1, "gain": param("gain")])
            }
        case .reverbBrick where p.count == 4:
            // two springs' sound, a little different for each output, driven from the input against GND
            let (input, gnd, out1, out2) = (p[0], p[1], p[2], p[3])
            let (o1, o2) = (node(), node())
            let springs: [(GridPoint, GridPoint, Double, Double)] = [(out1, o1, 0.0335, 0.62), (out2, o2, 0.0291, 0.55)]
            for (k, spring) in springs.enumerated() {
                threeTerminal(.springReverb, input, gnd, spring.1, "SPRING\(k + 1)",
                              ["decay": param("decay"), "delay": spring.2, "gain": param("level"), "inputResistance": 20_000,
                               "dispersion": spring.3])
                resistor(spring.1, spring.0, 100, "RO\(k + 1)")
            }
        case .analogEngine where p.count == 8:
            // its VCA, its RMS detector (against ground) and its spare op-amp
            let (input, ec, out, rmsIn, rmsOut, oaMinus, oaPlus, oaOut) = (p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7])
            let supply = param("supply")
            let g = node()
            ground(g)
            threeTerminal(.vca, input, ec, out, "VCA", Examples.model(.vca, "THAT2180").merging(["limit": max(supply - 1.5, 1)]) { $1 })
            threeTerminal(.levelDetector, rmsIn, g, rmsOut, "RMS",
                          Examples.model(.levelDetector, "THAT2252").merging(["attack": param("averaging"), "release": param("averaging")]) { $1 })
            opAmp(minus: oaMinus, plus: oaPlus, out: oaOut, "OA", amplifier(supply: supply, gbw: 5e6, slew: 5))
        case .tappedTransformer where p.count == 5:
            // winding A's resistance and leakage, its magnetising inductance, and two ideal cores on it, each driving
            // half the tapped winding (with half its resistance), the halves joined at the tap
            let (a1, a2, b1, ct, b2) = (p[0], p[1], p[2], p[3], p[4])
            let k = min(max(param("coupling"), 0.01), 1)
            let la = max(param("inductance"), 1e-12)
            let half = max(param("ratio"), 1e-6) / 2 / k
            let (x, y, s1, s2) = (node(), node(), node(), node())
            resistor(a1, x, max(param("ra"), 1e-6), "RA")
            let leakage = (1 - k * k) * la
            if leakage > 1e-9 * la { inductor(x, y, leakage, "LLEAK") } else { add(.wire, x, y, "LLEAK") }
            inductor(y, a2, k * k * la, "LM")
            core(y, a2, s1, ct, ratio: half, "CORE1")
            core(y, a2, ct, s2, ratio: half, "CORE2")
            resistor(s1, b1, max(param("rb") / 2, 1e-6), "RB1")
            resistor(s2, b2, max(param("rb") / 2, 1e-6), "RB2")
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
