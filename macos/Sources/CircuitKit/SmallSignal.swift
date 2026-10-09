import Foundation

/// A complex number, for small-signal analysis: a sinusoid's amplitude and phase
public struct Complex: Equatable, Sendable {
    public var re: Double
    public var im: Double

    public init(_ re: Double, _ im: Double = 0) {
        self.re = re
        self.im = im
    }

    public var magnitude: Double { hypot(re, im) }
    /// In radians, from −π to π
    public var phase: Double { atan2(im, re) }

    public static func + (a: Complex, b: Complex) -> Complex { Complex(a.re + b.re, a.im + b.im) }
    public static func - (a: Complex, b: Complex) -> Complex { Complex(a.re - b.re, a.im - b.im) }
    public static func * (a: Complex, b: Complex) -> Complex { Complex(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re) }
    public static func * (a: Double, b: Complex) -> Complex { Complex(a * b.re, a * b.im) }
    public static func / (a: Complex, b: Complex) -> Complex {
        let d = b.re * b.re + b.im * b.im
        return Complex((a.re * b.re + a.im * b.im) / d, (a.im * b.re - a.re * b.im) / d)
    }
}

/// The circuit linearised around one operating point: how small changes in its voltages and currents relate, at any
/// frequency. Its matrix is Newton-Raphson's at that point (the slopes of the diodes, transistors, op-amps and chips
/// there), less the capacitors and inductors, whose admittances jωC and 1 / jωL depend on the frequency, and less the
/// parts with dynamics of their own (an op-amp's internal pole, a filter chip's stages, a delay line's delay), which are
/// entries that are worked out for each frequency.
///
/// A sweep drives one source with a 1 V (or 1 A) sinusoid, all other sources held still, and solves for the
/// amplitude and phase of every node voltage.
public struct SmallSignalModel: Equatable, Sendable {
    /// Unknowns: node voltages 1..<nodeCount, then source and output currents
    public let size: Int
    public let nodeCount: Int
    /// The part of the matrix that does not depend on the frequency, row by row
    var matrix: [Double]
    var entries: [Entry]
    /// What driving each source means: a 1 V source sets its row, a 1 A source injects into its nodes
    var drives: [Int: Drive]
    /// Each voltage source's nodes (a loop probe's in is its minus, its out its plus)
    var terminals: [Int: Terminals] = [:]

    enum Drive: Equatable, Sendable {
        case row(Int)
        case current(from: Int, to: Int)
    }

    struct Terminals: Equatable, Sendable {
        var minus: Int
        var plus: Int
    }

    /// `scale` times the transfer at the frequency, added to the matrix at (row, column)
    struct Entry: Equatable, Sendable {
        var row: Int
        var column: Int
        var scale: Double
        var transfer: Transfer
    }

    enum Transfer: Equatable, Sendable {
        /// jωC: a capacitor's admittance
        case capacitance(Double)
        /// 1 / jωL: an inductor's
        case inductance(Double)
        /// gain / (jω + rate): an integrator that leaks at `rate` (an op-amp's internal stage)
        case pole(gain: Double, rate: Double)
        /// gain e^(−jωT), through `poles` one-pole low-passes at `cutoff` rad/s (a delay line)
        case delay(gain: Double, time: Double, cutoff: Double, poles: Int)
        /// A ladder of one-pole stages with feedback from the last to the input (a four-pole filter chip): the stages
        /// together are T = numerator / Π (jω + pole), and the whole is drive T / (1 + drive feedback T)
        case ladder(numerator: Double, poles: [Double], drive: Double, feedback: Double)
        /// The same at every frequency
        case constant(Double)

        func value(at omega: Double) -> Complex {
            let s = Complex(0, omega)
            switch self {
            case .capacitance(let c):
                return Complex(0, omega * c)
            case .inductance(let l):
                return Complex(0, -1 / (omega * l))
            case .pole(let gain, let rate):
                return Complex(gain) / (s + Complex(rate))
            case .delay(let gain, let time, let cutoff, let poles):
                var h = gain * Complex(cos(omega * time), -sin(omega * time))
                if cutoff > 0 {
                    for _ in 0..<poles { h = h * (Complex(cutoff) / (s + Complex(cutoff))) }
                }
                return h
            case .ladder(let numerator, let poles, let drive, let feedback):
                var t = Complex(numerator)
                for p in poles { t = t / (s + Complex(p)) }
                return (drive * t) / (Complex(1) + (drive * feedback) * t)
            case .constant(let value):
                return Complex(value)
            }
        }
    }

