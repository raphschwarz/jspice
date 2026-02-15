import Foundation

// MARK: - MNA Solver

/// Modified Nodal Analysis solver — the core of the SPICE simulation engine.
///
/// Implements the standard MNA formulation:
/// ```
/// [G  B] [v]   [i]
/// [C  D] [j] = [e]
/// ```
/// Where G is the conductance matrix, v are node voltages,
/// j are branch currents through voltage sources, i and e are excitation vectors.
///
/// References: JSpice CircuitMatrixSolver.java, Cheng "The MNA approach to linear circuits"
actor MNASolver {

    // MARK: - Configuration

    var maxIterations: Int = 100
    var convergenceTolerance: Double = 1e-9
    var dampingFactor: Double = 0.5  // Newton-Raphson damping (0 = no damping, 1 = full damping)

    // MARK: - Build the system from a netlist

    struct Netlist {
        var components: [MNAComponent]
        var groundNodeName: String = "0"
    }

    // MARK: - Errors

    enum SolverError: Error, CustomStringConvertible {
        case convergenceFailed(iterations: Int, residual: Double)
        case emptyNetlist
        case noNodes

        var description: String {
            switch self {
            case .convergenceFailed(let iters, let residual):
                return "Newton-Raphson failed to converge after \(iters) iterations (residual: \(String(format: "%.2e", residual)))"
            case .emptyNetlist:
                return "Netlist contains no components"
            case .noNodes:
                return "No circuit nodes found"
            }
        }
    }

    func solve(netlist: Netlist) throws -> MNASolution {
        guard !netlist.components.isEmpty else {
            throw SolverError.emptyNetlist
        }

        // 1. Map nodes (using local state, not instance properties)
        let (nodeMap, voltageSourceMap, groundNode) = buildNodeMap(from: netlist)

        // 2. Compute matrix size
        let matrixSize = nodeMap.count + voltageSourceMap.count
        guard matrixSize > 0 else {
            throw SolverError.noNodes
        }

        // 3. Check for nonlinear components
        let hasNonlinear = netlist.components.contains { $0.isNonlinear }

        if hasNonlinear {
            return try solveNonlinear(
                netlist: netlist,
                nodeMap: nodeMap,
                vsMap: voltageSourceMap,
                groundNode: groundNode,
                matrixSize: matrixSize
            )
        } else {
            return try solveLinear(
                netlist: netlist,
                nodeMap: nodeMap,
                vsMap: voltageSourceMap,
                groundNode: groundNode,
                matrixSize: matrixSize
            )
        }
    }

    // MARK: - Linear solve

    private func solveLinear(
        netlist: Netlist,
        nodeMap: [String: Int],
        vsMap: [String: Int],
        groundNode: String,
        matrixSize: Int
    ) throws -> MNASolution {
        var matrix = Matrix(rows: matrixSize, cols: matrixSize)
        var rhs = Vector(count: matrixSize)
        let initialGuess = Vector(count: matrixSize)

        for component in netlist.components {
            component.stamp(
                matrix: &matrix,
                rhs: &rhs,
                solution: initialGuess,
                nodeMap: nodeMap,
                vsMap: vsMap
            )
        }

        let solution = try solveLinearSystem(A: matrix, b: rhs)
        return buildSolution(from: solution, nodeMap: nodeMap, vsMap: vsMap, groundNode: groundNode)
    }

    // MARK: - Nonlinear solve (Newton-Raphson with damping)

    private func solveNonlinear(
        netlist: Netlist,
        nodeMap: [String: Int],
        vsMap: [String: Int],
        groundNode: String,
        matrixSize: Int
    ) throws -> MNASolution {
        var solution = Vector(count: matrixSize)
        var lastResidual: Double = .infinity

        for iteration in 0..<maxIterations {
            var matrix = Matrix(rows: matrixSize, cols: matrixSize)
            var rhs = Vector(count: matrixSize)

            // Stamp with current solution as linearization point
            for component in netlist.components {
                component.stamp(
                    matrix: &matrix,
                    rhs: &rhs,
                    solution: solution,
                    nodeMap: nodeMap,
                    vsMap: vsMap
                )
            }

            // Solve for new solution
            let newSolution = try solveLinearSystem(A: matrix, b: rhs)

            // Check convergence
            let diff = newSolution.difference(from: solution)
            let maxDiff = diff.maxNorm

            // Apply damping to improve convergence for nonlinear circuits
            // Damped Newton: x(k+1) = x(k) + alpha * (x_new - x(k))
            let alpha = 1.0 - dampingFactor * min(1.0, maxDiff / max(lastResidual, 1e-30))
            for i in 0..<solution.count {
                solution[i] = solution[i] + alpha * (newSolution[i] - solution[i])
            }

            lastResidual = maxDiff

            if maxDiff < convergenceTolerance {
                return buildSolution(from: solution, nodeMap: nodeMap, vsMap: vsMap, groundNode: groundNode)
            }
        }

        // Throw convergence error instead of silently returning bad results
        throw SolverError.convergenceFailed(iterations: maxIterations, residual: lastResidual)
    }

    // MARK: - Node mapping (pure function, no instance state mutation)

    private func buildNodeMap(from netlist: Netlist) -> (nodeMap: [String: Int], vsMap: [String: Int], ground: String) {
        let groundNode = netlist.groundNodeName

        var nodeNames = Set<String>()
        var vsNames: [String] = []

        // First pass: collect all node names and voltage source names
        for component in netlist.components {
            for node in component.nodes {
                if node != groundNode && node != "gnd" && node != "GND" {
                    nodeNames.insert(node)
                }
            }
            if component.requiresExtraEquation {
                vsNames.append(component.name)
            }
        }

        // Assign node indices (ground is implicit reference)
        var nodeMap: [String: Int] = [:]
        for (index, name) in nodeNames.sorted().enumerated() {
            nodeMap[name] = index
        }

        // Assign voltage source indices (after node indices)
        let nodeCount = nodeMap.count
        var vsMap: [String: Int] = [:]
        for (index, name) in vsNames.sorted().enumerated() {
            vsMap[name] = nodeCount + index
        }

        return (nodeMap, vsMap, groundNode)
    }

    // MARK: - Build solution

    private func buildSolution(
        from solution: Vector,
        nodeMap: [String: Int],
        vsMap: [String: Int],
        groundNode: String
    ) -> MNASolution {
        var voltages: [String: Double] = [:]
        var currents: [String: Double] = [:]

        // Ground is always 0V
        voltages[groundNode] = 0.0

        for (name, index) in nodeMap {
            voltages[name] = solution[index]
        }

        for (name, index) in vsMap {
            currents[name] = solution[index]
        }

        return MNASolution(nodeVoltages: voltages, branchCurrents: currents)
    }
}

