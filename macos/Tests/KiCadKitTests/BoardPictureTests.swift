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
}