    init(size: Int, nodeCount: Int, matrix: [Double], entries: [Entry], drives: [Int: Drive], terminals: [Int: Terminals] = [:]) {
        self.size = size
        self.nodeCount = nodeCount
        self.matrix = matrix
        self.entries = entries
        self.drives = drives
        self.terminals = terminals
    }

    /// Whether the element at `index` is a source a sweep can drive
    public func canDrive(from index: Int) -> Bool { drives[index] != nil }

    /// The amplitude and phase of every node voltage (index 0 is ground) at each frequency in Hz, for the source at
    /// `input` driven with 1 V or 1 A; nil if it is not a source, or the equations cannot be solved
    public func solve(input: Int, frequencies: [Double]) -> [[Complex]]? {
        guard let drive = drives[input] else { return nil }
        return solutions(frequencies: frequencies) { b in
            switch drive {
            case .row(let row):
                b[row] = 1
            case .current(let a, let b0):
                if a > 0 { b[a - 1] -= 1 }
                if b0 > 0 { b[b0 - 1] += 1 }
            }
        }?.map { x in [Complex(0)] + x.prefix(max(0, nodeCount - 1)) }
    }

    /// Every unknown (node voltages from node 1, then the sources' and outputs' currents) at each frequency in Hz, for
    /// the right-hand side `excite` sets (the real parts; zero elsewhere); nil if the equations cannot be solved
    func solutions(frequencies: [Double], _ excite: (inout [Double]) -> Void) -> [[Complex]]? {
        guard size > 0 else { return nil }
        let m = size
        var re = [Double](repeating: 0, count: m * m)
        var im = [Double](repeating: 0, count: m * m)
        var bre = [Double](repeating: 0, count: m)
        var bim = [Double](repeating: 0, count: m)
        var results: [[Complex]] = []
        results.reserveCapacity(frequencies.count)
        for frequency in frequencies {
            guard frequency > 0, frequency.isFinite else { return nil }
            let omega = 2 * Double.pi * frequency
            for k in 0..<(m * m) {
                re[k] = matrix[k]
                im[k] = 0
            }
            for entry in entries {
                let value = entry.transfer.value(at: omega)
                re[entry.row * m + entry.column] += entry.scale * value.re
                im[entry.row * m + entry.column] += entry.scale * value.im
            }
            for k in 0..<m {
                bre[k] = 0
                bim[k] = 0
            }
            excite(&bre)
            guard Self.solveInPlace(&re, &im, &bre, &bim, size: m) else { return nil }
            results.append((0..<m).map { Complex(bre[$0], bim[$0]) })
        }
        return results
    }

    /// Whether the element at `index` can be a loop's break point: a voltage source with a row (a loop probe)
    public func canBreakLoop(at index: Int) -> Bool {
        guard case .row = drives[index] else { return false }
        return terminals[index] != nil
    }

    /// The loop gain T (the return ratio) of the feedback loop through the loop probe (or 0 V source) at `probe`, at
    /// each frequency in Hz, by Middlebrook's double injection: a voltage injected in series at the break gives
    /// Tv = −v(in) / v(out), a current injected into it gives Ti = i_in / i_out (the currents into the two sides), and
    /// T = (Tv Ti − 1) / (Tv + Ti + 2), exact for a loop with loading on both sides of the break. The probe's in must face
    /// the side that drives the loop (an op-amp's output), its out the side driven (the feedback network). Negative
    /// feedback has T positive at low frequencies; the closed loop's response is the forward gain over 1 + T.
    public func loopGain(probe: Int, frequencies: [Double]) -> [Complex]? {
        // (both sides of the break are nodes of their own: a loop does not run through ground)
        guard case .row(let row)? = drives[probe], let t = terminals[probe], t.minus != t.plus, t.minus > 0, t.plus > 0,
              t.minus < nodeCount, t.plus < nodeCount else { return nil }
        func node(_ x: [Complex], _ n: Int) -> Complex { x[n - 1] }
        // voltage injection: v(out) − v(in) = 1
        guard let voltage = solutions(frequencies: frequencies, { $0[row] = 1 }),
              // current injection: 1 A into out, the probe at 0 V; its row holds the current it delivers into out (and so
              // takes from in)
              let current = solutions(frequencies: frequencies, { $0[t.plus - 1] += 1 }) else { return nil }
        var result: [Complex] = []
        result.reserveCapacity(frequencies.count)
        for k in frequencies.indices {
            let tv = Complex(0) - node(voltage[k], t.minus) / node(voltage[k], t.plus)
            let delivered = current[k][row]
            let into = Complex(0) - delivered                 // into the driving side, from the break
            let out = Complex(1) + delivered                  // into the driven side
            // T = (Tv Ti − 1) / (Tv + Ti + 2) with Ti = into / out, multiplied through by out (zero for an ideal driver)
            result.append((tv * into - out) / (tv * out + into + 2 * out))
        }
        return result
    }

