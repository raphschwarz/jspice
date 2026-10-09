import Foundation

/// Examples for the audio parts: microphone preamps, line and power amps, dynamics, tone and EQ, a reverb, meters
extension Examples {
    static let audioExamples: [Example] = [
        micPreamp, phantomPreamp, electretPreamp, lm386Amp, powerAmp, headphoneAmp, balancedLine, compressor, compander,
        optoCompressor, noiseGate, toneStacks, baxandall, graphicEQ, parametricEQ, toneControlChip, pickupFuzz, springReverb,
        barGraphMeter,
    ]

    private static func part(_ kind: ElementKind, _ name: String, _ params: [String: Double] = [:], _ connections: [String: String])
        -> NetlistPart {
        NetlistPart(kind: kind, name: name, params: params, connections: connections)
    }

    private static func r(_ name: String, _ ohms: Double, _ a: String, _ b: String) -> NetlistPart {
        part(.resistor, name, ["resistance": ohms], ["a": a, "b": b])
    }

    private static func c(_ name: String, _ farads: Double, _ a: String, _ b: String) -> NetlistPart {
        part(.capacitor, name, ["capacitance": farads], ["a": a, "b": b])
    }

    private static func opAmp(_ name: String, _ model: String, plus: String, minus: String, out: String) -> NetlistPart {
        part(.opAmp, name, Examples.model(.opAmp, model), ["plus": plus, "minus": minus, "out": out])
    }

    private static func probe(_ name: String, _ net: String) -> NetlistPart {
        part(.probe, name, [:], ["plus": net, "minus": "GND"])
    }

    /// An audio input playing the voice instead of the guitar riff
    private static func voice(_ name: String, level: Double, plus: String, minus: String = "GND") -> NetlistPart {
        var input = part(.audioInput, name, ["level": level, "loop": 1], ["plus": plus, "minus": minus])
        input.audio = AudioClip.speech
        return input
    }

    /// A circuit drawn from a netlist, with time scopes on some parts and frequency-response scopes on others
    private static func drawn(_ parts: [NetlistPart], time: [String], response: [String] = []) -> Circuit {
        var circuit = drawn(parts, scopes: time.map { ($0, .voltage) })
        for name in response {
            if let element = circuit.elements.first(where: { $0.name == name }) {
                circuit.scopes.append(ScopeSpec(elementID: element.id, quantity: .voltage, plot: .frequencyResponse))
            }
        }
        return circuit
    }

    // MARK: - Microphones and preamps

    static let micPreamp = Example(
        id: "mic-preamp", title: "Mic preamp: SSM2019 (sound)",
        summary: "A dynamic vocal mic into an SSM2019: 100 Ω between its RG pins sets a gain of 101 (40 dB), lifting the mic's 10 mV to line level on the VU meter. Its 10 kΩ resistors give the inputs a path to ground. Turn on sound to hear the voice; try another RG.",
        symbol: "mic.fill",
        circuit: drawn([
            part(.microphone, "MIC1", Examples.model(.microphone, "Dynamic vocal mic"), ["gnd": "GND", "hot": "inp", "cold": "inm"]),
            r("R1", 10_000, "inp", "GND"),
            r("R2", 10_000, "inm", "GND"),
            part(.instrumentationAmp, "U1", Examples.model(.instrumentationAmp, "SSM2019"),
                 ["minus": "inm", "plus": "inp", "rg1": "g1", "rg2": "g2", "ref": "GND", "out": "out"]),
            r("RG", 100, "g1", "g2"),
            part(.vuMeter, "VU1", Examples.model(.vuMeter, "VU meter, +4 dBu"), ["plus": "out", "minus": "GND"]),
            part(.speaker, "SPK1", ["fullScale": 2], ["plus": "out", "minus": "GND"]),
            part(.probe, "MIC", [:], ["plus": "inp", "minus": "inm"]),
        ], time: ["MIC", "SPK1"]))

