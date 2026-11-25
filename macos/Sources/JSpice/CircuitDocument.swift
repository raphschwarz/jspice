import SwiftUI
import UniformTypeIdentifiers
import CircuitKit

extension UTType {
    static let jspiceCircuit = UTType(exportedAs: "org.knowm.jspice.circuit", conformingTo: .json)
}

/// A circuit file. Saved as JSON with the .jspice extension.
final class CircuitDocument: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.jspiceCircuit, .json] }
    static var writableContentTypes: [UTType] { [.jspiceCircuit] }

    @Published var circuit: Circuit

    init(circuit: Circuit = Circuit()) {
        self.circuit = circuit
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // tolerant of what a newer version added (see `Circuit.loadNotes`); throws a readable error for other files
        circuit = try Circuit.decodeDocument(from: data)
    }

    func snapshot(contentType: UTType) throws -> Circuit {
        circuit
    }

    func fileWrapper(snapshot: Circuit, configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(snapshot))
    }
}
