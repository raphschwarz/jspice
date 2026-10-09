import Foundation

/// Examples for the pedal op-amps, ring modulators and the other chips added with them
extension Examples {
    static let chipExamples: [Example] = [tubeScreamer, rat, mc1496Ring, sa612Ring, diodeRing, frequencyShifter, xr2206Generator,
                                          nortonAmplifier, shiftRegisterSequencer, clockedChorus, multiTapEcho, fv1Reverb, beltonReverb,
                                          optoTremolo, micAGC, rmsCompressor, trueBypass, arduinoDualDAC, arduinoADCToDAC, picoI2S]

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

    // MARK: - Synth chips

    /// The XR2206 as a function generator: the timing resistor (10 kΩ and a pot) from pin 7 to ground and 47 nF set
    /// f = 1 / (R C), from about 190 Hz to 2.1 kHz
    static let xr2206Generator = Example(
        id: "xr2206", title: "XR2206 function generator (sound)",
        summary: "The XR2206 on 12 V: 10 kΩ plus the FREQUENCY pot from its timing pin to ground with 47 nF gives f = 1 / (R C), about 190 Hz to 2.1 kHz. It puts out a sine (choose a triangle in the inspector) at 6 V and a square from its sync pin. Turn on sound and turn FREQUENCY.",
        symbol: "waveform",
        circuit: drawn([
            part(.functionGenerator, "U1", Examples.model(.functionGenerator, "XR2206").merging(["capacitance": 47e-9, "amplitude": 2]) { $1 },
                 ["timing": "t", "control": "am", "out": "sine", "square": "sq"]),
            r("R1", 10_000, "t", "tp"),
            rheostat("FREQUENCY", 100_000, position: 0.3, audio: true, "tp", "GND"),
            r("R2", 100_000, "am", "+12V"),
            part(.dcVoltage, "VP", ["voltage": 12], ["plus": "+12V", "minus": "GND"]),
            c("C1", 10e-6, "sine", "out"),
            r("R3", 10_000, "out", "GND"),
            r("R4", 10_000, "sq", "GND"),
            part(.speaker, "SPK1", ["fullScale": 2], ["plus": "out", "minus": "GND"]),
        ], scopes: [("SPK1", .voltage), ("R4", .voltage)]))

    /// An LM3900 amplifier on one supply: its + input fed from the supply through twice the feedback resistor, so the
    /// output sits at half the supply (a Norton amplifier balances input currents, not voltages)
    static let nortonAmplifier = Example(
        id: "lm3900-amp", title: "LM3900 Norton amplifier (sound)",
        summary: "One of the LM3900's four current-differencing amplifiers, built transistor by transistor, as a single-supply amplifier with a gain of 10: its inputs are junctions at about 0.5 V, and it balances the currents into them. 200 kΩ from 15 V into + and 100 kΩ of feedback set the output's rest at half the supply (Rf / Rbias × V+); 10 kΩ in from the guitar sets the gain, −Rf / Rin. The output's 0.5 V/µs slew and 2.5 MHz shape the top end. Turn on sound.",
        symbol: "arrow.triangle.branch",
        circuit: drawn([
            part(.dcVoltage, "VP", ["voltage": 15], ["plus": "+15V", "minus": "GND"]),
            guitar(),
            c("C1", 1e-6, "gtr", "ci"),
            r("RIN", 10_000, "ci", "inv"),
            r("RBIAS", 200_000, "+15V", "noninv"),
            r("RF", 100_000, "out", "inv"),
            part(.nortonAmp, "U1", Examples.model(.nortonAmp, "LM3900"), ["minus": "inv", "plus": "noninv", "out": "out"]),
            c("C2", 10e-6, "out", "spk"),
            r("RL", 10_000, "spk", "GND"),
            part(.speaker, "SPK1", ["fullScale": 1.5], ["plus": "spk", "minus": "GND"]),
            part(.probe, "OUT", [:], ["plus": "out", "minus": "GND"]),
        ], scopes: [("GTR", .voltage), ("OUT", .voltage)]))

