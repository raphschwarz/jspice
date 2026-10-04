import Foundation

/// A point on the drawing grid. Elements connect where their terminals share a grid point.
public struct GridPoint: Hashable, Codable, Sendable {
    public var x: Int
    public var y: Int

    public init(_ x: Int, _ y: Int) {
        self.x = x
        self.y = y
    }

    public static let zero = GridPoint(0, 0)

    public static func + (lhs: GridPoint, rhs: GridPoint) -> GridPoint { GridPoint(lhs.x + rhs.x, lhs.y + rhs.y) }
    public static func - (lhs: GridPoint, rhs: GridPoint) -> GridPoint { GridPoint(lhs.x - rhs.x, lhs.y - rhs.y) }
    public static func * (lhs: GridPoint, rhs: Int) -> GridPoint { GridPoint(lhs.x * rhs, lhs.y * rhs) }

    /// Rotated 90° clockwise on screen (y points down) around `pivot`
    public func rotated(around pivot: GridPoint) -> GridPoint {
        let d = self - pivot
        return pivot + GridPoint(-d.y, d.x)
    }
}

public enum ElementCategory: String, CaseIterable, Sendable, Identifiable {
    case basics = "Basics"
    case sources = "Sources"
    case switches = "Switches"
    case semiconductors = "Semiconductors"
    case amplifiers = "Amplifiers"
    case memristors = "Memristors"
    case instruments = "Instruments"

    public var id: String { rawValue }
}

public enum ElementKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case wire, ground, resistor, potentiometer, lamp, capacitor, inductor
    case dcVoltage, acVoltage, squareVoltage, currentSource
    case toggleSwitch, pushButton
    case diode, zener, led, npn, pnp, nmos, pmos
    case opAmp
    case memristor
    case probe, ammeter

    public var id: String { rawValue }
}

/// Describes one editable number of an element, for the inspector and for defaults.
public struct ParamSpec: Sendable, Hashable {
    public let key: String
    public let name: String
    public let unit: String
    public let defaultValue: Double
    /// Range offered by the inspector slider; typed values may go beyond it
    public let range: ClosedRange<Double>
    public let logarithmic: Bool

    public init(_ key: String, _ name: String, unit: String, default defaultValue: Double, range: ClosedRange<Double>, log: Bool = true) {
        self.key = key
        self.name = name
        self.unit = unit
        self.defaultValue = defaultValue
        self.range = range
        self.logarithmic = log
    }
}

public enum LEDColor: Int, CaseIterable, Sendable {
    case red, green, blue, yellow, white

    public var name: String {
        switch self {
        case .red: return "Red"
        case .green: return "Green"
        case .blue: return "Blue"
        case .yellow: return "Yellow"
        case .white: return "White"
        }
    }

    /// sRGB components of the emitted light
    public var rgb: (Double, Double, Double) {
        switch self {
        case .red: return (1.0, 0.18, 0.12)
        case .green: return (0.2, 0.95, 0.3)
        case .blue: return (0.25, 0.45, 1.0)
        case .yellow: return (1.0, 0.85, 0.1)
        case .white: return (1.0, 1.0, 0.95)
        }
    }

    /// Typical forward voltage at 10 mA
    public var forwardVoltage: Double {
        switch self {
        case .red: return 1.9
        case .yellow: return 2.0
        case .green: return 2.2
        case .blue, .white: return 3.0
        }
    }
}

extension ElementKind {
    public var displayName: String {
        switch self {
        case .wire: return "Wire"
        case .ground: return "Ground"
        case .resistor: return "Resistor"
        case .potentiometer: return "Potentiometer"
        case .lamp: return "Lamp"
        case .capacitor: return "Capacitor"
        case .inductor: return "Inductor"
        case .dcVoltage: return "DC Voltage"
        case .acVoltage: return "AC Voltage"
        case .squareVoltage: return "Square Wave"
        case .currentSource: return "Current Source"
        case .toggleSwitch: return "Switch"
        case .pushButton: return "Push Button"
        case .diode: return "Diode"
        case .zener: return "Zener Diode"
        case .led: return "LED"
        case .npn: return "NPN Transistor"
        case .pnp: return "PNP Transistor"
        case .nmos: return "NMOS Transistor"
        case .pmos: return "PMOS Transistor"
        case .opAmp: return "Op-Amp"
        case .memristor: return "Memristor"
        case .probe: return "Voltage Probe"
        case .ammeter: return "Ammeter"
        }
    }