    static let phantomPreamp = Example(
        id: "phantom-preamp", title: "Condenser mic on phantom power (sound)",
        summary: "A condenser mic powered over its own signal wires: 48 V through 6.81 kΩ to each, as a mixing desk does. 10 µF capacitors keep the 48 V out of the THAT1510, whose gain is 1 + 5 kΩ / 200 Ω = 26. The mic's legs sit near 33 V, the preamp's inputs at 0 V.",
        symbol: "mic.circle",
        circuit: drawn([
            part(.dcVoltage, "P48", ["voltage": 48], ["plus": "+48V", "minus": "GND"]),
            part(.microphone, "MIC1", Examples.model(.microphone, "Large-diaphragm condenser"), ["gnd": "GND", "hot": "h", "cold": "k"]),
            r("R1", 6810, "+48V", "h"),
            r("R2", 6810, "+48V", "k"),
            c("C1", 10e-6, "h", "ip"),
            c("C2", 10e-6, "k", "im"),
            r("R3", 6800, "ip", "GND"),
            r("R4", 6800, "im", "GND"),
            part(.instrumentationAmp, "U1", Examples.model(.instrumentationAmp, "THAT1510"),
                 ["minus": "im", "plus": "ip", "rg1": "g1", "rg2": "g2", "ref": "GND", "out": "out"]),
            r("RG", 200, "g1", "g2"),
            part(.vuMeter, "VU1", Examples.model(.vuMeter, "VU meter, +4 dBu"), ["plus": "out", "minus": "GND"]),
            part(.speaker, "SPK1", ["fullScale": 2], ["plus": "out", "minus": "GND"]),
            probe("HOT", "h"),
        ], time: ["HOT", "SPK1"]))

    static let electretPreamp = Example(
        id: "electret-preamp", title: "Electret mic preamp: NE5534 (sound)",
        summary: "An electret capsule (a JFET inside) biased through 2.2 kΩ from 9 V, then an NE5534 with a gain of 101: 100 kΩ over 1 kΩ, the 10 µF keeping its DC gain at one. A preamp for a microcontroller's ADC or a recorder.",
        symbol: "mic",
        circuit: drawn([
            part(.dcVoltage, "V1", ["voltage": 9], ["plus": "+9V", "minus": "GND"]),
            r("R1", 2200, "+9V", "d"),
            part(.electretMic, "MIC1", Examples.model(.electretMic, "Electret capsule"), ["out": "d", "gnd": "GND"]),
            c("C1", 1e-6, "d", "b"),
            r("R2", 100_000, "b", "GND"),
            opAmp("U1", "NE5534", plus: "b", minus: "f", out: "out"),
            r("R3", 100_000, "out", "f"),
            r("R4", 1000, "f", "e"),
            c("C2", 10e-6, "e", "GND"),
            part(.speaker, "SPK1", ["fullScale": 2], ["plus": "out", "minus": "GND"]),
        ], time: ["MIC1", "SPK1"]))

    // MARK: - Power amps and headphones

    static let lm386Amp = Example(
        id: "lm386-amp", title: "LM386 into a loudspeaker (sound)",
        summary: "The classic little amp: a volume knob into an LM386 on 9 V (a gain of 20; 10 µF from pin 1 to pin 8 makes it 200), 220 µF into a 4\" loudspeaker modelled by its Thiele-Small parameters, and a Zobel network (10 Ω and 47 nF) that keeps the amp stable as the speaker's impedance rises.",
        symbol: "speaker.wave.2.fill",
        circuit: drawn([
            part(.audioInput, "IN1", ["level": 0.15, "loop": 1], ["plus": "in", "minus": "GND"]),
            part(.potentiometer, "VOLUME", ["resistance": 10_000, "position": 0.3, "taper": 1], ["a": "in", "b": "GND", "wiper": "v"]),
            part(.audioPowerAmp, "U1", Examples.model(.audioPowerAmp, "LM386N-1"),
                 ["minus": "GND", "plus": "v", "gain1": "g1", "gain8": "g8", "bypass": "byp", "out": "o"]),
            c("C1", 10e-6, "byp", "GND"),
            c("C2", 220e-6, "o", "s"),
            r("R1", 10, "o", "z"),
            c("C3", 47e-9, "z", "GND"),
            part(.speaker, "SPK1", Examples.model(.speaker, "Full-range 4\" 8 Ω").merging(["fullScale": 3]) { $1 },
                 ["plus": "s", "minus": "GND"]),
        ], time: ["IN1", "SPK1"]))

