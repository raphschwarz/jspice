import XCTest
@testable import KiCadKit

/// A board as the app draws it
final class BoardPictureTests: XCTestCase {
    func testABoardsFootprintsPadsTracksAndOutlineAreDrawn() throws {
        let board = try KiCadBoard(text: SExpressionTests.fixture("placed.kicad_pcb"))
        let picture = KiCadBoardPicture(board)
        XCTAssertEqual(picture.footprints.count, board.footprints.count)
        XCTAssertEqual(picture.pads.count, board.footprints.reduce(0) { $0 + $1.pads.count })
        XCTAssertEqual(picture.tracks.count, board.tracks.count)
        XCTAssertFalse(picture.copperLayers.isEmpty)
        for footprint in picture.footprints {
            XCTAssertTrue(picture.bounds.contains(footprint.position), footprint.reference)
            // a footprint is found where it is
            XCTAssertNotNil(picture.footprint(at: footprint.position), footprint.reference)
        }
        for pad in picture.pads where pad.outline.count > 2 {
            XCTAssertEqual(picture.pad(at: pad.center)?.footprint, pad.footprint)
        }
    }

    func testZonesAreDrawnWithTheirFills() throws {
        let board = try KiCadBoard(text: SExpressionTests.fixture("zone.kicad_pcb"))
        let picture = KiCadBoardPicture(board)
        XCTAssertFalse(picture.zones.isEmpty)
        XCTAssertTrue(picture.zones.contains { !$0.outline.isEmpty })
        XCTAssertNotNil(picture.boardSize)
    }

    func testTracksAndViasAreFoundWhereTheyAre() throws {
        let board = try KiCadBoard(text: SExpressionTests.fixture("placed.kicad_pcb"))
        board.addCopper(SExpr("segment", SExpr("start", 10.0, 10.0), SExpr("end", 20.0, 10.0), SExpr("width", 0.5),
                              SExpr("layer", "B.Cu"), board.netList("", pad: false), SExpr("uuid", "t1")))
        board.addCopper(SExpr("via", SExpr("at", 30.0, 10.0), SExpr("size", 0.8), SExpr("drill", 0.4),
                              SExpr("layers", "F.Cu", "B.Cu"), board.netList("", pad: false), SExpr("uuid", "v1")))
        let picture = KiCadBoardPicture(board)
        XCTAssertEqual(picture.copper(at: KiCadPoint(15, 10.2), layers: ["F.Cu", "B.Cu"]), "t1")
        XCTAssertNil(picture.copper(at: KiCadPoint(15, 10.4), layers: ["F.Cu", "B.Cu"]))
        XCTAssertEqual(picture.copper(at: KiCadPoint(15, 10.4), layers: ["B.Cu"], slop: 0.2), "t1")
        XCTAssertNil(picture.copper(at: KiCadPoint(15, 10.2), layers: ["F.Cu"]), "a track on another layer")
        XCTAssertEqual(picture.copper(at: KiCadPoint(30.3, 10), layers: []), "v1", "a via, on every layer")
    }

    func testTracksAndViasChangedOnAnOlderCopyAreCarriedOntoTheBoard() throws {
        let board = try KiCadBoard(text: SExpressionTests.fixture("placed.kicad_pcb"))
        board.addCopper(SExpr("segment", SExpr("start", 5.0, 5.0), SExpr("end", 6.0, 5.0), SExpr("width", 0.25),
                              SExpr("layer", "F.Cu"), board.netList("", pad: false), SExpr("uuid", "old-track")))
        let before = board.copy()
        let kept = try XCTUnwrap(before.copperItems.first?.value("uuid"))
        // routed on the copy: a track added, another taken away
        let after = before.copy()
        after.addCopper(SExpr("segment", SExpr("start", 1.0, 2.0), SExpr("end", 3.0, 4.0), SExpr("width", 0.25),
                              SExpr("layer", "F.Cu"), after.netList("", pad: false), SExpr("uuid", "new-track")))
        let gone = try XCTUnwrap(after.copperItems.last { $0.value("uuid") != "new-track" && $0.value("uuid") != kept })
        let goneID = try XCTUnwrap(gone.value("uuid"))
        after.root.remove(gone)
        // the board meanwhile changed elsewhere: a footprint moved
        let moved = try XCTUnwrap(board.footprints.first)
        moved.move(to: KiCadPoint(moved.position.x + 5, moved.position.y), rotation: moved.rotation)
        board.carryCopper(from: before, to: after)
        XCTAssertTrue(board.copperItems.contains { $0.value("uuid") == "new-track" })
        XCTAssertFalse(board.copperItems.contains { $0.value("uuid") == goneID })
        XCTAssertTrue(board.copperItems.contains { $0.value("uuid") == kept })
        XCTAssertEqual(board.footprints.first?.position.x, moved.position.x, "and keeps its own change")
        // the new track goes with the board's others, before its zones
        let heads = board.root.items.compactMap(\.head)
        let last = try XCTUnwrap(heads.lastIndex { ["segment", "arc", "via"].contains($0) })
        XCTAssertFalse(heads[..<last].contains("zone"))
    }
}
