import Foundation
import CoreGraphics

// MARK: - Component Type

enum ComponentType: String, Codable, CaseIterable, Identifiable {
    // Passive
    case resistor
    case capacitor
    case inductor

    // Semiconductor
    case diode
    case npnBJT
    case pnpBJT
    case nmosFET
    case pmosFET

    // Op-Amps
    case opAmp

    // Sources
    case dcVoltageSource
    case dcCurrentSource
    case acVoltageSource
    case signalGenerator

    // Controlled Sources
    case vcvs  // Voltage-Controlled Voltage Source
    case vccs  // Voltage-Controlled Current Source
    case ccvs  // Current-Controlled Voltage Source
    case cccs  // Current-Controlled Current Source

    // Special
    case ground

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .resistor: return "Resistor"
        case .capacitor: return "Capacitor"
        case .inductor: return "Inductor"
        case .diode: return "Diode"
        case .npnBJT: return "NPN BJT"
        case .pnpBJT: return "PNP BJT"
        case .nmosFET: return "N-MOSFET"
        case .pmosFET: return "P-MOSFET"
        case .opAmp: return "Op-Amp"
        case .dcVoltageSource: return "DC Voltage"
        case .dcCurrentSource: return "DC Current"
        case .acVoltageSource: return "AC Voltage"
        case .signalGenerator: return "Signal Gen"
        case .vcvs: return "VCVS"
        case .vccs: return "VCCS"
        case .ccvs: return "CCVS"
        case .cccs: return "CCCS"
        case .ground: return "Ground"
        }
    }

    var category: ComponentCategory {
        switch self {
        case .resistor, .capacitor, .inductor:
            return .passive
        case .diode, .npnBJT, .pnpBJT, .nmosFET, .pmosFET:
            return .semiconductor
        case .opAmp:
            return .amplifier
        case .dcVoltageSource, .dcCurrentSource, .acVoltageSource, .signalGenerator:
            return .source
        case .vcvs, .vccs, .ccvs, .cccs:
            return .controlledSource
        case .ground:
            return .special
        }
    }

    var symbolName: String {
        switch self {
        case .resistor: return "r.square"
        case .capacitor: return "c.square"
        case .inductor: return "l.joystick.tilt.up"
        case .diode: return "arrow.right.to.line"
        case .npnBJT, .pnpBJT: return "arrow.triangle.branch"
        case .nmosFET, .pmosFET: return "square.3.layers.3d"
        case .opAmp: return "triangle.fill"
        case .dcVoltageSource: return "battery.100"
        case .dcCurrentSource: return "arrow.up.circle"
        case .acVoltageSource: return "waveform.circle"
        case .signalGenerator: return "waveform"
        case .vcvs, .vccs, .ccvs, .cccs: return "diamond"
        case .ground: return "arrow.down.to.line"
        }
    }

    var defaultParameters: [String: ComponentParameter] {
        switch self {
        case .resistor:
            return ["resistance": .init(name: "Resistance", value: 1000, unit: .ohm, min: 0.001, max: 1e12)]
        case .capacitor:
            return [
                "capacitance": .init(name: "Capacitance", value: 1e-6, unit: .farad, min: 1e-15, max: 1),
                "initialVoltage": .init(name: "Initial Voltage", value: 0, unit: .volt, min: -1000, max: 1000)
            ]
        case .inductor:
            return [
                "inductance": .init(name: "Inductance", value: 1e-3, unit: .henry, min: 1e-12, max: 100),
                "initialCurrent": .init(name: "Initial Current", value: 0, unit: .ampere, min: -100, max: 100)
            ]
        case .diode:
            return [
                "saturationCurrent": .init(name: "Is", value: 1e-14, unit: .ampere, min: 1e-18, max: 1e-6),
                "emissionCoefficient": .init(name: "N", value: 1.0, unit: .none, min: 0.5, max: 5),
                "breakdownVoltage": .init(name: "Vbr", value: 100, unit: .volt, min: 0, max: 1000)
            ]
        case .npnBJT, .pnpBJT:
            return [
                "beta": .init(name: "Beta (hFE)", value: 100, unit: .none, min: 1, max: 10000),
                "saturationCurrent": .init(name: "Is", value: 1e-14, unit: .ampere, min: 1e-18, max: 1e-6),
                "earlyVoltage": .init(name: "VA", value: 100, unit: .volt, min: 1, max: 1000)
            ]
        case .nmosFET:
            return [
                "threshold": .init(name: "Vth", value: 0.7, unit: .volt, min: 0.01, max: 10),
                "kp": .init(name: "Kp", value: 110e-6, unit: .none, min: 1e-9, max: 1),
                "channelLength": .init(name: "L", value: 1e-6, unit: .meter, min: 1e-9, max: 1e-3),
                "channelWidth": .init(name: "W", value: 10e-6, unit: .meter, min: 1e-9, max: 1e-3)
            ]
        case .pmosFET:
            return [
                "threshold": .init(name: "Vth", value: -0.7, unit: .volt, min: -10, max: -0.01),
                "kp": .init(name: "Kp", value: 50e-6, unit: .none, min: 1e-9, max: 1),
                "channelLength": .init(name: "L", value: 1e-6, unit: .meter, min: 1e-9, max: 1e-3),
                "channelWidth": .init(name: "W", value: 20e-6, unit: .meter, min: 1e-9, max: 1e-3)
            ]
        case .opAmp:
            return [
                "openLoopGain": .init(name: "Aol", value: 1e5, unit: .none, min: 1, max: 1e9),
                "gbwProduct": .init(name: "GBW", value: 1e6, unit: .hertz, min: 1e3, max: 1e9),
                "inputOffset": .init(name: "Vos", value: 0, unit: .volt, min: -0.1, max: 0.1)
            ]
        case .dcVoltageSource:
            return ["voltage": .init(name: "Voltage", value: 5.0, unit: .volt, min: -1000, max: 1000)]
        case .dcCurrentSource:
            return ["current": .init(name: "Current", value: 0.001, unit: .ampere, min: -100, max: 100)]
        case .acVoltageSource:
            return [
                "amplitude": .init(name: "Amplitude", value: 1.0, unit: .volt, min: 0, max: 1000),
                "frequency": .init(name: "Frequency", value: 1000, unit: .hertz, min: 0.01, max: 1e9),
                "phase": .init(name: "Phase", value: 0, unit: .degree, min: 0, max: 360),
                "dcOffset": .init(name: "DC Offset", value: 0, unit: .volt, min: -1000, max: 1000)
            ]
        case .signalGenerator:
            return [
                "waveform": .init(name: "Waveform", value: 0, unit: .none, min: 0, max: 4), // 0=sine,1=square,2=tri,3=saw,4=pulse
                "amplitude": .init(name: "Amplitude", value: 1.0, unit: .volt, min: 0, max: 1000),
                "frequency": .init(name: "Frequency", value: 1000, unit: .hertz, min: 0.01, max: 1e9),
                "phase": .init(name: "Phase", value: 0, unit: .degree, min: 0, max: 360),
                "dcOffset": .init(name: "DC Offset", value: 0, unit: .volt, min: -1000, max: 1000),
                "dutyCycle": .init(name: "Duty Cycle", value: 0.5, unit: .none, min: 0, max: 1)
            ]
        case .vcvs, .vccs, .ccvs, .cccs:
            return ["gain": .init(name: "Gain", value: 1.0, unit: .none, min: -1e6, max: 1e6)]
        case .ground:
            return [:]
        }
    }

    var pinCount: Int {
        switch self {
        case .resistor, .capacitor, .inductor, .diode,
             .dcVoltageSource, .dcCurrentSource, .acVoltageSource, .signalGenerator:
            return 2
        case .npnBJT, .pnpBJT, .nmosFET, .pmosFET:
            return 3
        case .opAmp:
            return 5  // in+, in-, out, V+, V-
        case .vcvs, .vccs, .ccvs, .cccs:
            return 4
        case .ground:
            return 1
        }
    }

    var pinNames: [String] {
        switch self {
        case .resistor, .capacitor, .inductor:
            return ["1", "2"]
        case .diode:
            return ["anode", "cathode"]
        case .npnBJT:
            return ["collector", "base", "emitter"]
        case .pnpBJT:
            return ["collector", "base", "emitter"]
        case .nmosFET, .pmosFET:
            return ["drain", "gate", "source"]
        case .opAmp:
            return ["in+", "in-", "out", "V+", "V-"]
        case .dcVoltageSource, .dcCurrentSource, .acVoltageSource, .signalGenerator:
            return ["+", "-"]
        case .vcvs, .vccs:
            return ["out+", "out-", "ctrl+", "ctrl-"]
        case .ccvs, .cccs:
            return ["out+", "out-", "sense+", "sense-"]
        case .ground:
            return ["gnd"]
        }
    }
}

