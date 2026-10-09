import XCTest
@testable import CircuitKit

/// The sparse factoring behind the engine: planned once, replayed on new values, with the nonlinear block refactored
/// on its own as Newton-Raphson does, checked against the residual of the full equations
final class SparsePlanTests: XCTestCase {
    /// A random circuit's equations: a connected network of conductances over many decades, voltage sources (each a
    /// branch row) on distinct nodes, and devices among a few nodes
    struct System {
        var n: Int
        var matrix: [Double]
        var devices: [[Int]]
    }

    struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state ^ (state >> 29)
        }
    }

    func system(nodes: Int, sources: Int, devices: Int, sourcesOnDevices: Int, using g: inout Generator) -> System {
        let n = nodes + sources
        var a = [Double](repeating: 0, count: n * n)
        func conductance(_ p: Int, _ q: Int, _ value: Double) {
            if p >= 0 { a[p * n + p] += value }
            if q >= 0 { a[q * n + q] += value }
            if p >= 0 && q >= 0 {
                a[p * n + q] -= value
                a[q * n + p] -= value
            }
        }
        for i in 0..<nodes { a[i * n + i] += 1e-12 }
        for i in 1..<nodes { conductance(i, Int.random(in: -1..<i, using: &g), pow(10, Double.random(in: -6...0, using: &g))) }
        for _ in 0..<nodes {
            let p = Int.random(in: -1..<nodes, using: &g), q = Int.random(in: -1..<nodes, using: &g)
            if p != q { conductance(p, q, pow(10, Double.random(in: -7...1, using: &g))) }
        }
        var deviceList: [[Int]] = []
        for _ in 0..<devices {
            let count = min(nodes, Int.random(in: 2...3, using: &g))
            deviceList.append(Array((0..<nodes).shuffled(using: &g).prefix(count)))
        }
        let deviceNodes = Array(Set(deviceList.joined())).sorted()
        var used = Set<Int>()
        for s in 0..<sources {
            let row = nodes + s
            var choices = (s < sourcesOnDevices ? deviceNodes : Array(0..<nodes)).filter { !used.contains($0) }
            if choices.isEmpty { choices = (0..<nodes).filter { !used.contains($0) } }
            guard let plus = choices.randomElement(using: &g) else { break }
            used.insert(plus)
            a[plus * n + row] -= 1
            a[row * n + plus] += 1
        }
        return System(n: n, matrix: a, devices: deviceList)
    }

    /// Device stamps over many decades: each device's nodes get a full block, as a transistor's do
    func stamps(_ s: System, scale: Double, using g: inout Generator) -> (matrix: [Double], rhs: [Double]) {
        var m = [Double](repeating: 0, count: s.n * s.n)
        var r = [Double](repeating: 0, count: s.n)
        for device in s.devices {
            for i in device {
                for j in device { m[i * s.n + j] += Double.random(in: -1...1, using: &g) * scale * (i == j ? 3 : 1) }
                m[i * s.n + i] += scale
                r[i] += Double.random(in: -1...1, using: &g)
            }
        }
        return (m, r)
    }

    func residual(_ a: [Double], _ x: [Double], _ b: [Double], _ n: Int) -> Double {
        var worst = 0.0
        for r in 0..<n {
            var sum = -b[r]
            var scale = abs(b[r])
            for c in 0..<n where a[r * n + c] != 0 {
                sum += a[r * n + c] * x[c]
                scale = max(scale, abs(a[r * n + c] * x[c]))
            }
            worst = max(worst, abs(sum) / max(scale, 1e-30))
        }
        return worst
    }

    /// Factors the nonlinear block of `values` as the engine does, then solves for every unknown
    func solve(_ plan: SparsePlan, _ values: inout [Double], _ forwarded: [Double], linearFactored: Bool) throws -> [Double] {
        if !linearFactored {
            XCTAssertEqual(values.withUnsafeMutableBufferPointer { plan.linear.factor($0.baseAddress!) }, -1)
        }
        var scratch = [Double](repeating: 0, count: max(plan.entryCount - plan.tailStart, 1))
        let chosen = values.withUnsafeMutableBufferPointer { v in
            scratch.withUnsafeMutableBufferPointer { plan.factorBlock(v.baseAddress!, scratch: $0.baseAddress!) }
        }
        let order = try XCTUnwrap(chosen)
        var y = forwarded
        var x = [Double](repeating: 0, count: plan.n)
        values.withUnsafeBufferPointer { v in
            y.withUnsafeMutableBufferPointer { y in
                order.forward(v.baseAddress!, y.baseAddress!)
                x.withUnsafeMutableBufferPointer { x in
                    _ = order.back(v.baseAddress!, y.baseAddress!, x.baseAddress!)
                    _ = plan.linear.back(v.baseAddress!, y.baseAddress!, x.baseAddress!)
                }
            }
        }
        return x
    }

    func testLinearSystemsSolveFromTheirPlan() throws {
        var g = Generator(state: 1)
        for trial in 0..<40 {
            let s = system(nodes: 5 + trial, sources: trial % 4, devices: 0, sourcesOnDevices: 0, using: &g)
            let plan = try XCTUnwrap(SparsePlan.make(matrix: s.matrix, pattern: s.matrix.map { $0 != 0 },
                                                     nonlinear: [Bool](repeating: false, count: s.n), size: s.n), "trial \(trial)")
            XCTAssertEqual(plan.leading, s.n)
            var values = [Double](repeating: 0, count: plan.entryCount)
            for i in 0..<(s.n * s.n) where s.matrix[i] != 0 { values[Int(plan.slots[i])] += s.matrix[i] }
            XCTAssertEqual(values.withUnsafeMutableBufferPointer { plan.linear.factor($0.baseAddress!) }, -1)
            let b = (0..<s.n).map { _ in Double.random(in: -1...1, using: &g) }
            var forwarded = b
            values.withUnsafeBufferPointer { v in
                forwarded.withUnsafeMutableBufferPointer { plan.linear.forward(v.baseAddress!, $0.baseAddress!) }
            }
            let x = try solve(plan, &values, forwarded, linearFactored: true)
            XCTAssertLessThan(residual(s.matrix, x, b, s.n), 1e-9, "trial \(trial)")
            // never more operations than a dense elimination's (about n³/3)
            XCTAssertLessThanOrEqual(plan.linear.opCount, s.n * s.n * s.n / 3 + s.n, "trial \(trial)")
        }
    }

    func testNonlinearBlockRefactorsOnTheFactoredLinearBlock() throws {
        var g = Generator(state: 7)
        for trial in 0..<60 {
            let s = system(nodes: 8 + trial % 30, sources: trial % 5, devices: 1 + trial % 6, sourcesOnDevices: trial % 3, using: &g)
            let n = s.n
            var nonlinear = [Bool](repeating: false, count: n)
            var pattern = s.matrix.map { $0 != 0 }
            for device in s.devices {
                for i in device {
                    nonlinear[i] = true
                    for j in device { pattern[i * n + j] = true }
                }
            }
            let first = stamps(s, scale: 1e-3, using: &g)
            let planned = zip(s.matrix, first.matrix).map { $0 + $1 }
            let plan = try XCTUnwrap(SparsePlan.make(matrix: planned, pattern: pattern, nonlinear: nonlinear, size: n), "trial \(trial)")
            // every device stamp lands in the nonlinear block, which comes last
            for device in s.devices {
                for i in device {
                    for j in device { XCTAssertGreaterThanOrEqual(Int(plan.slots[i * n + j]), plan.tailStart) }
                }
            }
            var base = [Double](repeating: 0, count: plan.entryCount)
            for i in 0..<(n * n) where s.matrix[i] != 0 { base[Int(plan.slots[i])] += s.matrix[i] }
            XCTAssertEqual(base.withUnsafeMutableBufferPointer { plan.linear.factor($0.baseAddress!) }, -1)
            let b = (0..<n).map { _ in Double.random(in: -1...1, using: &g) }
            var forwarded = b
            base.withUnsafeBufferPointer { v in
                forwarded.withUnsafeMutableBufferPointer { plan.linear.forward(v.baseAddress!, $0.baseAddress!) }
            }
            for iteration in 0..<8 {
                // device values over six decades: pivot orders are reused or made as they need to be
                let restamp = stamps(s, scale: pow(10, Double.random(in: -6...0, using: &g)), using: &g)
                var values = base
                for i in 0..<(n * n) where restamp.matrix[i] != 0 { values[Int(plan.slots[i])] += restamp.matrix[i] }
                var y = forwarded
                for i in 0..<n { y[i] += restamp.rhs[i] }
                let x = try solve(plan, &values, y, linearFactored: true)
                let full = zip(s.matrix, restamp.matrix).map { $0 + $1 }
                let rhs = zip(b, restamp.rhs).map { $0 + $1 }
                XCTAssertLessThan(residual(full, x, rhs, n), 1e-9, "trial \(trial) iteration \(iteration)")
            }
            XCTAssertLessThanOrEqual(plan.orderCount, SparsePlan.maxOrders)
        }
    }

    func testAnOpAmpSwitchingBetweenItsLinearRangeAndSaturationReusesItsPivotOrders() throws {
        // a non-inverting amplifier: + input (0) driven through 1 kΩ, − input (1) with 10 kΩ to ground and 90 kΩ to the
        // output (2), the op-amp's row (3): v(out) − slope (v+ − v−) = 0, the slope a million in its linear range and
        // nearly nothing when it saturates
        let n = 4
        func matrix(slope: Double) -> [Double] {
            var a = [Double](repeating: 0, count: n * n)
            a[0 * n + 0] = 1e-3
            a[1 * n + 1] = 1e-4 + 1 / 90_000.0
            a[1 * n + 2] = -1 / 90_000.0
            a[2 * n + 1] = -1 / 90_000.0
            a[2 * n + 2] = 1 / 90_000.0
            a[2 * n + 3] = -1
            a[3 * n + 2] = 1
            a[3 * n + 0] = -slope
            a[3 * n + 1] = slope
            return a
        }
        var pattern = matrix(slope: 1).map { $0 != 0 }
        for i in 0..<n { for j in 0..<n { pattern[i * n + j] = pattern[i * n + j] || (i == 3 && j < 3) } }
        let plan = try XCTUnwrap(SparsePlan.make(matrix: matrix(slope: 1e6), pattern: pattern,
                                                 nonlinear: [true, true, true, true], size: n))
        let b = [1e-3, 0, 0, 0]
        for (round, slope) in [1e6, 1e-9, 1e6, 1e-9, 1e6, 1e-9].enumerated() {
            let a = matrix(slope: slope)
            var values = [Double](repeating: 0, count: plan.entryCount)
            for i in 0..<(n * n) where a[i] != 0 { values[Int(plan.slots[i])] += a[i] }
            let x = try solve(plan, &values, b, linearFactored: false)
            XCTAssertLessThan(residual(a, x, b, n), 1e-9, "round \(round)")
        }
        // at most one order for each state, made once and then switched between
        XCTAssertLessThanOrEqual(plan.orderCount, 2)
    }

    func testVoltageSourceOnNonlinearNodesJoinsTheNonlinearBlock() throws {
        // node 0 and 1 joined by 1 S; a transistor-like device on both; a 5 V source on node 0 (branch row 2)
        let n = 3
        var a = [Double](repeating: 0, count: n * n)
        a[0] = 1 + 1e-12; a[1] = -1; a[3] = -1; a[4] = 1 + 1e-3
        a[0 * n + 2] = -1; a[2 * n + 0] = 1
        var pattern = a.map { $0 != 0 }
        for i in 0..<2 { for j in 0..<2 { pattern[i * n + j] = true } }
        let plan = try XCTUnwrap(SparsePlan.make(matrix: a, pattern: pattern, nonlinear: [true, true, false], size: n))
        // the source's row has entries only in nonlinear columns: it can only be pivoted in the nonlinear block
        XCTAssertTrue(plan.nonlinear[2])
        XCTAssertEqual(plan.leading, 0)
    }

    func testSingularEquationsHaveNoPlan() {
        // two voltage sources on the same node: a loop of sources
        let n = 3
        var a = [Double](repeating: 0, count: n * n)
        a[0] = 1e-12
        a[0 * n + 1] = -1; a[1 * n + 0] = 1
        a[0 * n + 2] = -1; a[2 * n + 0] = 1
        XCTAssertNil(SparsePlan.make(matrix: a, pattern: a.map { $0 != 0 }, nonlinear: [false, false, false], size: n))
    }
}
