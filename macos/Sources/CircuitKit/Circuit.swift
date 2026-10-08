import Foundation

public enum Quantity: String, Codable, CaseIterable, Sendable, Identifiable {
    case voltage, current, power, resistance

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .voltage: return "Voltage"
        case .current: return "Current"
        case .power: return "Power"
        case .resistance: return "Resistance"
        }
    }

    public var unit: String {
        switch self {
        case .voltage: return "V"
        case .current: return "A"
        case .power: return "W"
        case .resistance: return "Ω"
        }
    }
}

public enum ScopePlot: String, Codable, Sendable {
    /// The quantity against time
    case time
    /// Current against voltage: the I–V curve, e.g. a memristor's pinched hysteresis loop
    case currentVersusVoltage
    /// The voltage's gain and phase against frequency for small signals from a source (a Bode plot), around the
    /// circuit's operating point with that source held still
    case frequencyResponse
}

/// A trace shown in the scope panel: one quantity of one element over time, or its current against its voltage.
public struct ScopeSpec: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var elementID: UUID
    public var quantity: Quantity
    public var plot: ScopePlot
    /// For a frequency response: the source driving it (nil: the circuit's first signal source)
    public var sourceID: UUID?

    public init(id: UUID = UUID(), elementID: UUID, quantity: Quantity, plot: ScopePlot = .time, sourceID: UUID? = nil) {
        self.id = id
        self.elementID = elementID
        self.quantity = quantity
        self.plot = plot
        self.sourceID = sourceID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        elementID = try container.decode(UUID.self, forKey: .elementID)
        quantity = try container.decodeIfPresent(Quantity.self, forKey: .quantity) ?? .voltage
        plot = try container.decodeIfPresent(ScopePlot.self, forKey: .plot) ?? .time
        sourceID = try container.decodeIfPresent(UUID.self, forKey: .sourceID)
    }
}

public struct SimulationSettings: Codable, Hashable, Sendable {
    /// Pick the speed from the circuit's time constants: real time when changes are slow enough to watch, slow motion otherwise
    public var autoSpeed: Bool
    /// Simulated seconds per real second, when not automatic
    public var speed: Double
    public var autoTimeStep: Bool
    public var timeStep: Double

    public init(autoSpeed: Bool = true, speed: Double = 1, autoTimeStep: Bool = true, timeStep: Double = 1e-5) {
        self.autoSpeed = autoSpeed
        self.speed = speed
        self.autoTimeStep = autoTimeStep
        self.timeStep = timeStep
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoSpeed = try container.decodeIfPresent(Bool.self, forKey: .autoSpeed) ?? true
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        autoTimeStep = try container.decodeIfPresent(Bool.self, forKey: .autoTimeStep) ?? true
        timeStep = try container.decodeIfPresent(Double.self, forKey: .timeStep) ?? 1e-5
    }
}

/// A step sequencer that plays the circuit's keyboard sources by itself, one step per sixteenth note: each step a note
/// or a rest, the gate open for part of the step, the pattern repeating. It runs on simulated time, so it keeps exact
/// time at any speed, with sound on, and in automated simulations.
public struct StepSequence: Codable, Hashable, Sendable {
    /// MIDI note of each step (60 is middle C); nil is a rest
    public var steps: [Double?]
    /// Quarter notes per minute
    public var tempo: Double
    /// Fraction of each step the gate stays open
    public var gateLength: Double
    public var playing: Bool

    public init(steps: [Double?], tempo: Double = 120, gateLength: Double = 0.5, playing: Bool = true) {
        self.steps = steps
        self.tempo = tempo
        self.gateLength = gateLength
        self.playing = playing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        steps = try container.decodeIfPresent([Double?].self, forKey: .steps) ?? []
        tempo = try container.decodeIfPresent(Double.self, forKey: .tempo) ?? 120
        gateLength = try container.decodeIfPresent(Double.self, forKey: .gateLength) ?? 0.5
        playing = try container.decodeIfPresent(Bool.self, forKey: .playing) ?? true
    }

    /// Seconds per step: a sixteenth note
    public var stepDuration: Double { 15 / min(max(tempo, 1), 1000) }

    /// The note and gate at time `t`; during a rest the pitch stays on the last note played. Nil without steps.
    public func state(at t: Double) -> (note: Double, gate: Bool)? {
        guard !steps.isEmpty else { return nil }
        let position = max(t, 0) / stepDuration
        let index = Int(position.rounded(.down)) % steps.count
        let phase = position - position.rounded(.down)
        if let note = steps[index] { return (note, phase < min(max(gateLength, 0.01), 1)) }
        for back in 1..<max(steps.count, 2) {
            if let note = steps[(index - back + steps.count * 2) % steps.count] { return (note, false) }
        }
        return (60, false)
    }
}

public struct Circuit: Codable, Hashable, Sendable {
    public var elements: [Element]
    public var scopes: [ScopeSpec]
    public var settings: SimulationSettings
    /// Net names given when the circuit was built from a netlist, by "part.terminal", so the nets can still be referred
    /// to by name once they are drawn as wires
    public var netNames: [String: String]
    /// A pattern that plays the keyboard sources, if any
    public var sequence: StepSequence?
    /// MIDI controllers mapped to the circuit's knobs and switches
    public var midiMappings: [MIDIMapping]

