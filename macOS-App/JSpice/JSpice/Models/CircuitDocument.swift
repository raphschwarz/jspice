import SwiftUI
import UniformTypeIdentifiers

// MARK: - Document Type

extension UTType {
    static var jspiceCircuit: UTType {
        UTType(exportedAs: "com.jspice.circuit", conformingTo: .json)
    }
}

// MARK: - Circuit Document

struct CircuitDocument: FileDocument, Codable {
    static var readableContentTypes: [UTType] { [.jspiceCircuit, .json] }

    var components: [SchematicComponent]
    var wires: [Wire]
    var metadata: ProjectMetadata
    var simulationConfig: SimulationConfig

    init() {
        self.components = []
        self.wires = []
        self.metadata = ProjectMetadata()
        self.simulationConfig = SimulationConfig()
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self = try JSONDecoder().decode(CircuitDocument.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        return .init(regularFileWithContents: data)
    }

    // MARK: - Mutation helpers

    mutating func addComponent(_ component: SchematicComponent) {
        components.append(component)
    }

    mutating func removeComponent(id: UUID) {
        components.removeAll { $0.id == id }
        // Also remove wires connected to this component
        wires.removeAll { wire in
            wire.startComponentID == id || wire.endComponentID == id
        }
    }

    mutating func addWire(_ wire: Wire) {
        wires.append(wire)
    }

    mutating func removeWire(id: UUID) {
        wires.removeAll { $0.id == id }
    }

    func component(withID id: UUID) -> SchematicComponent? {
        components.first { $0.id == id }
    }
}

// MARK: - Project Metadata

struct ProjectMetadata: Codable, Equatable {
    var name: String = "Untitled Circuit"
    var author: String = ""
    var description: String = ""
    var createdDate: Date = Date()
    var modifiedDate: Date = Date()
    var version: String = "1.0"
}

// MARK: - Simulation Configuration

struct SimulationConfig: Codable, Equatable {
    var dcOperatingPoint: DCOperatingPointConfig = .init()
    var transient: TransientConfig = .init()
    var acAnalysis: ACAnalysisConfig = .init()

    struct DCOperatingPointConfig: Codable, Equatable {
        var maxIterations: Int = 100
        var tolerance: Double = 1e-9
    }

    struct TransientConfig: Codable, Equatable {
        var startTime: Double = 0
        var stopTime: Double = 0.01    // 10ms
        var timeStep: Double = 1e-6    // 1us
        var maxTimeStep: Double = 1e-5
    }

    struct ACAnalysisConfig: Codable, Equatable {
        var startFrequency: Double = 1       // 1 Hz
        var stopFrequency: Double = 1e6      // 1 MHz
        var pointsPerDecade: Int = 20
        var sweepType: FrequencySweepType = .decade
    }

    enum FrequencySweepType: String, Codable, CaseIterable {
        case decade, linear, octave
    }
}

// MARK: - Equatable for document change detection

extension CircuitDocument: Equatable {
    static func == (lhs: CircuitDocument, rhs: CircuitDocument) -> Bool {
        lhs.components == rhs.components &&
        lhs.wires == rhs.wires &&
        lhs.metadata == rhs.metadata &&
        lhs.simulationConfig == rhs.simulationConfig
    }
}
