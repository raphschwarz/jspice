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
