import XCTest
@testable import KiCadKit

/// Boards JSpice writes, checked by KiCad itself (kicad-cli), where KiCad is installed
final class KiCadIntegrationTests: XCTestCase {
    /// The KiCad to check against, or a skip where there is none
    static func kicad() throws -> KiCadInstallation {
        guard let installation = KiCadInstallation.find() else { throw XCTSkip("KiCad is not installed") }
        if let problem = installation.problem { throw XCTSkip(problem) }
        return installation
    }

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-kicad-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A new board from the test netlist, with KiCad's own libraries, arranged and outlined, written with its project
    func writeBoard(_ installation: KiCadInstallation, in folder: URL) throws -> (URL, KiCadBoard) {
        // the stock libraries in the project's own table, so KiCad checks each footprint against its library even
        // where it has never been run (and has no global table)
        if let stock = installation.footprints, let names = try? FileManager.default.contentsOfDirectory(atPath: stock.path) {
            let rows = names.filter { $0.hasSuffix(".pretty") }.sorted().map { name in
                SExpr("lib", SExpr("name", String(name.dropLast(7))), SExpr("type", "KiCad"),
                      SExpr("uri", stock.appendingPathComponent(name).path), SExpr("options", ""), SExpr("descr", ""))
            }
            try SExpr("fp_lib_table", [SExpr("version", 7)] + rows).formatted(.libraryTable)
                .write(to: folder.appendingPathComponent("fp-lib-table"), atomically: true, encoding: .utf8)
        }
        let library = KiCadFootprintLibrary(installation: installation, projectFolder: folder)
        XCTAssertTrue(library.has("Resistor_SMD:R_0805_2012Metric"), "the stock libraries are found through KiCad's tables")
        let board = KiCadProject.newBoard(title: "Integration")
        let report = NetlistUpdater.update(board, to: NetlistUpdaterTests.netlist(), library: library)
        XCTAssertEqual(report.errors, [])
        KiCadProject.arrangeNewBoard(board, order: board.footprints)
        let file = folder.appendingPathComponent("integration.kicad_pcb")
        try board.write(to: file)
        try KiCadProject.projectFile(name: "integration", netClasses: [.standard, .init(name: "Power", trackWidth: 0.5, clearance: 0.2, patterns: ["GND", "VCC"])])
            .write(to: folder.appendingPathComponent("integration.kicad_pro"), atomically: true, encoding: .utf8)
        return (file, board)
    }

    func testKiCadReadsTheBoardAndItsRatsnestIsOurs() throws {
        let installation = try Self.kicad()
        let folder = try folder()
        let (file, board) = try writeBoard(installation, in: folder)
        let fab = KiCadFabrication(installation: installation)
        let drc = try fab.drc(file)
        let types = Set(drc.violations.map(\.type))
        // each footprint as its library has it, none overlapping another
        XCTAssertFalse(types.contains("lib_footprint_mismatch"), "\(drc.violations)")
        XCTAssertFalse(types.contains("lib_footprint_issues"), "\(drc.violations)")
        XCTAssertFalse(types.contains("courtyards_overlap"), "\(drc.violations)")
        XCTAssertFalse(types.contains("malformed_courtyard"), "\(drc.violations)")
        // the connections KiCad finds unrouted are the ones JSpice's ratsnest draws
        let ratsnest = KiCadConnectivity(board).ratsnest()
        XCTAssertGreaterThan(ratsnest.count, 0)
        XCTAssertEqual(drc.unconnected.count, ratsnest.count, "\(drc.unconnected.map { $0.items.map(\.description) }) vs \(ratsnest.map { "\($0.net) \($0.ends)" })")

        // a track joining two pads of a net (on the top, where the resistor's pads are) is one connection fewer
        let r1 = try XCTUnwrap(board.footprints.first { $0.reference == "R1" })
        let u1 = try XCTUnwrap(board.footprints.first { $0.reference == "U1" })
        let (a, b) = (try XCTUnwrap(r1.pads(numbered: "1").first).position, try XCTUnwrap(u1.pads(numbered: "8").first).position)
        board.root.items.append(SExpr("segment", SExpr("start", a.x, a.y), SExpr("end", b.x, b.y), SExpr("width", 0.25),
                                      SExpr("layer", "F.Cu"), SExpr("net", "VCC"), SExpr("uuid", KiCadBoard.newUUID())))
        try board.write(to: file)
        let routed = try fab.drc(file)
        XCTAssertEqual(routed.unconnected.count, ratsnest.count - 1)
        XCTAssertEqual(KiCadConnectivity(board).ratsnest().count, ratsnest.count - 1)
    }

    func testTheFabricationPackageIsComplete() throws {
        let installation = try Self.kicad()
        let folder = try folder()
        let (file, board) = try writeBoard(installation, in: folder)
        let fab = KiCadFabrication(installation: installation)
        let package = try fab.package(file, into: folder.appendingPathComponent("fab"), maker: .jlcpcb,
                                      bom: KiCadFabrication.bom(board), step: false, render: false)
        let names = package.gerbers.map(\.lastPathComponent)
        for ext in ["GTL", "GBL", "GTS", "GBS", "GTO", "GBO", "GM1"] {
            XCTAssertTrue(names.contains { $0.uppercased().hasSuffix("." + ext) }, "\(ext) in \(names)")
        }
        XCTAssertTrue(package.drill.contains { $0.pathExtension == "drl" }, "\(package.drill)")
        let positions = try String(contentsOf: try XCTUnwrap(package.positions), encoding: .utf8)
        XCTAssertTrue(positions.hasPrefix("Designator,Mid X,Mid Y,Layer,Rotation\n"))
        XCTAssertTrue(positions.contains("R1,"))
        let bom = try String(contentsOf: try XCTUnwrap(package.bom), encoding: .utf8)
        XCTAssertTrue(bom.contains("TL072,U1,DIP-8_W7.62mm,"))
        XCTAssertNotNil(package.drc)
    }

    func testABoardOfAnyNumberOfLayersIsReadByKiCad() throws {
        let installation = try Self.kicad()
        let folder = try folder()
        let board = KiCadProject.newBoard(title: "Four layers", copperLayers: 4)
        KiCadProject.addOutline(board, KiCadBox(minX: 0, minY: 0, maxX: 50, maxY: 30))
        let file = folder.appendingPathComponent("four.kicad_pcb")
        try board.write(to: file)
        let drc = try KiCadFabrication(installation: installation).drc(file)
        XCTAssertEqual(drc.errors.map(\.type), [])
        XCTAssertEqual(KiCadFabrication.fabricationLayers(board).prefix(4), ["F.Cu", "In1.Cu", "In2.Cu", "B.Cu"])
    }
}