    static let powerAmp = Example(
        id: "power-amp", title: "TDA2030 power amp (sound)",
        summary: "A power op-amp on ±16 V wired as a non-inverting amp with a gain of 33 (22 kΩ over 680 Ω, the 22 µF keeping its DC gain at one) into a 12\" guitar speaker, with a Zobel network. LM1875 and LM3886 are the same circuit with more power.",
        symbol: "hifispeaker.2.fill",
        circuit: drawn([
            part(.audioInput, "IN1", ["level": 0.3, "loop": 1], ["plus": "in", "minus": "GND"]),
            c("C1", 1e-6, "in", "p"),
            r("R1", 22_000, "p", "GND"),
            opAmp("U1", "TDA2030", plus: "p", minus: "f", out: "o"),
            r("R2", 22_000, "o", "f"),
            r("R3", 680, "f", "e"),
            c("C2", 22e-6, "e", "GND"),
            r("R4", 1, "o", "z"),
            c("C3", 220e-9, "z", "GND"),
            part(.speaker, "SPK1", Examples.model(.speaker, "Guitar 12\" 8 Ω").merging(["fullScale": 10]) { $1 },
                 ["plus": "o", "minus": "GND"]),
        ], time: ["IN1", "SPK1"]))

    static let headphoneAmp = Example(
        id: "headphone-amp", title: "Headphone amp: NJM4556 (sound)",
        summary: "An NJM4556, made to drive low impedances, with a gain of 2 into 32 Ω headphones through 33 Ω, which keeps it stable and sets the damping. The VU meter reads the consumer line level.",
        symbol: "headphones",
        circuit: drawn([
            voice("IN1", level: 0.5, plus: "in"),
            c("C1", 1e-6, "in", "p"),
            r("R1", 47_000, "p", "GND"),
            opAmp("U1", "NJM4556", plus: "p", minus: "f", out: "o"),
            r("R2", 10_000, "o", "f"),
            r("R3", 10_000, "f", "GND"),
            r("R4", 33, "o", "hp"),
            part(.speaker, "PHONES", Examples.model(.speaker, "Headphones 32 Ω").merging(["fullScale": 1]) { $1 },
                 ["plus": "hp", "minus": "GND"]),
            part(.vuMeter, "VU1", Examples.model(.vuMeter, "VU meter, −10 dBV"), ["plus": "hp", "minus": "GND"]),
        ], time: ["IN1", "PHONES"]))

    // MARK: - Balanced lines

    static let balancedLine = Example(
        id: "balanced-line", title: "Balanced line rejects hum",
        summary: "A 1 kHz tone sent down 10 m of cable near mains wiring, which induces 50 mV of 50 Hz hum in each conductor. Balanced (a DRV134 driving both conductors, an INA134 taking their difference) the hum cancels; unbalanced (the signal on one conductor, the other grounded) it comes through. Compare the two scopes.",
        symbol: "cable.connector",
        circuit: drawn([
            part(.acVoltage, "VS", ["amplitude": 1, "frequency": 1000], ["plus": "src", "minus": "GND"]),
            part(.lineDriver, "U1", Examples.model(.lineDriver, "DRV134"), ["in": "src", "outPlus": "dp", "outMinus": "dm"]),
            part(.balancedCable, "CBL1", Examples.model(.balancedCable, "Mic cable, 50 Hz mains"),
                 ["gnd1": "GND", "hot1": "dp", "cold1": "dm", "gnd2": "GND", "hot2": "rp", "cold2": "rm"]),
            part(.lineReceiver, "U2", Examples.model(.lineReceiver, "INA134"), ["minus": "rm", "plus": "rp", "ref": "GND", "out": "bal"]),
            part(.balancedCable, "CBL2", Examples.model(.balancedCable, "Mic cable, 50 Hz mains"),
                 ["gnd1": "GND", "hot1": "src", "cold1": "GND", "gnd2": "GND", "hot2": "up", "cold2": "um"]),
            r("R1", 100_000, "um", "GND"),
            opAmp("U3", "TL072", plus: "up", minus: "unbal", out: "unbal"),
            probe("BALANCED", "bal"),
            probe("UNBALANCED", "unbal"),
        ], time: ["BALANCED", "UNBALANCED"]))

