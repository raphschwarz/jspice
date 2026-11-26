import Foundation

/// Something the simulator has to say about the circuit: what is wrong, how sure it is that it matters, what to do,
/// and which parts it is about, so the app can point at them.
public struct Diagnostic: Hashable, Sendable, Identifiable {
    public enum Severity: String, Sendable, Comparable {
        /// The circuit, or a part of it, does not work as drawn: the simulation failed, or a part is left out of it
        case error
        /// It runs, but something is probably not what was meant, or the results may be wrong
        case warning
        /// Worth knowing, but not a fault
        case note

        private var rank: Int {
            switch self {
            case .error: return 0
            case .warning: return 1
            case .note: return 2
            }
        }

        /// Errors first, then warnings, then notes
        public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
    }

    public var severity: Severity
    /// One sentence saying what is wrong, naming the part(s) as the user sees them
    public var message: String
    /// What to do about it, when there is something specific to say
    public var hint: String?
    /// The parts it is about, as ids of elements in the DRAWN circuit (`Simulator.circuit`), so the app can select
    /// them: a part inside a block is reported as its block part's id
    public var elements: [UUID]
    /// Stable while the same problem persists from frame to frame (e.g. a kind plus the element ids), for SwiftUI
    public var id: String

    public init(severity: Severity, message: String, hint: String? = nil, elements: [UUID] = [], id: String) {
        self.severity = severity
        self.message = message
        self.hint = hint
        self.elements = elements
        self.id = id
    }

    /// A diagnostic whose id is its kind and the parts it is about
    init(_ severity: Severity, _ kind: String, _ message: String, hint: String? = nil, elements: [UUID]) {
        self.init(severity: severity, message: message, hint: hint, elements: elements,
                  id: ([kind] + elements.map(\.uuidString)).joined(separator: ":"))
    }

    /// Errors first, then warnings, then notes, each kept in the order given
    static func ordered(_ list: [Diagnostic]) -> [Diagnostic] {
        guard list.count > 1 else { return list }
        return list.enumerated().sorted { ($0.element.severity, $0.offset) < ($1.element.severity, $1.offset) }.map(\.element)
    }
}

/// How the parts of a circuit (flattened) hang together, for the warnings found at load: no ground, parts with no DC
/// path to ground, terminals connected to nothing. Each part is taken by its kind alone (an open switch counts as
/// closed, so that what it leaves floating while open is not warned of), and a part whose equations reach ground of
/// themselves (a chip, an op-amp's output, a synth module, anything not listed in `Link`) ties its nodes to ground:
/// these warnings are only given where they are sure.
struct ConnectivityCheck {
    /// A part found in a problem: its index in the flattened circuit
    struct Finding {
        enum Kind { case noGround, floating, coupledOnly, unconnected, dangling }
        var kind: Kind
        /// The part named, then any others it concerns
        var parts: [Int]
        /// For `noGround`, the reference's post on the first part; for `dangling`, the terminals connected to nothing
        var terminals: [Int] = []
    }

    /// How a part joins its nodes
    enum Link {
        /// Not a part (a wire, a label, a probe: already merged into nodes, or not in the equations)
        case none
        /// Its nodes are joined to ground through its own equations
        case ground
        /// Groups of its posts joined by a DC path (internal nodes go with the first group); the rest of its posts
        /// are reached only by AC (a capacitor's plates, a MOSFET's gate)
        case groups([[Int]])
    }

    static func link(_ element: Element, kind: ElementKind) -> Link {
        let all = [Array(0..<element.posts.count)]
        switch kind {
        case .wire, .ground, .netLabel, .probe, .ammeter, .block, .port, .loopProbe:
            return .none
        case .resistor, .potentiometer, .lamp, .inductor, .memristor, .speaker,
             .dcVoltage, .acVoltage, .squareVoltage, .noiseVoltage, .audioInput, .keyboardPitch, .keyboardGate,
             .toggleSwitch, .pushButton, .footswitch, .jack,
             .diode, .zener, .led, .npn, .pnp, .njfet, .pjfet, .triode, .pentode:
            return .groups(all)
        case .nmos, .pmos:
            // (the gate is insulated from the channel)
            return .groups([[1, 2], [0]])
        case .capacitor, .currentSource:
            return .groups([])
        case .vactrol:
            // an LED lighting a resistor, with nothing between the two
            return .groups([[0, 1], [2, 3]])
        case .transformer:
            // an ideal core: each winding a path of its own (a transformer of the drawing is simulated as its parts,
            // which are in the circuit after it)
            return element[param: "core"] != 0 ? .groups([[0, 1], [2, 3]]) : .none
        default:
            return .ground
        }
    }