    public var namePrefix: String {
        switch self {
        case .wire: return "W"
        case .ground: return "GND"
        case .resistor, .potentiometer: return "R"
        case .lamp: return "LMP"
        case .capacitor: return "C"
        case .inductor: return "L"
        case .dcVoltage, .acVoltage, .squareVoltage: return "V"
        case .currentSource: return "I"
        case .toggleSwitch, .pushButton: return "S"
        case .diode, .zener: return "D"
        case .led: return "LED"
        case .npn, .pnp: return "Q"
        case .nmos, .pmos: return "M"
        case .opAmp: return "U"
        case .memristor: return "MR"
        case .probe: return "P"
        case .ammeter: return "A"
        }
    }

    public var category: ElementCategory {
        switch self {
        case .wire, .ground, .resistor, .potentiometer, .lamp, .capacitor, .inductor: return .basics
        case .dcVoltage, .acVoltage, .squareVoltage, .currentSource: return .sources
        case .toggleSwitch, .pushButton: return .switches
        case .diode, .zener, .led, .npn, .pnp, .nmos, .pmos: return .semiconductors
        case .opAmp: return .amplifiers
        case .memristor: return .memristors
        case .probe, .ammeter: return .instruments
        }
    }

    /// Single-key shortcut that selects this tool on the canvas
    public var shortcut: Character? {
        switch self {
        case .wire: return "w"
        case .ground: return "g"
        case .resistor: return "r"
        case .potentiometer: return "t"
        case .lamp: return "y"
        case .capacitor: return "c"
        case .inductor: return "l"
        case .dcVoltage: return "v"
        case .acVoltage: return "a"
        case .squareVoltage: return "q"
        case .currentSource: return "i"
        case .toggleSwitch: return "s"
        case .pushButton: return "b"
        case .diode: return "d"
        case .zener: return "z"
        case .led: return "e"
        case .npn: return "j"
        case .pnp: return "k"
        case .nmos: return "n"
        case .pmos: return "p"
        case .opAmp: return "u"
        case .memristor: return "m"
        case .probe: return "o"
        case .ammeter: return "x"
        }
    }

    /// Three-terminal transistors drawn with their control terminal at `a` and their channel at `b`
    public var isTransistor: Bool { self == .nmos || self == .pmos || self == .npn || self == .pnp }

    public var isBipolar: Bool { self == .npn || self == .pnp }

    /// Parts whose terminals depend on a direction, which stay horizontal or vertical
    public var isAxisAligned: Bool { isTransistor || self == .opAmp || self == .potentiometer }

    /// Parts that can be mirrored across their axis
    public var canFlip: Bool { isTransistor || self == .opAmp || self == .potentiometer }

    public var isVoltageSource: Bool { self == .dcVoltage || self == .acVoltage || self == .squareVoltage }

    public var isSwitch: Bool { self == .toggleSwitch || self == .pushButton }

    /// Offset of the second point when the element is placed with a single click
    public var defaultOffset: GridPoint {
        switch self {
        case .ground: return GridPoint(0, 1)
        case .nmos, .pmos, .npn, .pnp: return GridPoint(2, 0)
        default: return GridPoint(4, 0)
        }
    }

