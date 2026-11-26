import XCTest
@testable import CircuitKit

/// The canvas's wiring, free terminals, paste placement and in-place values
final class CanvasGeometryTests: XCTestCase {
    private let o = GridPoint(0, 0)

    func testElbowGoesAcrossThenDownOrDownThenAcross() {
        let b = GridPoint(4, 3)
        XCTAssertEqual(CanvasGeometry.elbow(from: o, to: b, horizontalFirst: true),
                       [WireSegment(o, GridPoint(4, 0)), WireSegment(GridPoint(4, 0), b)])
        XCTAssertEqual(CanvasGeometry.elbow(from: o, to: b, horizontalFirst: false),
                       [WireSegment(o, GridPoint(0, 3)), WireSegment(GridPoint(0, 3), b)])
        // backwards and upwards too
        XCTAssertEqual(CanvasGeometry.elbow(from: b, to: o, horizontalFirst: true),
                       [WireSegment(b, GridPoint(0, 3)), WireSegment(GridPoint(0, 3), o)])
    }

    func testElbowDegenerateCases() {
        XCTAssertEqual(CanvasGeometry.elbow(from: o, to: o, horizontalFirst: true), [])
        // in line: one segment, whichever way it was meant to start
        XCTAssertEqual(CanvasGeometry.elbow(from: o, to: GridPoint(5, 0), horizontalFirst: false), [WireSegment(o, GridPoint(5, 0))])
        XCTAssertEqual(CanvasGeometry.elbow(from: o, to: GridPoint(0, -2), horizontalFirst: true), [WireSegment(o, GridPoint(0, -2))])
        // straight (⇧): one segment at any angle
        XCTAssertEqual(CanvasGeometry.elbow(from: o, to: GridPoint(3, 7), horizontalFirst: true, straight: true),
                       [WireSegment(o, GridPoint(3, 7))])
    }

    func testStartingDirection() {
        XCTAssertNil(CanvasGeometry.startsHorizontally(.zero))
        XCTAssertEqual(CanvasGeometry.startsHorizontally(GridPoint(2, 1)), true)
        XCTAssertEqual(CanvasGeometry.startsHorizontally(GridPoint(-1, 1)), true)
        XCTAssertEqual(CanvasGeometry.startsHorizontally(GridPoint(0, -1)), false)
    }

    func testFreeTerminals() {
        var circuit = Circuit()
        let r = circuit.add(Element(kind: .resistor, a: o, b: GridPoint(4, 0)))
        let w = circuit.add(Element(kind: .wire, a: GridPoint(4, 0), b: GridPoint(4, 4)))
        let g = circuit.add(Element(kind: .ground, a: GridPoint(8, 0), b: GridPoint(8, 1)))
        // a terminal on the middle of a wire is not joined to it
        let c = circuit.add(Element(kind: .capacitor, a: GridPoint(4, 2), b: GridPoint(8, 2)))
        let free = circuit.freeTerminals
        XCTAssertEqual(free[o], r)
        XCTAssertNil(free[GridPoint(4, 0)], "the resistor's right end meets the wire")
        XCTAssertEqual(free[GridPoint(4, 4)], w)
        XCTAssertEqual(free[GridPoint(8, 0)], g)
        XCTAssertEqual(free[GridPoint(4, 2)], c)
        XCTAssertTrue(circuit.isFreeTerminal(o))
        XCTAssertFalse(circuit.isFreeTerminal(GridPoint(4, 0)))
        XCTAssertFalse(circuit.isFreeTerminal(GridPoint(2, 0)), "the middle of a part is no terminal")
        XCTAssertEqual(circuit.terminalCounts[GridPoint(4, 0)], 2)
    }

