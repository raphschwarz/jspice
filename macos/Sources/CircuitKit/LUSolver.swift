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
        solve(b, into: &x)
        return x
    }

    /// Solves into `x`, reusing its storage when it already has the right size
    func solve(_ b: [Double], into x: inout [Double]) {
        if x.count != n { x = [Double](repeating: 0, count: n) }
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
    }
}

/// How an elimination went: the pivot chosen at each step and the non-zero entries it met. Newton-Raphson solves a
/// matrix with the same non-zero entries at every iteration (only their values change), so the next one can be
/// eliminated by replaying the plan, without searching for pivots or for non-zero entries.
struct EliminationPlan {
    let n: Int
    /// Entries that may be non-zero in a matrix the plan fits (row-major, as given, before any row swaps)
    let pattern: [Bool]
    /// The row swapped into place at each step
    let swaps: [Int]
    /// Step k updates rows[rowStart[k]..<rowStart[k + 1]] in the pivot row's columns
    /// columns[columnStart[k]..<columnStart[k + 1]] (all right of the diagonal)
    let rowStart: [Int]
    let rows: [Int]
    let columnStart: [Int]
    let columns: [Int]
}

extension LUSolver {
    /// Solves a · x = b by Gaussian elimination with partial pivoting, in place: `b` becomes x and `a` is used up.
    /// Newton-Raphson solves a new matrix of the same size at every iteration, so it keeps both buffers and allocates
    /// nothing. False when the matrix is singular.
    static func solveInPlace(_ a: inout [Double], _ b: inout [Double], size n: Int) -> Bool {
        guard n > 0, a.count >= n * n, b.count >= n else { return n == 0 }
        return finish(&a, &b, size: n, from: 0)
    }

    /// Solves like `solveInPlace`, replaying `plan` when the matrix still fits it, and otherwise eliminating afresh and
    /// leaving a new plan. A matrix fits when it has no non-zero entry the plan has not seen and each planned pivot is
    /// still large enough for its column; patterns only grow, so after a few new plans one fits for good.
    static func solveInPlace(_ a: inout [Double], _ b: inout [Double], size n: Int, plan: inout EliminationPlan?) -> Bool {
        guard n > 0, a.count >= n * n, b.count >= n else { return n == 0 }
        if let current = plan, current.n == n, fits(a, current) {
            let stopped = replay(&a, &b, current)
            if stopped < 0 { return true }
            // a planned pivot became too small: pivot afresh from that step, and plan again next time
            plan = nil
            return finish(&a, &b, size: n, from: stopped)
        }
        let prior = plan.flatMap { $0.n == n ? $0.pattern : nil }
        plan = makePlan(&a, &b, size: n, prior: prior)
        return plan != nil
    }