    /// Kinds whose terminals each have to reach something for the part to do anything: one connected to nothing is a
    /// mistake (a potentiometer's spare end, a chip's spare pin, a switch's spare throw are not, nor a supply drawn
    /// with one end free: chips and op-amps take their supply of themselves, and examples draw it to show where it
    /// comes from)
    static let needsEveryTerminal: Set<ElementKind> = [
        .resistor, .capacitor, .inductor, .lamp, .memristor, .diode, .zener, .led,
        .currentSource, .npn, .pnp, .nmos, .pmos, .njfet, .pjfet,
    ]

    /// Parts that count as something on a node (not wires, labels, probes or ground)
    static func isPart(_ kind: ElementKind) -> Bool {
        ![.wire, .ground, .netLabel, .probe, .ammeter, .port].contains(kind)
    }

    var findings: [Finding] = []
    /// Current sources whose current has no DC path from one of their terminals round to the other (any part of the
    /// flattened circuit): a cause of equations that cannot be solved
    var strandedCurrentSources: [Int] = []

    /// `drawn`: how many of the flattened circuit's parts are the drawing's own (they come first); only they are
    /// warned of, a block's insides and a model's parts being the business of whoever made them
    init(flat: Circuit, kinds: [ElementKind], topology: Topology, drawn: Int) {
        let n = topology.nodeCount
        guard n > 1 || !topology.hasGround else { return }
        let elements = flat.elements
        var dc = UnionFind(count: n)
        var any = UnionFind(count: n)
        // terminals of parts on each node
        var uses = [Int](repeating: 0, count: n)
        for i in elements.indices where i < kinds.count && i < topology.elementNodes.count {
            let nodes = topology.elementNodes[i]
            let posts = elements[i].posts.count
            if Self.isPart(kinds[i]) {
                for k in 0..<min(posts, nodes.count) { uses[nodes[k]] += 1 }
            }
            switch Self.link(elements[i], kind: kinds[i]) {
            case .none:
                continue
            case .ground:
                for node in nodes {
                    dc.union(0, node)
                    any.union(0, node)
                }
            case .groups(let groups):
                for node in nodes { any.union(nodes[0], node) }
                for (g, group) in groups.enumerated() {
                    var members = group.filter { $0 < nodes.count }.map { nodes[$0] }
                    if g == 0 && nodes.count > posts { members += nodes[posts...] }
                    for node in members.dropFirst() { dc.union(members[0], node) }
                }
            }
        }

        // current sources with no DC path from one terminal round to the other
        for i in elements.indices where i < kinds.count && kinds[i] == .currentSource && topology.elementNodes[i].count >= 2 {
            let nodes = topology.elementNodes[i]
            if dc.find(nodes[0]) != dc.find(nodes[1]) { strandedCurrentSources.append(i) }
        }

        // no ground: the reference the topology took, by a part on it
        if !topology.hasGround, let reference = topology.reference {
            var found: (part: Int, post: Int)?
            for i in elements.indices where i < drawn && Self.isPart(kinds[i]) {
                if let k = topology.elementPoints[i].firstIndex(of: reference) {
                    found = (i, k)
                    break
                }
            }
            if found == nil {
                let node = topology.nodeOfPoint[reference]
                for i in elements.indices where i < drawn && Self.isPart(kinds[i]) {
                    if let k = topology.elementNodes[i].prefix(elements[i].posts.count).firstIndex(of: node) {
                        found = (i, k)
                        break
                    }
                }
            }
            if let found { findings.append(Finding(kind: .noGround, parts: [found.part], terminals: [found.post])) }
        }

        // terminals connected to nothing
        var unconnectedParts = Set<Int>()
        var danglingNodes = Set<Int>()
        for i in 0..<min(drawn, elements.count) where Self.needsEveryTerminal.contains(kinds[i]) {
            let nodes = topology.elementNodes[i]
            let open = (0..<min(elements[i].posts.count, nodes.count)).filter { nodes[$0] != 0 && uses[nodes[$0]] == 1 }
            guard !open.isEmpty else { continue }
            for k in open { danglingNodes.insert(nodes[k]) }
            if open.count == elements[i].posts.count {
                unconnectedParts.insert(i)
                findings.append(Finding(kind: .unconnected, parts: [i]))
            } else {
                findings.append(Finding(kind: .dangling, parts: [i], terminals: open))
            }
        }

        // islands with no DC path to ground: named by a part of the drawing's on them
        let groundDC = dc.find(0), groundAny = any.find(0)
        var islands: [Int: (parts: [Int], nodes: Set<Int>, coupled: Bool)] = [:]
        var order: [Int] = []
        for i in elements.indices where i < kinds.count && i < topology.elementNodes.count && Self.isPart(kinds[i]) {
            if case .none = Self.link(elements[i], kind: kinds[i]) { continue }
            let nodes = topology.elementNodes[i].prefix(elements[i].posts.count)
            for node in nodes where node != 0 {
                let root = dc.find(node)
                guard root != groundDC else { continue }
                if islands[root] == nil {
                    islands[root] = ([], [], any.find(node) == groundAny)
                    order.append(root)
                }
                islands[root]!.nodes.insert(node)
                if islands[root]!.parts.last != i { islands[root]!.parts.append(i) }
            }
        }
        for root in order {
            guard let island = islands[root] else { continue }
            let drawnParts = island.parts.filter { $0 < drawn && kinds[$0] != .block && !kinds[$0].isMicrocontroller }
            guard let named = drawnParts.first else { continue }
            // (already said: a part connected to nothing, or the open end of one)
            if island.nodes.isSubset(of: danglingNodes) || drawnParts.allSatisfy({ unconnectedParts.contains($0) }) { continue }
            var parts = drawnParts
            parts.removeAll { $0 == named }
            findings.append(Finding(kind: island.coupled ? .coupledOnly : .floating, parts: [named] + parts))
        }
    }

