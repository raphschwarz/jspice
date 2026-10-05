import XCTest
@testable import CircuitKit

/// JSpice's analog engine against ngspice. tools/spice-reference/crosscheck.py runs each circuit in ngspice with
/// JSpice's own device equations and tight tolerances (the reference is converged to better than 0.02 % of each
/// waveform's range) and records the waveforms; here JSpice simulates the same circuits at the time step it would choose
/// itself, and at a tenth of it, and the waveforms are compared: so the differences are JSpice's numerical error alone.
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
    /// range, or for an oscillator the error in its period (also a fraction)
    struct Deviation {
        var waveform = 0.0
        var period: Double?
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
        return try SchematicLayout.layout(parts)
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

    private static func risingCrossings(_ times: [Double], _ values: [Double], level: Double) -> [Double] {
        var result: [Double] = []
        for i in 1..<values.count where values[i - 1] < level && values[i] >= level {
            let f = (level - values[i - 1]) / (values[i] - values[i - 1])
            result.append(times[i - 1] + f * (times[i] - times[i - 1]))
        }
        return result
    }

    private static func meanPeriod(_ crossings: [Double]) -> Double? {
        guard crossings.count >= 2 else { return nil }
        return (crossings.last! - crossings.first!) / Double(crossings.count - 1)
    }

    /// Simulates a case at `timeStep` and measures each probe against the reference
    private func deviations(_ test: Case, _ circuit: Circuit, timeStep: Double) throws -> [String: Deviation] {
        let simulator = Simulator(circuit: circuit, timeStep: timeStep)
        let probes = try test.probes.map { probe -> (Int, Int) in
            let index = try XCTUnwrap(circuit.elements.firstIndex { $0.name == probe.part }, probe.part)
            let terminal = try XCTUnwrap(circuit.elements[index].kind.terminalNames.firstIndex(of: probe.terminal), probe.terminal)
            return (index, terminal)
        }
        var times: [Double] = [0]
        var waves = probes.map { simulator.terminalVoltage($0.0, $0.1) * 0 }.map { [$0] }
        while simulator.time < test.duration {
            simulator.step()
            XCTAssertFalse(simulator.isFailed, "\(test.id) failed at \(simulator.time) s")
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
                let ours = Self.risingCrossings(times, waves[k], level: level)
                deviation.period = Self.meanPeriod(Array(ours.prefix(crossings.count))).map { abs($0 - period) / period } ?? 1
                let swing = (waves[k].max() ?? 0) - (waves[k].min() ?? 0)
                deviation.waveform = abs(swing - range) / range
            } else {
                for (t, value) in zip(test.times, probe.values) {
                    let ours = Self.interpolate(times, waves[k], at: t)
                    deviation.waveform = max(deviation.waveform, abs(ours - value) / range)
                }
            }
            result[probe.net] = deviation
        }
        return result
    }

    /// The most each case may differ from ngspice at the time step JSpice chooses (fractions of the waveform's range, and
    /// of an oscillator's period)
    static let tolerance: [String: Double] = [:]
    static let defaultTolerance = 0.05

    func testAnalogEngineMatchesNgspice() throws {
        let reference = try reference()
        var report = ["JSpice against \(reference.ngspice): largest difference, % of range (period error for oscillators)",
                      "case               probe      step         error   step/10   error"]
        for test in reference.cases {
            let circuit = try circuit(test)
            let step = Pacing.suggest(for: circuit).timeStep
            let coarse = try deviations(test, circuit, timeStep: step)
            let fine = try deviations(test, circuit, timeStep: step / 10)
            for probe in test.probes {
                let a = coarse[probe.net] ?? Deviation(), b = fine[probe.net] ?? Deviation()
                let measure = { (d: Deviation) in d.period ?? d.waveform }
                func percent(_ x: Double) -> String { String(format: "%7.3f%%", 100 * x) }
                report.append(test.id.padding(toLength: 19, withPad: " ", startingAt: 0)
                              + probe.net.padding(toLength: 8, withPad: " ", startingAt: 0)
                              + String(format: "%9.2e", step) + "  " + percent(measure(a)) + (a.period != nil ? " T" : "  ")
                              + String(format: "%9.2e", step / 10) + "  " + percent(measure(b)) + (b.period != nil ? " T" : ""))
                let limit = Self.tolerance[test.id] ?? Self.defaultTolerance
                XCTAssertLessThanOrEqual(measure(a), limit, "\(test.id) \(probe.net) (\(test.note))")
                XCTAssertLessThanOrEqual(measure(b), limit, "\(test.id) \(probe.net) at a tenth of the step")
            }
        }
        print(report.joined(separator: "\n"))
    }
}
