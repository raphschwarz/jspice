import Foundation

/// How to factor a circuit's equations: the order of the pivots and every operation of the elimination, worked out once
/// and then replayed on new values, as Newton-Raphson needs at every iteration.
///
/// Only the entries that can be non-zero are kept, in one array of values: the matrix's pattern and the fill-in the
/// elimination adds to it. The pivots are ordered by Markowitz's rule (the pivot whose row and column have the fewest
/// other entries, so the least fill-in) among those within a threshold of the largest in their column (so the
/// elimination stays accurate). A pivot is a row and a column: nothing is swapped, and the elimination is a list of
/// slots to update.
///
/// The unknowns no nonlinear part touches come first (the linear block). Their elimination only involves entries that
/// stay the same through a substep, so it is done once for each base matrix, and leaves the rest of the matrix (the
/// nonlinear block, with what the linear block contributes to it) for Newton-Raphson to restamp and refactor alone.
final class SparsePlan {
    let n: Int
    /// Values in the plan: the pattern's entries and the fill-in
    let entryCount: Int
    /// The first slot of the nonlinear block's entries (row and column both nonlinear unknowns), which come last: the
    /// only ones Newton-Raphson restamps
    let tailStart: Int
    /// Pivots of the linear block, which come first
    let leading: Int
    /// For each unknown, whether it is in the nonlinear block
    let nonlinear: [Bool]
    /// The pattern the plan was made for, without the fill-in (row-major)
    let structure: [Bool]
    /// The slot of each entry (row × n + column), -1 outside the plan
    let slots: UnsafeMutablePointer<Int32>
    /// For each pivot step: its row, its column and its slot
    let pivotRow, pivotColumn, diagonal: UnsafeMutablePointer<Int32>
    /// Step k divides the entries below its pivot, rows lRow[lStart[k]..<lStart[k + 1]] at slots lSlot[…], by the pivot,
    /// and subtracts each times the pivot row's entries right of it, columns uColumn[uStart[k]..<uStart[k + 1]] at slots
    /// uSlot[…], from the slots target[…] (opStart[k] on, row by row)
    let lStart, uStart, opStart: UnsafeMutablePointer<Int32>
    let lRow, lSlot, uColumn, uSlot, target: UnsafeMutablePointer<Int32>
    let lCount, uCount, opCount: Int

    /// The relative size, against the largest entry below it in its column, a pivot must have to be chosen
    static let threshold = 0.1
    /// The relative size a planned pivot must keep for the plan to be replayed: far below `threshold`, so the plan
    /// lasts while values move
    static let replayThreshold = 1e-3

    private init(n: Int, nonlinear: [Bool], structure: [Bool], mask: [Bool], pivots: [(row: Int, column: Int)],
                 below: [[Int32]], right: [[Int32]]) {
        let slots = UnsafeMutablePointer<Int32>.allocate(capacity: n * n)
        slots.initialize(repeating: -1, count: n * n)
        // the entries outside the nonlinear block first, then the nonlinear block's
        var slot: Int32 = 0
        var tailStart = 0
        for pass in 0..<2 {
            for r in 0..<n {
                for c in 0..<n where mask[r * n + c] && ((nonlinear[r] && nonlinear[c]) == (pass == 1)) {
                    slots[r * n + c] = slot
                    slot += 1
                }
            }
            if pass == 0 { tailStart = Int(slot) }
        }
        let lCount = below.reduce(0) { $0 + $1.count }
        let uCount = right.reduce(0) { $0 + $1.count }
        let opCount = zip(below, right).reduce(0) { $0 + $1.0.count * $1.1.count }
        let pivotRow = UnsafeMutablePointer<Int32>.allocate(capacity: n)
        let pivotColumn = UnsafeMutablePointer<Int32>.allocate(capacity: n)
        let diagonal = UnsafeMutablePointer<Int32>.allocate(capacity: n)
        let lStart = UnsafeMutablePointer<Int32>.allocate(capacity: n + 1)
        let uStart = UnsafeMutablePointer<Int32>.allocate(capacity: n + 1)
        let opStart = UnsafeMutablePointer<Int32>.allocate(capacity: n + 1)
        let lRow = UnsafeMutablePointer<Int32>.allocate(capacity: max(lCount, 1))
        let lSlot = UnsafeMutablePointer<Int32>.allocate(capacity: max(lCount, 1))
        let uColumn = UnsafeMutablePointer<Int32>.allocate(capacity: max(uCount, 1))
        let uSlot = UnsafeMutablePointer<Int32>.allocate(capacity: max(uCount, 1))
        let target = UnsafeMutablePointer<Int32>.allocate(capacity: max(opCount, 1))
        var l = 0, u = 0, op = 0
        for k in 0..<n {
            let (pr, pc) = pivots[k]
            pivotRow[k] = Int32(pr)
            pivotColumn[k] = Int32(pc)
            diagonal[k] = slots[pr * n + pc]
            lStart[k] = Int32(l)
            uStart[k] = Int32(u)
            opStart[k] = Int32(op)
            for r in below[k] {
                lRow[l] = r
                lSlot[l] = slots[Int(r) * n + pc]
                l += 1
                for c in right[k] {
                    target[op] = slots[Int(r) * n + Int(c)]
                    op += 1
                }
            }
            for c in right[k] {
                uColumn[u] = c
                uSlot[u] = slots[pr * n + Int(c)]
                u += 1
            }
        }
        lStart[n] = Int32(l)
        uStart[n] = Int32(u)
        opStart[n] = Int32(op)
        self.n = n
        self.nonlinear = nonlinear
        self.structure = structure
        self.leading = nonlinear.reduce(0) { $1 ? $0 : $0 + 1 }
        self.slots = slots
        self.entryCount = Int(slot)
        self.tailStart = tailStart
        self.lCount = lCount
        self.uCount = uCount
        self.opCount = opCount
        self.pivotRow = pivotRow
        self.pivotColumn = pivotColumn
        self.diagonal = diagonal
        self.lStart = lStart
        self.uStart = uStart
        self.opStart = opStart
        self.lRow = lRow
        self.lSlot = lSlot
        self.uColumn = uColumn
        self.uSlot = uSlot
        self.target = target
    }

