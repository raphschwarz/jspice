import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// A board's copper layer count changed as KiCad's Board Setup changes it (BoardEditing.setCopperLayerCount: the items
/// on the layers removed, the layer table, the stackup through the Physical Stackup page), against KiCad itself: each
/// BOARD.setup beside a board of Fixtures/boards, Fixtures/stackups and Fixtures/setup holds what KiCad's own dialog
/// made of it, step by step (tools/kicad-reference/boardsetup.py: from two layers to 4, 6 and 2; from four to 6, 2 and
/// 4; from six to 2, 8 and 4; from eight to 4 and 2), as KiCad saved it: its layer table, thickness and stackup, every
/// item's layers (a via's type, a zone's fills, a group's members) and every pad's; whether the dialog warned of items
/// on removed layers; and what kicad-cli's Gerber job file says of the stackup. The port makes the same steps on its
/// own boards, which must come out alike; and, where KiCad is installed, KiCad reads the port's boards (boardsetup.py
/// check) as it read its own, its job file of each the same, its stackup up to date. The project's pre-defined sizes,
/// put through the dialog's Pre-defined Sizes page, are written as KiCad's page wrote them, and the router takes each
/// as KiCad's track width menu does.
final class BoardSetupTests: XCTestCase {
    static func fixtures(_ ext: String) throws -> [URL] {
        var out: [URL] = []
        for folder in ["boards", "stackups", "setup"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: folder, withExtension: nil, subdirectory: "Fixtures"))
            out += try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).filter { $0.pathExtension == ext }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// KiCad's reading of `files` (boardsetup.py check), nil where its pcbnew module or kicad-cli is not to be had
    static func kicadChecks(_ files: [URL]) throws -> [String: Any]? {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent("../../tools/kicad-reference/boardsetup.py").standardized
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path, "check"] + files.map(\.path)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - A board summarized as boardsetup.py summarizes it

    static func tree(_ e: SExpr) -> Any { e.isList ? e.items.map(tree) : e.text }

    static let wildcards: [String: [String]] = ["F&B.Cu": ["F.Cu", "B.Cu"], "*.Mask": ["F.Mask", "B.Mask"],
                                                "*.Paste": ["F.Paste", "B.Paste"], "*.SilkS": ["F.SilkS", "B.SilkS"],
                                                "*.Adhes": ["F.Adhes", "B.Adhes"], "*.Fab": ["F.Fab", "B.Fab"],
                                                "*.CrtYd": ["F.CrtYd", "B.CrtYd"]]

    static func summary(_ board: KiCadBoard) -> [String: Any] {
        let root = board.root
        let table = Array(root["layers"]?.arguments ?? [])
        let enabled = Set(table.compactMap { $0.text(at: 0) })
        let copper = table.compactMap { $0.text(at: 0) }.filter { $0.hasSuffix(".Cu") }
        func expand(_ names: [String]) -> [String] {
            var out: Set<String> = []
            for n in names {
                if n == "*.Cu" { out.formUnion(copper) } else if n == "*In.Cu" { out.formUnion(copper.filter { $0.hasPrefix("In") }) } else { out.formUnion(wildcards[n] ?? [n]) }
            }
            return out.intersection(enabled).sorted()
        }
        var items: [String: Any] = [:]
        var pads: [String: Any] = [:]
        for node in root.arguments where node.isList {
            if node.head == "footprint" {
                let fid = node.value("uuid") ?? ""
                for (k, pad) in node.all("pad").enumerated() {
                    pads[fid + "/" + (pad.value("uuid") ?? String(k))] = expand(pad["layers"]?.arguments.map(\.text) ?? [])
                }
                continue
            }
            guard let uuid = node.value("uuid") else { continue }
            var entry: [String: Any] = ["kind": node.head ?? ""]
            if let layer = node["layer"] {
                entry["layers"] = expand([layer.text(at: 0) ?? ""])
            } else if let layers = node["layers"] {
                entry["layers"] = expand(layers.arguments.map(\.text))
            }
            if node.head == "via" {
                entry["type"] = node.arguments.first { $0.kind == .symbol && ["blind", "buried", "micro"].contains($0.text) }?.text ?? "through"
                entry["layers"] = node["layers"]?.arguments.map(\.text) ?? []
            }
            if node.head == "zone" {
                entry["fills"] = node.all("filled_polygon").compactMap { $0.value("layer") }.sorted()
                entry["filled"] = node["fill"]?.arguments.contains { $0.kind == .symbol && $0.text == "yes" } ?? false
                entry["properties"] = node.all("property").compactMap { $0.value("layer") }.sorted()
            }
            if node.head == "group" {
                entry["members"] = (node["members"]?.arguments.map(\.text) ?? []).sorted()
            }
            items[uuid] = entry
        }
        let thickness: Any = root["general"]?.value("thickness").map { $0 as Any } ?? NSNull()
        let stackup: Any = root["setup"]?["stackup"].map(tree) ?? NSNull()
        return ["layers": table.map(tree), "thickness": thickness, "stackup": stackup, "items": items, "pads": pads]
    }

    /// Where two summaries differ, as a path to the first difference
    static func difference(_ a: Any?, _ b: Any?, _ path: String = "") -> String? {
        switch (a, b) {
        case let (x as [String: Any], y as [String: Any]):
            for key in Set(x.keys).union(y.keys).sorted() {
                if let d = difference(x[key], y[key], path + "." + key) { return d }
            }
            return nil
        case let (x as [Any], y as [Any]):
            if x.count != y.count { return "\(path): \(x.count) entries, not \(y.count): \(x) / \(y)" }
            for (i, (p, q)) in zip(x, y).enumerated() {
                if let d = difference(p, q, path + "[\(i)]") { return d }
            }
            return nil
        case let (x as String, y as String):
            return x == y ? nil : "\(path): \(x) / \(y)"
        case let (x as NSNumber, y as NSNumber):
            return x == y ? nil : "\(path): \(x) / \(y)"
        case (nil, nil), (is NSNull, nil), (nil, is NSNull), (is NSNull, is NSNull):
            return nil
        default:
            if let x = a as? Bool, let y = b as? Bool { return x == y ? nil : "\(path): \(x) / \(y)" }
            return "\(path): \(a ?? "nothing") / \(b ?? "nothing")"
        }
    }

    // MARK: - Copper layers

    func testCopperLayerCountIsChangedAsKiCadsBoardSetupChangesIt() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let records = try Self.fixtures("setup")
        XCTAssertFalse(records.isEmpty)
        var written: [(URL, [String: Any])] = []
        var steps = 0, removed = 0, zones = 0
        for record in records {
            let kicad = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
            let file = record.deletingPathExtension().appendingPathExtension("kicad_pcb")
            let name = file.deletingPathExtension().lastPathComponent
            let session = BoardEditing(board: try KiCadBoard.read(file), project: BoardEditingTests.project(file))
            XCTAssertNil(session.setCopperLayerCount(session.layers.count), "\(name): the count it has")
            XCTAssertNil(session.setCopperLayerCount(3), "\(name): an odd count")
            for (k, step) in (kicad["steps"] as? [[String: Any]] ?? []).enumerated() {
                let n = try XCTUnwrap(step["copper"] as? Int)
                let what = "\(name) → \(n)"
                let warned = !session.itemsOnRemovedLayers(copperLayers: n).isEmpty
                XCTAssertEqual(warned, step["warned"] as? Bool, "\(what): KiCad's warning of items on removed layers")
                let edit = try XCTUnwrap(session.setCopperLayerCount(n), what)
                XCTAssertTrue(edit.setup)
                XCTAssertEqual(edit.name, "Change Copper Layer Count")
                XCTAssertEqual(session.layers, BoardStackup.copperNames(n), what)
                removed += edit.removed.count + edit.drawings.count
                zones += edit.zones.count
                let ours = Self.summary(session.board)
                if let d = Self.difference(ours, step["board"]) { XCTFail("\(what): \(d)") }
                // (the stackup up to date: as KiCad's job file writer finds it, nothing to bring to the board's layers)
                var stackup = BoardStackup.read(session.board).stackup
                XCTAssertFalse(stackup.synchronize(with: BoardStackup.BoardSettings(session.board)), "\(what): stackup up to date")
                XCTAssertEqual(step["upToDate"] as? Bool, true)
                // (the board written, read again, the same)
                let copy = work.appendingPathComponent("\(name)-\(k).kicad_pcb")
                try session.board.write(to: copy)
                if let d = Self.difference(Self.summary(try KiCadBoard.read(copy)), step["board"]) { XCTFail("\(what), read again: \(d)") }
                if let project = BoardEditingTests.project(file) {
                    try JSONSerialization.data(withJSONObject: project)
                        .write(to: copy.deletingPathExtension().appendingPathExtension("kicad_pro"))
                }
                written.append((copy, step))
                steps += 1
            }
        }
        print("BoardSetupTests: \(steps) steps on \(records.count) boards, \(removed) items taken away, \(zones) zones changed")
        guard let read = try Self.kicadChecks(written.map(\.0)) else {
            if ProcessInfo.processInfo.environment["JSPICE_REQUIRE_KICAD"] != nil { return XCTFail("KiCad 10's pcbnew and kicad-cli are needed") }
            throw XCTSkip("KiCad's pcbnew module or kicad-cli is not installed")
        }
        for (copy, step) in written {
            let theirs = try XCTUnwrap(read[copy.path] as? [String: Any], copy.lastPathComponent)
            for key in ["layers", "thickness", "stackup", "items", "pads"] {
                if let d = Self.difference(theirs[key], (step["board"] as? [String: Any])?[key], key) {
                    XCTFail("\(copy.lastPathComponent), as KiCad reads it: \(d)")
                }
            }
            XCTAssertEqual(theirs["upToDate"] as? Bool, true, "\(copy.lastPathComponent): KiCad's job file finds its stackup up to date")
            if let d = Self.difference(theirs["material"], step["material"], "MaterialStackup") {
                XCTFail("\(copy.lastPathComponent): \(d)")
            }
        }
        print("BoardSetupTests: \(written.count) of the port's boards read by KiCad as it read its own")
    }

    // MARK: - Pre-defined sizes

    func testPredefinedSizesAreWrittenAndTakenAsKiCadTakesThem() throws {
        var checked = 0
        for record in try Self.fixtures("setup") {
            let kicad = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
            guard let presets = kicad["presets"] as? [String: Any], let before = presets["before"] as? [String: Any],
                  let after = presets["after"] as? [String: Any] else { continue }
            var project: [String: Any] = ["board": ["design_settings": before]]
            let sizes = KiCadProject.PredefinedSizes(project)
            XCTAssertNil(sizes.problem)
            KiCadProject.setPredefinedSizes(sizes, in: &project)
            let ds = (project["board"] as? [String: Any])?["design_settings"] as? [String: Any]
            for key in ["track_widths", "via_dimensions"] {
                if let d = Self.difference(ds?[key], after[key], key) { XCTFail("\(record.lastPathComponent): \(d)") }
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
        // what the page refuses
        typealias Sizes = KiCadProject.PredefinedSizes
        XCTAssertEqual(Sizes(vias: [.init(diameter: 0.6, drill: 0.6)]).problem, "Via hole size must be smaller than via diameter")
        XCTAssertEqual(Sizes(vias: [.init(diameter: 0.0005, drill: 0.3)]).problem, "Via diameter is too small.")
        XCTAssertEqual(Sizes(vias: [.init(diameter: 0.6, drill: 0)]).problem, "Via drill is too small.")
        XCTAssertNotNil(Sizes(trackWidths: [0]).problem)
        // a project with none: none, and the lists KiCad's page writes of none
        XCTAssertEqual(Sizes(nil), Sizes())
        var empty: [String: Any] = [:]
        KiCadProject.setPredefinedSizes(Sizes(), in: &empty)
        let eds = (empty["board"] as? [String: Any])?["design_settings"] as? [String: Any]
        XCTAssertEqual(eds?["track_widths"] as? [Double], [0])
        XCTAssertEqual((eds?["via_dimensions"] as? [[String: Double]])?.count, 1)
    }

    func testThePredefinedSizeChosenIsWhatTheRouterTakes() throws {
        let file = try XCTUnwrap(Self.fixtures("kicad_pcb").first { $0.lastPathComponent == "random-2-15.kicad_pcb" })
        var project = try XCTUnwrap(BoardEditingTests.project(file))
        let sizes = KiCadProject.PredefinedSizes(trackWidths: [0.35, 0.15, 0.5, 0.1234567],
                                                 vias: [.init(diameter: 0.9, drill: 0.45), .init(diameter: 0.5, drill: 0.25)])
        let session = BoardEditing(board: try KiCadBoard.read(file), project: project)
        let written = try XCTUnwrap(session.setPredefinedSizes(sizes))
        KiCadProject.setPredefinedSizes(sizes, in: &project)
        XCTAssertTrue(NSDictionary(dictionary: written).isEqual(to: project))
        XCTAssertEqual(session.predefinedSizes, sizes.sorted)
        XCTAssertNil(session.setPredefinedSizes(KiCadProject.PredefinedSizes(vias: [.init(diameter: 0.3, drill: 0.4)])))
        let minimum = session.router.world.minTrackWidth
        // a track started where the board has nothing, with each width chosen
        let box = try XCTUnwrap(session.board.edgeBounds)
        let start = KiCadPoint(box.minX + 3, box.maxY - 3)
        var routed: [Int] = []
        for choice in 0...(sizes.trackWidths.count + 1) {
            session.sizeChoice = .init(track: choice, via: min(choice, sizes.vias.count))
            XCTAssertTrue(session.start(at: start, layer: "F.Cu"))
            let preview = try XCTUnwrap(session.move(to: KiCadPoint(start.x + 5, start.y)))
            let width = Int((preview.width * 1e6).rounded())
            routed.append(width)
            if choice > 0 && choice <= sizes.trackWidths.count {
                XCTAssertEqual(width, max(minimum, Int((sizes.sorted.trackWidths[choice - 1] * 1e6).rounded())), "track \(choice)")
                if choice <= sizes.vias.count {
                    XCTAssertEqual(Int((preview.viaSize * 1e6).rounded()), Int((sizes.sorted.vias[choice - 1].diameter * 1e6).rounded()))
                }
            } else {
                // (the net class's, and a choice past the list's end too)
                XCTAssertEqual(width, routed[0], "track \(choice)")
            }
            session.cancel()
        }
        // KiCad's own reading of the project's lists, as its track width menu picks them
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-sizes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let copy = work.appendingPathComponent("sizes.kicad_pcb")
        try session.board.write(to: copy)
        try JSONSerialization.data(withJSONObject: written).write(to: copy.deletingPathExtension().appendingPathExtension("kicad_pro"))
        guard let read = try Self.kicadChecks([copy]), let kicad = (read[copy.path] as? [String: Any])?["sizes"] as? [String: Any] else {
            if ProcessInfo.processInfo.environment["JSPICE_REQUIRE_KICAD"] != nil { return XCTFail("KiCad 10's pcbnew and kicad-cli are needed") }
            throw XCTSkip("KiCad's pcbnew module or kicad-cli is not installed")
        }
        let tracks = try XCTUnwrap(kicad["tracks"] as? [Int]), vias = try XCTUnwrap(kicad["vias"] as? [[Int]])
        XCTAssertEqual(tracks.count, sizes.trackWidths.count + 1)
        XCTAssertEqual(vias.count, sizes.vias.count + 1)
        let kicadMinimum = try XCTUnwrap(kicad["trackMinWidth"] as? Int)
        for i in 1..<tracks.count {
            session.sizeChoice = .init(track: i, via: 0)
            XCTAssertEqual(session.chosenTrackWidth(), max(kicadMinimum, tracks[i]), "track width \(i)")
        }
        for i in 1..<vias.count {
            session.sizeChoice = .init(track: 0, via: i)
            let ours = try XCTUnwrap(session.chosenViaSize())
            XCTAssertEqual([ours.diameter, ours.drill], vias[i], "via \(i)")
        }
    }
}
