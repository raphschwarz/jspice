import XCTest
import CircuitKit
import KiCadKit
@testable import JSpiceAutomation

/// The board tools an AI agent drives, on a board in its file (skipped where KiCad is not installed): the board made
/// beside the saved circuit, a footprint changed and taken to it, a value changed on the board and brought back to the
/// circuit and its file, a part deleted on the board and put back, footprints searched, the design rules checked and
/// a board house's files made
final class BoardToolsTests: XCTestCase {
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
        XCTAssertThrowsError(try session.call("pcb_route", arguments: ["nets": ["NO_SUCH_NET"]]))
        let routed = try call("pcb_route", ["skip_nets": ["GND"]])
        let added = try XCTUnwrap(routed["tracks_and_vias_added"] as? Int)
        XCTAssertGreaterThan(added, 0)
        XCTAssertFalse((routed["routed"] as? [String] ?? []).isEmpty)
        XCTAssertFalse((routed["routed"] as? [String] ?? []).contains { $0.hasPrefix("GND:") })
        XCTAssertEqual(routed["changed_in"] as? String, "the board's file")
        XCTAssertLessThan(try XCTUnwrap(call("pcb_status")["unrouted"] as? Int), unrouted)
        XCTAssertEqual(try KiCadBoard.read(folder.appendingPathComponent("blinker.kicad_pcb")).copperItems.count, added)

        // KiCad finds nothing wrong with the tracks
        let drc = try call("pcb_drc")
        let wrong: Set<String> = ["clearance", "hole_clearance", "copper_edge_clearance", "tracks_crossing", "shorting_items",
                                  "track_width", "via_diameter", "annular_width"]
        let found = (drc["violations"] as? [[String: Any]] ?? []).filter { wrong.contains($0["type"] as? String ?? "") }
        XCTAssertTrue(found.isEmpty, "\(found)")

        let unroute = try call("pcb_unroute", ["all": true])
        XCTAssertEqual(unroute["removed"] as? Int, added)
        XCTAssertEqual(try call("pcb_status")["unrouted"] as? Int, unrouted)
        XCTAssertThrowsError(try session.call("pcb_unroute", arguments: [:]))
    }
}
