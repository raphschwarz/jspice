import XCTest
@testable import CircuitKit

/// Reading what a newer JSpice wrote everywhere a circuit or part is read, not only when a file is opened: the block
/// library, the Audio Unit's presets, the pasteboard, and circuits rebuilt from one read from a file.
final class TolerantReadingTests: XCTestCase {
    private let futurePart: JSONValue = .object([
        "id": .string("6B1B9F5E-0C1E-4E5A-9C0D-3B7A1F2E4D5C"),
        "kind": .string("quantumFluxCapacitor"),
        "name": .string("Q1"),
        "a": .object(["x": .number(20), "y": .number(4)]),
        "b": .object(["x": .number(24), "y": .number(4)]),
    ])

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    /// The overdrive example as a newer JSpice would save it: format 2, a part of a kind this build lacks, and a field
    /// it does not know
    private func newerFile() throws -> Data {
        let circuit = try XCTUnwrap(Examples.example("overdrive")).circuit
        guard case .object(var fields) = try JSONDecoder().decode(JSONValue.self, from: encode(circuit)),
              case .array(var elements) = fields["elements"] else { throw XCTSkip("unexpected encoding") }
        elements.insert(futurePart, at: 1)
        fields["elements"] = .array(elements)
        fields["formatVersion"] = .number(2)
        fields["futureField"] = .string("kept")
        return try encode(JSONValue.object(fields))
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testPastedPartsAreReadOneByOne() throws {
        let known = Element(kind: .resistor, name: "R1", a: GridPoint(0, 0), b: GridPoint(4, 0))
        let list = JSONValue.array([try JSONDecoder().decode(JSONValue.self, from: encode(known)), futurePart])
        let read = try Element.decodeList(from: encode(list))
        XCTAssertEqual(read.elements.map(\.name), ["R1"])
        XCTAssertEqual(read.leftOut.count, 1)
        XCTAssertEqual(read.leftOut.first?.index, 1)
        XCTAssertEqual(read.leftOut.first?.raw["kind"]?.stringValue, "quantumFluxCapacitor")
        // something that is not a list at all is an error
        XCTAssertThrowsError(try Element.decodeList(from: Data("{\"kind\": \"resistor\"}".utf8)))
    }

    func testOneDamagedBlockFileLeavesTheOthersAndIsReported() throws {
        let folder = try temporaryFolder()
        let circuit = try XCTUnwrap(Examples.example("overdrive")).circuit
        try BlockLibrary.save(circuit.asBlock(named: "Good"), in: folder)
        try Data("{ not json".utf8).write(to: folder.appendingPathComponent("Broken.jspiceblock"))
        try Data("{\"circuit\": {}}".utf8).write(to: folder.appendingPathComponent("Nameless.jspiceblock"))
        let loaded = BlockLibrary.load(in: folder)
        XCTAssertEqual(loaded.blocks.map(\.name), ["Good"])
        XCTAssertEqual(loaded.problems.count, 2)
        XCTAssertTrue(loaded.problems[0].hasPrefix("Broken.jspiceblock: "), loaded.problems[0])
        XCTAssertTrue(loaded.problems[1].hasPrefix("Nameless.jspiceblock: "), loaded.problems[1])
        XCTAssertEqual(BlockLibrary.all(in: folder).map(\.name), ["Good"])
    }

    func testABlockFromANewerVersionKeepsWhatItCannotRead() throws {
        let folder = try temporaryFolder()
        let circuit = try Circuit.decodeDocument(from: newerFile())
        let block = circuit.asBlock(named: "Future")
        XCTAssertEqual(block.circuit.preserved.elements.count, 1, "the unknown part stays with the block's parts")
        try BlockLibrary.save(block, in: folder)
        let read = try XCTUnwrap(BlockLibrary.load(in: folder).blocks.first)
        XCTAssertEqual(read.circuit.preserved.elements.first?.raw["kind"]?.stringValue, "quantumFluxCapacitor")
        XCTAssertFalse(read.circuit.loadNotes.isEmpty)
    }

    func testAPresetFromANewerVersionOpensWithItsNotes() throws {
        let folder = try temporaryFolder()
        try newerFile().write(to: folder.appendingPathComponent("Future drive.jspice"))
        let entry = try XCTUnwrap(PluginLibrary.entries(instrument: false, folder: folder).last)
        XCTAssertEqual(entry.name, "Future drive")
        XCTAssertEqual(entry.circuit.fileFormatVersion, 2)
        XCTAssertTrue(entry.circuit.loadNotes.contains { $0.contains("newer version") })
    }

    func testARebuiltCircuitCarriesWhatTheFileHeld() throws {
        let original = try Circuit.decodeDocument(from: newerFile())
        XCTAssertFalse(original.preserved.isEmpty)
        let tidied = try SchematicLayout.tidy(original)
        XCTAssertTrue(tidied.preserved.isEmpty, "the layout builds a circuit of its own")
        let carried = tidied.carryingPreserved(from: original)
        XCTAssertEqual(carried.preserved, original.preserved)
        XCTAssertEqual(carried.fileFormatVersion, 2)
        XCTAssertEqual(carried.loadNotes, original.loadNotes)
        // and it is written back
        let saved = try JSONDecoder().decode(JSONValue.self, from: encode(carried))
        XCTAssertEqual(saved["futureField"], .string("kept"))
        XCTAssertEqual(saved["formatVersion"], .number(2))
        guard case .array(let elements) = saved["elements"] else { return XCTFail("no elements") }
        XCTAssertTrue(elements.contains { $0["kind"]?.stringValue == "quantumFluxCapacitor" })
    }
}