// MARK: - Component Category

enum ComponentCategory: String, Codable, CaseIterable, Identifiable {
    case passive = "Passive"
    case semiconductor = "Semiconductor"
    case amplifier = "Amplifiers"
    case source = "Sources"
    case controlledSource = "Controlled Sources"
    case special = "Special"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .passive: return "circle.grid.2x2"
        case .semiconductor: return "cpu"
        case .amplifier: return "triangle.fill"
        case .source: return "bolt.fill"
        case .controlledSource: return "diamond.fill"
        case .special: return "star.fill"
        }
    }

    var components: [ComponentType] {
        ComponentType.allCases.filter { $0.category == self }
    }
}

// MARK: - Component Parameter

struct ComponentParameter: Codable, Equatable {
    var name: String
    var value: Double
    var unit: ParameterUnit
    var min: Double
    var max: Double
}

enum ParameterUnit: String, Codable, CaseIterable {
    case ohm = "Ω"
    case farad = "F"
    case henry = "H"
    case volt = "V"
    case ampere = "A"
    case hertz = "Hz"
    case degree = "°"
    case meter = "m"
    case none = ""

    var symbol: String { rawValue }
}

// MARK: - Schematic Component (placed on canvas)

struct SchematicComponent: Identifiable, Codable, Equatable {
    let id: UUID
    var type: ComponentType
    var label: String
    var position: CGPoint
    var rotation: Double  // degrees: 0, 90, 180, 270
    var isMirrored: Bool
    var parameters: [String: ComponentParameter]
    var modelName: String?  // e.g., "2N3904", "1N4148"

