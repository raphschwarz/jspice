import Foundation

/// The FV-1 effects processor's eight ROM programs, with the chip's controls: the program its S0–S2 pins pick, and what
/// each of its three POT inputs (0 V to its supply) sets.
///
/// Spin's own code for them is not published, so these are rewritten: the same effects, built the usual way (a plate
/// reverb of the Dattorro kind, delay-line chorus and flanger, a two-tap pitch shifter). They run as the chip does, at
/// 32 768 samples a second (its usual 32.768 kHz crystal), on samples of the input taken then, through converters that
/// clip at ±1.5 V about the chip's bias; the outputs are held between samples and smoothed as by its output filter.
struct EffectsProcessor {
    static let sampleRate = 32_768.0
    /// The converters' full scale, either side of the bias
    static let fullScale = 1.5
    static let programs = [
        "Chorus-reverb: POT0 reverb mix, POT1 chorus rate, POT2 chorus mix",
        "Flange-reverb: POT0 reverb mix, POT1 flange rate, POT2 flange mix",
        "Tremolo-reverb: POT0 reverb mix, POT1 tremolo rate, POT2 tremolo depth",
        "Pitch shift: POT0 pitch (±4 semitones)",
        "Pitch-echo: POT0 pitch of each repeat, POT1 echo delay, POT2 echo mix",
        "Test (the input passes straight through)",
        "Reverb 1 (room): POT0 reverb time, POT1 brightness, POT2 low cut",
        "Reverb 2 (hall): POT0 reverb time, POT1 brightness, POT2 low cut",
    ]

    let program: Int
    /// The outputs over the next step
    private(set) var left = 0.0
    private(set) var right = 0.0
    private var heldLeft = 0.0
    private var heldRight = 0.0
    /// Samples due: the fraction of a sample period run since the last sample
    private var due = 0.0
    private var lastInput = 0.0
    /// The pots, smoothed (the chip filters them, so they do not step audibly)
    private var pots = (0.0, 0.0, 0.0)
    private var potsSet = false

    private var plate: Plate
    private var modulation = Delay(seconds: 0.03)
    private var shifter = PitchShifter()
    private var echo = Delay(seconds: 1.0)
    private var lfo = 0.0
    private var flangeFeedback = 0.0

    init(program: Int) {
        self.program = min(max(program, 0), 7)
        plate = Plate(size: self.program == 6 ? 0.55 : 1.0)
    }

    /// One step of `dt` seconds with the input and the pots' voltages (each over `supply`) at its end
    mutating func step(input: Double, pot0: Double, pot1: Double, pot2: Double, supply: Double, dt: Double) {
        func level(_ v: Double) -> Double { min(max(v / max(supply, 0.1), 0), 1) }
        let targets = (level(pot0), level(pot1), level(pot2))
        if !potsSet {
            pots = targets
            potsSet = true
        }
        let x = min(max(input, -Self.fullScale), Self.fullScale)
        let period = 1 / Self.sampleRate
        due += dt / period
        let samples = Int(due.rounded(.down))
        if samples > 0 {
            due -= Double(samples)
            let smoothing = 1 - exp(-period / 0.01)
            for k in 0..<min(samples, 4096) {
                pots.0 += (targets.0 - pots.0) * smoothing
                pots.1 += (targets.1 - pots.1) * smoothing
                pots.2 += (targets.2 - pots.2) * smoothing
                // the input as it was when this sample was taken, between the last step's and this one's
                let t = Double(k + 1) / Double(samples)
                let sample = lastInput + (x - lastInput) * t
                let (l, r) = run(sample / Self.fullScale)
                heldLeft = min(max(l, -1), 1) * Self.fullScale
                heldRight = min(max(r, -1), 1) * Self.fullScale
            }
        }
        lastInput = x
        // the output filter: a pole at 12 kHz
        let g = 1 - exp(-2 * .pi * 12_000 * dt)
        left += (heldLeft - left) * g
        right += (heldRight - right) * g
    }

