import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// Footprints dragged with the tracks on their pads as KiCad's router tool drags them (BoardEditing's
/// startFootprintDrag, dragFootprint, fixFootprintDrag), on the boards of Fixtures/boards with their connections
/// routed: each footprint with tracks on its pads dragged from its origin a little way, the first of a few ways that
/// the dragger finds clear, and kept; the footprint moved in the board's file by the offset, its pads with it, each
/// track that ended on one of its pads' centres taken away and a track ending there where the pad is now. kicad-cli's
/// DRC of the boards the drags leave finds nothing too near that it did not find before them, and no more left
/// unconnected.
final class BoardFootprintDragTests: XCTestCase {
    /// A footprint's pads as the router has them (their ids, centres, layers and nets; holes without plating aside,
    /// which tracks are not on), and the tracks and arcs with an end on one of their centres, on a layer of the pad's,
    /// of its net (their ids)
    static func attachments(_ world: BoardWorld, _ fp: KiCadFootprint) -> (pads: [(String, IPoint, LayerRange, Int?)], tracks: Set<String>) {
        let uuids = Set(fp.pads.map(\.uuid))
        var pads: [(String, IPoint, LayerRange, Int?)] = []
        for w in world.items where w.kind == .pad && !w.npth {
            guard let id = w.source, uuids.contains(id), let p = w.pos, !pads.contains(where: { $0.0 == id }) else { continue }
            pads.append((id, p, w.layers, w.net))
        }
        var tracks = Set<String>()
        for w in world.items where w.kind == .track || w.kind == .arc {
            guard let id = w.source else { continue }
            if pads.contains(where: { ($0.1 == w.a || $0.1 == w.b) && $0.2.overlaps(w.layer) && $0.3 == w.net }) { tracks.insert(id) }
        }
        return (pads, tracks)
    }

    /// Whether the footprint has what KiCad's footprint drag leaves where it is, breaking a connection: a track of a
    /// pad's net ending inside the pad off its centre (COMPONENT_DRAGGER looks for those, but asks whether they collide
    /// with the pad, which one of its net never does), or a via on a pad (it drags only tracks)
    static func leavesBehind(_ world: BoardWorld, _ fp: KiCadFootprint) -> Bool {
        let uuids = Set(fp.pads.map(\.uuid))
        for pad in world.items where pad.kind == .pad && !pad.npth && uuids.contains(pad.source ?? "") {
            guard let shape = pad.shape, let centre = pad.pos else { continue }
            for w in world.items where w.net == pad.net {
                let ends = w.kind == .via ? [w.a] : w.kind == .track || w.kind == .arc ? [w.a, w.b] : []
                let layers = w.kind == .via ? w.layers : LayerRange(w.layer)
                guard layers.overlaps(pad.layers) else { continue }
                for e in ends where (w.kind == .via || e != centre) && shape.collide(.circle(center: e, radius: 0), clearance: 0) {
                    return true
                }
            }
        }
        return false
    }

