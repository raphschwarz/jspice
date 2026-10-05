import Foundation

/// LU decomposition with partial pivoting of a dense, row-major n x n matrix.
struct LUSolver {
    let n: Int
    private let lu: [Double]
    private let pivots: [Int]

    /// Returns nil when the matrix is singular (for example a loop of voltage sources)
    init?(matrix: [Double], size n: Int) {
        var factors = matrix
        var permutation = Array(0..<n)
        let ok = factors.withUnsafeMutableBufferPointer { a -> Bool in
            for k in 0..<n {
                // pivot: the largest magnitude in column k at or below the diagonal
                var pivotRow = k
                var pivotMagnitude = abs(a[k * n + k])
                for r in (k + 1)..<n where abs(a[r * n + k]) > pivotMagnitude {
                    pivotMagnitude = abs(a[r * n + k])
                    pivotRow = r
                }
                if pivotMagnitude < 1e-14 { return false }
                if pivotRow != k {
                    for c in 0..<n { a.swapAt(k * n + c, pivotRow * n + c) }
                    permutation.swapAt(k, pivotRow)
                }
                let pivot = a[k * n + k]
                for r in (k + 1)..<n {
                    let factor = a[r * n + k] / pivot
                    if factor == 0 { continue }
                    a[r * n + k] = factor
                    for c in (k + 1)..<n {
                        a[r * n + c] -= factor * a[k * n + c]
                    }
                }
            }
            return true
        }
        if !ok { return nil }
        self.n = n
        lu = factors
        pivots = permutation
    }

    func solve(_ b: [Double]) -> [Double] {
        var x = [Double](repeating: 0, count: n)
        lu.withUnsafeBufferPointer { a in
            // forward substitution with the permuted right-hand side
            for r in 0..<n {
                var sum = b[pivots[r]]
                for c in 0..<r { sum -= a[r * n + c] * x[c] }
                x[r] = sum
            }
            // back substitution
            for r in stride(from: n - 1, through: 0, by: -1) {
                var sum = x[r]
                for c in (r + 1)..<n { sum -= a[r * n + c] * x[c] }
                x[r] = sum / a[r * n + r]
            }
        }
        return x
    }
}

extension LUSolver {
    /// Solves a · x = b by Gaussian elimination with partial pivoting, in place: `b` becomes x and `a` is used up.
    /// Newton-Raphson solves a new matrix of the same size at every iteration, so it keeps both buffers and allocates
    /// nothing. False when the matrix is singular.
    ///
    /// Circuit matrices are sparse (a node meets only a few parts), so each pivot row's non-zero columns are listed
    /// once and the rows below are updated in those columns only: most of the dense n³ work is multiplying by zero.
    static func solveInPlace(_ a: inout [Double], _ b: inout [Double], size n: Int) -> Bool {
        guard n > 0, a.count >= n * n, b.count >= n else { return n == 0 }
        return withUnsafeTemporaryAllocation(of: Int.self, capacity: n) { columns -> Bool in
            a.withUnsafeMutableBufferPointer { a -> Bool in
                b.withUnsafeMutableBufferPointer { b -> Bool in
                    for k in 0..<n {
                        var pivotRow = k
                        var pivotMagnitude = abs(a[k * n + k])
                        for r in (k + 1)..<n where abs(a[r * n + k]) > pivotMagnitude {
                            pivotMagnitude = abs(a[r * n + k])
                            pivotRow = r
                        }
                        if pivotMagnitude < 1e-14 { return false }
                        if pivotRow != k {
                            for c in k..<n { a.swapAt(k * n + c, pivotRow * n + c) }
                            b.swapAt(k, pivotRow)
                        }
                        let pivotBase = k * n
                        var count = 0
                        for c in (k + 1)..<n where a[pivotBase + c] != 0 {
                            columns[count] = c
                            count += 1
                        }
                        let pivot = a[pivotBase + k]
                        let bk = b[k]
                        for r in (k + 1)..<n {
                            let rowBase = r * n
                            let entry = a[rowBase + k]
                            if entry == 0 { continue }
                            let factor = entry / pivot
                            for j in 0..<count {
                                let c = columns[j]
                                a[rowBase + c] -= factor * a[pivotBase + c]
                            }
                            b[r] -= factor * bk
                        }
                    }
                    for r in stride(from: n - 1, through: 0, by: -1) {
                        let rowBase = r * n
                        var sum = b[r]
                        for c in (r + 1)..<n {
                            let entry = a[rowBase + c]
                            if entry != 0 { sum -= entry * b[c] }
                        }
                        b[r] = sum / a[rowBase + r]
                    }
                    return true
                }
            }
        }
    }
}
