import XCTest
@testable import JSpice

final class MatrixTests: XCTestCase {

    // MARK: - Matrix Operations

    func testMatrixCreation() {
        let m = Matrix(rows: 3, cols: 3)
        XCTAssertEqual(m.rows, 3)
        XCTAssertEqual(m.cols, 3)
        XCTAssertEqual(m[0, 0], 0)
    }

    func testMatrixIndexing() {
        var m = Matrix(rows: 2, cols: 2)
        m[0, 0] = 1
        m[0, 1] = 2
        m[1, 0] = 3
        m[1, 1] = 4
        XCTAssertEqual(m[0, 0], 1)
        XCTAssertEqual(m[0, 1], 2)
        XCTAssertEqual(m[1, 0], 3)
        XCTAssertEqual(m[1, 1], 4)
    }

    // MARK: - Linear Solver

    func testSimpleLinearSystem() throws {
        // Solve: 2x + y = 5, x + 3y = 7
        // Solution: x = 1.6, y = 1.8
        var A = Matrix(rows: 2, cols: 2)
        A[0, 0] = 2; A[0, 1] = 1
        A[1, 0] = 1; A[1, 1] = 3

        let b = Vector([5, 7])
        let x = try solveLinearSystem(A: A, b: b)

        XCTAssertEqual(x[0], 1.6, accuracy: 1e-10)
        XCTAssertEqual(x[1], 1.8, accuracy: 1e-10)
    }

    func testIdentityMatrix() throws {
        var A = Matrix(rows: 3, cols: 3)
        A[0, 0] = 1; A[1, 1] = 1; A[2, 2] = 1

        let b = Vector([3, 5, 7])
        let x = try solveLinearSystem(A: A, b: b)

        XCTAssertEqual(x[0], 3, accuracy: 1e-10)
        XCTAssertEqual(x[1], 5, accuracy: 1e-10)
        XCTAssertEqual(x[2], 7, accuracy: 1e-10)
    }

    func testSingularMatrix() {
        var A = Matrix(rows: 2, cols: 2)
        A[0, 0] = 1; A[0, 1] = 1
        A[1, 0] = 1; A[1, 1] = 1  // Singular

        let b = Vector([1, 2])

        XCTAssertThrowsError(try solveLinearSystem(A: A, b: b))
    }

    // MARK: - Vector Operations

    func testVectorNorm() {
        let v = Vector([3, -4, 0])
        XCTAssertEqual(v.maxNorm, 4, accuracy: 1e-10)
    }

    func testVectorDifference() {
        let a = Vector([5, 3, 1])
        let b = Vector([1, 2, 3])
        let diff = a.difference(from: b)
        XCTAssertEqual(diff[0], 4, accuracy: 1e-10)
        XCTAssertEqual(diff[1], 1, accuracy: 1e-10)
        XCTAssertEqual(diff[2], -2, accuracy: 1e-10)
    }
}

final class ComponentTests: XCTestCase {

    // MARK: - Resistor Voltage Divider

    func testVoltageDivider() async throws {
        // V1 (5V) -> R1 (1kΩ) -> node_mid -> R2 (1kΩ) -> GND
        // Expected: V(mid) = 2.5V
        let solver = MNASolver()
        let netlist = MNASolver.Netlist(
            components: [
                MNADCVoltageSource(name: "V1", nodes: ["in", "0"], voltage: 5.0),
                MNAResistor(name: "R1", nodes: ["in", "mid"], resistance: 1000),
                MNAResistor(name: "R2", nodes: ["mid", "0"], resistance: 1000)
            ],
            groundNodeName: "0"
        )

        let solution = try await solver.solve(netlist: netlist)
        XCTAssertEqual(solution.voltage(at: "mid"), 2.5, accuracy: 1e-6)
        XCTAssertEqual(solution.voltage(at: "in"), 5.0, accuracy: 1e-6)
    }

    // MARK: - Three-Resistor Network