    init(
        type: ComponentType,
        label: String? = nil,
        position: CGPoint = .zero,
        rotation: Double = 0,
        isMirrored: Bool = false,
        modelName: String? = nil
    ) {
        self.id = UUID()
        self.type = type
        self.label = label ?? type.displayName
        self.position = position
        self.rotation = rotation
        self.isMirrored = isMirrored
        self.parameters = type.defaultParameters
        self.modelName = modelName
    }

    /// Pin positions relative to component center, accounting for rotation
    var pinPositions: [CGPoint] {
        let basePins = type.basePinOffsets
        return basePins.map { pin in
            rotatePoint(pin, byDegrees: rotation, mirrored: isMirrored)
        }
    }

    /// Absolute pin positions on the canvas
    var absolutePinPositions: [CGPoint] {
        pinPositions.map { CGPoint(x: position.x + $0.x, y: position.y + $0.y) }
    }

    private func rotatePoint(_ point: CGPoint, byDegrees degrees: Double, mirrored: Bool) -> CGPoint {
        let radians = degrees * .pi / 180
        var x = point.x
        let y = point.y
        if mirrored { x = -x }
        return CGPoint(
            x: x * cos(radians) - y * sin(radians),
            y: x * sin(radians) + y * cos(radians)
        )
    }
}

extension ComponentType {
    /// Default pin offsets relative to component center (before rotation)
    var basePinOffsets: [CGPoint] {
        let spacing: CGFloat = 30
        switch pinCount {
        case 1: return [CGPoint(x: 0, y: spacing)]
        case 2: return [CGPoint(x: -spacing, y: 0), CGPoint(x: spacing, y: 0)]
        case 3: return [CGPoint(x: -spacing, y: 0), CGPoint(x: 0, y: -spacing), CGPoint(x: 0, y: spacing)]
        case 4: return [
            CGPoint(x: -spacing, y: -spacing/2), CGPoint(x: -spacing, y: spacing/2),
            CGPoint(x: spacing, y: -spacing/2), CGPoint(x: spacing, y: spacing/2)
        ]
        case 5: return [
            CGPoint(x: -spacing, y: -spacing/3), CGPoint(x: -spacing, y: spacing/3),
            CGPoint(x: spacing, y: 0),
            CGPoint(x: 0, y: -spacing), CGPoint(x: 0, y: spacing)
        ]
        default: return []
        }
    }
}

// MARK: - Wire

struct Wire: Identifiable, Codable, Equatable {
    let id: UUID
    var startComponentID: UUID
    var startPinIndex: Int
    var endComponentID: UUID
    var endPinIndex: Int
    var waypoints: [CGPoint]

    init(
        startComponentID: UUID,
        startPinIndex: Int,
        endComponentID: UUID,
        endPinIndex: Int,
        waypoints: [CGPoint] = []
    ) {
        self.id = UUID()
        self.startComponentID = startComponentID
        self.startPinIndex = startPinIndex
        self.endComponentID = endComponentID
        self.endPinIndex = endPinIndex
        self.waypoints = waypoints
    }
}
