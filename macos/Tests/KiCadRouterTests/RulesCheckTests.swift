import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// A rules file checked as KiCad's Board Setup checks one (DesignRulesCheck: DRC_RULES_PARSER with a reporter, the
/// expression compiler's errors at their places, checkPlausibility's warnings), against KiCad's own: Fixtures/rulescheck
/// holds a board and BOARD.rules (tools/kicad-reference/boardsetup.py rules), what KiCad's Custom Rules page said of
/// each of a list of rules files (whole, and broken in each of the ways it reports) as its "Check rule syntax" button
/// had it check them: its report's lines and where each error's link goes (line and column). The port must say the
/// same, in the same order, its links going to the same places.
final class RulesCheckTests: XCTestCase {
    /// A report's line as its HTML shows it: runs of white space one space
    static func collapsed(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    /// Links' targets with each link's run of words taken once
    static func runs(_ links: [String]) -> [String] {
        links.enumerated().filter { $0.offset == 0 || links[$0.offset - 1] != $0.element }.map(\.element)
    }

    func testSyntaxChecksAreKiCads() throws {
        let folder = try XCTUnwrap(Bundle.module.url(forResource: "rulescheck", withExtension: nil, subdirectory: "Fixtures"))
        var cases = 0
        for record in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "rules" }) {
            let file = record.deletingPathExtension().appendingPathExtension("kicad_pcb")
            let board = try KiCadBoard.read(file)
            let project = BoardEditingTests.project(file)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
            for (n, c) in try XCTUnwrap(json["cases"] as? [[String: Any]]).enumerated() {
                let text = try XCTUnwrap(c["text"] as? String)
                let messages = DesignRulesCheck.check(text, board: board, project: project)
                let ours = messages.map { Self.collapsed($0.severity == .error ? "ERROR: " + $0.message : $0.message) }
                let theirs = (c["report"] as? String ?? "").split(separator: "\n").map { Self.collapsed(String($0)) }
                XCTAssertEqual(ours, theirs, "case \(n): \(text)")
                let places = Self.runs(messages.filter { $0.severity == .error }.map { "\($0.line ?? 0):\($0.column ?? 0)" })
                XCTAssertEqual(places, Self.runs(c["links"] as? [String] ?? []), "case \(n) links: \(text)")
                cases += 1
            }
        }
        XCTAssertGreaterThan(cases, 0)
    }
}
