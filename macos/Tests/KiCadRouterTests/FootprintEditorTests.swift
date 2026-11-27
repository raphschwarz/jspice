import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// The footprint editor (FootprintFormat, FootprintEditor, FootprintChecks, FootprintExchange) against KiCad
/// (tools/kicad-reference/footprints.py, on the footprints and boards of Fixtures/footprints)
final class FootprintEditorTests: XCTestCase {
    static func folder() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["KICAD_FOOTPRINT_REFERENCE"] { return URL(fileURLWithPath: path) }
        return try XCTUnwrap(Bundle.module.url(forResource: "footprints", withExtension: nil, subdirectory: "Fixtures"))
    }

    static func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// Two footprint files' texts as they are compared: each id one of them has made anew (not in `source`, the text
    /// both were made from) taken as the other's at the same place, those of each being new; nil where they differ
    /// otherwise
    static func uuids(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "\\(uuid \"([0-9a-f-]+)\"\\)")
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    static func masked(_ text: String, keeping source: Set<String>) -> String {
        var out = text
        for id in Set(uuids(text)) where !source.contains(id) {
            out = out.replacingOccurrences(of: "\"\(id)\"", with: "\"new\"")
        }
        return out
    }

    /// The first line two texts differ at, for a failure's message
    static func difference(_ a: String, _ b: String) -> String {
        let x = a.components(separatedBy: "\n"), y = b.components(separatedBy: "\n")
        for i in 0..<max(x.count, y.count) where (i < x.count ? x[i] : nil) != (i < y.count ? y[i] : nil) {
            return "line \(i + 1): ours \(i < x.count ? x[i] : "-") | KiCad's \(i < y.count ? y[i] : "-")"
        }
        return "same"
    }

    /// Whether ours and KiCad's texts of a footprint made from `source` are the same, the ids each made anew aside
    /// (the same places hold new ids in both)
    static func same(_ ours: String, _ kicad: String, source: String) -> (Bool, String) {
        let kept = Set(uuids(source))
        let a = masked(ours, keeping: kept), b = masked(kicad, keeping: kept)
        return (a == b, difference(a, b))
    }

    // MARK: - Saving

    /// The library footprints of `folder` (each LIB.pretty/NAME.kicad_mod) and KiCad's FootprintSave of each as it read
    /// it (footprints.py roundtrip: FootprintLoad keeping its ids, FootprintSave), in `kicad`
    func checkRoundTrip(source: URL, kicad: URL, limit: Int? = nil) throws -> Int {
        let fm = FileManager.default
        var checked = 0, failed = 0
        var kinds: [String: Int] = [:]
        for lib in try fm.contentsOfDirectory(atPath: source.path).sorted() where lib.hasSuffix(".pretty") {
            for file in try fm.contentsOfDirectory(atPath: source.appendingPathComponent(lib).path).sorted() where file.hasSuffix(".kicad_mod") {
                let ref = kicad.appendingPathComponent(lib).appendingPathComponent(file)
                guard let theirs = try? String(contentsOf: ref, encoding: .utf8) else { continue }
                let text = try String(contentsOf: source.appendingPathComponent(lib).appendingPathComponent(file), encoding: .utf8)
                let ours = FootprintFormat.libraryText(try SExpr.parse(text))
                Self.dump(ours, "roundtrip/\(lib)/\(file)")
                let (same, why) = Self.same(ours, theirs, source: text)
                checked += 1
                if !same {
                    failed += 1
                    kinds[why.split(separator: ":", maxSplits: 1).last.map(String.init) ?? why, default: 0] += 1
                    if failed <= 10 { XCTFail("\(lib)/\(file): \(why)") }
                }
                if let limit, checked >= limit { return checked }
            }
        }
        for (kind, n) in kinds.sorted(by: { $0.value > $1.value }).prefix(20) { print("\(n)\t\(kind)") }
        XCTAssertEqual(failed, 0, "of \(checked)")
        return checked
    }

    /// Footprints of KiCad's libraries, each written as FootprintSave writes it: the same text as KiCad's, byte for
    /// byte, the ids KiCad made anew (the mandatory fields' and those of items their file gave none) aside. With
    /// KICAD_FOOTPRINT_ROUNDTRIP (a folder of footprints.py roundtrip's of all of KiCad's libraries), every one.
    func testLibraryFootprintsSavedAsKiCadSavesThem() throws {
        if let all = ProcessInfo.processInfo.environment["KICAD_FOOTPRINT_ROUNDTRIP"] {
            let stock = ProcessInfo.processInfo.environment["KICAD_FOOTPRINT_DIR"] ?? "/usr/share/kicad/footprints"
            let n = try checkRoundTrip(source: URL(fileURLWithPath: stock), kicad: URL(fileURLWithPath: all))
            print("footprints saved as KiCad saves them: \(n)")
            return
        }
        let folder = try Self.folder().appendingPathComponent("roundtrip")
        let n = try checkRoundTrip(source: folder.appendingPathComponent("library"), kicad: folder.appendingPathComponent("kicad"))
        XCTAssertGreaterThan(n, 0)
    }

    /// KICAD_FOOTPRINT_DUMP: a folder the port's footprints are written into, for footprints.py readback
    static func dump(_ text: String, _ path: String) {
        guard let folder = ProcessInfo.processInfo.environment["KICAD_FOOTPRINT_DUMP"] else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Editing

    static func mm(_ v: Any?) -> KiCadPoint {
        let a = (v as? [NSNumber])?.map(\.doubleValue) ?? [0, 0]
        return KiCadPoint(a[0], a[1])
    }

    /// An item of the editor's footprint as footprints.py selects one: by its kind and its place among the
    /// footprint's (as it read them: pad:N, drawing:N, field:NAME); its id
    static func select(_ editor: FootprintEditor, _ sel: String) -> String {
        let parts = sel.split(separator: ":", maxSplits: 1).map(String.init)
        let fp = editor.footprint
        switch parts[0] {
        case "pad": return fp.all("pad")[Int(parts[1])!].value("uuid") ?? ""
        case "drawing":
            return fp.items.filter { BoardItems.footprintDrawings[$0.head ?? ""] != nil }[Int(parts[1])!].value("uuid") ?? ""
        default: return fp.all("property").first { $0.text(at: 0) == parts[1] }?.value("uuid") ?? ""
        }
    }

    /// footprints.py's edits done with the editor's own (FootprintEditor's moves, turns, deletions, pads placed,
    /// shapes and texts drawn, pad and footprint properties set, net tie groups, Save As's name)
    static func apply(_ editor: FootprintEditor, _ edit: [String: Any]) throws {
        let op = edit["op"] as? String ?? ""
        let items = (edit["items"] as? [String] ?? []).map { select(editor, $0) }
        switch op {
        case "move": editor.move(items, by: mm(edit["by"]))
        case "rotate": editor.rotate(items, about: mm(edit["about"]), degrees: (edit["degrees"] as? NSNumber)?.doubleValue ?? 0)
        case "delete": editor.delete(items)
        case "placePad": editor.placePad(at: mm(edit["at"]))
        case "shape":
            let kind: BoardShape.Kind = ["segment": .segment, "rectangle": .rectangle, "circle": .circle, "arc": .arc,
                                         "polygon": .polygon][edit["kind"] as? String ?? ""]!
            let width = BoardWorld.iu((edit["width"] as? NSNumber)?.doubleValue ?? 0)
            var s = BoardShape(kind: kind, layer: edit["layer"] as? String ?? "", width: width)
            let pts = (edit["points"] as? [Any] ?? []).map { BoardEditing.nm(mm($0)) }
            switch kind {
            case .arc: s.setArcGeometry(start: pts[0], mid: pts[1], end: pts[2])
            case .polygon: s.points = pts
            default: (s.start, s.end) = (pts[0], pts[1])
            }
            s.filled = edit["filled"] as? Bool ?? false
            editor.addShape(s)
        case "text": editor.addText(edit["text"] as? String ?? "", at: mm(edit["at"]), layer: edit["layer"] as? String ?? "")
        case "pad":
            let id = select(editor, edit["item"] as? String ?? "")
            var p = try XCTUnwrap(editor.padProperties(id))
            if let shape = edit["shape"] as? String { p.shape = PadProperties.Shape(rawValue: shape)! }
            if edit["size"] != nil { p.size = mm(edit["size"]) }
            if let d = (edit["drill"] as? NSNumber)?.doubleValue { p.drill = KiCadPoint(d, d) }
            if let r = (edit["ratio"] as? NSNumber)?.doubleValue { p.cornerRatio = r }
            XCTAssertTrue(editor.setPadProperties(id, p))
        case "describe":
            editor.setLibraryProperties(description: edit["description"] as? String ?? "", keywords: edit["keywords"] as? String ?? "")
        case "value":
            var p = try XCTUnwrap(editor.footprintProperties)
            let i = try XCTUnwrap(p.fields.firstIndex { $0.name == "Value" })
            p.fields[i].text = edit["text"] as? String ?? ""
            XCTAssertTrue(editor.setFootprintProperties(p))
        case "attributes":
            var p = try XCTUnwrap(editor.footprintProperties)
            let flags = Set(edit["flags"] as? [String] ?? [])
            p.mounting = flags.contains("smd") ? .smd : flags.contains("through_hole") ? .throughHole : .unspecified
            p.boardOnly = flags.contains("board_only")
            p.excludeFromBOM = flags.contains("exclude_from_bom")
            p.excludeFromPositionFiles = flags.contains("exclude_from_pos_files")
            XCTAssertTrue(editor.setFootprintProperties(p))
        case "netTie": editor.setNetTiePadGroups(edit["groups"] as? [String] ?? [])
        case "saveAs": editor.rename(edit["name"] as? String ?? "", library: editor.libraryName)
        default: XCTFail("no edit \(op)")
        }
    }

    /// Footprints of KiCad's libraries edited (footprints.py edits): each edit made with the editor's own, as
    /// KiCad's footprint editor makes it, and the footprint saved: the same text as KiCad's FootprintSave of the same
    /// edits made through its own model, byte for byte, the ids each made anew aside
    func testEditedFootprintsSavedAsKiCadSavesThem() throws {
        let folder = try Self.folder().appendingPathComponent("edits")
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("edits.json"))) as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let name = c["case"] as? String ?? ""
            let source = try String(contentsOf: folder.appendingPathComponent("library/\(name).kicad_mod"), encoding: .utf8)
            let editor = FootprintEditor(library: try SExpr.parse(source), libID: "\(c["library"] as? String ?? ""):\(c["footprint"] as? String ?? "")")
            for edit in c["edits"] as? [[String: Any]] ?? [] { try Self.apply(editor, edit) }
            let ours = editor.libraryText()
            let theirs = try String(contentsOf: folder.appendingPathComponent("kicad/\(name).kicad_mod"), encoding: .utf8)
            let (same, why) = Self.same(ours, theirs, source: source)
            XCTAssertTrue(same, "\(name): \(why)")
            XCTAssertEqual(FootprintEditor.fileURL(editor.name, in: URL(fileURLWithPath: "/")).lastPathComponent, c["saved"] as? String)
            Self.dump(ours, "edits/\(name).kicad_mod")
        }
    }

    // MARK: - Checks

    /// The footprint checks KiCad's board DRC makes as its footprint checker does (DRC_TEST_PROVIDER_FOOTPRINT_CHECKS'
    /// CheckFootprintAttributes, CheckPads, CheckNetTiePadGroups and a net tie's CheckNetTies; the courtyards'
    /// provider's malformed and missing courtyards); not CheckShortingPads, which the DRC leaves to its clearance checks
    static let drcFootprintChecks: Set<String> = ["footprint_type_mismatch", "pad_th_with_no_hole", "padstack",
                                                  "padstack_invalid", "footprint", "malformed_courtyard", "missing_courtyard",
                                                  "shorting_items"]

    /// Footprints of KiCad's libraries made faulty, each on a board of its own (footprints.py checks): the footprint
    /// checker's markers as KiCad's design rules check finds them (kicad-cli's, its footprint checks made errors), each
    /// of the same check, of the same items, saying the same
    func testFootprintChecksFindWhatKiCadsFind() throws {
        let folder = try Self.folder().appendingPathComponent("checks")
        let boards = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "kicad_pcb" }.sorted { $0.path < $1.path }
        XCTAssertFalse(boards.isEmpty)
        var found = 0
        for url in boards {
            let board = try KiCadBoard.read(url)
            let report = try Self.json(url.deletingPathExtension().appendingPathExtension("drc"))
            let fp = try XCTUnwrap(board.root.all("footprint").first)
            let netTie = FootprintChecks.isNetTie(fp)
            func key(_ type: String, _ detail: String, _ items: [String]) -> String { "\(type) \(detail) \(items.sorted())" }
            var theirs: [String] = []
            for v in report["violations"] as? [[String: Any]] ?? [] {
                let type = v["type"] as? String ?? ""
                let description = v["description"] as? String ?? ""
                // (a short between nets is the clearance checks')
                guard Self.drcFootprintChecks.contains(type), type != "shorting_items" || (netTie && !description.contains("(nets ")) else { continue }
                // (the description is the check's title, then its detail; a net tie's short names its nets)
                var detail = description.firstIndex(of: "(").map { String(description[$0...]) } ?? ""
                if type == "shorting_items" { detail = "" }
                let items = (v["items"] as? [[String: Any]] ?? []).compactMap { $0["uuid"] as? String }
                theirs.append(key(type, detail, items))
            }
            let drc = BoardDRC(board: board)
            let shorting = Set(FootprintChecks.shortingPads(fp, drc))
            var checked = FootprintChecks.run(board).filter { !shorting.contains($0) && Self.drcFootprintChecks.contains($0.type) }
            // (the checker reports a courtyard both malformed and so missing, the DRC's courtyard checks the first alone)
            if checked.contains(where: { $0.type == "malformed_courtyard" }) { checked.removeAll { $0.type == "missing_courtyard" } }
            let ours = checked.map { key($0.type, $0.detail, $0.items) }
            XCTAssertEqual(ours.sorted(), theirs.sorted(), url.lastPathComponent)
            found += theirs.count
        }
        XCTAssertGreaterThan(found, 0)
    }

    // MARK: - Updating from the library

    /// A board's footprints updated from their libraries (footprints.py update: KiCad's own PCB editor's Update
    /// Footprints from Library, with its own options, with every text kept but its clearance overrides and models,
    /// and with every reset as the footprint editor's Update Footprint on Board makes them): the port's update of
    /// the same board from the same libraries, with the same options, is KiCad's, byte for byte, the ids each made
    /// anew aside (those of items new to the board: pads, drawings and fields matched to none of the old ones)
    func testFootprintsUpdatedFromLibraryAsKiCadUpdatesThem() throws {
        let folder = try Self.folder().appendingPathComponent("update")
        let cases = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("update-") }.sorted()
        XCTAssertFalse(cases.isEmpty)
        let labels: [String: WritableKeyPath<FootprintExchange.Options, Bool>] = [
            "Remove text items if not in library footprint": \.deleteExtraTexts,
            "Update/reset text layers and visibilities": \.resetTextLayers,
            "Update/reset text sizes and styles": \.resetTextEffects,
            "Update/reset text positions": \.resetTextPositions,
            "Update/reset text content": \.resetTextContent,
            "Update/reset fabrication attributes": \.resetFabricationAttrs,
            "Update/reset clearance overrides": \.resetClearanceOverrides,
            "Update/reset 3D models": \.reset3DModels,
        ]
        for name in cases {
            let dir = folder.appendingPathComponent(name)
            let job = try Self.json(dir.appendingPathComponent("update.json"))
            var options = FootprintExchange.Options()
            for (label, value) in job["options"] as? [String: Bool] ?? [:] {
                if let path = labels[label] { options[keyPath: path] = value }
            }
            let table = try String(contentsOf: dir.appendingPathComponent("fp-lib-table"), encoding: .utf8)
            let library = KiCadFootprintLibrary(libraries: KiCadFootprintLibrary.parseTable(table, variables: ["KIPRJMOD": dir.path]))
            let before = try String(contentsOf: dir.appendingPathComponent("board.kicad_pcb"), encoding: .utf8)
            let board = try KiCadBoard(text: before)
            let report = FootprintExchange.updateFromLibrary(board, library: library, options: options)
            let theirs = try String(contentsOf: dir.appendingPathComponent("board-updated.kicad_pcb"), encoding: .utf8)
            // (the ids the libraries' files hold are not kept: the footprints are loaded with new ones)
            let (same, why) = Self.same(board.text, theirs, source: before)
            XCTAssertTrue(same, "\(name): \(why)")
            XCTAssertEqual(report.lines.count, board.footprints.count, name)
            Self.dump(board.text, "update/\(name).kicad_pcb")
        }
    }
}