    /// A walking pattern from a 74HC595: its last stage, inverted, fed back into its first (a Johnson counter, sixteen
    /// steps), its outputs summed by equal resistors into a 1 V/octave VCO, a semitone for each output high
    static let shiftRegisterSequencer = Example(
        id: "shift-sequencer", title: "Shift-register sequencer (sound)",
        summary: "A 74HC14 oscillator clocks a 74HC595 five times a second, both its clocks joined. Q7S, inverted by another 74HC14 gate, feeds SER, so ones fill the register and then zeros chase them: sixteen steps. 47 kΩ from each output into 1 kΩ adds about a twelfth of a volt (a semitone) for each output high, and an AS3340 at 1 V/octave plays the run up and down. Turn on sound.",
        symbol: "stairs",
        circuit: drawn([
            part(.dcVoltage, "VCC", ["voltage": 5], ["plus": "+5V", "minus": "GND"]),
            part(.schmittInverter, "U1A", Examples.model(.schmittInverter, "74HC14"), ["in": "osc", "out": "clk"]),
            r("RT", 220_000, "clk", "osc"),
            c("CT", 1e-6, "osc", "GND"),
            part(.shiftRegister, "U2", Examples.model(.shiftRegister, "74HC595"),
                 ["ser": "ser", "srclk": "clk", "rclk": "clk", "oe": "GND", "srclr": "+5V",
                  "q0": "q0", "q1": "q1", "q2": "q2", "q3": "q3", "q4": "q4", "q5": "q5", "q6": "q6", "q7": "q7", "q7s": "q7s"]),
            part(.schmittInverter, "U1B", Examples.model(.schmittInverter, "74HC14"), ["in": "q7s", "out": "ser"]),
        ] + (0...7).map { r("RQ\($0)", 47_000, "q\($0)", "cv") } + [
            r("RCV", 1000, "cv", "GND"),
            part(.vco, "U3", Examples.model(.vco, "AS3340").merging(["waveform": 0, "frequency": 130.81]) { $1 },
                 ["cv": "cv", "pw": "GND", "out": "out"]),
            part(.speaker, "SPK1", ["fullScale": 5], ["plus": "out", "minus": "GND"]),
            part(.probe, "CV", [:], ["plus": "cv", "minus": "GND"]),
        ], scopes: [("CV", .voltage), ("SPK1", .voltage)]))

    // MARK: - Delays, reverbs and opto

    /// A pot from GND to `supply`, its wiper a control voltage
    private static func control(_ name: String, _ position: Double, supply: String, wiper: String) -> NetlistPart {
        part(.potentiometer, name, ["resistance": 10_000, "position": position], ["a": "GND", "b": supply, "wiper": wiper])
    }

    /// A chorus as pedals build it: a bucket brigade clocked by a clock driver, its clock swept by an LFO
    static let clockedChorus = Example(
        id: "bbd-chorus-mn3102", title: "BBD chorus with its clock driver (sound)",
        summary: "An MN3207 bucket brigade clocked from pin CP1 of an MN3102. The clock runs at about 1 / (2.2 R C): 56 kΩ from RX and 100 pF make 80 kHz, so the 1024 stages delay the guitar by 512 cycles, 6.4 ms. A 0.7 Hz LFO through 470 kΩ into RX sweeps the clock by a quarter either way, so the delay swings from about 5 to 8.5 ms, and mixed with the dry guitar the delayed copy shimmers. Low-pass filters before and after keep the clock's images out. The bucket brigade counts the driver's cycles exactly, whatever the step. Turn on sound.",
        symbol: "water.waves",
        circuit: drawn([
            guitar(),
            part(.acVoltage, "LFO", ["amplitude": 2, "frequency": 0.7], ["plus": "lfo", "minus": "GND"]),
            r("RLFO", 470_000, "lfo", "rx"),
            r("RT", 56_000, "rx", "GND"),
            part(.bbdClock, "U1", Examples.model(.bbdClock, "MN3102"), ["rx": "rx", "cp1": "cp1", "cp2": "cp2", "vgg": "vgg"]),
            r("RIN", 10_000, "gtr", "bin"),
            c("CIN", 4.7e-9, "bin", "GND"),
            part(.delayLine, "U2", Examples.model(.delayLine, "MN3207").merging(["clocking": 1]) { $1 },
                 ["in": "bin", "ctrl": "cp1", "out": "bout"]),
            r("RF1", 10_000, "bout", "f1"),
            c("CF1", 4.7e-9, "f1", "GND"),
            r("RF2", 10_000, "f1", "wet"),
            c("CF2", 2.2e-9, "wet", "GND"),
            r("RDRY", 20_000, "gtr", "mix"),
            r("RWET", 20_000, "wet", "mix"),
            r("RMIX", 20_000, "mix", "GND"),
            part(.speaker, "SPK1", ["fullScale": 0.15], ["plus": "mix", "minus": "GND"]),
        ], scopes: [("SPK1", .voltage), ("LFO", .voltage)]))

