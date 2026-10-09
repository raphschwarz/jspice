import Foundation

/// Examples for the pedal op-amps, ring modulators and the other chips added with them
extension Examples {
    static let chipExamples: [Example] = [tubeScreamer, rat, mc1496Ring, sa612Ring, diodeRing, frequencyShifter]

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

    private static func diode(_ name: String, _ model: String, anode: String, cathode: String) -> NetlistPart {
        part(.diode, name, Examples.model(.diode, model), ["anode": anode, "cathode": cathode])
    }

    /// An op-amp on a single 9 V supply: swinging about the 4.5 V reference, a few volts each way
    private static func pedalOpAmp(_ name: String, _ model: String, swing: Double, plus: String, minus: String, out: String) -> NetlistPart {
        part(.opAmp, name, Examples.model(.opAmp, model).merging(["limit": swing, "midpoint": 4.5]) { $1 },
             ["plus": plus, "minus": minus, "out": out])
    }

    /// A pot wired as a variable resistor between `a` and `b` (the wiper joined to `b`)
    private static func rheostat(_ name: String, _ ohms: Double, position: Double, audio: Bool, _ a: String, _ b: String) -> NetlistPart {
        part(.potentiometer, name, ["resistance": ohms, "position": position, "taper": audio ? 1 : 0], ["a": a, "b": b, "wiper": b])
    }

    /// A 9 V battery and the half-supply reference a pedal's op-amps work about
    private static func pedalSupply(divider: Double, filter: Double) -> [NetlistPart] {
        [
            part(.dcVoltage, "VB", ["voltage": 9], ["plus": "+9V", "minus": "GND"]),
            r("RA", divider, "+9V", "vref"),
            r("RB", divider, "vref", "GND"),
            c("CREF", filter, "vref", "GND"),
        ]
    }

    private static func guitar(level: Double = 0.15) -> NetlistPart {
        part(.audioInput, "GTR", ["level": level, "loop": 1], ["plus": "gtr", "minus": "GND"])
    }

    // MARK: - Pedals

    /// The Tube Screamer's clipping stage and tone control: a JRC4558 with two diodes in its feedback, so the drive
    /// clips softly, and only above the 720 Hz its gain leg passes (the bass stays clean: the mid hump)
    static let tubeScreamer = Example(
        id: "tube-screamer", title: "Tube Screamer overdrive (sound)",
        summary: "The TS808's heart on a 9 V battery: one half of a JRC4558 amplifies by 1 + (51 kΩ + DRIVE) / 4.7 kΩ, but its 4.7 kΩ leg goes to the 4.5 V reference through 47 nF, so only the frequencies above about 720 Hz are amplified and clipped by the two 1N4148s in its feedback: the soft, mid-heavy overdrive. A 1 kΩ and 220 nF filter tames the fizz, and the other half is the active TONE control. Turn on sound and turn DRIVE and TONE.",
        symbol: "flame.fill",
        circuit: drawn(pedalSupply(divider: 10_000, filter: 47e-6) + [
            guitar(),
            c("C1", 47e-9, "gtr", "in"),
            r("R1", 1e6, "in", "vref"),
            pedalOpAmp("U1", "JRC4558", swing: 3.2, plus: "in", minus: "fb", out: "drv"),
            r("R2", 4700, "fb", "leg"),
            c("C2", 47e-9, "leg", "vref"),
            r("R3", 51_000, "drv", "f1"),
            rheostat("DRIVE", 500_000, position: 0.5, audio: true, "f1", "fb"),
            c("C3", 51e-12, "drv", "fb"),
            diode("D1", "1N4148", anode: "drv", cathode: "fb"),
            diode("D2", "1N4148", anode: "fb", cathode: "drv"),
            r("R4", 1000, "drv", "t1"),
            c("C4", 220e-9, "t1", "vref"),
            r("R5", 1000, "t1", "p2"),
            pedalOpAmp("U2", "JRC4558", swing: 3.2, plus: "p2", minus: "n2", out: "o2"),
            r("R6", 1000, "o2", "n2"),
            r("R7", 220, "p2", "ta"),
            r("R8", 1000, "n2", "tb"),
            part(.potentiometer, "TONE", ["resistance": 20_000, "position": 0.5, "taper": 0], ["a": "ta", "b": "tb", "wiper": "tw"]),
            c("C5", 220e-9, "tw", "vref"),
            r("R9", 1000, "o2", "o3"),
            c("C6", 10e-6, "o3", "o4"),
            part(.potentiometer, "LEVEL", ["resistance": 100_000, "position": 0.7, "taper": 1], ["a": "o4", "b": "GND", "wiper": "out"]),
            part(.speaker, "SPK1", ["fullScale": 1.5], ["plus": "out", "minus": "GND"]),
        ], scopes: [("GTR", .voltage), ("SPK1", .voltage)]))

