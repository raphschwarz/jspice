import XCTest
@testable import CircuitKit

/// Perfboard and half-size breadboards: every example connected exactly as drawn on each
final class PerfboardTests: XCTestCase {
    func testEveryExampleIsConnectedExactlyAsDrawnOnPerfboard() {
        var report: [String] = []
        for example in Examples.all {
            let layout = Perfboard.layout(example.circuit)
            XCTAssertEqual(Perfboard.verify(layout), [], "\(example.id): \(layout.notes)")
            // every part is somewhere, as on stripboard
            let placed = layout.placements.map { $0.name + " " + $0.title } + layout.offBoard.map(\.name)
            for element in example.circuit.flattened(expandingModels: false).elements
                where ![.wire, .ground, .netLabel, .port, .block, .probe, .loopProbe].contains(element.kind) {
                XCTAssertTrue(placed.contains { $0.hasPrefix(element.name + " ") || $0 == element.name || $0.contains(element.name + ",") || $0.contains(element.name + ")") },
                              "\(example.id): \(element.name) is nowhere")
            }
            // no strips to cut, and a board and wire to buy
            XCTAssertFalse(layout.notes.contains { $0.hasPrefix("Cut the strips") }, example.id)
            XCTAssertTrue(layout.bom.contains { $0.description.hasPrefix("perfboard") }, example.id)
            XCTAssertFalse(layout.bom.contains { $0.description.hasPrefix("stripboard") }, example.id)
            for trail in layout.trails { XCTAssertLessThan(trail.from, trail.to, "\(example.id): a trail joins two pads or more") }
            let length = layout.trails.reduce(0) { $0 + $1.to - $1.from }
            report.append(String(format: "%-22@ %2d × %3d  %3d trails, %4d holes long, %3d links", example.id as NSString,
                                 layout.rows, layout.columns, layout.trails.count, length, layout.links.count))
        }
        print("Perfboard layouts (rows × holes, trails, links):\n" + report.joined(separator: "\n"))
    }

    /// A trail run over a pad of another net shorts them, and `verify` says so; a net left without its trail is split
    func testVerifyCatchesATrailOverAnotherNetsPad() throws {
        var layout = Perfboard.layout(try XCTUnwrap(Examples.all.first { $0.id == "fuzz" }).circuit)
        XCTAssertEqual(Perfboard.verify(layout), [])
        let trail = try XCTUnwrap(layout.trails.first)
        // stretched to the next pad in use on its row, of another net
        let others = layout.nets.filter { $0.key.row == trail.row && $0.key.column > trail.to && !$0.value.isEmpty && $0.value != trail.net }
        if let next = others.min(by: { $0.key.column < $1.key.column }) {
            var stretched = layout
            stretched.trails[0].to = next.key.column
            XCTAssertTrue(Perfboard.verify(stretched).contains { $0.hasPrefix("The board joins nets that should be apart") },
                          "\(Perfboard.verify(stretched))")
        }
        layout.trails.removeFirst()
        XCTAssertTrue(Perfboard.verify(layout).contains { $0.contains("places the board does not join") }, "\(Perfboard.verify(layout))")
    }

    /// Where the circuit's resting voltages cannot be found, an electrolytic's polarity is not guessed from them: its
    /// note and the board's say to follow the schematic
    func testUnknownRestingVoltagesAreSaid() {
        let electrolytic = NetlistPart(kind: .capacitor, name: "C1", params: ["capacitance": 10e-6], connections: ["a": "GND", "b": "x"])
        XCTAssertTrue(Breadboard.describe(electrolytic, [:]).2?.contains("resting voltages are unknown") == true)
        XCTAssertTrue(Breadboard.describe(electrolytic, ["GND": 0, "x": 0]).2?.hasPrefix("No DC across it") == true)
        var plan = Breadboard.Plan()
        XCTAssertTrue(plan.supplyNotes.isEmpty)
        plan.restingFound = false
        XCTAssertTrue(plan.supplyNotes.contains { $0.hasPrefix("JSpice could not find the voltages this circuit rests at") })
    }

    func testEveryExampleIsConnectedExactlyAsDrawnOnHalfSizeBreadboards() {
        for example in Examples.all {
            let layout = Breadboard.layout(example.circuit, size: .half)
            XCTAssertEqual(Breadboard.verify(layout), [], example.id)
            XCTAssertEqual(layout.size, .half)
            // a whole number of boards, each in the bill of materials
            XCTAssertEqual(layout.width % 30, 0, example.id)
            XCTAssertEqual(layout.bom.first { $0.description == "solderless breadboard, half size (400 points)" }?.quantity, layout.boards, example.id)
            if layout.boards > 1 { XCTAssertTrue(layout.notes.contains { $0.contains("half-size breadboards") }, example.id) }
        }
        // a full-size board is one board of 63 columns for a small circuit
        let small = Breadboard.layout(Examples.all.first { $0.id == "fuzz" }!.circuit)
        XCTAssertEqual(small.boards, 1)
        XCTAssertEqual(small.width, 63)
        XCTAssertEqual(small.bom.first { $0.description == "solderless breadboard, full size (830 points)" }?.quantity, 1)
    }
}
