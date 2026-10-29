import Foundation
import XCTest
import KiCadKit
@testable import KiCadRouter

/// The design rules' parser, expression language and engine on their own, against what kicad-cli 10.0.7 does with
/// the same rules (its DRC of a board with them: which assertions fail, which rules it keeps). The whole of it is
/// checked against KiCad by DRCTests and FillTests on boards with rules files (Fixtures/rules, rules.py's).
final class RulesTests: XCTestCase {
    /// A board's rules engine with `rules` as its rules file
    private func engine(_ rules: String, board name: String = "random-2-74") throws -> BoardDRC {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "kicad_pcb", subdirectory: "Fixtures/boards"))
        let project = (try? Data(contentsOf: url.deletingPathExtension().appendingPathExtension("kicad_pro")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        return BoardDRC(board: try KiCadBoard.read(url), project: project, designRules: rules)
    }

    /// Whether `test` holds of each footprint of the board, as an assertion's test
    private func holds(_ test: String, compiles: Bool = true) throws -> [Bool] {
        let drc = try engine("(version 1)")
        let condition = RuleCondition(test)
        XCTAssertEqual(condition.compile(), compiles, test)
        return drc.ruleState.footprints.map {
            condition.evaluate($0, nil, constraint: .assertion, layer: $0.layer, board: drc.ruleState.board)
        }
    }

    /// The grammar's precedences as KiCad's lemon parser has them: && looser than ||, * before +, a unit binding
    /// tightest; names compared without case, wildcards in the right one (kicad-cli fails the first assertion on
    /// every footprint and passes the others)
    func testPrecedencesAndComparisons() throws {
        XCTAssertEqual(Set(try holds("A.Type == 'Footprint' || A.Type == 'Pad' && A.Type == 'Via'")), [false])
        XCTAssertEqual(Set(try holds("1mm + 1mm * 2 == 3mm")), [true])
        XCTAssertEqual(Set(try holds("A.Type == 'footprint' && A.Reference == 'u*'")), [true])
        XCTAssertEqual(Set(try holds("1mil < 0.03mm && 1in == 25.4mm")), [true])
        XCTAssertEqual(Set(try holds("!A.Type == 'Footprint'")), [false])
    }

    /// A syntax error in a condition: its code is empty, and an assertion of it fails
    func testASyntaxErrorFails() throws {
        XCTAssertEqual(Set(try holds("A.Type == ", compiles: false)), [false])
    }

    /// A file KiCad cannot read: none of its rules, the implicit rules alone
    func testAFileThatDoesNotParseHasNoRules() throws {
        let drc = try engine("(version 1)\n(rule big (constraint clearance (min 2mm)))\n(rule open (constraint track_width (min 1mm))\n")
        XCTAssertNotNil(drc.ruleState.engine.rulesError)
        XCTAssert(drc.ruleState.engine.userConstraintTypes.isEmpty)
    }

    /// A rule KiCad cannot compile: the rules before it keep their constraints (the implicit rules made again after
    /// them), the rules from it on are lost
    func testARuleThatDoesNotCompileKeepsTheRulesBeforeIt() throws {
        let drc = try engine("""
            (version 1)
            (rule w1 (constraint track_width (min 0.35mm) (max 0.31mm)))
            (rule bad (condition "A.No_Such_Property == 3mm") (constraint clearance (min 1mm)))
            (rule after (constraint hole_size (min 2mm)))
            """)
        let engine = drc.ruleState.engine
        XCTAssertNotNil(engine.rulesError)
        XCTAssertEqual(engine.userConstraintTypes, [.trackWidth])
    }

    /// wxString::Matches: a character that differs fails at once; text left when the mask is done goes back to the
    /// last '*' once
    func testWildcards() {
        XCTAssert(WildMatch.matches("SIG1", "SIG?"))
        XCTAssert(WildMatch.matches("/sub/clk", "/sub/*"))
        XCTAssertFalse(WildMatch.matches("SIG12", "SIG?"))
        XCTAssert(WildMatch.matches("abcbc", "*bc"))
        XCTAssertFalse(WildMatch.matches("abcbcx", "*bc"))
    }
}