    /// The impedance between nodes `plus` and `minus` at each frequency in Hz, the sources at rest (voltage sources
    /// shorted, current sources open): the voltage a 1 A current into `plus` and out of `minus` sets across them
    public func impedance(plus: Int, minus: Int, frequencies: [Double]) -> [Complex]? {
        guard plus != minus, plus < nodeCount, minus < nodeCount else { return nil }
        guard let x = solutions(frequencies: frequencies, { b in
            if plus > 0 { b[plus - 1] += 1 }
            if minus > 0 { b[minus - 1] -= 1 }
        }) else { return nil }
        return x.map { v in (plus > 0 ? v[plus - 1] : Complex(0)) - (minus > 0 ? v[minus - 1] : Complex(0)) }
    }

    /// The impedance the source at `input` sees, looking into the circuit from its terminals, at each frequency in Hz
    /// (a circuit's input impedance): its voltage over the current it delivers, the other sources at rest
    public func loadImpedance(input: Int, frequencies: [Double]) -> [Complex]? {
        switch drives[input] {
        case .row(let row)?:
            guard let x = solutions(frequencies: frequencies, { $0[row] = 1 }) else { return nil }
            return x.map { Complex(1) / $0[row] }
        case .current(let from, let to)?:
            return impedance(plus: to, minus: from, frequencies: frequencies)
        case nil:
            return nil
        }
    }

    /// One source of noise in the circuit: a current between two nodes (a resistor's thermal noise, a junction's shot
    /// noise), or a voltage in series with an op-amp's input, which reaches its output row through `transfer`
    public struct NoiseSource: Sendable {
        /// The part it comes from, and what in it ("R1", "Q1 collector")
        public var element: Int
        public var label: String
        /// Its power spectral density: A²/Hz for a current, V²/Hz for a voltage
        public var density: Double
        var injection: Injection

        enum Injection: Sendable {
            case current(from: Int, to: Int)
            case row(Int, Transfer)
        }

        init(element: Int, label: String, density: Double, injection: Injection) {
            self.element = element
            self.label = label
            self.density = density
            self.injection = injection
        }
    }

    /// The noise at an output, frequency by frequency, and each source's share of it over the band
    public struct NoiseResult: Sendable {
        public var frequencies: [Double]
        /// Spectral density at the output, V/√Hz
        public var output: [Double]
        /// The same referred to the input source: the output's divided by the gain from it (V/√Hz for a voltage
        /// source); nil without an input, or where the gain is nil
        public var input: [Double]?
        /// RMS noise at the output over the frequencies (trapezoids in frequency), V
        public var total: Double
        /// Each source's RMS share of `total` (their squares add up to its square), loudest first
        public var contributions: [(label: String, element: Int, rms: Double)]
    }

