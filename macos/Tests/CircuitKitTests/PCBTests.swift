import XCTest
@testable import CircuitKit
import KiCadKit

/// The circuit as its printed circuit board has it: KiCad's netlist of it, and boards KiCad reads
final class PCBTests: XCTestCase {
    static let tl072: [String: Double] = ElementKind.opAmp.models.first { $0.name == "TL072" }?.values ?? [:]

    /// Three op-amps (a TL072 and half of another), a resistor and a transistor, its nets left unnamed but for the
    /// supply
    static func circuit(opAmps: [String] = ["A1", "A2", "A3"]) throws -> Circuit {
        var parts = [
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 15], connections: ["plus": "vcc", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 4700], connections: ["a": "vcc", "b": "x"]),
            NetlistPart(kind: .npn, name: "Q1", params: ElementKind.npn.models.first { $0.name == "2N3904" }?.values ?? [:],
                        connections: ["base": "x", "collector": "vcc", "emitter": "e"]),
            NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 10_000], connections: ["a": "e", "b": "GND"]),
        ]
        for (k, name) in opAmps.enumerated() {
            parts.append(NetlistPart(kind: .opAmp, name: name, params: tl072,
                                     connections: ["plus": "e", "minus": "o\(k)", "out": "o\(k)"]))
        }
        var circuit = try SchematicLayout.layout(parts)
        // the nets as a drawing leaves them: unnamed, but for the supply
        circuit.netNames = circuit.netNames.filter { $0.value == "vcc" }
        return circuit
    }

    func testEveryExampleHasABoardNetlist() {
        for example in Examples.all {
            let board = PCBNetlistBuilder.netlist(example.circuit)
            let references = board.netlist.components.map(\.reference)
            XCTAssertEqual(Set(references).count, references.count, "\(example.id): \(references)")
            for component in board.netlist.components {
                XCTAssertFalse(component.pins.isEmpty, "\(example.id) \(component.reference)")
                XCTAssertTrue(component.footprint.isEmpty == board.unassigned.contains(component.reference) || component.excludeFromBoard,
                              "\(example.id) \(component.reference)")
                for pin in component.pins.values {
                    // in ASCII, and none left with the schematic's passing numbers
                    XCTAssertFalse(pin.net.contains("−"), "\(example.id) \(pin.net)")
                    XCTAssertFalse(pin.net.count > 1 && pin.net.first == "N" && pin.net.dropFirst().allSatisfy(\.isNumber),
                                   "\(example.id) \(component.reference) \(pin.net)")
                }
            }
        }
    }

    func testUnnamedNetsAreNamedAfterTheirFirstPadAndKeepTheirNames() throws {
        let circuit = try Self.circuit()
        let board = PCBNetlistBuilder.netlist(circuit)
        let r1 = try XCTUnwrap(board.netlist.component(reference: "R1"))
        XCTAssertEqual(r1.pins["1"]?.net, "vcc")
        XCTAssertEqual(r1.pins["2"]?.net, "Net-(Q1-Pad2)")
        let q1 = try XCTUnwrap(board.netlist.component(reference: "Q1"))
        // the emitter (E B C), on A3's + input too, the first of the net's pads
        XCTAssertEqual(q1.pins["1"]?.net, "Net-(A3-Pad3)")
        // another part elsewhere moves the schematic's own numbering, not the board's names
        var more = circuit
        more.add(Element(kind: .resistor, a: GridPoint(80, 80), b: GridPoint(84, 80), params: ["resistance": 1000]))
        let again = PCBNetlistBuilder.netlist(more)
        XCTAssertEqual(again.netlist.component(reference: "R1")?.pins, r1.pins)
    }

    func testChipsKeepTheirUnitsAsTheSchematicChanges() throws {
        var circuit = try Self.circuit()
        let board = PCBNetlistBuilder.netlist(circuit)
        let u1 = try XCTUnwrap(board.netlist.components.first { $0.value == "TL072" && $0.ids.count == 2 })
        XCTAssertEqual(u1.units.map(\.pins), [["1", "2", "3"], ["5", "6", "7"]])
        let a3 = try XCTUnwrap(board.netlist.component(reference: "A3"))
        XCTAssertEqual(a3.value, "TL072")
        // the first op-amp goes: the others stay in their packages and units rather than being packed afresh
        circuit.remove(Set(circuit.elements.filter { $0.name == "A1" }.map(\.id)))
        let after = PCBNetlistBuilder.netlist(circuit, design: board.design)
        let kept = try XCTUnwrap(after.netlist.component(reference: u1.reference))
        XCTAssertEqual(kept.ids, [u1.ids[1]], "A2 stays in \(u1.reference)")
        XCTAssertEqual(kept.pins["5"]?.net, u1.pins["5"]?.net, "in unit B")
        XCTAssertEqual(kept.pins["1"]?.net, "unconnected-(\(u1.reference)-Pad1)", "unit A now free")
        XCTAssertEqual(after.netlist.component(reference: "A3")?.ids, a3.ids)
        // and the board, linked to the first unit's id when it was made, finds its footprint again by reference
        XCTAssertEqual(after.design.units.count, 2)
    }

    func testSurfaceMountPartsAndTheirPads() throws {
        var design = PCBDesign()
        design.style = .surfaceMount
        let board = PCBNetlistBuilder.netlist(try Self.circuit(), design: design)
        let byRef = Dictionary(uniqueKeysWithValues: board.netlist.components.map { ($0.reference, $0) })
        XCTAssertEqual(byRef["R1"]?.footprint, "Resistor_SMD:R_0805_2012Metric")
        XCTAssertEqual(byRef["A3"]?.footprint, "Package_SO:SOIC-8_3.9x4.9mm_P1.27mm")
        let q1 = try XCTUnwrap(byRef["Q1"])
        XCTAssertEqual(q1.footprint, "Package_TO_SOT_SMD:SOT-23")
        // SOT-23: base, emitter, collector
        XCTAssertEqual(q1.pins["1"]?.function, "base")
        XCTAssertEqual(q1.pins["2"]?.function, "emitter")
        XCTAssertEqual(q1.pins["3"]?.function, "collector")
    }

    func testAPartsOwnFootprintPinoutAndPlaceOnTheBoard() throws {
        let circuit = try Self.circuit()
        let id = { (name: String) in circuit.elements.first { $0.name == name }!.id.uuidString }
        var design = PCBDesign()
        design.footprints[id("R1")] = "Resistor_SMD:R_1206_3216Metric"
        design.pinouts[id("Q1")] = "CBE"
        design.offBoard.insert(id("R2"))
        design.doNotPopulate.insert(id("A3"))
        let board = PCBNetlistBuilder.netlist(circuit, design: design)
        XCTAssertEqual(board.netlist.component(reference: "R1")?.footprint, "Resistor_SMD:R_1206_3216Metric")
        XCTAssertEqual(board.netlist.component(reference: "Q1")?.pins["1"]?.function, "collector")
        XCTAssertEqual(board.netlist.component(reference: "R2")?.excludeFromBoard, true)
        XCTAssertEqual(board.netlist.component(reference: "A3")?.doNotPopulate, true)
    }

    // MARK: - With KiCad

    static func kicad() throws -> KiCadInstallation {
        guard let installation = KiCadInstallation.find() else { throw XCTSkip("KiCad is not installed") }
        if let problem = installation.problem { throw XCTSkip(problem) }
        return installation
    }

    /// A folder with a footprint library table of KiCad's stock libraries, so KiCad checks each footprint against its
    /// library even where it has never been run
    func project(_ installation: KiCadInstallation) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jspice-pcb-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        if let stock = installation.footprints, let names = try? FileManager.default.contentsOfDirectory(atPath: stock.path) {
            let rows = names.filter { $0.hasSuffix(".pretty") }.sorted().map { name in
                SExpr("lib", SExpr("name", String(name.dropLast(7))), SExpr("type", "KiCad"),
                      SExpr("uri", stock.appendingPathComponent(name).path), SExpr("options", ""), SExpr("descr", ""))
            }
            try SExpr("fp_lib_table", [SExpr("version", 7)] + rows).formatted(.libraryTable)
                .write(to: folder.appendingPathComponent("fp-lib-table"), atomically: true, encoding: .utf8)
        }
        return folder
    }

    func testEveryExampleGoesOnABoardKiCadReads() throws {
        let installation = try Self.kicad()
        let folder = try project(installation)
        let library = KiCadFootprintLibrary(installation: installation, projectFolder: folder)
        let fab = KiCadFabrication(installation: installation)
        for (n, example) in Examples.all.enumerated() {
            let result = PCBNetlistBuilder.netlist(example.circuit)
            let board = KiCadProject.newBoard(title: example.title)
            let report = NetlistUpdater.update(board, to: result.netlist, library: library)
            // every footprint found, every pin on a pad of it (but the parts JSpice leaves for KiCad's assignment)
            let errors = report.errors.filter { e in !result.unassigned.contains { e.text == "No footprint is assigned to \($0)." } }
            XCTAssertEqual(errors.map { $0.text }, [String](), example.id)
            KiCadProject.arrangeNewBoard(board, order: board.footprints)
            // KiCad itself on every eighth: it reads the board, its footprints are its libraries', none overlap, and
            // the connections it finds unrouted are the ones JSpice's ratsnest draws
            guard n % 8 == 0 else { continue }
            let file = folder.appendingPathComponent("\(example.id).kicad_pcb")
            try board.write(to: file)
            let drc = try fab.drc(file)
            let types = Set(drc.violations.map(\.type))
            for bad in ["lib_footprint_mismatch", "lib_footprint_issues", "courtyards_overlap", "shorting_items", "duplicate_footprints"] {
                XCTAssertFalse(types.contains(bad), "\(example.id): \(drc.violations.filter { $0.type == bad }.map(\.description))")
            }
            XCTAssertEqual(drc.unconnected.count, KiCadConnectivity(board).ratsnest().count, example.id)
        }
    }
}
