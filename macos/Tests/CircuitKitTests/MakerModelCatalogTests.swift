import XCTest
@testable import CircuitKit

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

    func testMakersModelsMatchNgspice() throws {
        guard ProcessInfo.processInfo.environment["JSPICE_MAKER_MODELS"] != nil else {
            throw XCTSkip("Set JSPICE_MAKER_MODELS to download the makers' models and check them (CI does)")
        }
        var report = ["Makers' models measured by JSpice (beside the datasheet, and ngspice on the same file):"]
        /// Progress as it goes (on standard error, unbuffered), so a run that takes too long shows where
        func progress(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
        for model in MakerModelCatalog.models {
            progress("\(model.part): downloading \(model.archive)")
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
            let pins = try XCTUnwrap(imported.block.source?.pins)
            // what a step costs: a follower at rest, 200 steps of 1 µs
            let follower = try MakerModels.bench(imported.block, pins: pins, supply: model.supply, load: model.load,
                                                  input: NetlistPart(kind: .dcVoltage, name: "VI", params: ["voltage": 0],
                                                                     connections: ["plus": "inp", "minus": "GND"]), follower: true)
            let probe = Simulator(circuit: follower, timeStep: 1e-6)
            let clock = Date()
            for _ in 0..<200 where !probe.isFailed { probe.step() }
            let shape = probe.planShape
            progress(String(format: "%@: %.2f ms a step; %ld unknowns, %ld in the nonlinear block, %ld pivot orders, %ld plans; "
                            + "%.1f Newton iterations, %.1f substeps (%ld rejected) a step, %ld convergence failures",
                            model.part, Date().timeIntervalSince(clock) * 1e3 / 200, shape.unknowns, shape.nonlinear, shape.orders,
                            probe.plans, Double(probe.newtonIterations) / 200, Double(probe.substeps) / 200, probe.rejectedSubsteps,
                            probe.convergenceFailures))
            let started = Date()
            progress("\(model.part): imported (\(imported.block.circuit.elements.count) parts), measuring")
            let figures = try MakerModels.measureOpAmp(imported.block, pins: pins, supply: model.supply, load: model.load)
            report.append(String(format: "  %@ (%@, measured in %.1f s):", model.part, model.revision, Date().timeIntervalSince(started)))
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