    // MARK: - Dynamics

    static let compressor = Example(
        id: "compressor", title: "Compressor: THAT2180 and THAT2252 (sound)",
        summary: "A feed-forward compressor: the THAT2252 reads the voice's RMS level at 6.1 mV per dB; above the threshold (−10 dB, set by VT) an op-amp takes three quarters of the excess (a 4:1 ratio) and a precision rectifier passes only gain reduction to the THAT2180, which turns down 1 dB for each 6.1 mV. GR shows the gain reduction.",
        symbol: "waveform.path.badge.minus",
        circuit: drawn([
            voice("IN1", level: 2, plus: "in"),
            part(.vca, "U1", Examples.model(.vca, "THAT2180"), ["in": "in", "cv": "cv", "out": "out"]),
            part(.levelDetector, "U2", Examples.model(.levelDetector, "THAT2252"), ["in": "in", "ref": "GND", "out": "det"]),
            part(.dcVoltage, "VT", ["voltage": -0.061], ["plus": "thr", "minus": "GND"]),
            r("R1", 10_000, "thr", "a"),
            r("R2", 7500, "a", "x"),
            r("R3", 10_000, "det", "b"),
            r("R4", 7500, "b", "GND"),
            opAmp("U3", "TL072", plus: "b", minus: "a", out: "x"),
            opAmp("U4", "TL072", plus: "x", minus: "cv", out: "d"),
            part(.diode, "D1", Examples.model(.diode, "1N4148"), ["anode": "d", "cathode": "cv"]),
            r("R5", 10_000, "cv", "GND"),
            probe("GR", "cv"),
            part(.speaker, "SPK1", ["fullScale": 3], ["plus": "out", "minus": "GND"]),
        ], time: ["IN1", "SPK1", "GR"]))

    static let compander = Example(
        id: "compander", title: "NE570 compander (sound)",
        summary: "One NE570 channel compresses 2:1 (its ΔG cell in the op-amp's feedback, so the output's level sets the gain), the other expands 2:1: the voice comes out as it went in, while the signal between them (a tape or a radio link, where noise would get in) swings over half the decibels.",
        symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
        circuit: drawn([
            voice("IN1", level: 0.775, plus: "in"),
            c("C1", 2.2e-6, "in", "ci"),
            part(.compander, "U1", Examples.model(.compander, "NE570"),
                 ["rectIn": "cr", "gainIn": "cr", "rectCap": "rc1", "invIn": "inv1", "r3": "ci", "out": "comp"]),
            c("C2", 1e-6, "rc1", "GND"),
            c("C3", 2.2e-6, "comp", "cr"),
            r("R1", 100_000, "cr", "GND"),
            r("R2", 10_000, "comp", "dc"),
            r("R3", 10_000, "dc", "inv1"),
            c("C4", 10e-6, "dc", "GND"),
            c("C5", 2.2e-6, "comp", "ein"),
            r("R4", 100_000, "ein", "GND"),
            part(.compander, "U2", Examples.model(.compander, "NE570"),
                 ["rectIn": "ein", "gainIn": "ein", "rectCap": "rc2", "invIn": "inv2", "r3": "expo", "out": "expo"]),
            c("C6", 1e-6, "rc2", "GND"),
            probe("COMPRESSED", "comp"),
            part(.speaker, "SPK1", ["fullScale": 2], ["plus": "expo", "minus": "GND"]),
        ], time: ["IN1", "COMPRESSED", "SPK1"]))