    /// One sample through the program, the input and outputs in full scales
    private mutating func run(_ x: Double) -> (Double, Double) {
        let (p0, p1, p2) = pots
        let fs = Self.sampleRate
        switch program {
        case 0:
            // chorus: a 12 ms delay swept ±5 ms by a sine, the right side's the other way; a medium reverb behind
            lfo = (lfo + 0.1 * pow(50, p1) / fs).truncatingRemainder(dividingBy: 1)
            modulation.write(x)
            let sweep = sin(2 * .pi * lfo)
            let wetL = modulation.read(seconds: 0.012 + 0.005 * sweep)
            let wetR = modulation.read(seconds: 0.012 - 0.005 * sweep)
            let (revL, revR) = plate.process(x, decay: 0.5, damping: 0.45, lowCut: 0.1)
            return (x * (1 - p2 / 2) + wetL * p2 / 2 + p0 * revL, x * (1 - p2 / 2) + wetR * p2 / 2 + p0 * revR)
        case 1:
            // flanger: 0.3 to 4 ms swept by a triangle, with feedback
            lfo = (lfo + 0.05 * pow(40, p1) / fs).truncatingRemainder(dividingBy: 1)
            let triangle = 1 - 2 * abs(2 * lfo - 1)
            modulation.write(x + 0.6 * flangeFeedback)
            let wet = modulation.read(seconds: 0.00215 + 0.00185 * triangle)
            flangeFeedback = wet
            let (revL, revR) = plate.process(x, decay: 0.5, damping: 0.45, lowCut: 0.1)
            let mixed = x * (1 - p2 / 2) + wet * p2 / 2
            return (mixed + p0 * revL, mixed + p0 * revR)
        case 2:
            // tremolo: the level swung by a sine from full to (1 − depth)
            lfo = (lfo + pow(15, p1) / fs).truncatingRemainder(dividingBy: 1)
            let gain = 1 - p2 * (0.5 - 0.5 * cos(2 * .pi * lfo))
            let (revL, revR) = plate.process(x, decay: 0.5, damping: 0.45, lowCut: 0.1)
            return (x * gain + p0 * revL, x * gain + p0 * revR)
        case 3:
            let shifted = shifter.process(x, semitones: 8 * p0 - 4)
            return (shifted, shifted)
        case 4:
            // each repeat shifted again: the echoes climb (or fall) in pitch
            let delay = 0.05 + 0.95 * p1
            let echoed = echo.read(seconds: delay)
            echo.write(x + 0.5 * shifter.process(echoed, semitones: 8 * p0 - 4))
            return (x + p2 * echoed, x + p2 * echoed)
        case 5:
            return (x, x)
        default:
            // reverb alone, for mixing with the dry signal outside
            return plate.process(x, decay: 0.25 + 0.55 * p0, damping: 0.85 * (1 - p1), lowCut: 0.02 + 0.4 * p2)
        }
    }
}

/// A delay line of samples at the processor's rate, read between samples by linear interpolation
private struct Delay {
    private var buffer: [Double]
    private var index = 0

    init(samples: Int) { buffer = Array(repeating: 0, count: max(samples, 2)) }
    init(seconds: Double) { self.init(samples: Int(seconds * EffectsProcessor.sampleRate) + 4) }

    mutating func write(_ x: Double) {
        index = index + 1 == buffer.count ? 0 : index + 1
        buffer[index] = x
    }

    /// The sample written `n` samples ago (0: the last)
    func read(_ n: Int) -> Double {
        var k = index - min(max(n, 0), buffer.count - 1)
        if k < 0 { k += buffer.count }
        return buffer[k]
    }

    func read(samples d: Double) -> Double {
        let d = min(max(d, 0), Double(buffer.count - 2))
        let whole = Int(d)
        let fraction = d - Double(whole)
        return read(whole) * (1 - fraction) + read(whole + 1) * fraction
    }

    func read(seconds: Double) -> Double { read(samples: seconds * EffectsProcessor.sampleRate) }
}

/// An all-pass filter around a delay of `length` samples (a Schroeder diffuser), its delay optionally swept
private struct AllPass {
    private var line: Delay
    let length: Double

    init(_ length: Double) {
        self.length = max(length, 1)
        line = Delay(samples: Int(length) + 24)
    }

    mutating func process(_ x: Double, gain g: Double, excursion: Double = 0) -> Double {
        let delayed = line.read(samples: length - 1 + excursion)
        let v = x + g * delayed
        line.write(v)
        return delayed - g * v
    }

    func tap(_ n: Double) -> Double { line.read(samples: n) }
}

/// A plate reverb after Dattorro ("Effect Design, Part 1", 1997): four input diffusers, then a figure-eight tank of two
/// branches, each a swept all-pass, a delay, damping, a second all-pass and a second delay, feeding the other; the
/// outputs taken from seven points along the tank. `size` scales its delays (1 the hall, smaller a room).
private struct Plate {
    private var bandwidth = 0.0
    private var diffusers: [AllPass]
    private var sweptA: AllPass, sweptB: AllPass
    private var delayA1: Delay, delayB1: Delay
    private var diffuseA: AllPass, diffuseB: AllPass
    private var delayA2: Delay, delayB2: Delay
    private var dampA = 0.0, dampB = 0.0
    private var lowA = 0.0, lowB = 0.0
    private var lastA = 0.0, lastB = 0.0
    private var phase = 0.0
    private let scale: Double
    private let lengths: (a1: Double, b1: Double, a2: Double, b2: Double)