    public var params: [ParamSpec] {
        switch self {
        case .wire, .ground, .toggleSwitch, .pushButton, .probe, .ammeter:
            return []
        case .resistor:
            return [ParamSpec("resistance", "Resistance", unit: "Ω", default: 1000, range: 1...10_000_000)]
        case .potentiometer:
            return [
                ParamSpec("resistance", "Resistance", unit: "Ω", default: 10_000, range: 10...10_000_000),
                ParamSpec("position", "Wiper position", unit: "", default: 0.5, range: 0...1, log: false),
            ]
        case .zener:
            return [ParamSpec("breakdown", "Breakdown voltage", unit: "V", default: 5.1, range: 1...50, log: false)]
        case .npn, .pnp:
            return [ParamSpec("beta", "Current gain", unit: "", default: 100, range: 5...1000)]
        case .opAmp:
            return [
                ParamSpec("gain", "Open-loop gain", unit: "", default: 100_000, range: 10...10_000_000),
                ParamSpec("limit", "Output limit", unit: "V", default: 15, range: 1...50, log: false),
            ]
        case .lamp:
            return [
                ParamSpec("resistance", "Resistance", unit: "Ω", default: 100, range: 1...100_000),
                ParamSpec("ratedPower", "Rated power", unit: "W", default: 0.25, range: 0.001...100),
            ]
        case .capacitor:
            return [
                ParamSpec("capacitance", "Capacitance", unit: "F", default: 10e-6, range: 1e-12...1),
                ParamSpec("initialVoltage", "Initial voltage", unit: "V", default: 0, range: -50...50, log: false),
            ]
        case .inductor:
            return [ParamSpec("inductance", "Inductance", unit: "H", default: 1, range: 1e-9...100)]
        case .dcVoltage:
            return [ParamSpec("voltage", "Voltage", unit: "V", default: 5, range: -24...24, log: false)]
        case .acVoltage:
            return [
                ParamSpec("amplitude", "Amplitude", unit: "V", default: 5, range: 0.001...1000),
                ParamSpec("frequency", "Frequency", unit: "Hz", default: 50, range: 0.01...1_000_000),
                ParamSpec("offset", "DC offset", unit: "V", default: 0, range: -24...24, log: false),
                ParamSpec("phase", "Phase", unit: "°", default: 0, range: 0...360, log: false),
            ]
        case .squareVoltage:
            return [
                ParamSpec("high", "High voltage", unit: "V", default: 5, range: -24...24, log: false),
                ParamSpec("low", "Low voltage", unit: "V", default: 0, range: -24...24, log: false),
                ParamSpec("frequency", "Frequency", unit: "Hz", default: 10, range: 0.01...1_000_000),
                ParamSpec("duty", "Duty cycle", unit: "", default: 0.5, range: 0.01...0.99, log: false),
            ]
        case .currentSource:
            return [ParamSpec("current", "Current", unit: "A", default: 0.01, range: 1e-6...10)]
        case .diode:
            return [
                ParamSpec("saturationCurrent", "Saturation current", unit: "A", default: 1e-14, range: 1e-18...1e-6),
                ParamSpec("emission", "Emission coefficient", unit: "", default: 1, range: 0.5...3, log: false),
            ]
        case .led:
            return [ParamSpec("color", "Color", unit: "", default: 0, range: 0...4, log: false)]
        case .nmos, .pmos:
            return [
                ParamSpec("threshold", "Threshold voltage", unit: "V", default: 1.5, range: 0.1...5, log: false),
                ParamSpec("beta", "Beta", unit: "A/V²", default: 0.02, range: 1e-4...1),
            ]
        case .memristor:
            return [
                ParamSpec("ron", "On resistance", unit: "Ω", default: 1000, range: 1...10_000_000),
                ParamSpec("roff", "Off resistance", unit: "Ω", default: 10_000, range: 1...10_000_000),
                ParamSpec("von", "On threshold", unit: "V", default: 0.3, range: 0.01...10, log: false),
                ParamSpec("voff", "Off threshold", unit: "V", default: 0.3, range: 0.01...10, log: false),
                ParamSpec("tau", "Switching time", unit: "s", default: 0.05, range: 1e-7...100),
                ParamSpec("initialState", "Initial state", unit: "", default: 0, range: 0...1, log: false),
            ]
        }
    }
}

