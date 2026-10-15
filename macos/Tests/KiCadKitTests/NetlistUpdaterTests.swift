import XCTest
@testable import KiCadKit

/// Footprints from the test's fixtures, by Library:Name
struct FixtureFootprints: KiCadFootprintSource {
    static let files = [
        "Resistor_SMD:R_0805_2012Metric": "R_0805_2012Metric.kicad_mod",
        "Package_DIP:DIP-8_W7.62mm": "DIP-8_W7.62mm.kicad_mod",
        "Package_TO_SOT_THT:TO-92_Inline": "flipped/TO-92_Inline.kicad_mod",
        "LED_THT:LED_D5.0mm": "flipped/LED_D5.0mm.kicad_mod",
        "Capacitor_THT:CP_Radial_D5.0mm_P2.00mm": "flipped/CP_Radial_D5.0mm_P2.00mm.kicad_mod",
    ]

    func footprint(_ libID: String) throws -> SExpr {
        guard let file = Self.files[libID] else { throw KiCadFootprintLibrary.LoadError.noFootprint(libID) }
        return try SExpr.parse(SExpressionTests.fixture(file))
    }
}

/// A board brought up to date with its schematic as KiCad's Update PCB from Schematic brings it
final class NetlistUpdaterTests: XCTestCase {
    static let r1 = "11111111-1111-4111-8111-111111111111"
    static let ua = "22222222-2222-4222-8222-222222222222"
    static let ub = "33333333-3333-4333-8333-333333333333"
    static let q1 = "44444444-4444-4444-8444-444444444444"

    /// A resistor from VCC to OUT, a TL072 (both halves) and a transistor
    static func netlist(value: String = "10k", resistorFootprint: String = "Resistor_SMD:R_0805_2012Metric",
                        outNet: String = "OUT") -> PCBNetlist {
        var r = PCBNetlist.Component(reference: "R1", value: value, footprint: resistorFootprint, ids: [r1],
                                     pins: ["1": .init(net: "VCC"), "2": .init(net: outNet)])
        r.fields = [("Datasheet", ""), ("Description", "Resistor")]
        var u = PCBNetlist.Component(reference: "U1", value: "TL072", footprint: "Package_DIP:DIP-8_W7.62mm", ids: [ua, ub], pins: [
            "1": .init(net: outNet, function: "out", type: "output"), "2": .init(net: outNet, function: "-", type: "input"),
            "3": .init(net: "IN", function: "+", type: "input"), "4": .init(net: "GND", function: "V-", type: "power_in"),
            "5": .init(net: "unconnected-(U1-Pad5)", function: "+", type: "input+no_connect"),
            "6": .init(net: "unconnected-(U1-Pad6)", function: "-", type: "input+no_connect"),
            "7": .init(net: "unconnected-(U1-Pad7)", function: "out", type: "output+no_connect"),
            "8": .init(net: "VCC", function: "V+", type: "power_in"),
        ])
        u.fields = [("Datasheet", ""), ("Description", "Dual op-amp")]
        u.units = [.init(name: "A", pins: ["1", "2", "3"]), .init(name: "B", pins: ["5", "6", "7"])]
        var q = PCBNetlist.Component(reference: "Q1", value: "2N3904", footprint: "Package_TO_SOT_THT:TO-92_Inline", ids: [q1],
                                     pins: ["1": .init(net: "GND"), "2": .init(net: "IN"), "3": .init(net: outNet)])
        q.fields = [("Datasheet", ""), ("Description", "NPN transistor")]
        return PCBNetlist(components: [r, u, q])
    }

    static func newBoard(_ netlist: PCBNetlist = netlist()) -> (KiCadBoard, NetlistUpdater.Report) {
        let board = KiCadProject.newBoard(title: "Test", date: Date(timeIntervalSince1970: 0))
        let report = NetlistUpdater.update(board, to: netlist, library: FixtureFootprints())
        return (board, report)
    }