    /// The RAT: an LM308 whose slow slewing (0.3 V/µs with its 30 pF) is part of the sound, two gain legs that boost
    /// the treble most, and hard clipping by two diodes to ground
    static let rat = Example(
        id: "rat", title: "RAT distortion (sound)",
        summary: "The ProCo RAT's circuit on 9 V: an LM308 with up to 100 kΩ of DISTORTION over two legs to ground (47 Ω with 2.2 µF, 560 Ω with 4.7 µF), a gain of over 2000 in the treble. At high gain the LM308 cannot slew fast enough (0.3 V/µs), which rounds and thickens the sound. Two 1N4148s to ground clip hard, and FILTER sweeps a low-pass from bright to dark. Turn on sound.",
        symbol: "bolt.fill",
        circuit: drawn(pedalSupply(divider: 100_000, filter: 10e-6) + [
            guitar(),
            c("C1", 22e-9, "gtr", "in"),
            r("R1", 1e6, "in", "vref"),
            pedalOpAmp("U1", "LM308", swing: 3.5, plus: "in", minus: "fb", out: "drv"),
            rheostat("DISTORTION", 100_000, position: 0.6, audio: true, "drv", "fb"),
            c("C2", 100e-12, "drv", "fb"),
            r("R2", 47, "fb", "l1"),
            c("C3", 2.2e-6, "l1", "GND"),
            r("R3", 560, "fb", "l2"),
            c("C4", 4.7e-6, "l2", "GND"),
            c("C5", 4.7e-6, "drv", "c1"),
            r("R4", 1000, "c1", "clip"),
            diode("D1", "1N4148", anode: "clip", cathode: "GND"),
            diode("D2", "1N4148", anode: "GND", cathode: "clip"),
            r("R5", 1500, "clip", "f1"),
            rheostat("FILTER", 100_000, position: 0.2, audio: false, "f1", "flt"),
            c("C6", 3.3e-9, "flt", "GND"),
            c("C7", 1e-6, "flt", "o1"),
            part(.potentiometer, "VOLUME", ["resistance": 100_000, "position": 0.7, "taper": 1], ["a": "o1", "b": "GND", "wiper": "out"]),
            part(.speaker, "SPK1", ["fullScale": 1], ["plus": "out", "minus": "GND"]),
        ], scopes: [("GTR", .voltage), ("SPK1", .voltage)]))

    // MARK: - Ring modulators

    /// The MC1496 as a ring modulator, biased as in its datasheet: about 1 mA into pin 5, the signal pair's inputs at
    /// ground, the carrier's at +6 V, 3.9 kΩ loads to +12 V, and a difference amplifier taking the two outputs apart
    static let mc1496Ring = Example(
        id: "mc1496-ring", title: "Ring modulator: MC1496 (sound)",
        summary: "A guitar riff times a 440 Hz carrier in an MC1496, built transistor by transistor (its Gilbert cell, current sources and bias mirror). 6.8 kΩ from pin 5 sets about 1 mA in each half, 1 kΩ between pins 2 and 3 its gain; the carrier switches the quad at +6 V. Only the sum and difference frequencies come out: a metallic, bell-like sound. Turn on sound; change the carrier's frequency in the inspector.",
        symbol: "multiply.circle",
        circuit: drawn([
            part(.dcVoltage, "VP", ["voltage": 12], ["plus": "+12V", "minus": "GND"]),
            guitar(),
            c("C1", 1e-6, "gtr", "sp"),
            r("R1", 1000, "sp", "GND"),
            r("R2", 1000, "sm", "GND"),
            part(.balancedModulator, "U1", Examples.model(.balancedModulator, "MC1496"),
                 ["sigPlus": "sp", "sigMinus": "sm", "carPlus": "cp", "carMinus": "cm", "bias": "b5", "gain1": "g1", "gain2": "g2",
                  "outPlus": "op", "outMinus": "om"]),
            r("RE", 1000, "g1", "g2"),
            r("RB", 6800, "b5", "GND"),
            r("R3", 10_000, "+12V", "cb"),
            r("R4", 10_000, "cb", "GND"),
            c("C2", 10e-6, "cb", "GND"),
            r("R5", 1000, "cp", "cb"),
            r("R6", 1000, "cm", "cb"),
            part(.acVoltage, "CARRIER", ["amplitude": 0.3, "frequency": 440], ["plus": "car", "minus": "GND"]),
            c("C3", 100e-9, "car", "cp"),
            r("RL1", 3900, "+12V", "op"),
            r("RL2", 3900, "+12V", "om"),
            r("R7", 10_000, "om", "pp"),
            r("R8", 10_000, "pp", "GND"),
            r("R9", 10_000, "op", "nn"),
            r("R10", 10_000, "out", "nn"),
            part(.opAmp, "U2", Examples.model(.opAmp, "TL072"), ["plus": "pp", "minus": "nn", "out": "out"]),
            part(.speaker, "SPK1", ["fullScale": 2], ["plus": "out", "minus": "GND"]),
        ], scopes: [("GTR", .voltage), ("SPK1", .voltage)]))