    func testFootprintsAreDraggedWithTheTracksOnTheirPads() throws {
        var drags = 0, kept = 0, collided = 0, wholeTracks = 0, fanned = 0
        var boards: [(URL, KiCadBoard, KiCadBoard, BoardWorld)] = []
        for file in try BoardEditingTests.boards() {
            let session = BoardEditing(board: try KiCadBoard.read(file), project: BoardEditingTests.project(file))
            // (the board's connections routed, for tracks on the pads)
            _ = session.routeConnections(most: 12)
            let routed = session.board.copy()
            // (the footprints with the most tracks on their pads first; not those with a track or via KiCad's drag
            // leaves behind)
            let candidates = session.board.footprints.filter { !Self.leavesBehind(session.router.world, $0) }
                .map { ($0.uuid, Self.attachments(session.router.world, $0).tracks.count) }
                .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
            for (k, (uuid, _)) in candidates.prefix(4).enumerated() {
                guard let fp = session.board.footprint(uuid: uuid) else { continue }
                session.mode = k % 2 == 0 ? .shove : .walkaround
                let origin = fp.position
                // (the board as the drags before left it)
                let (pads, attached) = Self.attachments(session.router.world, fp)
                guard !attached.isEmpty, !Self.leavesBehind(session.router.world, fp) else { continue }
                // (a way that the drag finds clear of everything, of the few tried)
                var edit: BoardEditing.Edit?
                var offset = KiCadPoint.zero
                for (dx, dy) in [(0.6, 0.0), (0.0, 0.6), (-0.6, 0.0), (0.0, -0.6), (1.2, 1.2), (-1.2, 0.0), (0.0, 1.5)] {
                    let start = try XCTUnwrap(session.startFootprintDrag([uuid], at: origin), "\(fp.reference) to drag")
                    XCTAssertTrue(session.isRouting)
                    XCTAssertEqual(start.offset, .zero)
                    drags += 1
                    var last = start
                    for t in [0.5, 1.0] {
                        last = try XCTUnwrap(session.dragFootprint(to: KiCadPoint(origin.x + dx * t, origin.y + dy * t)))
                    }
                    // (the footprint goes from its origin to the grid point nearest the pointer)
                    XCTAssertEqual(last.offset.x, dx, accuracy: 0.05)
                    XCTAssertEqual(last.offset.y, dy, accuracy: 0.05)
                    XCTAssertEqual(last.footprints, [uuid])
                    for moved in last.moved { XCTAssertTrue(session.board.copperItems.contains { $0.value("uuid") == moved }) }
                    if last.collides {
                        // (a click there keeps nothing: the drag goes on, and is dropped)
                        XCTAssertNil(session.fixFootprintDrag(at: KiCadPoint(origin.x + dx, origin.y + dy)))
                        XCTAssertTrue(session.isRouting)
                        session.cancelFootprintDrag()
                        XCTAssertFalse(session.isRouting)
                        collided += 1
                        continue
                    }
                    if !last.tracks.isEmpty { fanned += 1 }
                    edit = try XCTUnwrap(session.fixFootprintDrag(at: KiCadPoint(origin.x + dx, origin.y + dy)), "\(fp.reference) kept")
                    offset = last.offset
                    break
                }
                guard let edit else { continue }
                kept += 1
                XCTAssertFalse(session.isRouting)
                XCTAssertEqual(edit.footprints, [uuid])
                XCTAssertEqual(edit.name, "Drag \(fp.reference)")
                // (the footprint moved by the offset in the board's file, its pads with it)
                let after = try XCTUnwrap(edit.after.footprint(uuid: uuid))
                XCTAssertEqual(after.position.x, origin.x + offset.x, accuracy: 1e-6)
                XCTAssertEqual(after.position.y, origin.y + offset.y, accuracy: 1e-6)
                let d = BoardEditing.nm(offset)
                let (padsAfter, _) = Self.attachments(session.router.world, after)
                for (id, p, _, _) in pads {
                    let q = try XCTUnwrap(padsAfter.first { $0.0 == id }?.1, "\(fp.reference) pad \(id)")
                    XCTAssertEqual(q, p + d, "\(fp.reference) pad \(id)")
                }
                // (each track that ended on one of its pads taken away, and a track ending on the pad where it is now)
                for id in attached { XCTAssertTrue(edit.removed.contains(id), "\(fp.reference): track \(id) on a pad dragged") }
                for id in edit.added { XCTAssertTrue(edit.after.copperItems.contains { $0.value("uuid") == id }) }
                let tracksAfter = session.router.world.items.filter { ($0.kind == .track || $0.kind == .arc) && edit.added.contains($0.source ?? "") }
                for w in session.router.world.items where (w.kind == .track || w.kind == .arc) && attached.contains(w.source ?? "") {
                    XCTFail("\(fp.reference): track \(w.source ?? "") left on the board")
                }
                for (id, p, layers, net) in pads where edit.before.copperItems.contains(where: { node in
                    attached.contains(node.value("uuid") ?? "") && (BoardWorld.point(node["start"]) == p || BoardWorld.point(node["end"]) == p)
                }) {
                    XCTAssertTrue(tracksAfter.contains { ($0.a == p + d || $0.b == p + d) && layers.overlaps($0.layer) && $0.net == net },
                                  "\(fp.reference) pad \(id): a track on it moved with it")
                }
                // (a track from one of its pads to another moved whole: the same, by the offset)
                for node in edit.before.copperItems where node.head == "segment" && attached.contains(node.value("uuid") ?? "") {
                    let a = BoardWorld.point(node["start"]), b = BoardWorld.point(node["end"])
                    if pads.contains(where: { $0.1 == a }) && pads.contains(where: { $0.1 == b }),
                       tracksAfter.contains(where: { $0.kind == .track && $0.a == a + d && $0.b == b + d }) {
                        wholeTracks += 1
                    }
                }
            }
            boards.append((file, routed, session.board, session.router.world))
        }
        print("BoardFootprintDragTests: \(kept) footprints dragged and kept, of \(drags) drags (\(collided) colliding, dropped), "
              + "\(fanned) with lines dragged out of their pads, \(wholeTracks) tracks moved whole")
        XCTAssertGreaterThan(kept, 3)
        XCTAssertGreaterThan(fanned, 0)
        guard let kicad = KiCadInstallation.find(), kicad.major >= KiCadInstallation.minimumMajor else {
            if ProcessInfo.processInfo.environment["JSPICE_REQUIRE_KICAD"] != nil { return XCTFail("KiCad 10's kicad-cli is needed") }
            return
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-footprint-drag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        for (file, routed, dragged, world) in boards {
            // (KiCad's DRC of the board routed, before the drags, and after them)
            func drc(_ board: KiCadBoard, _ name: String) throws -> KiCadFabrication.DRCReport {
                let copy = work.appendingPathComponent(name + "-" + file.lastPathComponent)
                try board.write(to: copy)
                let pro = file.deletingPathExtension().appendingPathExtension("kicad_pro")
                try? FileManager.default.copyItem(at: pro, to: copy.deletingPathExtension().appendingPathExtension("kicad_pro"))
                return try KiCadFabrication(installation: kicad).drc(copy, refillZones: false)
            }
            let was = try drc(routed, "routed"), now = try drc(dragged, "dragged")
            func key(_ v: KiCadFabrication.Violation) -> String { v.type + ":" + v.items.map(\.uuid).sorted().joined(separator: ",") }
            let before = Set(was.violations.map(key))
            let new = now.violations.filter { v in
                guard BoardEditingTests.clearanceViolations.contains(v.type), !before.contains(key(v)) else { return false }
                // (a hole clearance of 0: KiCad's router takes tracks along a hole's very edge, which its DRC finds
                // touching it, as BoardRoutingTests counts apart; one cutting into the hole is wrong)
                if v.type == "hole_clearance", v.description.contains("hole clearance 0 mm"),
                   let overlap = BoardRoutingTests.holeOverlap(v, board: dragged, world: world), overlap < 1_000 {
                    return false
                }
                return true
            }
            XCTAssert(new.isEmpty, "\(file.lastPathComponent): " + new.map { "\($0.type): \($0.description)" }.joined(separator: "; "))
            XCTAssertLessThanOrEqual(now.unconnected.count, was.unconnected.count, "\(file.lastPathComponent): connections broken: "
                                     + now.unconnected.map { $0.items.map(\.description).joined(separator: " / ") }.joined(separator: "; "))
        }
    }
}
