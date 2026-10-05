import Foundation

/// A ready-made circuit for the library.
public struct Example: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    /// SF Symbol name for the library
    public let symbol: String
    public let circuit: Circuit
}

/// Builds circuits from grid coordinates.
struct CircuitBuilder {
    var circuit = Circuit()

    @discardableResult
    mutating func add(_ kind: ElementKind, _ a: (Int, Int), _ b: (Int, Int), _ params: [String: Double] = [:],
                      closed: Bool = false, flipped: Bool = false, name: String = "") -> UUID {
        circuit.add(Element(kind: kind, name: name, a: GridPoint(a.0, a.1), b: GridPoint(b.0, b.1), params: params,
                            closed: closed, flipped: flipped))
    }

    /// Wires along a polyline
    mutating func wire(_ points: (Int, Int)...) {
        for i in 0..<(points.count - 1) {
            add(.wire, points[i], points[i + 1])
        }
    }

    mutating func ground(_ p: (Int, Int)) {
        add(.ground, p, (p.0, p.1 + 1))
    }

    mutating func scope(_ id: UUID, _ quantity: Quantity, plot: ScopePlot = .time) {
        circuit.scopes.append(ScopeSpec(elementID: id, quantity: quantity, plot: plot))
    }
}

public enum Examples {
    public static let all: [Example] = [
        ledSwitch, voltageDivider, rcCharging, lowPass, lcOscillator, rectifier, zenerRegulator, dimmer, blinker,
        transistorSwitch, cmosInverter, opAmpAmplifier, lfo, vca, timerFlasher, schmittOscillator, sampleAndHold,
        beeper, tone, tremolo, keyboardVCO, monoSynth, filter, wind, voice, memristorHysteresis, memristorPulses,
    ]

    /// A circuit drawn from a netlist by the tidy layout, with scopes on the named parts
    static func drawn(_ parts: [NetlistPart], scopes: [(String, Quantity)]) -> Circuit {
        var circuit = (try? SchematicLayout.layout(parts)) ?? Circuit()
        for (name, quantity) in scopes {
            if let element = circuit.elements.first(where: { $0.name == name }) {
                circuit.scopes.append(ScopeSpec(elementID: element.id, quantity: quantity))
            }
        }
        return circuit
    }

