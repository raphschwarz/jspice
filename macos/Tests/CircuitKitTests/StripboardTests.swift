import XCTest
@testable import CircuitKit

/// Stripboard: every leg on a piece of strip of its own net, the strips cut between nets, chips' pins where the
/// datasheets put them
final class StripboardTests: XCTestCase {
    func testEveryExampleIsConnectedExactlyAsDrawn() {
        var report: [String] = []
        for example in Examples.all {
            let layout = Stripboard.layout(example.circuit)
            // how tidy: the links' count and length in holes, and the board's size
            let lengths = layout.links.map { abs($0.from.row - $0.to.row) + abs($0.from.column - $0.to.column) }
            report.append(String(format: "%-22@ %2d × %3d  %3d links, %4d holes long, longest %2d", example.id as NSString,
                                 layout.rows, layout.columns, lengths.count, lengths.reduce(0, +), lengths.max() ?? 0))
            XCTAssertEqual(Stripboard.verify(layout), [], "\(example.id): \(layout.notes)")
            let placed = layout.placements.map { $0.name + " " + $0.title } + layout.offBoard.map(\.name)
            for element in example.circuit.flattened(expandingModels: false).elements
                where ![.wire, .ground, .netLabel, .port, .block, .probe].contains(element.kind) {
                XCTAssertTrue(placed.contains { $0.hasPrefix(element.name + " ") || $0 == element.name || $0.contains(element.name + ",") || $0.contains(element.name + ")") },
                              "\(example.id): \(element.name) is nowhere")
            }
            // parts stand across the strips, both legs in one column
            for placement in layout.placements where placement.legs.count == 2 {
                XCTAssertEqual(placement.legs[0].hole.column, placement.legs[1].hole.column, "\(example.id): \(placement.name)")
                XCTAssertGreaterThanOrEqual(abs(placement.legs[0].hole.row - placement.legs[1].hole.row), Stripboard.minimumSpan(placement.style),
                                            "\(example.id): \(placement.name)")
            }
        }
        print("Stripboard layouts (strips × holes, links):\n" + report.joined(separator: "\n"))
    }

    private func layout(_ parts: [NetlistPart]) throws -> Stripboard.Layout {
        let layout = Stripboard.layout(try SchematicLayout.layout(parts))
        XCTAssertEqual(Stripboard.verify(layout), [])
        return layout
    }

