import Foundation

/// A part described by its connections rather than its position: which net each terminal joins.
public struct NetlistPart: Sendable {
    public var kind: ElementKind
    public var name: String
    public var params: [String: Double]
    public var flipped: Bool
    /// Terminal name (see `ElementKind.terminalNames`) or 1-based terminal number, to net name. "GND" or "0" is ground.
    public var connections: [String: String]
    /// Switch state
    public var closed: Bool
    /// Keeps the part's identity (and its scopes) when a circuit is redrawn
    public var id: UUID?
    /// A microcontroller's sketch and firmware
    public var code: String?
    public var firmware: Data?

    public init(kind: ElementKind, name: String = "", params: [String: Double] = [:], flipped: Bool = false,
                connections: [String: String] = [:], closed: Bool = false, id: UUID? = nil) {
        self.kind = kind
        self.name = name
        self.params = params
        self.flipped = flipped
        self.connections = connections
        self.closed = closed
        self.id = id
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

/// Reads the netlist back out of a drawn circuit: every part with the net each terminal is on. Nets are named after
/// their net labels, else after the names they were given when the circuit was built from a netlist (`netNames`), else
/// numbered; the ground net is "GND". Terminals connected to nothing are left out.
public enum NetlistExtractor {
    public static func netlist(from circuit: Circuit) -> [NetlistPart] {
        let simulator = Simulator(circuit: circuit, timeStep: 1e-6)
        let isPart: (Element) -> Bool = { ![.wire, .ground, .netLabel].contains($0.kind) }
        var names: [Int: String] = [0: "GND"]
        var taken: Set<String> = ["GND"]
        func name(_ node: Int, _ candidate: String) {
            guard names[node] == nil, !candidate.isEmpty, !taken.contains(candidate) else { return }
            if Topology.isGroundName(candidate) { return }
            names[node] = candidate
            taken.insert(candidate)
        }
        for (i, element) in circuit.elements.enumerated() where element.kind == .netLabel {
            if let node = simulator.nodes(of: i).first { name(node, element.name.trimmingCharacters(in: .whitespaces)) }
        }
        var terminalsOnNode: [Int: Int] = [:]
        for (i, element) in circuit.elements.enumerated() where isPart(element) {
            for (t, node) in simulator.nodes(of: i).enumerated() {
                terminalsOnNode[node, default: 0] += 1
                if let given = circuit.netNames["\(element.name).\(element.kind.terminalNames[t])"] { name(node, given) }
            }
        }
        // supplies without a name are named after their voltage, like "+9V"
        for (i, element) in circuit.elements.enumerated() where element.kind == .dcVoltage {
            let nodes = simulator.nodes(of: i)
            guard nodes.count == 2 else { continue }
            let volts = element[param: "voltage"]
            let size = SI.trimmed(abs(volts), digits: 3)
            if nodes[0] == 0 && nodes[1] != 0 {
                name(nodes[1], (volts >= 0 ? "+" : "-") + size + "V")
            } else if nodes[1] == 0 && nodes[0] != 0 {
                name(nodes[0], (volts >= 0 ? "-" : "+") + size + "V")
            }
        }
        let labelled = Set(circuit.elements.enumerated().filter { $0.element.kind == .netLabel || $0.element.kind == .ground }
            .compactMap { simulator.nodes(of: $0.offset).first })
        var counter = 1
        var parts: [NetlistPart] = []
        for (i, element) in circuit.elements.enumerated() where isPart(element) {
            var connections: [String: String] = [:]
            for (t, node) in simulator.nodes(of: i).enumerated() {
                // a terminal alone on its node is not connected to anything
                if node != 0 && (terminalsOnNode[node] ?? 0) < 2 && names[node] == nil && !labelled.contains(node) { continue }
                if names[node] == nil {
                    while taken.contains("N\(counter)") { counter += 1 }
                    name(node, "N\(counter)")
                }
                connections[element.kind.terminalNames[t]] = names[node]
            }
            var part = NetlistPart(kind: element.kind, name: element.name, params: element.params, flipped: element.flipped,
                                   connections: connections, closed: element.closed, id: element.id)
            part.code = element.code
            part.firmware = element.firmware
            parts.append(part)
        }
        return parts
    }
}
