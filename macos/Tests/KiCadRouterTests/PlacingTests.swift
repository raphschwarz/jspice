import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// Texts and footprints placed on a board on their own (BoardEditing.addText and addFootprint), and texts edited,
/// moved, turned and taken away, each as one change; KiCad (its pcbnew module, tools/kicad-reference/placed.py) then
/// reads the board: each text as KiCad's Add Text would have made it on its layer (its size, pen, bold, italic, kept
/// upright, mirrored on the back, justified left and to the baseline), by the project's text defaults and by KiCad's
/// own where a project has none, where it was put, at its angle, its words as written; each footprint where it was
/// put, on the front, unturned, its reference and value the library's, board only, its pads on no net.
final class PlacingTests: XCTestCase {
    /// KiCad's reading of `files` (placed.py), nil where its pcbnew module is not to be had
    static func kicadReads(_ files: [URL]) throws -> [String: Any]? {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent("../../tools/kicad-reference/placed.py").standardized
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path] + files.map(\.path)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func testTextsAndFootprintsArePlacedAsKiCadPlacesThem() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-placing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let library = KiCadInstallation.find().flatMap { try? KiCadFootprintLibrary(installation: $0) }
        var written: [URL] = []
        var placedTexts: [String: (text: String, layer: String, at: KiCadPoint, angle: Double)] = [:]
        var placedFootprints: [String: (libID: String, at: KiCadPoint)] = [:]
        var edits = 0
        for (n, file) in try BoardEditingTests.boards().enumerated() {
            let board = try KiCadBoard.read(file)
            var project = BoardEditingTests.project(file)
            // (every other board's project of other text defaults: larger, a bolder pen, italic, upright; one with none)
            if n % 2 == 1, var p = project, var b = p["board"] as? [String: Any], var ds = b["design_settings"] as? [String: Any],
               var d = ds["defaults"] as? [String: Any] {
                d["silk_text_size_v"] = 1.6
                d["silk_text_size_h"] = 1.2
                d["silk_text_thickness"] = 0.25
                d["silk_text_italic"] = true
                d["copper_text_upright"] = true
                d["fab_text_thickness"] = 0.3
                ds["defaults"] = d
                b["design_settings"] = ds
                p["board"] = b
                project = p
            } else if n == 4 {
                project = nil
            }
            let session = BoardEditing(board: board, project: project)
            let layers = Set(board.root["layers"]?.items.compactMap { $0.text(at: 0) } ?? [])
            var k = 0
            for layer in ["F.SilkS", "B.SilkS", "F.Cu", "B.Cu", "F.Fab", "B.Fab", "Dwgs.User", "Cmts.User", "Edge.Cuts", "F.CrtYd"]
            where layers.contains(layer) {
                k += 1
                let at = KiCadPoint(100 + Double(k) * 1.234567, 50 + Double(n) * 2.000001)
                let text = k == 1 ? "JSpice \"\(n)\"\nrev 2" : "\(layer) \(n)"
                let angle = Double(k % 4) * 45
                let edit = try XCTUnwrap(session.addText(text, at: at, layer: layer, angle: angle), layer)
                XCTAssertEqual(edit.name, "Add Text")
                let uuid = try XCTUnwrap(edit.drawings.first)
                placedTexts[uuid] = (text, layer, at, angle)
                edits += 1
            }
            XCTAssertNil(session.addText("  \n", at: KiCadPoint(1, 1), layer: "F.SilkS"), "nothing printable")
            // one text's words changed, one moved, one turned, one taken away
            let ids = Array(placedTexts.keys.filter { id in session.router.board.boardDrawings.contains { $0.value("uuid") == id } }).sorted()
            if ids.count >= 4 {
                XCTAssertNotNil(session.setText(ids[0], to: "Edited \(n)"))
                placedTexts[ids[0]]?.text = "Edited \(n)"
                XCTAssertNotNil(session.moveDrawings([ids[1]], by: KiCadPoint(0.5, -0.25)))
                let was = try XCTUnwrap(placedTexts[ids[1]]).at
                placedTexts[ids[1]]?.at = KiCadPoint(was.x + 0.5, was.y - 0.25)
                XCTAssertNotNil(session.rotateTexts([ids[2]]))
                let angle = try XCTUnwrap(placedTexts[ids[2]]).angle
                placedTexts[ids[2]]?.angle = BoardEditing.normalizedAngle(angle + 90)
                let gone = try XCTUnwrap(session.removeDrawings([ids[3]]))
                XCTAssertEqual(gone.drawings, [ids[3]])
                placedTexts[ids[3]] = nil
                edits += 4
            }
            // loose footprints from KiCad's library
            if let library {
                if n == 0 {
                    let found = library.search("r_0805 resistor_smd")
                    XCTAssertTrue(found.contains("Resistor_SMD:R_0805_2012Metric"), "\(found)")
                    XCTAssertTrue(found.allSatisfy { $0.lowercased().contains("r_0805") && $0.hasPrefix("Resistor_SMD:") })
                    XCTAssertEqual(library.search(""), [])
                }
                for (j, libID) in ["Resistor_SMD:R_0805_2012Metric", "MountingHole:MountingHole_3.2mm_M3", "TestPoint:TestPoint_Pad_D1.0mm"].enumerated() {
                    guard let footprint = try? library.footprint(libID) else { continue }
                    let at = KiCadPoint(120.123457 + Double(j) * 3, 60.5 + Double(n))
                    let edit = try XCTUnwrap(session.addFootprint(footprint, libID: libID, at: at))
                    XCTAssertEqual(edit.name, "Place Footprint")
                    placedFootprints[try XCTUnwrap(edit.footprints.first)] = (libID, at)
                    edits += 1
                }
            }
            // the texts carried onto the board's file as it was, by their ids
            let elsewhere = try KiCadBoard.read(file)
            elsewhere.carryDrawings(from: try KiCadBoard.read(file), to: session.router.board)
            XCTAssertEqual(Set(elsewhere.boardDrawings.map(\.compact)), Set(session.router.board.boardDrawings.map(\.compact)))
            let copy = work.appendingPathComponent(file.lastPathComponent)
            try session.router.board.write(to: copy)
            if let project {
                let data = try JSONSerialization.data(withJSONObject: project)
                try data.write(to: copy.deletingPathExtension().appendingPathExtension("kicad_pro"))
            }
            written.append(copy)
        }
        guard let read = try Self.kicadReads(written) else {
            if ProcessInfo.processInfo.environment["JSPICE_REQUIRE_KICAD"] != nil { return XCTFail("KiCad 10's pcbnew module is needed") }
            throw XCTSkip("KiCad's pcbnew module is not installed")
        }
        var texts = 0, footprints = 0
        for file in written {
            let board = try XCTUnwrap(read[file.path] as? [String: Any])
            for t in board["texts"] as? [[String: Any]] ?? [] {
                guard let uuid = t["uuid"] as? String, let ours = placedTexts[uuid] else { continue }
                texts += 1
                let what = "\(file.lastPathComponent) \(ours.layer) text"
                XCTAssertEqual(t["text"] as? String, ours.text, what)
                XCTAssertEqual(t["layer"] as? String, ours.layer, what)
                XCTAssertEqual((t["position"] as? [NSNumber])?.map(\.intValue), [BoardWorld.iu(ours.at.x), BoardWorld.iu(ours.at.y)], what)
                XCTAssertEqual((t["angle"] as? NSNumber)?.doubleValue ?? -1, ours.angle, accuracy: 1e-9, what)
                let expected = try XCTUnwrap(t["expected"] as? [String: Any])
                for key in ["size", "thickness", "bold", "italic", "upright", "mirrored", "justify"] {
                    XCTAssertEqual("\(t[key] ?? "")", "\(expected[key] ?? "")", "\(what) \(key)")
                }
            }
            for f in board["footprints"] as? [[String: Any]] ?? [] {
                guard let uuid = f["uuid"] as? String, let ours = placedFootprints[uuid] else { continue }
                footprints += 1
                let what = "\(file.lastPathComponent) \(ours.libID)"
                XCTAssertEqual(f["lib_id"] as? String, ours.libID, what)
                XCTAssertEqual((f["position"] as? [NSNumber])?.map(\.intValue), [BoardWorld.iu(ours.at.x), BoardWorld.iu(ours.at.y)], what)
                XCTAssertEqual((f["angle"] as? NSNumber)?.doubleValue, 0, what)
                XCTAssertEqual(f["layer"] as? String, "F.Cu", what)
                XCTAssertEqual(f["board_only"] as? Bool, true, what)
                XCTAssertEqual(f["nets"] as? [String], (f["pads"] as? Int ?? 0) > 0 ? [""] : [], what)
                // its reference and value as the library has them
                let footprint = try XCTUnwrap(library?.footprint(ours.libID))
                let fields = Dictionary(footprint.all("property").compactMap { p in p.text(at: 0).map { ($0, p.text(at: 1) ?? "") } },
                                        uniquingKeysWith: { _, b in b })
                XCTAssertEqual(f["reference"] as? String, fields["Reference"], what)
                XCTAssertEqual(f["value"] as? String, fields["Value"], what)
            }
        }
        print("placing: \(written.count) boards, \(edits) changes, KiCad read \(texts) texts and \(footprints) footprints as placed")
        XCTAssertEqual(texts, placedTexts.count)
        XCTAssertEqual(footprints, placedFootprints.count)
        XCTAssertGreaterThan(texts, 0)
    }
}
