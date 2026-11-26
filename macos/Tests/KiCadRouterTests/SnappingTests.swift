import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// Where the pointer snaps to the board's items, the port's (BoardSnapping.swift: PCBGridHelper on a SnapBoard)
/// against KiCad's own: tools/kicad-reference/snapping.py draws lines with KiCad's Draw Lines tool, the pointer moved
/// to pixels near the board's pads, tracks, vias, footprints, zones and graphics (and level with them, and anywhere)
/// and clicked, with the Magnetic Points snapping to pads, tracks and graphics always and KiCad 10's extension snaps
/// off, some boards opened on local settings that dim the inactive layers or hide objects; NAME.snapped has every
/// event and the lines KiCad drew. The port, given the same pointer positions (the view's
/// transform applied to the pixels) in the same order, a grid helper of its own for each line as each Draw Lines has
/// one, and the board as it then was (the lines drawn before on it), must put each line's ends where KiCad did, to the
/// nanometre. KICAD_SNAPPING_REFERENCE names a folder of such boards (or several, separated by colons); with none,
/// Fixtures/snapping.
final class SnappingTests: XCTestCase {
    private static var folders: [URL] {
        if let f = ProcessInfo.processInfo.environment["KICAD_SNAPPING_REFERENCE"] {
            return f.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        return ["snapping"].compactMap { Bundle.module.url(forResource: $0, withExtension: nil, subdirectory: "Fixtures") }
    }

    func testDrawnLinesEndWhereKiCadSnapsThem() throws {
        let files = try Self.folders.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { $0.pathExtension == "snapped" }.sorted { $0.path < $1.path }
        var lines = 0, snappedToItems = 0, unsure = 0, missed = 0, differences: [String] = []
        for file in files {
            guard let record = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
                  let events = record["events"] as? [[String: Any]], let t = record["transform"] as? [String: Double] else { continue }
            let boardURL = file.deletingPathExtension().appendingPathExtension("kicad_pcb")
            let text = try String(contentsOf: boardURL, encoding: .utf8)
            let project = (try? Data(contentsOf: file.deletingPathExtension().appendingPathExtension("kicad_pro")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let made = record["made"] as? [String: [String]] ?? [:]
            // (the local settings the board was opened on, if the plan gave it any)
            let local = KiCadLocalSettings(text: (record["plan"] as? [String: Any])?["prl"] as? String)
            let drawn = record["lines"] as? [String: [String: Any]] ?? [:]
            var magnetic = MagneticSettings()
            magnetic.pads = .captureAlways
            magnetic.tracks = .captureAlways
            magnetic.graphics = true
            // (the lines drawn before each step, on the board as it then was)
            var before: [String] = []
            var step: Int?
            var helper: PCBGridHelper?
            var view: SnapView?
            var clicks: [IPoint] = []
            var pointer = IPoint.zero
            var raw = (0.0, 0.0)
            var clickRaws: [(Double, Double)] = []
            // (a move KiCad's canvas did not see: the pointer gone off it, below or beside the view, the status bar
            // reading where it was before though the pointer went well away; not given to the port either)
            var lastPixel: [Int]?, lastReading: [Double]?, pendingMove: (IPoint, (Double, Double))?
            // (and the clicks there, which it did not see either)
            var offCanvas = false
            func point(_ e: [String: Any]) -> IPoint {
                let raw = e["raw"] as? [Double] ?? [0, 0]
                return IPoint(KiMath.round(raw[0]), KiMath.round(raw[1]))
            }
            for e in events {
                switch e["ev"] as? String {
                case "mark":
                    step = e["step"] as? Int
                    let board = try KiCadBoard(text: text)
                    for uuid in before {
                        guard let l = drawn[uuid], let s = l["start"] as? [Int], let en = l["end"] as? [Int], let w = l["width"] as? Int else { continue }
                        func mm(_ v: Int) -> Double { Double(v) / 1e6 }
                        board.root.items.append(SExpr("gr_line", SExpr("start", mm(s[0]), mm(s[1])), SExpr("end", mm(en[0]), mm(en[1])),
                                                      SExpr("stroke", SExpr("width", mm(w)), SExpr("type", Keyword("solid"))),
                                                      SExpr("layer", "F.Cu"), SExpr("uuid", uuid)))
                    }
                    let layers = Set(KiCadLayers.enabled(board).map(\.id))
                    let appearance = KiCadAppearanceControls(opening: local.board, boardLayers: layers).appearance
                    view = SnapView(appearance: appearance, enabledLayers: layers, worldPerPixel: abs(t["sx"] ?? 0) * 1e6,
                                    grid: IPoint(1_000, 1_000))
                    helper = PCBGridHelper(board: SnapBoard(board: board, project: project), magnetic: magnetic)
                    clicks = []
                    clickRaws = []
                case "move":
                    let r = e["raw"] as? [Double] ?? [0, 0]
                    let pixel = e["pixel"] as? [Int] ?? [0, 0]
                    defer { lastPixel = pixel }
                    guard step != nil else {
                        lastReading = nil
                        continue
                    }
                    if let lp = lastPixel, abs(lp[0] - pixel[0]) + abs(lp[1] - pixel[1]) > 40 {
                        pendingMove = (point(e), (r[0], r[1]))
                        continue
                    }
                    guard var h = helper, let v = view else { continue }
                    pointer = point(e)
                    offCanvas = false
                    raw = (r[0], r[1])
                    _ = h.bestSnapAnchor(pointer, layers: [0], view: v)
                    helper = h
                case "check":
                    let reading = e["cursor"] as? [Double]
                    defer { lastReading = reading }
                    guard let (p, r) = pendingMove else { continue }
                    pendingMove = nil
                    if reading != nil && reading == lastReading {
                        missed += 1
                        offCanvas = true
                        continue
                    }
                    guard step != nil, var h = helper, let v = view else { continue }
                    pointer = p
                    offCanvas = false
                    raw = r
                    _ = h.bestSnapAnchor(pointer, layers: [0], view: v)
                    helper = h
                case "click":
                    guard step != nil, !offCanvas, var h = helper, let v = view else { continue }
                    let p = h.bestSnapAnchor(pointer, layers: [0], view: v)
                    // (Draw Lines' first click: the line starts there, which a snap line does not snap to)
                    if clicks.isEmpty { h.skipPoint = p }
                    clicks.append(p)
                    clickRaws.append(raw)
                    helper = h
                case "made":
                    guard let i = step else { continue }
                    lines += 1
                    let uuids = made[String(i)] ?? []
                    before += uuids
                    let theirs = uuids.compactMap { drawn[$0] }.map { l -> [IPoint] in
                        let s = l["start"] as? [Int] ?? [], en = l["end"] as? [Int] ?? []
                        return [IPoint(s[0], s[1]), IPoint(en[0], en[1])]
                    }
                    let mine: [[IPoint]] = clicks.count >= 2 && clicks[0] != clicks[1] ? [[clicks[0], clicks[1]]] : []
                    // (a coordinate of a grid point, KiCad's and ours a micrometre apart, where the pixel's place on the
                    // board is half way between two of the grid's: the view's transform, fitted to the status bar's
                    // readings to the micrometre, does not know which side of the half the pixel is; counted)
                    func sameOrUnsure(_ k: IPoint, _ m: IPoint, _ r: (Double, Double)) -> Bool {
                        func coordinate(_ a: Int, _ b: Int, _ v: Double) -> Bool {
                            if a == b { return true }
                            let frac = v / 1_000 - (v / 1_000).rounded(.down)
                            return a % 1_000 == 0 && b % 1_000 == 0 && abs(a - b) == 1_000 && abs(frac - 0.5) < 0.35
                        }
                        return coordinate(k.x, m.x, r.0) && coordinate(k.y, m.y, r.1)
                    }
                    if theirs != mine, theirs.count == 1, mine.count == 1, clickRaws.count >= 2,
                       sameOrUnsure(theirs[0][0], mine[0][0], clickRaws[0]), sameOrUnsure(theirs[0][1], mine[0][1], clickRaws[1]) {
                        unsure += 1
                    } else if theirs != mine {
                        differences.append("\(file.lastPathComponent) line \(i): KiCad \(theirs), ours \(mine)")
                    }
                    // (an end KiCad put off the grid: on an item)
                    for l in theirs { for p in l where p.x % 1_000 != 0 || p.y % 1_000 != 0 { snappedToItems += 1 } }
                    step = nil
                default:
                    break
                }
            }
        }
        print("snapping: \(lines) lines drawn in KiCad, \(snappedToItems) ends off the grid, \(unsure) a micrometre off the grid's"
              + " point where the pixel is half way between two, \(missed) moves off KiCad's canvas, \(differences.count) differences")
        XCTAssertGreaterThan(lines, 0)
        XCTAssertEqual(differences, [], differences.prefix(10).joined(separator: "\n"))
    }

    /// The Magnetic Points preferences as KiCad reads them from pcbnew.json, its defaults where it has none
    func testMagneticSettingsAsKiCadReadsThem() {
        let d = MagneticSettings(pcbnewSettings: nil)
        XCTAssertEqual(d.pads, .captureCursorInTrackTool)
        XCTAssertEqual(d.tracks, .captureCursorInTrackTool)
        XCTAssertTrue(d.graphics)
        XCTAssertFalse(d.allLayers)
        let s = MagneticSettings(pcbnewSettings: ["editing": ["magnetic_pads": 2, "magnetic_tracks": 0, "magnetic_graphics": false,
                                                              "magnetic_all_layers": true]])
        XCTAssertEqual(s.pads, .captureAlways)
        XCTAssertEqual(s.tracks, .noEffect)
        XCTAssertFalse(s.graphics)
        XCTAssertTrue(s.allLayers)
        XCTAssertFalse(s.routerSnapsToTracks)
    }
}
