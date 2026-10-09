import XCTest
@testable import CircuitKit

/// SPICE decks as written, imported: `crosscheck.py --netlists` runs each in ngspice as it is (controlled sources in every
/// form, a subcircuit of them: an op-amp macromodel, and a library file of JFET-input op-amps with sections, includes and
/// parameters), and JSpice imports the same text with `SpiceNetlist`, draws it, and simulates it at the step it picks
/// with error control. Each probed net must follow ngspice's waveform.
final class SpiceNetlistCrossCheckTests: XCTestCase {
    struct Reference: Decodable {
        let ngspice: String
        let cases: [Case]
    }

    struct Case: Decodable {
        let id: String
        let note: String
        let netlist: String
        let duration: Double
        let times: [Double]
        let probes: [Probe]
        /// The files the deck includes, by the paths it names them with
        let files: [String: String]?
    }

    struct Probe: Decodable {
        let net: String
        let values: [Double]
    }

    /// The most a probed waveform may differ from ngspice's, as a fraction of its range
    static let tolerance = 0.01

    /// A part's terminal on net `net` of an imported circuit
    private func terminal(on net: String, in circuit: Circuit) throws -> (index: Int, terminal: Int) {
        for (key, value) in circuit.netNames where value.lowercased() == net.lowercased() {
            guard let dot = key.lastIndex(of: ".") else { continue }
            let part = String(key[..<dot]), name = String(key[key.index(after: dot)...])
            guard let index = circuit.elements.firstIndex(where: { $0.name == part }),
                  let t = circuit.elements[index].terminalNames.firstIndex(of: name) else { continue }
            return (index, t)
        }
        throw NSError(domain: "SpiceNetlistCrossCheckTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "no part on net \(net)"])
    }

    private static func interpolate(_ times: [Double], _ values: [Double], at t: Double) -> Double {
        var lo = 0, hi = times.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if times[mid] <= t { lo = mid } else { hi = mid }
        }
        guard times[hi] > times[lo] else { return values[lo] }
        return values[lo] + (t - times[lo]) / (times[hi] - times[lo]) * (values[hi] - values[lo])
    }

