import XCTest
@testable import CircuitKit

/// The breadboard: every leg in a hole of its own net, the pins where the datasheets put them
final class BreadboardTests: XCTestCase {
    func testEveryExampleIsConnectedExactlyAsDrawn() {
        for example in Examples.all {
            let layout = Breadboard.layout(example.circuit)
            XCTAssertEqual(Breadboard.verify(layout), [], example.id)
            // every part is somewhere: on the board, in a package, or off it
            let placed = layout.placements.map { $0.name + " " + $0.title } + layout.offBoard.map(\.name)
            for element in example.circuit.flattened(expandingModels: false).elements
                where ![.wire, .ground, .netLabel, .port, .block, .probe, .loopProbe].contains(element.kind) {
                XCTAssertTrue(placed.contains { $0.hasPrefix(element.name + " ") || $0 == element.name || $0.contains(element.name + ",") || $0.contains(element.name + ")") },
                              "\(example.id): \(element.name) is nowhere")
            }
        }
    }

    private func layout(_ parts: [NetlistPart]) throws -> Breadboard.Layout {
        let layout = Breadboard.layout(try SchematicLayout.layout(parts))
        XCTAssertEqual(Breadboard.verify(layout), [])
        return layout
    }

    private func leg(_ placement: Breadboard.Placement, pin: Int) -> Breadboard.Leg? {
        placement.legs.first { $0.name.hasPrefix("\(pin) ") }
    }