    func testANewBoardGetsEveryPartWithTheNetsOnItsPads() throws {
        let (board, report) = Self.newBoard()
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(board.footprints.map(\.reference).sorted(), ["Q1", "R1", "U1"])
        let r1 = try XCTUnwrap(board.footprints.first { $0.reference == "R1" })
        XCTAssertEqual(r1.libID, "Resistor_SMD:R_0805_2012Metric")
        XCTAssertEqual(r1.value, "10k")
        XCTAssertEqual(r1.path, "/" + Self.r1)
        XCTAssertEqual(r1.pads.map { $0.net ?? "" }, ["VCC", "OUT"])
        XCTAssertEqual(r1.property("Description"), "Resistor")
        let u1 = try XCTUnwrap(board.footprints.first { $0.reference == "U1" })
        // linked to its first unit's id; each pad on its net with the pin's name and type
        XCTAssertEqual(u1.path, "/" + Self.ua)
        XCTAssertEqual(u1.pads(numbered: "8").first?.net, "VCC")
        XCTAssertEqual(u1.pads(numbered: "1").first?.pinFunction, "out")
        XCTAssertEqual(u1.pads(numbered: "5").first?.pinType, "input+no_connect")
        XCTAssertEqual(u1.units, [.init(name: "A", pins: ["1", "2", "3"]), .init(name: "B", pins: ["5", "6", "7"])])
        XCTAssertTrue(report.actions.contains { $0.text == "Add U1 (footprint 'Package_DIP:DIP-8_W7.62mm')." })
        // and it reads back as it was written
        let again = try KiCadBoard(text: board.text)
        XCTAssertEqual(again.footprints.count, 3)
        XCTAssertEqual(again.netNames, board.netNames)
    }

    func testUpdatingAgainChangesNothing() throws {
        let (board, _) = Self.newBoard()
        let before = board.text
        let report = NetlistUpdater.update(board, to: Self.netlist(), library: FixtureFootprints())
        XCTAssertEqual(report.actions, [])
        XCTAssertEqual(board.text, before)
    }

    func testAValueChangeAndARenameReachTheBoardAndNothingMoves() throws {
        let (board, _) = Self.newBoard()
        let r1 = try XCTUnwrap(board.footprints.first { $0.reference == "R1" })
        r1.move(to: KiCadPoint(50, 50), rotation: 90)
        var netlist = Self.netlist(value: "4k7")
        netlist.components[0].reference = "R7"
        // a dry run says what would change and changes nothing
        let dry = NetlistUpdater.update(board, to: netlist, library: FixtureFootprints(), dryRun: true)
        XCTAssertEqual(dry.actions.map(\.text), ["Change R1 reference designator to R7.", "Change R7 value from 10k to 4k7."])
        XCTAssertEqual(board.footprints.first { $0.uuid == r1.uuid }?.reference, "R1")
        NetlistUpdater.update(board, to: netlist, library: FixtureFootprints())
        let r7 = try XCTUnwrap(board.footprints.first { $0.uuid == r1.uuid })
        XCTAssertEqual(r7.reference, "R7")
        XCTAssertEqual(r7.value, "4k7")
        XCTAssertEqual(r7.position, KiCadPoint(50, 50))
        XCTAssertEqual(r7.rotation, 90)
    }

    func testAPartGoneFromTheSchematicLeavesTheBoardUnlessLocked() throws {
        let (board, _) = Self.newBoard()
        var netlist = Self.netlist()
        netlist.components.removeAll { $0.reference == "Q1" }
        let report = NetlistUpdater.update(board, to: netlist, library: FixtureFootprints())
        XCTAssertEqual(board.footprints.map(\.reference).sorted(), ["R1", "U1"])
        XCTAssertEqual(report.removed.count, 1)

        let (locked, _) = Self.newBoard()
        locked.footprints.first { $0.reference == "Q1" }!.node.set(SExpr("locked", Keyword("yes")), after: ["footprint"])
        let kept = NetlistUpdater.update(locked, to: netlist, library: FixtureFootprints())
        XCTAssertEqual(locked.footprints.count, 3)
        XCTAssertEqual(kept.warnings.map(\.text), ["Cannot remove unused footprint Q1 (locked)."])
    }