    /// Elimination with partial pivoting from step `first` on, then back substitution.
    ///
    /// Circuit matrices are sparse (a node meets only a few parts), so each pivot row's non-zero columns are listed
    /// once and the rows below are updated in those columns only: most of the dense n³ work is multiplying by zero.
    private static func finish(_ a: inout [Double], _ b: inout [Double], size n: Int, from first: Int) -> Bool {
        withUnsafeTemporaryAllocation(of: Int.self, capacity: n) { columns -> Bool in
            a.withUnsafeMutableBufferPointer { a -> Bool in
                b.withUnsafeMutableBufferPointer { b -> Bool in
                    for k in first..<n {
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

    /// True when every non-zero entry of `a` is one the plan expects
    private static func fits(_ a: [Double], _ plan: EliminationPlan) -> Bool {
        a.withUnsafeBufferPointer { a -> Bool in
            plan.pattern.withUnsafeBufferPointer { pattern -> Bool in
                for i in 0..<(plan.n * plan.n) where a[i] != 0 && !pattern[i] { return false }
                return true
            }
        }
    }

    /// Eliminates and solves along the plan; -1 when done, or the step whose planned pivot is too small to use (the
    /// steps before it are done, and elimination can go on from there with fresh pivoting)
    private static func replay(_ a: inout [Double], _ b: inout [Double], _ plan: EliminationPlan) -> Int {
        let n = plan.n
        return a.withUnsafeMutableBufferPointer { a -> Int in
            b.withUnsafeMutableBufferPointer { b -> Int in
                plan.rows.withUnsafeBufferPointer { rows -> Int in
                    plan.columns.withUnsafeBufferPointer { columns -> Int in
                        plan.rowStart.withUnsafeBufferPointer { rowStart -> Int in
                            plan.columnStart.withUnsafeBufferPointer { columnStart -> Int in
                                for k in 0..<n {
                                    let swap = plan.swaps[k]
                                    if swap != k {
                                        for c in k..<n { a.swapAt(k * n + c, swap * n + c) }
                                        b.swapAt(k, swap)
                                    }
                                    let pivotBase = k * n
                                    let pivot = a[pivotBase + k]
                                    let firstRow = rowStart[k]
                                    let endRow = rowStart[k + 1]
                                    var largest = 0.0
                                    for j in firstRow..<endRow { largest = max(largest, abs(a[rows[j] * n + k])) }
                                    if abs(pivot) < 1e-14 || abs(pivot) < 1e-3 * largest { return k }
                                    let firstColumn = columnStart[k]
                                    let endColumn = columnStart[k + 1]
                                    let bk = b[k]
                                    for j in firstRow..<endRow {
                                        let r = rows[j]
                                        let rowBase = r * n
                                        let entry = a[rowBase + k]
                                        if entry == 0 { continue }
                                        let factor = entry / pivot
                                        for i in firstColumn..<endColumn {
                                            let c = columns[i]
                                            a[rowBase + c] -= factor * a[pivotBase + c]
                                        }
                                        b[r] -= factor * bk
                                    }
                                }
                                for r in stride(from: n - 1, through: 0, by: -1) {
                                    let rowBase = r * n
                                    var sum = b[r]
                                    for i in columnStart[r]..<columnStart[r + 1] {
                                        let c = columns[i]
                                        sum -= a[rowBase + c] * b[c]
                                    }
                                    b[r] = sum / a[rowBase + r]
                                }
                                return -1
                            }
                        }
                    }
                }
            }
        }
    }

    /// Eliminates and solves with partial pivoting, keeping track of which entries are non-zero by structure (not just
    /// by value, which can be zero by chance), and returns the plan; nil if the matrix is singular. `prior` adds the
    /// entries a previous plan expected, so the pattern only grows.
    private static func makePlan(_ a: inout [Double], _ b: inout [Double], size n: Int, prior: [Bool]?) -> EliminationPlan? {
        var pattern = [Bool](repeating: false, count: n * n)
        for i in 0..<(n * n) where a[i] != 0 || (prior?[i] ?? false) { pattern[i] = true }
        var mask = pattern
        var swaps = [Int](repeating: 0, count: n)
        var rowStart = [0]
        var rows: [Int] = []
        var columnStart = [0]
        var columns: [Int] = []
        rowStart.reserveCapacity(n + 1)
        columnStart.reserveCapacity(n + 1)
        for k in 0..<n {
            var pivotRow = k
            var pivotMagnitude = abs(a[k * n + k])
            for r in (k + 1)..<n where abs(a[r * n + k]) > pivotMagnitude {
                pivotMagnitude = abs(a[r * n + k])
                pivotRow = r
            }
            if pivotMagnitude < 1e-14 { return nil }
            if pivotRow != k {
                for c in k..<n {
                    a.swapAt(k * n + c, pivotRow * n + c)
                    mask.swapAt(k * n + c, pivotRow * n + c)
                }
                b.swapAt(k, pivotRow)
            }
            swaps[k] = pivotRow
            let firstColumn = columns.count
            for c in (k + 1)..<n where mask[k * n + c] { columns.append(c) }
            let firstRow = rows.count
            for r in (k + 1)..<n where mask[r * n + k] { rows.append(r) }
            let pivot = a[k * n + k]
            for j in firstRow..<rows.count {
                let r = rows[j]
                let factor = a[r * n + k] / pivot
                for i in firstColumn..<columns.count {
                    let c = columns[i]
                    mask[r * n + c] = true
                    a[r * n + c] -= factor * a[k * n + c]
                }
                b[r] -= factor * b[k]
            }
            rowStart.append(rows.count)
            columnStart.append(columns.count)
        }
        for r in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[r]
            for i in columnStart[r]..<columnStart[r + 1] {
                let c = columns[i]
                sum -= a[r * n + c] * b[c]
            }
            b[r] = sum / a[r * n + r]
        }
        return EliminationPlan(n: n, pattern: pattern, swaps: swaps, rowStart: rowStart, rows: rows, columnStart: columnStart,
                               columns: columns)
    }
}
