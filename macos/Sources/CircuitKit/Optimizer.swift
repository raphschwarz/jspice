import Foundation

/// Finding part values: a downhill simplex (Nelder-Mead) search, which needs only the cost of each try, so it works
/// on anything a simulation measures; and the standard E-series values real parts come in.
public enum Optimizer {
    public struct Result: Sendable {
        public var point: [Double]
        public var cost: Double
        public var evaluations: Int
    }

    /// The point in the unit cube (each coordinate from 0 to 1) where `cost` is least, from `start`, in at most
    /// `evaluations` tries. Points outside the cube are brought back to its faces before they are tried.
    public static func minimize(_ cost: ([Double]) -> Double, start: [Double], step: Double = 0.15, evaluations limit: Int = 200,
                                tolerance: Double = 1e-9) -> Result {
        let n = start.count
        var evaluations = 0
        func f(_ x: [Double]) -> (point: [Double], cost: Double) {
            let p = x.map { min(max($0, 0), 1) }
            evaluations += 1
            let c = cost(p)
            return (p, c.isFinite ? c : .greatestFiniteMagnitude)
        }
        guard n > 0 else { return Result(point: [], cost: cost([]), evaluations: 1) }
        // the starting simplex: the start and a step along each axis (inwards at a face)
        var simplex = [f(start)]
        for k in 0..<n {
            var x = simplex[0].point
            x[k] += x[k] + step <= 1 ? step : -step
            simplex.append(f(x))
        }
        while evaluations < limit {
            simplex.sort { $0.cost < $1.cost }
            let best = simplex[0], worst = simplex[n]
            if abs(worst.cost - best.cost) <= tolerance * (abs(best.cost) + tolerance) { break }
            // the centre of all but the worst
            var centre = [Double](repeating: 0, count: n)
            for vertex in simplex.dropLast() { for k in 0..<n { centre[k] += vertex.point[k] / Double(n) } }
            func along(_ t: Double) -> [Double] { (0..<n).map { centre[$0] + t * (worst.point[$0] - centre[$0]) } }
            let reflected = f(along(-1))
            if reflected.cost < best.cost {
                let expanded = f(along(-2))
                simplex[n] = expanded.cost < reflected.cost ? expanded : reflected
            } else if reflected.cost < simplex[n - 1].cost {
                simplex[n] = reflected
            } else {
                let contracted = reflected.cost < worst.cost ? f(along(-0.5)) : f(along(0.5))
                if contracted.cost < min(worst.cost, reflected.cost) {
                    simplex[n] = contracted
                } else {
                    // shrink towards the best
                    for i in 1...n {
                        simplex[i] = f((0..<n).map { best.point[$0] + 0.5 * (simplex[i].point[$0] - best.point[$0]) })
                    }
                }
            }
        }
        simplex.sort { $0.cost < $1.cost }
        return Result(point: simplex[0].point, cost: simplex[0].cost, evaluations: evaluations)
    }
}

/// The preferred values parts are made in: E12 (10 %), E24 (5 %), E96 (1 %)
public enum ESeries {
    static let e12: [Double] = [1.0, 1.2, 1.5, 1.8, 2.2, 2.7, 3.3, 3.9, 4.7, 5.6, 6.8, 8.2]
    static let e24: [Double] = [1.0, 1.1, 1.2, 1.3, 1.5, 1.6, 1.8, 2.0, 2.2, 2.4, 2.7, 3.0, 3.3, 3.6, 3.9, 4.3, 4.7, 5.1, 5.6, 6.2,
                                6.8, 7.5, 8.2, 9.1]
    static let e96: [Double] = (0..<96).map { k in (pow(10, Double(k) / 96) * 100).rounded() / 100 }

    /// The mantissas of a series by its size (12, 24 or 96), nil for any other
    public static func mantissas(_ size: Int) -> [Double]? {
        switch size {
        case 12: return e12
        case 24: return e24
        case 96: return e96
        default: return nil
        }
    }

    /// The series' values around `value`: the nearest one, and the ones next to it below and above
    public static func around(_ value: Double, series size: Int) -> (nearest: Double, below: Double, above: Double)? {
        guard value > 0, value.isFinite, let mantissas = mantissas(size) else { return nil }
        let decade = pow(10, floor(log10(value)))
        // the series over three decades, so the neighbours of the ends are there
        let values = [decade / 10, decade, decade * 10].flatMap { d in mantissas.map { $0 * d } }
        // nearest in ratio, as the series are spaced
        guard let k = values.indices.min(by: { abs(log(values[$0] / value)) < abs(log(values[$1] / value)) }) else { return nil }
        return (values[k], values[max(k - 1, 0)], values[min(k + 1, values.count - 1)])
    }
}
