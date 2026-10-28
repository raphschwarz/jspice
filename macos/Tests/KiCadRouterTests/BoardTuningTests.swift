import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// Tracks' and differential pairs' lengths tuned on real boards as KiCad's tuning patterns tune them (BoardEditing's
/// startTuning, moveTuning, fixTuning: the port of KiCad's meander placers, which RouterTests checks against KiCad's
/// own): each tuning started on a track, its stretch taken to the track's end, kept; the length it reports is the
/// length the board's tracks then have. kicad-cli's DRC finds no clearance, crossing or short with the meanders.
final class BoardTuningTests: XCTestCase {
    static func mm(_ p: IPoint) -> KiCadPoint { BoardEditingTests.mm(p) }

    /// Long tracks of the session's board (their uuids, ends and layers), in an order of their own
    static func longTracks(_ session: BoardEditing, nets: Set<String>? = nil, seed: String) -> [WorldItem] {
        let world = session.router.world
        var rng = BoardRoutingTests.SplitMix(seed: UInt64(truncatingIfNeeded: seed.utf8.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1) }))
        var tracks = world.items.filter { t in
            t.kind == .track && (t.net ?? 0) != 0 && t.a.distance(t.b) > 3_000_000 && t.source != nil
                && (nets == nil || nets!.contains(t.net.flatMap { world.netNames[$0] } ?? ""))
        }
        for i in tracks.indices.reversed() { tracks.swapAt(i, Int(rng.next() % UInt64(i + 1))) }
        return tracks
    }

    /// Tunes the track `w` (its line, its pair or its skew), from a quarter of the way along it to its end, to its
    /// path's length and `more` (or the skew it has and `more`); the change if it was kept, and the length the placer
    /// reported and the status
    static func tune(_ session: BoardEditing, _ w: WorldItem, mode: BoardRouter.TuningMode, more: Int,
                     file: String) throws -> (BoardEditing.Edit, Double, BoardEditing.TuningPreview.Status)? {
        let layer = session.router.layerName(w.layer)
        let from = w.a + (w.b - w.a).divided(by: 4)
        // (what it measures now: a tuning not moved yet)
        guard let started = session.startTuning(at: mm(from), layer: layer, mode: mode) else {
            XCTFail("\(file): \(w.source ?? "") not tuned: \(session.failureReason)")
            return nil
        }
        XCTAssertTrue(session.isRouting)
        XCTAssertEqual(started.status, .tooShort)
        var settings = MeanderSettings()
        if mode == .skew {
            settings.setTargetSkew(Int((started.length * 1e6).rounded()) + more)
        } else {
            settings.setTargetLength(Int((started.length * 1e6).rounded()) + more)
        }
        settings.maxAmplitude = 1_500_000
        settings.spacing = 800_000
        _ = session.updateTuningSettings(settings)
        var preview = try XCTUnwrap(session.moveTuning(to: mm(w.b)))
        // (and a step of the amplitude down and up again)
        XCTAssertNotNil(session.stepTuningAmplitude(-1))
        preview = try XCTUnwrap(session.stepTuningAmplitude(1))
        XCTAssertEqual(preview.lines.count, mode == .diffPair ? 2 : 1)
        guard let edit = session.fixTuning(at: mm(w.b)) else {
            XCTFail("\(file): \(w.source ?? "")'s tuning not kept")
            return nil
        }
        XCTAssertFalse(session.isRouting)
        return (edit, preview.length, preview.status)
    }

    func testTracksAreTunedToTheLengthAsked() throws {
        var tunings = 0, tuned = 0
        var finalBoards: [(URL, KiCadBoard, KiCadBoard, BoardWorld)] = []
        for file in try BoardEditingTests.boards() {
            let session = BoardEditing(board: try KiCadBoard.read(file), project: BoardEditingTests.project(file))
            // (the board's tracks, and some more routed)
            _ = session.routeConnections(most: 12)
            let start = session.board.copy()
            for w in Self.longTracks(session, seed: file.lastPathComponent).prefix(5) {
                guard let uuid = w.source, session.board.copperItems.contains(where: { $0.value("uuid") == uuid }) else { continue }
                guard let (edit, length, status) = try Self.tune(session, w, mode: .single, more: 2_500_000, file: file.lastPathComponent) else {
                    continue
                }
                tunings += 1
                if status == .tuned { tuned += 1 }
                XCTAssertEqual(edit.name, "Tune Length")
                XCTAssertTrue(edit.removed.contains(uuid))
                XCTAssertFalse(edit.added.isEmpty)
                for uuid in edit.removed { XCTAssertFalse(edit.after.copperItems.contains { $0.value("uuid") == uuid }) }
                for uuid in edit.added { XCTAssertTrue(edit.after.copperItems.contains { $0.value("uuid") == uuid }) }
                // (the length the placer reported is the length of what it put on the board: a tuning started on it
                // again measures it, within the nanometres the line's points are rounded to)
                let again = try XCTUnwrap(session.startTuning(at: Self.mm(w.a + (w.b - w.a).divided(by: 8)),
                                                              layer: session.router.layerName(w.layer)),
                                          "\(file.lastPathComponent): the tuned track")
                XCTAssertEqual(again.length, length, accuracy: 0.0001, "\(file.lastPathComponent) \(uuid)")
                session.cancelTuning()
            }
            // (nothing to tune there: refused as KiCad refuses it)
            XCTAssertNil(session.startTuning(at: KiCadPoint(-50, -50), layer: "F.Cu"))
            XCTAssertEqual(session.failureReason, "Please select a track whose length you want to tune.")
            finalBoards.append((file, start, session.board, session.router.world))
        }
        print("BoardTuningTests: \(tunings) tracks tuned, \(tuned) to the length asked")
        XCTAssertGreaterThan(tuned, 0)
        try Self.checkDRC(finalBoards, "tune")
    }

    /// Differential pairs routed from the connector's pads to the chip's on the boards of Fixtures/pairboards, then
    /// each tuned: the one's length, the other's skew
    func testPairsAreTunedToTheLengthAndSkewAsked() throws {
        let folder = try XCTUnwrap(Bundle.module.url(forResource: "pairboards", withExtension: nil, subdirectory: "Fixtures"))
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "kicad_pcb" }.sorted { $0.path < $1.path }
        var tunings = 0, tuned = 0
        var finalBoards: [(URL, KiCadBoard, KiCadBoard, BoardWorld)] = []
        for file in files {
            let session = BoardEditing(board: try KiCadBoard.read(file), project: BoardEditingTests.project(file))
            let world = session.router.world
            var start = session.board.copy()
            let positives = world.netNames.values.filter { name in
                let (polarity, coupled) = WorldResolver.matchDpSuffix(name)
                return polarity == 1 && world.netNames.values.contains(coupled)
            }.sorted()
            for (k, positive) in positives.enumerated() {
                let negative = WorldResolver.matchDpSuffix(positive).complement
                func pads(_ net: String, _ footprint: String) -> [WorldItem] {
                    session.router.world.items.filter { $0.kind == .pad && $0.footprint == footprint && $0.net.flatMap { world.netNames[$0] } == net }
                }
                guard let from = pads(negative, "J1").first?.pos, let to = pads(positive, "U1").first?.pos else { continue }
                // (the pair routed there, walking round)
                session.mode = .walkaround
                guard session.startPair(at: Self.mm(from), layer: session.router.layerName(0)) != nil else { continue }
                _ = session.movePair(to: Self.mm(IPoint((from.x + to.x) / 2, (from.y + to.y) / 2)))
                _ = session.movePair(to: Self.mm(to))
                guard session.fix(at: Self.mm(to)) ?? session.stop() != nil else { continue }
                start = session.board.copy()
                let mode: BoardRouter.TuningMode = k % 2 == 0 ? .diffPair : .skew
                for w in Self.longTracks(session, nets: [positive], seed: file.lastPathComponent).prefix(1) {
                    guard let (edit, _, status) = try Self.tune(session, w, mode: mode, more: mode == .skew ? 500_000 : 2_000_000,
                                                               file: file.lastPathComponent) else { continue }
                    tunings += 1
                    if status == .tuned { tuned += 1 }
                    XCTAssertEqual(edit.name, mode == .skew ? "Tune Skew" : "Tune Length")
                    // (a pair's tuning replaces both its lines' tracks; a skew's, the one line's)
                    let nets = Set(edit.after.copperItems.filter { edit.added.contains($0.value("uuid") ?? "") }.compactMap { $0.value("net") })
                    XCTAssertEqual(nets, mode == .diffPair ? [positive, negative] : [positive], file.lastPathComponent)
                }
            }
            finalBoards.append((file, start, session.board, session.router.world))
        }
        print("BoardTuningTests: \(tunings) pairs tuned, \(tuned) to the length or skew asked")
        XCTAssertGreaterThan(tunings, 0)
        try Self.checkDRC(finalBoards, "tune-pairs")
    }

    /// kicad-cli's DRC of the boards finds no clearance, crossing or short with what the tunings put on them that it
    /// did not find on the board before them (a tuning puts the rest of the tuned track's line on again, as KiCad's
    /// does, where the line was: what the line met there before, it still meets)
    static func checkDRC(_ boards: [(URL, KiCadBoard, KiCadBoard, BoardWorld)], _ name: String) throws {
        guard let kicad = KiCadInstallation.find(), kicad.major >= KiCadInstallation.minimumMajor else {
            if ProcessInfo.processInfo.environment["JSPICE_REQUIRE_KICAD"] != nil { return XCTFail("KiCad 10's kicad-cli is needed") }
            return
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        for (file, before, board, world) in boards {
            let copy = work.appendingPathComponent(file.lastPathComponent)
            try board.write(to: copy)
            let pro = file.deletingPathExtension().appendingPathExtension("kicad_pro")
            try? FileManager.default.copyItem(at: pro, to: copy.deletingPathExtension().appendingPathExtension("kicad_pro"))
            let original = Set(try KiCadBoard.read(file).copperItems.compactMap { $0.value("uuid") })
            let added = Set(board.copperItems.compactMap { $0.value("uuid") }).subtracting(original)
            let report = try KiCadFabrication(installation: kicad).drc(copy, refillZones: false)
            let beforeCopy = work.appendingPathComponent("before-" + file.lastPathComponent)
            try before.write(to: beforeCopy)
            try? FileManager.default.copyItem(at: pro, to: beforeCopy.deletingPathExtension().appendingPathExtension("kicad_pro"))
            func where_(_ v: KiCadFabrication.Violation) -> String {
                v.type + v.items.compactMap { $0.position.map { "\(($0.x * 1e4).rounded()),\(($0.y * 1e4).rounded())" } }.sorted().joined(separator: " ")
            }
            let already = Set(try KiCadFabrication(installation: kicad).drc(beforeCopy, refillZones: false).violations.map(where_))
            let ours = report.violations.filter { v in
                guard BoardEditingTests.clearanceViolations.contains(v.type) && v.items.contains(where: { added.contains($0.uuid) }),
                      !already.contains(where_(v)) else {
                    return false
                }
                // (a hole clearance of 0: KiCad's router takes the tracks it routes along a hole's very edge, which its
                // DRC finds touching it, as BoardRoutingTests counts apart; one cutting into the hole is wrong)
                if v.type == "hole_clearance", v.description.contains("hole clearance 0 mm"),
                   let overlap = BoardRoutingTests.holeOverlap(v, board: board, world: world), overlap < 1_000 {
                    return false
                }
                return true
            }
            XCTAssert(ours.isEmpty, "\(file.lastPathComponent): " + ours.map { v in
                "\(v.type): \(v.description) [" + v.items.map { "\($0.description) \($0.uuid) \(String(describing: $0.position))" }.joined(separator: " / ") + "]"
            }.joined(separator: "; "))
        }
    }
}