/// One component on the schematic. Two-terminal parts run from `a` to `b`; a ground's terminal is `a` and `b` sets its
/// direction; a transistor's gate is at `a`, its channel at `b`, with drain and source two grid units either side of `b`.
public struct Element: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: ElementKind
    public var name: String
    public var a: GridPoint
    public var b: GridPoint
    public var params: [String: Double]
    /// Switch state
    public var closed: Bool
    /// Mirrored across its axis (transistors, op-amps, potentiometers)
    public var flipped: Bool

    public init(id: UUID = UUID(), kind: ElementKind, name: String = "", a: GridPoint, b: GridPoint,
                params: [String: Double] = [:], closed: Bool = false, flipped: Bool = false) {
        self.id = id
        self.kind = kind
        self.name = name
        self.a = a
        self.b = b
        self.params = params
        self.closed = closed
        self.flipped = flipped
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decode(ElementKind.self, forKey: .kind)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        a = try container.decode(GridPoint.self, forKey: .a)
        b = try container.decode(GridPoint.self, forKey: .b)
        params = try container.decodeIfPresent([String: Double].self, forKey: .params) ?? [:]
        closed = try container.decodeIfPresent(Bool.self, forKey: .closed) ?? false
        flipped = try container.decodeIfPresent(Bool.self, forKey: .flipped) ?? false
    }

    /// A parameter value, falling back to the kind's default
    public subscript(param key: String) -> Double {
        get { params[key] ?? kind.params.first(where: { $0.key == key })?.defaultValue ?? 0 }
        set { params[key] = newValue }
    }

    /// Unit direction from `a` to `b` along the dominant axis
    var axisDirection: GridPoint {
        let dx = b.x - a.x
        let dy = b.y - a.y
        if dx == 0 && dy == 0 { return GridPoint(1, 0) }
        return abs(dx) >= abs(dy) ? GridPoint(dx.signum(), 0) : GridPoint(0, dy.signum())
    }

    /// Unit vector at right angles to the element's axis: "below" a left-to-right part, or "above" it when flipped
    public var perpendicular: GridPoint {
        let d = axisDirection
        let p = GridPoint(-d.y, d.x)
        return flipped ? p * -1 : p
    }

    /// Drain and source (collector and emitter) terminals of a transistor. N-type devices have their drain or collector
    /// on the side opposite `perpendicular`, P-type devices on the same side.
    public var transistorTerminals: (drain: GridPoint, source: GridPoint) {
        let up = b - perpendicular * 2
        let down = b + perpendicular * 2
        return kind == .nmos || kind == .npn ? (up, down) : (down, up)
    }

    /// The potentiometer's wiper, two grid units to the side of its middle
    public var wiper: GridPoint {
        GridPoint((a.x + b.x) / 2, (a.y + b.y) / 2) - perpendicular * 2
    }

    /// Terminal positions: [a, b] for two-terminal parts, [a] for ground, [gate, drain, source] for MOSFETs,
    /// [base, collector, emitter] for bipolar transistors, [a, b, wiper] for potentiometers and [−, +, output] for op-amps
    public var posts: [GridPoint] {
        switch kind {
        case .ground:
            return [a]
        case .nmos, .pmos, .npn, .pnp:
            let t = transistorTerminals
            return [a, t.drain, t.source]
        case .potentiometer:
            return [a, b, wiper]
        case .opAmp:
            return [a - perpendicular, a + perpendicular, b]
        default:
            return [a, b]
        }
    }

    /// All grid points the element occupies at its ends, for moving and bounds
    public var extentPoints: [GridPoint] {
        posts.count > 2 ? posts + [a, b] : [a, b]
    }

    /// Ideal conductors: their ends are the same node
    public var isConductor: Bool {
        kind == .wire || kind == .ammeter || (kind.isSwitch && closed)
    }
}
