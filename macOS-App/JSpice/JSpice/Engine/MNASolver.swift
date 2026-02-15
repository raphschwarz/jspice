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
    // MARK: - Node Mapping

    private var nodeMap: [String: Int] = [:]  // node name -> matrix index
    private var voltageSourceMap: [String: Int] = [:]  // VS name -> extra row index
    private var groundNode: String = "0"

    // MARK: - System

    private var matrixSize: Int = 0
    private var matrix: Matrix = Matrix(rows: 0, cols: 0)
    private var rhs: Vector = Vector(count: 0)

    // MARK: - Configuration

    var maxIterations: Int = 100
    var convergenceTolerance: Double = 1e-9

    // MARK: - Build the system from a netlist

    struct Netlist {
        var components: [MNAComponent]
        var groundNodeName: String = "0"
    }

    func solve(netlist: Netlist) throws -> MNASolution {
        // 1. Map nodes
        buildNodeMap(from: netlist)

        // 2. Allocate matrix
        matrixSize = nodeMap.count + voltageSourceMap.count
        matrix = Matrix(rows: matrixSize, cols: matrixSize)
        rhs = Vector(count: matrixSize)

        // 3. Check for nonlinear components
        let hasNonlinear = netlist.components.contains { $0.isNonlinear }

        if hasNonlinear {
            return try solveNonlinear(netlist: netlist)
        } else {
            return try solveLinear(netlist: netlist)
        }
    }

    // MARK: - Linear solve

    private func solveLinear(netlist: Netlist) throws -> MNASolution {
        matrix.reset()
        rhs.reset()

        // Stamp all components
        var mutableMatrix = matrix
        var mutableRHS = rhs
        let initialGuess = Vector(count: matrixSize)

        for component in netlist.components {
            component.stamp(
                matrix: &mutableMatrix,
                rhs: &mutableRHS,
                solution: initialGuess,
                nodeMap: nodeMap,
                vsMap: voltageSourceMap
            )
        }

        // Solve Ax = b
        let solution = try solveLinearSystem(A: mutableMatrix, b: mutableRHS)
        return buildSolution(from: solution)
    }

    // MARK: - Nonlinear solve (Newton-Raphson iteration)

    private func solveNonlinear(netlist: Netlist) throws -> MNASolution {
        var solution = Vector(count: matrixSize)

        for iteration in 0..<maxIterations {
            // Reset system
            var mutableMatrix = Matrix(rows: matrixSize, cols: matrixSize)
            var mutableRHS = Vector(count: matrixSize)

            // Stamp with current solution as linearization point
            for component in netlist.components {
                component.stamp(
                    matrix: &mutableMatrix,
                    rhs: &mutableRHS,
                    solution: solution,
                    nodeMap: nodeMap,
                    vsMap: voltageSourceMap
                )
            }

            // Solve for new solution
            let newSolution = try solveLinearSystem(A: mutableMatrix, b: mutableRHS)

            // Check convergence
            let diff = newSolution.difference(from: solution)
            let maxDiff = diff.maxNorm

            solution = newSolution

            if maxDiff < convergenceTolerance {
                return buildSolution(from: solution)
            }
        }

        // Return best solution even if not fully converged
        return buildSolution(from: solution)
    }

    // MARK: - Node mapping

    private func buildNodeMap(from netlist: Netlist) {
        groundNode = netlist.groundNodeName
        nodeMap.removeAll()
        voltageSourceMap.removeAll()

        var nodeNames = Set<String>()
        var vsCount = 0

        for component in netlist.components {
            for node in component.nodes {
                if node != groundNode {
                    nodeNames.insert(node)
                }
            }
            if component.requiresExtraEquation {
                voltageSourceMap[component.name] = nodeNames.count + vsCount
                vsCount += 1
            }
        }

        // Assign indices (ground is implicit 0 reference)
        for (index, name) in nodeNames.sorted().enumerated() {
            nodeMap[name] = index
        }

        // Adjust VS map indices based on final node count
        let nodeCount = nodeMap.count
        var newVSMap: [String: Int] = [:]
        for (name, _) in voltageSourceMap {
            newVSMap[name] = nodeCount + Array(voltageSourceMap.keys.sorted()).firstIndex(of: name)!
        }
        voltageSourceMap = newVSMap
    }

    // MARK: - Build solution

    private func buildSolution(from solution: Vector) -> MNASolution {
        var voltages: [String: Double] = [:]
        var currents: [String: Double] = [:]

        // Ground is always 0V
        voltages[groundNode] = 0.0

        for (name, index) in nodeMap {
            voltages[name] = solution[index]
        }

        for (name, index) in voltageSourceMap {
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
    /// Helper to get matrix index for a node (-1 for ground)
    func nodeIndex(_ node: String, nodeMap: [String: Int]) -> Int? {
        if node == "0" || node == "gnd" { return nil }
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