    func testImportedNetlistsMatchNgspice() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "spice-netlist-reference", withExtension: "json", subdirectory: "Fixtures"))
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        var report = ["Imported netlists against \(reference.ngspice) (largest difference, % of range):"]
        for test in reference.cases {
            let files = test.files ?? [:]
            let (circuit, warnings) = try SpiceNetlist.circuit(from: test.netlist, include: { path, _ in files[path].map { (path, $0) } })
            XCTAssertTrue(warnings.isEmpty, "\(test.id): \(warnings)")
            let probes = try test.probes.map { try terminal(on: $0.net, in: circuit) }
            // the step JSpice picks, at most a thousandth of the run: a TABLE's corners are not errors its step control sees,
            // and straight lines across them between longer steps would be
            let step = min(Pacing.suggest(for: circuit).timeStep, test.duration / 1000)
            let simulator = Simulator(circuit: circuit, timeStep: step)
            XCTAssertTrue(simulator.problems.isEmpty, "\(test.id): \(simulator.problems)")
            // the waveforms from the first step (before it, the circuit has not been solved)
            var times: [Double] = []
            var waves = probes.map { _ in [Double]() }
            while simulator.time < test.duration {
                simulator.step()
                if simulator.isFailed { break }
                times.append(simulator.time)
                for (k, probe) in probes.enumerated() { waves[k].append(simulator.terminalVoltage(probe.index, probe.terminal)) }
            }
            XCTAssertFalse(simulator.isFailed, "\(test.id) failed at \(simulator.time) s: \(simulator.problems)")
            guard !times.isEmpty else { continue }
            for (k, probe) in test.probes.enumerated() {
                let range = max((probe.values.max() ?? 0) - (probe.values.min() ?? 0), 1e-9)
                var worst = 0.0, at = 0.0
                // from 1 % into the run: powering up from rest (all at 0 V, the supplies switched on), a stiff circuit's first
                // steps depend on how long each simulator makes them
                let start = max(times.first ?? 0, test.duration / 100)
                for (t, value) in zip(test.times, probe.values) where t >= start && t <= simulator.time {
                    let difference = abs(Self.interpolate(times, waves[k], at: t) - value) / range
                    if difference > worst { (worst, at) = (difference, t) }
                }
                report.append("  " + test.id.padding(toLength: 20, withPad: " ", startingAt: 0)
                              + probe.net.padding(toLength: 6, withPad: " ", startingAt: 0)
                              + String(format: "%8.3f%%  (at %.4g s, step %.2e)", 100 * worst, at, step))
                XCTAssertLessThanOrEqual(worst, Self.tolerance, "\(test.id) \(probe.net) at \(at) s (\(test.note))")
            }
        }
        print(report.joined(separator: "\n"))
    }

    /// The expression engine: SPICE's precedence, functions and POLY's order of coefficients, with exact slopes
    func testExpressions() throws {
        func value(_ text: String, _ inputs: [Double] = [], parameters: [String: Double] = [:]) throws -> Double {
            let e = try SpiceExpression(parsing: text, parameters: parameters)
            return inputs.withUnsafeBufferPointer { e.value($0.baseAddress ?? UnsafePointer(bitPattern: 8)!) }
        }
        XCTAssertEqual(try value("-2^2"), -4)
        XCTAssertEqual(try value("2**3**2"), 512)
        XCTAssertEqual(try value("1k + 2.2u*1meg"), 1002.2, accuracy: 1e-9)
        XCTAssertEqual(try value("{gain * 2}", parameters: ["GAIN": 3]), 6)
        XCTAssertEqual(try value("limit(5, 2, -1)"), 2)
        XCTAssertEqual(try value("1 < 2 && 3 > 4 ? 10 : 20"), 20)
        // PSpice's single | and &
        XCTAssertEqual(try value("if(1 > 2 | 3 > 2, 1, 0)"), 1)
        XCTAssertEqual(try value("if(1 < 2 & 3 > 4, 1, 0)"), 0)
        XCTAssertEqual(try value("table(0.25, 0, 0, 0.5, 1, 1, 1.2)"), 0.5)
        let e = try SpiceExpression(parsing: "V(a)*V(a,b) + 2*tanh(I(VX)) + pwr(V(a), 1.5)")
        XCTAssertEqual(e.inputs, [.voltage("a", nil), .voltage("a", "b"), .current("VX")])
        let x = [1.3, -0.7, 0.2]
        x.withUnsafeBufferPointer { p in
            // each slope against a difference quotient
            for k in 0..<3 {
                var up = x, down = x
                up[k] += 1e-6
                down[k] -= 1e-6
                let high: Double = up.withUnsafeBufferPointer { e.value($0.baseAddress!) }
                let low: Double = down.withUnsafeBufferPointer { e.value($0.baseAddress!) }
                let numeric = (high - low) / 2e-6
                XCTAssertEqual(e.slope(k, p.baseAddress!), numeric, accuracy: 1e-6, "slope \(k)")
            }
        }
        // POLY(2): p0 + p1 x1 + p2 x2 + p3 x1² + p4 x1 x2 + p5 x2²
        let poly = SpiceExpression.polynomial(dimensions: 2, coefficients: [1, 2, 3, 4, 5, 6],
                                              inputs: [.voltage("a", nil), .voltage("b", nil)])
        [0.5, -2.0].withUnsafeBufferPointer { p in
            // 1 + 2 (0.5) + 3 (−2) + 4 (0.25) + 5 (0.5)(−2) + 6 (4)
            XCTAssertEqual(poly.value(p.baseAddress!), 16, accuracy: 1e-12)
        }
        // .func: a call is the function's body with the call's arguments in place of its own
        let functions = ["sq": SpiceExpression.UserFunction(arguments: ["x"], body: "{x*x}"),
                         "clip": SpiceExpression.UserFunction(arguments: ["x", "lo", "hi"], body: "max(min(x, hi), lo)")]
        let user = try SpiceExpression(parsing: "sq(V(a) - 1) + clip(2*V(a), 0, 1)", functions: functions)
        XCTAssertEqual(user.inputs, [.voltage("a", nil)])
        [0.25].withUnsafeBufferPointer { p in
            // (0.25 − 1)² + 0.5, and its slope 2 (0.25 − 1) + 2
            XCTAssertEqual(user.value(p.baseAddress!), 1.0625, accuracy: 1e-12)
            XCTAssertEqual(user.slope(0, p.baseAddress!), 0.5, accuracy: 1e-12)
        }
        XCTAssertThrowsError(try SpiceExpression(parsing: "sq(1, 2)", functions: functions))
    }
}