    func testOpAmpsArePackedIntoDualsWithTheirDatasheetPins() throws {
        let tl072 = Examples.model(.opAmp, "TL072")
        let layout = try layout([
            NetlistPart(kind: .acVoltage, name: "VIN", params: ["amplitude": 0.1, "frequency": 1000], connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .opAmp, name: "OA1", params: tl072, connections: ["minus": "fb1", "plus": "in", "out": "o1"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 10_000], connections: ["a": "o1", "b": "fb1"]),
            NetlistPart(kind: .opAmp, name: "OA2", params: tl072, connections: ["minus": "fb2", "plus": "o1", "out": "o2"]),
            NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 10_000], connections: ["a": "o2", "b": "fb2"]),
            NetlistPart(kind: .opAmp, name: "OA3", params: tl072, connections: ["minus": "o3", "plus": "o2", "out": "o3"]),
            NetlistPart(kind: .resistor, name: "R3", params: ["resistance": 10_000], connections: ["a": "o3", "b": "GND"]),
        ])
        let chips = layout.placements.filter { if case .dip = $0.style { return true }; return false }
        XCTAssertEqual(chips.count, 2, "three op-amps in two TL072s")
        let first = try XCTUnwrap(chips.first { $0.title.contains("OA1") })
        // TL072: 1 OUT A, 2 −IN A, 3 +IN A, 4 V−, 5 +IN B, 6 −IN B, 7 OUT B, 8 V+
        XCTAssertEqual(leg(first, pin: 1)?.net, "o1")
        XCTAssertEqual(leg(first, pin: 2)?.net, "fb1")
        XCTAssertEqual(leg(first, pin: 3)?.net, "in")
        XCTAssertEqual(leg(first, pin: 5)?.net, "o1")
        XCTAssertEqual(leg(first, pin: 6)?.net, "fb2")
        XCTAssertEqual(leg(first, pin: 7)?.net, "o2")
        XCTAssertEqual(leg(first, pin: 4)?.net, "−15V")
        XCTAssertEqual(leg(first, pin: 8)?.net, "+15V")
        let second = try XCTUnwrap(chips.first { $0.title.contains("OA3") || $0.name == "OA3" })
        XCTAssertTrue(second.note?.contains("unused") ?? false)
        // pin 1 at the bottom left, across the channel: 1–4 along row f, 5–8 back along row e
        guard case .strip(let c1, 5) = try XCTUnwrap(leg(first, pin: 1)).hole,
              case .strip(let c8, 4) = try XCTUnwrap(leg(first, pin: 8)).hole,
              case .strip(let c4, 5) = try XCTUnwrap(leg(first, pin: 4)).hole,
              case .strip(let c5, 4) = try XCTUnwrap(leg(first, pin: 5)).hole else { return XCTFail("pins not across the channel") }
        XCTAssertEqual(c8, c1)
        XCTAssertEqual(c4, c1 + 3)
        XCTAssertEqual(c5, c4)
        // the supplies on the rails, with a note that the circuit needs them
        XCTAssertEqual(Set(layout.rails.values), ["GND", "+15V", "−15V"])
        XCTAssertTrue(layout.notes.contains { $0.contains("+15V") })
    }

    func testTransistorLegsFollowTheirPinouts() throws {
        let layout = try layout([
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 9], connections: ["plus": "vcc", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "RB", params: ["resistance": 100_000], connections: ["a": "vcc", "b": "b"]),
            NetlistPart(kind: .resistor, name: "RC", params: ["resistance": 4700], connections: ["a": "vcc", "b": "c"]),
            NetlistPart(kind: .npn, name: "Q1", params: Examples.model(.npn, "BC547C"), connections: ["base": "b", "collector": "c", "emitter": "GND"]),
            NetlistPart(kind: .njfet, name: "J1", params: Examples.model(.njfet, "2N3819"), connections: ["gate": "GND", "drain": "c", "source": "s"]),
            NetlistPart(kind: .resistor, name: "RS", params: ["resistance": 1000], connections: ["a": "s", "b": "GND"]),
        ])
        let q1 = try XCTUnwrap(layout.placements.first { $0.name == "Q1" })
        XCTAssertEqual(q1.style, .transistor(pinout: "CBE"))
        XCTAssertEqual(q1.legs.map(\.name), ["collector", "base", "emitter"])
        XCTAssertEqual(q1.legs.map(\.hole.column), [q1.legs[0].hole.column, q1.legs[0].hole.column + 1, q1.legs[0].hole.column + 2])
        let j1 = try XCTUnwrap(layout.placements.first { $0.name == "J1" })
        XCTAssertEqual(j1.legs.map(\.name), ["source", "gate", "drain"], "the 2N3819 runs S G D")
        XCTAssertEqual(Breadboard.transistor(NetlistPart(kind: .njfet, params: Examples.model(.njfet, "J201"))).pinout, "DSG")
        XCTAssertEqual(Breadboard.transistor(NetlistPart(kind: .npn, params: Examples.model(.npn, "2N3904"))).pinout, "EBC")
    }

    func testElectrolyticsGoTheRightWayRoundAndTheBOMCounts() throws {
        let layout = try layout([
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 9], connections: ["plus": "vcc", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 10_000], connections: ["a": "vcc", "b": "mid"]),
            NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 10_000], connections: ["a": "mid", "b": "GND"]),
            // the − end at the 4.5 V divider, the + end... at ground: the + lead must go to the divider
            NetlistPart(kind: .capacitor, name: "C1", params: ["capacitance": 10e-6], connections: ["a": "GND", "b": "mid"]),
            NetlistPart(kind: .capacitor, name: "C2", params: ["capacitance": 100e-9], connections: ["a": "mid", "b": "out"]),
            NetlistPart(kind: .resistor, name: "R3", params: ["resistance": 1e6], connections: ["a": "out", "b": "GND"]),
        ])
        let c1 = try XCTUnwrap(layout.placements.first { $0.name == "C1" })
        XCTAssertEqual(c1.style, .electrolytic)
        XCTAssertEqual(c1.legs.first { $0.name == "+" }?.net, "mid")
        XCTAssertEqual(c1.legs.first { $0.name == "−" }?.net, "GND")
        XCTAssertTrue(c1.title.contains("10 V"), c1.title)
        let resistors = try XCTUnwrap(layout.bom.first { $0.description.hasPrefix("10 kΩ resistor") })
        XCTAssertEqual(resistors.quantity, 2)
        XCTAssertEqual(Set(resistors.parts), ["R1", "R2"])
        XCTAssertNotNil(layout.bom.first { $0.description.contains("ceramic") })
        XCTAssertNotNil(layout.bom.first { $0.description.contains("Power supply") })
    }

    func testVerifyCatchesAMistake() throws {
        var layout = Breadboard.layout(Examples.all.first { $0.id == "fuzz" }!.circuit)
        XCTAssertEqual(Breadboard.verify(layout), [])
        // move one leg into a strip of another net
        let k = try XCTUnwrap(layout.placements.firstIndex { $0.legs.count == 3 })
        layout.placements[k].legs[0].hole = layout.placements[k].legs[1].hole
        XCTAssertFalse(Breadboard.verify(layout).isEmpty)
    }
}
