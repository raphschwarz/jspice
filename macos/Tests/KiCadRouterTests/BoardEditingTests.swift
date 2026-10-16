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

    /// A ground pour added, filled by KiCad, and taken away again
    func testAPourIsAddedAndFilledByKiCad() throws {
        let file = try XCTUnwrap(Self.boards().first)
        let session = BoardEditing(board: try KiCadBoard.read(file), project: Self.project(file))
        let net = try XCTUnwrap(session.groundNets.first ?? session.router.world.netNames.values.sorted().first)
        let edit = try XCTUnwrap(session.addPour(net: net, layers: ["B.Cu"]))
        XCTAssertEqual(edit.zones.count, 1)
        let zone = try XCTUnwrap(edit.after.zones.first { $0.uuid == edit.zones[0] })
        XCTAssertEqual(zone.net, net)
        XCTAssertEqual(zone.layers, ["B.Cu"])
        XCTAssertEqual(zone.outline.count, 4)
        XCTAssertTrue(zone.fills.isEmpty)
        // KiCad reads it, fills it and saves the board
        if let kicad = KiCadInstallation.find(), kicad.major >= KiCadInstallation.minimumMajor {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-pour-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let copy = work.appendingPathComponent(file.lastPathComponent)
            try edit.after.write(to: copy)
            try? FileManager.default.copyItem(at: file.deletingPathExtension().appendingPathExtension("kicad_pro"),
                                              to: copy.deletingPathExtension().appendingPathExtension("kicad_pro"))
            try KiCadFabrication(installation: kicad).fillZones(copy)
            let filled = try KiCadBoard.read(copy)
            let back = try XCTUnwrap(filled.zones.first { $0.uuid == zone.uuid })
            XCTAssertFalse(back.fills.isEmpty, "KiCad filled the pour")
            XCTAssertEqual(back.net, net)
        }
        let removed = try XCTUnwrap(session.removeZones([zone.uuid]))
        XCTAssertEqual(removed.zones, [zone.uuid])
        XCTAssertFalse(removed.after.zones.contains { $0.uuid == zone.uuid })
    }

    /// The outline drawn round the parts: drawn where there was none, then drawn again round a part moved out, with
    /// the pour drawn to it
    func testTheOutlineIsFittedToTheParts() throws {
        let file = try XCTUnwrap(Self.boards().first)
        let board = try KiCadBoard.read(file)
        for node in board.edgeDrawings { board.root.remove(node) }
        let session = BoardEditing(board: board, project: Self.project(file))
        let drawn = try XCTUnwrap(session.fitOutline())
        XCTAssertTrue(drawn.outline)
        XCTAssertEqual(drawn.after.edgeDrawings.count, 1)
        XCTAssertNil(session.fitOutline(), "already round the parts")
        let pour = try XCTUnwrap(session.addPour(net: try XCTUnwrap(session.router.world.netNames.values.sorted().first), layers: ["B.Cu"]))
        let edge = try XCTUnwrap(pour.after.edgeBounds)
        let footprint = try XCTUnwrap(session.board.footprints.first)
        _ = try XCTUnwrap(session.moveFootprints([footprint.uuid], by: KiCadPoint(edge.maxX - footprint.position.x + 20, 0)))
        let fitted = try XCTUnwrap(session.fitOutline())
        let box = try XCTUnwrap(fitted.after.edgeBounds)
        XCTAssertGreaterThan(box.maxX, edge.maxX + 15)
        XCTAssertEqual(box.maxX, box.maxX.rounded(), "on whole millimetres")
        let zone = try XCTUnwrap(fitted.after.zones.first { $0.uuid == pour.zones.first })
        XCTAssertEqual(zone.outline.map(\.x).max(), box.maxX, "the pour follows the outline")
        // carried onto a copy of the board as it was before
        let elsewhere = fitted.before.copy()
        elsewhere.carryOutline(from: fitted.before, to: fitted.after)
        elsewhere.carryZones(from: fitted.before, to: fitted.after)
        XCTAssertEqual(elsewhere.edgeBounds?.maxX, box.maxX)
        XCTAssertEqual(elsewhere.zones.first { $0.uuid == zone.uuid }?.outline.map(\.x).max(), box.maxX)
    }

    /// A keepout zone and another net's arc track in the way of a track: kept clear of (the port's stand-ins for
    /// KiCad's keepout triangles and arc items)
    func testKeepoutsAndArcTracksAreKeptClearOf() throws {
        let file = try XCTUnwrap(Self.boards().first)
        let board = try KiCadBoard.read(file)
        for node in board.copperItems { board.root.remove(node) }
        let box = try XCTUnwrap(board.edgeBounds)
        // a clear run along the board's middle: a keepout across it on the left, an arc of another net on the right
        let y = (box.minY + box.maxY) / 2, x0 = box.minX + 3, x1 = box.maxX - 3
        let kx = x0 + (x1 - x0) * 0.3, ax = x0 + (x1 - x0) * 0.7
        board.root.items.append(try SExpr.parse("""
            (zone (net 0) (net_name "") (layers "F.Cu" "B.Cu") (uuid "keepout-1") (hatch edge 0.5)
              (connect_pads (clearance 0)) (min_thickness 0.25) (filled_areas_thickness no)
              (keepout (tracks not_allowed) (vias not_allowed) (pads allowed) (copperpour allowed) (footprints allowed))
              (fill (thermal_gap 0.5) (thermal_bridge_width 0.5))
              (polygon (pts (xy \(kx - 1) \(y - 2)) (xy \(kx + 1) \(y - 2)) (xy \(kx + 1) \(y + 2)) (xy \(kx - 1) \(y + 2)))))
            """))
        let net = try XCTUnwrap(KiCadConnectivity(board).ratsnest().first?.net)
        board.addCopper(SExpr("arc", SExpr("start", ax, y - 2), SExpr("mid", ax + 1, y), SExpr("end", ax, y + 2), SExpr("width", 0.3),
                              SExpr("layer", "F.Cu"), board.netList(net, pad: false), SExpr("uuid", "arc-1")))
        let router = BoardRouter(board: board)
        XCTAssertTrue(router.unsupported.contains { $0.hasPrefix("keepout zone") })
        XCTAssertTrue(router.unsupported.contains { $0.hasPrefix("arc track") })
        let a = IPoint(Int(x0 * 1e6), Int(y * 1e6)), b = IPoint(Int(x1 * 1e6), Int(y * 1e6))
        guard router.start(at: a, layer: 0, width: 200_000) else { return XCTFail("no start") }
        router.move(to: b)
        let p = try XCTUnwrap(router.preview)
        let points = p.tail.points + p.head.points
        XCTAssertGreaterThan(points.count, 2, "the track goes round")
        let keepout = Shape.simple(LineChain([IPoint(Int((kx - 1) * 1e6), Int((y - 2) * 1e6)), IPoint(Int((kx + 1) * 1e6), Int((y - 2) * 1e6)),
                                              IPoint(Int((kx + 1) * 1e6), Int((y + 2) * 1e6)), IPoint(Int((kx - 1) * 1e6), Int((y + 2) * 1e6))], closed: true))
        let arc = Shape.arc(ShapeArc(start: IPoint(Int(ax * 1e6), Int((y - 2) * 1e6)), mid: IPoint(Int((ax + 1) * 1e6), Int(y * 1e6)),
                                     end: IPoint(Int(ax * 1e6), Int((y + 2) * 1e6)), width: 300_000))
        for (u, v) in zip(points, points.dropFirst()) {
            let track = Shape.segment(Seg(u, v), width: 200_000)
            XCTAssertFalse(track.collide(keepout, clearance: 0), "through the keepout: \(u) \(v)")
            XCTAssertFalse(track.collide(arc, clearance: 0), "over the arc: \(u) \(v)")
        }
    }

    /// Net classes read from the project, changed and added, as KiCad keeps them; the router takes the new widths
    func testNetClassesAreChangedAndTheRouterTakesThem() throws {
        var project = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(KiCadProject.projectFile(
            name: "t", netClasses: [.standard, KiCadProject.NetClass(name: "Power", trackWidth: 0.5, clearance: 0.2, viaDiameter: 0.8,
                                                                   viaDrill: 0.4, patterns: ["GND", "+*V"])]).utf8)) as? [String: Any])
        var classes = KiCadProject.netClasses(in: project)
        XCTAssertEqual(classes.map(\.name), ["Default", "Power"])
        XCTAssertEqual(classes[1].patterns, ["GND", "+*V"])
        XCTAssertEqual(classes[1].trackWidth, 0.5)

        var power = classes[1]
        power.trackWidth = 0.8
        power.patterns = ["GND"]
        KiCadProject.setNetClass(power, in: &project)
        KiCadProject.setNetClass(KiCadProject.NetClass(name: "Signal", trackWidth: 0.15, clearance: 0.15, patterns: ["SIG*"]), in: &project)
        classes = KiCadProject.netClasses(in: project)
        XCTAssertEqual(classes.map(\.name), ["Default", "Power", "Signal"])
        XCTAssertEqual(classes[1].trackWidth, 0.8)
        XCTAssertEqual(classes[1].patterns, ["GND"])
        XCTAssertEqual(classes[2].patterns, ["SIG*"])

        // the router reads them: a GND track 0.8 mm wide
        let file = try XCTUnwrap(Self.boards().first)
        let board = try KiCadBoard.read(file)
        let session = BoardEditing(board: board, project: nil)
        session.load(board, project: project)
        XCTAssertEqual(session.router.sizes(for: nil, net: "GND").trackWidth, 800_000)
        XCTAssertEqual(session.router.sizes(for: nil, net: "SIG1").trackWidth, max(150_000, session.router.world.minTrackWidth))
    }
}
