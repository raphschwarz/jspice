import XCTest
@testable import CircuitKit

/// JSpice's analog engine against ngspice. tools/spice-reference/crosscheck.py runs each circuit in ngspice with
/// JSpice's own device equations and tight tolerances (the reference is converged to better than 0.02 % of each
/// waveform's range) and records the waveforms; here JSpice simulates the same circuits at the time step it would choose
/// itself (with fixed steps, and with the substeps its error control takes) and at a tenth of it, and the waveforms are
/// compared: so the differences are JSpice's numerical error alone.
final class SpiceCrossCheckTests: XCTestCase {
    struct Reference: Decodable {
        let ngspice: String
        let cases: [Case]
    }

    struct Case: Decodable {
        let id: String
        let note: String
        let duration: Double
        let times: [Double]
        let probes: [Probe]
        /// °C, when not the parts' nominal 27 °C
        let temperature: Double?
        let example: String?
        let parts: [Part]?
    }

    struct Probe: Decodable {
        let net: String
        let part: String
        let terminal: String
        let values: [Double]
        /// For an oscillator: the level its rising crossings are timed at, and their times
        let level: Double?
        let crossings: [Double]?
    }

    struct Part: Decodable {
        let kind: String
        let name: String
        let params: [String: Double]
        let connections: [String: String]
    }

    /// How far JSpice is from the reference: the largest difference over the run as a fraction of the reference's
    /// range, or for an oscillator the error in its period (also a fraction), with what JSpice's oscillator did
    struct Deviation {
        var waveform = 0.0
        var period: Double?
        var note = ""
    }

    private func reference() throws -> Reference {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "spice-reference", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }

    private func circuit(_ test: Case) throws -> Circuit {
        if let id = test.example { return try XCTUnwrap(Examples.all.first { $0.id == id }).circuit }
        let parts = try (test.parts ?? []).map { part -> NetlistPart in
            NetlistPart(kind: try XCTUnwrap(ElementKind(rawValue: part.kind)), name: part.name, params: part.params,
                        connections: part.connections)
        }
        var circuit = try SchematicLayout.layout(parts)
        if let temperature = test.temperature { circuit.settings.temperature = temperature }
        return circuit
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

    /// The lowest and highest the waveform comes within `window` of `t`: a step either way is as close as a
    /// fixed-step simulation can place an edge
    private static func band(_ times: [Double], _ values: [Double], at t: Double, window: Double) -> ClosedRange<Double> {
        var low = interpolate(times, values, at: t - window), high = low
        for x in [interpolate(times, values, at: t), interpolate(times, values, at: t + window)] {
            low = min(low, x)
            high = max(high, x)
        }
        var lo = 0, hi = times.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if times[mid] < t - window { lo = mid } else { hi = mid }
        }
        var k = hi
        while k < times.count && times[k] <= t + window {
            low = min(low, values[k])
            high = max(high, values[k])
            k += 1
        }
        return low...high
    }

    /// When the waveform rises through `level`, having been below `level - hysteresis` since it last did
    private static func risingCrossings(_ times: [Double], _ values: [Double], level: Double, hysteresis: Double) -> [Double] {
        var result: [Double] = []
        var armed = false
        for i in 1..<values.count {
            if values[i - 1] < level - hysteresis { armed = true }
            if armed && values[i - 1] < level && values[i] >= level {
                let f = (level - values[i - 1]) / (values[i] - values[i - 1])
                result.append(times[i - 1] + f * (times[i] - times[i - 1]))
                armed = false
            }
        }
        return result
    }

    private static func meanPeriod(_ crossings: [Double]) -> Double? {
        guard crossings.count >= 2 else { return nil }
        return (crossings.last! - crossings.first!) / Double(crossings.count - 1)
    }