    static let optoCompressor = Example(
        id: "opto-compressor", title: "Opto compressor (sound)",
        summary: "The LA-2A idea: the output, amplified, lights the LED of an NSL-32 opto cell whose LDR shunts the signal to ground after 10 kΩ. Louder means brighter, a lower resistance and less signal; the cell's slow release gives the smooth, programme-dependent sound.",
        symbol: "light.max",
        circuit: drawn([
            part(.audioInput, "IN1", ["level": 1, "loop": 1], ["plus": "in", "minus": "GND"]),
            r("R1", 10_000, "in", "s"),
            part(.vactrol, "OC1", Examples.model(.vactrol, "NSL-32"), ["anode": "led", "cathode": "GND", "a": "s", "b": "GND"]),
            opAmp("U1", "TL072", plus: "s", minus: "f", out: "out"),
            r("R2", 20_000, "out", "f"),
            r("R3", 10_000, "f", "GND"),
            opAmp("U2", "TL072", plus: "out", minus: "g", out: "sc"),
            r("R4", 47_000, "sc", "g"),
            r("R5", 4700, "g", "GND"),
            part(.diode, "D1", Examples.model(.diode, "1N4148"), ["anode": "sc", "cathode": "ledr"]),
            r("R6", 1000, "ledr", "led"),
            part(.speaker, "SPK1", ["fullScale": 3], ["plus": "out", "minus": "GND"]),
        ], time: ["IN1", "SPK1"]))

    static let noiseGate = Example(
        id: "noise-gate", title: "Noise gate (sound)",
        summary: "A voice over a hiss. A peak detector follows the level; a comparator opens the gate above 50 mV (with hysteresis, so it does not chatter), and 10 kΩ with 1 µF softens the gate's edges before a linear VCA. Between words the hiss is gone.",
        symbol: "waveform.badge.minus",
        circuit: drawn([
            part(.noiseVoltage, "HISS", ["amplitude": 0.01], ["plus": "n", "minus": "GND"]),
            voice("IN1", level: 0.5, plus: "in", minus: "n"),
            part(.levelDetector, "U1", Examples.model(.levelDetector, "Peak detector"), ["in": "in", "ref": "GND", "out": "env"]),
            part(.dcVoltage, "VT", ["voltage": 0.05], ["plus": "thr", "minus": "GND"]),
            part(.comparator, "U2", ["high": 5, "low": 0, "hysteresis": 0.02], ["minus": "thr", "plus": "env", "out": "gate"]),
            r("R1", 10_000, "gate", "sm"),
            c("C1", 1e-6, "sm", "GND"),
            part(.vca, "U3", Examples.model(.vca, "Linear"), ["in": "in", "cv": "sm", "out": "out"]),
            part(.speaker, "SPK1", ["fullScale": 1], ["plus": "out", "minus": "GND"]),
        ], time: ["IN1", "SPK1"]))

    // MARK: - Tone and EQ

    static let toneStacks = Example(
        id: "tone-stacks", title: "Fender and Marshall tone stacks",
        summary: "The passive treble-middle-bass stacks of guitar amps, side by side: Fender's (250 pF, 0.1 µF, 0.047 µF, 100 kΩ) and Marshall's (470 pF, 22 nF, 22 nF, 33 kΩ). The frequency-response scopes show the mid scoop; turn the knobs and watch it move.",
        symbol: "slider.vertical.3",
        circuit: drawn([
            part(.acVoltage, "VS", ["amplitude": 1, "frequency": 1000], ["plus": "in", "minus": "GND"]),
            c("C1", 250e-12, "in", "ft"),
            part(.potentiometer, "TREBLE1", ["resistance": 250_000, "position": 0.5, "taper": 1], ["a": "ft", "b": "fb", "wiper": "fo"]),
            r("R1", 100_000, "in", "fn"),
            c("C2", 100e-9, "fn", "fb"),
            c("C3", 47e-9, "fn", "fm"),
            part(.potentiometer, "BASS1", ["resistance": 1_000_000, "position": 0.5, "taper": 1], ["a": "fb", "b": "fm", "wiper": "fm"]),
            part(.potentiometer, "MID1", ["resistance": 10_000, "position": 0.5], ["a": "fm", "b": "GND", "wiper": "GND"]),
            r("RL1", 1_000_000, "fo", "GND"),
            probe("FENDER", "fo"),
            c("C4", 470e-12, "in", "mt"),
            part(.potentiometer, "TREBLE2", ["resistance": 220_000, "position": 0.5, "taper": 1], ["a": "mt", "b": "mb", "wiper": "mo"]),
            r("R2", 33_000, "in", "mn"),
            c("C5", 22e-9, "mn", "mb"),
            c("C6", 22e-9, "mn", "mm"),
            part(.potentiometer, "BASS2", ["resistance": 1_000_000, "position": 0.5, "taper": 1], ["a": "mb", "b": "mm", "wiper": "mm"]),
            part(.potentiometer, "MID2", ["resistance": 25_000, "position": 0.5], ["a": "mm", "b": "GND", "wiper": "GND"]),
            r("RL2", 1_000_000, "mo", "GND"),
            probe("MARSHALL", "mo"),
        ], time: [], response: ["FENDER", "MARSHALL"]))