    /// The noise at V(plus) − V(minus) from `sources`, at each frequency (Hz), and referred to the source at `input`.
    /// One solve of the transposed equations per frequency gives how every node's current reaches the output.
    public func noise(plus: Int, minus: Int, input: Int?, sources: [NoiseSource], frequencies: [Double]) -> NoiseResult? {
        guard size > 0 else { return nil }
        let m = size
        var re = [Double](repeating: 0, count: m * m)
        var im = [Double](repeating: 0, count: m * m)
        var bre = [Double](repeating: 0, count: m)
        var bim = [Double](repeating: 0, count: m)
        var output: [Double] = []
        var referred: [Double] = []
        var shares = [[Double]](repeating: [], count: sources.count)
        func z(_ node: Int) -> Complex { node > 0 && node <= m ? Complex(bre[node - 1], bim[node - 1]) : Complex(0) }
        for frequency in frequencies {
            guard frequency > 0, frequency.isFinite else { return nil }
            let omega = 2 * Double.pi * frequency
            // the matrix, transposed
            for r in 0..<m {
                for c in 0..<m {
                    re[c * m + r] = matrix[r * m + c]
                    im[c * m + r] = 0
                }
            }
            for entry in entries {
                let value = entry.transfer.value(at: omega)
                re[entry.column * m + entry.row] += entry.scale * value.re
                im[entry.column * m + entry.row] += entry.scale * value.im
            }
            for k in 0..<m {
                bre[k] = 0
                bim[k] = 0
            }
            if plus > 0 { bre[plus - 1] += 1 }
            if minus > 0 { bre[minus - 1] -= 1 }
            guard Self.solveInPlace(&re, &im, &bre, &bim, size: m) else { return nil }
            var power = 0.0
            for (k, source) in sources.enumerated() {
                let gain: Complex
                switch source.injection {
                case .current(let a, let b):
                    gain = z(b) - z(a)
                case .row(let row, let transfer):
                    gain = row < m ? Complex(bre[row], bim[row]) * transfer.value(at: omega) : Complex(0)
                }
                let share = gain.magnitude * gain.magnitude * source.density
                shares[k].append(share)
                power += share
            }
            output.append(power.squareRoot())
            if let input, let drive = drives[input] {
                let gain: Complex
                switch drive {
                case .row(let row): gain = Complex(bre[row], bim[row])
                case .current(let a, let b): gain = z(b) - z(a)
                }
                referred.append(gain.magnitude > 0 ? power.squareRoot() / gain.magnitude : .infinity)
            }
        }
        /// ∫ density² df by trapezoids
        func integrate(_ values: [Double]) -> Double {
            var sum = 0.0
            for k in 1..<max(1, frequencies.count) {
                sum += (values[k] + values[k - 1]) / 2 * (frequencies[k] - frequencies[k - 1])
            }
            return sum
        }
        var contributions = sources.enumerated().map { k, source in
            (label: source.label, element: source.element, rms: integrate(shares[k]).squareRoot())
        }
        contributions.sort { $0.rms > $1.rms }
        return NoiseResult(frequencies: frequencies, output: output, input: input != nil && referred.count == frequencies.count ? referred : nil,
                           total: integrate(output.map { $0 * $0 }).squareRoot(), contributions: contributions)
    }

    /// The response V(plus) − V(minus) to the source at `input` at each frequency in Hz
    public func response(input: Int, plus: Int, minus: Int, frequencies: [Double]) -> [Complex]? {
        guard let solution = solve(input: input, frequencies: frequencies) else { return nil }
        return solution.map { v in
            (plus > 0 && plus < v.count ? v[plus] : Complex(0)) - (minus > 0 && minus < v.count ? v[minus] : Complex(0))
        }
    }

