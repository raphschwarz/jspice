import Foundation
import XCTest
import KiCadKit

/// KiCad's Appearance panel and the board's part of the project's local settings, the port's (KiCadKit's
/// KiCadAppearanceControls, KiCadBoardAppearance and KiCadLocalSettings) against KiCad's own:
/// tools/kicad-reference/appearance.py opens each board in KiCad's PCB editor twice (first with no .kicad_prl, then on
/// the one the first left), clicks the panel's controls at random (layers' and objects' eyes, opacity sliders, the
/// inactive layers' mode, a layer's name, a built-in preset) and saves the board with File > Save twice:
/// NAME.appearance has each run's steps and the .kicad_prl as each Save left it. The port, opening the board on the
/// same settings and doing the same steps, must come to the same settings, and write them out to the same text;
/// and every file KiCad wrote, read by the port and written again, must come out as KiCad wrote it.
/// KICAD_APPEARANCE_REFERENCE names a folder of such boards (or several, separated by colons); with none,
/// Fixtures/nets (the net inspector's boards, which have theirs).
final class AppearanceTests: XCTestCase {
    private static var folders: [URL] {
        if let f = ProcessInfo.processInfo.environment["KICAD_APPEARANCE_REFERENCE"] {
            return f.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        return ["nets"].compactMap { Bundle.module.url(forResource: $0, withExtension: nil, subdirectory: "Fixtures") }
    }

    private struct Run {
        var file: URL
        var number: Int
        var steps: [[Any]]
        /// The local settings as the run opened the board (none on the first run)
        var before: String?
        var saved: String?
        var savedChanged: Bool
        /// The local settings as the second File > Save left them (as closing the editor writes them)
        var again: String?
        var layers: [(id: Int, name: String, canonical: String)]
    }

    private func runs() throws -> [Run] {
        let files = try Self.folders.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { $0.pathExtension == "kicad_pcb" }.sorted { $0.path < $1.path }
        var out: [Run] = []
        for file in files {
            let reference = file.deletingPathExtension().appendingPathExtension("appearance")
            guard let data = try? Data(contentsOf: reference),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let runs = json["runs"] as? [[String: Any]] else { continue }
            let board = try KiCadBoard(text: String(contentsOf: file, encoding: .utf8))
            let layers = KiCadLayers.enabled(board)
            var before: String?
            for (n, r) in runs.enumerated() {
                let again = r["saved_again"] as? String
                out.append(Run(file: file, number: n + 1, steps: r["steps"] as? [[Any]] ?? [], before: before,
                               saved: r["saved"] as? String, savedChanged: r["saved_changed"] as? Bool ?? false,
                               again: again, layers: layers))
                before = again ?? before
            }
        }
        return out
    }

    /// The board's settings at the end of each run as KiCad's File > Save writes them (the display options and active
    /// layer as the board was opened: KiCad writes the local settings before it copies the frame's into them), and as a
    /// second one leaves them (as closing the editor writes them), the port's by the same steps
    func testStepsAsKiCadsAppearancePanelTakesThem() throws {
        var runs = 0, steps = 0, files = 0, differences: [String] = []
        for run in try self.runs() {
            runs += 1
            let ids = Dictionary(run.layers.map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })
            let opened = KiCadLocalSettings(text: run.before)
            var controls = KiCadAppearanceControls(opening: opened.board, boardLayers: Set(run.layers.map(\.id)))
            for step in run.steps {
                steps += 1
                guard let kind = step.first as? String, let name = step.count > 1 ? step[1] as? String : nil else { continue }
                let item = KiCadBoardAppearance.objectRows.first { $0.title == name }?.item
                switch kind {
                case "layer": if let id = ids[name] { controls.toggleLayer(id) }
                case "object": if let item { controls.setVisible(item, !controls.appearance.isVisible(item)) }
                case "opacity": if let item, let v = step[2] as? Int { controls.setOpacity(item, slider: v) }
                case "contrast":
                    controls.setHighContrast(["Normal": .normal, "Dim": .dimmed, "Hide": .hidden][name] ?? .normal)
                case "active": if let id = ids[name] { controls.setActiveLayer(id) }
                case "preset": controls.applyPreset(name)
                default: XCTFail("step \(kind)")
                }
            }
            let label = "\(run.file.lastPathComponent) run \(run.number)"
            func check(_ theirs: String?, _ board: KiCadBoardAppearance, _ what: String) {
                guard let theirs else { return }
                files += 1
                // (the file KiCad had read, the port's settings written into it as KiCad writes them)
                var ours = opened
                ours.board = board
                let mine = ours.text(projectName: "b")
                let theirBoard = KiCadJSON(text: theirs)?["board"]?.dump() ?? ""
                let myBoard = KiCadJSON(text: mine)?["board"]?.dump() ?? ""
                if theirBoard != myBoard {
                    differences.append("\(label) \(what): KiCad\n\(theirBoard)\nours\n\(myBoard)")
                }
            }
            if run.savedChanged { check(run.saved, controls.saved, "saved") }
            check(run.again, controls.closed, "saved again")
        }
        print("appearance: \(runs) runs of KiCad, \(steps) steps, \(files) files KiCad wrote, \(differences.count) differences")
        XCTAssertGreaterThan(files, 0)
        XCTAssertEqual(differences, [], differences.prefix(6).joined(separator: "\n\n"))
    }

    /// Every .kicad_prl KiCad wrote, read and written again by the port: the same text, byte for byte. (KiCad writes
    /// a user layer made the active one, but reads back only F.Cu to F.Fab (its PARAM_ENUM's range), taking F.Cu for
    /// any other: such a file comes out with F.Cu, as KiCad would write it again; counted)
    func testLocalSettingsWrittenAsKiCadWritesThem() throws {
        var files = 0, userLayers = 0, differences: [String] = []
        for run in try self.runs() {
            for text in [run.saved, run.again].compactMap({ $0 }) {
                files += 1
                var theirs = text
                if var json = KiCadJSON(text: text), let active = json[path: "board.active_layer"]?.int, !(0...35).contains(active) {
                    json[path: "board.active_layer"] = .integer(0)
                    theirs = json.dump() + "\n"
                    userLayers += 1
                }
                let mine = KiCadLocalSettings(text: text).text(projectName: "b")
                if mine != theirs { differences.append("\(run.file.lastPathComponent) run \(run.number): KiCad\n\(theirs)\nours\n\(mine)") }
            }
        }
        print("local settings: \(files) files KiCad wrote, \(userLayers) of a user layer active, \(differences.count) written otherwise")
        XCTAssertGreaterThan(files, 0)
        XCTAssertEqual(differences, [], differences.prefix(2).joined(separator: "\n\n"))
    }

    /// LSET's hexadecimal form both ways (FmtHex, ParseHex), as the files have it
    func testLayerSetsInKiCadsHex() {
        var set = KiCadLayers.Set128.all
        set.remove(33)
        set.remove(27)
        set.remove(29)
        XCTAssertEqual(set.hex, "ffffffff_ffffffff_fffffffd_d7ffffff")
        XCTAssertEqual(KiCadLayers.Set128(hex: set.hex), set)
        XCTAssertEqual(KiCadLayers.Set128(hex: "5"), KiCadLayers.Set128([0, 2]))
        XCTAssertNil(KiCadLayers.Set128(hex: "zz"))
    }
}