    func testANewFootprintIsExchangedWhereTheOldOneStood() throws {
        let (board, _) = Self.newBoard()
        let old = try XCTUnwrap(board.footprints.first { $0.reference == "R1" })
        old.move(to: KiCadPoint(40, 30), rotation: 180)
        old.flip()
        let (uuid, padIDs) = (old.uuid, old.pads.map(\.uuid))
        NetlistUpdater.update(board, to: Self.netlist(resistorFootprint: "LED_THT:LED_D5.0mm"), library: FixtureFootprints())
        let new = try XCTUnwrap(board.footprints.first { $0.reference == "R1" })
        XCTAssertEqual(new.libID, "LED_THT:LED_D5.0mm")
        XCTAssertEqual(new.uuid, uuid)
        XCTAssertEqual(new.position, KiCadPoint(40, 30))
        XCTAssertEqual(new.layer, "B.Cu")
        XCTAssertEqual(new.rotation, old.rotation)
        XCTAssertEqual(new.pads.map(\.uuid), padIDs)
        XCTAssertEqual(new.pads.map { $0.net ?? "" }, ["VCC", "OUT"])
        XCTAssertEqual(board.footprints.count, 3)
    }

    func testTracksAndZonesFollowTheirPadsToARenamedNet() throws {
        let (board, _) = Self.newBoard()
        let r1 = try XCTUnwrap(board.footprints.first { $0.reference == "R1" })
        let pad = try XCTUnwrap(r1.pads(numbered: "2").first)
        // a track from R1's pad 2 out to a via, both on OUT, and a zone on OUT
        let end = pad.position + KiCadPoint(5, 0)
        board.root.items.append(SExpr("segment", SExpr("start", pad.position.x, pad.position.y), SExpr("end", end.x, end.y),
                                      SExpr("width", 0.25), SExpr("layer", "F.Cu"), SExpr("net", "OUT"), SExpr("uuid", KiCadBoard.newUUID())))
        board.root.items.append(SExpr("via", SExpr("at", end.x, end.y), SExpr("size", 0.6), SExpr("drill", 0.3),
                                      SExpr("layers", "F.Cu", "B.Cu"), SExpr("net", "OUT"), SExpr("uuid", KiCadBoard.newUUID())))
        board.root.items.append(try SExpr.parse("""
            (zone (net "OUT") (layer "B.Cu") (uuid "\(KiCadBoard.newUUID())") (hatch edge 0.5) (connect_pads (clearance 0.5)) \
            (min_thickness 0.25) (fill (thermal_gap 0.5) (thermal_bridge_width 0.5)) (polygon (pts (xy 0 0) (xy 10 0) (xy 10 10) (xy 0 10))))
            """))
        let report = NetlistUpdater.update(board, to: Self.netlist(outNet: "AMP_OUT"), library: FixtureFootprints())
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(board.tracks.first?.net, "AMP_OUT")
        XCTAssertEqual(board.vias.first?.net, "AMP_OUT")
        XCTAssertEqual(board.zones.first?.net, "AMP_OUT")
        XCTAssertFalse(board.netNames.contains("OUT"))
    }

    func testAMissingFootprintOrPadIsAnError() throws {
        var netlist = Self.netlist()
        netlist.components[0].footprint = "Resistor_SMD:R_0402"
        netlist.components[2].pins["4"] = .init(net: "GND")
        let (board, report) = Self.newBoard(netlist)
        XCTAssertEqual(board.footprints.count, 2)
        XCTAssertEqual(report.errors.count, 2)
        XCTAssertTrue(report.errors[0].text.hasPrefix("Cannot add R1: footprint 'Resistor_SMD:R_0402' not found"))
        XCTAssertEqual(report.errors[1].text, "Q1 pad 4 not found in Package_TO_SOT_THT:TO-92_Inline.")
    }

    func testANetlistForKiCadsOwnImport() throws {
        let text = Self.netlist().kicadNetlist(source: "test.jspice", date: Date(timeIntervalSince1970: 0))
        let tree = try SExpr.parse(text)
        XCTAssertEqual(tree["version"]?.text(at: 0), "E")
        XCTAssertEqual(tree["components"]?.all("comp").count, 3)
        let nets = try XCTUnwrap(tree["nets"]?.all("net"))
        XCTAssertEqual(nets.first?["name"]?.text(at: 0), "GND")
        let u1 = try XCTUnwrap(tree["components"]?.all("comp").first { $0.value("ref") == "U1" })
        XCTAssertEqual(u1.value("tstamps"), "\(Self.ua) \(Self.ub)")
    }
}
