import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// KiCad's Highlight Net, the port's (NetHighlight) against KiCad's own: tools/kicad-reference/nets.py looks at each
/// board in KiCad's PCB editor from a random active copper layer, with inactive layers now and then dimmed or hidden
/// and now and then a copper layer, tracks, vias, pads, zones or a side's footprints hidden, moves the pointer to
/// points near the board's pads, tracks, vias and zones and anywhere on it and presses `: NAME.nets has where the
/// pointer was (on the view's pixels), the display's settings, and the net KiCad highlighted there, if any. The port
/// must pick the same net at the same points, with the same five pixels' accuracy. KICAD_NETS_REFERENCE names a folder
/// of such boards (or several, separated by colons); with none, Fixtures/nets.
final class NetHighlightTests: XCTestCase {
    private static var folders: [URL] {
        if let f = ProcessInfo.processInfo.environment["KICAD_NETS_REFERENCE"] {
            return f.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        return ["nets"].compactMap { Bundle.module.url(forResource: $0, withExtension: nil, subdirectory: "Fixtures") }
    }

    func testHighlightPicksAsKiCadsDoes() throws {
        let files = try Self.folders.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { $0.pathExtension == "kicad_pcb" }.sorted { $0.path < $1.path }
        var boards = 0, picks = 0, highlighted = 0, differences: [String] = []
        for file in files {
            let reference = file.deletingPathExtension().appendingPathExtension("nets")
            guard let data = try? Data(contentsOf: reference),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let h = json["highlight"] as? [String: Any], let transform = h["transform"] as? [String: Any],
                  let settingsData = try? JSONSerialization.data(withJSONObject: ["board": h["settings"] ?? [:]]),
                  let settings = KiCadJSON(text: String(decoding: settingsData, as: UTF8.self)) else { continue }
            let board = try KiCadBoard(text: String(contentsOf: file, encoding: .utf8))
            let projectURL = file.deletingPathExtension().appendingPathExtension("kicad_pro")
            let project = (try? Data(contentsOf: projectURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            var highlight = NetHighlight(board: board, project: project)
            // (KiROUND( 5 * OnePixelInIU ): the view's millimetres to the pixel, as the pointer's readings make them)
            let sx = abs((transform["sx"] as? NSNumber)?.doubleValue ?? 0)
            let guide = NetHighlight.Guide(appearance: KiCadBoardAppearance(json: settings), accuracy: KiMath.round(5 * sx * 1e6))
            boards += 1
            for entry in h["picks"] as? [[String: Any]] ?? [] {
                guard let world = entry["world"] as? [NSNumber], let on = entry["on"] as? Bool else { continue }
                let p = IPoint(KiMath.round(world[0].doubleValue * 1e6), KiMath.round(world[1].doubleValue * 1e6))
                // (the board's highlighted nets by name where nets.py read them, else the net inspector's selection,
                // which has no row for a net of no pads, tracks or vias)
                let codes = entry["codes"] as? [[Any]]
                let theirs = codes.map { $0.compactMap { $0.last as? String } } ?? entry["nets"] as? [String] ?? []
                let ours = highlight.pick(at: p, guide: guide)
                picks += 1
                if on { highlighted += 1 }
                let mine = ours.map { codes != nil || $0.code > 0 ? [$0.name] : [] } ?? []
                if (ours != nil) != on || mine != theirs {
                    differences.append("\(file.lastPathComponent) at \(p): KiCad \(on ? theirs.description : "none"), ours \(ours.map { "\($0.name) (\($0.code))" } ?? "none")")
                }
            }
        }
        print("net highlight: \(boards) boards, \(picks) points, \(highlighted) highlighted by KiCad, \(differences.count) differences")
        XCTAssertGreaterThan(picks, 0)
        XCTAssertEqual(differences, [], differences.prefix(40).joined(separator: "\n"))
    }
}