    /// The SA612 as a ring modulator: the guitar on one input (the other held at AC ground), a carrier on the
    /// oscillator's base instead of a crystal
    static let sa612Ring = Example(
        id: "sa612-ring", title: "Ring modulator: SA612 (sound)",
        summary: "The SA612 mixer, made for radios, as a ring modulator: a guitar riff into IN A (IN B held at AC ground by 100 nF), a 300 Hz carrier on the oscillator's base (pin 6) where a crystal would go. Its inputs and outputs have 1.5 kΩ inside; the outputs sit near 5 V, so they are coupled out with capacitors. Turn on sound.",
        symbol: "dot.radiowaves.left.and.right",
        circuit: drawn([
            guitar(),
            c("C1", 100e-9, "gtr", "ia"),
            c("C2", 100e-9, "ib", "GND"),
            part(.acVoltage, "CARRIER", ["amplitude": 0.2, "frequency": 300], ["plus": "car", "minus": "GND"]),
            c("C3", 100e-9, "car", "ob"),
            part(.mixerOscillator, "U1", Examples.model(.mixerOscillator, "SA612"),
                 ["inA": "ia", "inB": "ib", "oscBase": "ob", "oscEmitter": "oe", "outA": "oa", "outB": "obb"]),
            r("RE", 10_000, "oe", "GND"),
            c("C4", 10e-6, "oa", "out"),
            r("R1", 10_000, "out", "GND"),
            c("C5", 10e-6, "obb", "outb"),
            r("R2", 10_000, "outb", "GND"),
            part(.speaker, "SPK1", ["fullScale": 1], ["plus": "out", "minus": "GND"]),
        ], scopes: [("GTR", .voltage), ("SPK1", .voltage)]))

    /// The classic passive ring modulator: four germanium diodes in a ring between two centre-tapped transformers, the
    /// carrier between the taps
    static let diodeRing = Example(
        id: "diode-ring", title: "Diode ring modulator (sound)",
        summary: "The ring modulator of the first synthesizers and of the Daleks: four OA90 germanium diodes in a ring between two centre-tapped transformers. A 300 Hz carrier into the input transformer's tap switches the diodes in pairs, so the guitar reaches the output transformer one way round, then the other: the guitar times a square wave. Turn on sound; raise the carrier until it is louder than the guitar.",
        symbol: "circle.circle",
        circuit: drawn([
            guitar(level: 0.3),
            r("R1", 100, "gtr", "ta"),
            part(.tappedTransformer, "T1", Examples.model(.tappedTransformer, "600 Ω : 600 Ω CT"),
                 ["a1": "ta", "a2": "GND", "b1": "ra", "ct": "ct1", "b2": "rc"]),
            part(.acVoltage, "CARRIER", ["amplitude": 1, "frequency": 300], ["plus": "c0", "minus": "GND"]),
            r("R2", 100, "c0", "ct1"),
            diode("D1", "OA90", anode: "ra", cathode: "rb"),
            diode("D2", "OA90", anode: "rb", cathode: "rc"),
            diode("D3", "OA90", anode: "rc", cathode: "rd"),
            diode("D4", "OA90", anode: "rd", cathode: "ra"),
            part(.tappedTransformer, "T2", Examples.model(.tappedTransformer, "600 Ω : 600 Ω CT"),
                 ["a1": "out", "a2": "GND", "b1": "rb", "ct": "GND", "b2": "rd"]),
            r("RL", 600, "out", "GND"),
            part(.speaker, "SPK1", ["fullScale": 0.3], ["plus": "out", "minus": "GND"]),
        ], scopes: [("GTR", .voltage), ("SPK1", .voltage)]))

