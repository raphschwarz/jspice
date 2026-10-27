import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// The port's courtyards against KiCad's: tools/kicad-reference/courtyards.py has KiCad build each footprint's
/// (FOOTPRINT::BuildCourtyardCaches, NAME.courtyards next to NAME.kicad_pcb), and BoardDRC.courtyards, made of the
/// same board, must give the same: each side's polygons, their outlines and holes point for point, the width of the
/// first outline, and which sides are malformed. KICAD_BOARD_REFERENCE names a folder of such boards (or several,
/// separated by colons); with none,
/// Fixtures/boards and Fixtures/courtyards (footprints drawn to take the conversion down its other ways: holes,
/// contours crossing, islands, chains that do not close or cross themselves, arcs, circles, curves, rounded and
/// turned rectangles).
final class CourtyardTests: XCTestCase {
    private static var folders: [URL] {
        if let f = ProcessInfo.processInfo.environment["KICAD_BOARD_REFERENCE"] {
            return f.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        return ["boards", "courtyards"].compactMap { Bundle.module.url(forResource: $0, withExtension: nil, subdirectory: "Fixtures") }
    }

    private static func chain(_ any: Any?) -> (points: [IPoint], closed: Bool, arcs: Int) {
        let d = any as? [String: Any] ?? [:]
        let pts = (d["points"] as? [[NSNumber]] ?? []).map { IPoint($0[0].intValue, $0[1].intValue) }
        return (pts, d["closed"] as? Bool ?? false, (d["arcs"] as? NSNumber)?.intValue ?? 0)
    }

    /// The differences between KiCad's side of a courtyard and the port's
    private static func compare(_ theirs: [String: Any], _ ours: PolySet, _ ourWidth: Int, _ what: String) -> [String] {
        let polys = theirs["polygons"] as? [[String: Any]] ?? []
        var out: [String] = []
        if polys.count != ours.outlineCount {
            return ["\(what): KiCad has \(polys.count) outlines, ours \(ours.outlineCount)"]
        }
        let width = (theirs["width"] as? NSNumber)?.intValue ?? 0
        if width != ourWidth { out.append("\(what): KiCad's width \(width), ours \(ourWidth)") }
        for (i, p) in polys.enumerated() {
            let holes = p["holes"] as? [Any] ?? []
            let contours = [p["outline"] as Any] + holes
            if contours.count != ours.polygons[i].count {
                out.append("\(what) outline \(i): KiCad has \(holes.count) holes, ours \(ours.holeCount(i))")
                continue
            }
            for (j, c) in contours.enumerated() {
                let k = chain(c)
                let mine = ours.polygons[i][j]
                if k.points != mine.points || k.closed != mine.isClosed || k.arcs != mine.arcCount {
                    out.append("\(what) outline \(i) contour \(j): KiCad's \(k.points.count) points (closed \(k.closed), \(k.arcs) arcs) "
                               + "\(k.points.prefix(6)), ours \(mine.pointCount) (closed \(mine.isClosed), \(mine.arcCount) arcs) "
                               + "\(mine.points.prefix(6))")
                }
            }
        }
        return out
    }

    func testCourtyardsAsKiCadMakesThem() throws {
        let files = try Self.folders.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { $0.pathExtension == "kicad_pcb" }.sorted { $0.path < $1.path }
        var boards = 0, footprints = 0, sides = 0, malformed = 0, holes = 0, outlines = 0
        var differences: [String] = []
        for file in files {
            let referenceURL = file.deletingPathExtension().appendingPathExtension("courtyards")
            guard let data = try? Data(contentsOf: referenceURL),
                  let reference = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { continue }
            let pro = file.deletingPathExtension().appendingPathExtension("kicad_pro")
            let board = try KiCadBoard.read(file)
            let drc = BoardDRC(board: board, projectURL: FileManager.default.fileExists(atPath: pro.path) ? pro : nil)
            boards += 1
            let name = file.deletingPathExtension().lastPathComponent
            var seen = Set<String>()
            for (i, fp) in board.root.all("footprint").enumerated() {
                let uuid = fp.value("uuid") ?? ""
                guard let theirs = reference[uuid] else {
                    differences.append("\(name): footprint \(uuid) not in KiCad's courtyards")
                    continue
                }
                seen.insert(uuid)
                footprints += 1
                let ours = drc.courtyards(i)
                let what = "\(name) \(theirs["reference"] as? String ?? uuid)"
                for (side, polys, width, flag, ourFlag) in [
                    ("front", ours.front, ours.frontWidth, "malformedFront", ours.malformedFront),
                    ("back", ours.back, ours.backWidth, "malformedBack", ours.malformedBack),
                ] {
                    let t = theirs[side] as? [String: Any] ?? [:]
                    sides += 1
                    let theirFlag = theirs[flag] as? Bool ?? false
                    if theirFlag { malformed += 1 }
                    if theirFlag != ourFlag {
                        differences.append("\(what) \(side): KiCad's malformed \(theirFlag), ours \(ourFlag)")
                    }
                    outlines += polys.outlineCount
                    holes += polys.polygons.reduce(0) { $0 + max(0, $1.count - 1) }
                    differences += Self.compare(t, polys, width, "\(what) \(side)")
                }
            }
            for uuid in reference.keys where !seen.contains(uuid) {
                differences.append("\(name): KiCad's footprint \(uuid) not on the port's board")
            }
        }
        print("CourtyardTests: \(boards) boards, \(footprints) footprints, \(sides) courtyard sides: \(outlines) outlines, "
              + "\(holes) holes, \(malformed) malformed")
        XCTAssertGreaterThan(boards, 0)
        XCTAssertTrue(differences.isEmpty, "\(differences.count) differences:\n" + differences.prefix(40).joined(separator: "\n"))
    }
}
