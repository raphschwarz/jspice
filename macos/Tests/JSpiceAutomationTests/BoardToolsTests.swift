import XCTest
import CircuitKit
import KiCadKit
@testable import JSpiceAutomation

/// The board tools an AI agent drives, on a board in its file (skipped where KiCad is not installed): the board made
/// beside the saved circuit, a footprint changed and taken to it, a value changed on the board and brought back to the
/// circuit and its file, a part deleted on the board and put back, footprints searched, the design rules checked and
/// a board house's files made
final class BoardToolsTests: XCTestCase {
    /// A board's zones filled in its file without KiCad, by the port of KiCad's zone filler: the blinker's ground pour,
    /// its fill taken away, filled again as KiCad fills it (FillTests checks the port's fill against KiCad's own)
    func testZonesAreFilledInTheBoardsFileWithoutKiCad() throws {
        let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../docs/pcb").standardized
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-board-fill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(at: docs.appendingPathComponent("blinker.kicad_pro"), to: folder.appendingPathComponent("blinker.kicad_pro"))
        let board = try KiCadBoard.read(docs.appendingPathComponent("blinker.kicad_pcb"))
        let filled = board.zones.filter { !$0.isRuleArea && !$0.fills.isEmpty }.map(\.uuid)
        XCTAssertFalse(filled.isEmpty)
        for zone in board.root.all("zone") { zone.remove("filled_polygon") }
        let file = folder.appendingPathComponent("blinker.kicad_pcb")
        try board.write(to: file)
        XCTAssertTrue(try KiCadBoard.read(file).zones.allSatisfy { $0.fills.isEmpty })

        let link = BoardLink(boardFile: file, installation: nil)
        let (after, engine) = try link.fillZonesReporting()
        XCTAssertEqual(engine, .port)
        let saved = try KiCadBoard.read(file)
        for uuid in filled {
            let zone = try XCTUnwrap(saved.zones.first { $0.uuid == uuid })
            XCTAssertFalse(zone.fills.isEmpty, "\(zone.net) filled again")
            XCTAssertEqual(zone.fills.map(\.points.count), after.zones.first { $0.uuid == uuid }?.fills.map(\.points.count))
        }
    }

    func testABoardMadeKeptInStepBothWaysCheckedAndMadeReadyForABoardHouse() throws {
        guard let kicad = KiCadInstallation.find(), kicad.problem == nil else { throw XCTSkip("KiCad 10 or later is not installed") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-board-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let session = CircuitSession(circuit: try XCTUnwrap(Examples.example("opamp")?.circuit))
        func call(_ name: String, _ arguments: [String: Any] = [:]) throws -> [String: Any] {
            try XCTUnwrap(session.call(name, arguments: arguments) as? [String: Any])
        }
        let boardFile = folder.appendingPathComponent("amp.kicad_pcb")

        // no file, no board
        XCTAssertThrowsError(try session.call("pcb_create", arguments: [:]))
        XCTAssertFalse((try call("pcb_status")["parts"] as? [Any] ?? []).isEmpty)

        let made = try call("pcb_create", ["path": folder.appendingPathComponent("amp.jspice").path, "style": "surface_mount"])
        XCTAssertEqual(made["board"] as? String, boardFile.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("amp.kicad_pro").path))
        XCTAssertThrowsError(try session.call("pcb_create", arguments: [:]), "a second board")
        XCTAssertEqual(try call("pcb_status")["in_step"] as? Bool, true)

        // a footprint chosen, taken to the board
        let resistor = try XCTUnwrap(session.circuit.elements.first { $0.kind == .resistor })
        XCTAssertEqual(try call("pcb_part", ["part": resistor.name, "footprint": "Resistor_SMD:R_1206_3216Metric"])["footprint"] as? String,
                       "Resistor_SMD:R_1206_3216Metric")
        XCTAssertEqual(try call("pcb_status")["in_step"] as? Bool, false)
        XCTAssertFalse((try call("pcb_update")["to_board"] as? [String] ?? []).isEmpty)
        let board = try KiCadBoard.read(boardFile)
        XCTAssertTrue(board.footprints.contains { $0.libID == "Resistor_SMD:R_1206_3216Metric" && $0.reference == resistor.name })
        XCTAssertEqual(try call("pcb_status")["in_step"] as? Bool, true)

        // a value changed on the board comes back, and is saved with the circuit
        try XCTUnwrap(board.footprints.first { $0.reference == resistor.name }).value = "22k"
        try board.write(to: boardFile)
        XCTAssertEqual((try call("pcb_update")["from_board"] as? [String])?.count, 1)
        XCTAssertEqual(session.circuit[resistor.id]?.params["resistance"], 22_000)
        let saved = try JSONDecoder().decode(Circuit.self, from: Data(contentsOf: folder.appendingPathComponent("amp.jspice")))
        XCTAssertEqual(saved[resistor.id]?.params["resistance"], 22_000)

        // deleted on the board: waiting, then put back
        let deleted = try KiCadBoard.read(boardFile)
        deleted.remove(try XCTUnwrap(deleted.footprints.first { $0.reference == resistor.name }))
        try deleted.write(to: boardFile)
        XCTAssertEqual((try call("pcb_status")["deleted_on_board"] as? [String])?.count, 1)
        _ = try call("pcb_update", ["put_back": [resistor.name]])
        XCTAssertTrue(try KiCadBoard.read(boardFile).footprints.contains { $0.reference == resistor.name })
        XCTAssertNotNil(session.circuit[resistor.id])

        XCTAssertTrue((try call("pcb_footprints", ["search": "SOIC-8 3.9x4.9"])["footprints"] as? [String] ?? [])
            .contains("Package_SO:SOIC-8_3.9x4.9mm_P1.27mm"))
        // nothing is routed yet
        XCTAssertGreaterThan(try call("pcb_drc")["unrouted"] as? Int ?? 0, 0)
        let files = try call("pcb_fabricate", ["maker": "jlcpcb"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(files["zip"] as? String)))
        XCTAssertNotNil(files["positions"])
    }

