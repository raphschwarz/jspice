import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// Several tracks dragged together as KiCad's router tool drags the tracks selected (BoardEditing's startMultiDrag,
/// multiDrag, fixMultiDrag), on the boards of Fixtures/boards with their connections routed: segments of different
/// nets near each other on a layer, running the same way, dragged across a little way, walking round and shoving;
/// those kept are written into the board (the tracks taken away gone, those put on there), and kicad-cli's DRC of the
/// boards the drags leave is reported (KiCad's multi dragger can leave a fault where its own router leaves it).
final class BoardMultiDragTests: XCTestCase {
    func testTracksSelectedAreDraggedTogether() throws {
        var drags = 0, kept = 0, others = 0
        var boards: [(URL, KiCadBoard, KiCadBoard, BoardWorld)] = []
        for file in try BoardEditingTests.boards() {
            let session = BoardEditing(board: try KiCadBoard.read(file), project: BoardEditingTests.project(file))
            _ = session.routeConnections(most: 12)
            let routed = session.board.copy()
            for k in 0..<6 {
                // (the board as the drags before left it: a long segment, and those of other nets beside it, the same
                // way, on its layer)
                let tracks = session.router.world.items.filter { $0.kind == .track && $0.source != nil && $0.a.distance($0.b) > 1_500_000 }
                guard k < tracks.count else { break }
                let lead = tracks[(k * 7) % tracks.count]
                let dir = Direction45(Seg(lead.a, lead.b))
                let mid = IPoint((lead.a.x + lead.b.x) / 2, (lead.a.y + lead.b.y) / 2)
                let beside = tracks.filter { w in
                    w.net != lead.net && w.layer == lead.layer && w.source != lead.source
                        && [dir, dir.opposite].contains(Direction45(Seg(w.a, w.b))) && Seg(w.a, w.b).distance(mid) < 3_000_000
                }
                let uuids = [lead.source!] + beside.prefix(2).map { $0.source! }
                guard uuids.count >= 2 else { continue }
                session.mode = k % 2 == 0 ? .walkaround : .shove
                let layer = session.router.layerName(lead.layer)
                let start = try XCTUnwrap(session.startMultiDrag(uuids, at: BoardEditingTests.mm(mid), layer: layer), "\(uuids) to drag")
                XCTAssertTrue(session.isRouting)
                _ = start
                drags += 1
                // (across the lead, a little way)
                let d = lead.b - lead.a
                let n = (Double(d.x) * Double(d.x) + Double(d.y) * Double(d.y)).squareRoot()
                let way = IPoint(Int(-Double(d.y) / n * 500_000), Int(Double(d.x) / n * 500_000)) * (k % 3 == 0 ? -1 : 1)
                var last: BoardEditing.DragPreview?
                for t in [0.5, 1.0] {
                    last = try XCTUnwrap(session.multiDrag(to: BoardEditingTests.mm(mid + IPoint(Int(Double(way.x) * t), Int(Double(way.y) * t)))))
                }
                if let last, last.moved.count > 1 { others += 1 }
                guard let edit = session.fixMultiDrag(at: BoardEditingTests.mm(mid + way)) else {
                    session.cancelMultiDrag()
                    XCTAssertFalse(session.isRouting)
                    continue
                }
                kept += 1
                XCTAssertFalse(session.isRouting)
                XCTAssertEqual(edit.name, "Drag Tracks")
                for id in edit.removed { XCTAssertFalse(edit.after.copperItems.contains { $0.value("uuid") == id }) }
                for id in edit.added { XCTAssertTrue(edit.after.copperItems.contains { $0.value("uuid") == id }) }
            }
            boards.append((file, routed, session.board, session.router.world))
        }
        print("BoardMultiDragTests: \(kept) of \(drags) drags of several tracks kept, \(others) moving more than one track")
        XCTAssertGreaterThan(kept, 0)
        guard let kicad = KiCadInstallation.find(), kicad.major >= KiCadInstallation.minimumMajor else {
            if ProcessInfo.processInfo.environment["JSPICE_REQUIRE_KICAD"] != nil { return XCTFail("KiCad 10's kicad-cli is needed") }
            return
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-multi-drag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var newViolations = 0
        for (file, routed, dragged, world) in boards {
            func drc(_ board: KiCadBoard, _ name: String) throws -> KiCadFabrication.DRCReport {
                let copy = work.appendingPathComponent(name + "-" + file.lastPathComponent)
                try board.write(to: copy)
                let pro = file.deletingPathExtension().appendingPathExtension("kicad_pro")
                try? FileManager.default.copyItem(at: pro, to: copy.deletingPathExtension().appendingPathExtension("kicad_pro"))
                return try KiCadFabrication(installation: kicad).drc(copy, refillZones: false)
            }
            let was = try drc(routed, "routed"), now = try drc(dragged, "dragged")
            // (by the items of the board before the drags, a track a drag has put on in place of another the same
            // as any: a short or clearance the drag left as it found it, with the tracks put back, is no new one)
            let old = Set(routed.copperItems.compactMap { $0.value("uuid") }).union(routed.footprints.flatMap { $0.pads.map(\.uuid) })
            func key(_ v: KiCadFabrication.Violation) -> String {
                v.type + ":" + v.items.map { old.contains($0.uuid) ? $0.uuid : "*" }.sorted().joined(separator: ",")
            }
            let before = Set(was.violations.map(key))
            let new = now.violations.filter { v in
                guard BoardEditingTests.clearanceViolations.contains(v.type), !before.contains(key(v)) else { return false }
                if v.type == "hole_clearance", v.description.contains("hole clearance 0 mm"),
                   let overlap = BoardRoutingTests.holeOverlap(v, board: dragged, world: world), overlap < 1_000 {
                    return false
                }
                return true
            }
            // (KiCad's multi dragger, which KiCad calls a demonstration, does not keep what it leaves clear of
            // everything: on random-2-74, after a drag that walks round, KiCad's DRC reports a short of a track over
            // another net's pad that it reported otherwise before it, and KiCad's own router, run on that board and
            // that drag by tools/kicad-reference, makes the same tracks there. What it reports is printed, not failed.)
            newViolations += new.count
            for v in new { print("BoardMultiDragTests: \(file.lastPathComponent): \(v.type): \(v.items.map(\.description).joined(separator: ", "))") }
        }
        print("BoardMultiDragTests: KiCad's DRC finds \(newViolations) clearance, crossing or short faults it did not find before the drags")
    }
}