    func testChipsStraddleACutWithTheirDatasheetPins() throws {
        let tl072 = Examples.model(.opAmp, "TL072")
        let layout = try layout([
            NetlistPart(kind: .acVoltage, name: "VIN", params: ["amplitude": 0.1, "frequency": 1000], connections: ["plus": "in", "minus": "GND"]),
            NetlistPart(kind: .opAmp, name: "OA1", params: tl072, connections: ["minus": "fb1", "plus": "in", "out": "o1"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 10_000], connections: ["a": "o1", "b": "fb1"]),
            NetlistPart(kind: .resistor, name: "R2", params: ["resistance": 1000], connections: ["a": "fb1", "b": "GND"]),
            NetlistPart(kind: .opAmp, name: "OA2", params: tl072, connections: ["minus": "o2", "plus": "o1", "out": "o2"]),
            NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 10_000], connections: ["a": "o2", "b": "GND"]),
        ])
        let chip = try XCTUnwrap(layout.placements.first { if case .dip = $0.style { return true }; return false })
        func leg(_ pin: Int) throws -> Stripboard.Leg { try XCTUnwrap(chip.legs.first { $0.name.hasPrefix("\(pin) ") }) }
        // TL072: 1 OUT A, 2 −IN A, 3 +IN A, 4 V−, 5 +IN B, 6 −IN B, 7 OUT B, 8 V+
        XCTAssertEqual(try leg(1).net, "o1")
        XCTAssertEqual(try leg(2).net, "fb1")
        XCTAssertEqual(try leg(3).net, "in")
        XCTAssertEqual(try leg(4).net, "−15V")
        XCTAssertEqual(try leg(5).net, "o1")
        XCTAssertEqual(try leg(6).net, "o2")
        XCTAssertEqual(try leg(7).net, "o2")
        XCTAssertEqual(try leg(8).net, "+15V")
        // pin 1 top left, 1–4 down the left, 5–8 back up the right, three holes across
        let p1 = try leg(1).hole, p4 = try leg(4).hole, p5 = try leg(5).hole, p8 = try leg(8).hole
        XCTAssertEqual(p4.column, p1.column)
        XCTAssertEqual(p4.row, p1.row + 3)
        XCTAssertEqual(p8.row, p1.row)
        XCTAssertEqual(p5.row, p4.row)
        XCTAssertEqual(p8.column, p1.column + 3)
        // each strip under the chip is cut between its rows, unless both pins are on one net
        for row in p1.row...p4.row {
            let left = chip.legs.first { $0.hole == Stripboard.Hole(row: row, column: p1.column) }!
            let right = chip.legs.first { $0.hole == Stripboard.Hole(row: row, column: p8.column) }!
            let cut = layout.cuts.contains { $0.row == row && $0.column > p1.column && $0.column < p8.column }
            XCTAssertEqual(cut, left.net != right.net, "row \(row)")
        }
        // the supplies on their strips
        XCTAssertEqual(Set(layout.buses.values), ["GND", "+15V", "−15V"])
        XCTAssertTrue(layout.bom.contains { $0.description == "DIP-8 socket" })
    }

    func testTransistorsStandAcrossThreeStrips() throws {
        let layout = try layout([
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 9], connections: ["plus": "vcc", "minus": "GND"]),
            NetlistPart(kind: .resistor, name: "RB", params: ["resistance": 100_000], connections: ["a": "vcc", "b": "b"]),
            NetlistPart(kind: .resistor, name: "RC", params: ["resistance": 4700], connections: ["a": "vcc", "b": "c"]),
            NetlistPart(kind: .npn, name: "Q1", params: Examples.model(.npn, "2N3904"), connections: ["base": "b", "collector": "c", "emitter": "GND"]),
            NetlistPart(kind: .potentiometer, name: "VOL", params: ["resistance": 10_000], connections: ["a": "c", "wiper": "out", "b": "GND"]),
            NetlistPart(kind: .resistor, name: "RL", params: ["resistance": 100_000], connections: ["a": "out", "b": "GND"]),
        ])
        let q1 = try XCTUnwrap(layout.placements.first { $0.name == "Q1" })
        XCTAssertEqual(q1.legs.map(\.name), ["emitter", "base", "collector"], "a 2N3904 runs E B C")
        XCTAssertEqual(Set(q1.legs.map(\.hole.column)).count, 1)
        let rows = q1.legs.map(\.hole.row)
        XCTAssertTrue(rows == [rows[0], rows[0] + 1, rows[0] + 2] || rows == [rows[0], rows[0] - 1, rows[0] - 2], "\(rows)")
        // the emitter, on ground, goes straight into the ground strip: the transistor turned round to reach it
        XCTAssertEqual(layout.buses[q1.legs[0].hole.row], "GND")
        XCTAssertTrue(q1.note?.contains("to the right, legs from the bottom: E B C") ?? false, q1.note ?? "")
        // the pot goes on the panel, wired by its lugs
        let pot = try XCTUnwrap(layout.offBoard.first { $0.name == "VOL" })
        XCTAssertEqual(pot.wires.map(\.name), ["lug 1", "lug 2", "lug 3"])
        XCTAssertEqual(pot.wires.map(\.net), ["c", "out", "GND"])
    }

    func testVerifyCatchesAMissingCut() throws {
        var layout = Stripboard.layout(Examples.all.first { $0.id == "fuzz" }!.circuit)
        XCTAssertEqual(Stripboard.verify(layout), [])
        XCTAssertFalse(layout.cuts.isEmpty)
        layout.cuts.removeFirst()
        XCTAssertFalse(Stripboard.verify(layout).isEmpty)
        XCTAssertEqual(Stripboard.letters(0), "A")
        XCTAssertEqual(Stripboard.letters(27), "AB")
    }
}