    /// Simulates a case at `timeStep` and measures each probe against the reference; and how many substeps a step took
    private func deviations(_ test: Case, _ circuit: Circuit, timeStep: Double,
                            errorControl: Bool) throws -> (deviations: [String: Deviation], substeps: Double) {
        let simulator = Simulator(circuit: circuit, timeStep: timeStep)
        simulator.errorControl = errorControl
        let probes = try test.probes.map { probe -> (Int, Int) in
            let index = try XCTUnwrap(circuit.elements.firstIndex { $0.name == probe.part }, probe.part)
            let terminal = try XCTUnwrap(circuit.elements[index].kind.terminalNames.firstIndex(of: probe.terminal), probe.terminal)
            return (index, terminal)
        }
        var times: [Double] = [0]
        var steps = 0
        var waves = probes.map { simulator.terminalVoltage($0.0, $0.1) * 0 }.map { [$0] }
        while simulator.time < test.duration {
            simulator.step()
            XCTAssertFalse(simulator.isFailed, "\(test.id) failed at \(simulator.time) s")
            steps += 1
            if simulator.isFailed { break }
            times.append(simulator.time)
            for (k, probe) in probes.enumerated() { waves[k].append(simulator.terminalVoltage(probe.0, probe.1)) }
        }
        var result: [String: Deviation] = [:]
        for (k, probe) in test.probes.enumerated() {
            var deviation = Deviation()
            let range = max((probe.values.max() ?? 0) - (probe.values.min() ?? 0), 1e-9)
            if let level = probe.level, let crossings = probe.crossings, let period = Self.meanPeriod(crossings) {
                // an oscillator's phase drifts: compare its period, and its swing
                // from about when the reference first crosses (a start from rest may cross once more on its way)
                let ours = Self.risingCrossings(times, waves[k], level: level, hysteresis: 0.1 * range)
                    .filter { $0 > crossings[0] - period / 2 }
                let ourPeriod = Self.meanPeriod(Array(ours.prefix(crossings.count)))
                deviation.period = ourPeriod.map { abs($0 - period) / period } ?? 1
                // and the swing, once it has settled into its cycle
                let settled = waves[k].indices.filter { times[$0] >= crossings[0] }.map { waves[k][$0] }
                let reference = probe.values.indices.filter { test.times[$0] >= crossings[0] }.map { probe.values[$0] }
                let swing = (settled.max() ?? 0) - (settled.min() ?? 0)
                let referenceSwing = max((reference.max() ?? 0) - (reference.min() ?? 0), 1e-9)
                deviation.waveform = abs(swing - referenceSwing) / referenceSwing
                deviation.note = String(format: "period %.5g s (ngspice %.5g s), %.4g..%.4g V (ngspice %.4g..%.4g V)",
                                        ourPeriod ?? 0, period, settled.min() ?? 0, settled.max() ?? 0,
                                        reference.min() ?? 0, reference.max() ?? 0)
            } else {
                var worst = (time: 0.0, value: 0.0, ours: 0.0...0.0)
                for (t, value) in zip(test.times, probe.values) {
                    let ours = Self.band(times, waves[k], at: t, window: timeStep)
                    let distance = value < ours.lowerBound ? ours.lowerBound - value : max(0, value - ours.upperBound)
                    if distance / range > deviation.waveform {
                        deviation.waveform = distance / range
                        worst = (t, value, ours)
                    }
                }
                // where a waveform is well off, where and how
                if deviation.waveform > 0.02 {
                    deviation.note = String(format: "worst at %.5g s: ngspice %.4g V, JSpice %.4g..%.4g V; %d substeps unconverged",
                                            worst.time, worst.value, worst.ours.lowerBound, worst.ours.upperBound,
                                            simulator.convergenceFailures)
                }
            }
            result[probe.net] = deviation
        }
        return (result, Double(simulator.substeps + simulator.rejectedSubsteps) / Double(max(steps, 1)))
    }

    /// The most each case may differ from ngspice at the time step JSpice chooses (fractions of the waveform's range, and
    /// of an oscillator's period)
    static let tolerance: [String: Double] = [:]
    static let defaultTolerance = 0.05

    func testAnalogEngineMatchesNgspice() throws {
        let reference = try reference()
        var report = ["JSpice against \(reference.ngspice): largest difference, % of range (for oscillators T: the larger",
                      "of the period's and the swing's error), at JSpice's step with fixed steps and with error control",
                      "(and the solves a step took), and at a tenth of the step with error control",
                      "case               probe      step      fixed    adaptive  solves   step/10  adaptive"]
        for test in reference.cases {
            let circuit = try circuit(test)
            let step = Pacing.suggest(for: circuit).timeStep
            let fixed = try deviations(test, circuit, timeStep: step, errorControl: false)
            let coarse = try deviations(test, circuit, timeStep: step, errorControl: true)
            let fine = try deviations(test, circuit, timeStep: step / 10, errorControl: true)
            for probe in test.probes {
                let f = fixed.deviations[probe.net] ?? Deviation()
                let a = coarse.deviations[probe.net] ?? Deviation(), b = fine.deviations[probe.net] ?? Deviation()
                let measure = { (d: Deviation) in d.period.map { max($0, d.waveform) } ?? d.waveform }
                func percent(_ x: Double) -> String { String(format: "%7.3f%%", 100 * x) }
                report.append(test.id.padding(toLength: 19, withPad: " ", startingAt: 0)
                              + probe.net.padding(toLength: 8, withPad: " ", startingAt: 0)
                              + String(format: "%9.2e", step) + "  " + percent(measure(f)) + "  " + percent(measure(a))
                              + String(format: "%7.2f", coarse.substeps) + (a.period != nil ? " T" : "  ")
                              + String(format: "%9.2e", step / 10) + "  " + percent(measure(b))
                              + (a.note.isEmpty ? "" : "\n    " + a.note) + (f.note.isEmpty ? "" : "\n    fixed: " + f.note))
                let limit = Self.tolerance[test.id] ?? Self.defaultTolerance
                XCTAssertLessThanOrEqual(measure(a), limit, "\(test.id) \(probe.net) (\(test.note))")
                XCTAssertLessThanOrEqual(measure(b), limit, "\(test.id) \(probe.net) at a tenth of the step")
            }
        }
        print(report.joined(separator: "\n"))
    }
}