    /// Six echoes from one bucket brigade: the MN3011's taps, none a multiple of another
    static let multiTapEcho = Example(
        id: "mn3011-multitap", title: "MN3011 multi-tap echo (sound)",
        summary: "An MN3011 clocked by an MN3101 at about 16.8 kHz (270 kΩ and 100 pF): its six outputs give the guitar back after 12, 20, 36, 51, 83 and 99 ms, at stages 396, 662, 1194, 1726, 2790 and 3328, spaced so that no echo lands on another's multiple, the way BBD reverbs and multi-head tape echoes blur into a room. The later taps are mixed in louder. A 3.4 kHz filter on the way in keeps the slow clock from aliasing, and another smooths the steps on the way out. Turn on sound.",
        symbol: "repeat",
        circuit: drawn([
            guitar(),
            r("RT", 270_000, "rx", "GND"),
            part(.bbdClock, "U1", Examples.model(.bbdClock, "MN3101"), ["rx": "rx", "cp1": "cp1", "cp2": "cp2", "vgg": "vgg"]),
            r("RIN", 10_000, "gtr", "bin"),
            c("CIN", 4.7e-9, "bin", "GND"),
            part(.multiTapDelay, "U2", Examples.model(.multiTapDelay, "MN3011"),
                 ["in": "bin", "cp": "cp1", "out1": "t1", "out2": "t2", "out3": "t3", "out4": "t4", "out5": "t5", "out6": "t6"]),
        ] + [(1, 68_000.0), (2, 56_000), (3, 47_000), (4, 39_000), (5, 33_000), (6, 27_000)].map { r("RTAP\($0.0)", $0.1, "t\($0.0)", "taps") } + [
            r("RTAPS", 10_000, "taps", "GND"),
            r("RF", 10_000, "taps", "wet"),
            c("CF", 4.7e-9, "wet", "GND"),
            r("RDRY", 22_000, "gtr", "mix"),
            r("RWET", 10_000, "wet", "mix"),
            r("RMIX", 22_000, "mix", "GND"),
            part(.speaker, "SPK1", ["fullScale": 0.12], ["plus": "mix", "minus": "GND"]),
        ], scopes: [("SPK1", .voltage)]))

    /// The FV-1's hall reverb, its three pots on 3.3 V
    static let fv1Reverb = Example(
        id: "fv1-reverb", title: "FV-1 reverb (sound)",
        summary: "Spin's FV-1 running its Reverb 2 program (S0–S2 pick one of eight; choose another in the inspector): a hall-sized plate reverb, here rewritten after Dattorro, at 32.768 kHz. TIME on POT0 sets how long the tail rings (about 1 to 6 s), TONE on POT1 its brightness and LOW CUT on POT2 how thin it is; each pot is a 10 kΩ divider from 3.3 V. The chip's output is the reverb alone, mixed here with the dry guitar. Try program 0 (chorus and reverb) or 3 (pitch shift). Turn on sound.",
        symbol: "building.columns",
        circuit: drawn([
            part(.dcVoltage, "V33", ["voltage": 3.3], ["plus": "+3V3", "minus": "GND"]),
            guitar(),
            part(.effectsProcessor, "U1", Examples.model(.effectsProcessor, "FV-1").merging(["program": 7]) { $1 },
                 ["in": "gtr", "pot0": "p0", "pot1": "p1", "pot2": "p2", "outL": "left", "outR": "right"]),
            control("TIME", 0.5, supply: "+3V3", wiper: "p0"),
            control("TONE", 0.5, supply: "+3V3", wiper: "p1"),
            control("LOWCUT", 0.2, supply: "+3V3", wiper: "p2"),
            r("RDRY", 10_000, "gtr", "mix"),
            r("RWET", 10_000, "left", "mix"),
            r("RMIX", 10_000, "mix", "GND"),
            r("RR", 10_000, "right", "GND"),
            part(.speaker, "SPK1", ["fullScale": 0.15], ["plus": "mix", "minus": "GND"]),
            part(.probe, "RIGHT", [:], ["plus": "right", "minus": "GND"]),
        ], scopes: [("SPK1", .voltage), ("RIGHT", .voltage)]))