    static let baxandall = Example(
        id: "baxandall", title: "Baxandall tone control",
        summary: "The active bass and treble control in nearly every hi-fi amp: both networks between the input and the output with their knobs' wipers into the op-amp's inverting input. Centred, it is flat; each knob boosts or cuts its end of the band by up to 15 dB.",
        symbol: "dial.medium",
        circuit: drawn([
            part(.acVoltage, "VS", ["amplitude": 1, "frequency": 1000], ["plus": "in", "minus": "GND"]),
            r("R1", 10_000, "in", "na"),
            part(.potentiometer, "BASS", ["resistance": 100_000, "position": 0.5], ["a": "na", "b": "nb", "wiper": "w"]),
            r("R2", 10_000, "nb", "out"),
            c("C1", 22e-9, "na", "w"),
            c("C2", 22e-9, "w", "nb"),
            r("R3", 3300, "w", "sum"),
            c("C3", 2.2e-9, "in", "ta"),
            part(.potentiometer, "TREBLE", ["resistance": 100_000, "position": 0.5], ["a": "ta", "b": "tb", "wiper": "tw"]),
            c("C4", 2.2e-9, "tb", "out"),
            r("R4", 3300, "tw", "sum"),
            opAmp("U1", "NE5532", plus: "GND", minus: "sum", out: "out"),
            probe("OUT", "out"),
        ], time: [], response: ["OUT"]))

    static let graphicEQ = Example(
        id: "graphic-eq", title: "Graphic EQ with gyrators",
        summary: "Five bands (60 Hz to 12 kHz). Each slider runs between the op-amp's inputs; its wiper meets a series resonant circuit to ground whose inductor is a gyrator: an op-amp follower, a capacitor and two resistors (L = R × R × C). A slider towards the input cuts its band, towards the output boosts it.",
        symbol: "slider.horizontal.3",
        circuit: drawn({
            var parts: [NetlistPart] = [
                part(.acVoltage, "VS", ["amplitude": 0.5, "frequency": 1000], ["plus": "in", "minus": "GND"]),
                r("RIN", 2200, "in", "p"),
                r("RF", 2200, "out", "n"),
                opAmp("U0", "TL072", plus: "p", minus: "n", out: "out"),
                probe("OUT", "out"),
            ]
            // (series capacitor, gyrator capacitor) for 60 Hz, 250 Hz, 1 kHz, 4 kHz and 12 kHz with 100 kΩ and 1 kΩ
            let bands: [(String, Double, Double, Double)] = [
                ("60", 1e-6, 70e-9, 0.7), ("250", 220e-9, 18e-9, 0.5), ("1K", 47e-9, 5.4e-9, 0.5), ("4K", 10e-9, 1.6e-9, 0.5),
                ("12K", 2.2e-9, 0.8e-9, 0.3),
            ]
            for (k, (label, cs, ca, position)) in bands.enumerated() {
                let n = k + 1
                parts += [
                    part(.potentiometer, "EQ" + label, ["resistance": 10_000, "position": position], ["a": "p", "b": "n", "wiper": "w\(n)"]),
                    c("CS\(n)", cs, "w\(n)", "g\(n)"),
                    c("CA\(n)", ca, "g\(n)", "y\(n)"),
                    r("RB\(n)", 100_000, "y\(n)", "GND"),
                    opAmp("U\(n)", "TL072", plus: "y\(n)", minus: "o\(n)", out: "o\(n)"),
                    r("RL\(n)", 1000, "o\(n)", "g\(n)"),
                ]
            }
            return parts
        }(), time: [], response: ["OUT"]))

