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

    func testLinearSystemsSolveFromTheirPlan() throws {
        var g = Generator(state: 1)
        for trial in 0..<40 {
            let s = system(nodes: 5 + trial, sources: trial % 4, devices: 0, sourcesOnDevices: 0, using: &g)
            let plan = try XCTUnwrap(SparsePlan.make(matrix: s.matrix, pattern: s.matrix.map { $0 != 0 },
                                                     nonlinear: [Bool](repeating: false, count: s.n), size: s.n), "trial \(trial)")
            XCTAssertEqual(plan.leading, s.n)
            var values = [Double](repeating: 0, count: plan.entryCount)
            for i in 0..<(s.n * s.n) where s.matrix[i] != 0 { values[Int(plan.slots[i])] += s.matrix[i] }
            XCTAssertEqual(values.withUnsafeMutableBufferPointer { plan.factor($0.baseAddress!, from: 0, to: s.n) }, -1)
            let b = (0..<s.n).map { _ in Double.random(in: -1...1, using: &g) }
            var y = b
            var x = [Double](repeating: 0, count: s.n)
            values.withUnsafeBufferPointer { v in
                y.withUnsafeMutableBufferPointer { y in
                    plan.forward(v.baseAddress!, y.baseAddress!, from: 0, to: s.n)
                    _ = x.withUnsafeMutableBufferPointer { plan.back(v.baseAddress!, y.baseAddress!, $0.baseAddress!, from: 0, to: s.n) }
                }
            }
            XCTAssertLessThan(residual(s.matrix, x, b, s.n), 1e-9, "trial \(trial)")
            // never more operations than a dense elimination's (about n³/3)
            XCTAssertLessThanOrEqual(plan.opCount, s.n * s.n * s.n / 3 + s.n, "trial \(trial)")
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
            XCTAssertEqual(base.withUnsafeMutableBufferPointer { plan.factor($0.baseAddress!, from: 0, to: plan.leading) }, -1)
            let b = (0..<n).map { _ in Double.random(in: -1...1, using: &g) }
            var forwarded = b
            base.withUnsafeBufferPointer { v in
                forwarded.withUnsafeMutableBufferPointer { plan.forward(v.baseAddress!, $0.baseAddress!, from: 0, to: plan.leading) }
            }
            for iteration in 0..<6 {
                let restamp = stamps(s, scale: pow(10, Double.random(in: -6...0, using: &g)), using: &g)
                var values = base
                for i in 0..<(n * n) where restamp.matrix[i] != 0 { values[Int(plan.slots[i])] += restamp.matrix[i] }
                var y = forwarded
                for i in 0..<n { y[i] += restamp.rhs[i] }
                // a pivot that has become too small asks for a new plan, which the engine then makes
                guard values.withUnsafeMutableBufferPointer({ plan.factor($0.baseAddress!, from: plan.leading, to: n) }) < 0 else { continue }
                var x = [Double](repeating: 0, count: n)
                values.withUnsafeBufferPointer { v in
                    y.withUnsafeMutableBufferPointer { y in
                        plan.forward(v.baseAddress!, y.baseAddress!, from: plan.leading, to: n)
                        x.withUnsafeMutableBufferPointer { x in
                            _ = plan.back(v.baseAddress!, y.baseAddress!, x.baseAddress!, from: plan.leading, to: n)
                            _ = plan.back(v.baseAddress!, y.baseAddress!, x.baseAddress!, from: 0, to: plan.leading)
                        }
                    }
                }
                let full = zip(s.matrix, restamp.matrix).map { $0 + $1 }
                let rhs = zip(b, restamp.rhs).map { $0 + $1 }
                XCTAssertLessThan(residual(full, x, rhs, n), 1e-9, "trial \(trial) iteration \(iteration)")
            }
        }
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