    init(size: Double) {
        // Dattorro's delays are given at 29 761 Hz
        let s = size * EffectsProcessor.sampleRate / 29_761
        scale = s
        diffusers = [142, 107, 379, 277].map { AllPass($0 * s) }
        sweptA = AllPass(672 * s)
        sweptB = AllPass(908 * s)
        lengths = (4453 * s, 4217 * s, 3720 * s, 3163 * s)
        delayA1 = Delay(samples: Int(lengths.a1) + 4)
        delayB1 = Delay(samples: Int(lengths.b1) + 4)
        diffuseA = AllPass(1800 * s)
        diffuseB = AllPass(2656 * s)
        delayA2 = Delay(samples: Int(lengths.a2) + 4)
        delayB2 = Delay(samples: Int(lengths.b2) + 4)
    }

    /// One sample: `decay` the tank's gain per pass, `damping` how much of each pass's highs are lost (0 none),
    /// `lowCut` how much of its lows (0 none)
    mutating func process(_ x: Double, decay: Double, damping: Double, lowCut: Double) -> (Double, Double) {
        bandwidth += (x - bandwidth) * 0.9995
        var d = diffusers[0].process(bandwidth, gain: 0.75)
        d = diffusers[1].process(d, gain: 0.75)
        d = diffusers[2].process(d, gain: 0.625)
        d = diffusers[3].process(d, gain: 0.625)
        // the swept all-passes' delays move ±8 samples (at 29 761 Hz) at about 1 Hz
        phase = (phase + 1 / EffectsProcessor.sampleRate).truncatingRemainder(dividingBy: 1)
        let excursion = 8 * scale * sin(2 * .pi * phase)
        let diffusion2 = min(max(decay + 0.15, 0.25), 0.5)
        func branch(_ input: Double, _ swept: inout AllPass, _ delay1: inout Delay, _ length1: Double, _ damp: inout Double,
                    _ low: inout Double, _ diffuse: inout AllPass, _ delay2: inout Delay, _ length2: Double, sweep: Double) -> Double {
            var a = swept.process(input, gain: -0.7, excursion: sweep)
            delay1.write(a)
            a = delay1.read(samples: length1 - 1)
            damp += (a - damp) * (1 - damping)
            low += (damp - low) * lowCut * 0.05
            a = (damp - low) * decay
            a = diffuse.process(a, gain: diffusion2)
            delay2.write(a)
            return delay2.read(samples: length2 - 1) * decay
        }
        let newA = branch(d + lastB, &sweptA, &delayA1, lengths.a1, &dampA, &lowA, &diffuseA, &delayA2, lengths.a2, sweep: excursion)
        let newB = branch(d + lastA, &sweptB, &delayB1, lengths.b1, &dampB, &lowB, &diffuseB, &delayB2, lengths.b2, sweep: -excursion)
        (lastA, lastB) = (newA, newB)
        let s = scale
        let left = delayB1.read(samples: 266 * s) + delayB1.read(samples: 2974 * s) - diffuseB.tap(1913 * s)
            + delayB2.read(samples: 1996 * s) - delayA1.read(samples: 1990 * s) - diffuseA.tap(187 * s) - delayA2.read(samples: 1066 * s)
        let right = delayA1.read(samples: 353 * s) + delayA1.read(samples: 3627 * s) - diffuseA.tap(1228 * s)
            + delayA2.read(samples: 2673 * s) - delayB1.read(samples: 2111 * s) - diffuseB.tap(335 * s) - delayB2.read(samples: 121 * s)
        return (0.6 * left, 0.6 * right)
    }
}

/// A pitch shifter of two taps sliding along a 50 ms delay at the rate that shifts the pitch, each faded out as it
/// wraps round while the other, half a window apart, is heard
private struct PitchShifter {
    private var line = Delay(seconds: 0.06)
    private var phase = 0.0
    private static let window = 0.05 * EffectsProcessor.sampleRate

    mutating func process(_ x: Double, semitones: Double) -> Double {
        line.write(x)
        let ratio = pow(2, semitones / 12)
        // the delay shrinks by (ratio − 1) samples each sample to play faster, grows to play slower
        phase -= (ratio - 1) / Self.window
        phase -= phase.rounded(.down)
        let second = (phase + 0.5).truncatingRemainder(dividingBy: 1)
        let w1 = pow(sin(.pi * phase), 2)
        let w2 = pow(sin(.pi * second), 2)
        return w1 * line.read(samples: 2 + phase * Self.window) + w2 * line.read(samples: 2 + second * Self.window)
    }
}