    static let parametricEQ = Example(
        id: "parametric-eq", title: "Parametric EQ band (state-variable)",
        summary: "A state-variable filter (a summer and two integrators, 10 kΩ and 15.9 nF: 1 kHz, Q 1.5) whose band-pass output, through a GAIN knob between it and its inverse, is added to the signal: up to +8 dB or −6 dB around 1 kHz, flat with the knob centred.",
        symbol: "waveform.path.ecg",
        circuit: drawn([
            part(.acVoltage, "VS", ["amplitude": 0.5, "frequency": 1000], ["plus": "in", "minus": "GND"]),
            r("R1", 10_000, "in", "s1"),
            r("R2", 10_000, "lp", "s1"),
            r("R3", 10_000, "hp", "s1"),
            r("R4", 10_000, "bp", "p1"),
            r("R5", 2870, "p1", "GND"),
            opAmp("U1", "TL072", plus: "p1", minus: "s1", out: "hp"),
            r("R6", 10_000, "hp", "s2"),
            c("C1", 15.9e-9, "bp", "s2"),
            opAmp("U2", "TL072", plus: "GND", minus: "s2", out: "bp"),
            r("R7", 10_000, "bp", "s3"),
            c("C2", 15.9e-9, "lp", "s3"),
            opAmp("U3", "TL072", plus: "GND", minus: "s3", out: "lp"),
            r("R8", 10_000, "bp", "i4"),
            r("R9", 10_000, "i4", "nbp"),
            opAmp("U4", "TL072", plus: "GND", minus: "i4", out: "nbp"),
            part(.potentiometer, "GAIN", ["resistance": 10_000, "position": 0.25], ["a": "bp", "b": "nbp", "wiper": "w"]),
            r("R10", 10_000, "in", "s5"),
            r("R11", 10_000, "w", "s5"),
            r("R12", 10_000, "s5", "o5"),
            opAmp("U5", "TL072", plus: "GND", minus: "s5", out: "o5"),
            r("R13", 10_000, "o5", "s6"),
            r("R14", 10_000, "s6", "out"),
            opAmp("U6", "TL072", plus: "GND", minus: "s6", out: "out"),
            probe("OUT", "out"),
        ], time: [], response: ["OUT"]))

    static let toneControlChip = Example(
        id: "lm1036", title: "LM1036 tone control chip",
        summary: "Volume, bass and treble set by DC voltages: three knobs across the chip's 5.4 V reference. Centred, bass and treble are flat; the ends give ±15 dB around 250 Hz and 2 kHz. DC control keeps the knobs' wires free of audio.",
        symbol: "dial.low",
        circuit: drawn([
            part(.acVoltage, "VS", ["amplitude": 0.5, "frequency": 1000], ["plus": "in", "minus": "GND"]),
            part(.toneControl, "U1", Examples.model(.toneControl, "LM1036"),
                 ["in": "in", "volume": "vol", "bass": "bas", "treble": "tre", "ref": "ref", "out": "out"]),
            part(.potentiometer, "VOLUME", ["resistance": 10_000, "position": 0.1], ["a": "ref", "b": "GND", "wiper": "vol"]),
            part(.potentiometer, "BASS", ["resistance": 10_000, "position": 0.3], ["a": "ref", "b": "GND", "wiper": "bas"]),
            part(.potentiometer, "TREBLE", ["resistance": 10_000, "position": 0.5], ["a": "ref", "b": "GND", "wiper": "tre"]),
            probe("OUT", "out"),
        ], time: [], response: ["OUT"]))

    // MARK: - Guitar

