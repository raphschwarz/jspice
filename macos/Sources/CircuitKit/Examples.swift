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
        transistorSwitch, cmosInverter, opAmpAmplifier, opAmpStability, lfo, vca, timerFlasher, schmittOscillator, sampleAndHold,
        beeper, tone, tremolo, keyboardVCO, monoSynth, filter, wind, voice, acid, chipVoice, randomNotes, comparatorPWM,
        cmosSequencer, babyTen, cmosDrone, pllOctave, cmosFuzz, echo, blocks,
        ringModulator, chorus, fuzz, guitarFuzz, tubeAmp, overdrive, lowpassGate, arduinoBlink, arduinoFade, arduinoKnob, arduinoMelody, arduinoDAC, megaBarGraph, tinyDimmer, picoKnob, picoMelody,
        memristorHysteresis, memristorPulses,
    ] + audioExamples + chipExamples

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

    /// A one-pole low-pass with a TONE knob (the pot as a variable resistor) and a TL072 buffer, as a block
    public static let toneStage: BlockDefinition = {
        let parts = [
            NetlistPart(kind: .port, name: "in", params: ["side": 1], connections: ["net": "in"]),
            NetlistPart(kind: .potentiometer, name: "TONE", params: ["resistance": 100_000, "position": 0.3],
                        connections: ["a": "in", "wiper": "rc", "b": "rc"]),
            NetlistPart(kind: .capacitor, name: "C1", params: ["capacitance": 10e-9], connections: ["a": "rc", "b": "GND"]),
            NetlistPart(kind: .opAmp, name: "U1", params: model(.opAmp, "TL072"), connections: ["plus": "rc", "minus": "out", "out": "out"]),
            NetlistPart(kind: .port, name: "out", params: ["side": 2], connections: ["net": "out"]),
        ]
        return ((try? SchematicLayout.layout(parts)) ?? Circuit()).asBlock(named: "Tone stage")
    }()

    /// The tone stage block used twice in series
    static let blocks: Example = {
        func stage(_ name: String, _ input: String, _ output: String, tone: Double) -> NetlistPart {
            var block = toneStage
            for i in block.circuit.elements.indices where block.circuit.elements[i].kind == .potentiometer {
                block.circuit.elements[i][param: "position"] = tone
            }
            var part = NetlistPart(kind: .block, name: name, connections: ["in": input, "out": output])
            part.block = block
            return part
        }
        var circuit = drawn([
            NetlistPart(kind: .squareVoltage, name: "VIN", params: ["frequency": 110, "high": 1, "low": -1, "duty": 0.5],
                        connections: ["plus": "in", "minus": "GND"]),
            stage("X1", "in", "mid", tone: 0.3),
            stage("X2", "mid", "out", tone: 0.6),
            NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 1], connections: ["plus": "out", "minus": "GND"]),
        ], scopes: [("VIN", .voltage), ("SPK1", .voltage)])
        if let speaker = circuit.elements.first(where: { $0.name == "SPK1" }) {
            circuit.scopes.append(ScopeSpec(elementID: speaker.id, quantity: .voltage, plot: .frequencyResponse))
        }
        return Example(
            id: "blocks", title: "Blocks: two tone stages (sound)",
            summary: "One low-pass stage saved as a block and used twice in series, each copy with its own TONE knob on the panel. Turn on sound, and right-click a block to open it.",
            symbol: "square.on.square", circuit: circuit)
    }()

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
        var parts: [NetlistPart] = [
            input,
            NetlistPart(kind: .dcVoltage, name: "VP", params: ["voltage": 15], connections: ["plus": "+15V", "minus": "GND"]),
            NetlistPart(kind: .dcVoltage, name: "VN", params: ["voltage": 15], connections: ["plus": "GND", "minus": "-15V"]),
        ]
        parts += filterCore(input: "in", output: "lp", control: "cutb", resonance: resonance)
        parts += [
            // cutoff: a pot across the supplies, buffered, sets both OTAs' bias currents
            NetlistPart(kind: .potentiometer, name: "CUTOFF", params: ["resistance": 100_000, "position": 0.5],
                        connections: ["a": "-15V", "b": "+15V", "wiper": "cut"]),
            NetlistPart(kind: .opAmp, name: "U5", params: model(.opAmp, "TL072"), connections: ["plus": "cut", "minus": "cutb", "out": "cutb"]),
        ]
        return parts
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
    static func voiceParts(resonance: Double) -> [NetlistPart] {
        var parts = vcoParts
        parts += [
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
        ]
        parts += filterCore(input: "fin", output: "flp", control: "env", resonance: resonance, prefix: "F")
        parts += [
            // VCA
            NetlistPart(kind: .resistor, name: "RIN", params: ["resistance": 220_000], connections: ["a": "flp", "b": "vin"]),
            NetlistPart(kind: .resistor, name: "RIN2", params: ["resistance": 1000], connections: ["a": "vin", "b": "GND"]),
            NetlistPart(kind: .resistor, name: "RBIAS", params: ["resistance": 33_000], connections: ["a": "env", "b": "iabc2"]),
            NetlistPart(kind: .ota, name: "U6", params: model(.ota, "LM13700"),
                        connections: ["minus": "GND", "plus": "vin", "out": "out", "bias": "iabc2"]),
            NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 10_000], connections: ["a": "out", "b": "GND"]),
            NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 4], connections: ["plus": "out", "minus": "GND"]),
        ]
        return parts
    }

    static let voice = Example(
        id: "voice", title: "Synth voice: VCO, VCF, VCA",
        summary: "A playable subtractive synth voice: the keyboard VCO through the resonant LM13700 filter and a VCA, with one envelope opening both. Turn on sound and play with A–; (or a MIDI keyboard); turn RES for more squelch.",
        symbol: "pianokeys.inverse",
        circuit: drawn(voiceParts(resonance: 0.6), scopes: [("CENV", .voltage), ("SPK1", .voltage)]))

    /// The synth voice played by the step sequencer: a sixteen-step bassline, with the filter's resonance turned up
    static let acid: Example = {
        var circuit = drawn(voiceParts(resonance: 0.85), scopes: [("CENV", .voltage), ("SPK1", .voltage)])
        let c2 = 36.0
        circuit.sequence = StepSequence(
            steps: [c2, c2, c2 + 12, c2, nil, c2 + 7, c2 + 10, c2, c2, c2 + 12, nil, c2 + 5, c2 + 7, c2, c2 + 15, c2 + 12],
            tempo: 125, gateLength: 0.5, playing: true)
        return Example(id: "acid", title: "Sequenced bassline (sound)",
                       summary: "The synth voice played by the step sequencer. Turn on sound; change the notes, tempo and gate in the inspector (click an empty spot first).",
                       symbol: "metronome", circuit: circuit)
    }()

    // MARK: Synth chips

    /// The classic chip synth: two AS3340s (a saw, and a pulse whose width an LFO sweeps) and a CD4013 sub-oscillator an
    /// octave down, mixed into an AS3320 four-pole filter; one AS3310 envelope opens the filter and a linear VCA. A
    /// sequencer plays an arpeggio.
    static let chipVoice: Example = {
        let parts: [NetlistPart] = [
            NetlistPart(kind: .keyboardPitch, name: "KB1", connections: ["plus": "cv", "minus": "GND"]),
            NetlistPart(kind: .keyboardGate, name: "KB2", params: ["high": 5], connections: ["plus": "gate", "minus": "GND"]),
            NetlistPart(kind: .acVoltage, name: "LFO", params: ["amplitude": 3, "frequency": 0.4], connections: ["plus": "lfo", "minus": "GND"]),
            NetlistPart(kind: .vco, name: "U1", params: model(.vco, "AS3340").merging(["waveform": 0]) { $1 },
                        connections: ["cv": "cv", "pw": "GND", "out": "saw"]),
            NetlistPart(kind: .vco, name: "U2", params: model(.vco, "AS3340").merging(["waveform": 2]) { $1 },
                        connections: ["cv": "cv", "pw": "lfo", "out": "pulse"]),
            NetlistPart(kind: .divider, name: "U3", params: model(.divider, "CD4013"), connections: ["clock": "pulse", "reset": "GND", "out": "sub"]),
            NetlistPart(kind: .capacitor, name: "C1", params: ["capacitance": 1e-6], connections: ["a": "sub", "b": "subc"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 100_000], connections: ["a": "saw", "b": "mix"]),
            NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 100_000], connections: ["a": "pulse", "b": "mix"]),
            NetlistPart(kind: .resistor, name: "R3", params: ["resistance": 100_000], connections: ["a": "subc", "b": "mix"]),
            NetlistPart(kind: .resistor, name: "R4", params: ["resistance": 47_000], connections: ["a": "mix", "b": "GND"]),
            NetlistPart(kind: .envelope, name: "U5", params: ["attack": 0.003, "decay": 0.25, "sustain": 0.3, "release": 0.2, "peak": 5],
                        connections: ["gate": "gate", "trig": "GND", "out": "env"]),
            NetlistPart(kind: .vcf, name: "U4", params: model(.vcf, "AS3320").merging(["cutoff": 150, "resonance": 0.45]) { $1 },
                        connections: ["in": "mix", "cv": "env", "out": "filt"]),
            NetlistPart(kind: .vca, name: "U6", params: model(.vca, "Linear"), connections: ["in": "filt", "cv": "env", "out": "out"]),
            NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 1], connections: ["plus": "out", "minus": "GND"]),
        ]
        var circuit = drawn(parts, scopes: [("U5", .voltage), ("SPK1", .voltage)])
        circuit.sequence = StepSequence(steps: [48, 51, 55, 60, 63, 60, 55, 51, 46, 50, 53, 58, 62, 58, 53, 50],
                                        tempo: 132, gateLength: 0.6, playing: true)
        return Example(id: "chipvoice", title: "Chip synth: AS3340, AS3320, AS3310 (sound)",
                       summary: "Two AS3340 VCOs and a CD4013 sub-oscillator through an AS3320 filter and a VCA, opened by an AS3310 envelope, playing an arpeggio. Turn on sound; stop the sequencer in the inspector to play it from the keys.",
                       symbol: "cpu", circuit: circuit)
    }()

    /// Random notes: noise sampled six times a second sets a VCO's pitch, a plucky envelope on each clock
    static let randomNotes = Example(
        id: "random", title: "Random notes: sample and hold (sound)",
        summary: "A clocked sample and hold picks a random voltage from noise six times a second; an AS3340 plays it as a pitch, an envelope plucks each note. The classic 'computer thinking' sound. Turn on sound.",
        symbol: "dice",
        circuit: drawn([
            NetlistPart(kind: .noiseVoltage, name: "NOISE", params: ["amplitude": 1], connections: ["plus": "noise", "minus": "GND"]),
            NetlistPart(kind: .squareVoltage, name: "CLK", params: ["high": 5, "low": 0, "frequency": 6, "duty": 0.5],
                        connections: ["plus": "clk", "minus": "GND"]),
            NetlistPart(kind: .sampleHold, name: "U1", params: model(.sampleHold, "Clocked"), connections: ["in": "noise", "trig": "clk", "out": "held"]),
            NetlistPart(kind: .vco, name: "U2", params: model(.vco, "AS3340").merging(["waveform": 1, "frequency": 261.63]) { $1 },
                        connections: ["cv": "held", "pw": "GND", "out": "tone"]),
            NetlistPart(kind: .envelope, name: "U3", params: ["attack": 0.002, "decay": 0.12, "sustain": 0, "release": 0.05],
                        connections: ["gate": "clk", "trig": "GND", "out": "env"]),
            NetlistPart(kind: .vca, name: "U4", params: model(.vca, "Linear"), connections: ["in": "tone", "cv": "env", "out": "out"]),
            NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 5], connections: ["plus": "out", "minus": "GND"]),
        ], scopes: [("U1", .voltage), ("SPK1", .voltage)]))

    /// Pulse-width modulation from a comparator: a triangle compared with a slow sine is high for longer the lower the
    /// sine is
    static let comparatorPWM = Example(
        id: "pwm", title: "Comparator PWM (sound)",
        summary: "An LM311 compares a 110 Hz triangle with a slow sine: the pulse it puts out widens and narrows, the hollow, chorused sound of pulse-width modulation. Turn on sound.",
        symbol: "square.split.2x1",
        circuit: drawn([
            NetlistPart(kind: .vco, name: "U1", params: model(.vco, "AS3340").merging(["waveform": 1, "frequency": 110]) { $1 },
                        connections: ["cv": "GND", "pw": "GND", "out": "tri"]),
            NetlistPart(kind: .acVoltage, name: "LFO", params: ["amplitude": 4, "frequency": 0.3], connections: ["plus": "lfo", "minus": "GND"]),
            NetlistPart(kind: .comparator, name: "U2", params: model(.comparator, "LM311"), connections: ["plus": "tri", "minus": "lfo", "out": "pulse"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 10_000], connections: ["a": "pulse", "b": "GND"]),
            NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 12], connections: ["plus": "pulse", "minus": "GND"]),
        ], scopes: [("LFO", .voltage), ("SPK1", .voltage)]))

    // MARK: CMOS logic

    /// A CD4093 gate as an oscillator: its output charges the capacitor through the resistor (and `pot`, a potentiometer
    /// wired as a variable resistor, if given) until the Schmitt input turns it round, at
    /// f = 1 / (R C ln((1 - VT-/V) VT+ / ((1 - VT+/V) VT-))), about 1 / (0.81 R C). Its other input gates it: while
    /// `enable` is low the output stays high.
    static func gatedOscillator(_ index: Int, resistance: Double, capacitance: Double, enable: String, cap: String, out: String,
                                supply: Double = 12, pot: Double? = nil) -> [NetlistPart] {
        var parts = [
            NetlistPart(kind: .logicGate, name: "U\(index)", params: model(.logicGate, "CD4093").merging(["supply": supply]) { $1 },
                        connections: ["in1": cap, "in2": enable, "out": out]),
            NetlistPart(kind: .capacitor, name: "C\(index)", params: ["capacitance": capacitance], connections: ["a": cap, "b": "GND"]),
        ]
        if let pot {
            let middle = out + "r"
            parts.append(NetlistPart(kind: .resistor, name: "R\(index)", params: ["resistance": resistance],
                                     connections: ["a": out, "b": middle]))
            parts.append(NetlistPart(kind: .potentiometer, name: "P\(index)", params: ["resistance": 100_000, "position": pot],
                                     connections: ["a": middle, "wiper": cap]))
        } else {
            parts.append(NetlistPart(kind: .resistor, name: "R\(index)", params: ["resistance": resistance],
                                     connections: ["a": out, "b": cap]))
        }
        return parts
    }

    /// The pot positions of the sequencer's eight steps: a minor pentatonic phrase, two volts being two octaves
    static let sequencerSteps: [Double] = [0, 3, 7, 10, 12, 10, 7, 3].map { $0 / 24 }

    static func sequencerParts() -> [NetlistPart] {
        var parts = [
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 12], connections: ["plus": "VCC", "minus": "GND"]),
            NetlistPart(kind: .toggleSwitch, name: "S1", connections: ["a": "VCC", "b": "run"], closed: true),
            NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 100_000], connections: ["a": "run", "b": "GND"]),
        ]
        parts += gatedOscillator(1, resistance: 300_000, capacitance: 1e-6, enable: "run", cap: "timing", out: "clock")
        parts.append(NetlistPart(kind: .binaryCounter, name: "U2", params: model(.binaryCounter, "CD4040"),
                                 connections: ["clock": "clock", "reset": "GND", "q1": "sa", "q2": "sb", "q3": "sc"]))
        parts.append(NetlistPart(kind: .dcVoltage, name: "VREF", params: ["voltage": 2], connections: ["plus": "ref", "minus": "GND"]))
        var mux = ["a": "sa", "b": "sb", "c": "sc", "inhibit": "GND", "x": "cv"]
        for (k, position) in sequencerSteps.enumerated() {
            parts.append(NetlistPart(kind: .potentiometer, name: "P\(k + 1)", params: ["resistance": 10_000, "position": position],
                                     connections: ["a": "GND", "b": "ref", "wiper": "x\(k)"]))
            mux["x\(k)"] = "x\(k)"
        }
        parts.append(NetlistPart(kind: .analogMux, name: "U3", params: model(.analogMux, "CD4051"), connections: mux))
        parts.append(NetlistPart(kind: .probe, name: "CV", connections: ["plus": "cv", "minus": "GND"]))
        parts.append(NetlistPart(kind: .vco, name: "U4", params: model(.vco, "AS3340").merging(["waveform": 0, "frequency": 130.81]) { $1 },
                                 connections: ["cv": "cv", "pw": "GND", "out": "osc"]))
        parts.append(NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 6], connections: ["plus": "osc", "minus": "GND"]))
        return parts
    }

    static let cmosSequencer = Example(
        id: "cmos-sequencer", title: "CMOS 8-step sequencer (sound)",
        summary: "A CD4093 clock steps a CD4040 counter, whose first three outputs pick one of eight knobs through a CD4051 multiplexer: the voltage plays an AS3340 VCO at one volt per octave. S1 stops and starts it. Turn on sound and set the knobs on the front panel.",
        symbol: "slider.vertical.3",
        circuit: drawn(sequencerParts(), scopes: [("C1", .voltage), ("CV", .voltage)]))

    /// The Baby 10's steps: where each knob is set
    static let babyTenSteps: [Double] = [0.25, 0.45, 0.35, 0.6]

    static func babyTenParts() -> [NetlistPart] {
        var parts = [NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 12], connections: ["plus": "VCC", "minus": "GND"])]
        parts += gatedOscillator(1, resistance: 220_000, capacitance: 1e-6, enable: "VCC", cap: "timing", out: "clock")
        parts.append(NetlistPart(kind: .decadeCounter, name: "U2", params: model(.decadeCounter, "CD4017"),
                                 connections: ["clock": "clock", "inhibit": "GND", "reset": "q4", "q0": "q0", "q1": "q1", "q2": "q2",
                                               "q3": "q3", "q4": "q4"]))
        for (k, position) in babyTenSteps.enumerated() {
            parts.append(NetlistPart(kind: .potentiometer, name: "P\(k + 1)", params: ["resistance": 100_000, "position": position],
                                     connections: ["a": "GND", "b": "q\(k)", "wiper": "w\(k)"]))
            parts.append(NetlistPart(kind: .diode, name: "D\(k + 1)", params: model(.diode, "1N4148"),
                                     connections: ["anode": "w\(k)", "cathode": "bus"]))
        }
        parts.append(NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 100_000], connections: ["a": "bus", "b": "cv"]))
        parts.append(NetlistPart(kind: .resistor, name: "R3", params: ["resistance": 22_000], connections: ["a": "cv", "b": "GND"]))
        parts.append(NetlistPart(kind: .probe, name: "CV", connections: ["plus": "cv", "minus": "GND"]))
        parts.append(NetlistPart(kind: .vco, name: "U3", params: model(.vco, "AS3340").merging(["waveform": 2, "frequency": 110]) { $1 },
                                 connections: ["cv": "cv", "pw": "GND", "out": "osc"]))
        parts.append(NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 6], connections: ["plus": "osc", "minus": "GND"]))
        return parts
    }

    static let babyTen = Example(
        id: "baby10", title: "Baby 10 sequencer, four steps (sound)",
        summary: "The classic CD4017 step sequencer: each step's output feeds its knob, a diode passes the knob's voltage to the CV bus, and Q4 resets the count after four steps. A CD4093 clocks it; an AS3340 plays the CV. Turn on sound.",
        symbol: "dial.medium",
        circuit: drawn(babyTenParts(), scopes: [("C1", .voltage), ("CV", .voltage)]))

    static func droneParts() -> [NetlistPart] {
        var parts = [NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 9], connections: ["plus": "VCC", "minus": "GND"])]
        parts += gatedOscillator(1, resistance: 22_000, capacitance: 47e-9, enable: "VCC", cap: "ca", out: "a", supply: 9, pot: 0.4)
        parts += gatedOscillator(2, resistance: 56_000, capacitance: 47e-9, enable: "VCC", cap: "cb", out: "b", supply: 9)
        parts.append(NetlistPart(kind: .logicGate, name: "U3", params: model(.logicGate, "CD4070").merging(["supply": 9]) { $1 },
                                 connections: ["in1": "a", "in2": "b", "out": "xor"]))
        parts.append(NetlistPart(kind: .flipFlop, name: "U4", params: model(.flipFlop, "CD4013").merging(["supply": 9]) { $1 },
                                 connections: ["clock": "a", "d": "qbar", "qbar": "qbar", "q": "sub", "set": "GND", "reset": "GND"]))
        parts.append(NetlistPart(kind: .resistor, name: "R3", params: ["resistance": 10_000], connections: ["a": "xor", "b": "mix"]))
        parts.append(NetlistPart(kind: .resistor, name: "R4", params: ["resistance": 10_000], connections: ["a": "sub", "b": "mix"]))
        parts.append(NetlistPart(kind: .resistor, name: "R5", params: ["resistance": 10_000], connections: ["a": "mix", "b": "GND"]))
        parts.append(NetlistPart(kind: .capacitor, name: "C3", params: ["capacitance": 1e-6], connections: ["a": "mix", "b": "spk"]))
        parts.append(NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 10_000], connections: ["a": "spk", "b": "GND"]))
        parts.append(NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 4], connections: ["plus": "spk", "minus": "GND"]))
        return parts
    }

    static let cmosDrone = Example(
        id: "cmos-drone", title: "CMOS drone (sound)",
        summary: "Two CD4093 oscillators, a CD4070 XOR that sounds their sum and difference, and a CD4013 flip-flop dividing the first by two for a sub-octave, mixed into a speaker. Turn on sound and turn P1 to detune.",
        symbol: "waveform.path",
        circuit: drawn(droneParts(), scopes: [("C1", .voltage), ("SPK1", .voltage)]))

    static func pllParts() -> [NetlistPart] {
        [
            NetlistPart(kind: .acVoltage, name: "VIN", params: ["amplitude": 5, "frequency": 220, "offset": 6],
                        connections: ["plus": "sig", "minus": "GND"]),
            NetlistPart(kind: .pll, name: "U1", params: model(.pll, "CD4046").merging(["fMin": 100, "fMax": 2000]) { $1 },
                        connections: ["signal": "sig", "comparator": "half", "vco_in": "vc", "inhibit": "GND", "vco_out": "vco", "pc2": "pc"]),
            // the loop filter: phase comparator 2 charges C1 through R1; R2 damps the loop
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 100_000], connections: ["a": "pc", "b": "vc"]),
            NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 10_000], connections: ["a": "vc", "b": "damp"]),
            NetlistPart(kind: .capacitor, name: "C1", params: ["capacitance": 1e-6], connections: ["a": "damp", "b": "GND"]),
            NetlistPart(kind: .probe, name: "VC", connections: ["plus": "vc", "minus": "GND"]),
            // the VCO divided by two goes back to the comparator, so the VCO locks at twice the input
            NetlistPart(kind: .flipFlop, name: "U2", params: model(.flipFlop, "CD4013"),
                        connections: ["clock": "vco", "d": "qb", "qbar": "qb", "q": "half", "set": "GND", "reset": "GND"]),
            NetlistPart(kind: .resistor, name: "R3", params: ["resistance": 47_000], connections: ["a": "vco", "b": "mix"]),
            NetlistPart(kind: .resistor, name: "R4", params: ["resistance": 47_000], connections: ["a": "sig", "b": "mix"]),
            NetlistPart(kind: .resistor, name: "R5", params: ["resistance": 10_000], connections: ["a": "mix", "b": "GND"]),
            NetlistPart(kind: .capacitor, name: "C2", params: ["capacitance": 1e-6], connections: ["a": "mix", "b": "spk"]),
            NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 10_000], connections: ["a": "spk", "b": "GND"]),
            NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 3], connections: ["plus": "spk", "minus": "GND"]),
        ]
    }

    static let pllOctave = Example(
        id: "pll-octave", title: "PLL octave up (sound)",
        summary: "A CD4046 phase-locked loop with a CD4013 dividing its VCO by two in the loop: the VCO locks at twice the 220 Hz input, an octave up, mixed with it. Watch VCO IN settle as it locks; turn on sound.",
        symbol: "arrow.up.and.down.circle",
        circuit: drawn(pllParts(), scopes: [("VC", .voltage), ("SPK1", .voltage)]))

    static func fuzzParts() -> [NetlistPart] {
        [
            NetlistPart(kind: .acVoltage, name: "VIN", params: ["amplitude": 0.2, "frequency": 110], connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .capacitor, name: "C1", params: ["capacitance": 100e-9], connections: ["a": "in", "b": "a"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 10_000], connections: ["a": "a", "b": "ia"]),
            NetlistPart(kind: .unbufferedInverter, name: "U1", params: model(.unbufferedInverter, "CD4049UB"),
                        connections: ["in": "ia", "out": "oa"]),
            // the gain: a megohm pot as a variable feedback resistor
            NetlistPart(kind: .potentiometer, name: "P1", params: ["resistance": 1_000_000, "position": 0.5],
                        connections: ["a": "oa", "wiper": "ia"]),
            NetlistPart(kind: .capacitor, name: "C2", params: ["capacitance": 100e-9], connections: ["a": "oa", "b": "b"]),
            NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 22_000], connections: ["a": "b", "b": "ib"]),
            NetlistPart(kind: .unbufferedInverter, name: "U2", params: model(.unbufferedInverter, "CD4049UB"),
                        connections: ["in": "ib", "out": "ob"]),
            NetlistPart(kind: .resistor, name: "R3", params: ["resistance": 470_000], connections: ["a": "ob", "b": "ib"]),
            NetlistPart(kind: .capacitor, name: "C3", params: ["capacitance": 1e-6], connections: ["a": "ob", "b": "spk"]),
            NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 10_000], connections: ["a": "spk", "b": "GND"]),
            NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 5], connections: ["plus": "spk", "minus": "GND"]),
        ]
    }

    static let cmosFuzz = Example(
        id: "cmos-fuzz", title: "CMOS fuzz (sound)",
        summary: "Two unbuffered CD4049UB inverters biased as amplifiers, the classic CMOS fuzz: each biases itself at half the supply through its feedback resistor and clips softly at the rails. P1 sets the gain. Turn on sound.",
        symbol: "bolt.horizontal",
        circuit: drawn(fuzzParts(), scopes: [("VIN", .voltage), ("SPK1", .voltage)]))

    static func echoParts() -> [NetlistPart] {
        [
            // a plucked note: an AS3340 saw through a VCA that an AS3310 envelope opens on each beat
            NetlistPart(kind: .squareVoltage, name: "BEAT", params: ["high": 5, "low": 0, "frequency": 0.8, "duty": 0.05],
                        connections: ["plus": "gate", "minus": "GND"]),
            NetlistPart(kind: .envelope, name: "U1", params: model(.envelope, "AS3310").merging(["attack": 0.002, "decay": 0.15, "sustain": 0, "release": 0.1]) { $1 },
                        connections: ["gate": "gate", "trig": "GND", "out": "env"]),
            NetlistPart(kind: .vco, name: "U2", params: model(.vco, "AS3340").merging(["waveform": 0, "frequency": 220, "amplitude": 2]) { $1 },
                        connections: ["cv": "GND", "pw": "GND", "out": "saw"]),
            NetlistPart(kind: .vca, name: "U3", params: model(.vca, "Linear"), connections: ["in": "saw", "cv": "env", "out": "dry"]),
            // into the echo: the dry signal and, through REPEATS, the echo itself
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 10_000], connections: ["a": "dry", "b": "send"]),
            NetlistPart(kind: .potentiometer, name: "REPEATS", params: ["resistance": 50_000, "position": 0.1],
                        connections: ["a": "wet", "wiper": "send"]),
            NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 100_000], connections: ["a": "send", "b": "GND"]),
            NetlistPart(kind: .digitalDelay, name: "U4", params: model(.digitalDelay, "PT2399"),
                        connections: ["in": "send", "time": "t", "out": "wet"]),
            // TIME: the resistance from pin 6 to ground
            NetlistPart(kind: .resistor, name: "R3", params: ["resistance": 1000], connections: ["a": "t", "b": "t2"]),
            NetlistPart(kind: .potentiometer, name: "TIME", params: ["resistance": 50_000, "position": 0.2],
                        connections: ["a": "t2", "wiper": "GND"]),
            // out: dry and echo together
            NetlistPart(kind: .resistor, name: "R4", params: ["resistance": 10_000], connections: ["a": "dry", "b": "mix"]),
            NetlistPart(kind: .resistor, name: "R5", params: ["resistance": 10_000], connections: ["a": "wet", "b": "mix"]),
            NetlistPart(kind: .resistor, name: "R6", params: ["resistance": 10_000], connections: ["a": "mix", "b": "GND"]),
            NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 2], connections: ["plus": "mix", "minus": "GND"]),
        ]
    }

    static let echo = Example(
        id: "pt2399-echo", title: "PT2399 echo (sound)",
        summary: "A plucked note into a PT2399 echo chip. TIME is the resistance from its pin 6 to ground (about 30 to 600 ms); REPEATS feeds the echo back into it. Longer delays sound darker and noisier, as on the real chip. Turn on sound.",
        symbol: "dot.radiowaves.right",
        circuit: drawn(echoParts(), scopes: [("U3", .voltage), ("SPK1", .voltage)]))

    // MARK: Microcontrollers

    /// An ATmega328P with a sketch and its firmware
    static func arduino(_ name: String = "U1", kind: ElementKind = .atmega328p, code: String, firmware: String,
                        connections: [String: String]) -> NetlistPart {
        var part = NetlistPart(kind: kind, name: name, connections: connections)
        part.code = code
        part.firmware = ArduinoSketches.firmware(firmware)
        return part
    }

    static func pico(_ name: String = "U1", code: String, firmware: String, connections: [String: String]) -> NetlistPart {
        var part = NetlistPart(kind: .rp2040, name: name, connections: connections)
        part.code = code
        part.firmware = PicoSketches.firmware(firmware)
        return part
    }

    static let arduinoBlink = Example(
        id: "arduino-blink", title: "Arduino: Blink",
        summary: "An ATmega328P runs the Blink sketch: the LED on pin 13 flashes once a second. Select the chip to read and change its code.",
        symbol: "cpu",
        circuit: drawn([
            arduino(code: ArduinoSketches.blinkCode, firmware: ArduinoSketches.blinkFirmware, connections: ["d13": "pin13"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 220], connections: ["a": "pin13", "b": "anode"]),
            NetlistPart(kind: .led, name: "D1", connections: ["anode": "anode", "cathode": "GND"]),
        ], scopes: [("D1", .current)]))

    static let arduinoFade = Example(
        id: "arduino-fade", title: "Arduino: PWM fade",
        summary: "analogWrite() on pin 9 fades an LED with 490 Hz PWM; an RC filter averages the pulses into a smooth voltage.",
        symbol: "light.max",
        circuit: drawn([
            arduino(code: ArduinoSketches.fadeCode, firmware: ArduinoSketches.fadeFirmware, connections: ["d9": "pwm"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 220], connections: ["a": "pwm", "b": "anode"]),
            NetlistPart(kind: .led, name: "D1", params: ["color": 1], connections: ["anode": "anode", "cathode": "GND"]),
            NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 10_000], connections: ["a": "pwm", "b": "average"]),
            NetlistPart(kind: .capacitor, name: "C1", params: ["capacitance": 2.2e-6], connections: ["a": "average", "b": "GND"]),
        ], scopes: [("D1", .current), ("C1", .voltage)]))

    static let arduinoKnob = Example(
        id: "arduino-knob", title: "Arduino: knob and LED",
        summary: "analogRead() measures the pot on A0 and analogWrite() sets the LED's brightness to match; the readings go to the serial monitor. Turn the pot.",
        symbol: "dial.medium",
        circuit: drawn([
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 5], connections: ["plus": "+5V", "minus": "GND"]),
            NetlistPart(kind: .potentiometer, name: "POT", params: ["resistance": 10_000, "position": 0.6],
                        connections: ["a": "GND", "b": "+5V", "wiper": "knob"]),
            arduino(code: ArduinoSketches.knobCode, firmware: ArduinoSketches.knobFirmware, connections: ["a0": "knob", "d9": "pwm"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 220], connections: ["a": "pwm", "b": "anode"]),
            NetlistPart(kind: .led, name: "D1", params: ["color": 4], connections: ["anode": "anode", "cathode": "GND"]),
        ], scopes: [("POT", .voltage), ("D1", .current)]))

    static let arduinoDAC = Example(
        id: "arduino-dac", title: "Arduino: SPI DAC through a filter (sound)",
        summary: "The Arduino computes a sawtooth 8000 times a second and sends each sample to an MCP4921 DAC over SPI, playing an arpeggio; an AS3320 filter swept by a slow LFO shapes it. Every SPI clock edge reaches the DAC, even many within one step of the circuit. Turn on sound.",
        symbol: "waveform.path.ecg",
        circuit: drawn([
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 5], connections: ["plus": "+5V", "minus": "GND"]),
            arduino(code: ArduinoSketches.dacSynthCode, firmware: ArduinoSketches.dacSynthFirmware,
                    connections: ["d10": "cs", "d13": "sck", "d11": "sdi"]),
            NetlistPart(kind: .dac, name: "U2", params: model(.dac, "MCP4921"),
                        connections: ["cs": "cs", "sck": "sck", "sdi": "sdi", "ldac": "GND", "vref": "+5V", "out": "dac"]),
            NetlistPart(kind: .probe, name: "DAC", connections: ["plus": "dac", "minus": "GND"]),
            NetlistPart(kind: .capacitor, name: "C1", params: ["capacitance": 1e-6], connections: ["a": "dac", "b": "ac"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 10_000], connections: ["a": "ac", "b": "GND"]),
            NetlistPart(kind: .acVoltage, name: "LFO", params: ["amplitude": 1.5, "frequency": 0.25, "offset": 1.5],
                        connections: ["plus": "lfo", "minus": "GND"]),
            NetlistPart(kind: .vcf, name: "U3", params: model(.vcf, "AS3320").merging(["cutoff": 200, "resonance": 0.6]) { $1 },
                        connections: ["in": "ac", "cv": "lfo", "out": "filt"]),
            NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 3], connections: ["plus": "filt", "minus": "GND"]),
        ], scopes: [("DAC", .voltage), ("SPK1", .voltage)]))

    static let megaBarGraph = Example(
        id: "arduino-mega-bargraph", title: "Arduino Mega: bar graph",
        summary: "An ATmega2560 reads the pot on A8 and lights up to five LEDs on pins 22 to 26; the readings go to the serial monitor. Turn the pot.",
        symbol: "chart.bar",
        circuit: drawn([
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 5], connections: ["plus": "+5V", "minus": "GND"]),
            NetlistPart(kind: .potentiometer, name: "POT", params: ["resistance": 10_000, "position": 0.65],
                        connections: ["a": "GND", "b": "+5V", "wiper": "knob"]),
            arduino(kind: .atmega2560, code: ArduinoSketches.megaBarGraphCode, firmware: ArduinoSketches.megaBarGraphFirmware,
                    connections: ["a8": "knob", "d22": "led0", "d23": "led1", "d24": "led2", "d25": "led3", "d26": "led4"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 330], connections: ["a": "led0", "b": "k0"]),
            NetlistPart(kind: .led, name: "D1", params: ["color": 2], connections: ["anode": "k0", "cathode": "GND"]),
            NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 330], connections: ["a": "led1", "b": "k1"]),
            NetlistPart(kind: .led, name: "D2", params: ["color": 2], connections: ["anode": "k1", "cathode": "GND"]),
            NetlistPart(kind: .resistor, name: "R3", params: ["resistance": 330], connections: ["a": "led2", "b": "k2"]),
            NetlistPart(kind: .led, name: "D3", params: ["color": 3], connections: ["anode": "k2", "cathode": "GND"]),
            NetlistPart(kind: .resistor, name: "R4", params: ["resistance": 330], connections: ["a": "led3", "b": "k3"]),
            NetlistPart(kind: .led, name: "D4", params: ["color": 3], connections: ["anode": "k3", "cathode": "GND"]),
            NetlistPart(kind: .resistor, name: "R5", params: ["resistance": 330], connections: ["a": "led4", "b": "k4"]),
            NetlistPart(kind: .led, name: "D5", params: ["color": 1], connections: ["anode": "k4", "cathode": "GND"]),
        ], scopes: [("POT", .voltage), ("D1", .current)]))

    static let tinyDimmer = Example(
        id: "attiny85-dimmer", title: "ATtiny85: dimmer",
        summary: "An ATtiny85 reads the pot on A1 (PB2) and sets an LED's brightness on PB0 with PWM; a second LED on PB4 breathes, from timer 1.",
        symbol: "light.min",
        circuit: drawn([
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 5], connections: ["plus": "+5V", "minus": "GND"]),
            NetlistPart(kind: .potentiometer, name: "POT", params: ["resistance": 10_000, "position": 0.5],
                        connections: ["a": "GND", "b": "+5V", "wiper": "knob"]),
            arduino(kind: .attiny85, code: ArduinoSketches.tinyDimmerCode, firmware: ArduinoSketches.tinyDimmerFirmware,
                    connections: ["pb2": "knob", "pb0": "pwm", "pb4": "breath"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 220], connections: ["a": "pwm", "b": "a1"]),
            NetlistPart(kind: .led, name: "D1", params: ["color": 4], connections: ["anode": "a1", "cathode": "GND"]),
            NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 220], connections: ["a": "breath", "b": "a2"]),
            NetlistPart(kind: .led, name: "D2", params: ["color": 2], connections: ["anode": "a2", "cathode": "GND"]),
        ], scopes: [("D1", .current), ("D2", .current)]))

    static let picoKnob = Example(
        id: "pico-knob", title: "Raspberry Pi Pico: knob and LED",
        summary: "A Pico reads the pot on GP26 (A0) and sets the LED on GP15 with 12-bit PWM; its own LED blinks, and the readings go to the serial monitor over USB. Turn the pot.",
        symbol: "dial.low",
        circuit: drawn([
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 3.3], connections: ["plus": "+3V3", "minus": "GND"]),
            NetlistPart(kind: .potentiometer, name: "POT", params: ["resistance": 10_000, "position": 0.6],
                        connections: ["a": "GND", "b": "+3V3", "wiper": "knob"]),
            pico(code: PicoSketches.knobCode, firmware: PicoSketches.knobFirmware, connections: ["gp26": "knob", "gp15": "pwm"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 100], connections: ["a": "pwm", "b": "anode"]),
            NetlistPart(kind: .led, name: "D1", params: ["color": 4], connections: ["anode": "anode", "cathode": "GND"]),
        ], scopes: [("POT", .voltage), ("D1", .current)]))

    static let picoMelody = Example(
        id: "pico-melody", title: "Raspberry Pi Pico: melody (sound)",
        summary: "tone() on GP5 plays a scale and a phrase through the speaker; on the Pico it runs on a PIO state machine. Turn on sound.",
        symbol: "music.quarternote.3",
        circuit: drawn([
            pico(code: PicoSketches.melodyCode, firmware: PicoSketches.melodyFirmware, connections: ["gp5": "gp5"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 470], connections: ["a": "gp5", "b": "spk"]),
            NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 3.3], connections: ["plus": "spk", "minus": "GND"]),
        ], scopes: [("SPK1", .voltage)]))

    static let arduinoMelody = Example(
        id: "arduino-melody", title: "Arduino: melody (sound)",
        summary: "tone() plays a tune on pin 8 through the speaker. Turn on sound.",
        symbol: "music.note",
        circuit: drawn([
            arduino(code: ArduinoSketches.melodyCode, firmware: ArduinoSketches.melodyFirmware, connections: ["d8": "pin8"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 1000], connections: ["a": "pin8", "b": "spk"]),
            NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 5], connections: ["plus": "spk", "minus": "GND"]),
        ], scopes: [("SPK1", .voltage)]))

    // MARK: Effects

    static let ringModulator = Example(
        id: "ringmod", title: "Ring modulator (sound)",
        summary: "An AD633 multiplies two tones: you hear their sum and difference (740 Hz and 140 Hz), not the tones themselves. Turn on sound.",
        symbol: "circle.circle",
        circuit: drawn([
            NetlistPart(kind: .acVoltage, name: "VX", params: ["amplitude": 5, "frequency": 440], connections: ["plus": "x", "minus": "GND"]),
            NetlistPart(kind: .acVoltage, name: "VY", params: ["amplitude": 5, "frequency": 300], connections: ["plus": "y", "minus": "GND"]),
            NetlistPart(kind: .multiplier, name: "U1", params: model(.multiplier, "AD633"), connections: ["x": "x", "y": "y", "out": "ring"]),
            NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 10_000], connections: ["a": "ring", "b": "GND"]),
            NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 3], connections: ["plus": "ring", "minus": "GND"]),
        ], scopes: [("VX", .voltage), ("SPK1", .voltage)]))

    /// A chorus: the signal delayed 10 to 17 ms by an MN3207 whose clock a slow LFO sweeps, mixed with the dry signal
    static let chorus = Example(
        id: "chorus", title: "BBD chorus (sound)",
        summary: "An MN3207 bucket brigade delays a 220 Hz square by about 13 ms, a 0.7 Hz LFO sweeping its clock; mixed with the dry signal it shimmers. Turn on sound.",
        symbol: "water.waves",
        circuit: drawn([
            NetlistPart(kind: .squareVoltage, name: "VIN", params: ["high": 2, "low": -2, "frequency": 220, "duty": 0.5],
                        connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .acVoltage, name: "LFO", params: ["amplitude": 1, "frequency": 0.7], connections: ["plus": "lfo", "minus": "GND"]),
            NetlistPart(kind: .delayLine, name: "U1", params: model(.delayLine, "MN3207"), connections: ["in": "in", "ctrl": "lfo", "out": "wet"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 10_000], connections: ["a": "in", "b": "sum"]),
            NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 10_000], connections: ["a": "wet", "b": "sum"]),
            NetlistPart(kind: .opAmp, name: "U2", params: model(.opAmp, "TL072"), connections: ["minus": "sum", "plus": "GND", "out": "mix"]),
            NetlistPart(kind: .resistor, name: "R3", params: ["resistance": 10_000], connections: ["a": "sum", "b": "mix"]),
            NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 5], connections: ["plus": "mix", "minus": "GND"]),
        ], scopes: [("LFO", .voltage), ("SPK1", .voltage)]))

    /// The silicon Fuzz Face: two high-gain NPNs in a feedback pair, the 100 k from Q2's emitter biasing Q1, played by
    /// `guitar` (a source on the net "gtr")
    static func fuzzFaceParts(guitar: NetlistPart) -> [NetlistPart] {
        [
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 9], connections: ["plus": "+9V", "minus": "GND"]),
            guitar,
            NetlistPart(kind: .capacitor, name: "C1", params: ["capacitance": 2.2e-6], connections: ["a": "gtr", "b": "b1"]),
            NetlistPart(kind: .npn, name: "Q1", params: model(.npn, "BC108"), connections: ["base": "b1", "collector": "c1", "emitter": "GND"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 33_000], connections: ["a": "+9V", "b": "c1"]),
            NetlistPart(kind: .npn, name: "Q2", params: model(.npn, "BC108"), connections: ["base": "c1", "collector": "c2", "emitter": "e2"]),
            NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 8200], connections: ["a": "+9V", "b": "c2a"]),
            NetlistPart(kind: .resistor, name: "R3", params: ["resistance": 470], connections: ["a": "c2a", "b": "c2"]),
            NetlistPart(kind: .resistor, name: "R4", params: ["resistance": 100_000], connections: ["a": "e2", "b": "b1"]),
            NetlistPart(kind: .potentiometer, name: "FUZZ", params: ["resistance": 1000, "position": 0.8],
                        connections: ["a": "GND", "b": "e2", "wiper": "fz"]),
            NetlistPart(kind: .capacitor, name: "C2", params: ["capacitance": 20e-6], connections: ["a": "fz", "b": "GND"]),
            NetlistPart(kind: .capacitor, name: "C3", params: ["capacitance": 10e-9], connections: ["a": "c2", "b": "outc"]),
            NetlistPart(kind: .potentiometer, name: "VOLUME", params: ["resistance": 500_000, "position": 0.6, "taper": 1],
                        connections: ["a": "GND", "b": "outc", "wiper": "out"]),
            NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 2], connections: ["plus": "out", "minus": "GND"]),
        ]
    }

    static let fuzz = Example(
        id: "fuzz", title: "Fuzz Face (sound)",
        summary: "The classic two-transistor fuzz (silicon, BC108) on a guitar's G string. Turn on sound and turn FUZZ up.",
        symbol: "bolt.horizontal",
        circuit: drawn(fuzzFaceParts(guitar: NetlistPart(kind: .acVoltage, name: "GTR", params: ["amplitude": 0.1, "frequency": 196],
                                                         connections: ["plus": "gtr", "minus": "GND"])),
                       scopes: [("GTR", .voltage), ("SPK1", .voltage)]))

    /// The same fuzz played by a recorded guitar riff (an audio input), or by a real guitar through the Mac's input
    static let guitarFuzz = Example(
        id: "guitar-fuzz", title: "Fuzz Face on a guitar riff (sound)",
        summary: "The Fuzz Face played by a recorded guitar riff from an audio input part. Turn on sound; choose your own sound file in the inspector, or set the input to the Mac's live input and plug in a guitar. File ▸ Export Sound writes the result to a WAV file.",
        symbol: "guitars",
        circuit: drawn(fuzzFaceParts(guitar: NetlistPart(kind: .audioInput, name: "GTR", params: ["level": 0.15, "loop": 1],
                                                         connections: ["plus": "gtr", "minus": "GND"])),
                       scopes: [("GTR", .voltage), ("SPK1", .voltage)]))

    /// A small guitar amp: a 12AX7 preamp stage into a single-ended 6L6GC, its output transformer into an 8 Ω speaker
    static let tubeAmp = Example(
        id: "tube-amp", title: "Single-ended tube amp (sound)",
        summary: "A guitar riff through a 12AX7 preamp stage (a gain of about 60) and a volume knob into a 6L6GC, cathode biased, driving an 8 Ω speaker through its output transformer, from 300 V. Turn on sound and turn VOLUME up until the power tube clips.",
        symbol: "hifispeaker.fill",
        circuit: drawn([
            NetlistPart(kind: .dcVoltage, name: "VB", params: ["voltage": 300], connections: ["plus": "+300V", "minus": "GND"]),
            NetlistPart(kind: .audioInput, name: "GTR", params: ["level": 0.15, "loop": 1], connections: ["plus": "gtr", "minus": "GND"]),
            NetlistPart(kind: .capacitor, name: "C1", params: ["capacitance": 22e-9], connections: ["a": "gtr", "b": "g1"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 1e6], connections: ["a": "g1", "b": "GND"]),
            NetlistPart(kind: .triode, name: "V1", params: model(.triode, "12AX7"), connections: ["grid": "g1", "plate": "p1", "cathode": "k1"]),
            NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 100_000], connections: ["a": "+300V", "b": "p1"]),
            NetlistPart(kind: .resistor, name: "R3", params: ["resistance": 1500], connections: ["a": "k1", "b": "GND"]),
            NetlistPart(kind: .capacitor, name: "C2", params: ["capacitance": 22e-6], connections: ["a": "k1", "b": "GND"]),
            NetlistPart(kind: .capacitor, name: "C3", params: ["capacitance": 22e-9], connections: ["a": "p1", "b": "vol"]),
            NetlistPart(kind: .potentiometer, name: "VOLUME", params: ["resistance": 1e6, "position": 0.6, "taper": 1],
                        connections: ["a": "GND", "b": "vol", "wiper": "g2"]),
            NetlistPart(kind: .pentode, name: "V2", params: model(.pentode, "6L6GC"),
                        connections: ["grid": "g2", "plate": "p2", "cathode": "k2", "screen": "sc"]),
            NetlistPart(kind: .resistor, name: "R4", params: ["resistance": 470], connections: ["a": "+300V", "b": "sc"]),
            NetlistPart(kind: .resistor, name: "R5", params: ["resistance": 250], connections: ["a": "k2", "b": "GND"]),
            NetlistPart(kind: .capacitor, name: "C4", params: ["capacitance": 100e-6], connections: ["a": "k2", "b": "GND"]),
            NetlistPart(kind: .transformer, name: "T1", params: model(.transformer, "Output 8 kΩ : 8 Ω"),
                        connections: ["p1": "+300V", "p2": "p2", "s1": "spk", "s2": "GND"]),
            NetlistPart(kind: .resistor, name: "R6", params: ["resistance": 8], connections: ["a": "spk", "b": "GND"]),
            NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 5], connections: ["plus": "spk", "minus": "GND"]),
        ], scopes: [("V1", .voltage), ("SPK1", .voltage)]))

    /// Overdrive: a TL072 with a gain of 22 into a pair of 1N4148 diodes that clip at about ±0.6 V
    static let overdrive = Example(
        id: "overdrive", title: "Diode-clipper overdrive (sound)",
        summary: "A TL072 gain stage drives two 1N4148s to ground, which round off everything above about 0.6 V. Turn on sound.",
        symbol: "flame",
        circuit: drawn([
            NetlistPart(kind: .acVoltage, name: "VIN", params: ["amplitude": 0.3, "frequency": 220], connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .opAmp, name: "U1", params: model(.opAmp, "TL072"), connections: ["plus": "in", "minus": "fb", "out": "amp"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 4700], connections: ["a": "fb", "b": "GND"]),
            NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 100_000], connections: ["a": "amp", "b": "fb"]),
            NetlistPart(kind: .resistor, name: "R3", params: ["resistance": 1000], connections: ["a": "amp", "b": "clip"]),
            NetlistPart(kind: .diode, name: "D1", params: model(.diode, "1N4148"), connections: ["anode": "clip", "cathode": "GND"]),
            NetlistPart(kind: .diode, name: "D2", params: model(.diode, "1N4148"), connections: ["anode": "GND", "cathode": "clip"]),
            NetlistPart(kind: .capacitor, name: "C1", params: ["capacitance": 10e-9], connections: ["a": "clip", "b": "GND"]),
            NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 1], connections: ["plus": "clip", "minus": "GND"]),
        ], scopes: [("VIN", .voltage), ("SPK1", .voltage)]))

    /// A lowpass gate: a VTL5C3's LDR in series with the signal and a capacitor to ground, its LED pulsed by a gate, so
    /// each pulse opens the sound quickly and lets it die away with the LDR's slow decay
    static let lowpassGate = Example(
        id: "lpg", title: "Vactrol lowpass gate (sound)",
        summary: "A VTL5C3 vactrol opens a 330 Hz tone on each gate pulse and lets it fade with the LDR's natural decay, a soft 'bongo' pluck. Turn on sound.",
        symbol: "lightbulb",
        circuit: drawn([
            NetlistPart(kind: .squareVoltage, name: "GATE", params: ["high": 5, "low": 0, "frequency": 2, "duty": 0.1],
                        connections: ["plus": "g", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 220], connections: ["a": "g", "b": "led"]),
            NetlistPart(kind: .vactrol, name: "VTL1", params: model(.vactrol, "VTL5C3"),
                        connections: ["anode": "led", "cathode": "GND", "a": "in", "b": "out"]),
            NetlistPart(kind: .acVoltage, name: "VIN", params: ["amplitude": 2, "frequency": 330], connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .capacitor, name: "C1", params: ["capacitance": 10e-9], connections: ["a": "out", "b": "GND"]),
            NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 10_000], connections: ["a": "out", "b": "GND"]),
            NetlistPart(kind: .speaker, name: "SPK1", params: ["fullScale": 2], connections: ["plus": "out", "minus": "GND"]),
        ], scopes: [("GATE", .voltage), ("SPK1", .voltage)]))

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

    /// A TL072 at a gain of 2 driving a cable's capacitance through 100 Ω, its feedback taken at the cable: the cable's
    /// pole inside the loop leaves it about 6° of phase margin, so a square wave rings; a loop probe at its output
    /// shows the loop's gain
    static let opAmpStability: Example = {
        let parts = [
            NetlistPart(kind: .squareVoltage, name: "VIN", params: ["frequency": 1000, "high": 0.5, "low": -0.5, "duty": 0.5],
                        connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .opAmp, name: "U1", params: model(.opAmp, "TL072"), connections: ["plus": "in", "minus": "fb", "out": "out"]),
            NetlistPart(kind: .loopProbe, name: "LP1", connections: ["in": "out", "out": "drive"]),
            NetlistPart(kind: .resistor, name: "RISO", params: ["resistance": 100], connections: ["a": "drive", "b": "cable"]),
            NetlistPart(kind: .capacitor, name: "CABLE", params: ["capacitance": 100e-9], connections: ["a": "cable", "b": "GND"]),
            NetlistPart(kind: .resistor, name: "RF", params: ["resistance": 10_000], connections: ["a": "cable", "b": "fb"]),
            NetlistPart(kind: .resistor, name: "RG", params: ["resistance": 10_000], connections: ["a": "fb", "b": "GND"]),
        ]
        var circuit = drawn(parts, scopes: [("CABLE", .voltage)])
        if let probe = circuit.elements.first(where: { $0.name == "LP1" }) {
            circuit.scopes.append(ScopeSpec(elementID: probe.id, quantity: .voltage, plot: .frequencyResponse))
        }
        return Example(id: "opamp-stability", title: "Op-amp stability: driving a cable",
                       summary: "A gain-of-2 TL072 drives 100 nF of cable through 100 Ω, its feedback from the cable: the loop probe shows about 6° of phase margin, and the square wave rings. Make CABLE 1 nF, or take RF from the op-amp's output, and watch the margin come back.",
                       symbol: "waveform.path.ecg", circuit: circuit)
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
