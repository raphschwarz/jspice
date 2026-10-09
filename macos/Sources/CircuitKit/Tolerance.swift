import Foundation

/// Tolerance (Monte Carlo) analysis: copies of a circuit with each part's value drawn within its tolerance, the way
/// a batch of real parts comes off the reel. Each value is drawn from a normal distribution whose three standard
/// deviations are the tolerance, cut off there, the same for the same seed and run.
public struct Tolerances: Sendable, Equatable {
    /// ± fractions by kind of value
    public var resistors = 0.05
    public var capacitors = 0.10
    public var inductors = 0.10
    /// A bipolar transistor's current gain varies widely from one to the next
    public var transistorGain = 0.3
    /// A JFET's saturation current and pinch-off voltage
    public var fets = 0.2
    /// Tolerances of single parts, by id, in place of their kind's
    public var parts: [UUID: Double] = [:]

    public init() {}

    /// The values a part varies, each with its tolerance
    public func varied(_ element: Element) -> [(key: String, tolerance: Double)] {
        let own = parts[element.id]
        switch element.kind {
        case .resistor, .lamp, .potentiometer: return [("resistance", own ?? resistors)]
        case .capacitor: return [("capacitance", own ?? capacitors)]
        case .inductor, .transformer: return [("inductance", own ?? inductors)]
        case .npn, .pnp: return [("beta", own ?? transistorGain)]
        case .njfet, .pjfet: return [("idss", own ?? fets), ("pinchOff", own ?? fets)]
        default: return []
        }
    }

    /// The circuit with its values drawn for run `run` of the analysis seeded with `seed` (run 0 of any seed is the
    /// circuit as drawn, the nominal values)
    public func variant(of circuit: Circuit, seed: UInt64, run: Int) -> Circuit {
        guard run > 0 else { return circuit }
        var random = SplitMix(seed &+ UInt64(run) &* 0x9E37_79B9_7F4A_7C15)
        return vary(circuit, &random)
    }

    private func vary(_ circuit: Circuit, _ random: inout SplitMix) -> Circuit {
        var copy = circuit
        for i in copy.elements.indices {
            for (key, tolerance) in varied(copy.elements[i]) where tolerance > 0 {
                let z = max(-3, min(3, random.normal()))
                copy.elements[i][param: key] *= 1 + tolerance * z / 3
            }
            // the parts inside a block vary as well, each copy its own way
            if var block = copy.elements[i].block {
                block.circuit = vary(block.circuit, &random)
                copy.elements[i].block = block
            }
        }
        return copy
    }

    /// A summary of values measured over the runs
    public struct Summary: Sendable, Equatable {
        public var mean: Double
        public var standardDeviation: Double
        public var minimum: Double
        public var maximum: Double
        /// The values 5 % and 95 % of the runs stay above and below
        public var low: Double
        public var high: Double
        public var count: Int
    }

    public static func summary(_ values: [Double]) -> Summary? {
        let finite = values.filter(\.isFinite).sorted()
        guard !finite.isEmpty else { return nil }
        let n = Double(finite.count)
        let mean = finite.reduce(0, +) / n
        let variance = finite.count > 1 ? finite.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / (n - 1) : 0
        func quantile(_ q: Double) -> Double {
            let position = q * (n - 1)
            let k = Int(position)
            let f = position - Double(k)
            return k + 1 < finite.count ? finite[k] + (finite[k + 1] - finite[k]) * f : finite[k]
        }
        return Summary(mean: mean, standardDeviation: variance.squareRoot(), minimum: finite.first!, maximum: finite.last!,
                       low: quantile(0.05), high: quantile(0.95), count: finite.count)
    }
}

/// A small, fast random number generator (SplitMix64), with normally distributed numbers by Box-Muller
struct SplitMix {
    private var state: UInt64

    init(_ seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in (0, 1)
    mutating func uniform() -> Double { (Double(next() >> 11) + 0.5) / Double(1 << 53) }

    mutating func normal() -> Double {
        (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())
    }
}

/// Values for a sweep: `count` of them from `start` to `stop`, evenly or (for `logarithmic`) in even ratios
public enum Sweep {
    public static func values(from start: Double, to stop: Double, count: Int, logarithmic: Bool) -> [Double] {
        guard count > 1 else { return [start] }
        return (0..<count).map { k in
            let f = Double(k) / Double(count - 1)
            return logarithmic && start > 0 && stop > 0 ? start * pow(stop / start, f) : start + (stop - start) * f
        }
    }
}