    func testAddWireJoinsItsEndsButNotItsCorner() {
        var circuit = Circuit()
        // a horizontal wire the new wire starts on, a vertical one its second leg crosses and a slanting one its
        // corner sits on
        let base = circuit.add(Element(kind: .wire, a: o, b: GridPoint(8, 0)))
        circuit.add(Element(kind: .wire, a: GridPoint(10, -2), b: GridPoint(10, 6)))
        circuit.add(Element(kind: .wire, a: GridPoint(2, 2), b: GridPoint(6, 6)))
        let ids = circuit.addWire(CanvasGeometry.elbow(from: GridPoint(4, 0), to: GridPoint(12, 4), horizontalFirst: false))
        XCTAssertEqual(ids.count, 2)
        let wires = circuit.elements.filter { $0.kind == .wire }
        // the base wire split at the start; the crossed and the cornered wires untouched
        XCTAssertEqual(wires.count, 6)
        XCTAssertTrue(wires.contains { $0.a == GridPoint(2, 2) && $0.b == GridPoint(6, 6) })
        XCTAssertTrue(wires.contains { $0.id == base && $0.a == o && $0.b == GridPoint(4, 0) })
        XCTAssertTrue(wires.contains { $0.a == GridPoint(4, 0) && $0.b == GridPoint(8, 0) })
        XCTAssertTrue(wires.contains { $0.a == GridPoint(10, -2) && $0.b == GridPoint(10, 6) })
        XCTAssertEqual(circuit[ids[0]].map { [$0.a, $0.b] }, [GridPoint(4, 0), GridPoint(4, 4)])
        XCTAssertEqual(circuit[ids[1]].map { [$0.a, $0.b] }, [GridPoint(4, 4), GridPoint(12, 4)])

        // the far end landing on a wire's middle joins it as well
        var other = Circuit()
        other.add(Element(kind: .wire, a: GridPoint(0, 5), b: GridPoint(0, -5)))
        other.addWire(CanvasGeometry.elbow(from: GridPoint(6, 3), to: GridPoint(0, 1), horizontalFirst: false))
        XCTAssertEqual(other.elements.filter { $0.kind == .wire }.count, 4)
        XCTAssertTrue(other.addWire([]).isEmpty)
    }

    func testPastePlacementCentresOnTargetKeepingShape() {
        let elements = [
            Element(kind: .resistor, a: GridPoint(10, 10), b: GridPoint(14, 10)),
            Element(kind: .capacitor, a: GridPoint(14, 10), b: GridPoint(14, 13)),
        ]
        let placed = CanvasGeometry.placed(elements, centredAt: GridPoint(-3, 2))
        // extent 10...14 by 10...13, centre (12, 11)
        XCTAssertEqual(placed[0].a, GridPoint(-5, 1))
        XCTAssertEqual(placed[0].b, GridPoint(-1, 1))
        XCTAssertEqual(placed[1].a, GridPoint(-1, 1))
        XCTAssertEqual(placed[1].b, GridPoint(-1, 4))
        XCTAssertEqual(placed.map(\.id), elements.map(\.id))
        XCTAssertTrue(CanvasGeometry.placed([], centredAt: o).isEmpty)
        // negative extents round the same way
        let left = CanvasGeometry.placed([Element(kind: .wire, a: GridPoint(-3, -3), b: GridPoint(0, -3))], centredAt: o)
        XCTAssertEqual(left[0].a, GridPoint(-1, 0))
        XCTAssertEqual(left[0].b, GridPoint(2, 0))
    }

    func testInlineValueIsTheOneTheLabelShows() {
        XCTAssertEqual(ElementKind.resistor.inlineValueParam?.key, "resistance")
        XCTAssertEqual(ElementKind.capacitor.inlineValueParam?.key, "capacitance")
        XCTAssertEqual(ElementKind.inductor.inlineValueParam?.key, "inductance")
        XCTAssertEqual(ElementKind.dcVoltage.inlineValueParam?.key, "voltage")
        XCTAssertEqual(ElementKind.acVoltage.inlineValueParam?.key, "amplitude")
        XCTAssertNil(ElementKind.wire.inlineValueParam)
        XCTAssertNil(ElementKind.npn.inlineValueParam)
        XCTAssertNil(ElementKind.opAmp.inlineValueParam)
        // every kind that names a key has that parameter, as a number
        for kind: ElementKind in [.resistor, .potentiometer, .lamp, .zener, .speaker, .capacitor, .inductor, .dcVoltage, .acVoltage,
                                  .noiseVoltage, .squareVoltage, .keyboardGate, .currentSource] {
            XCTAssertNotNil(kind.inlineValueParam, "\(kind)")
        }
        XCTAssertEqual(SI.parse("4k7"), 4700)
        XCTAssertEqual(SI.parse("2.2 MΩ"), 2.2e6)
    }
}
