import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// The nets' colours and hidden ratsnest, the port's (KiCadRouter's NetDisplay, KiCadKit's KiCadNetColors and
/// KiCadAppearanceControls) against KiCad's own: tools/kicad-reference/netdisplay.py opens each board in KiCad's PCB
/// editor twice (first with no .kicad_prl, then on what the first left), does random steps in the Nets tab of its
/// Appearance panel (a net's or a net class's colour set with the colour picker or cleared, a net's or a net class's
/// eye clicked, the net colour mode chosen), saves the board with File > Save twice and closes the editor:
/// NAME.netdisplay has each run's steps and the .kicad_pro and .kicad_prl as each of the three left them. The port,
/// opening the board on the same files and doing the same steps, must come to the same project colours (each net's,
/// each class's) and the same local settings, written out to the same text.
/// KICAD_NETDISPLAY_REFERENCE names a folder of such boards (or several, separated by colons); with none,
/// Fixtures/nets (the net inspector's boards, which have theirs).
final class NetDisplayTests: XCTestCase {
    private static var folders: [URL] {
        if let f = ProcessInfo.processInfo.environment["KICAD_NETDISPLAY_REFERENCE"] {
            return f.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        return ["nets"].compactMap { Bundle.module.url(forResource: $0, withExtension: nil, subdirectory: "Fixtures") }
    }

    /// The project's colours as a file has them: each net's, each class's, as written
    private static func colors(_ text: String?) -> (nets: [String: String], classes: [String: String])? {
        guard let text, let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let ns = json["net_settings"] as? [String: Any] ?? [:]
        let nets = (ns["net_colors"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        var classes: [String: String] = [:]
        for c in ns["classes"] as? [[String: Any]] ?? [] {
            if let name = c["name"] as? String, let color = c["pcb_color"] as? String { classes[name] = color }
        }
        return (nets, classes)
    }

    private static func project(_ text: String?) -> [String: Any]? {
        text.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    func testNetsTabAsKiCadsTakesIt() throws {
        let files = try Self.folders.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { $0.pathExtension == "kicad_pcb" }.sorted { $0.path < $1.path }
        var runs = 0, steps = 0, compared = 0, differences: [String] = []
        for file in files {
            let reference = file.deletingPathExtension().appendingPathExtension("netdisplay")
            guard let data = try? Data(contentsOf: reference),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["runs"] as? [[String: Any]] else { continue }
            let board = try KiCadBoard(text: String(contentsOf: file, encoding: .utf8))
            let layers = Set(KiCadLayers.enabled(board).map(\.id))
            for (n, r) in list.enumerated() {
                runs += 1
                let label = "\(file.lastPathComponent) run \(n + 1)"
                let opened = r["opened"] as? [String: Any] ?? [:]
                let local = KiCadLocalSettings(text: opened["prl"] as? String)
                let project = Self.project(opened["pro"] as? String)
                var controls = KiCadAppearanceControls(opening: local.board, boardLayers: layers)
                var display = NetDisplay(board: board, project: project, appearance: local.board)
                for step in r["steps"] as? [[Any]] ?? [] {
                    steps += 1
                    guard let kind = step.first as? String, let name = step.count > 1 ? step[1] as? String : nil else { continue }
                    let code = display.netCodes[name] ?? -1
                    switch kind {
                    case "netcolor": display.setNetColor(code, KiCadColor(hex: step[2] as? String ?? "") ?? .unspecified)
                    case "netclear": display.setNetColor(code, .unspecified)
                    case "neteye": display.toggleNet(code)
                    case "classcolor": display.setNetclassColor(name, KiCadColor(hex: step[2] as? String ?? "") ?? .unspecified)
                    case "classclear": display.setNetclassColor(name, .unspecified)
                    case "classeye":
                        let show = display.hiddenNetclasses.contains(name)
                        display.showNetclass(name, show)
                        controls.setNetclassHidden(name, !show)
                    case "colormode": controls.setNetColorMode(["None": 0, "Ratsnest": 1, "All": 2][name] ?? 1)
                    default: XCTFail("step \(kind)")
                    }
                }
                func check(_ what: String, _ texts: Any?, prl board: KiCadBoardAppearance, colors ours: KiCadNetColors) {
                    guard let texts = texts as? [String: Any] else { return }
                    if let theirs = texts["prl"] as? String {
                        compared += 1
                        var mine = local
                        mine.board = board
                        let a = KiCadJSON(text: theirs)?["board"]?.dump() ?? "", b = KiCadJSON(text: mine.text(projectName: "b"))?["board"]?.dump() ?? ""
                        if a != b { differences.append("\(label) \(what) .kicad_prl: KiCad\n\(a)\nours\n\(b)") }
                    }
                    if let theirs = Self.colors(texts["pro"] as? String) {
                        compared += 1
                        var written = project ?? [:]
                        ours.write(into: &written)
                        let mine = Self.colors(String(decoding: try! JSONSerialization.data(withJSONObject: written), as: UTF8.self))!
                        if theirs.nets != mine.nets || theirs.classes != mine.classes {
                            differences.append("\(label) \(what) .kicad_pro: KiCad \(theirs)\nours \(mine)")
                        }
                    }
                }
                // (File > Save: the hidden nets and the net colour mode as opened, the classes' colours and hidden
                // classes as they are; a second Save and closing the editor: the hidden nets as the view has them,
                // and closing, the nets' colours too)
                var saved = controls.saved
                saved.hiddenNetclasses = display.hiddenNetclassNames
                check("saved", r["saved"], prl: saved, colors: display.savedColors)
                var closed = controls.closed
                closed.hiddenNets = display.hiddenNetNames
                closed.hiddenNetclasses = display.hiddenNetclassNames
                check("saved again", r["saved_again"], prl: closed, colors: display.savedColors)
                check("closed", r["closed"], prl: closed, colors: display.closedColors)
            }
        }
        print("net display: \(runs) runs of KiCad, \(steps) steps, \(compared) files KiCad wrote, \(differences.count) differences")
        XCTAssertGreaterThan(compared, 0)
        XCTAssertEqual(differences, [], differences.prefix(4).joined(separator: "\n\n"))
    }

    /// Every .kicad_prl those runs of KiCad wrote (their hidden nets and net classes, their net colour modes), read
    /// and written again by the port: the same text, byte for byte
    func testTheirLocalSettingsWrittenAsKiCadWritesThem() throws {
        let files = try Self.folders.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { $0.pathExtension == "netdisplay" }
        var count = 0, differences: [String] = []
        for file in files {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
            for r in json?["runs"] as? [[String: Any]] ?? [] {
                for key in ["saved", "saved_again", "closed"] {
                    guard let text = (r[key] as? [String: Any])?["prl"] as? String else { continue }
                    count += 1
                    let mine = KiCadLocalSettings(text: text).text(projectName: "b")
                    if mine != text { differences.append("\(file.lastPathComponent) \(key): KiCad\n\(text)\nours\n\(mine)") }
                }
            }
        }
        XCTAssertGreaterThan(count, 0)
        XCTAssertEqual(differences, [], differences.prefix(2).joined(separator: "\n\n"))
    }

    /// Colours as KiCad reads and writes them (COLOR4D::SetFromWxString through wxColour, ToCSSString)
    func testColoursAsKiCadWritesThem() {
        XCTAssertEqual(KiCadColor(wxString: "rgba(0, 0, 0, 0.000)"), .unspecified)
        XCTAssertEqual(KiCadColor(wxString: "rgb(255, 0, 128)")?.css, "rgb(255, 0, 128)")
        XCTAssertEqual(KiCadColor(wxString: "rgba(12, 34, 56, 0.502)")?.css, "rgba(12, 34, 56, 0.502)")
        XCTAssertEqual(KiCadColor(wxString: "rgba(12,34,56,0.5)")?.bytes.a, 128)
        XCTAssertEqual(KiCadColor(wxString: "rgb(300, -4, 7)")?.css, "rgb(255, 0, 7)")
        XCTAssertEqual(KiCadColor(wxString: "#0A0B0C")?.css, "rgb(10, 11, 12)")
        XCTAssertNil(KiCadColor(wxString: "rgba(1, 2, 3, x)"))
        XCTAssertEqual(KiCadColor(hex: "#11223380")?.css, "rgba(17, 34, 51, 0.502)")
        XCTAssertEqual(KiCadColor.unspecified.css, "rgba(0, 0, 0, 0.000)")
    }
}
