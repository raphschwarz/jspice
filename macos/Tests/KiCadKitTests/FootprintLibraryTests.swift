import XCTest
@testable import KiCadKit

/// Footprints taken from their library and placed on a board as KiCad places them
final class FootprintLibraryTests: XCTestCase {
    /// Every id the same, to compare two boards' items
    static func sameIDs(_ text: String) -> String {
        text.replacingOccurrences(of: #"\(uuid "[0-9a-f-]+"\)"#, with: "(uuid)", options: .regularExpression)
    }

    /// A footprint's items, ids aside, in an order of their own (KiCad sorts a footprint's drawings as it saves it)
    static func items(_ footprint: SExpr) -> [String] {
        footprint.items.map { sameIDs($0.compact) }.sorted()
    }

    func testAFootprintIsPlacedAsKiCadPlacesIt() throws {
        // placed.kicad_pcb: KiCad 10's pcbnew placed these from its library (FootprintLoad, SetPosition, SetOrientation)
        let kicad = try KiCadBoard(text: SExpressionTests.fixture("placed.kicad_pcb"))
        let r1 = try XCTUnwrap(kicad.footprints.first { $0.reference == "R1" })
        let u1 = try XCTUnwrap(kicad.footprints.first { $0.reference == "U1" })

        let resistor = KiCadFootprintLibrary.placeable(try SExpr.parse(SExpressionTests.fixture("R_0805_2012Metric.kicad_mod")),
                                                       libID: "R_0805_2012Metric", reference: "R1", value: "10k",
                                                       at: KiCadPoint(20, 20))
        let board = KiCadBoard(SExpr(list: [SExpr(symbol: "kicad_pcb"), resistor]))
        board.footprints[0].path = "/0f3a3bde-8f9a-4c79-9d07-4a2b3c4d5e6f"
        // its pads take their nets as the netlist gives them
        board.footprints[0].pads[0].setNet("VCC")
        board.footprints[0].pads[1].setNet("OUT")
        XCTAssertEqual(Self.items(resistor), Self.items(r1.node))

        let dip = KiCadFootprintLibrary.placeable(try SExpr.parse(SExpressionTests.fixture("DIP-8_W7.62mm.kicad_mod")),
                                                  libID: "DIP-8_W7.62mm", reference: "U1", value: "TL072",
                                                  at: KiCadPoint(40, 20), rotation: 90)
        let board2 = KiCadBoard(SExpr(list: [SExpr(symbol: "kicad_pcb"), dip]))
        board2.footprints[0].pads[0].setNet("OUT")
        XCTAssertEqual(Self.items(dip), Self.items(u1.node))
    }

    /// Two lists of items alike, ids aside, each number within a nanometre or two (KiCad keeps a footprint's items in
    /// whole nanometres on the board, so one turned off square comes back a nanometre out) and angles a whole turn
    /// apart counting as one
    static func alike(_ ours: [String], _ theirs: [String]) -> [String] {
        func tokens(_ s: String) -> [String] {
            s.replacingOccurrences(of: "(", with: " ( ").replacingOccurrences(of: ")", with: " ) ").split(separator: " ").map(String.init)
        }
        func same(_ x: String, _ y: String) -> Bool {
            let (tx, ty) = (tokens(x), tokens(y))
            guard tx.count == ty.count else { return false }
            for (p, q) in zip(tx, ty) where p != q {
                guard let u = Double(p), let v = Double(q) else { return false }
                let d = abs(u - v)
                if d > 3e-6 && abs(d - 360) > 3e-6 { return false }
            }
            return true
        }
        var rest = theirs
        var unmatched: [String] = []
        for x in ours {
            if let j = rest.firstIndex(where: { same(x, $0) }) { rest.remove(at: j) } else { unmatched.append("ours:  " + x) }
        }
        return unmatched + rest.map { "KiCad: " + $0 }
    }

    func testFootprintsTurnedAndFlippedAsKiCadTurnsAndFlipsThem() throws {
        // flipped/flipped.kicad_pcb: KiCad 10 placed each footprint at 0°, 90° and 37° on the front, and turned at 0°,
        // 90° and -143° before flipping it onto the back (FOOTPRINT::SetLayerAndFlip): texts kept upright and
        // mirrored, arcs reversed, custom pads, points and fields
        let kicad = try KiCadBoard(text: SExpressionTests.fixture("flipped/flipped.kicad_pcb"))
        let data = try XCTUnwrap(SExpressionTests.fixture("flipped/flipped.json").data(using: .utf8))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(rows.count, 48)
        for row in rows {
            let ref = try XCTUnwrap(row["ref"] as? String), lib = try XCTUnwrap(row["lib"] as? String)
            let theirs = try XCTUnwrap(kicad.footprints.first { $0.reference == ref })
            let footprint = try SExpr.parse(SExpressionTests.fixture("flipped/\(lib).kicad_mod"))
            let node = KiCadFootprintLibrary.placeable(footprint, libID: theirs.libID, reference: ref, value: theirs.value,
                                                       at: theirs.position, rotation: try XCTUnwrap(row["rotation"] as? Double))
            let board = KiCadBoard(SExpr(list: [SExpr(symbol: "kicad_pcb"), node]))
            if row["back"] as? Bool == true { board.footprints[0].flip() }
            XCTAssertEqual(board.footprints[0].rotation, theirs.rotation, accuracy: 1e-9, ref)
            XCTAssertEqual(board.footprints[0].layer, theirs.layer, ref)
            XCTAssertEqual(Self.alike(Self.items(node), Self.items(theirs.node)), [], "\(ref) \(lib) \(row)")
        }
    }
}
