import XCTest
@testable import CircuitKit

/// Results of jobs on other threads
private final class ResultBox<T>: @unchecked Sendable {
    let lock = NSLock()
    var results: [T?]
    init(_ count: Int) { results = Array(repeating: nil, count: count) }
}

/// The makers' models of the catalog, downloaded from their makers as the app does (CI sets JSPICE_MAKER_MODELS; the
/// files are the makers' and are not kept here). Each must still be the revision the catalog names, import with nothing
/// left out, and measure as ngspice measures the same file; its datasheet's figures are printed beside, with what the
/// model is known to get wrong.
final class MakerModelCatalogTests: XCTestCase {
    /// How near JSpice must come to ngspice on each figure: relative, and absolute for figures near zero
    static func tolerance(_ figure: MakerModelCatalog.Figure, _ reference: Double) -> Double {
        switch figure {
        case .offset: return max(0.01 * abs(reference), 0.002)       // mV
        case .supplyCurrent: return 0.005 * abs(reference)            // mA
        case .openLoopGain: return 0.2                                // dB
        case .gainBandwidth, .unityGain: return 0.01 * reference      // MHz
        case .phaseMargin: return 1                                   // degrees
        case .slewRise, .slewFall: return 0.03 * reference            // V/µs
        case .swingHigh, .swingLow: return 0.02                       // V
        }
    }

