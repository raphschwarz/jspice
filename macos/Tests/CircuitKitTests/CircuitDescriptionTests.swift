import XCTest
@testable import CircuitKit

/// The words VoiceOver reads for a schematic: each part's name and kind, what its terminals connect to, and the summary
final class CircuitDescriptionTests: XCTestCase {
    private func part(_ circuit: Circuit, named name: String) -> Element {
        circuit.elements.first { $0.name == name }!
    }

    func testDimmerDescribesNetsByNameOrByWhatIsOnThem() throws {
        let circuit = try XCTUnwrap(Examples.example("dimmer")).circuit
        let words = CircuitDescription.connections(in: circuit)
        // R1 is the potentiometer, R2 the 47 kΩ base resistor, R3 the LED's resistor
        XCTAssertEqual(words[part(circuit, named: "R2").id], "between the wiper of R1 and the base of Q1")
        XCTAssertEqual(words[part(circuit, named: "R3").id], "between +9V and the anode of LED1")
        XCTAssertEqual(words[part(circuit, named: "V1").id], "minus to ground, plus to +9V")
        let transistor = try XCTUnwrap(words[part(circuit, named: "Q1").id])
        XCTAssertTrue(transistor.contains("base to R2"), transistor)
        XCTAssertTrue(transistor.contains("collector to the cathode of LED1"), transistor)
        XCTAssertTrue(transistor.contains("emitter to ground"), transistor)
        let pot = try XCTUnwrap(words[part(circuit, named: "R1").id])
        XCTAssertTrue(pot.contains("end a to +9V") && pot.contains("end b to ground") && pot.contains("wiper to R2"), pot)
        // every part but wires and grounds is described
        for element in circuit.elements where CircuitDescription.isDescribed(element) {
            XCTAssertFalse(words[element.id]?.isEmpty ?? true, "\(element.name) has a description")
        }
        XCTAssertNil(words[circuit.elements.first { $0.kind == .wire }!.id])
    }

    func testOpenSwitchSplitsANet() throws {
        var circuit = try XCTUnwrap(Examples.example("led")).circuit
        let resistor = part(circuit, named: "R1")
        XCTAssertEqual(CircuitDescription.connections(in: circuit)[resistor.id], "between +9V and the anode of LED1")
        let switchID = try XCTUnwrap(circuit.elements.first { $0.kind == .toggleSwitch }).id
        circuit.update(switchID) { $0.closed = false }
        // with the switch open, the resistor's left end meets only the switch
        XCTAssertEqual(CircuitDescription.connections(in: circuit)[resistor.id], "between S1 and the anode of LED1")
        XCTAssertEqual(CircuitDescription.connections(in: circuit)[switchID], "between +9V and R1")
    }

    func testNetLabelsLooseEndsAndNames() {
        var circuit = Circuit()
        circuit.add(Element(kind: .dcVoltage, name: "V1", a: GridPoint(0, 4), b: GridPoint(0, 0), params: ["voltage": 5]))
        circuit.add(Element(kind: .ground, a: GridPoint(0, 4), b: GridPoint(0, 5)))
        circuit.add(Element(kind: .netLabel, name: "OUT", a: GridPoint(0, 0), b: GridPoint(1, 0)))
        circuit.add(Element(kind: .resistor, name: "R1", a: GridPoint(4, 0), b: GridPoint(8, 0)))
        circuit.add(Element(kind: .netLabel, name: "OUT", a: GridPoint(4, 0), b: GridPoint(3, 0)))
        let words = CircuitDescription.connections(in: circuit)
        XCTAssertEqual(words[part(circuit, named: "R1").id], "one end on OUT, the other not connected")
        XCTAssertEqual(words[part(circuit, named: "V1").id], "minus to ground, plus to OUT")
        let label = circuit.elements.first { $0.kind == .netLabel }!
        XCTAssertEqual(words[label.id], "connects the plus of V1 and R1")
        XCTAssertEqual(CircuitDescription.spokenName(label), "net label OUT")
        XCTAssertEqual(CircuitDescription.summary(of: circuit, state: "paused"), "Schematic: 2 parts, paused")
        XCTAssertEqual(CircuitDescription.summary(of: Circuit(), state: nil), "Schematic: empty")
    }

    func testSpokenNames() {
        XCTAssertEqual(CircuitDescription.spokenKind(.resistor), "resistor")
        XCTAssertEqual(CircuitDescription.spokenKind(.npn), "NPN transistor")
        XCTAssertEqual(CircuitDescription.spokenKind(.opAmp), "op-amp")
        XCTAssertEqual(CircuitDescription.spokenKind(.atmega328p), "ATmega328P (Arduino Uno)")
        XCTAssertEqual(CircuitDescription.spokenKind(.led), "LED")
        XCTAssertEqual(CircuitDescription.spokenKind(.dcVoltage), "DC voltage")
        XCTAssertEqual(CircuitDescription.spokenKind(.pushButton), "push button")
        XCTAssertEqual(CircuitDescription.spokenName(Element(kind: .capacitor, name: "C3", a: .zero, b: GridPoint(0, 2))), "C3, capacitor")
        XCTAssertEqual(CircuitDescription.list(["a", "b", "c"]), "a, b and c")
    }
}