    static let pickupFuzz = Example(
        id: "pickup-fuzz", title: "Fuzz Face with a humbucker (sound)",
        summary: "The Fuzz Face played by a guitar pickup instead of an ideal source: the humbucker's 8 kΩ and 4.5 H in series with the strings' voltage, its capacitance across. The fuzz's low input impedance loads the pickup and takes its treble: turn FUZZ and listen.",
        symbol: "guitars.fill",
        circuit: drawn(fuzzFaceParts(guitar: NetlistPart(kind: .pickup, name: "PU", params: Examples.model(.pickup, "Humbucker"),
                                                         connections: ["hot": "gtr", "gnd": "GND"])),
                       scopes: [("PU", .voltage), ("SPK1", .voltage)]))

    static let springReverb = Example(
        id: "spring-reverb", title: "Spring reverb (sound)",
        summary: "An op-amp drives a long spring tank's 1475 Ω input coil; another lifts what comes back from the springs (about 30 dB) and the MIX knob blends it with the dry guitar. The springs' delays and their dispersion give the drip of a surf guitar.",
        symbol: "water.waves",
        circuit: drawn([
            part(.audioInput, "IN1", ["level": 0.3, "loop": 1], ["plus": "in", "minus": "GND"]),
            opAmp("U1", "TL072", plus: "in", minus: "f", out: "drv"),
            r("R1", 40_000, "drv", "f"),
            r("R2", 10_000, "f", "GND"),
            part(.springReverb, "RT1", Examples.model(.springReverb, "Long tank, 1475 Ω input"), ["in": "drv", "gnd": "GND", "out": "wet"]),
            opAmp("U2", "TL072", plus: "wet", minus: "g", out: "rec"),
            r("R3", 47_000, "rec", "g"),
            r("R4", 2200, "g", "GND"),
            part(.potentiometer, "MIX", ["resistance": 10_000, "position": 0.4], ["a": "in", "b": "rec", "wiper": "mix"]),
            part(.speaker, "SPK1", ["fullScale": 2], ["plus": "mix", "minus": "GND"]),
        ], time: ["IN1", "SPK1"]))

    // MARK: - Meters

    static let barGraphMeter = Example(
        id: "bargraph", title: "LED level meter: LM3915",
        summary: "Ten LEDs in 3 dB steps: a diode and 1 µF catch the music's peaks (100 kΩ lets them fall), and the LM3915 compares them with taps on its resistor string, from its 1.25 V reference raised to 5.3 V by 1.2 kΩ and 3.9 kΩ. The chip sets the LEDs' current: no resistors. A VU meter reads the same signal.",
        symbol: "chart.bar.fill",
        circuit: drawn({
            var parts: [NetlistPart] = [
                part(.dcVoltage, "V1", ["voltage": 12], ["plus": "+12V", "minus": "GND"]),
                part(.audioInput, "IN1", ["level": 3, "loop": 1], ["plus": "in", "minus": "GND"]),
                part(.diode, "D1", Examples.model(.diode, "1N4148"), ["anode": "in", "cathode": "pk"]),
                c("C1", 1e-6, "pk", "GND"),
                r("R1", 100_000, "pk", "GND"),
                part(.barGraphDriver, "U1", Examples.model(.barGraphDriver, "LM3915"),
                     ["sig": "pk", "rlo": "GND", "rhi": "ref", "refOut": "ref", "refAdj": "adj"]
                        .merging(Dictionary(uniqueKeysWithValues: (1...10).map { ("led\($0)", "l\($0)") })) { $1 }),
                r("R2", 1200, "ref", "adj"),
                r("R3", 3900, "adj", "GND"),
                part(.vuMeter, "VU1", Examples.model(.vuMeter, "VU meter, +4 dBu"), ["plus": "in", "minus": "GND"]),
            ]
            for k in 1...10 {
                let color: LEDColor = k <= 6 ? .green : k <= 8 ? .yellow : .red
                parts.append(part(.led, "LED\(k)", ["color": Double(color.rawValue)], ["anode": "+12V", "cathode": "l\(k)"]))
            }
            return parts
        }(), time: ["IN1"]))
}
