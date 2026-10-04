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

/// A trace shown in the scope panel: one quantity of one element over time.
public struct ScopeSpec: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var elementID: UUID
    public var quantity: Quantity

    public init(id: UUID = UUID(), elementID: UUID, quantity: Quantity) {
        self.id = id
        self.elementID = elementID
        self.quantity = quantity
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

public struct Circuit: Codable, Hashable, Sendable {
    public var elements: [Element]
    public var scopes: [ScopeSpec]
    public var settings: SimulationSettings

    public init(elements: [Element] = [], scopes: [ScopeSpec] = [], settings: SimulationSettings = SimulationSettings()) {
        self.elements = elements
        self.scopes = scopes
        self.settings = settings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        elements = try container.decodeIfPresent([Element].self, forKey: .elements) ?? []
        scopes = try container.decodeIfPresent([ScopeSpec].self, forKey: .scopes) ?? []
        settings = try container.decodeIfPresent(SimulationSettings.self, forKey: .settings) ?? SimulationSettings()
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