    deinit {
        for pointer in [slots, pivotRow, pivotColumn, diagonal, lStart, uStart, opStart, lRow, lSlot, uColumn, uSlot, target] {
            pointer.deallocate()
        }
    }

    // MARK: - Planning

    /// Plans the elimination of `matrix` (row-major, n × n) with the entries `pattern` allows to be non-zero, putting
    /// the unknowns `nonlinear` marks last; nil when the matrix is singular. An unknown of the linear block that cannot
    /// be pivoted there (a voltage source's row whose nodes are all nonlinear) joins the nonlinear block.
    static func make(matrix: [Double], pattern: [Bool], nonlinear: [Bool], size n: Int) -> SparsePlan? {
        guard n > 0, matrix.count >= n * n, pattern.count >= n * n, nonlinear.count >= n else { return nil }
        var inS = nonlinear
        // a linear row without an entry in a linear column (or the reverse) can only be pivoted in the nonlinear block
        var moved = true
        while moved {
            moved = false
            for i in 0..<n where !inS[i] {
                var rowHasLinear = false, columnHasLinear = false
                for j in 0..<n where !inS[j] {
                    if pattern[i * n + j] { rowHasLinear = true }
                    if pattern[j * n + i] { columnHasLinear = true }
                }
                if !rowHasLinear || !columnHasLinear {
                    inS[i] = true
                    moved = true
                }
            }
        }
        for _ in 0...n {
            switch attempt(matrix, pattern, inS, n) {
            case .planned(let plan): return plan
            case .singular: return nil
            case .stuck(let unknowns):
                for i in unknowns { inS[i] = true }
            }
        }
        return nil
    }

    private enum Attempt {
        case planned(SparsePlan)
        case singular
        /// The linear block ran out of usable pivots: these unknowns join the nonlinear block
        case stuck([Int])
    }

    private static func attempt(_ matrix: [Double], _ pattern: [Bool], _ inS: [Bool], _ n: Int) -> Attempt {
        var a = Array(matrix[0..<(n * n)])
        var mask = Array(pattern[0..<(n * n)])
        var rowsOfColumn = [[Int32]](repeating: [], count: n)
        var columnsOfRow = [[Int32]](repeating: [], count: n)
        for r in 0..<n {
            for c in 0..<n where mask[r * n + c] {
                rowsOfColumn[c].append(Int32(r))
                columnsOfRow[r].append(Int32(c))
            }
        }
        var rowCount = columnsOfRow.map(\.count)
        var columnCount = rowsOfColumn.map(\.count)
        var rowLeft = [Bool](repeating: true, count: n)
        var columnLeft = [Bool](repeating: true, count: n)
        let leading = inS.reduce(0) { $1 ? $0 : $0 + 1 }
        var pivots: [(row: Int, column: Int)] = []
        var below: [[Int32]] = []
        var right: [[Int32]] = []
        pivots.reserveCapacity(n)
        below.reserveCapacity(n)
        right.reserveCapacity(n)
        for k in 0..<n {
            let linear = k < leading
            var best = (row: -1, column: -1)
            var bestCost = Int.max
            var bestRatio = 0.0
            for c in 0..<n where columnLeft[c] && inS[c] != linear {
                var largest = 0.0
                for r in rowsOfColumn[c] where rowLeft[Int(r)] { largest = max(largest, abs(a[Int(r) * n + c])) }
                guard largest >= 1e-14 else { continue }
                for r32 in rowsOfColumn[c] {
                    let r = Int(r32)
                    guard rowLeft[r] && inS[r] != linear else { continue }
                    let magnitude = abs(a[r * n + c])
                    guard magnitude >= threshold * largest && magnitude >= 1e-14 else { continue }
                    let cost = (rowCount[r] - 1) * (columnCount[c] - 1)
                    let ratio = magnitude / largest
                    if cost < bestCost || (cost == bestCost && ratio > bestRatio) {
                        best = (r, c)
                        bestCost = cost
                        bestRatio = ratio
                    }
                }
            }
            if best.row < 0 {
                guard linear else { return .singular }
                // rows of the linear block left without a usable entry in its columns move over; failing that, all
                // that is left of the linear block does
                var stuck: [Int] = []
                for r in 0..<n where rowLeft[r] && !inS[r] {
                    let usable = columnsOfRow[r].contains { c in
                        columnLeft[Int(c)] && !inS[Int(c)] && abs(a[r * n + Int(c)]) >= 1e-14
                    }
                    if !usable { stuck.append(r) }
                }
                if stuck.isEmpty { stuck = (0..<n).filter { rowLeft[$0] && !inS[$0] } }
                return .stuck(stuck)
            }
            let (pr, pc) = best
            let pivotColumns = columnsOfRow[pr].filter { columnLeft[Int($0)] && Int($0) != pc }
            let pivotRows = rowsOfColumn[pc].filter { rowLeft[Int($0)] && Int($0) != pr }
            let pivot = a[pr * n + pc]
            for r32 in pivotRows {
                let r = Int(r32)
                let factor = a[r * n + pc] / pivot
                a[r * n + pc] = factor
                for c32 in pivotColumns {
                    let c = Int(c32)
                    if !mask[r * n + c] {
                        mask[r * n + c] = true
                        rowsOfColumn[c].append(r32)
                        columnsOfRow[r].append(c32)
                        rowCount[r] += 1
                        columnCount[c] += 1
                    }
                    a[r * n + c] -= factor * a[pr * n + c]
                }
            }
            rowLeft[pr] = false
            columnLeft[pc] = false
            for c in pivotColumns { columnCount[Int(c)] -= 1 }
            for r in pivotRows { rowCount[Int(r)] -= 1 }
            pivots.append((pr, pc))
            below.append(pivotRows)
            right.append(pivotColumns)
        }
        return .planned(SparsePlan(n: n, nonlinear: inS, structure: Array(pattern[0..<(n * n)]), mask: mask, pivots: pivots,
                                   below: below, right: right))
    }