    /// A Belton brick's spring sound mixed back with the guitar
    static let beltonReverb = Example(
        id: "belton-reverb", title: "Belton brick reverb (sound)",
        summary: "A Belton BTDR-2H reverb brick: a spring reverb's drip and splash made by delay chips, wet only, the way most reverb pedals get theirs. The guitar goes in through 1 µF; output 1 goes through the LEVEL pot and is mixed with the dry guitar. Its second output, a little different, is for stereo. Turn on sound and turn LEVEL.",
        symbol: "wave.3.right",
        circuit: drawn([
            guitar(),
            c("CIN", 1e-6, "gtr", "bin"),
            r("RB", 100_000, "bin", "GND"),
            part(.reverbBrick, "U1", Examples.model(.reverbBrick, "BTDR-2H"), ["in": "bin", "gnd": "GND", "out1": "o1", "out2": "o2"]),
            part(.potentiometer, "LEVEL", ["resistance": 10_000, "position": 0.6, "taper": 1], ["a": "GND", "b": "o1", "wiper": "wet"]),
            r("RO2", 10_000, "o2", "GND"),
            r("RDRY", 10_000, "gtr", "mix"),
            r("RWET", 10_000, "wet", "mix"),
            r("RMIX", 10_000, "mix", "GND"),
            part(.speaker, "SPK1", ["fullScale": 0.15], ["plus": "mix", "minus": "GND"]),
        ], scopes: [("SPK1", .voltage)]))

    /// A tremolo from a photo-FET: its channel shunts the guitar to ground as its LED is lit
    static let optoTremolo = Example(
        id: "h11f1-tremolo", title: "H11F1 opto tremolo (sound)",
        summary: "An H11F1 photo-FET optocoupler as a voltage-controlled resistor: a 5 Hz LFO from 0 to 5 V lights its LED through 220 Ω, and its FET channel, about 150 Ω at 16 mA and hundreds of megohms dark, shunts the guitar after 4.7 kΩ. The level dips each time the LED lights: a choppy tremolo, as fast as the LFO since the FET follows the light within tens of microseconds (a vactrol's cell lags milliseconds). Turn on sound.",
        symbol: "lightbulb.led.fill",
        circuit: drawn([
            guitar(),
            part(.acVoltage, "LFO", ["amplitude": 2.5, "offset": 2.5, "frequency": 5], ["plus": "lfo", "minus": "GND"]),
            r("RLED", 220, "lfo", "led"),
            part(.vactrol, "U1", Examples.model(.vactrol, "H11F1"), ["anode": "led", "cathode": "GND", "a": "out", "b": "GND"]),
            r("RS", 4700, "gtr", "out"),
            part(.speaker, "SPK1", ["fullScale": 0.15], ["plus": "out", "minus": "GND"]),
        ], scopes: [("SPK1", .voltage), ("LFO", .voltage)]))

    // MARK: - Dynamics, switching and converters

    /// A voice through the SSM2166: its preamp, compressor and gate
    static let micAGC = Example(
        id: "ssm2166-agc", title: "SSM2166 mic preamp with compression (sound)",
        summary: "A dynamic mic into an SSM2166: its preamp (×10) feeds a VCA steered by its RMS detector. Above the rotation point (100 mV RMS out of the preamp) every 3 dB louder comes out 1 dB louder, so loud and soft words come out closer in level; below the gate (2 mV) the VCA closes a dB for each dB, hushing the hiss between words. Compare the mic and the output on the scope, and turn up RATIO in the inspector. Turn on sound.",
        symbol: "mic.badge.plus",
        circuit: drawn([
            part(.microphone, "MIC1", Examples.model(.microphone, "Dynamic vocal mic"), ["gnd": "GND", "hot": "mic", "cold": "GND"]),
            part(.agcPreamp, "U1", Examples.model(.agcPreamp, "SSM2166"), ["in": "mic", "gnd": "GND", "out": "out"]),
            c("C1", 10e-6, "out", "spk"),
            r("RL", 10_000, "spk", "GND"),
            part(.speaker, "SPK1", ["fullScale": 1], ["plus": "spk", "minus": "GND"]),
            part(.probe, "MIC", [:], ["plus": "mic", "minus": "GND"]),
        ], scopes: [("MIC", .voltage), ("SPK1", .voltage)]))