    /// The blinker's board (docs/pcb) without its tracks, routed by an agent with the PCB view's router, checked by
    /// KiCad's design rules check, and its tracks taken off again
    func testAnAgentRoutesTheBoardAndTakesTheTracksOffAgain() throws {
        guard let kicad = KiCadInstallation.find(), kicad.problem == nil else { throw XCTSkip("KiCad 10 or later is not installed") }
        let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../docs/pcb").standardized
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-board-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        for name in ["blinker.jspice", "blinker.kicad_pro"] {
            try FileManager.default.copyItem(at: docs.appendingPathComponent(name), to: folder.appendingPathComponent(name))
        }
        let board = try KiCadBoard.read(docs.appendingPathComponent("blinker.kicad_pcb"))
        for item in board.copperItems { board.root.remove(item) }
        try board.write(to: folder.appendingPathComponent("blinker.kicad_pcb"))
        let session = CircuitSession(circuit: try JSONDecoder().decode(Circuit.self, from: Data(contentsOf: folder.appendingPathComponent("blinker.jspice"))))
        session.fileURL = folder.appendingPathComponent("blinker.jspice")
        func call(_ name: String, _ arguments: [String: Any] = [:]) throws -> [String: Any] {
            try XCTUnwrap(session.call(name, arguments: arguments) as? [String: Any])
        }

        let unrouted = try XCTUnwrap(call("pcb_status")["unrouted"] as? Int)
        XCTAssertGreaterThan(unrouted, 0)
        // the signal tracks a little wider than the default class's
        let classes = try XCTUnwrap(call("pcb_net_class")["net_classes"] as? [[String: Any]])
        XCTAssertTrue(classes.contains { $0["name"] as? String == "Default" })
        let set = try XCTUnwrap(call("pcb_net_class", ["name": "Default", "track_width_mm": 0.3])["net_classes"] as? [[String: Any]])
        XCTAssertEqual(set.first { $0["name"] as? String == "Default" }?["track_width_mm"] as? Double, 0.3)
        XCTAssertThrowsError(try session.call("pcb_net_class", arguments: ["name": "Default", "via_drill_mm": 2]))
        XCTAssertThrowsError(try session.call("pcb_route", arguments: ["nets": ["NO_SUCH_NET"]]))
        let routed = try call("pcb_route", ["skip_nets": ["GND"]])
        let added = try XCTUnwrap(routed["tracks_and_vias_added"] as? Int)
        XCTAssertGreaterThan(added, 0)
        XCTAssertFalse((routed["routed"] as? [String] ?? []).isEmpty)
        XCTAssertFalse((routed["routed"] as? [String] ?? []).contains { $0.hasPrefix("GND:") })
        XCTAssertEqual(routed["changed_in"] as? String, "the board's file")
        XCTAssertLessThan(try XCTUnwrap(call("pcb_status")["unrouted"] as? Int), unrouted)
        XCTAssertEqual(try KiCadBoard.read(folder.appendingPathComponent("blinker.kicad_pcb")).copperItems.count, added)

        // ground poured on the bottom, filled as KiCad fills it (in the board's file, by the port of its filler): the
        // ground connections made by the pour
        let poured = try call("pcb_pour")
        XCTAssertEqual(poured["filled_by"] as? String, "JSpice")
        let zones = try XCTUnwrap(poured["zones"] as? [[String: Any]])
        XCTAssertTrue(zones.contains { $0["net"] as? String == "GND" && $0["filled"] as? Bool == true })
        XCTAssertLessThan(try XCTUnwrap(poured["unrouted"] as? Int), try XCTUnwrap(call("pcb_status")["unrouted"] as? Int) + 1)

        // the outline made larger, its corners rounded; the pour follows it, filled again
        let outline = try XCTUnwrap(call("pcb_outline")["outline"] as? [String: Any])
        let width = try XCTUnwrap(outline["width_mm"] as? Double), height = try XCTUnwrap(outline["height_mm"] as? Double)
        let shaped = try XCTUnwrap(call("pcb_outline", ["width_mm": width + 4, "height_mm": height + 2, "corner_radius_mm": 3])["outline"] as? [String: Any])
        XCTAssertEqual(shaped["width_mm"] as? Double, width + 4)
        XCTAssertEqual(shaped["corner_radius_mm"] as? Double, 3)
        let reshaped = try KiCadBoard.read(folder.appendingPathComponent("blinker.kicad_pcb"))
        XCTAssertEqual(reshaped.outlineRectangle?.radius, 3)
        XCTAssertTrue(reshaped.zones.contains { $0.net == "GND" && !$0.fills.isEmpty })
        // (the board came with a ground pour of its own, a little inside the outline; KiCad keeps zones in no set order)
        XCTAssertEqual(reshaped.zones.filter { $0.net == "GND" }.flatMap { $0.outline.map(\.x) }.max(), (outline["x_mm"] as? Double ?? 0) + width + 4)
        XCTAssertThrowsError(try session.call("pcb_outline", arguments: ["corner_radius_mm": 1000]))

        // mounting holes in its corners, kept by the schematic's updates
        let inStep = try call("pcb_status")["in_step"] as? Bool
        let holes = try XCTUnwrap(call("pcb_mounting_holes", ["screw": "M3"])["added"] as? [[String: Any]])
        XCTAssertEqual(holes.count, 4)
        XCTAssertEqual((try call("pcb_mounting_holes")["added"] as? [Any])?.count, 0, "each corner has one")
        XCTAssertThrowsError(try session.call("pcb_mounting_holes", arguments: ["screw": "M7"]))
        let holed = try KiCadBoard.read(folder.appendingPathComponent("blinker.kicad_pcb"))
        XCTAssertEqual(holed.footprints.filter { $0.attributes.contains("board_only") }.count, 4)
        let status = try call("pcb_status")
        XCTAssertEqual(status["in_step"] as? Bool, inStep, "the schematic's update leaves them: \(status["to_board"] ?? "")")
        XCTAssertFalse((status["to_board"] as? [String] ?? []).contains { $0.contains("H1") })
        XCTAssertThrowsError(try session.call("pcb_pour", arguments: ["layers": ["In7.Cu"]]))

        // the ground poured on the top too, and stitched to the bottom's
        let stitched = try call("pcb_pour", ["layers": ["top"], "stitch_pitch_mm": 5])
        XCTAssertGreaterThan(try XCTUnwrap(stitched["stitching_vias"] as? Int), 0)
        let stitchedBoard = try KiCadBoard.read(folder.appendingPathComponent("blinker.kicad_pcb"))
        XCTAssertTrue(stitchedBoard.vias.contains { $0.net == "GND" && $0.node.value("free") == "yes" })

        // KiCad finds nothing wrong with the tracks
        let drc = try call("pcb_drc")
        let wrong: Set<String> = ["clearance", "hole_clearance", "copper_edge_clearance", "tracks_crossing", "shorting_items",
                                  "track_width", "via_diameter", "annular_width"]
        let found = (drc["violations"] as? [[String: Any]] ?? []).filter { wrong.contains($0["type"] as? String ?? "") }
        XCTAssertTrue(found.isEmpty, "\(found)")

        let unroute = try call("pcb_unroute", ["all": true])
        XCTAssertEqual(unroute["removed"] as? Int, added + (stitched["stitching_vias"] as? Int ?? 0))
        XCTAssertThrowsError(try session.call("pcb_unroute", arguments: [:]))
    }
}
