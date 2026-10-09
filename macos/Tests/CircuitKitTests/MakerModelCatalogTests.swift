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

    static func profile(_ model: MakerModelCatalog.Model, _ block: BlockDefinition, _ pins: [String], linear: Bool,
                        budget: TimeInterval) throws -> Profile {
        let follower = try MakerModels.bench(block, pins: pins, supply: model.supply, load: model.load,
                                              input: NetlistPart(kind: .dcVoltage, name: "VI", params: ["voltage": 0],
                                                                 connections: ["plus": "inp", "minus": "GND"]), follower: true)
        let output = try XCTUnwrap(follower.elements.firstIndex { $0.name == "RL" })
        Simulator.linearAffineSources = linear
        let probe = Simulator(circuit: follower, timeStep: 1e-6)
        let clock = Date()
        let stepped = concurrently([{ () -> Int in
            var steps = 0
            while steps < 200 && !probe.isFailed {
                probe.step()
                steps += 1
            }
            return steps
        }], budget: budget)[0]
        if stepped == nil { probe.stopRequested = true }
        let steps = stepped ?? Int((probe.time / probe.timeStep).rounded())
        let shape = probe.planShape
        let line = String(format: "%@ (affine sources %@): %@%.2f ms a step over %ld steps; %ld unknowns, %ld in the nonlinear block, "
                          + "%ld pivot orders, %ld plans (%.2f s); %.1f Newton iterations, %.1f substeps (%ld rejected) a step, "
                          + "%ld convergence failures%@",
                          model.part, linear ? "linear" : "nonlinear", stepped == nil ? "STOPPED after \(Int(budget)) s, " : "",
                          Date().timeIntervalSince(clock) * 1e3 / Double(max(steps, 1)), steps, shape.unknowns, shape.nonlinear,
                          shape.orders, probe.plans, probe.planningSeconds,
                          Double(probe.newtonIterations) / Double(max(steps, 1)), Double(probe.substeps) / Double(max(steps, 1)),
                          probe.rejectedSubsteps, probe.convergenceFailures,
                          probe.isFailed && stepped != nil ? "; FAILED: " + probe.problems.joined(separator: "; ") : "")
        return Profile(line: line, output: stepped == nil ? .nan : probe.terminalVoltage(output, 0),
                       finished: stepped == 200 && !probe.isFailed)
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
                imported = try MakerModelCatalog.download(model)
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

        // what a step costs, with affine sources linearised at every iteration and stamped once as linear parts: the two
        // must agree
        var linearAgrees = true
        let profiles = try [false, true].map { linear in
            try models.map { m in try Self.profile(m.model, m.block, m.pins, linear: linear, budget: 60) }
        }
        for (k, m) in models.enumerated() {
            let (nonlinear, linear) = (profiles[0][k], profiles[1][k])
            Self.progress(nonlinear.line)
            Self.progress(linear.line)
            guard nonlinear.finished, linear.finished, abs(linear.output - nonlinear.output) <= 1e-6 else {
                linearAgrees = false
                XCTFail("\(m.model.part): with affine sources linear the follower ends at \(linear.output) V, "
                        + "linearised at every iteration \(nonlinear.output) V")
                continue
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
