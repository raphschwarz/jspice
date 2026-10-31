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

    /// An open board is a file by its name and its project's folder, never by its name alone
    func testAnOpenBoardIsItsFileOnlyInItsOwnFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-api-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        var document = Kiapi_Common_Types_DocumentSpecifier()
        document.boardFilename = "amp.kicad_pcb"
        document.project.path = folder.path
        XCTAssertTrue(KiCadAPI.document(document, is: folder.appendingPathComponent("amp.kicad_pcb")))
        XCTAssertFalse(KiCadAPI.document(document, is: folder.appendingPathComponent("other.kicad_pcb")))
        XCTAssertFalse(KiCadAPI.document(document, is: URL(fileURLWithPath: "/elsewhere/amp.kicad_pcb")), "another project's amp")
        // the same folder by a link
        let link = folder.deletingLastPathComponent().appendingPathComponent("jspice-api-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        addTeardownBlock { try? FileManager.default.removeItem(at: link) }
        XCTAssertTrue(KiCadAPI.document(document, is: link.appendingPathComponent("amp.kicad_pcb")))
        document.project.path = ""
        XCTAssertFalse(KiCadAPI.document(document, is: folder.appendingPathComponent("amp.kicad_pcb")))
    }

    /// A footprint's symbol units (the board file's units) go with it, as KiCad 10.0.8's API carries them
    /// (FootprintInstance.symbol_units), made and patched alike
    func testAFootprintCarriesItsSymbolUnits() throws {
        let board = try KiCadBoard(text: """
            (kicad_pcb (version 20260206) (generator "pcbnew") (generator_version "10.0") (general (thickness 1.6))
              (layers (0 "F.Cu" signal) (2 "B.Cu" signal) (25 "Edge.Cuts" user))
              (footprint "Package_SO:SOIC-8" (layer "F.Cu") (uuid "f0000000-0000-0000-0000-000000000001") (at 10 10)
                (units (unit (name "A") (pins "1" "2" "3")) (unit (name "B") (pins "5" "6" "7")))))
            """)
        let footprint = try XCTUnwrap(board.footprints.first)
        let expected = [("A", ["1", "2", "3"]), ("B", ["5", "6", "7"])]
        var instance = try KiCadFootprintMessage.instance(footprint)
        XCTAssertEqual(instance.symbolUnits.map(\.name), expected.map(\.0))
        XCTAssertEqual(instance.symbolUnits.map(\.pinNumbers), expected.map(\.1))
        instance.symbolUnits = []
        try KiCadLiveBoard.patch(&instance, from: footprint)
        XCTAssertEqual(instance.symbolUnits.map(\.pinNumbers), expected.map(\.1))
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