    /// Gaussian elimination with partial pivoting on a dense complex matrix (real and imaginary parts apart), skipping
    /// the zeros that most of a circuit's matrix is
    static func solveInPlace(_ re: inout [Double], _ im: inout [Double], _ bre: inout [Double], _ bim: inout [Double],
                             size m: Int) -> Bool {
        var columns: [Int] = []
        columns.reserveCapacity(m)
        for k in 0..<m {
            var pivot = k
            var largest = 0.0
            for r in k..<m {
                let magnitude = abs(re[r * m + k]) + abs(im[r * m + k])
                if magnitude > largest {
                    largest = magnitude
                    pivot = r
                }
            }
            guard largest > 1e-300, largest.isFinite else { return false }
            if pivot != k {
                for c in 0..<m {
                    re.swapAt(k * m + c, pivot * m + c)
                    im.swapAt(k * m + c, pivot * m + c)
                }
                bre.swapAt(k, pivot)
                bim.swapAt(k, pivot)
            }
            // the pivot row's non-zero entries right of the diagonal
            columns.removeAll(keepingCapacity: true)
            for c in (k + 1)..<max(k + 1, m) where re[k * m + c] != 0 || im[k * m + c] != 0 { columns.append(c) }
            let pr = re[k * m + k], pi = im[k * m + k]
            let d = pr * pr + pi * pi
            for r in (k + 1)..<max(k + 1, m) {
                let ar = re[r * m + k], ai = im[r * m + k]
                guard ar != 0 || ai != 0 else { continue }
                // factor = a / pivot
                let fr = (ar * pr + ai * pi) / d
                let fi = (ai * pr - ar * pi) / d
                re[r * m + k] = 0
                im[r * m + k] = 0
                for c in columns {
                    let xr = re[k * m + c], xi = im[k * m + c]
                    re[r * m + c] -= fr * xr - fi * xi
                    im[r * m + c] -= fr * xi + fi * xr
                }
                let xr = bre[k], xi = bim[k]
                bre[r] -= fr * xr - fi * xi
                bim[r] -= fr * xi + fi * xr
            }
        }
        for k in stride(from: m - 1, through: 0, by: -1) {
            var sr = bre[k], si = bim[k]
            for c in (k + 1)..<max(k + 1, m) {
                let ar = re[k * m + c], ai = im[k * m + c]
                guard ar != 0 || ai != 0 else { continue }
                sr -= ar * bre[c] - ai * bim[c]
                si -= ar * bim[c] + ai * bre[c]
            }
            let pr = re[k * m + k], pi = im[k * m + k]
            let d = pr * pr + pi * pi
            bre[k] = (sr * pr + si * pi) / d
            bim[k] = (si * pr - sr * pi) / d
            guard bre[k].isFinite && bim[k].isFinite else { return false }
        }
        return true
    }
}

/// A frequency sweep's points: frequencies spaced evenly on a log scale
public enum FrequencySweep {
    public static func logarithmic(from start: Double, to stop: Double, pointsPerDecade: Int) -> [Double] {
        guard start > 0, stop > start, pointsPerDecade > 0 else { return [] }
        let count = Int((log10(stop / start) * Double(pointsPerDecade)).rounded()) + 1
        return (0..<count).map { start * pow(10, Double($0) / Double(pointsPerDecade)) }
    }

    /// Phases in degrees, unwrapped so that they run on continuously from one frequency to the next (a third-order
    /// roll-off reads −270°, not +90°)
    public static func unwrappedPhases(_ values: [Complex]) -> [Double] {
        var result: [Double] = []
        result.reserveCapacity(values.count)
        for value in values {
            var phase = value.phase * 180 / .pi
            if let previous = result.last {
                while phase - previous > 180 { phase -= 360 }
                while phase - previous < -180 { phase += 360 }
            }
            result.append(phase)
        }
        return result
    }
}

/// A feedback loop's stability, read from its loop gain T over a sweep: where |T| crosses 1 (crossover) and how far T's
/// phase is from −180° there (the phase margin), and where T's phase crosses −180° and how far |T| is below 1 there (the
/// gain margin). A loop with 45° or more and 6 dB or more settles without much ringing.
public struct StabilityMargins: Sendable {
    public struct Crossing: Sendable {
        public var frequency: Double
        /// Degrees for a unity-gain crossing, dB for a phase crossing
        public var margin: Double
    }

    /// Each frequency where |T| crosses 1, with the phase margin there: how much more phase lag (where |T| falls through
    /// 1, as at the top of a loop's band) or lead (where it rises through 1, below an AC-coupled loop's band) would take
    /// T to −1, from −180° to 180° (negative: the loop is unstable)
    public var unityCrossings: [Crossing] = []
    /// Each frequency where T's phase crosses −180° (or −540°…), with the gain margin there (dB below unity; negative if
    /// above)
    public var phaseCrossings: [Crossing] = []

    /// The smallest phase margin over the unity-gain crossings; nil if |T| never crosses 1 in the sweep
    public var phaseMargin: Double? { unityCrossings.map(\.margin).min() }
    /// The highest unity-gain crossing: the loop's bandwidth
    public var crossover: Double? { unityCrossings.last?.frequency }
    /// The gain margin at the phase crossing nearest crossover (above it for a stable loop, below it for one with too
    /// much gain), or at the first if |T| never crosses 1
    public var gainMargin: Double? {
        guard let crossover else { return phaseCrossings.first?.margin }
        return phaseCrossings.min { abs(log($0.frequency / crossover)) < abs(log($1.frequency / crossover)) }?.margin
    }