    /// A feed-forward compressor from a THAT4301: its RMS detector steers its VCA, through a divider that sets the ratio
    static let rmsCompressor = Example(
        id: "that4301-compressor", title: "THAT4301 compressor (sound)",
        summary: "THAT's Analog Engine as a feed-forward compressor, the dbx way. The spare op-amp amplifies the guitar by 8 (18 dB) into the RMS detector, so its output crosses 0 V when the guitar is at about 100 mV RMS (the rotation point), moving 6.1 mV for each dB. A divider passes three quarters of that to the VCA's EC− (−6.1 mV per dB), so for every 4 dB the guitar rises above the rotation point the VCA takes 3 dB away: 4:1. Below it the VCA adds gain in the same way. Turn on sound and change RA and RB for other ratios.",
        symbol: "gauge.with.dots.needle.33percent",
        circuit: drawn([
            part(.dcVoltage, "VP", ["voltage": 15], ["plus": "+15V", "minus": "GND"]),
            guitar(level: 0.4),
            part(.analogEngine, "U1", Examples.model(.analogEngine, "THAT4301"),
                 ["in": "gtr", "ec": "ec", "out": "out", "rmsIn": "side", "rmsOut": "rms", "oaMinus": "fb", "oaPlus": "gtr", "oaOut": "side"]),
            r("RF", 70_000, "side", "fb"),
            r("RG", 10_000, "fb", "GND"),
            r("RA", 25_000, "rms", "ec"),
            r("RB", 75_000, "ec", "GND"),
            part(.speaker, "SPK1", ["fullScale": 1], ["plus": "out", "minus": "GND"]),
            part(.probe, "EC", [:], ["plus": "ec", "minus": "GND"]),
        ], scopes: [("GTR", .voltage), ("SPK1", .voltage), ("EC", .voltage)]))

    /// A 3PDT footswitch wired for true bypass around a boost, its third pole lighting the LED
    static let trueBypass = Example(
        id: "true-bypass", title: "3PDT true bypass (sound)",
        summary: "The footswitch of most pedals: three poles, two throws. Bypassed, pole 1 and pole 2 join the input jack straight to the output jack, and the effect's input and output are cut off from both. Pressed in, pole 1 sends the guitar into the effect (an op-amp gain of 11 with two 1N4148s clipping in its feedback), pole 2 takes the output from it, and pole 3 grounds the LED's cathode so it lights. Click the footswitch to switch the effect in and out. Turn on sound.",
        symbol: "power.circle",
        circuit: drawn(pedalSupply(divider: 10_000, filter: 47e-6) + [
            guitar(),
            part(.footswitch, "SW1", [:], ["c1": "gtr", "a1": "bypass", "b1": "fxsend", "c2": "out", "a2": "bypass", "b2": "fxreturn",
                                          "c3": "ledk", "a3": "ledoff", "b3": "GND"]),
            c("C1", 100e-9, "fxsend", "fxin"),
            r("RBIAS", 1_000_000, "fxin", "vref"),
            r("RPD1", 1_000_000, "fxsend", "GND"),
            pedalOpAmp("U1", "TL072", swing: 3.5, plus: "fxin", minus: "fb", out: "fxo"),
            r("RF", 100_000, "fxo", "fb"),
            diode("D1", "1N4148", anode: "fxo", cathode: "fb"),
            diode("D2", "1N4148", anode: "fb", cathode: "fxo"),
            r("RG", 10_000, "fb", "g"),
            c("CG", 1e-6, "g", "vref"),
            c("C2", 1e-6, "fxo", "fxreturn"),
            r("RPD2", 100_000, "fxreturn", "GND"),
            r("RLED", 4700, "+9V", "leda"),
            part(.led, "LED1", ["color": 2], ["anode": "leda", "cathode": "ledk"]),
            r("RL", 100_000, "out", "GND"),
            part(.speaker, "SPK1", ["fullScale": 1], ["plus": "out", "minus": "GND"]),
        ], scopes: [("SPK1", .voltage)]))

    /// Two control voltages from an MCP4822, written by an Arduino over SPI
    static let arduinoDualDAC = Example(
        id: "arduino-mcp4822", title: "Arduino: two LFOs from an MCP4822",
        summary: "An Arduino Uno computes a sine and a triangle, both at 2 Hz, and writes them to the two halves of an MCP4822 over SPI at 8 MHz: bit 15 of each word picks output A or B, and the chip's own 2.048 V reference sets the scale, so each swings between about 0.02 and 2 V. Control voltages for a synth, from one chip.",
        symbol: "waveform.path",
        circuit: drawn([
            part(.dcVoltage, "V1", ["voltage": 5], ["plus": "+5V", "minus": "GND"]),
            Examples.arduino(code: ArduinoSketches.mcp4822Code, firmware: ArduinoSketches.mcp4822Firmware,
                             connections: ["d10": "cs", "d13": "sck", "d11": "sdi"]),
            part(.dualDac, "U2", Examples.model(.dualDac, "MCP4822"),
                 ["cs": "cs", "sck": "sck", "sdi": "sdi", "ldac": "GND", "outA": "a", "outB": "b"]),
            r("RA", 10_000, "a", "GND"),
            r("RB", 10_000, "b", "GND"),
            part(.probe, "OUTA", [:], ["plus": "a", "minus": "GND"]),
            part(.probe, "OUTB", [:], ["plus": "b", "minus": "GND"]),
        ], scopes: [("OUTA", .voltage), ("OUTB", .voltage)]))