    /// A first-order all-pass stage on one op-amp: unity gain, its phase falling from 0 to −180° about 1 / (2π R C)
    private static func allPass(_ name: String, _ ohms: Double, input: String, output: String) -> [NetlistPart] {
        [
            r(name + "A", 10_000, input, name + "n"),
            r(name + "F", 10_000, output, name + "n"),
            r(name + "R", ohms, input, name + "p"),
            c(name + "C", 10e-9, name + "p", "GND"),
            part(.opAmp, name, Examples.model(.opAmp, "TL074"), ["plus": name + "p", "minus": name + "n", "out": output]),
        ]
    }

    /// Bode's frequency shifter: two chains of all-pass stages whose outputs stay 90° apart over the audio band (within
    /// a degree from 40 Hz to 8 kHz), each multiplied by one of a quadrature pair of carriers, and the products subtracted:
    /// every frequency moves up by the carrier's, not in proportion as a pitch shift would
    static let frequencyShifter = Example(
        id: "frequency-shifter", title: "Bode frequency shifter (sound)",
        summary: "Every frequency of a guitar riff moved up by 30 Hz: two chains of four all-pass stages (TL074s, 10 nF with 261k, 41.2k, 7.32k and 825 Ω, and with 1M, 102k, 17.4k and 3.01k) keep their outputs 90° apart, within a degree from 40 Hz to 8 kHz. Two AD633s multiply them by a cosine and a sine at 30 Hz, and their difference keeps only the sum frequencies (their sum would keep the differences). Harmonics no longer line up: the guitar turns bell-like and detuned. Turn on sound; try a carrier of 2 Hz for a slow, phaser-like swirl.",
        symbol: "waveform.path",
        circuit: drawn(frequencyShifterParts(), scopes: [("GTR", .voltage), ("SPK1", .voltage)]))

    private static func frequencyShifterParts() -> [NetlistPart] {
        var parts: [NetlistPart] = [guitar(), r("RIN", 10_000, "gtr", "in"), r("RIN2", 100_000, "in", "GND")]
        // the two chains: the first ends at "i" (in phase), the second at "q" (90° behind)
        for (chain, ohms, end) in [("UA", [261_000.0, 41_200, 7320, 825], "i"), ("UB", [1e6, 102_000, 17_400, 3010], "q")] {
            var input = "in"
            for (k, value) in ohms.enumerated() {
                let output = k == ohms.count - 1 ? end : chain.lowercased() + "\(k + 1)"
                parts += allPass(chain + "\(k + 1)", value, input: input, output: output)
                input = output
            }
        }
        parts += [
            part(.acVoltage, "COS", ["amplitude": 10, "frequency": 30, "phase": 90], ["plus": "cos", "minus": "GND"]),
            part(.acVoltage, "SIN", ["amplitude": 10, "frequency": 30], ["plus": "sin", "minus": "GND"]),
            part(.multiplier, "X1", Examples.model(.multiplier, "AD633"), ["x": "i", "y": "cos", "out": "pi"]),
            part(.multiplier, "X2", Examples.model(.multiplier, "AD633"), ["x": "q", "y": "sin", "out": "pq"]),
            r("RD1", 10_000, "pi", "dp"),
            r("RD2", 10_000, "dp", "GND"),
            r("RD3", 10_000, "pq", "dn"),
            r("RD4", 10_000, "out", "dn"),
            part(.opAmp, "UD", Examples.model(.opAmp, "TL072"), ["plus": "dp", "minus": "dn", "out": "out"]),
            part(.speaker, "SPK1", ["fullScale": 0.3], ["plus": "out", "minus": "GND"]),
        ]
        return parts
    }
}