    public init(frequencies: [Double], loopGain: [Complex]) {
        let n = min(frequencies.count, loopGain.count)
        guard n >= 2 else { return }
        let db = loopGain.prefix(n).map { 20 * log10(max($0.magnitude, 1e-300)) }
        let phases = FrequencySweep.unwrappedPhases(Array(loopGain.prefix(n)))
        func at(_ k: Int, _ fraction: Double) -> Double {
            frequencies[k - 1] * pow(frequencies[k] / frequencies[k - 1], fraction)
        }
        for k in 1..<n {
            let (a, b) = (db[k - 1], db[k])
            if (a >= 0) != (b >= 0), a != b {
                let fraction = a / (a - b)
                let phase = phases[k - 1] + fraction * (phases[k] - phases[k - 1])
                var margin = b < a ? 180 + phase : 180 - phase
                margin -= 360 * ((margin + 180) / 360).rounded(.down)
                unityCrossings.append(Crossing(frequency: at(k, fraction), margin: margin))
            }
            // the phase plus 180° crossing a multiple of 360°
            let (p, q) = (phases[k - 1] + 180, phases[k] + 180)
            let (lo, hi) = ((p / 360).rounded(.down), (q / 360).rounded(.down))
            if lo != hi, p != q {
                let target = 360 * max(lo, hi)
                let fraction = (target - p) / (q - p)
                phaseCrossings.append(Crossing(frequency: at(k, fraction), margin: -(a + fraction * (b - a))))
            }
        }
    }
}

extension Simulator {
    /// The circuit with the source at `holding` held still, for finding the operating point a sweep linearises around:
    /// an AC source at its offset, a square wave at its low level, noise silent
    public static func quiet(_ circuit: Circuit, holding source: Int?) -> Circuit {
        var quiet = circuit
        guard let source, source < quiet.elements.count else { return quiet }
        switch quiet.elements[source].kind {
        case .acVoltage, .noiseVoltage:
            quiet.elements[source][param: "amplitude"] = 0
        case .audioInput, .microphone, .electretMic, .pickup:
            quiet.elements[source][param: "level"] = 0
        case .balancedCable:
            quiet.elements[source][param: "hum"] = 0
        case .squareVoltage:
            quiet.elements[source][param: "high"] = quiet.elements[source][param: "low"]
        default:
            break
        }
        return quiet
    }

    /// How long the circuit takes to settle from rest (five of its slowest time constants, its sources' own periods
    /// left out) and a time step to settle it with
    public static func settling(_ circuit: Circuit) -> (duration: Double, timeStep: Double) {
        var still = circuit
        still.elements.removeAll { [.acVoltage, .squareVoltage, .noiseVoltage, .audioInput].contains($0.kind) }
        return (5 * (Pacing.slowestTimeScale(of: still) ?? 0), Pacing.suggest(for: still).timeStep)
    }

    /// A simulator that has run the circuit from rest until it settles, for small-signal analysis around where it comes
    /// to rest: the source at `holding` (the one a sweep will drive) is held still (see `quiet`). The run lasts
    /// `duration`, by default five times the circuit's slowest time constant, in at most `maxSteps` steps; given up on
    /// (the simulation failed) once it has taken `budget` seconds.
    public static func settled(_ circuit: Circuit, holding source: Int?, duration: Double? = nil,
                               maxSteps: Int = 1_000_000, budget: TimeInterval? = nil) -> Simulator {
        let held = Self.quiet(circuit, holding: source)
        let estimate = Self.settling(held)
        let length = max(duration ?? estimate.duration, 0)
        var timeStep = estimate.timeStep
        if length / timeStep > Double(maxSteps) { timeStep = length / Double(maxSteps) }
        let simulator = Simulator(circuit: held, timeStep: timeStep)
        let steps = max(10, Int((length / timeStep).rounded(.up)))
        let started = Date()
        for _ in 0..<steps where !simulator.isFailed {
            if let budget, Date().timeIntervalSince(started) > budget { simulator.stopRequested = true }
            simulator.step()
        }
        return simulator
    }
}
