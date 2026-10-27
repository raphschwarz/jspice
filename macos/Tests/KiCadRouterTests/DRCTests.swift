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
                                       "annular_width", "hole_to_hole", "holes_co_located"]

    func testViolationsAsKiCadFindsThem() throws {
        let files = try Self.folders.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { $0.pathExtension == "kicad_pcb" }.sorted { $0.path < $1.path }
        var boards = 0, found = 0
        var differences: [String] = []
        var byType: [String: Int] = [:]
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
            let theirs = report.violations.filter { Self.checked.contains($0.type) }
                .map { key($0.type, $0.severity, $0.description, $0.items.map(\.uuid)) }.sorted()
            let ours = drc.run().filter { Self.checked.contains($0.type) }
                .map { key($0.type, $0.severity, $0.description, $0.items) }.sorted()
            for v in theirs { byType[String(v.prefix { $0 != " " }), default: 0] += 1 }
            found += theirs.count
            let missing = Self.minus(theirs, ours), extra = Self.minus(ours, theirs)
            for m in missing.prefix(5) { differences.append("\(name): KiCad finds, ours does not: \(m)") }
            for e in extra.prefix(5) { differences.append("\(name): ours finds, KiCad does not: \(e)") }
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
