import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// The footprint editor's footprint checker and its pad numbering against KiCad's own (tools/kicad-reference/
/// footprint-checker.py, on the footprints of Fixtures/footprints/checker)
final class FootprintCheckerTests: XCTestCase {
    static func folder() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["KICAD_CHECKER_REFERENCE"] { return URL(fileURLWithPath: path) }
        return try XCTUnwrap(Bundle.module.url(forResource: "checker", withExtension: nil, subdirectory: "Fixtures/footprints"))
    }

    static func json(_ url: URL) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    }

    // MARK: - Checks

    /// Footprints made faulty (pads over each other, touching, on other layers, of one number or net tie group; holes
    /// at one place and touching; every shape of pad; silk over pads and mask; footprints.py's faulty footprints of
    /// KiCad's libraries; random ones; some of KiCad's libraries as they are), opened in the editor from a library:
    /// the port's checker finds what KiCad's runChecks finds (footprint-checker.py checks: KiCad's own functions
    /// called as the dialog calls them), marker for marker in the same order, each of the same check, saying the same,
    /// of the same items, at the same place, of the severity the footprint editor gives it; and lists what the dialog
    /// lists (errors, then warnings, the ignored left out), as the dialog words it
    func testFootprintCheckerFindsWhatKiCadsFinds() throws {
        let folder = try Self.folder()
        let cases = try XCTUnwrap(Self.json(folder.appendingPathComponent("checks.json")) as? [String: [[String: Any]]])
        XCTAssertFalse(cases.isEmpty)
        var found: [String: Int] = [:]
        var failed = 0
        for (name, markers) in cases.sorted(by: { $0.key < $1.key }) {
            let text = try String(contentsOf: folder.appendingPathComponent("checks.pretty/\(name).kicad_mod"), encoding: .utf8)
            let editor = FootprintEditor(library: try SExpr.parse(text), libID: "checks:\(name)")
            let fpID = editor.footprint.value("uuid") ?? ""
            func describe(_ type: String, _ severity: String, _ detail: String, _ items: [String], _ at: [Int]) -> String {
                "\(type) [\(severity)] \(detail) \(items.map { $0 == fpID ? "footprint" : $0 }) @\(at)"
            }
            let theirs = markers.map { m in
                describe(m["type"] as? String ?? "", m["severity"] as? String ?? "", m["detail"] as? String ?? "",
                         m["items"] as? [String] ?? [], (m["at"] as? [NSNumber] ?? []).map(\.intValue))
            }
            let violations = editor.check()
            let ours = violations.map { describe($0.type, FootprintChecks.severity($0.type), $0.detail, $0.items, [$0.position.x, $0.position.y]) }
            if ours != theirs {
                failed += 1
                if failed <= 15 {
                    let first = zip(ours, theirs).first { $0 != $1 }
                    XCTFail("\(name): ours \(ours.count), KiCad's \(theirs.count); first differing: \(first.map { "ours \($0.0) | KiCad's \($0.1)" } ?? "(one has more) ours \(ours) KiCad's \(theirs)")")
                }
            }
            // (the dialog: errors before warnings, each kept in order, the ignored left out, "Error: " or "Warning: "
            // and the check's title and detail)
            let listed = markers.filter { ($0["severity"] as? String) != "ignore" }.enumerated().sorted {
                let a = $0.element["severity"] as? String == "error" ? 0 : 1, b = $1.element["severity"] as? String == "error" ? 0 : 1
                return a != b ? a < b : $0.offset < $1.offset
            }.map { m -> String in
                let type = m.element["type"] as? String ?? "", detail = m.element["detail"] as? String ?? ""
                return (m.element["severity"] as? String == "error" ? "Error: " : "Warning: ") + (FootprintChecks.titles[type] ?? type) + (detail.isEmpty ? "" : " " + detail)
            }
            XCTAssertEqual(FootprintChecks.reported(violations).map(\.text), listed, name)
            for m in markers { found[m["type"] as? String ?? "", default: 0] += 1 }
        }
        XCTAssertEqual(failed, 0, "of \(cases.count)")
        print("checked \(cases.count) footprints: \(found.sorted { $0.key < $1.key })")
        for type in ["shorting_items", "holes_co_located", "hole_to_hole", "silk_over_copper", "padstack", "malformed_courtyard"] {
            XCTAssertGreaterThan(found[type] ?? 0, 0, type)
        }
    }

    // MARK: - Renumber Pads

    /// A footprint of a board opened in KiCad's own footprint editor and renumbered with its Renumber Pads tool, the
    /// dialog's start, step and prefix set, pads clicked, clicked again, dragged over, over each other, ones that can
    /// have no number among them (footprint-checker.py renumber: KiCad's editor under Xvfb, the pointer's events as
    /// KiCad's tool had them): the port's editor, opened on the same footprint and told the same events, numbers
    /// every pad as KiCad did
    func testRenumberPadsNumbersThePadsAsKiCadsDoes() throws {
        let folder = try Self.folder().appendingPathComponent("renumber")
        let runs = try XCTUnwrap(Self.json(folder.appendingPathComponent("renumber.json")) as? [[String: Any]])
        XCTAssertFalse(runs.isEmpty)
        for run in runs {
            let n = try XCTUnwrap(run["run"] as? Int)
            let board = try KiCadBoard.read(folder.appendingPathComponent("renumber-\(n).kicad_pcb"))
            let fp = try XCTUnwrap(board.footprints.first)
            let editor = try XCTUnwrap(FootprintEditor(board: board, footprint: fp.uuid))
            let events = try (run["events"] as? [[Any]] ?? []).map { e -> FootprintEditor.PadEnumerationEvent in
                let xy = try XCTUnwrap(e[1] as? [NSNumber]).map { Int(($0.doubleValue * 1e6).rounded()) }
                let p = IPoint(xy[0], xy[1])
                switch e[0] as? String {
                case "motion": return .motion(p)
                case "down": return .down(p)
                case "drag": return .drag(p)
                case "up": return .up(p)
                default: return .click(p)
                }
            }
            // (the collector's accuracy: five of the view's pixels, as the status bar's readings make one)
            let scale = try XCTUnwrap(run["scale"] as? [NSNumber]).map(\.doubleValue)
            let accuracy = KiMath.round(5 * abs(scale[0]) * 1e6)
            editor.enumeratePads(events, start: run["start"] as? Int ?? 1, step: run["step"] as? Int ?? 1,
                                 prefix: run["prefix"] as? String ?? "", accuracy: accuracy, activeLayer: "F.SilkS")
            // (each pad by its place: KiCad's saving onto the board gives each pad the board's id of its number)
            var ours: [String: String] = [:]
            for pad in editor.footprint.all("pad") {
                let at = pad["at"]
                ours[String(format: "%.4f,%.4f", at?.number(at: 0) ?? 0, at?.number(at: 1) ?? 0)] = pad.text(at: 0) ?? ""
            }
            XCTAssertEqual(ours, run["numbers"] as? [String: String], "run \(n)")
            // (the dialog's spin controls: 0 to 999, as the app's steppers)
            let dialog = run["dialog"] as? [String: Any]
            XCTAssertEqual((dialog?["ranges"] as? [[Int]]) ?? [], [[0, 999], [0, 999]])
        }
    }

    // MARK: - Pad numbers

    /// Footprints of random pad numbers, and random last numbers (prefixes, question marks, leading zeros, numbers
    /// too long for an int, characters not ASCII): the port's next pad number after each (as a pad placed, or
    /// duplicated with Duplicate and Increment, is numbered) is KiCad's FOOTPRINT::GetNextPadNumber's
    /// (footprint-checker.py numbers)
    func testNextPadNumberIsKiCads() throws {
        let cases = try XCTUnwrap(Self.json(Self.folder().appendingPathComponent("numbers.json")) as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 100)
        var failed = 0
        for c in cases {
            let numbers = c["numbers"] as? [String] ?? []
            let fp = SExpr(list: [SExpr(symbol: "footprint"), SExpr(string: "x")] + numbers.map { SExpr(list: [SExpr(symbol: "pad"), SExpr(string: $0)]) })
            let ours = FootprintEditor.nextPadNumber(fp, after: c["last"] as? String ?? "")
            if ours != c["next"] as? String {
                failed += 1
                XCTFail("\(numbers) after \(c["last"] ?? ""): ours \(ours), KiCad's \(c["next"] ?? "")")
            }
        }
        XCTAssertEqual(failed, 0)
    }
}
