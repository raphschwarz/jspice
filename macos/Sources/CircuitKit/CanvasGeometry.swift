import Foundation

/// A straight piece of wire between two grid points
public struct WireSegment: Hashable, Sendable {
    public var a: GridPoint
    public var b: GridPoint

    public init(_ a: GridPoint, _ b: GridPoint) {
        self.a = a
        self.b = b
    }
}

/// The schematic editor's geometry that does not depend on the screen: how a drawn wire is routed, which terminals
/// are free to start one from, and where pasted parts land.
public enum CanvasGeometry {
    /// Which way a wire drawn by dragging `delta` from its start leaves it: horizontally when the drag went at least as
    /// far across as down; nil while it has not moved
    public static func startsHorizontally(_ delta: GridPoint) -> Bool? {
        if delta == .zero { return nil }
        return abs(delta.x) >= abs(delta.y)
    }

    /// The wire from `a` to `b`: one segment when the two are in line (or `straight`, at any angle), else an elbow of a
    /// horizontal and a vertical segment, the first one leaving `a` horizontally when `horizontalFirst`. None when the
    /// two points are the same.
    public static func elbow(from a: GridPoint, to b: GridPoint, horizontalFirst: Bool, straight: Bool = false) -> [WireSegment] {
        if a == b { return [] }
        if straight || a.x == b.x || a.y == b.y { return [WireSegment(a, b)] }
        let corner = horizontalFirst ? GridPoint(b.x, a.y) : GridPoint(a.x, b.y)
        return [WireSegment(a, corner), WireSegment(corner, b)]
    }

    /// The elements moved together so that the middle of their extent lands on `target` (a grid point, so the pasted
    /// parts stay on the grid), keeping their positions relative to each other. Only their places change.
    public static func placed(_ elements: [Element], centredAt target: GridPoint) -> [Element] {
        let points = elements.flatMap(\.extentPoints)
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return elements }
        // (>> 1 rounds down for negative sums too, so the same copy always lands the same way)
        let centre = GridPoint((minX + maxX) >> 1, (minY + maxY) >> 1)
        let delta = target - centre
        return elements.map { element in
            var element = element
            element.a = element.a + delta
            element.b = element.b + delta
            return element
        }
    }
}

extension Circuit {
    /// How many terminals (posts) of all the elements sit at each grid point. Two or more at a point connect there.
    public var terminalCounts: [GridPoint: Int] {
        var count: [GridPoint: Int] = [:]
        for element in elements {
            for post in element.posts { count[post, default: 0] += 1 }
        }
        return count
    }

    /// The free terminals, each with the element it belongs to: a terminal is free when no other terminal (of any
    /// element, wires included, or another of the element's own) shares its grid point, so nothing connects to it. These
    /// are the terminals the canvas rings as unconnected. (A terminal that only touches the middle of a wire is free too:
    /// the circuit does not join them until a wire is split there.)
    public var freeTerminals: [GridPoint: UUID] {
        let count = terminalCounts
        var free: [GridPoint: UUID] = [:]
        for element in elements {
            for post in element.posts where count[post] == 1 { free[post] = element.id }
        }
        return free
    }

    /// True when exactly one terminal sits at `point`
    public func isFreeTerminal(_ point: GridPoint) -> Bool {
        var n = 0
        for element in elements {
            for post in element.posts where post == point {
                n += 1
                if n > 1 { return false }
            }
        }
        return n == 1
    }

    /// Adds a wire drawn as `segments` (as `CanvasGeometry.elbow` routes it) and joins its two outer ends to wires
    /// they land on the middle of, as a part's terminals join a wire it is dropped on. The corner of an elbow joins
    /// nothing it happens to pass over. Returns the new wires' ids.
    @discardableResult
    public mutating func addWire(_ segments: [WireSegment]) -> [UUID] {
        let segments = segments.filter { $0.a != $0.b }
        guard let first = segments.first, let last = segments.last else { return [] }
        var ids: [UUID] = []
        for segment in segments {
            ids.append(add(Element(kind: .wire, a: segment.a, b: segment.b)))
        }
        splitWires(at: [first.a, last.b], sparing: Set(ids))
        return ids
    }

    /// Splits every wire (but those in `sparing`) that has one of `points` strictly inside it, making T-junctions there
    public mutating func splitWires(at points: Set<GridPoint>, sparing: Set<UUID> = []) {
        guard !points.isEmpty else { return }
        var result: [Element] = []
        for element in elements {
            guard element.kind == .wire, !sparing.contains(element.id) else {
                result.append(element)
                continue
            }
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
}

extension ElementKind {
    /// The value the canvas prints beside a part of this kind and lets you edit in place (double-click or Return):
    /// the first value its label shows, when that is a number (resistance, capacitance, a source's voltage). Nil for
    /// parts labelled with a model's name, a reading or a choice, which keep the inspector.
    public var inlineValueParam: ParamSpec? {
        let key: String
        switch self {
        case .resistor, .potentiometer, .lamp: key = "resistance"
        case .zener: key = "breakdown"
        case .speaker: key = "fullScale"
        case .capacitor: key = "capacitance"
        case .inductor: key = "inductance"
        case .dcVoltage: key = "voltage"
        case .acVoltage, .noiseVoltage: key = "amplitude"
        case .squareVoltage, .keyboardGate: key = "high"
        case .currentSource: key = "current"
        default: return nil
        }
        return params.first { $0.key == key && $0.choices.isEmpty }
    }
}
