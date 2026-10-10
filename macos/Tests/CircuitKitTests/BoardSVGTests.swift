import XCTest
@testable import CircuitKit

/// Printable build sheets: well-formed SVG at the board's true size, every part drawn and listed
final class BoardSVGTests: XCTestCase {
    /// Parses the SVG, counting its elements by name and gathering its text
    final class Reader: NSObject, XMLParserDelegate {
        var counts: [String: Int] = [:]
        var root: [String: String] = [:]
        var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if counts.isEmpty { root = attributes }
            counts[name, default: 0] += 1
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string + " " }
    }

    private func read(_ svg: String, _ label: String) throws -> Reader {
        let reader = Reader()
        let parser = XMLParser(data: Data(svg.utf8))
        parser.delegate = reader
        XCTAssertTrue(parser.parse(), "\(label): \(parser.parserError.map { "\($0)" } ?? "")")
        return reader
    }

    /// The width in mm the root names, and the user units across its view box, which must agree: 1 unit is 1 mm
    private func checkScale(_ reader: Reader, _ label: String) throws {
        let width = try XCTUnwrap(reader.root["width"], label)
        XCTAssertTrue(width.hasSuffix("mm"), label)
        let box = try XCTUnwrap(reader.root["viewBox"]?.split(separator: " ").compactMap { Double($0) }, label)
        XCTAssertEqual(box.count, 4, label)
        XCTAssertEqual(Double(width.dropLast(2)) ?? 0, box[2], accuracy: 0.01, label)
    }

    func testSheetsAreWellFormedAtTrueSize() throws {
        for id in ["fuzz", "opamp", "tube-screamer", "opamp-stability"] {
            let circuit = try XCTUnwrap(Examples.all.first { $0.id == id }, id).circuit
            let strip = Stripboard.layout(circuit)
            let perf = Perfboard.layout(circuit)
            let bread = Breadboard.layout(circuit, size: .half)
            for (kind, svg, names, holes) in [
                ("stripboard", BoardSVG.stripboard(strip, title: id), strip.placements.map(\.name), strip.rows * strip.columns),
                ("perfboard", BoardSVG.perfboard(perf, title: id), perf.placements.map(\.name), perf.rows * perf.columns),
                ("breadboard", BoardSVG.breadboard(bread, title: id), bread.placements.map(\.name), bread.width * 14),
            ] {
                let label = "\(id) \(kind)"
                let reader = try read(svg, label)
                try checkScale(reader, label)
                // a circle for every hole (and pads, legs on top)
                XCTAssertGreaterThanOrEqual(reader.counts["circle"] ?? 0, holes, label)
                for name in names { XCTAssertTrue(reader.text.contains(name), "\(label): \(name) not drawn") }
                XCTAssertTrue(reader.text.contains("Bill of materials"), label)
                XCTAssertTrue(reader.text.contains("25.4 mm"), label)
            }
            // the stripboard's cuts, and the perfboard's trails
            XCTAssertGreaterThanOrEqual(try read(BoardSVG.stripboard(strip, title: id), id).counts["line"] ?? 0, strip.cuts.count * 2)
            XCTAssertGreaterThanOrEqual(try read(BoardSVG.perfboard(perf, title: id), id).counts["line"] ?? 0, perf.trails.count * 2)
        }
        // text is escaped
        XCTAssertEqual(BoardSVG.escaped("R&D <1> \"x\""), "R&amp;D &lt;1&gt; &quot;x&quot;")
    }
}
