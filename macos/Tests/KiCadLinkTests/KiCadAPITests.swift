import XCTest
@testable import KiCadLink
import KiCadKit

/// KiCad's API, against a KiCad PCB editor running with its API on (skipped where none is)
final class KiCadAPITests: XCTestCase {
    func api() throws -> KiCadAPI {
        for socket in KiCadAPI.sockets() {
            do {
                let api = try KiCadAPI(socket: socket)
                _ = try api.version()
                return api
            } catch {
                print("\(socket): \(error)")
            }
        }
        throw XCTSkip("No KiCad is running with its API on")
    }

    func testKiCadSaysWhoItIsAndWhatItHasOpen() throws {
        let api = try api()
        let version = try api.version()
        XCTAssertGreaterThanOrEqual(version.major, 9)
        let boards = try api.openBoards()
        XCTAssertFalse(boards.isEmpty)
        let text = try api.text(of: boards[0])
        let board = try KiCadBoard(text: text)
        XCTAssertGreaterThan(board.version, 20240000)
        let footprints = try api.footprints(boards[0])
        XCTAssertEqual(Set(footprints.map(\.id.value)), Set(board.footprints.map(\.uuid)))
    }
}