// MARK: - MNA Solution

struct MNASolution: Sendable {
    let nodeVoltages: [String: Double]
    let branchCurrents: [String: Double]

    func voltage(at node: String) -> Double {
        nodeVoltages[node] ?? 0
    }

    func voltageDifference(from nodeA: String, to nodeB: String) -> Double {
        voltage(at: nodeA) - voltage(at: nodeB)
    }
}

// MARK: - MNA Component Protocol

/// Protocol for components that can be stamped into the MNA matrix
protocol MNAComponent {
    var name: String { get }
    var nodes: [String] { get }
    var isNonlinear: Bool { get }
    var requiresExtraEquation: Bool { get }

    func stamp(
        matrix: inout Matrix,
        rhs: inout Vector,
        solution: Vector,
        nodeMap: [String: Int],
        vsMap: [String: Int]
    )
}

extension MNAComponent {
    /// Helper to get matrix index for a node (nil for ground)
    func nodeIndex(_ node: String, nodeMap: [String: Int]) -> Int? {
        if node == "0" || node == "gnd" || node == "GND" { return nil }
        return nodeMap[node]
    }

    /// Stamp a conductance between two nodes
    func stampConductance(
        _ conductance: Double,
        node1: String,
        node2: String,
        matrix: inout Matrix,
        nodeMap: [String: Int]
    ) {
        let i = nodeIndex(node1, nodeMap: nodeMap)
        let j = nodeIndex(node2, nodeMap: nodeMap)

        if let i = i { matrix[i, i] += conductance }
        if let j = j { matrix[j, j] += conductance }
        if let i = i, let j = j {
            matrix[i, j] -= conductance
            matrix[j, i] -= conductance
        }
    }

    /// Stamp a current source between two nodes
    /// Convention: positive current flows from fromNode to toNode
    func stampCurrentSource(
        _ current: Double,
        fromNode: String,
        toNode: String,
        rhs: inout Vector,
        nodeMap: [String: Int]
    ) {
        let i = nodeIndex(fromNode, nodeMap: nodeMap)
        let j = nodeIndex(toNode, nodeMap: nodeMap)

        if let i = i { rhs[i] -= current }
        if let j = j { rhs[j] += current }
    }
}