    // MARK: - Replaying

    /// Eliminates pivot steps `first..<end` in `values`, in place; -1 when done, or the step whose pivot has become too
    /// small to use (a new plan is needed)
    func factor(_ values: UnsafeMutablePointer<Double>, from first: Int, to end: Int) -> Int {
        var k = first
        while k < end {
            let pivot = values[Int(diagonal[k])]
            let l0 = Int(lStart[k]), l1 = Int(lStart[k + 1])
            var largest = 0.0
            var j = l0
            while j < l1 {
                largest = max(largest, abs(values[Int(lSlot[j])]))
                j += 1
            }
            let size = abs(pivot)
            // (written so that a pivot that is not a number fails too)
            guard size >= 1e-14 && size >= Self.replayThreshold * largest else { return k }
            let u0 = Int(uStart[k]), u1 = Int(uStart[k + 1])
            var t = Int(opStart[k])
            j = l0
            while j < l1 {
                let slot = Int(lSlot[j])
                let factor = values[slot] / pivot
                values[slot] = factor
                if factor != 0 {
                    var i = u0
                    while i < u1 {
                        values[Int(target[t])] -= factor * values[Int(uSlot[i])]
                        i += 1
                        t += 1
                    }
                } else {
                    t += u1 - u0
                }
                j += 1
            }
            k += 1
        }
        return -1
    }

    /// Forward substitution through pivot steps `first..<end`: `b` (indexed by row, as stamped) becomes L⁻¹ b
    func forward(_ values: UnsafePointer<Double>, _ b: UnsafeMutablePointer<Double>, from first: Int, to end: Int) {
        var k = first
        while k < end {
            let bk = b[Int(pivotRow[k])]
            if bk != 0 {
                var j = Int(lStart[k])
                let l1 = Int(lStart[k + 1])
                while j < l1 {
                    b[Int(lRow[j])] -= values[Int(lSlot[j])] * bk
                    j += 1
                }
            }
            k += 1
        }
    }

    /// Back substitution through pivot steps `end - 1` down to `first`, writing the unknowns their columns stand for
    /// into `x` (the later steps' unknowns must be there already). Returns the largest change of an unknown, relative
    /// to its new size, or NaN if one is not a number (then `x` is partly written).
    func back(_ values: UnsafePointer<Double>, _ b: UnsafePointer<Double>, _ x: UnsafeMutablePointer<Double>,
              from first: Int, to end: Int) -> Double {
        var change = 0.0
        var k = end - 1
        while k >= first {
            var sum = b[Int(pivotRow[k])]
            var i = Int(uStart[k])
            let u1 = Int(uStart[k + 1])
            while i < u1 {
                sum -= values[Int(uSlot[i])] * x[Int(uColumn[i])]
                i += 1
            }
            let column = Int(pivotColumn[k])
            let next = sum / values[Int(diagonal[k])]
            guard next.isFinite else { return .nan }
            change = max(change, abs(next - x[column]) / (1 + abs(next)))
            x[column] = next
            k -= 1
        }
        return change
    }
}
