import Foundation

private struct UnionFind {
    var parent: [Int]

    init(count: Int) { parent = Array(0..<count) }

    mutating func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        var node = x
        while parent[node] != root {
            let next = parent[node]
            parent[node] = root
            node = next
        }
        return root
    }

    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a)
        let rb = find(b)
        if ra != rb { parent[rb] = ra }
    }
}

/// One step of computing wire currents: the wire `element` carries everything that flowed into point `from` on to point `to`.
struct FlowStep {
    let element: Int
    let from: Int
    let to: Int
}

/// How the drawn circuit maps onto the equations: which terminals form the same node, where each voltage source's current
/// unknown lives, and in which order wire currents can be recovered.
///
/// Wires and closed switches are ideal conductors, so their ends are merged into one node and they do not appear in the
/// equations. Their currents, needed to animate them, are recovered afterwards from Kirchhoff's current law by peeling the
/// wire network like a tree from its leaves.
struct Topology {
    /// Every terminal position, indexed
    var points: [GridPoint] = []
    var pointIndex: [GridPoint: Int] = [:]
    /// Node of each point; node 0 is ground
    var nodeOfPoint: [Int] = []
    var nodeCount = 1
    /// Per element, the node of each of its posts, then of its internal nodes
    var elementNodes: [[Int]] = []
    /// Per element, the point index of each of its posts
    var elementPoints: [[Int]] = []
    /// Per element, the matrix row of its current unknown (voltage sources), or -1
    var sourceRow: [Int] = []
    var matrixSize = 0
    var flowOrder: [FlowStep] = []
    var isGroundPoint: [Bool] = []
    var problems: [String] = []
    var shorted: Set<Int> = []

    init() {}

    init(circuit: Circuit) {
        let elements = circuit.elements
        for element in elements {
            for post in element.posts where pointIndex[post] == nil {
                pointIndex[post] = points.count
                points.append(post)
            }
        }
        elementPoints = elements.map { $0.posts.map { pointIndex[$0]! } }
        isGroundPoint = Array(repeating: false, count: points.count)

        // nodes: conductors merge their ends, grounds merge into the ground sentinel
        let groundSentinel = points.count
        var nodes = UnionFind(count: points.count + 1)
        var hasGround = false
        // net labels with the same name are one node; "GND" or "0" is ground
        var labels: [String: Int] = [:]
        for (i, element) in elements.enumerated() {
            let joined = element.joinedTerminals
            if !joined.isEmpty {
                for (p, q) in joined where p < elementPoints[i].count && q < elementPoints[i].count {
                    nodes.union(elementPoints[i][p], elementPoints[i][q])
                }
            } else if element.kind == .ground || (element.kind == .netLabel && Self.isGroundName(element.name)) {
                nodes.union(groundSentinel, elementPoints[i][0])
                isGroundPoint[elementPoints[i][0]] = true
                hasGround = true
            } else if element.kind == .netLabel {
                let name = element.name.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                if let first = labels[name] {
                    nodes.union(first, elementPoints[i][0])
                } else {
                    labels[name] = elementPoints[i][0]
                }
            }
        }
        if !hasGround, !points.isEmpty {
            // no ground symbol: use the negative terminal of the first source, or else any terminal, as the reference
            let reference = elements.firstIndex { $0.kind.isVoltageSource }
                .map { elementPoints[$0][0] } ?? 0
            nodes.union(groundSentinel, reference)
        }

        let groundRoot = nodes.find(groundSentinel)
        var nodeOfRoot: [Int: Int] = [groundRoot: 0]
        nodeOfPoint = points.indices.map { p in
            let root = nodes.find(p)
            if let node = nodeOfRoot[root] { return node }
            let node = nodeOfRoot.count
            nodeOfRoot[root] = node
            return node
        }
        nodeCount = nodeOfRoot.count
        elementNodes = elementPoints.map { $0.map { nodeOfPoint[$0] } }
        // parts' nodes of their own (a transistor's internal base, collector and emitter behind its resistances), after
        // the drawn ones and on no point: they follow its terminals in its nodes
        for (i, element) in elements.enumerated() {
            for _ in 0..<element.internalNodeCount {
                elementNodes[i].append(nodeCount)
                nodeCount += 1
            }
        }

        // voltage sources and op-amp outputs get a current unknown, unless they are shorted out
        sourceRow = Array(repeating: -1, count: elements.count)
        var row = nodeCount - 1
        for (i, element) in elements.enumerated()
        where element.kind.isVoltageSource || element.kind.drivesOutput || element.isTransformerCore || element.setsBehavioralVoltage {
            let name = element.name.isEmpty ? element.kind.displayName : element.name
            if element.isTransformerCore {
                // an ideal transformer with both windings shorted would leave its current undetermined
                let n = elementNodes[i]
                if n.count < 4 || (n[0] == n[1] && n[2] == n[3]) {
                    shorted.insert(i)
                    continue
                }
            } else if element.kind.drivesOutput {
                if elementNodes[i][2] == 0 {
                    shorted.insert(i)
                    problems.append("The output of \(name) is connected straight to ground.")
                    continue
                }
            } else if elementNodes[i][0] == elementNodes[i][1] {
                shorted.insert(i)
                problems.append("\(name) is short-circuited.")
                continue
            }
            sourceRow[i] = row
            row += 1
        }
        matrixSize = row

        buildFlowOrder(elements)
    }

    static func isGroundName(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces).lowercased()
        return name == "gnd" || name == "0" || name == "ground"
    }

    /// Spanning forest of the conductors, rooted at a ground point where there is one. Conductors that close a loop of
    /// conductors carry no current in this model, since the split around such a loop is not determined.
    private mutating func buildFlowOrder(_ elements: [Element]) {
        var forest = UnionFind(count: points.count)
        var adjacency = [[(point: Int, element: Int)]](repeating: [], count: points.count)
        for (i, element) in elements.enumerated() {
            for (a, b) in element.joinedTerminals where a < elementPoints[i].count && b < elementPoints[i].count {
                let p = elementPoints[i][a]
                let q = elementPoints[i][b]
                if forest.find(p) == forest.find(q) { continue }
                forest.union(p, q)
                adjacency[p].append((q, i))
                adjacency[q].append((p, i))
            }
        }

        var visited = [Bool](repeating: false, count: points.count)
        let roots = points.indices.filter { isGroundPoint[$0] } + points.indices.filter { !isGroundPoint[$0] }
        for root in roots where !visited[root] && !adjacency[root].isEmpty {
            // breadth-first from the root; recording each point's link to its parent
            var order: [FlowStep] = []
            var queue = [root]
            visited[root] = true
            var head = 0
            while head < queue.count {
                let point = queue[head]
                head += 1
                for (neighbour, element) in adjacency[point] where !visited[neighbour] {
                    visited[neighbour] = true
                    queue.append(neighbour)
                    order.append(FlowStep(element: element, from: neighbour, to: point))
                }
            }
            // leaves first
            flowOrder.append(contentsOf: order.reversed())
        }
    }
}
