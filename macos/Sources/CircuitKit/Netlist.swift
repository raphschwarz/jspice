import Foundation

/// A part described by its connections rather than its position: which net each terminal joins.
public struct NetlistPart: Sendable {
    public var kind: ElementKind
    public var name: String
    public var params: [String: Double]
    public var flipped: Bool
    /// Terminal name (see `ElementKind.terminalNames`) or 1-based terminal number, to net name. "GND" or "0" is ground.
    public var connections: [String: String]

    public init(kind: ElementKind, name: String = "", params: [String: Double] = [:], flipped: Bool = false,
                connections: [String: String] = [:]) {
        self.kind = kind
        self.name = name
        self.params = params
        self.flipped = flipped
        self.connections = connections
    }
}

public enum NetlistError: Error, CustomStringConvertible {
    case unknownTerminal(part: String, terminal: String, valid: [String])
    case duplicateName(String)

    public var description: String {
        switch self {
        case let .unknownTerminal(part, terminal, valid):
            return "\(part) has no terminal \"\(terminal)\"; its terminals are \(valid.joined(separator: ", "))"
        case let .duplicateName(name):
            return "There is already a part named \(name)"
        }
    }
}

/// Turns netlists into drawable schematics: each part gets its own cell on a grid, three to a row, and each connected
/// terminal a short lead ending in a net label (or a ground symbol), so parts on the same net are joined by name.
public enum NetlistLayout {
    static let cellWidth = 13
    static let cellHeight = 9
    static let columns = 3

    /// Top-left corner of cell number `index`
    public static func cellOrigin(_ index: Int) -> GridPoint {
        GridPoint((index % columns) * cellWidth, (index / columns) * cellHeight)
    }

    /// The first cell below everything already in the circuit
    public static func firstFreeCell(in circuit: Circuit) -> Int {
        guard let bounds = circuit.bounds else { return 0 }
        let row = Int((Double(bounds.max.y + 3) / Double(cellHeight)).rounded(.up))
        return max(0, row) * columns
    }

    /// Index of a terminal given by name (case-insensitive), or by 1-based number
    public static func terminalIndex(_ terminal: String, of kind: ElementKind) -> Int? {
        let names = kind.terminalNames
        let key = terminal.trimmingCharacters(in: .whitespaces).lowercased()
        if let index = names.firstIndex(of: key) { return index }
        let aliases: [String: String] = ["+": "plus", "-": "minus", "−": "minus", "in+": "plus", "in-": "minus",
                                          "output": "out", "input": "in", "g": "gate", "d": "drain", "s": "source",
                                          "b": "base", "c": "collector", "e": "emitter", "anode": "a", "cathode": "b",
                                          "a": "anode", "k": "cathode", "iabc": "bias", "rst": "reset", "threshold": "thr",
                                          "trigger": "trig", "discharge": "dis", "control": "ctrl"]
        if let alias = aliases[key], let index = names.firstIndex(of: alias) { return index }
        if let number = Int(key), number >= 1, number <= names.count { return number - 1 }
        return nil
    }

    /// The element for `part` placed in the cell at `origin`, with its terminals pointing outwards
    public static func element(for part: NetlistPart, at origin: GridPoint) -> Element {
        func p(_ x: Int, _ y: Int) -> GridPoint { origin + GridPoint(x, y) }
        let (a, b): (GridPoint, GridPoint)
        switch part.kind {
        case .nmos, .pmos, .npn, .pnp, .njfet: (a, b) = (p(4, 4), p(6, 4))
        case .potentiometer, .analogSwitch: (a, b) = (p(3, 5), p(7, 5))
        case .timer555: (a, b) = (p(6, 2), p(6, 7))
        case .ground: (a, b) = (p(5, 4), p(5, 5))
        case .netLabel: (a, b) = (p(5, 4), p(6, 4))
        default: (a, b) = (p(3, 4), p(7, 4))
        }
        var params = part.params
        for spec in part.kind.params where params[spec.key] == nil { params[spec.key] = spec.defaultValue }
        return Element(kind: part.kind, name: part.name, a: a, b: b, params: params, flipped: part.flipped)
    }

    /// Adds `parts` to `circuit`, one per cell from cell `firstCell` on. Returns the new parts' ids.
    @discardableResult
    public static func add(_ parts: [NetlistPart], to circuit: inout Circuit, firstCell: Int) throws -> [UUID] {
        var ids: [UUID] = []
        var names = Set(circuit.elements.map(\.name))
        for (offset, part) in parts.enumerated() {
            if !part.name.isEmpty {
                guard !names.contains(part.name) else { throw NetlistError.duplicateName(part.name) }
                names.insert(part.name)
            }
            var element = element(for: part, at: cellOrigin(firstCell + offset))
            if element.name.isEmpty, element.kind != .wire, element.kind != .ground {
                element.name = circuit.uniqueName(for: element.kind)
                names.insert(element.name)
            }
            // check every terminal before adding anything
            var leads: [(post: GridPoint, net: String)] = []
            for (terminal, net) in part.connections.sorted(by: { $0.key < $1.key }) {
                guard let index = terminalIndex(terminal, of: part.kind) else {
                    throw NetlistError.unknownTerminal(part: element.name, terminal: terminal, valid: part.kind.terminalNames)
                }
                let net = net.trimmingCharacters(in: .whitespaces)
                guard !net.isEmpty else { continue }
                leads.append((element.posts[index], net))
            }
            circuit.elements.append(element)
            ids.append(element.id)
            // a lead outwards from the part's middle, one unit long, ending in the net's label
            let middleX = Double(element.a.x + element.b.x) / 2
            let middleY = Double(element.a.y + element.b.y) / 2
            for (post, net) in leads {
                let dx = Double(post.x) - middleX
                let dy = Double(post.y) - middleY
                let direction = abs(dx) >= abs(dy) ? GridPoint(dx >= 0 ? 1 : -1, 0) : GridPoint(0, dy >= 0 ? 1 : -1)
                let end = post + direction
                circuit.elements.append(Element(kind: .wire, a: post, b: end))
                if Topology.isGroundName(net) {
                    circuit.elements.append(Element(kind: .ground, a: end, b: end + GridPoint(0, 1)))
                } else {
                    circuit.elements.append(Element(kind: .netLabel, name: net, a: end, b: end + direction))
                }
            }
        }
        return ids
    }

    /// The net names in the circuit: every net label's name
    public static func netNames(in circuit: Circuit) -> [String] {
        Array(Set(circuit.elements.filter { $0.kind == .netLabel && !$0.name.isEmpty }.map(\.name))).sorted()
    }
}