    func testThreeResistorNetwork() async throws {
        // V1 (10V) -> R1 (1kΩ) -> node_a -> R2 (2kΩ) -> GND
        //                                 -> R3 (2kΩ) -> GND
        // R2 || R3 = 1kΩ, so V(a) = 10 * 1/(1+1) = 5V
        let solver = MNASolver()
        let netlist = MNASolver.Netlist(
            components: [
                MNADCVoltageSource(name: "V1", nodes: ["in", "0"], voltage: 10.0),
                MNAResistor(name: "R1", nodes: ["in", "a"], resistance: 1000),
                MNAResistor(name: "R2", nodes: ["a", "0"], resistance: 2000),
                MNAResistor(name: "R3", nodes: ["a", "0"], resistance: 2000)
            ],
            groundNodeName: "0"
        )

        let solution = try await solver.solve(netlist: netlist)
        XCTAssertEqual(solution.voltage(at: "a"), 5.0, accuracy: 1e-6)
    }

    // MARK: - Current Source

    func testCurrentSourceWithResistor() async throws {
        // I1 (1mA) flowing into node_a, R1 (1kΩ) to ground
        // V(a) = I * R = 0.001 * 1000 = 1V
        let solver = MNASolver()
        let netlist = MNASolver.Netlist(
            components: [
                MNADCCurrentSource(name: "I1", nodes: ["0", "a"], current: 0.001),
                MNAResistor(name: "R1", nodes: ["a", "0"], resistance: 1000)
            ],
            groundNodeName: "0"
        )

        let solution = try await solver.solve(netlist: netlist)
        XCTAssertEqual(solution.voltage(at: "a"), 1.0, accuracy: 1e-6)
    }
}

final class SPICEParserTests: XCTestCase {

    func testParseValue() throws {
        XCTAssertEqual(try SPICENetlistParser.parseValue("1k"), 1000, accuracy: 1e-6)
        XCTAssertEqual(try SPICENetlistParser.parseValue("4.7u"), 4.7e-6, accuracy: 1e-12)
        XCTAssertEqual(try SPICENetlistParser.parseValue("100n"), 100e-9, accuracy: 1e-15)
        XCTAssertEqual(try SPICENetlistParser.parseValue("10meg"), 10e6, accuracy: 1)
        XCTAssertEqual(try SPICENetlistParser.parseValue("2.2p"), 2.2e-12, accuracy: 1e-18)
        XCTAssertEqual(try SPICENetlistParser.parseValue("47"), 47, accuracy: 1e-6)
    }

    func testParseSimpleNetlist() throws {
        let netlist = """
        Voltage Divider
        V1 in 0 5
        R1 in mid 1k
        R2 mid 0 1k
        .tran 1u 10m
        .end
        """

        let document = try SPICENetlistParser.parse(netlist)
        XCTAssertEqual(document.components.count, 3)  // V1, R1, R2
        XCTAssertEqual(document.simulationConfig.transient.timeStep, 1e-6, accuracy: 1e-12)
        XCTAssertEqual(document.simulationConfig.transient.stopTime, 10e-3, accuracy: 1e-9)
    }

    func testExportRoundTrip() throws {
        var document = CircuitDocument()
        document.addComponent(SchematicComponent(type: .resistor))
        document.addComponent(SchematicComponent(type: .dcVoltageSource))

        let exported = SPICENetlistExporter.export(document: document)
        XCTAssertTrue(exported.contains(".tran"))
        XCTAssertTrue(exported.contains(".end"))
    }
}

final class ComplexNumberTests: XCTestCase {

    func testMagnitude() {
        let c = ComplexNumber(real: 3, imag: 4)
        XCTAssertEqual(c.magnitude, 5, accuracy: 1e-10)
    }

    func testPhase() {
        let c = ComplexNumber(real: 1, imag: 1)
        XCTAssertEqual(c.phaseDegrees, 45, accuracy: 1e-10)
    }

    func testMultiplication() {
        let a = ComplexNumber(real: 1, imag: 2)
        let b = ComplexNumber(real: 3, imag: 4)
        let result = a * b
        // (1+2i)(3+4i) = 3+4i+6i+8i² = 3+10i-8 = -5+10i
        XCTAssertEqual(result.real, -5, accuracy: 1e-10)
        XCTAssertEqual(result.imag, 10, accuracy: 1e-10)
    }
}