    public init(elements: [Element] = [], scopes: [ScopeSpec] = [], settings: SimulationSettings = SimulationSettings(),
                netNames: [String: String] = [:], sequence: StepSequence? = nil, midiMappings: [MIDIMapping] = []) {
        self.elements = elements
        self.scopes = scopes
        self.settings = settings
        self.netNames = netNames
        self.sequence = sequence
        self.midiMappings = midiMappings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        elements = try container.decodeIfPresent([Element].self, forKey: .elements) ?? []
        scopes = try container.decodeIfPresent([ScopeSpec].self, forKey: .scopes) ?? []
        settings = try container.decodeIfPresent(SimulationSettings.self, forKey: .settings) ?? SimulationSettings()
        netNames = try container.decodeIfPresent([String: String].self, forKey: .netNames) ?? [:]
        sequence = try container.decodeIfPresent(StepSequence.self, forKey: .sequence)
        midiMappings = try container.decodeIfPresent([MIDIMapping].self, forKey: .midiMappings) ?? []
    }

    public subscript(id: UUID) -> Element? {
        elements.first { $0.id == id }
    }

    public func index(of id: UUID) -> Int? {
        elements.firstIndex { $0.id == id }
    }

    public func uniqueName(for kind: ElementKind) -> String {
        let used = Set(elements.map(\.name))
        var i = 1
        while used.contains("\(kind.namePrefix)\(i)") { i += 1 }
        return "\(kind.namePrefix)\(i)"
    }

    /// Adds an element, naming it if it has no name yet
    @discardableResult
    public mutating func add(_ element: Element) -> UUID {
        var element = element
        if element.name.isEmpty && element.kind != .wire && element.kind != .ground {
            element.name = uniqueName(for: element.kind)
        }
        elements.append(element)
        return element.id
    }

    public mutating func remove(_ ids: Set<UUID>) {
        elements.removeAll { ids.contains($0.id) }
        scopes.removeAll { ids.contains($0.elementID) }
        midiMappings.removeAll { ids.contains($0.part) }
    }

    public mutating func update(_ id: UUID, _ change: (inout Element) -> Void) {
        guard let i = index(of: id) else { return }
        change(&elements[i])
    }

    /// Moves the elements by `delta`. Wires that are not moved but end on a moved terminal stretch to follow it.
    public mutating func move(_ ids: Set<UUID>, by delta: GridPoint) {
        guard delta != .zero else { return }
        var moved = Set<GridPoint>()
        for element in elements where ids.contains(element.id) {
            moved.formUnion(element.posts)
        }
        for i in elements.indices {
            if ids.contains(elements[i].id) {
                elements[i].a = elements[i].a + delta
                elements[i].b = elements[i].b + delta
            } else if elements[i].kind == .wire {
                if moved.contains(elements[i].a) { elements[i].a = elements[i].a + delta }
                if moved.contains(elements[i].b) { elements[i].b = elements[i].b + delta }
            }
        }
        elements.removeAll { $0.kind == .wire && $0.a == $0.b }
    }

    /// Mirrors transistors, op-amps and potentiometers across their axis
    public mutating func flip(_ ids: Set<UUID>) {
        for i in elements.indices where ids.contains(elements[i].id) && elements[i].kind.canFlip {
            elements[i].flipped.toggle()
        }
    }

    /// Connects the terminals of the given elements to wires they land on: a wire that has one of those terminals in its
    /// middle (not at an end) is split there, making a T-junction. Wires that only cross stay unconnected.
    public mutating func connectTerminals(of ids: Set<UUID>) {
        var points = Set<GridPoint>()
        for element in elements where ids.contains(element.id) {
            points.formUnion(element.posts)
        }
        guard !points.isEmpty else { return }
        var result: [Element] = []
        for element in elements {
            guard element.kind == .wire else {
                result.append(element)
                continue
            }
            // terminals strictly inside this wire, ordered from a to b
            let inside = points.filter { $0 != element.a && $0 != element.b && Self.lies($0, on: element.a, element.b) }
                .sorted { Self.distanceSquared(element.a, $0) < Self.distanceSquared(element.a, $1) }
            if inside.isEmpty {
                result.append(element)
                continue
            }
            var start = element.a
            for (k, point) in (inside + [element.b]).enumerated() {
                var piece = element
                if k > 0 { piece.id = UUID() }
                piece.a = start
                piece.b = point
                result.append(piece)
                start = point
            }
        }
        elements = result
    }

    static func lies(_ p: GridPoint, on a: GridPoint, _ b: GridPoint) -> Bool {
        let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
        guard cross == 0 else { return false }
        let dot = (p.x - a.x) * (b.x - a.x) + (p.y - a.y) * (b.y - a.y)
        return dot > 0 && dot < distanceSquared(a, b)
    }

    static func distanceSquared(_ a: GridPoint, _ b: GridPoint) -> Int {
        (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
    }

    /// Rotates the elements 90° clockwise around the centre of their bounds
    public mutating func rotate(_ ids: Set<UUID>) {
        let points = elements.filter { ids.contains($0.id) }.flatMap(\.extentPoints)
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return }
        let pivot = GridPoint((minX + maxX) / 2, (minY + maxY) / 2)
        for i in elements.indices where ids.contains(elements[i].id) {
            elements[i].a = elements[i].a.rotated(around: pivot)
            elements[i].b = elements[i].b.rotated(around: pivot)
        }
    }

    /// Smallest rectangle containing every terminal, or nil for an empty circuit
    public var bounds: (min: GridPoint, max: GridPoint)? {
        let points = elements.flatMap(\.extentPoints)
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        return (GridPoint(minX, minY), GridPoint(maxX, maxY))
    }
}