    /// An ADC read over SPI and a DAC written over I²C: the DAC follows the knob
    static let arduinoADCToDAC = Example(
        id: "arduino-mcp3008-mcp4725", title: "Arduino: SPI ADC to I²C DAC",
        summary: "An Arduino Uno reads the knob on CH0 of an MCP3008 over SPI (a start bit, then single-ended channel 0; the 10-bit code comes back in the next two bytes, the ADC answering bit by bit as the clock runs) and writes four times the code to an MCP4725 over I²C at 400 kHz (address 0x60; the DAC acknowledges each byte by holding SDA low). Both run on 5 V, so the DAC's output follows the knob. The readings go to the serial monitor. Turn the pot.",
        symbol: "arrow.left.arrow.right",
        circuit: drawn([
            part(.dcVoltage, "V1", ["voltage": 5], ["plus": "+5V", "minus": "GND"]),
            part(.potentiometer, "POT", ["resistance": 10_000, "position": 0.6], ["a": "GND", "b": "+5V", "wiper": "knob"]),
            Examples.arduino(code: ArduinoSketches.adcDacCode, firmware: ArduinoSketches.adcDacFirmware,
                             connections: ["d10": "cs", "d13": "sck", "d11": "mosi", "d12": "miso", "a4": "sda", "a5": "scl"]),
            part(.spiAdc, "U2", Examples.model(.spiAdc, "MCP3008"),
                 ["cs": "cs", "clk": "sck", "din": "mosi", "dout": "miso", "vref": "+5V", "ch0": "knob", "ch1": "GND", "ch2": "GND",
                  "ch3": "GND", "ch4": "GND", "ch5": "GND", "ch6": "GND", "ch7": "GND"]),
            r("RSDA", 4700, "+5V", "sda"),
            r("RSCL", 4700, "+5V", "scl"),
            part(.i2cDac, "U3", Examples.model(.i2cDac, "MCP4725"), ["scl": "scl", "sda": "sda", "a0": "GND", "out": "dac"]),
            r("RL", 10_000, "dac", "GND"),
            part(.probe, "DAC", [:], ["plus": "dac", "minus": "GND"]),
        ], scopes: [("POT", .voltage), ("DAC", .voltage)]))

    /// A sine from a Pico's PIO into a PCM5102 over I²S
    static let picoI2S = Example(
        id: "pico-pcm5102", title: "Pico: I²S audio DAC (sound)",
        summary: "A Raspberry Pi Pico plays a 440 Hz sine through a PCM5102 audio DAC. The I2S library's PIO program clocks the bits out (BCK on GP20, LRCK on GP21, data on GP22: a 32-bit frame, 16 bits each for left and right, about 21 900 frames a second) and the sketch keeps its FIFO full. The DAC reads each bit on BCK's rising edge, the word for each channel starting one BCK after LRCK changes, and puts it out at up to 2.1 V RMS about ground. Turn on sound.",
        symbol: "hifispeaker",
        circuit: drawn([
            Examples.pico(code: PicoSketches.i2sCode, firmware: PicoSketches.i2sFirmware,
                          connections: ["gp20": "bck", "gp21": "lrck", "gp22": "din"]),
            part(.i2sDac, "U2", Examples.model(.i2sDac, "PCM5102"), ["bck": "bck", "din": "din", "lrck": "lrck", "outL": "left", "outR": "right"]),
            r("RL", 10_000, "left", "GND"),
            r("RR", 10_000, "right", "GND"),
            part(.speaker, "SPK1", ["fullScale": 2], ["plus": "left", "minus": "GND"]),
            part(.probe, "RIGHT", [:], ["plus": "right", "minus": "GND"]),
        ], scopes: [("SPK1", .voltage)]))
}
