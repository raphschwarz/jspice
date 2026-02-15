import Foundation
import Accelerate

// MARK: - Dense Matrix (backed by Accelerate)

/// Row-major dense matrix for MNA solver, backed by Apple's Accelerate framework
/// for LAPACK-optimized linear algebra on Apple Silicon.
struct Matrix: Sendable {
    let rows: Int
    let cols: Int
    private(set) var data: [Double]  // column-major for LAPACK

    init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
        self.data = [Double](repeating: 0, count: rows * cols)
    }

    init(rows: Int, cols: Int, data: [Double]) {
        precondition(data.count == rows * cols)
        self.rows = rows
        self.cols = cols
        self.data = data
    }

    // Column-major indexing for LAPACK
    subscript(row: Int, col: Int) -> Double {
        get {
            precondition(row >= 0 && row < rows && col >= 0 && col < cols)
            return data[col * rows + row]
        }
        set {
            precondition(row >= 0 && row < rows && col >= 0 && col < cols)
            data[col * rows + row] = newValue
        }
    }

    mutating func reset() {
        data = [Double](repeating: 0, count: rows * cols)
    }

    var isSquare: Bool { rows == cols }
}

// MARK: - Vector

struct Vector: Sendable {
    let count: Int
    private(set) var data: [Double]

    init(count: Int) {
        self.count = count
        self.data = [Double](repeating: 0, count: count)
    }

    init(_ data: [Double]) {
        self.count = data.count
        self.data = data
    }

    subscript(index: Int) -> Double {
        get {
            precondition(index >= 0 && index < count)
            return data[index]
        }
        set {
            precondition(index >= 0 && index < count)
            data[index] = newValue
        }
    }

    mutating func reset() {
        data = [Double](repeating: 0, count: count)
    }

    /// L-infinity norm (max absolute value)
    var maxNorm: Double {
        var result: Double = 0
        vDSP_maxmgvD(data, 1, &result, vDSP_Length(count))
        return result
    }

    /// Difference between two vectors
    func difference(from other: Vector) -> Vector {
        precondition(count == other.count)
        var result = [Double](repeating: 0, count: count)
        vDSP_vsubD(other.data, 1, data, 1, &result, 1, vDSP_Length(count))
        return Vector(result)
    }
}

// MARK: - Linear System Solver (Ax = b)

enum LinearAlgebraError: Error, CustomStringConvertible {
    case singularMatrix
    case dimensionMismatch
    case solverFailed(Int32)

    var description: String {
        switch self {
        case .singularMatrix:
            return "Matrix is singular (no unique solution exists)"
        case .dimensionMismatch:
            return "Matrix and vector dimensions do not match"
        case .solverFailed(let info):
            return "LAPACK solver failed with info = \(info)"
        }
    }
}

/// Solves the linear system Ax = b using LU decomposition via Accelerate's LAPACK
/// This is the core operation for Modified Nodal Analysis.
func solveLinearSystem(A: Matrix, b: Vector) throws -> Vector {
    guard A.isSquare else { throw LinearAlgebraError.dimensionMismatch }
    guard A.rows == b.count else { throw LinearAlgebraError.dimensionMismatch }

    let n = A.rows
    var a = A.data  // copy (LAPACK modifies in-place)
    var x = b.data  // copy (solution will be written here)
    var pivots = [__CLPK_integer](repeating: 0, count: n)
    var nrhs: __CLPK_integer = 1
    var order = __CLPK_integer(n)
    var lda = __CLPK_integer(n)
    var ldb = __CLPK_integer(n)
    var info: __CLPK_integer = 0

    // dgesv_ solves AX = B via LU factorization with partial pivoting
    dgesv_(&order, &nrhs, &a, &lda, &pivots, &x, &ldb, &info)

    if info < 0 {
        throw LinearAlgebraError.solverFailed(info)
    } else if info > 0 {
        throw LinearAlgebraError.singularMatrix
    }

    return Vector(x)
}

// MARK: - Complex Matrix for AC Analysis

struct ComplexNumber: Sendable {
    var real: Double
    var imag: Double

    static let zero = ComplexNumber(real: 0, imag: 0)
    static let one = ComplexNumber(real: 1, imag: 0)
    static let j = ComplexNumber(real: 0, imag: 1)

    var magnitude: Double { sqrt(real * real + imag * imag) }
    var phase: Double { atan2(imag, real) }
    var magnitudeDB: Double { 20 * log10(max(magnitude, 1e-30)) }
    var phaseDegrees: Double { phase * 180.0 / .pi }

    static func + (lhs: ComplexNumber, rhs: ComplexNumber) -> ComplexNumber {
        ComplexNumber(real: lhs.real + rhs.real, imag: lhs.imag + rhs.imag)
    }

    static func * (lhs: ComplexNumber, rhs: ComplexNumber) -> ComplexNumber {
        ComplexNumber(
            real: lhs.real * rhs.real - lhs.imag * rhs.imag,
            imag: lhs.real * rhs.imag + lhs.imag * rhs.real
        )
    }

    static func * (lhs: Double, rhs: ComplexNumber) -> ComplexNumber {
        ComplexNumber(real: lhs * rhs.real, imag: lhs * rhs.imag)
    }
}