    static let beeper = Example(
        id: "beeper", title: "555 beeper (sound)",
        summary: "A 555 at about 460 Hz into a speaker. Turn on sound in the toolbar to hear it.",
        symbol: "speaker.wave.2",
        circuit: drawn([
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 9], connections: ["plus": "VCC", "minus": "GND"]),
            NetlistPart(kind: .timer555, name: "U1", params: model(.timer555, "NE555"),
                        connections: ["vcc": "VCC", "reset": "VCC", "gnd": "GND", "dis": "dis", "thr": "trig", "trig": "trig", "out": "out"]),
            NetlistPart(kind: .resistor, name: "RA", params: ["resistance": 1000], connections: ["a": "VCC", "b": "dis"]),
            NetlistPart(kind: .resistor, name: "RB", params: ["resistance": 15_000], connections: ["a": "dis", "b": "trig"]),
            NetlistPart(kind: .capacitor, name: "C1", params: ["capacitance": 100e-9], connections: ["a": "trig", "b": "GND"]),
            NetlistPart(kind: .capacitor, name: "C2", params: ["capacitance": 10e-6], connections: ["a": "out", "b": "spk"]),
            NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 10_000], connections: ["a": "spk", "b": "GND"]),
            NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 6], connections: ["plus": "spk", "minus": "GND"]),
        ], scopes: [("C1", .voltage), ("SPK1", .voltage)]))

    static let tone = Example(
        id: "tone", title: "Schmitt oscillator tone (sound)",
        summary: "One gate of a 40106 makes a square wave in the audio range. Turn on sound and scroll over the potentiometer to change the pitch.",
        symbol: "music.note",
        circuit: drawn([
            NetlistPart(kind: .schmittInverter, name: "U1", params: model(.schmittInverter, "CD40106"), connections: ["in": "cap", "out": "out"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 10_000], connections: ["a": "out", "b": "pitch"]),
            NetlistPart(kind: .potentiometer, name: "P1", params: ["resistance": 100_000, "position": 0.5], connections: ["a": "pitch", "wiper": "cap"]),
            NetlistPart(kind: .capacitor, name: "C1", params: ["capacitance": 22e-9], connections: ["a": "cap", "b": "GND"]),
            NetlistPart(kind: .capacitor, name: "C2", params: ["capacitance": 1e-6], connections: ["a": "out", "b": "spk"]),
            NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 10_000], connections: ["a": "spk", "b": "GND"]),
            NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 8], connections: ["plus": "spk", "minus": "GND"]),
        ], scopes: [("C1", .voltage), ("SPK1", .voltage)]))

    static let tremolo = Example(
        id: "tremolo", title: "OTA tremolo (sound)",
        summary: "An LM13700 VCA: a 4 Hz LFO sweeps the bias current, so a 220 Hz tone throbs. Turn on sound to hear it.",
        symbol: "waveform",
        circuit: drawn([
            NetlistPart(kind: .acVoltage, name: "VIN", params: ["amplitude": 5, "frequency": 220], connections: ["plus": "sig", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 100_000], connections: ["a": "sig", "b": "inm"]),
            NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 330], connections: ["a": "inm", "b": "GND"]),
            NetlistPart(kind: .ota, name: "U1", params: model(.ota, "LM13700"),
                        connections: ["minus": "inm", "plus": "GND", "out": "out", "bias": "iabc"]),
            NetlistPart(kind: .resistor, name: "RB", params: ["resistance": 15_000], connections: ["a": "cv", "b": "iabc"]),
            NetlistPart(kind: .acVoltage, name: "LFO", params: ["amplitude": 6, "frequency": 4, "offset": -7.5], connections: ["plus": "cv", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 10_000], connections: ["a": "out", "b": "GND"]),
            NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 4], connections: ["plus": "out", "minus": "GND"]),
        ], scopes: [("LFO", .voltage), ("SPK1", .voltage)]))



    /// The parts of a VCO that follows a keyboard at one volt per octave: an exponential converter (one PNP transistor)
    /// sets an LM13700's bias current, the OTA charges a capacitor with that current one way or the other, and a TL072
    /// comparator turns it round at ±4.5 V, so the capacitor ramps up and down in a triangle whose frequency is
    /// proportional to the current. One volt more at the base divider's input is 17.9 mV more across the transistor's
    /// base and emitter, which doubles its collector current: one octave. VREF tunes C4 (2 V) to 261.6 Hz.
    static let vcoParts: [NetlistPart] = [
        NetlistPart(kind: .keyboardPitch, name: "KB1", connections: ["plus": "cv", "minus": "GND"]),
        // the converter needs the pitch upside down: an inverting amplifier
        NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 10_000], connections: ["a": "cv", "b": "inv"]),
        NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 10_000], connections: ["a": "inv", "b": "ncv"]),
        NetlistPart(kind: .opAmp, name: "U1", params: model(.opAmp, "TL072"), connections: ["minus": "inv", "plus": "GND", "out": "ncv"]),
        // divider: 17.92 mV at the base per volt of pitch (Vt ln 2), plus the reference
        NetlistPart(kind: .resistor, name: "RA", params: ["resistance": 10_000], connections: ["a": "ncv", "b": "base"]),
        NetlistPart(kind: .resistor, name: "RB", params: ["resistance": 182.5], connections: ["a": "base", "b": "ref"]),
        NetlistPart(kind: .dcVoltage, name: "VREF", params: ["voltage": -0.550192], connections: ["plus": "ref", "minus": "GND"]),
        NetlistPart(kind: .pnp, name: "Q1", connections: ["base": "base", "emitter": "GND", "collector": "iabc"]),
        // the core: the OTA's current into CT, turned round by the comparator U2
        NetlistPart(kind: .ota, name: "U3", params: model(.ota, "LM13700"),
                    connections: ["minus": "GND", "plus": "sqdiv", "out": "tri", "bias": "iabc"]),
        NetlistPart(kind: .capacitor, name: "CT", params: ["capacitance": 10e-9], connections: ["a": "tri", "b": "GND"]),
        NetlistPart(kind: .opAmp, name: "U2", params: model(.opAmp, "TL072"), connections: ["minus": "tri", "plus": "hys", "out": "sq"]),
        NetlistPart(kind: .resistor, name: "R3", params: ["resistance": 20_000], connections: ["a": "sq", "b": "hys"]),
        NetlistPart(kind: .resistor, name: "R4", params: ["resistance": 10_000], connections: ["a": "hys", "b": "GND"]),
        NetlistPart(kind: .resistor, name: "R5", params: ["resistance": 100_000], connections: ["a": "sq", "b": "sqdiv"]),
        NetlistPart(kind: .resistor, name: "R6", params: ["resistance": 1000], connections: ["a": "sqdiv", "b": "GND"]),
    ]

    static let keyboardVCO = Example(
        id: "vco", title: "Keyboard VCO (1 V/octave)",
        summary: "An exponential converter and an LM13700 triangle core track the keyboard at one volt per octave. Turn on sound and play with A–; (or a MIDI keyboard).",
        symbol: "pianokeys",
        circuit: drawn(vcoParts + [
            NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 5], connections: ["plus": "tri", "minus": "GND"]),
        ], scopes: [("KB1", .voltage), ("SPK1", .voltage)]))

    /// The keyboard VCO's square wave through an OTA VCA whose bias current follows an envelope: while a key is held, the
    /// gate closes S1 and charges CENV from the gate through RATT (attack); when the key is let go, S1 opens and RREL
    /// pulls the envelope down to −15 V (release). RBIAS turns the envelope into the VCA's bias current, which is zero
    /// once the envelope is below the bias pin, two junctions above −15 V.
    static let monoSynth = Example(
        id: "synth", title: "Mono synth: VCO, envelope and VCA",
        summary: "A playable synth voice: the keyboard VCO's square wave, an attack–release envelope from the gate, and an LM13700 VCA. Turn on sound and play with A–; (or a MIDI keyboard).",
        symbol: "pianokeys.inverse",
        circuit: drawn(vcoParts + [
            NetlistPart(kind: .keyboardGate, name: "KB2", params: ["high": 10], connections: ["plus": "gate", "minus": "GND"]),
            NetlistPart(kind: .dcVoltage, name: "VN", params: ["voltage": 15], connections: ["plus": "GND", "minus": "-15V"]),
            NetlistPart(kind: .resistor, name: "RATT", params: ["resistance": 2200], connections: ["a": "gate", "b": "att"]),
            NetlistPart(kind: .analogSwitch, name: "S1", params: model(.analogSwitch, "DG411"),
                        connections: ["a": "att", "b": "env", "control": "gate"]),
            NetlistPart(kind: .capacitor, name: "CENV", params: ["capacitance": 4.7e-6, "initialVoltage": -15],
                        connections: ["a": "env", "b": "GND"]),
            NetlistPart(kind: .resistor, name: "RREL", params: ["resistance": 220_000], connections: ["a": "env", "b": "-15V"]),
            NetlistPart(kind: .resistor, name: "RBIAS", params: ["resistance": 33_000], connections: ["a": "env", "b": "iabc2"]),
            // the comparator's square wave, divided down to ±29 mV for the OTA's input
            NetlistPart(kind: .resistor, name: "RIN", params: ["resistance": 470_000], connections: ["a": "sq", "b": "vin"]),
            NetlistPart(kind: .resistor, name: "RIN2", params: ["resistance": 1000], connections: ["a": "vin", "b": "GND"]),
            NetlistPart(kind: .ota, name: "U4", params: model(.ota, "LM13700"),
                        connections: ["minus": "GND", "plus": "vin", "out": "out", "bias": "iabc2"]),
            NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 10_000], connections: ["a": "out", "b": "GND"]),
            NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 4], connections: ["plus": "out", "minus": "GND"]),
        ], scopes: [("CENV", .voltage), ("SPK1", .voltage)]))

    /// An LM13700 state-variable filter, 12 dB per octave, fed from `input` (a source whose plus terminal is the net "in").
    ///
    /// U1 integrates the input less the low-pass and some of the band-pass output into C1 (band-pass), U3 integrates the
    /// band-pass into C2 (low-pass); TL072 followers buffer both capacitors. Each OTA input sits behind a 100 k / 220 Ω
    /// divider (a = 0.0022), which keeps it within ±10 mV, where the OTA is nearly linear. The cutoff is
    /// f0 = gm a / (2π C) with gm = I_abc / 2Vt: the CUTOFF pot sets both bias currents through the follower U5, about
    /// 295 µA (2 kHz) at its centre. The RES pot feeds back band-pass: Q is about its resistance over 100 k.
    public static func filterParts(input: NetlistPart, resonance: Double = 0.5) -> [NetlistPart] {
        [
            input,
            NetlistPart(kind: .dcVoltage, name: "VP", params: ["voltage": 15], connections: ["plus": "+15V", "minus": "GND"]),
            NetlistPart(kind: .dcVoltage, name: "VN", params: ["voltage": 15], connections: ["plus": "GND", "minus": "-15V"]),
        ] + filterCore(input: "in", output: "lp", control: "cutb", resonance: resonance) + [
            // cutoff: a pot across the supplies, buffered, sets both OTAs' bias currents
            NetlistPart(kind: .potentiometer, name: "CUTOFF", params: ["resistance": 100_000, "position": 0.5],
                        connections: ["a": "-15V", "b": "+15V", "wiper": "cut"]),
            NetlistPart(kind: .opAmp, name: "U5", params: model(.opAmp, "TL072"), connections: ["plus": "cut", "minus": "cutb", "out": "cutb"]),
        ]
    }

    /// The filter itself, from net `input` to net `output` (low-pass), its bias currents set from net `control` through
    /// 47 k each (so the cutoff is zero with the control at −13.9 V and rises in proportion above it). Part and inner net
    /// names start with `prefix`, so the filter can share a circuit with other parts.
    static func filterCore(input: String, output: String, control: String, resonance: Double, prefix: String = "") -> [NetlistPart] {
        let tl072 = model(.opAmp, "TL072")
        let lm13700 = model(.ota, "LM13700")
        func n(_ name: String) -> String { prefix.isEmpty ? name : prefix.lowercased() + name }
        func r(_ name: String, _ ohms: Double, _ a: String, _ b: String) -> NetlistPart {
            NetlistPart(kind: .resistor, name: prefix + name, params: ["resistance": ohms], connections: ["a": a, "b": b])
        }
        return [
            r("R1", 100_000, input, n("p1")),
            r("R2", 220, n("p1"), "GND"),
            NetlistPart(kind: .ota, name: prefix + "U1", params: lm13700,
                        connections: ["plus": n("p1"), "minus": n("m1"), "out": n("c1"), "bias": n("b1")]),
            NetlistPart(kind: .capacitor, name: prefix + "C1", params: ["capacitance": 1e-9], connections: ["a": n("c1"), "b": "GND"]),
            NetlistPart(kind: .opAmp, name: prefix + "U2", params: tl072, connections: ["plus": n("c1"), "minus": n("bp"), "out": n("bp")]),
            r("R3", 100_000, n("bp"), n("p2")),
            r("R4", 220, n("p2"), "GND"),
            NetlistPart(kind: .ota, name: prefix + "U3", params: lm13700,
                        connections: ["plus": n("p2"), "minus": "GND", "out": n("c2"), "bias": n("b2")]),
            NetlistPart(kind: .capacitor, name: prefix + "C2", params: ["capacitance": 1e-9], connections: ["a": n("c2"), "b": "GND"]),
            NetlistPart(kind: .opAmp, name: prefix + "U4", params: tl072, connections: ["plus": n("c2"), "minus": output, "out": output]),
            // feedback into U1's minus input: all of the low-pass, and some band-pass (the resonance control)
            r("R5", 100_000, output, n("m1")),
            r("R6", 220, n("m1"), "GND"),
            NetlistPart(kind: .potentiometer, name: prefix + "RES", params: ["resistance": 470_000, "position": resonance],
                        connections: ["a": n("bp"), "wiper": n("m1")]),
            r("RB1", 47_000, control, n("b1")),
            r("RB2", 47_000, control, n("b2")),
        ]
    }

    /// A whole synth voice: the keyboard VCO's square wave through the resonant filter and a VCA, with one envelope
    /// opening both, so each note starts bright and closes as it dies away. The envelope (the gate through S1 and
    /// RATT into CENV, RREL down to −15 V) sets the filter's and the VCA's bias currents directly: an op-amp buffer
    /// could not follow it down to −15 V, where both currents stop.
    static let voice = Example(
        id: "voice", title: "Synth voice: VCO, VCF, VCA",
        summary: "A playable subtractive synth voice: the keyboard VCO through the resonant LM13700 filter and a VCA, with one envelope opening both. Turn on sound and play with A–; (or a MIDI keyboard); turn RES for more squelch.",
        symbol: "pianokeys.inverse",
        circuit: drawn(vcoParts + [
            NetlistPart(kind: .dcVoltage, name: "VN", params: ["voltage": 15], connections: ["plus": "GND", "minus": "-15V"]),
            // the square wave, divided to ±3.4 V for the filter
            NetlistPart(kind: .resistor, name: "R7", params: ["resistance": 100_000], connections: ["a": "sq", "b": "fin"]),
            NetlistPart(kind: .resistor, name: "R8", params: ["resistance": 33_000], connections: ["a": "fin", "b": "GND"]),
            // envelope
            NetlistPart(kind: .keyboardGate, name: "KB2", params: ["high": 10], connections: ["plus": "gate", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "RATT", params: ["resistance": 2200], connections: ["a": "gate", "b": "att"]),
            NetlistPart(kind: .analogSwitch, name: "S1", params: model(.analogSwitch, "DG411"),
                        connections: ["a": "att", "b": "env", "control": "gate"]),
            NetlistPart(kind: .capacitor, name: "CENV", params: ["capacitance": 4.7e-6, "initialVoltage": -15],
                        connections: ["a": "env", "b": "GND"]),
            NetlistPart(kind: .resistor, name: "RREL", params: ["resistance": 47_000], connections: ["a": "env", "b": "-15V"]),
        ] + filterCore(input: "fin", output: "flp", control: "env", resonance: 0.6, prefix: "F") + [
            // VCA
            NetlistPart(kind: .resistor, name: "RIN", params: ["resistance": 220_000], connections: ["a": "flp", "b": "vin"]),
            NetlistPart(kind: .resistor, name: "RIN2", params: ["resistance": 1000], connections: ["a": "vin", "b": "GND"]),
            NetlistPart(kind: .resistor, name: "RBIAS", params: ["resistance": 33_000], connections: ["a": "env", "b": "iabc2"]),
            NetlistPart(kind: .ota, name: "U6", params: model(.ota, "LM13700"),
                        connections: ["minus": "GND", "plus": "vin", "out": "out", "bias": "iabc2"]),
            NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 10_000], connections: ["a": "out", "b": "GND"]),
            NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 4], connections: ["plus": "out", "minus": "GND"]),
        ], scopes: [("CENV", .voltage), ("SPK1", .voltage)]))

    static let filter = Example(
        id: "vcf", title: "LM13700 filter (sound)",
        summary: "A resonant 12 dB/octave state-variable filter on a 110 Hz square wave. Turn on sound, then scroll over CUTOFF and RES to sweep it.",
        symbol: "waveform.path",
        circuit: drawn(filterParts(input: NetlistPart(kind: .squareVoltage, name: "VIN",
                                                      params: ["high": 4, "low": -4, "frequency": 110, "duty": 0.5],
                                                      connections: ["plus": "in", "minus": "GND"])) + [
            NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 8], connections: ["plus": "lp", "minus": "GND"]),
        ], scopes: [("VIN", .voltage), ("SPK1", .voltage)]))

    static let wind = Example(
        id: "wind", title: "Wind: filtered noise (sound)",
        summary: "White noise through the resonant LM13700 filter. Turn on sound and sweep CUTOFF slowly for wind, or turn up RES to whistle.",
        symbol: "wind",
        circuit: drawn(filterParts(input: NetlistPart(kind: .noiseVoltage, name: "NOISE", params: ["amplitude": 1],
                                                      connections: ["plus": "in", "minus": "GND"]), resonance: 0.85) + [
            NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 5], connections: ["plus": "lp", "minus": "GND"]),
        ], scopes: [("SPK1", .voltage)]))

    /// Parameter values of one of the part's models, by name
    public static func model(_ kind: ElementKind, _ name: String) -> [String: Double] {
        kind.models.first { $0.name == name }?.values ?? [:]
    }

    public static func example(_ id: String) -> Example? {
        all.first { $0.id == id }
    }

    static let ledSwitch: Example = {
        var b = CircuitBuilder()
        b.add(.dcVoltage, (0, 6), (0, 2), ["voltage": 9])
        b.wire((0, 2), (0, 0), (2, 0))
        b.add(.toggleSwitch, (2, 0), (6, 0), closed: true)
        b.add(.resistor, (6, 0), (10, 0), ["resistance": 330])
        b.wire((10, 0), (12, 0), (12, 2))
        b.add(.led, (12, 2), (12, 6), ["color": 0])
        b.wire((12, 6), (12, 8), (0, 8), (0, 6))
        b.ground((0, 8))
        return Example(id: "led", title: "LED and switch", summary: "Click the switch to turn the LED on and off.",
                       symbol: "lightbulb", circuit: b.circuit)
    }()

    static let voltageDivider: Example = {
        var b = CircuitBuilder()
        b.add(.dcVoltage, (0, 6), (0, 2), ["voltage": 10])
        b.wire((0, 2), (0, 0), (6, 0))
        b.add(.resistor, (6, 0), (6, 4), ["resistance": 1000])
        b.add(.resistor, (6, 4), (6, 8), ["resistance": 2000])
        b.wire((6, 8), (0, 8), (0, 6))
        b.wire((6, 4), (10, 4))
        b.wire((6, 8), (10, 8))
        b.add(.probe, (10, 4), (10, 8))
        b.ground((0, 8))
        return Example(id: "divider", title: "Voltage divider", summary: "Two resistors split 10 V in the ratio 1 : 2.",
                       symbol: "divide", circuit: b.circuit)
    }()

    static let rcCharging: Example = {
        var b = CircuitBuilder()
        b.add(.dcVoltage, (0, 6), (0, 2), ["voltage": 5])
        b.wire((0, 2), (0, 0), (2, 0))
        b.add(.toggleSwitch, (2, 0), (6, 0), closed: false)
        b.add(.resistor, (6, 0), (10, 0), ["resistance": 10_000])
        b.wire((10, 0), (12, 0), (12, 2))
        let c = b.add(.capacitor, (12, 2), (12, 6), ["capacitance": 100e-6])
        b.wire((12, 0), (16, 0), (16, 2))
        b.add(.resistor, (16, 2), (16, 6), ["resistance": 10_000])
        b.wire((16, 6), (16, 8), (12, 8))
        b.wire((12, 6), (12, 8), (0, 8), (0, 6))
        b.ground((0, 8))
        b.scope(c, .voltage)
        return Example(id: "rc", title: "Capacitor charging", summary: "Close the switch and watch the capacitor charge, in real time.",
                       symbol: "battery.50percent", circuit: b.circuit)
    }()

    static let lowPass: Example = {
        var b = CircuitBuilder()
        let source = b.add(.squareVoltage, (0, 6), (0, 2), ["high": 5, "low": 0, "frequency": 100, "duty": 0.5])
        b.wire((0, 2), (0, 0), (2, 0))
        b.add(.resistor, (2, 0), (6, 0), ["resistance": 1000])
        b.wire((6, 0), (8, 0), (8, 2))
        let c = b.add(.capacitor, (8, 2), (8, 6), ["capacitance": 1e-6])
        b.wire((8, 6), (8, 8), (0, 8), (0, 6))
        b.ground((0, 8))
        b.scope(source, .voltage)
        b.scope(c, .voltage)
        return Example(id: "lowpass", title: "RC low-pass filter", summary: "A 100 Hz square wave rounded off by an RC filter, in slow motion.",
                       symbol: "waveform.path", circuit: b.circuit)
    }()

    static let lcOscillator: Example = {
        var b = CircuitBuilder()
        let c = b.add(.capacitor, (0, 2), (0, 6), ["capacitance": 10e-6, "initialVoltage": 5])
        b.wire((0, 2), (0, 0), (2, 0))
        b.add(.toggleSwitch, (2, 0), (6, 0), closed: false)
        b.wire((6, 0), (8, 0), (8, 2))
        let l = b.add(.inductor, (8, 2), (8, 6), ["inductance": 1])
        b.wire((8, 6), (8, 8), (0, 8), (0, 6))
        b.ground((0, 8))
        b.scope(c, .voltage)
        b.scope(l, .current)
        return Example(id: "lc", title: "LC oscillator", summary: "Close the switch: a charged capacitor and a coil swap energy at 50 Hz.",
                       symbol: "waveform", circuit: b.circuit)
    }()

    static let rectifier: Example = {
        var b = CircuitBuilder()
        let source = b.add(.acVoltage, (0, 6), (0, 2), ["amplitude": 10, "frequency": 60])
        b.wire((0, 2), (0, 0), (2, 0))
        b.add(.diode, (2, 0), (6, 0))
        b.wire((6, 0), (8, 0), (8, 2))
        let c = b.add(.capacitor, (8, 2), (8, 6), ["capacitance": 100e-6])
        b.wire((8, 0), (12, 0), (12, 2))
        b.add(.resistor, (12, 2), (12, 6), ["resistance": 1000])
        b.wire((12, 6), (12, 8), (8, 8), (0, 8), (0, 6))
        b.wire((8, 6), (8, 8))
        b.ground((0, 8))
        b.scope(source, .voltage)
        b.scope(c, .voltage)
        return Example(id: "rectifier", title: "Half-wave rectifier", summary: "A diode and a capacitor turn 60 Hz AC into DC.",
                       symbol: "arrow.right.to.line", circuit: b.circuit)
    }()

    static let transistorSwitch: Example = {
        var b = CircuitBuilder()
        b.add(.dcVoltage, (0, 10), (0, 6), ["voltage": 5])
        b.wire((0, 6), (0, 0))
        b.wire((0, 0), (4, 0))
        b.wire((4, 0), (10, 0))
        b.add(.resistor, (10, 0), (10, 4), ["resistance": 220])
        b.add(.led, (10, 4), (10, 8), ["color": 1])
        b.add(.nmos, (8, 10), (10, 10))
        b.wire((10, 12), (10, 14))
        b.wire((10, 14), (4, 14))
        b.wire((4, 14), (0, 14))
        b.wire((0, 14), (0, 10))
        b.add(.toggleSwitch, (4, 0), (4, 4), closed: false)
        b.wire((4, 4), (4, 10))
        b.wire((4, 10), (8, 10))
        b.add(.resistor, (4, 10), (4, 14), ["resistance": 10_000])
        b.ground((0, 14))
        return Example(id: "nmos", title: "Transistor switch", summary: "A MOSFET lets a small switch current control an LED.",
                       symbol: "switch.2", circuit: b.circuit)
    }()

    static let cmosInverter: Example = {
        var b = CircuitBuilder()
        b.add(.dcVoltage, (0, 10), (0, 6), ["voltage": 5])
        b.wire((0, 6), (0, 0))
        b.wire((0, 0), (2, 0))
        b.wire((2, 0), (8, 0))
        b.wire((8, 0), (8, 4))
        b.add(.pmos, (6, 6), (8, 6))
        b.add(.nmos, (6, 10), (8, 10))
        b.wire((6, 6), (6, 8))
        b.wire((6, 8), (6, 10))
        b.wire((8, 12), (8, 16))
        b.add(.toggleSwitch, (2, 0), (2, 4), closed: false)
        b.wire((2, 4), (2, 8))
        b.wire((2, 8), (6, 8))
        b.add(.resistor, (2, 8), (2, 12), ["resistance": 10_000])
        b.wire((2, 12), (2, 16))
        b.wire((8, 8), (12, 8))
        b.add(.resistor, (12, 8), (12, 12), ["resistance": 330])
        b.add(.led, (12, 12), (12, 16), ["color": 3])
        b.wire((12, 8), (16, 8))
        let probe = b.add(.probe, (16, 8), (16, 16))
        b.wire((0, 10), (0, 16))
        b.wire((0, 16), (2, 16))
        b.wire((2, 16), (8, 16))
        b.wire((8, 16), (12, 16))
        b.wire((12, 16), (16, 16))
        b.ground((0, 16))
        _ = probe
        return Example(id: "cmos", title: "CMOS inverter", summary: "Two transistors invert the input: switch on, LED off.",
                       symbol: "arrow.left.arrow.right", circuit: b.circuit)
    }()

    static let memristorHysteresis: Example = {
        var b = CircuitBuilder()
        let source = b.add(.acVoltage, (0, 6), (0, 2), ["amplitude": 1, "frequency": 1])
        b.wire((0, 2), (0, 0), (2, 0))
        let memristor = b.add(.memristor, (2, 0), (6, 0), ["ron": 1000, "roff": 10_000, "von": 0.3, "voff": 0.3, "tau": 0.05])
        b.add(.resistor, (6, 0), (10, 0), ["resistance": 100])
        b.wire((10, 0), (12, 0), (12, 8), (0, 8), (0, 6))
        b.ground((0, 8))
        b.scope(source, .voltage)
        b.scope(memristor, .resistance)
        b.scope(memristor, .current, plot: .currentVersusVoltage)
        return Example(id: "memristor", title: "Memristor hysteresis", summary: "A 1 Hz sine switches a memristor on and off, tracing its pinched I–V loop.",
                       symbol: "memorychip", circuit: b.circuit)
    }()

    static let zenerRegulator: Example = {
        var b = CircuitBuilder()
        b.add(.dcVoltage, (0, 6), (0, 2), ["voltage": 12])
        b.wire((0, 2), (0, 0), (2, 0))
        b.add(.resistor, (2, 0), (6, 0), ["resistance": 470])
        b.wire((6, 0), (8, 0), (8, 2))
        b.add(.zener, (8, 6), (8, 2), ["breakdown": 5.1])
        b.wire((8, 0), (12, 0), (12, 2))
        b.add(.resistor, (12, 2), (12, 6), ["resistance": 1000])
        b.wire((12, 0), (16, 0), (16, 2))
        b.add(.probe, (16, 2), (16, 6))
        b.wire((16, 6), (16, 8))
        b.wire((0, 6), (0, 8), (8, 8), (12, 8), (16, 8))
        b.wire((8, 6), (8, 8))
        b.wire((12, 6), (12, 8))
        b.ground((0, 8))
        return Example(id: "zener", title: "Zener regulator", summary: "A Zener diode holds the output at 5.1 V. Try changing the 12 V supply.",
                       symbol: "bolt.badge.checkmark", circuit: b.circuit)
    }()

    static let dimmer: Example = {
        var b = CircuitBuilder()
        b.add(.dcVoltage, (0, 10), (0, 6), ["voltage": 9])
        b.wire((0, 6), (0, 0), (6, 0))
        b.wire((6, 0), (16, 0))
        b.wire((6, 0), (6, 2))
        b.add(.potentiometer, (6, 2), (6, 6), ["resistance": 10_000, "position": 0.5])
        b.wire((8, 4), (8, 10))
        b.add(.resistor, (8, 10), (12, 10), ["resistance": 47_000])
        b.wire((12, 10), (14, 10))
        b.add(.npn, (14, 10), (16, 10))
        b.add(.resistor, (16, 0), (16, 4), ["resistance": 330])
        b.add(.led, (16, 4), (16, 8), ["color": 3])
        b.wire((16, 12), (16, 14))
        b.wire((6, 6), (6, 14))
        b.wire((0, 10), (0, 14), (6, 14), (16, 14))
        b.ground((0, 14))
        return Example(id: "dimmer", title: "Light dimmer", summary: "Turn the potentiometer (scroll over it) to dim the LED through a transistor.",
                       symbol: "dial.medium", circuit: b.circuit)
    }()

    static let blinker: Example = {
        var b = CircuitBuilder()
        b.add(.dcVoltage, (0, 10), (0, 6), ["voltage": 9])
        b.wire((0, 6), (0, 0))
        b.wire((0, 0), (4, 0), (8, 0), (12, 0), (16, 0))
        // each side: resistor, LED, transistor
        b.add(.resistor, (4, 0), (4, 3), ["resistance": 470])
        let led1 = b.add(.led, (4, 3), (4, 6), ["color": 0])
        b.wire((4, 6), (4, 9), (4, 10))
        b.add(.npn, (6, 12), (4, 12), flipped: true)
        b.add(.resistor, (16, 0), (16, 3), ["resistance": 470])
        b.add(.led, (16, 3), (16, 6), ["color": 1])
        b.wire((16, 6), (16, 10))
        b.add(.npn, (14, 12), (16, 12))
        // base resistors, slightly unequal so the circuit starts oscillating by itself
        b.add(.resistor, (8, 0), (8, 4), ["resistance": 47_000])
        b.wire((8, 4), (8, 6), (8, 12), (6, 12))
        b.add(.resistor, (12, 0), (12, 4), ["resistance": 51_000])
        b.wire((12, 4), (12, 9), (12, 12), (14, 12))
        // cross-coupling capacitors: each collector drives the other transistor's base (the wires cross unconnected)
        b.wire((4, 9), (9, 9))
        let c1 = b.add(.capacitor, (9, 9), (12, 9), ["capacitance": 10e-6])
        b.wire((16, 6), (11, 6))
        b.add(.capacitor, (11, 6), (8, 6), ["capacitance": 10e-6])
        b.wire((4, 14), (4, 16))
        b.wire((16, 14), (16, 16))
        b.wire((0, 10), (0, 16), (4, 16), (16, 16))
        b.ground((0, 16))
        b.scope(led1, .current)
        b.scope(c1, .voltage)
        return Example(id: "blinker", title: "Blinking LEDs", summary: "Two transistors take turns, flashing the LEDs about once a second.",
                       symbol: "light.beacon.max", circuit: b.circuit)
    }()

    static let opAmpAmplifier: Example = {
        var b = CircuitBuilder()
        let source = b.add(.acVoltage, (0, 9), (0, 5), ["amplitude": 0.5, "frequency": 50])
        b.add(.resistor, (0, 5), (4, 5), ["resistance": 1000])
        b.wire((4, 5), (8, 5))
        let amplifier = b.add(.opAmp, (8, 6), (12, 6))
        b.wire((4, 5), (4, 2))
        b.add(.resistor, (4, 2), (12, 2), ["resistance": 10_000])
        b.wire((12, 2), (12, 6))
        b.wire((12, 6), (16, 6))
        b.add(.probe, (16, 6), (16, 10))
        b.wire((8, 7), (8, 10))
        b.wire((0, 9), (0, 10), (8, 10), (16, 10))
        b.ground((0, 10))
        b.scope(source, .voltage)
        b.scope(amplifier, .voltage)
        return Example(id: "opamp", title: "Op-amp amplifier", summary: "An inverting amplifier with a gain of −10. Raise the input past 1.5 V to see it clip.",
                       symbol: "triangle", circuit: b.circuit)
    }()

    static let lfo: Example = {
        var b = CircuitBuilder()
        let tl072 = model(.opAmp, "TL072")
        // integrator
        let integrator = b.add(.opAmp, (10, 4), (14, 4), tl072)
        b.ground((10, 5))
        b.wire((10, 3), (10, -1))
        b.add(.capacitor, (10, -1), (14, -1), ["capacitance": 1e-6])
        b.wire((14, -1), (14, 4))
        // comparator with hysteresis (a Schmitt trigger): + input from a divider between the triangle and the square
        b.wire((14, 4), (16, 4), (16, 5))
        b.add(.resistor, (16, 5), (20, 5), ["resistance": 10_000])
        let comparator = b.add(.opAmp, (20, 6), (24, 6), tl072, flipped: true)
        b.ground((20, 7))
        b.wire((20, 5), (20, 2))
        b.add(.resistor, (20, 2), (24, 2), ["resistance": 20_000])
        b.wire((24, 2), (26, 2), (26, 6))
        b.wire((24, 6), (26, 6))
        // the square drives the integrator
        b.wire((26, 6), (26, 10), (18, 10))
        b.add(.resistor, (18, 10), (14, 10), ["resistance": 220_000])
        b.wire((14, 10), (8, 10), (8, 3), (10, 3))
        b.scope(integrator, .voltage)
        b.scope(comparator, .voltage)
        return Example(id: "lfo", title: "Triangle and square LFO",
                       summary: "Two TL072 op-amps: an integrator and a Schmitt trigger chase each other at about 2 Hz.",
                       symbol: "waveform.path", circuit: b.circuit)
    }()

    static let vca: Example = {
        var b = CircuitBuilder()
        // audio in, attenuated to a few tens of millivolts for the OTA's inputs
        b.add(.acVoltage, (0, 8), (0, 4), ["amplitude": 5, "frequency": 20])
        b.ground((0, 8))
        b.wire((0, 4), (0, 2), (2, 2))
        b.add(.resistor, (2, 2), (6, 2), ["resistance": 100_000])
        b.add(.resistor, (6, 2), (6, 6), ["resistance": 330])
        b.ground((6, 6))
        b.wire((6, 2), (10, 2))
        b.add(.ota, (10, 3), (14, 3), model(.ota, "LM13700"))
        b.ground((10, 4))
        // control voltage: sets the bias current, and with it the gain
        b.wire((12, 5), (12, 8))
        b.add(.resistor, (12, 8), (16, 8), ["resistance": 15_000])
        b.wire((16, 8), (18, 8))
        let cv = b.add(.acVoltage, (18, 12), (18, 8), ["amplitude": 7, "frequency": 0.5, "offset": -6.8])
        b.ground((18, 12))
        // the output current into a load resistor
        b.wire((14, 3), (20, 3))
        let load = b.add(.resistor, (20, 3), (20, 7), ["resistance": 10_000])
        b.ground((20, 7))
        b.scope(cv, .voltage)
        b.scope(load, .voltage)
        return Example(id: "vca", title: "OTA voltage-controlled amplifier",
                       summary: "An LM13700 OTA: a slow control voltage sets the bias current, so the 20 Hz signal swells and fades.",
                       symbol: "dial.medium", circuit: b.circuit)
    }()

    static let timerFlasher: Example = {
        var b = CircuitBuilder()
        b.add(.dcVoltage, (0, 12), (0, 8), ["voltage": 9])
        b.ground((0, 12))
        b.wire((0, 8), (0, 0), (7, 0), (17, 0))
        let timer = b.add(.timer555, (12, 3), (12, 8), model(.timer555, "NE555"), flipped: true)
        // VCC and RESET to the supply, GND to ground
        b.wire((7, 0), (7, 4), (9, 4))
        b.wire((7, 4), (7, 5), (9, 5))
        b.wire((9, 7), (8, 7), (8, 12))
        b.wire((0, 12), (4, 12), (8, 12), (17, 12))
        // timing: RA from VCC to DIS, RB from DIS to THR and TRIG, C to ground
        b.add(.resistor, (17, 0), (17, 4), ["resistance": 1000])
        b.wire((15, 4), (17, 4))
        b.add(.resistor, (17, 4), (17, 8), ["resistance": 68_000])
        b.wire((15, 5), (16, 5), (16, 6), (16, 8), (17, 8))
        b.wire((15, 6), (16, 6))
        let c = b.add(.capacitor, (17, 8), (17, 12), ["capacitance": 10e-6])
        // the output lights an LED
        b.wire((9, 6), (4, 6))
        b.add(.resistor, (4, 6), (4, 9), ["resistance": 470])
        b.add(.led, (4, 9), (4, 12), ["color": 0])
        b.scope(c, .voltage)
        b.scope(timer, .voltage)
        return Example(id: "555", title: "555 LED flasher",
                       summary: "The classic astable 555: the capacitor charges through RA and RB and discharges through RB, about once a second.",
                       symbol: "timer", circuit: b.circuit)
    }()

    static let schmittOscillator: Example = {
        var b = CircuitBuilder()
        let inverter = b.add(.schmittInverter, (6, 4), (10, 4), model(.schmittInverter, "CD40106"))
        b.wire((10, 4), (10, 1))
        b.add(.resistor, (10, 1), (6, 1), ["resistance": 100_000])
        b.wire((6, 1), (6, 4))
        let c = b.add(.capacitor, (6, 4), (6, 8), ["capacitance": 4.7e-6])
        b.ground((6, 8))
        b.add(.resistor, (10, 4), (14, 4), ["resistance": 3300])
        b.add(.led, (14, 4), (14, 8), ["color": 1])
        b.ground((14, 8))
        b.scope(c, .voltage)
        b.scope(inverter, .voltage)
        return Example(id: "schmitt", title: "Schmitt trigger oscillator",
                       summary: "One gate of a 40106 with a resistor and a capacitor: the simplest synth oscillator, here blinking an LED.",
                       symbol: "square.on.square", circuit: b.circuit)
    }()

    static let sampleAndHold: Example = {
        var b = CircuitBuilder()
        let input = b.add(.acVoltage, (0, 8), (0, 4), ["amplitude": 5, "frequency": 0.5])
        b.ground((0, 8))
        b.wire((0, 4), (0, 2), (2, 2))
        b.add(.resistor, (2, 2), (6, 2), ["resistance": 10_000])
        b.add(.analogSwitch, (6, 2), (10, 2), model(.analogSwitch, "CD4066"))
        // a short clock pulse closes the switch four times a second
        b.add(.squareVoltage, (4, -2), (4, -6), ["high": 12, "low": 0, "frequency": 4, "duty": 0.1])
        b.ground((4, -2))
        b.wire((4, -6), (8, -6), (8, 0))
        b.add(.capacitor, (10, 2), (10, 6), ["capacitance": 1e-6])
        b.ground((10, 6))
        // a TL072 buffer reads the held voltage without draining it
        b.wire((10, 2), (12, 2))
        let buffer = b.add(.opAmp, (12, 3), (16, 3), model(.opAmp, "TL072"), flipped: true)
        b.wire((12, 4), (12, 6), (17, 6), (17, 3), (16, 3))
        b.scope(input, .voltage)
        b.scope(buffer, .voltage)
        return Example(id: "sh", title: "Sample and hold",
                       summary: "A CD4066 switch samples a slow sine into a capacitor on each clock pulse; a TL072 buffers the held steps.",
                       symbol: "stairs", circuit: b.circuit)
    }()

    static let memristorPulses: Example = {
        var b = CircuitBuilder()
        b.add(.squareVoltage, (0, 6), (0, 2), ["high": 1, "low": 0, "frequency": 5, "duty": 0.2])
        b.wire((0, 2), (0, 0), (2, 0))
        let memristor = b.add(.memristor, (2, 0), (6, 0), ["ron": 1000, "roff": 10_000, "von": 0.3, "voff": 0.3, "tau": 0.2])
        b.add(.resistor, (6, 0), (10, 0), ["resistance": 100])
        b.wire((10, 0), (12, 0), (12, 8), (0, 8), (0, 6))
        b.ground((0, 8))
        b.scope(memristor, .resistance)
        b.scope(memristor, .current)
        return Example(id: "memristor-pulses", title: "Memristor programming", summary: "Each pulse lowers the memristor's resistance a little.",
                       symbol: "square.stack.3d.up", circuit: b.circuit)
    }()
}
