import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// The board edited as the PCB view edits it (BoardEditing): tracks routed by pointer moves and clicks, finished,
/// stopped, vias placed, tracks taken away; each change handed back as the board before and after it. The board the
/// session leaves goes through kicad-cli's DRC where KiCad is installed.
final class BoardEditingTests: XCTestCase {
    static func boards() throws -> [URL] {
        let folder = try XCTUnwrap(Bundle.module.url(forResource: "boards", withExtension: nil, subdirectory: "Fixtures"))
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "kicad_pcb" }.sorted { $0.path < $1.path }
    }

    static func project(_ file: URL) -> [String: Any]? {
        (try? Data(contentsOf: file.deletingPathExtension().appendingPathExtension("kicad_pro")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static func mm(_ p: IPoint) -> KiCadPoint { KiCadPoint(Double(p.x) / 1e6, Double(p.y) / 1e6) }

    func testASessionOfRoutingHandsBackEachChange() throws {
        var edits = 0, placed = 0
        var finalBoards: [(URL, KiCadBoard)] = []
        for file in try Self.boards() {
            let board = try KiCadBoard.read(file)
            let session = BoardEditing(board: board, project: Self.project(file))
            XCTAssertFalse(session.layers.isEmpty)
            XCTAssertEqual(session.layers.first, "F.Cu")
            var last = board.text
            for (k, (a, b, layer)) in BoardRoutingTests.pairs(session.router.world, seed: file.lastPathComponent).enumerated() {
                let from = Self.mm(a), to = Self.mm(b)
                guard session.start(at: from, layer: session.layers[layer]) else { continue }
                XCTAssertTrue(session.isRouting)
                // a pad's centre is where the pointer goes on it (magnetic pads)
                XCTAssertEqual(session.snap(KiCadPoint(to.x + 0.01, to.y - 0.01), layer: session.layers[layer]), b)
                for t in [0.3, 0.6] {
                    let preview = session.move(to: KiCadPoint(from.x + (to.x - from.x) * t + 0.4, from.y + (to.y - from.y) * t - 0.3))
                    XCTAssertNotNil(preview)
                    XCTAssertEqual(preview?.net, session.routedNet)
                }
                if k == 1 {
                    // a via on the way, and the track on from it on the other side
                    session.placeVia()
                    _ = session.fix(at: KiCadPoint(from.x + (to.x - from.x) * 0.6 + 0.4, from.y + (to.y - from.y) * 0.6 - 0.3))
                }
                session.move(to: to)
                // a click on the other pad finishes it; a track that could not get there is finished by a double click
                // there, or kept as far as it is fixed (Escape)
                let edit = session.fix(at: to) ?? (k % 2 == 0 ? session.finish(at: to) : session.stop())
                XCTAssertFalse(session.isRouting)
                guard let edit else { continue }
                edits += 1
                placed += edit.added.count
                XCTAssertEqual(edit.before.text, last, "each change is made from the board the last one left")
                XCTAssertEqual(edit.after.text, session.board.text)
                for uuid in edit.added { XCTAssertTrue(edit.after.copperItems.contains { $0.value("uuid") == uuid }) }
                last = edit.after.text
            }
            // the tracks of the first change taken away again
            if let first = session.board.copperItems.compactMap({ $0.value("uuid") }).first(where: { !board.text.contains($0) }) {
                let edit = try XCTUnwrap(session.remove([first]))
                XCTAssertEqual(edit.removed, [first])
                XCTAssertEqual(edit.before.text, last)
                XCTAssertFalse(edit.after.copperItems.contains { $0.value("uuid") == first })
                edits += 1
            }
            // the same board read again: nothing to do; another: routing on it
            let router = session.router
            session.load(session.board.copy())
            XCTAssertTrue(session.router === router)
            finalBoards.append((file, session.board))
        }
        print("BoardEditingTests: \(edits) changes, \(placed) tracks and vias placed")
        XCTAssertGreaterThan(placed, 0)

        guard let kicad = KiCadInstallation.find(), kicad.major >= KiCadInstallation.minimumMajor else {
            if ProcessInfo.processInfo.environment["JSPICE_REQUIRE_KICAD"] != nil { return XCTFail("KiCad 10's kicad-cli is needed") }
            return
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-editing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        for (file, board) in finalBoards {
            let copy = work.appendingPathComponent(file.lastPathComponent)
            try board.write(to: copy)
            let pro = file.deletingPathExtension().appendingPathExtension("kicad_pro")
            try? FileManager.default.copyItem(at: pro, to: copy.deletingPathExtension().appendingPathExtension("kicad_pro"))
            let original = Set(try KiCadBoard.read(file).copperItems.compactMap { $0.value("uuid") })
            let added = Set(board.copperItems.compactMap { $0.value("uuid") }).subtracting(original)
            let report = try KiCadFabrication(installation: kicad).drc(copy, refillZones: false)
            let ours = report.violations.filter { v in
                BoardRoutingTests.routerViolations.contains(v.type) && v.items.contains { added.contains($0.uuid) }
            }
            XCTAssert(ours.isEmpty, "\(file.lastPathComponent): " + ours.map { "\($0.type): \($0.description)" }.joined(separator: "; "))
        }
    }

    /// Footprints moved, turned and turned over, each a change of its own; the router then sees their pads where they
    /// went
    func testFootprintsArePlaced() throws {
        let file = try XCTUnwrap(Self.boards().first)
        let session = BoardEditing(board: try KiCadBoard.read(file), project: Self.project(file))
        let footprint = try XCTUnwrap(session.board.footprints.first { $0.pads.contains { $0.isCopper && $0.net != nil } })
        let uuid = footprint.uuid, start = footprint.position, turn = footprint.rotation
        let pad = try XCTUnwrap(footprint.pads.first { $0.isCopper && $0.net != nil })
        let offset = KiCadPoint(pad.position.x - start.x, pad.position.y - start.y)

        let moved = try XCTUnwrap(session.moveFootprint(uuid, to: KiCadPoint(start.x + 2.5, start.y - 1.25)))
        XCTAssertEqual(moved.footprints, [uuid])
        XCTAssertEqual(moved.added, [])
        XCTAssertTrue(moved.name.hasPrefix("Move"))
        let now = try XCTUnwrap(moved.after.footprint(uuid: uuid))
        XCTAssertEqual(now.position.x, start.x + 2.5, accuracy: 1e-9)
        XCTAssertEqual(now.rotation, turn)
        XCTAssertEqual(try XCTUnwrap(moved.before.footprint(uuid: uuid)).position, start, "the board before it is as it was")
        // the router sees the pad where it went
        let there = KiCadPoint(start.x + 2.5 + offset.x, start.y - 1.25 + offset.y)
        let layer = pad.layers.contains("B.Cu") && !pad.layers.contains("F.Cu") && !pad.layers.contains("*.Cu") ? "B.Cu" : "F.Cu"
        XCTAssertNotNil(session.router.item(at: BoardEditing.nm(there), layer: session.router.layer(layer) ?? 0))
        XCTAssertNil(session.moveFootprint(uuid, to: now.position), "not moved: no change")

        let rotated = try XCTUnwrap(session.rotateFootprint(uuid))
        XCTAssertEqual(try XCTUnwrap(rotated.after.footprint(uuid: uuid)).rotation,
                       (turn + 90).truncatingRemainder(dividingBy: 360) > 180 ? turn + 90 - 360 : turn + 90, accuracy: 1e-9)
        XCTAssertEqual(rotated.before.text, moved.after.text)

        let side = now.layer
        let flipped = try XCTUnwrap(session.flipFootprint(uuid))
        XCTAssertNotEqual(try XCTUnwrap(flipped.after.footprint(uuid: uuid)).layer, side)
        XCTAssertEqual(session.board.text, flipped.after.text)
    }

    /// Every connection routed in one go: one change, the connections left fewer
    func testEveryConnectionIsRoutedAsOneChange() throws {
        let file = try XCTUnwrap(Self.boards().last)
        let board = try KiCadBoard.read(file)
        let session = BoardEditing(board: board, project: Self.project(file))
        let before = KiCadConnectivity(board).ratsnest().count
        let routed = session.routeConnections()
        print("BoardEditingTests: \(routed.routed.count) of \(before) connections routed, \(routed.left) left")
        XCTAssertFalse(routed.routed.isEmpty)
        XCTAssertLessThan(routed.left, before)
        let edit = try XCTUnwrap(routed.edit)
        XCTAssertEqual(edit.before.text, board.text)
        XCTAssertEqual(edit.after.text, session.board.text)
        XCTAssertFalse(edit.added.isEmpty)
        XCTAssertFalse(session.isRouting)
        // only one net, and nothing on a net left out
        let again = BoardEditing(board: board, project: Self.project(file))
        let net = try XCTUnwrap(KiCadConnectivity(board).ratsnest().first?.net)
        let one = again.routeConnections(nets: [net])
        XCTAssertTrue((one.routed + one.failed).allSatisfy { $0.hasPrefix(net + ":") })
        XCTAssertTrue(again.routeConnections(skip: Set(KiCadConnectivity(board).ratsnest().map(\.net))).routed.isEmpty)
    }
}
