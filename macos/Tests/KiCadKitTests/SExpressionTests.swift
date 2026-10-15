import XCTest
@testable import KiCadKit

/// KiCad's files read and written again exactly as KiCad writes them
final class SExpressionTests: XCTestCase {
    static func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testABoardKiCadWroteIsWrittenBackByteForByte() throws {
        // a board saved by KiCad 10's pcbnew: footprints, a track, a via, a filled zone
        let text = try Self.fixture("zone.kicad_pcb")
        let tree = try SExpr.parse(text)
        XCTAssertEqual(tree.head, "kicad_pcb")
        XCTAssertEqual(tree.formatted(), text)
    }

    func testLibraryFootprintsAreWrittenBackByteForByte() throws {
        for name in ["DIP-8_W7.62mm.kicad_mod", "R_0805_2012Metric.kicad_mod"] {
            let text = try Self.fixture(name)
            XCTAssertEqual(try SExpr.parse(text).formatted(), text, name)
        }
    }

    func testStringsAreQuotedAndEscapedAsKiCadDoes() throws {
        let node = try SExpr.parse(#"(property "Value" "say \"hi\" \\ there" (at 1 -2.5 90))"#)
        XCTAssertEqual(node.text(at: 1), #"say "hi" \ there"#)
        XCTAssertEqual(node["at"]?.number(at: 1), -2.5)
        XCTAssertEqual(node.compact, #"(property "Value" "say \"hi\" \\ there" (at 1 -2.5 90))"#)
    }

    func testNumbersAreWrittenAsKiCadWritesThem() {
        XCTAssertEqual(KiCadNumber.format(0.9125), "0.9125")
        XCTAssertEqual(KiCadNumber.format(-0.227064), "-0.227064")
        XCTAssertEqual(KiCadNumber.format(20), "20")
        XCTAssertEqual(KiCadNumber.format(-0.0000001), "0")
        XCTAssertEqual(KiCadNumber.format(1.0 / 3), "0.333333")
        XCTAssertEqual(KiCadNumber.format(0.00005), "0.00005")
        XCTAssertEqual(KiCadNumber.format(152.4), "152.4")
    }

    func testEditingInPlaceKeepsTheRest() throws {
        let text = try Self.fixture("zone.kicad_pcb")
        let tree = try SExpr.parse(text)
        let footprint = try XCTUnwrap(tree.all("footprint").first)
        footprint.set(SExpr("at", 25.4, 30.0))
        let again = try SExpr.parse(tree.formatted())
        XCTAssertEqual(again.all("footprint").first?["at"]?.compact, "(at 25.4 30)")
        XCTAssertEqual(again.all("footprint").count, tree.all("footprint").count)
        XCTAssertEqual(again.all("zone").first?["filled_polygon"]?.compact, tree.all("zone").first?["filled_polygon"]?.compact)
    }
}
