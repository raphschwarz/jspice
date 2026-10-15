import XCTest
@testable import CircuitKit
import KiCadKit

/// Footprints made up for the tests: as many pads as the footprint's name says (DIP-8 eight, a TO-92 three, a 1x02
/// header two, else two), in a row, inside a courtyard
struct MadeUpFootprints: KiCadFootprintSource {
    func footprint(_ libID: String) throws -> SExpr {
        let name = libID.split(separator: ":").last.map(String.init) ?? libID
        var pads = 2
        if let r = name.range(of: #"DIP-(\d+)"#, options: .regularExpression) { pads = Int(name[r].dropFirst(4)) ?? 8 }
        if let r = name.range(of: #"SOIC-(\d+)"#, options: .regularExpression) { pads = Int(name[r].dropFirst(5)) ?? 8 }
        if let r = name.range(of: #"1x(\d+)"#, options: .regularExpression) { pads = Int(name[r].dropFirst(2)) ?? 2 }
        if name.contains("TO-92") || name.contains("SOT-23") || name.contains("Potentiometer") { pads = 3 }
        let width = Double(pads) * 2.54
        var items: [SExpr] = [SExpr(symbol: "footprint"), SExpr(string: name), SExpr("layer", "F.Cu"),
                              SExpr("property", "Reference", "REF**", SExpr("at", 0.0, -2.0, 0.0), SExpr("layer", "F.SilkS")),
                              SExpr("property", "Value", name, SExpr("at", 0.0, 2.0, 0.0), SExpr("layer", "F.Fab")),
                              SExpr("attr", Keyword("through_hole")),
                              SExpr("fp_rect", SExpr("start", -1.5, -1.5), SExpr("end", width - 1.0, 1.5),
                                    SExpr("stroke", SExpr("width", 0.05), SExpr("type", Keyword("solid"))), SExpr("fill", Keyword("no")),
                                    SExpr("layer", "F.CrtYd"))]
        for n in 1...pads {
            items.append(SExpr("pad", "\(n)", Keyword("thru_hole"), Keyword("circle"), SExpr("at", Double(n - 1) * 2.54, 0.0),
                               SExpr("size", 1.6, 1.6), SExpr("drill", 0.8), SExpr("layers", "*.Cu", "*.Mask")))
        }
        return SExpr(list: items)
    }
}

/// The schematic and its board kept as one: the schematic's changes taken to the board, the board's brought back
final class PCBSyncTests: XCTestCase {
    static let library = MadeUpFootprints()

    static func circuit() throws -> Circuit {
        try PCBTests.circuit(opAmps: ["A1", "A2"])
    }

    func element(_ circuit: Circuit, _ name: String) throws -> Element {
        try XCTUnwrap(circuit.elements.first { $0.name == name }, name)
    }

    func testANewBoardHasEveryPartAndIsAsTheSchematicSays() throws {
        let (board, result) = PCBSync.newBoard(try Self.circuit(), title: "Test", library: Self.library)
        XCTAssertEqual(result.report.errors.map(\.text), [])
        // the supply on J1, and on J2 the -15 V the TL072 needs and the circuit leaves implicit
        XCTAssertEqual(Set(board.footprints.map(\.reference)), ["R1", "R2", "Q1", "U1", "J1", "J2"])
        XCTAssertNotNil(board.edgeBounds)
        // every footprint inside the outline
        let outline = try XCTUnwrap(board.outline.first.flatMap { KiCadBox($0.points) })
        for footprint in board.footprints { XCTAssertTrue(outline.contains(footprint.position), footprint.reference) }
        // the common ground recorded, and nothing left to do
        XCTAssertEqual(result.circuit.pcb?.synced.count, 6)
        let status = PCBSync.status(result.circuit, board: board, library: Self.library)
        XCTAssertTrue(status.consistent, "\(status)")
    }

    func testASchematicChangeReachesTheBoardWhereItStands() throws {
        let (board, made) = PCBSync.newBoard(try Self.circuit(), title: "Test", library: Self.library)
        var circuit = made.circuit
        let r1 = try XCTUnwrap(board.footprints.first { $0.reference == "R1" })
        r1.move(to: KiCadPoint(42, 17), rotation: 90)
        let i = try XCTUnwrap(circuit.elements.firstIndex { $0.name == "R1" })
        circuit.elements[i].params["resistance"] = 22_000
        let result = PCBSync.sync(circuit, board: board, library: Self.library)
        XCTAssertEqual(result.applied, [])
        XCTAssertEqual(result.report.actions.map(\.text), ["Change R1 value from 4.7k to 22k."])
        let after = try XCTUnwrap(board.footprint(uuid: r1.uuid))
        XCTAssertEqual(after.value, "22k")
        XCTAssertEqual(after.position, KiCadPoint(42, 17))
    }

    func testTheBoardsRenameValueFootprintAndFittingComeBackToTheSchematic() throws {
        let (board, made) = PCBSync.newBoard(try Self.circuit(), title: "Test", library: Self.library)
        let r1 = try XCTUnwrap(board.footprints.first { $0.reference == "R1" })
        let r2 = try XCTUnwrap(board.footprints.first { $0.reference == "R2" })
        let u1 = try XCTUnwrap(board.footprints.first { $0.reference == "U1" })
        // changed in KiCad
        r1.reference = "R10"
        r2.value = "22k"
        u1.libID = "Package_SO:SOIC-8_3.9x4.9mm_P1.27mm"
        var attrs = r2.attributes
        attrs.insert("dnp")
        r2.attributes = attrs
        let result = PCBSync.sync(made.circuit, board: board, library: Self.library)
        XCTAssertEqual(Set(result.applied.map(\.description)), [
            "R1 renamed R10 on the board", "R2's value changed from 10k to 22k on the board",
            "U1's footprint changed from Package_DIP:DIP-8_W7.62mm to Package_SO:SOIC-8_3.9x4.9mm_P1.27mm on the board",
            "R2 marked not to be fitted on the board",
        ])
        let circuit = result.circuit
        XCTAssertNoThrow(try element(circuit, "R10"))
        XCTAssertEqual(try element(circuit, "R2")[param: "resistance"], 22_000)
        let a1 = try element(circuit, "A1")
        XCTAssertEqual(circuit.pcb?.footprints[a1.id.uuidString], "Package_SO:SOIC-8_3.9x4.9mm_P1.27mm")
        XCTAssertEqual(circuit.pcb?.doNotPopulate.contains(try element(circuit, "R2").id.uuidString), true)
        // the board keeps its own changes: nothing to take back to it
        XCTAssertEqual(result.report.actions.map(\.text), [])
        XCTAssertTrue(PCBSync.status(circuit, board: board, library: Self.library).consistent)
    }

    func testWhereBothChangedTheSchematicStands() throws {
        let (board, made) = PCBSync.newBoard(try Self.circuit(), title: "Test", library: Self.library)
        board.footprints.first { $0.reference == "R1" }!.value = "22k"
        var circuit = made.circuit
        circuit.elements[try XCTUnwrap(circuit.elements.firstIndex { $0.name == "R1" })].params["resistance"] = 1000
        let result = PCBSync.sync(circuit, board: board, library: Self.library)
        XCTAssertEqual(result.applied, [])
        XCTAssertEqual(board.footprints.first { $0.reference == "R1" }?.value, "1k")
    }

    func testAPartDeletedOnTheBoardIsLeftOffUntilTheUserSays() throws {
        let (board, made) = PCBSync.newBoard(try Self.circuit(), title: "Test", library: Self.library)
        board.remove(try XCTUnwrap(board.footprints.first { $0.reference == "Q1" }))
        // asked about, not put back, and asked about again until decided
        var result = PCBSync.sync(made.circuit, board: board, library: Self.library)
        XCTAssertEqual(result.removed.map(\.description), ["Q1 deleted from the board"])
        XCTAssertNil(board.footprints.first { $0.reference == "Q1" })
        result = PCBSync.sync(result.circuit, board: board, library: Self.library)
        XCTAssertEqual(result.removed.map(\.description), ["Q1 deleted from the board"])
        // put back
        let q1 = try element(result.circuit, "Q1").id
        let back = PCBSync.sync(result.circuit, board: board, library: Self.library, putBack: [q1])
        XCTAssertEqual(back.removed, [])
        XCTAssertNotNil(board.footprints.first { $0.reference == "Q1" })
        // or deleted from the schematic too
        board.remove(try XCTUnwrap(board.footprints.first { $0.reference == "Q1" }))
        var circuit = PCBSync.sync(back.circuit, board: board, library: Self.library).circuit
        let pending = PCBSync.sync(circuit, board: board, library: Self.library).removed
        XCTAssertEqual(pending.count, 1)
        PCBSync.delete(pending[0], from: &circuit)
        XCTAssertNil(circuit.elements.first { $0.name == "Q1" })
        let final = PCBSync.sync(circuit, board: board, library: Self.library)
        XCTAssertEqual(final.removed, [])
        // nothing added or removed (the nets named after Q1's pads are named after others now)
        XCTAssertEqual(final.report.added, [])
        XCTAssertEqual(final.report.removed, [])
    }

    func testWhatWasPutOnTheBoardWithoutTheSchematicStays() throws {
        let (board, made) = PCBSync.newBoard(try Self.circuit(), title: "Test", library: Self.library)
        let hole = KiCadFootprintLibrary.placeable(try Self.library.footprint("MountingHole:MountingHole_3.2mm_M3"),
                                                   libID: "MountingHole:MountingHole_3.2mm_M3", reference: "H1", value: "M3",
                                                   at: KiCadPoint(5, 5))
        board.add(hole)
        let result = PCBSync.sync(made.circuit, board: board, library: Self.library)
        XCTAssertEqual(result.report.removed, [])
        XCTAssertNotNil(board.footprints.first { $0.reference == "H1" })
    }

    func testANewPartGoesBelowTheBoardAndEveryOtherStaysPut() throws {
        let (board, made) = PCBSync.newBoard(try Self.circuit(), title: "Test", library: Self.library)
        let places = Dictionary(uniqueKeysWithValues: board.footprints.map { ($0.uuid, $0.position) })
        var circuit = made.circuit
        circuit.add(Element(kind: .resistor, a: GridPoint(90, 90), b: GridPoint(94, 90), params: ["resistance": 1000]))
        let result = PCBSync.sync(circuit, board: board, library: Self.library)
        XCTAssertEqual(result.report.added.count, 1)
        let edge = try XCTUnwrap(board.outline.first.flatMap { KiCadBox($0.points) })
        let new = try XCTUnwrap(board.footprint(uuid: result.report.added[0]))
        XCTAssertGreaterThan(new.position.y, edge.maxY)
        for footprint in board.footprints where footprint.uuid != new.uuid {
            XCTAssertEqual(footprint.position, places[footprint.uuid], footprint.reference)
        }
    }
}
