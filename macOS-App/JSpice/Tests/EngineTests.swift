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

    func testColumnMajorStorage() {
        // Verify that indexing is column-major (correct for LAPACK)
        var m = Matrix(rows: 2, cols: 2)
        m[0, 0] = 1  // data[0]
        m[1, 0] = 2  // data[1]
        m[0, 1] = 3  // data[2]
        m[1, 1] = 4  // data[3]
        // Column-major: [1, 2, 3, 4]
        XCTAssertEqual(m.data[0], 1)
        XCTAssertEqual(m.data[1], 2)
        XCTAssertEqual(m.data[2], 3)
        XCTAssertEqual(m.data[3], 4)
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

    // MARK: - Diode (Nonlinear)

    func testDiodeForwardBias() async throws {
        // V1 (5V) -> R1 (1kΩ) -> anode -> D1 -> GND
        // Diode should be forward biased, voltage across diode ≈ 0.6-0.7V
        let solver = MNASolver()
        let netlist = MNASolver.Netlist(
            components: [
                MNADCVoltageSource(name: "V1", nodes: ["in", "0"], voltage: 5.0),
                MNAResistor(name: "R1", nodes: ["in", "anode"], resistance: 1000),
                MNADiode(name: "D1", nodes: ["anode", "0"], saturationCurrent: 1e-14, emissionCoefficient: 1.0)
            ],
            groundNodeName: "0"
        )

        let solution = try await solver.solve(netlist: netlist)
        let vAnode = solution.voltage(at: "anode")
        // Diode forward voltage should be approximately 0.5-0.8V
        XCTAssertGreaterThan(vAnode, 0.4)
        XCTAssertLessThan(vAnode, 0.9)
    }

    // MARK: - RC Circuit (Companion Model)

    func testRCCapacitorCharging() async throws {
        // V1 (5V) -> R1 (1kΩ) -> node_a -> C1 (1µF) -> GND
        // RC = 1kΩ * 1µF = 1ms time constant
        // At t = 5RC = 5ms, capacitor should be nearly charged to 5V
        let solver = MNASolver()

        // Test initial state (t=0, no charge): V(a) should be near 0
        let netlistT0 = MNASolver.Netlist(
            components: [
                MNADCVoltageSource(name: "V1", nodes: ["in", "0"], voltage: 5.0),
                MNAResistor(name: "R1", nodes: ["in", "a"], resistance: 1000),
                MNACapacitorCompanion(
                    name: "C1", nodes: ["a", "0"],
                    companionConductance: 2.0 * 1e-6 / 1e-6,  // 2C/h = 2
                    companionCurrent: 0  // Initial: no charge
                )
            ],
            groundNodeName: "0"
        )

        let solutionT0 = try await solver.solve(netlist: netlistT0)
        // With Geq=2 and R=1000: V(a) = 5 * Geq/(Geq + 1/R) ≈ near 5V (Geq dominates)
        // Actually Geq = 2 S (conductance), R = 1000Ω (conductance = 0.001 S)
        // So V(a) = 5 * 0.001/(0.001 + 2) ≈ 0.0025V — because cap is a low impedance
        XCTAssertLessThan(solutionT0.voltage(at: "a"), 1.0)
    }

    // MARK: - Empty and Error Cases

    func testEmptyNetlist() async {
        let solver = MNASolver()
        let netlist = MNASolver.Netlist(components: [], groundNodeName: "0")

        do {
            _ = try await solver.solve(netlist: netlist)
            XCTFail("Should have thrown emptyNetlist error")
        } catch {
            // Expected
        }
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

    func testParseValueEdgeCases() throws {
        XCTAssertEqual(try SPICENetlistParser.parseValue("0"), 0, accuracy: 1e-18)
        XCTAssertEqual(try SPICENetlistParser.parseValue("1.5"), 1.5, accuracy: 1e-10)
        XCTAssertEqual(try SPICENetlistParser.parseValue("1G"), 1e9, accuracy: 1)
        XCTAssertEqual(try SPICENetlistParser.parseValue("10f"), 10e-15, accuracy: 1e-20)
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

    func testParseNetlistWithComments() throws {
        let netlist = """
        Test Circuit
        * This is a comment
        V1 in 0 5
        ; Another comment
        R1 in out 1k
        .end
        """

        let document = try SPICENetlistParser.parse(netlist)
        XCTAssertEqual(document.components.count, 2)
    }

    func testParseACSource() throws {
        let netlist = """
        AC Test
        V1 in 0 AC 1 SIN(0 1 1000)
        R1 in 0 1k
        .end
        """

        let document = try SPICENetlistParser.parse(netlist)
        XCTAssertEqual(document.components.count, 2)
        let acSource = document.components.first { $0.type == .acVoltageSource }
        XCTAssertNotNil(acSource)
        XCTAssertEqual(acSource?.parameters["frequency"]?.value ?? 0, 1000, accuracy: 1e-6)
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

    func testAddition() {
        let a = ComplexNumber(real: 1, imag: 2)
        let b = ComplexNumber(real: 3, imag: 4)
        let result = a + b
        XCTAssertEqual(result.real, 4, accuracy: 1e-10)
        XCTAssertEqual(result.imag, 6, accuracy: 1e-10)
    }

    func testSubtraction() {
        let a = ComplexNumber(real: 5, imag: 3)
        let b = ComplexNumber(real: 2, imag: 1)
        let result = a - b
        XCTAssertEqual(result.real, 3, accuracy: 1e-10)
        XCTAssertEqual(result.imag, 2, accuracy: 1e-10)
    }

    func testMultiplication() {
        let a = ComplexNumber(real: 1, imag: 2)
        let b = ComplexNumber(real: 3, imag: 4)
        let result = a * b
        // (1+2i)(3+4i) = 3+4i+6i+8i² = 3+10i-8 = -5+10i
        XCTAssertEqual(result.real, -5, accuracy: 1e-10)
        XCTAssertEqual(result.imag, 10, accuracy: 1e-10)
    }

    func testDivision() {
        let a = ComplexNumber(real: 1, imag: 0)
        let b = ComplexNumber(real: 0, imag: 1)
        let result = a / b
        // 1/i = -i
        XCTAssertEqual(result.real, 0, accuracy: 1e-10)
        XCTAssertEqual(result.imag, -1, accuracy: 1e-10)
    }

    func testNegation() {
        let a = ComplexNumber(real: 3, imag: -4)
        let result = -a
        XCTAssertEqual(result.real, -3, accuracy: 1e-10)
        XCTAssertEqual(result.imag, 4, accuracy: 1e-10)
    }

    func testConjugate() {
        let a = ComplexNumber(real: 3, imag: 4)
        let conj = a.conjugate
        XCTAssertEqual(conj.real, 3, accuracy: 1e-10)
        XCTAssertEqual(conj.imag, -4, accuracy: 1e-10)
    }

    func testMagnitudeDB() {
        // 1V = 0 dB
        let unity = ComplexNumber(real: 1, imag: 0)
        XCTAssertEqual(unity.magnitudeDB, 0, accuracy: 0.01)

        // 10V = 20 dB
        let ten = ComplexNumber(real: 10, imag: 0)
        XCTAssertEqual(ten.magnitudeDB, 20, accuracy: 0.01)
    }
}
