import XCTest
@testable import CircuitKit

/// The .jspice file format: its version, and files from newer versions of JSpice opening here, keeping what this build
/// cannot read and writing it back unchanged.
///
/// Files are compared byte for byte only when both were written by this platform's JSONEncoder (as the app writes them);
/// otherwise they are compared as JSON trees, so the tests hold whatever key order or number formatting it uses.
final class FileFormatTests: XCTestCase {
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    private func tree(_ circuit: Circuit) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: encode(circuit))
    }

    private func tree(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// The circuit a file of this JSON reads as, and the file
    private func open(_ file: JSONValue) throws -> (circuit: Circuit, data: Data) {
        let data = try encode(file)
        return (try Circuit.decodeDocument(from: data), data)
    }

    private func objectKeys(_ value: JSONValue?) -> Set<String> {
        if case .object(let fields) = value { return Set(fields.keys) }
        return []
    }

    private func array(_ value: JSONValue?) -> [JSONValue] {
        if case .array(let items) = value { return items }
        return []
    }

    private func number(_ value: Double) -> JSONValue { .number(value) }

    private func point(_ x: Double, _ y: Double) -> JSONValue { .object(["x": number(x), "y": number(y)]) }

    /// A part of a kind no version of JSpice has, with fields of all kinds of JSON value
    private let futurePart: JSONValue = .object([
        "id": .string("6B1B9F5E-0C1E-4E5A-9C0D-3B7A1F2E4D5C"),
        "kind": .string("quantumFluxCapacitor"),
        "name": .string("Q1"),
        "a": .object(["x": .number(20), "y": .number(4)]),
        "b": .object(["x": .number(24), "y": .number(4)]),
        "params": .object(["flux": .number(1.21), "gigawatts": .number(-3.5e-7)]),
        "closed": .bool(false),
        "flipped": .bool(true),
        "seed": .integer(9_007_199_254_740_993),
        "future": .array([.null, .bool(true), .string("ünïcödé \"quoted\""), .object(["nested": .array([])])]),
    ])

    private func editing(_ value: JSONValue, _ key: String, _ change: (inout JSONValue) -> Void) -> JSONValue {
        guard case .object(var fields) = value else { return value }
        var field = fields[key] ?? .null
        change(&field)
        fields[key] = field
        return .object(fields)
    }

    private func inserting(_ item: JSONValue, at index: Int, in value: inout JSONValue) {
        var items = array(value)
        items.insert(item, at: min(index, items.count))
        value = .array(items)
    }

    // MARK: - The built-in circuits

    func testEveryExampleRoundTripsByteIdentically() throws {
        for example in Examples.all {
            let first = try encode(example.circuit)
            let read = try Circuit.decodeDocument(from: first)
            XCTAssertEqual(try encode(read), first, example.id)
            XCTAssertEqual(read, example.circuit, example.id)
            XCTAssertTrue(read.preserved.isEmpty, example.id)
            XCTAssertEqual(read.loadNotes, [], example.id)
            XCTAssertEqual(read.fileFormatVersion, Circuit.formatVersion, example.id)
        }
    }

    /// Saved files keep the shape they had before the format had a version: the same fields, plus `formatVersion` at the
    /// top only
    func testTheFileShapeIsUnchangedApartFromTheVersion() throws {
        let topLevel: Set<String> = ["elements", "scopes", "settings", "netNames", "midiMappings"]
        let partFields: Set<String> = ["id", "kind", "name", "a", "b", "params", "closed", "flipped"]
        let optionalPartFields: Set<String> = ["code", "firmware", "block", "audio"]
        func check(_ circuit: JSONValue, top: Bool, _ id: String) {
            let keys = objectKeys(circuit)
            XCTAssertEqual(keys.subtracting(["sequence", "formatVersion"]), topLevel, id)
            XCTAssertEqual(keys.contains("formatVersion"), top, id)
            if top { XCTAssertEqual(circuit["formatVersion"], .number(1), id) }
            for part in array(circuit["elements"]) {
                let fields = objectKeys(part)
                XCTAssertEqual(fields.intersection(partFields), partFields, id)
                XCTAssertEqual(fields.subtracting(partFields).subtracting(optionalPartFields), [], id)
                if let inner = part["block"]?["circuit"] { check(inner, top: false, id) }
            }
        }
        for example in Examples.all {
            check(try tree(example.circuit), top: true, example.id)
        }
    }

    /// A file as JSpice wrote it before the format had a version
    private let unversionedFile = """
        {
          "elements" : [
            { "a" : { "x" : 0, "y" : 4 }, "b" : { "x" : 0, "y" : 0 }, "closed" : false, "flipped" : false,
              "id" : "11111111-2222-3333-4444-555555555555", "kind" : "dcVoltage", "name" : "V1", "params" : { "voltage" : 10 } },
            { "a" : { "x" : 0, "y" : 0 }, "b" : { "x" : 4, "y" : 0 }, "closed" : false, "flipped" : false,
              "id" : "21111111-2222-3333-4444-555555555555", "kind" : "wire", "name" : "", "params" : { } },
            { "a" : { "x" : 4, "y" : 0 }, "b" : { "x" : 4, "y" : 4 }, "closed" : false, "flipped" : false,
              "id" : "31111111-2222-3333-4444-555555555555", "kind" : "resistor", "name" : "R1", "params" : { "resistance" : 1000 } },
            { "a" : { "x" : 4, "y" : 4 }, "b" : { "x" : 0, "y" : 4 }, "closed" : false, "flipped" : false,
              "id" : "41111111-2222-3333-4444-555555555555", "kind" : "wire", "name" : "", "params" : { } },
            { "a" : { "x" : 0, "y" : 4 }, "b" : { "x" : 0, "y" : 5 }, "closed" : false, "flipped" : false,
              "id" : "51111111-2222-3333-4444-555555555555", "kind" : "ground", "name" : "", "params" : { } }
          ],
          "midiMappings" : [ ],
          "netNames" : { },
          "scopes" : [
            { "elementID" : "31111111-2222-3333-4444-555555555555", "id" : "61111111-2222-3333-4444-555555555555",
              "plot" : "time", "quantity" : "current" }
          ],
          "settings" : { "autoSpeed" : true, "autoTimeStep" : true, "speed" : 1, "temperature" : 27, "timeStep" : 1.0000000000000001e-05 }
        }
        """

    func testAFileWithoutAVersionOpensAsVersionOne() throws {
        let circuit = try Circuit.decodeDocument(from: Data(unversionedFile.utf8))
        XCTAssertEqual(circuit.fileFormatVersion, 1)
        XCTAssertEqual(circuit.loadNotes, [])
        XCTAssertTrue(circuit.preserved.isEmpty)
        XCTAssertEqual(circuit.elements.map(\.kind), [.dcVoltage, .wire, .resistor, .wire, .ground])
        XCTAssertEqual(circuit.scopes.first?.quantity, .current)
        // written back the same, with the version added
        guard case .object(var written) = try tree(circuit) else { return XCTFail("not an object") }
        XCTAssertEqual(written.removeValue(forKey: "formatVersion"), .number(1))
        XCTAssertEqual(JSONValue.object(written), try tree(unversionedFile))
        let simulator = Simulator(circuit: circuit)
        simulator.step()
        XCTAssertFalse(simulator.isFailed)
        XCTAssertEqual(abs(simulator.current(2)), 0.01, accuracy: 1e-6)
    }

    func testAFileOfANewerVersionOpensWithANote() throws {
        let file = editing(try tree(unversionedFile), "formatVersion") { $0 = .number(99) }
        let (circuit, data) = try open(file)
        XCTAssertEqual(circuit.fileFormatVersion, 99)
        XCTAssertEqual(circuit.elements.count, 5)
        XCTAssertEqual(circuit.loadNotes.count, 1)
        XCTAssertTrue(circuit.loadNotes[0].contains("newer version of JSpice"), circuit.loadNotes[0])
        // saved again it keeps its version, since what was kept unread is in that format
        XCTAssertEqual(try encode(circuit), data)
        // and the version does not make circuits unequal
        XCTAssertEqual(circuit, try Circuit.decodeDocument(from: Data(unversionedFile.utf8)))
    }

    // MARK: - Parts, scopes and fields this build does not know

    func testAPartOfAnUnknownKindIsKeptOutOfTheCircuitAndWrittenBack() throws {
        let original = Examples.voltageDivider.circuit
        let file = editing(try tree(original), "elements") { inserting(futurePart, at: 3, in: &$0) }
        let (circuit, data) = try open(file)
        // the rest is all there
        XCTAssertEqual(circuit.elements, original.elements)
        XCTAssertEqual(circuit.scopes, original.scopes)
        XCTAssertNotEqual(circuit, original)
        XCTAssertEqual(circuit.preserved.elements, [PreservedEntry(index: 3, raw: futurePart)])
        XCTAssertEqual(circuit.loadNotes, ["1 part this version of JSpice does not know (kind: quantumFluxCapacitor) was "
            + "left out of the drawing and the simulation; it is kept in the file."])
        // saved again, the file is as it was
        XCTAssertEqual(try encode(circuit), data)
        XCTAssertEqual(array(try tree(circuit)["elements"])[3], futurePart)
        // and the circuit simulates without it
        let simulator = Simulator(circuit: circuit)
        simulator.step()
        XCTAssertFalse(simulator.isFailed, "\(simulator.problems)")
        let probe = try XCTUnwrap(circuit.elements.firstIndex { $0.kind == .probe })
        XCTAssertEqual(abs(simulator.voltageAcross(probe)), 20.0 / 3, accuracy: 1e-3)
    }

    func testEditedCircuitsKeepTheirUnknownPartsToo() throws {
        let original = Examples.voltageDivider.circuit
        var file = editing(try tree(original), "elements") { inserting(futurePart, at: 1, in: &$0) }
        file = editing(file, "elements") { inserting(editing(futurePart, "kind") { $0 = .string("hoverboard") }, at: 100, in: &$0) }
        var circuit = try open(file).circuit
        XCTAssertEqual(circuit.preserved.elements.map(\.index), [1, original.elements.count + 1])
        XCTAssertEqual(circuit.loadNotes, ["2 parts this version of JSpice does not know (kinds: quantumFluxCapacitor, "
            + "hoverboard) were left out of the drawing and the simulation; they are kept in the file."])
        circuit.remove(Set(circuit.elements.prefix(3).map(\.id)))
        circuit.add(Element(kind: .resistor, a: GridPoint(30, 0), b: GridPoint(30, 4)))
        let kinds = array(try tree(circuit)["elements"]).compactMap { $0["kind"]?.stringValue }
        XCTAssertEqual(kinds.filter { $0 == "quantumFluxCapacitor" || $0 == "hoverboard" }, ["quantumFluxCapacitor", "hoverboard"])
        XCTAssertEqual(kinds.count, circuit.elements.count + 2)
        // (read back, the kept parts have their new places; the circuit saves the same)
        let saved = try encode(circuit)
        XCTAssertEqual(try encode(Circuit.decodeDocument(from: saved)), saved)
        XCTAssertEqual(try Circuit.decodeDocument(from: saved).elements, circuit.elements)
    }

    func testAPartThatCannotBeReadIsKeptAndNamed() throws {
        // a resistor whose ends are given in a form this build does not read
        let broken = editing(editing(futurePart, "kind") { $0 = .string("resistor") }, "a") { $0 = .string("4,5") }
        let file = editing(try tree(Examples.voltageDivider.circuit), "elements") { inserting(broken, at: 0, in: &$0) }
        let (circuit, data) = try open(file)
        XCTAssertEqual(circuit.elements.count, Examples.voltageDivider.circuit.elements.count)
        XCTAssertEqual(circuit.loadNotes, ["1 part this version of JSpice could not read (resistor) was left out of the "
            + "drawing and the simulation; it is kept in the file."])
        XCTAssertEqual(try encode(circuit), data)
    }

    func testAnUnknownPartInsideABlockIsKeptAndNoted() throws {
        let original = Examples.blocks.circuit
        let blockIndex = try XCTUnwrap(original.elements.firstIndex { $0.kind == .block })
        let file = editing(try tree(original), "elements") { elements in
            var parts = array(elements)
            parts[blockIndex] = editing(parts[blockIndex], "block") { block in
                block = editing(block, "circuit") { inner in
                    inner = editing(inner, "elements") { inserting(futurePart, at: 0, in: &$0) }
                }
            }
            elements = .array(parts)
        }
        let (circuit, data) = try open(file)
        XCTAssertEqual(circuit.elements.count, original.elements.count)
        XCTAssertEqual(circuit.elements[blockIndex].block?.circuit.preserved.elements.count, 1)
        XCTAssertEqual(circuit.loadNotes.count, 1)
        XCTAssertTrue(circuit.loadNotes[0].hasPrefix("In block \u{201C}"), circuit.loadNotes[0])
        XCTAssertTrue(circuit.loadNotes[0].contains("quantumFluxCapacitor"), circuit.loadNotes[0])
        XCTAssertEqual(try encode(circuit), data)
        let simulator = Simulator(circuit: circuit)
        for _ in 0..<10 { simulator.step() }
        XCTAssertFalse(simulator.isFailed, "\(simulator.problems)")
    }

    func testScopesOfUnknownQuantitiesOrPlotsAreKeptAndWrittenBack() throws {
        let original = try Circuit.decodeDocument(from: Data(unversionedFile.utf8))
        let flux: JSONValue = .object(["id": .string("71111111-2222-3333-4444-555555555555"),
                                       "elementID": .string("31111111-2222-3333-4444-555555555555"),
                                       "quantity": .string("magneticFlux"), "plot": .string("time")])
        let waterfall = editing(editing(flux, "quantity") { $0 = .string("voltage") }, "plot") { $0 = .string("waterfall") }
        var file = editing(try tree(original), "scopes") { inserting(flux, at: 0, in: &$0) }
        file = editing(file, "scopes") { inserting(waterfall, at: 5, in: &$0) }
        let (circuit, data) = try open(file)
        XCTAssertEqual(circuit.scopes, original.scopes)
        XCTAssertEqual(circuit.elements, original.elements)
        XCTAssertEqual(circuit.preserved.scopes.map(\.raw), [flux, waterfall])
        XCTAssertEqual(circuit.loadNotes, ["2 scope traces this version of JSpice cannot show were left out; they are kept in the file."])
        XCTAssertEqual(try encode(circuit), data)
        XCTAssertEqual(array(try tree(circuit)["scopes"]), [flux] + array(try tree(original)["scopes"]) + [waterfall])
    }

    func testUnknownParametersAndFieldsSurvive() throws {
        let original = try Circuit.decodeDocument(from: Data(unversionedFile.utf8))
        var file = editing(try tree(original), "elements") { elements in
            var parts = array(elements)
            parts[2] = editing(parts[2], "params") { params in params = editing(params, "futureKnob") { $0 = .number(0.25) } }
            parts[2] = editing(parts[2], "label") { $0 = .string("load") }
            elements = .array(parts)
        }
        file = editing(file, "probes") { $0 = .array([.object(["at": point(4, 0), "colour": .string("red")])]) }
        let (circuit, data) = try open(file)
        XCTAssertEqual(circuit.loadNotes, [], "fields an older build can skip are not worth a note")
        XCTAssertEqual(circuit.elements[2][param: "futureKnob"], 0.25)
        XCTAssertEqual(circuit.elements[2].unknownFields, ["label": .string("load")])
        XCTAssertEqual(circuit.preserved.fields.keys.sorted(), ["probes"])
        XCTAssertEqual(try encode(circuit), data)
        // they go along with the part when it is copied and pasted
        let pasted = try JSONDecoder().decode([Element].self, from: JSONEncoder().encode([circuit.elements[2]]))
        XCTAssertEqual(pasted, [circuit.elements[2]])
    }

    func testFieldsThatCannotBeReadFallBackAndAreKeptUntilChanged() throws {
        var file = editing(try tree(unversionedFile), "settings") { $0 = .object(["speed": .string("ludicrous")]) }
        file = editing(file, "formatVersion") { $0 = .number(1) }
        var (circuit, data) = try open(file)
        XCTAssertEqual(circuit.settings, SimulationSettings())
        XCTAssertEqual(circuit.elements.count, 5)
        XCTAssertEqual(circuit.loadNotes.count, 1)
        XCTAssertTrue(circuit.loadNotes[0].contains("simulation settings"), circuit.loadNotes[0])
        XCTAssertEqual(try encode(circuit), data)
        circuit.settings.temperature = 50
        XCTAssertEqual(try tree(circuit)["settings"]?["temperature"], .number(50))
        data = try encode(circuit)
        XCTAssertEqual(try Circuit.decodeDocument(from: data).settings.temperature, 50)
    }

    // MARK: - Equality, and what is not a circuit

    func testCircuitsDifferingInWhatWasKeptAreNotEqual() throws {
        let base = try tree(Examples.voltageDivider.circuit)
        let one = try open(editing(base, "elements") { inserting(futurePart, at: 0, in: &$0) }).circuit
        let other = try open(editing(base, "elements") {
            inserting(editing(futurePart, "name") { $0 = .string("Q2") }, at: 0, in: &$0)
        }).circuit
        let same = try open(editing(base, "elements") { inserting(futurePart, at: 0, in: &$0) }).circuit
        XCTAssertNotEqual(one, other)
        XCTAssertNotEqual(one, Examples.voltageDivider.circuit)
        XCTAssertEqual(one, same)
        XCTAssertEqual(one.hashValue, same.hashValue)
        XCTAssertEqual(Set([one, other, same]).count, 2)
        // how it was read (its version) is not part of it
        let plain = try open(base).circuit
        XCTAssertEqual(plain, Examples.voltageDivider.circuit)
        XCTAssertEqual(plain.hashValue, Examples.voltageDivider.circuit.hashValue)
    }

    func testWhatIsNotACircuitGivesAReadableError() throws {
        for text in ["not json at all", "[1, 2, 3]", "{\"name\": \"a shopping list\"}", "{}", "{\"elements\": 5}"] {
            XCTAssertThrowsError(try Circuit.decodeDocument(from: Data(text.utf8)), text) { error in
                XCTAssertTrue(error is CircuitFileError, "\(text): \(error)")
                XCTAssertEqual((error as? LocalizedError)?.errorDescription, "This file is not a JSpice circuit, or it is damaged.")
            }
        }
        // an empty circuit's file is a circuit
        XCTAssertNoThrow(try Circuit.decodeDocument(from: encode(Circuit())))
    }

    /// Every stored property of a part and of a circuit is written to the file (the coding is written out by hand, so a
    /// property added without a line there would silently not be saved)
    func testEveryStoredPropertyIsWritten() throws {
        var part = Element(kind: .atmega328p, name: "U1", a: GridPoint(0, 0), b: GridPoint(0, 8), params: ["x": 1])
        part.code = "void setup() {}"
        part.firmware = Data([1, 2, 3])
        part.block = BlockDefinition(name: "B", circuit: Circuit())
        part.audio = AudioClip(name: "a", sampleRate: 8000, samples: [0, 0.5])
        part.unknownFields = ["later": .bool(true)]
        let properties = Set(Mirror(reflecting: part).children.compactMap(\.label))
        let written = objectKeys(try JSONDecoder().decode(JSONValue.self, from: encode(part)))
        XCTAssertEqual(properties.subtracting(["unknownFields"]).union(["later"]), written)
        XCTAssertEqual(try JSONDecoder().decode(Element.self, from: encode(part)), part)

        var circuit = Circuit(elements: [part], scopes: [ScopeSpec(elementID: part.id, quantity: .voltage)],
                              netNames: ["U1.a": "n"], sequence: StepSequence(steps: [60, nil]),
                              midiMappings: [MIDIMapping(controller: 1, part: part.id)])
        circuit.preserved.fields = ["later": .number(2)]
        let circuitProperties = Set(Mirror(reflecting: circuit).children.compactMap(\.label))
        let circuitWritten = objectKeys(try tree(circuit))
        XCTAssertEqual(circuitProperties.subtracting(["preserved", "loadInfo"]).union(["formatVersion", "later"]), circuitWritten)
        XCTAssertEqual(try Circuit.decodeDocument(from: encode(circuit)), circuit)
    }

    func testRawJSONKeepsLargeWholeNumbersExactly() throws {
        let value: JSONValue = .array([.integer(9_007_199_254_740_993), .integer(Int64.max), .number(0.1), .number(1e300),
                                       .number(-0.0), .number(42)])
        let data = try encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
        XCTAssertEqual(try encode(JSONDecoder().decode(JSONValue.self, from: data)), data)
    }
}
