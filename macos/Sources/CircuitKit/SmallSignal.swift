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

    enum Drive: Equatable, Sendable {
        case row(Int)
        case current(from: Int, to: Int)
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
            }
        }
    }

    init(size: Int, nodeCount: Int, matrix: [Double], entries: [Entry], drives: [Int: Drive]) {
        self.size = size
        self.nodeCount = nodeCount
        self.matrix = matrix
        self.entries = entries
        self.drives = drives
    }

    /// Whether the element at `index` is a source a sweep can drive
    public func canDrive(from index: Int) -> Bool { drives[index] != nil }

    /// The amplitude and phase of every node voltage (index 0 is ground) at each frequency in Hz, for the source at
    /// `input` driven with 1 V or 1 A; nil if it is not a source, or the equations cannot be solved
    public func solve(input: Int, frequencies: [Double]) -> [[Complex]]? {
        guard let drive = drives[input], size > 0 else { return nil }
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
            switch drive {
            case .row(let row):
                bre[row] = 1
            case .current(let a, let b):
                if a > 0 { bre[a - 1] -= 1 }
                if b > 0 { bre[b - 1] += 1 }
            }
            guard Self.solveInPlace(&re, &im, &bre, &bim, size: m) else { return nil }
            var voltages = [Complex(0)]
            voltages.reserveCapacity(nodeCount)
            for node in 1..<max(1, nodeCount) { voltages.append(Complex(bre[node - 1], bim[node - 1])) }
            results.append(voltages)
        }
        return results
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

extension Simulator {
    /// The circuit with the source at `holding` held still, for finding the operating point a sweep linearises around:
    /// an AC source at its offset, a square wave at its low level, noise silent
    public static func quiet(_ circuit: Circuit, holding source: Int?) -> Circuit {
        var quiet = circuit
        guard let source, source < quiet.elements.count else { return quiet }
        switch quiet.elements[source].kind {
        case .acVoltage, .noiseVoltage:
            quiet.elements[source][param: "amplitude"] = 0
        case .audioInput:
            quiet.elements[source][param: "level"] = 0
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
    /// `duration`, by default five times the circuit's slowest time constant, in at most `maxSteps` steps.
    public static func settled(_ circuit: Circuit, holding source: Int?, duration: Double? = nil,
                               maxSteps: Int = 1_000_000) -> Simulator {
        let held = Self.quiet(circuit, holding: source)
        let estimate = Self.settling(held)
        let length = max(duration ?? estimate.duration, 0)
        var timeStep = estimate.timeStep
        if length / timeStep > Double(maxSteps) { timeStep = length / Double(maxSteps) }
        let simulator = Simulator(circuit: held, timeStep: timeStep)
        let steps = max(10, Int((length / timeStep).rounded(.up)))
        for _ in 0..<steps where !simulator.isFailed { simulator.step() }
        return simulator
    }
}