    /// Voltage sources (and outputs that act as them) that make a loop with wires: each loop's sources, or two
    /// sources in parallel. Two sources across the same nodes, or a ring of them, leave the currents around it
    /// undetermined and the voltages contradictory: the equations have no single solution.
    static func sourceLoops(kinds: [ElementKind], topology: Topology) -> [[Int]] {
        let n = topology.nodeCount
        var forest = UnionFind(count: n)
        var adjacency = [[(node: Int, element: Int)]](repeating: [], count: n)
        var loops: [[Int]] = []
        for i in kinds.indices where i < topology.sourceRow.count && topology.sourceRow[i] >= 0 && kinds[i].isVoltageSource {
            let nodes = topology.elementNodes[i]
            guard nodes.count >= 2 else { continue }
            let (a, b) = (nodes[0], nodes[1])
            if forest.find(a) == forest.find(b) {
                // the path from a to b through the sources found so far, and this one
                var previous: [Int: (node: Int, element: Int)] = [a: (a, -1)]
                var queue = [a], head = 0
                while head < queue.count, previous[b] == nil {
                    let node = queue[head]
                    head += 1
                    for edge in adjacency[node] where previous[edge.node] == nil {
                        previous[edge.node] = (node, edge.element)
                        queue.append(edge.node)
                    }
                }
                var loop = [i], node = b
                while node != a, let step = previous[node], step.element >= 0 {
                    loop.append(step.element)
                    node = step.node
                }
                loops.append(loop.sorted())
                if loops.count >= 4 { break }
                continue
            }
            forest.union(a, b)
            adjacency[a].append((b, i))
            adjacency[b].append((a, i))
        }
        return loops
    }

    /// A terminal, as a sentence names it: "the − terminal", "the base", "one end"
    static func terminalPhrase(_ element: Element, _ post: Int) -> String {
        let names = element.terminalNames
        guard post < names.count else { return "a terminal" }
        switch names[post] {
        case "minus": return "the − terminal"
        case "plus": return "the + terminal"
        case "a", "b": return element.posts.count == 2 ? "one end" : "terminal \(names[post])"
        case let name: return "the " + name
        }
    }
}

extension Array where Element == String {
    /// "A", "A and B", "A, B and C"
    var listed: String {
        switch count {
        case 0: return ""
        case 1: return self[0]
        default: return dropLast().joined(separator: ", ") + " and " + last!
        }
    }
}
