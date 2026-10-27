import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// The port's design rules check against KiCad's: tools/kicad-reference/drc.py has kicad-cli check each board
/// (NAME.drc, its report, next to NAME.kicad_pcb), and BoardDRC, checking the same board itself, must find the same
/// violations of the checks it makes: of the same kind, between the same items, in the same words (its rule and the
/// actual value, to KiCad's digits). KICAD_BOARD_REFERENCE names a folder of such boards; with none,
/// Fixtures/boards.
final class DRCTests: XCTestCase {
    private static var folders: [URL] {
        if let f = ProcessInfo.processInfo.environment["KICAD_BOARD_REFERENCE"] { return [URL(fileURLWithPath: f)] }
        return ["boards"].compactMap { Bundle.module.url(forResource: $0, withExtension: nil, subdirectory: "Fixtures") }
    }

    /// The checks BoardDRC makes
    static let checked: Set<String> = ["track_width", "via_diameter", "drill_out_of_range", "microvia_drill_out_of_range",
                                       "annular_width", "hole_to_hole", "holes_co_located", "clearance", "hole_clearance",
                                       "shorting_items", "tracks_crossing"]

    func testViolationsAsKiCadFindsThem() throws {
        let files = try Self.folders.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { $0.pathExtension == "kicad_pcb" }.sorted { $0.path < $1.path }
        var boards = 0, found = 0
        var differences: [String] = []
        var byType: [String: Int] = [:]
        var all: [String] = []
        for file in files {
            let reportURL = file.deletingPathExtension().appendingPathExtension("drc")
            guard let data = try? Data(contentsOf: reportURL) else { continue }
            let report = try KiCadFabrication.parseDRC(data)
            let pro = file.deletingPathExtension().appendingPathExtension("kicad_pro")
            let drc = BoardDRC(board: try KiCadBoard.read(file), projectURL: FileManager.default.fileExists(atPath: pro.path) ? pro : nil)
            boards += 1
            let name = file.deletingPathExtension().lastPathComponent
            func key(_ type: String, _ severity: String, _ description: String, _ items: [String]) -> String {
                "\(type) [\(severity)] \(description) \(items.joined(separator: " "))"
            }
            let ourViolations = drc.run()
            // (a check KiCad stopped at its limit of: which it found first goes by its threads, so only that the port
            // stops at the limit too)
            var capped: Set<String> = []
            for type in Self.checked {
                let limit = BoardDRC.errorLimit(type)
                let n = report.violations.filter { $0.type == type }.count
                guard n == limit else { continue }
                capped.insert(type)
                let m = ourViolations.filter { $0.type == type }.count
                if m != limit { differences.append("\(name): KiCad finds \(limit) \(type), its limit, ours \(m)") }
            }
            // (and once the shorts are, the copper's checks: KiCad reports what it would have as a short as a
            // clearance, and which go by the order it found them in)
            if capped.contains("shorting_items") || capped.contains("clearance") || capped.contains("hole_clearance") {
                capped.formUnion(["clearance", "shorting_items", "hole_clearance", "tracks_crossing"])
            }
            let theirs = report.violations.filter { Self.checked.contains($0.type) && !capped.contains($0.type) }
                .map { key($0.type, $0.severity, $0.description, $0.items.map(\.uuid)) }.sorted()
            let ours = ourViolations.filter { Self.checked.contains($0.type) && !capped.contains($0.type) }
                .map { key($0.type, $0.severity, $0.description, $0.items) }.sorted()
            for v in theirs { byType[String(v.prefix { $0 != " " }), default: 0] += 1 }
            found += theirs.count
            let missing = Self.minus(theirs, ours), extra = Self.minus(ours, theirs)
            for m in missing { all.append("\(name): KiCad finds, ours does not: \(m)") }
            for e in extra { all.append("\(name): ours finds, KiCad does not: \(e)") }
            for m in missing.prefix(5) { differences.append("\(name): KiCad finds, ours does not: \(m)") }
            for e in extra.prefix(5) { differences.append("\(name): ours finds, KiCad does not: \(e)") }
        }
        // (DRC_DIFFERENCES: every difference written there, for looking at by hand)
        if let path = ProcessInfo.processInfo.environment["DRC_DIFFERENCES"] {
            try? all.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        print("DRCTests: \(boards) boards, \(found) violations of the checks made: "
              + byType.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", "))
        XCTAssertGreaterThan(boards, 0)
        XCTAssert(differences.isEmpty, "\(differences.count) differences from KiCad's DRC:\n" + differences.prefix(30).joined(separator: "\n"))
    }

    /// What `a` has more of than `b` (as multisets)
    static func minus(_ a: [String], _ b: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for x in b { counts[x, default: 0] += 1 }
        var out: [String] = []
        for x in a {
            if let c = counts[x], c > 0 { counts[x] = c - 1 } else { out.append(x) }
        }
        return out
    }
}
