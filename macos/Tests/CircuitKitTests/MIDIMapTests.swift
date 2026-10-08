import XCTest
@testable import CircuitKit

/// MIDI Learn: controllers mapped to knobs and switches, kept in the circuit file
final class MIDIMapTests: XCTestCase {
    private func circuit() throws -> Circuit {
        try SchematicLayout.layout([
            NetlistPart(kind: .dcVoltage, name: "V1", params: ["voltage": 9], connections: ["plus": "vcc", "minus": "GND"]),
            NetlistPart(kind: .potentiometer, name: "P1", params: ["resistance": 10_000, "position": 0.5],
                        connections: ["a": "vcc", "b": "GND", "wiper": "w"]),
            NetlistPart(kind: .toggleSwitch, name: "S1", connections: ["a": "w", "b": "out"]),
            NetlistPart(kind: .resistor, name: "R1", params: ["resistance": 1000], connections: ["a": "out", "b": "GND"]),
        ])
    }

    private func id(_ circuit: Circuit, _ name: String) throws -> UUID {
        try XCTUnwrap(circuit.elements.first { $0.name == name }).id
    }

    func testControllersMoveTheirControls() throws {
        var circuit = try circuit()
        let pot = try id(circuit, "P1"), toggle = try id(circuit, "S1")
        circuit.learnMIDI(controller: 21, channel: nil, part: pot)
        circuit.learnMIDI(controller: 64, channel: 2, part: toggle)
        XCTAssertTrue(circuit.applyControlChange(controller: 21, channel: 9, value: 127))
        XCTAssertEqual(circuit[pot]?[param: "position"], 1)
        XCTAssertTrue(circuit.applyControlChange(controller: 21, channel: 0, value: 0))
        XCTAssertEqual(circuit[pot]?[param: "position"], 0)
        // the same value again changes nothing
        XCTAssertFalse(circuit.applyControlChange(controller: 21, channel: 0, value: 0))
        // the switch listens on channel 3 only, and is on from 64
        XCTAssertFalse(circuit.applyControlChange(controller: 64, channel: 0, value: 127))
        XCTAssertTrue(circuit.applyControlChange(controller: 64, channel: 2, value: 64))
        XCTAssertEqual(circuit[toggle]?.closed, true)
        XCTAssertTrue(circuit.applyControlChange(controller: 64, channel: 2, value: 63))
        XCTAssertEqual(circuit[toggle]?.closed, false)
        XCTAssertFalse(circuit.applyControlChange(controller: 7, channel: 0, value: 100))
        XCTAssertEqual(circuit.midiMapping(part: toggle)?.label, "CC 64 · ch 3")
    }

    func testLearningReplacesOldMappings() throws {
        var circuit = try circuit()
        let pot = try id(circuit, "P1"), toggle = try id(circuit, "S1")
        circuit.learnMIDI(controller: 21, channel: nil, part: pot)
        // the pot learns another controller: the old one lets go of it
        circuit.learnMIDI(controller: 22, channel: nil, part: pot)
        XCTAssertEqual(circuit.midiMappings.count, 1)
        XCTAssertEqual(circuit.midiMapping(part: pot)?.controller, 22)
        // another control learns that controller: it moves the new control only
        circuit.learnMIDI(controller: 22, channel: nil, part: toggle)
        XCTAssertNil(circuit.midiMapping(part: pot))
        XCTAssertEqual(circuit.midiMapping(part: toggle)?.controller, 22)
        circuit.forgetMIDI(part: toggle)
        XCTAssertTrue(circuit.midiMappings.isEmpty)
        // deleting a part forgets its mapping
        circuit.learnMIDI(controller: 1, channel: nil, part: pot)
        circuit.remove([pot])
        XCTAssertTrue(circuit.midiMappings.isEmpty)
    }

    func testMappingsAreSavedAndReachInsideBlocks() throws {
        let inner = try circuit()
        let block = inner.asBlock(named: "Tone")
        var outer = Circuit()
        var element = Element(kind: .block, name: "X1", a: GridPoint(0, 0), b: GridPoint(4, 0))
        element.block = block
        let part = outer.add(element)
        let knob = try id(inner, "P1")
        outer.learnMIDI(controller: 74, channel: nil, part: part, inner: knob)
        XCTAssertTrue(outer.applyControlChange(controller: 74, channel: 0, value: 127))
        XCTAssertEqual(outer[part]?.block?.circuit[knob]?[param: "position"], 1)
        // the simulation sees the knob moved
        let flat = outer.flattened()
        XCTAssertEqual(flat[UUID.inBlock(part, part: knob)]?[param: "position"], 1)

        let reloaded = try JSONDecoder().decode(Circuit.self, from: JSONEncoder().encode(outer))
        XCTAssertEqual(reloaded.midiMappings, outer.midiMappings)
        // older files have none
        XCTAssertTrue(try JSONDecoder().decode(Circuit.self, from: Data("{}".utf8)).midiMappings.isEmpty)
        // a block made of a circuit leaves its mappings behind
        var mapped = try circuit()
        mapped.learnMIDI(controller: 1, channel: nil, part: try id(mapped, "P1"))
        XCTAssertEqual(mapped.midiMappings.count, 1)
        XCTAssertTrue(mapped.asBlock(named: "B").circuit.midiMappings.isEmpty)
    }
}