    /// Progress as it goes (on standard error, unbuffered), so a run that takes too long shows where
    static func progress(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

    /// Runs each of `jobs` on its own thread, all at once, giving each `budget` seconds; a job's result, or nil for one
    /// still running when its time is up (it is left to finish on its own)
    static func concurrently<T>(_ jobs: [() -> T], budget: TimeInterval) -> [T?] {
        let box = ResultBox<T>(jobs.count)
        let finished = jobs.map { _ in DispatchSemaphore(value: 0) }
        for (k, job) in jobs.enumerated() {
            let thread = Thread {
                let result = job()
                box.lock.lock()
                box.results[k] = result
                box.lock.unlock()
                finished[k].signal()
            }
            thread.stackSize = 16 << 20
            thread.start()
        }
        let deadline = DispatchTime.now() + budget
        for semaphore in finished { _ = semaphore.wait(timeout: deadline) }
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.results
    }

    /// What a step costs: a follower at rest, 200 steps of 1 µs, and where its output ends
    struct Profile {
        var line: String
        var output: Double
        var finished: Bool
    }

    /// What a step costs: a follower at rest, 200 steps of 1 µs (or, `audio`, a 1 kHz sine of 1 V through it for 4,800
    /// steps of a 48 kHz sample, without error control, as the live sound runs), and where its output ends
    static func profile(_ model: MakerModelCatalog.Model, _ block: BlockDefinition, _ pins: [String], linear: Bool,
                        reuse: Bool = true, audio: Bool = false, budget: TimeInterval) throws -> Profile {
        let input = audio
            ? NetlistPart(kind: .acVoltage, name: "VI", params: ["amplitude": 1, "frequency": 1000, "offset": 0],
                          connections: ["plus": "inp", "minus": "GND"])
            : NetlistPart(kind: .dcVoltage, name: "VI", params: ["voltage": 0], connections: ["plus": "inp", "minus": "GND"])
        let follower = try MakerModels.bench(block, pins: pins, supply: model.supply, load: model.load, input: input, follower: true)
        let output = try XCTUnwrap(follower.elements.firstIndex { $0.name == "RL" })
        Simulator.linearAffineSources = linear
        Simulator.reusesFactors = reuse
        Simulator.profiling = true
        defer {
            Simulator.reusesFactors = true
            Simulator.profiling = false
        }
        let probe = Simulator(circuit: follower, timeStep: audio ? 1 / 48_000 : 1e-6)
        // the live sound sets its own step, without the integration's error control
        if audio { probe.errorControl = false }
        let total = audio ? 4_800 : 200
        let clock = Date()
        let stepped = concurrently([{ () -> Int in
            var steps = 0
            while steps < total && !probe.isFailed {
                probe.step()
                steps += 1
            }
            return steps
        }], budget: budget)[0]
        if stepped == nil { probe.stopRequested = true }
        let steps = stepped ?? Int((probe.time / probe.timeStep).rounded())
        let seconds = Date().timeIntervalSince(clock)
        let shape = probe.planShape
        let perStep = seconds / Double(max(steps, 1))
        let line = String(format: "%@ (affine sources %@, factors %@%@): %@%.1f µs a step over %ld steps%@; %ld unknowns, %ld in the nonlinear block, "
                          + "%ld pivot orders, %ld plans (%.2f s); %.1f Newton iterations (%ld factored, %ld with kept factors; "
                          + "%.1f µs stamping, %.1f µs solving an iteration), %.1f substeps (%ld rejected) a step, %ld convergence failures%@",
                          model.part, linear ? "linear" : "nonlinear", reuse ? "kept" : "made each iteration", audio ? ", 1 kHz at 48 kHz" : "",
                          stepped == nil ? "STOPPED after \(Int(budget)) s, " : "", perStep * 1e6, steps,
                          audio ? String(format: " (%.2f× real time)", (1.0 / 48_000) / perStep) : "",
                          shape.unknowns, shape.nonlinear, shape.orders, probe.plans, probe.planningSeconds,
                          Double(probe.newtonIterations) / Double(max(steps, 1)), probe.factorings, probe.reusedFactorings,
                          Double(probe.stampNanoseconds) / 1e3 / Double(max(probe.newtonIterations, 1)),
                          Double(probe.solveNanoseconds) / 1e3 / Double(max(probe.newtonIterations, 1)),
                          Double(probe.substeps) / Double(max(steps, 1)), probe.rejectedSubsteps, probe.convergenceFailures,
                          probe.isFailed && stepped != nil ? "; FAILED: " + probe.problems.joined(separator: "; ") : "")
        return Profile(line: line, output: stepped == nil ? .nan : probe.terminalVoltage(output, 0),
                       finished: stepped == total && !probe.isFailed)
    }

    func testMakersModelsMatchNgspice() throws {
        guard ProcessInfo.processInfo.environment["JSPICE_MAKER_MODELS"] != nil else {
            throw XCTSkip("Set JSPICE_MAKER_MODELS to download the makers' models and check them (CI does)")
        }
        defer { Simulator.linearAffineSources = true }
        var report = ["Makers' models measured by JSpice (beside the datasheet, and ngspice on the same file):"]
        var models: [(model: MakerModelCatalog.Model, block: BlockDefinition, pins: [String])] = []
        for model in MakerModelCatalog.models {
            Self.progress("\(model.part): downloading \(model.archive)")
            let imported: (block: BlockDefinition, warnings: [String])
            do {
                imported = try MakerModelCatalog.download(model, cached: false)
            } catch let error as MakerModelCatalog.DownloadError {
                XCTFail("\(model.part): \(error)")
                continue
            } catch {
                report.append("  \(model.part): can't download \(model.archive): \(error)")
                continue
            }
            XCTAssertTrue(imported.warnings.isEmpty, "\(model.part): \(imported.warnings)")
            Self.progress("\(model.part): imported (\(imported.block.circuit.elements.count) parts)")
            models.append((model, imported.block, try XCTUnwrap(imported.block.source?.pins)))
        }

        // a built-in TL072 running TI's model in its place: a gain of 2 on ±15 V (ngspice: 1.99995 V), and driven to its
        // swing into the 20 kΩ of its feedback (ngspice: 13.4758 V), where JSpice's own TL072 swings to 13.5 V
        if let tl072 = models.first(where: { $0.model.part == "TL072" }) {
            for (volts, expected) in [(1.0, 1.99995), (10.0, 13.4758)] {
                var u = NetlistPart(kind: .opAmp, name: "U1", params: ElementKind.opAmp.models.first { $0.name == "TL072" }?.values ?? [:],
                                    connections: ["plus": "in", "minus": "fb", "out": "out"])
                u.params["makerModel"] = 1
                u.block = tl072.block
                let circuit = try SchematicLayout.layout([
                    u,
                    NetlistPart(kind: .dcVoltage, name: "VI", params: ["voltage": volts], connections: ["plus": "in", "minus": "GND"]),
                    NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 10_000], connections: ["a": "out", "b": "fb"]),
                    NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 10_000], connections: ["a": "fb", "b": "GND"]),
                ])
                let index = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "U1" })
                let simulator = Simulator.settled(circuit, holding: nil, duration: 0.01, maxSteps: 2_000)
                XCTAssertFalse(simulator.isFailed, "\(simulator.problems)")
                XCTAssertEqual(simulator.terminalVoltages(index)[2], expected, accuracy: 0.002, "TL072 in place, \(volts) V in")
            }
        }

        // what a step costs, with affine sources linearised at every iteration and stamped once as linear parts, and
        // with the nonlinear block factored at every iteration and its factors kept while it stays as it was: all must
        // agree
        var linearAgrees = true
        let profiles = try [(false, true), (true, false), (true, true)].map { (linear, reuse) in
            try models.map { m in try Self.profile(m.model, m.block, m.pins, linear: linear, reuse: reuse, budget: 60) }
        }
        for (k, m) in models.enumerated() {
            let (nonlinear, factored, linear) = (profiles[0][k], profiles[1][k], profiles[2][k])
            Self.progress(nonlinear.line)
            Self.progress(factored.line)
            Self.progress(linear.line)
            guard nonlinear.finished, linear.finished, abs(linear.output - nonlinear.output) <= 1e-6 else {
                linearAgrees = false
                XCTFail("\(m.model.part): with affine sources linear the follower ends at \(linear.output) V, "
                        + "linearised at every iteration \(nonlinear.output) V")
                continue
            }
            XCTAssertTrue(factored.finished, m.model.part)
            XCTAssertEqual(linear.output, factored.output, accuracy: 1e-6, "\(m.model.part): kept factors against factoring at every iteration")
        }
        // at the sound's rate: a sine through each, factors kept and made each iteration, which must agree
        for m in models {
            let made = try Self.profile(m.model, m.block, m.pins, linear: true, reuse: false, audio: true, budget: 20)
            let kept = try Self.profile(m.model, m.block, m.pins, linear: true, reuse: true, audio: true, budget: 20)
            Self.progress(made.line)
            Self.progress(kept.line)
            if made.finished && kept.finished {
                XCTAssertEqual(kept.output, made.output, accuracy: 1e-4, "\(m.model.part) at 48 kHz: kept factors against factoring each iteration")
            }
        }

        // measured all at once, each on its own thread
        Simulator.linearAffineSources = linearAgrees
        Self.progress("measuring \(models.map(\.model.part).joined(separator: ", ")) at once, affine sources \(linearAgrees ? "linear" : "nonlinear")")
        let budget: TimeInterval = 14 * 60
        let results = Self.concurrently(models.map { m in
            { () -> (figures: MakerModels.OpAmpFigures?, error: String?, seconds: Double) in
                let started = Date()
                do {
                    let figures = try MakerModels.measureOpAmp(m.block, pins: m.pins, supply: m.model.supply, load: m.model.load,
                                                               slewGain: m.model.slewGain, stageBudget: 150) {
                        Self.progress("\(m.model.part): \($0)")
                    }
                    return (figures, nil, Date().timeIntervalSince(started))
                } catch {
                    return (nil, "\(error)", Date().timeIntervalSince(started))
                }
            }
        }, budget: budget)
        for (m, result) in zip(models, results) {
            let model = m.model
            guard let result else {
                XCTFail("\(model.part): not measured within \(Int(budget)) s")
                continue
            }
            guard let figures = result.figures else {
                XCTFail("\(model.part): \(result.error ?? "")")
                continue
            }
            report.append(String(format: "  %@ (%@, measured in %.1f s):", model.part, model.revision, result.seconds))
            report += MakerModelCatalog.comparison(model, figures).map { "    " + $0 }
            report += model.notes.map { "    note: " + $0 }
            for (figure, reference) in model.ngspice {
                guard let ours = figure.value(figures) else {
                    XCTFail("\(model.part): no \(figure.name) measured (ngspice: \(reference))")
                    continue
                }
                XCTAssertEqual(ours, reference, accuracy: Self.tolerance(figure, reference), "\(model.part) \(figure.name) against ngspice")
            }
        }
        print(report.joined(separator: "\n"))
    }
}
