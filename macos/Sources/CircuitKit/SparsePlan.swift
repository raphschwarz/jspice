import Foundation

/// One elimination worked out ahead: its pivots in order and every operation, as slots into an array of values, so it
/// can be replayed on new values without searching for pivots or non-zero entries, and without swapping rows (a pivot
/// is a row and a column). Rows and columns are the equations' own unknowns.
final class EliminationProgram {
    let steps: Int
    /// For each step: its pivot's row, column and slot
    let pivotRow, pivotColumn, diagonal: UnsafeMutablePointer<Int32>
    /// Step k divides the entries below its pivot, rows lRow[lStart[k]..<lStart[k + 1]] at slots lSlot[…], by the pivot,
    /// and subtracts each times the pivot row's entries right of it, columns uColumn[uStart[k]..<uStart[k + 1]] at slots
    /// uSlot[…], from the slots target[…] (opStart[k] on, row by row)
    let lStart, uStart, opStart: UnsafeMutablePointer<Int32>
    let lRow, lSlot, uColumn, uSlot, target: UnsafeMutablePointer<Int32>
    let opCount: Int
    /// The most entries right of a pivot
    private let widest: Int

    /// The relative size a pivot must keep, against the largest entry below it, for the program to be replayed: far
    /// below the threshold it was chosen with (`SparsePlan.threshold`), so a program lasts while values move
    static let replayThreshold = 1e-3

    init(pivots: [(row: Int, column: Int)], below: [[Int32]], right: [[Int32]], slot: (Int, Int) -> Int32) {
        steps = pivots.count
        let lCount = below.reduce(0) { $0 + $1.count }
        let uCount = right.reduce(0) { $0 + $1.count }
        opCount = zip(below, right).reduce(0) { $0 + $1.0.count * $1.1.count }
        pivotRow = .allocate(capacity: max(steps, 1))
        pivotColumn = .allocate(capacity: max(steps, 1))
        diagonal = .allocate(capacity: max(steps, 1))
        lStart = .allocate(capacity: steps + 1)
        uStart = .allocate(capacity: steps + 1)
        opStart = .allocate(capacity: steps + 1)
        lRow = .allocate(capacity: max(lCount, 1))
        lSlot = .allocate(capacity: max(lCount, 1))
        uColumn = .allocate(capacity: max(uCount, 1))
        uSlot = .allocate(capacity: max(uCount, 1))
        target = .allocate(capacity: max(opCount, 1))
        var l = 0, u = 0, op = 0
        for k in 0..<steps {
            let (pr, pc) = pivots[k]
            pivotRow[k] = Int32(pr)
            pivotColumn[k] = Int32(pc)
            diagonal[k] = slot(pr, pc)
            lStart[k] = Int32(l)
            uStart[k] = Int32(u)
            opStart[k] = Int32(op)
            for r in below[k] {
                lRow[l] = r
                lSlot[l] = slot(Int(r), pc)
                l += 1
                for c in right[k] {
                    target[op] = slot(Int(r), Int(c))
                    op += 1
                }
            }
            for c in right[k] {
                uColumn[u] = c
                uSlot[u] = slot(pr, Int(c))
                u += 1
            }
        }
        lStart[steps] = Int32(l)
        uStart[steps] = Int32(u)
        opStart[steps] = Int32(op)
        widest = right.map(\.count).max() ?? 0
    }

    deinit {
        for pointer in [pivotRow, pivotColumn, diagonal, lStart, uStart, opStart, lRow, lSlot, uColumn, uSlot, target] {
            pointer.deallocate()
        }
    }

    /// The slots elimination writes: the entries below each pivot, and those it updates (the fill-in among them)
    var writtenSlots: [Int32] {
        Array(UnsafeBufferPointer(start: lSlot, count: Int(lStart[steps]))) + Array(UnsafeBufferPointer(start: target, count: opCount))
    }

    /// Eliminates in `values`, in place; -1 when done, or the step whose pivot has become too small to use
    func factor(_ values: UnsafeMutablePointer<Double>) -> Int {
        withUnsafeTemporaryAllocation(of: Double.self, capacity: max(widest, 1)) { row in factor(values, row: row.baseAddress!) }
    }

    /// The elimination, each pivot row's entries read once into `row` for all the rows below it
    private func factor(_ values: UnsafeMutablePointer<Double>, row: UnsafeMutablePointer<Double>) -> Int {
        var k = 0
        while k < steps {
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
            let width = u1 - u0
            var i = 0
            while i < width {
                row[i] = values[Int(uSlot[u0 + i])]
                i += 1
            }
            var t = Int(opStart[k])
            j = l0
            while j < l1 {
                let slot = Int(lSlot[j])
                let factor = values[slot] / pivot
                values[slot] = factor
                if factor != 0 {
                    i = 0
                    while i < width {
                        values[Int(target[t])] -= factor * row[i]
                        i += 1
                        t += 1
                    }
                } else {
                    t += width
                }
                j += 1
            }
            k += 1
        }
        return -1
    }

    /// How many values `pack` writes: the factors below the pivots, right of them, and the pivots
    var packedCount: Int { Int(lStart[steps]) + Int(uStart[steps]) + steps }

    /// The factors in `values` (as `factor` left them) gathered in the order substitution reads them: those below the
    /// pivots, then those right of them, then the pivots. Substituting through them then reads memory in order.
    func pack(_ values: UnsafePointer<Double>, into packed: UnsafeMutablePointer<Double>) {
        let lCount = Int(lStart[steps]), uCount = Int(uStart[steps])
        for j in 0..<lCount { packed[j] = values[Int(lSlot[j])] }
        for i in 0..<uCount { packed[lCount + i] = values[Int(uSlot[i])] }
        for k in 0..<steps { packed[lCount + uCount + k] = values[Int(diagonal[k])] }
    }

    /// `forward` with factors packed by `pack`: the same operations in the same order
    func forwardPacked(_ packed: UnsafePointer<Double>, _ b: UnsafeMutablePointer<Double>) {
        var k = 0
        while k < steps {
            let bk = b[Int(pivotRow[k])]
            if bk != 0 {
                var j = Int(lStart[k])
                let l1 = Int(lStart[k + 1])
                while j < l1 {
                    b[Int(lRow[j])] -= packed[j] * bk
                    j += 1
                }
            }
            k += 1
        }
    }

    /// `back` with factors packed by `pack`: the same operations in the same order
    func backPacked(_ packed: UnsafePointer<Double>, _ b: UnsafePointer<Double>, _ x: UnsafeMutablePointer<Double>) -> Double {
        let upper = packed + Int(lStart[steps])
        let pivots = upper + Int(uStart[steps])
        var change = 0.0
        var k = steps - 1
        while k >= 0 {
            var sum = b[Int(pivotRow[k])]
            var i = Int(uStart[k])
            let u1 = Int(uStart[k + 1])
            while i < u1 {
                sum -= upper[i] * x[Int(uColumn[i])]
                i += 1
            }
            let column = Int(pivotColumn[k])
            let next = sum / pivots[k]
            guard next.isFinite else { return .nan }
            change = max(change, abs(next - x[column]) / (1 + abs(next)))
            x[column] = next
            k -= 1
        }
        return change
    }

    /// Forward substitution: `b` (indexed by the equations' rows) becomes L⁻¹ b
    func forward(_ values: UnsafePointer<Double>, _ b: UnsafeMutablePointer<Double>) {
        var k = 0
        while k < steps {
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

    /// Back substitution, last step first, writing the unknowns the pivots' columns stand for into `x` (the unknowns of
    /// later eliminations must be there already). Returns the largest change of an unknown, relative to its new size, or
    /// NaN if one is not a number (then `x` is partly written).
    func back(_ values: UnsafePointer<Double>, _ b: UnsafePointer<Double>, _ x: UnsafeMutablePointer<Double>) -> Double {
        var change = 0.0
        var k = steps - 1
        while k >= 0 {
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

/// How a circuit's equations are factored, worked out once and replayed as Newton-Raphson needs at every iteration.
///
/// Only the entries that can be non-zero are kept, in one array of values, with the fill-in the elimination adds. The
/// pivots are ordered by Markowitz's rule (the pivot whose row and column have the fewest other entries, so the least
/// fill-in) among those within a threshold of the largest in their column (so the elimination stays accurate).
///
/// The unknowns no nonlinear part touches come first (the linear block). Their elimination only involves entries that
/// stay the same through a substep, so it is done once for each base matrix. It leaves the rest (the nonlinear block,
/// with what the linear block contributes to it) for Newton-Raphson to restamp and refactor alone. That block is kept
/// whole (its values the last ones, row by row), and has a few pivot orders: a nonlinear part's entries can change by
/// many decades (an op-amp's gain from its linear range into saturation), so one order cannot suit every state. Each
/// is tried in turn, the last one used first, and an order is made for values none of them suits.
final class SparsePlan {
    let n: Int
    /// Values in the plan: the linear block's entries and fill-in, then the nonlinear block whole
    let entryCount: Int
    /// The first slot of the nonlinear block, the only part Newton-Raphson restamps
    let tailStart: Int
    /// Pivots of the linear block
    let leading: Int
    /// For each unknown, whether it is in the nonlinear block
    let nonlinear: [Bool]
    /// The pattern the plan was made for, without the fill-in (row-major)
    let structure: [Bool]
    /// The slot of each entry (row × n + column), -1 outside the plan
    let slots: UnsafeMutablePointer<Int32>
    /// The same for Newton-Raphson's stamps, but -1 for the nonlinear block's entries outside its structure too: a
    /// stamp there means a new plan, so an iteration only ever changes the structure and what elimination writes
    let stampSlots: UnsafeMutablePointer<Int32>
    /// The nonlinear block's unknowns, in the order of its rows and columns in the values
    let block: [Int]
    /// Entries of the nonlinear block that can be non-zero once the linear block is eliminated (row-major, local)
    let blockStructure: [Bool]
    /// The linear block's elimination
    let linear: EliminationProgram
    /// Pivot orders for the nonlinear block, the last one used first
    private(set) var orders: [EliminationProgram]
    /// The nonlinear block's slots its pivot orders write, and with its structure, all an iteration can change (the
    /// rest keeps the base matrix's values)
    private(set) var writtenSlots: [Int32] = []
    private(set) var changingSlots: [Int32] = []

    /// The relative size, against the largest entry below it in its column, a pivot must have to be chosen
    static let threshold = 0.1
    static let maxOrders = 6

    private init(n: Int, nonlinear: [Bool], structure: [Bool], mask: [Bool], linearPivots: [(row: Int, column: Int)],
                 below: [[Int32]], right: [[Int32]], blockValues: [Double]) {
        let block = (0..<n).filter { nonlinear[$0] }
        let s = block.count
        let slots = UnsafeMutablePointer<Int32>.allocate(capacity: n * n)
        slots.initialize(repeating: -1, count: n * n)
        // the linear block's entries first, then the nonlinear block whole
        var slot: Int32 = 0
        for r in 0..<n {
            for c in 0..<n where mask[r * n + c] && !(nonlinear[r] && nonlinear[c]) {
                slots[r * n + c] = slot
                slot += 1
            }
        }
        let tailStart = Int(slot)
        for (i, r) in block.enumerated() {
            for (j, c) in block.enumerated() { slots[r * n + c] = Int32(tailStart + i * s + j) }
        }
        var blockStructure = [Bool](repeating: false, count: s * s)
        for (i, r) in block.enumerated() {
            for (j, c) in block.enumerated() where mask[r * n + c] { blockStructure[i * s + j] = true }
        }
        self.n = n
        self.nonlinear = nonlinear
        self.structure = structure
        self.slots = slots
        self.entryCount = tailStart + s * s
        self.tailStart = tailStart
        self.leading = n - s
        self.block = block
        self.blockStructure = blockStructure
        let stampSlots = UnsafeMutablePointer<Int32>.allocate(capacity: n * n)
        stampSlots.update(from: slots, count: n * n)
        for (i, r) in block.enumerated() {
            for (j, c) in block.enumerated() where !blockStructure[i * s + j] { stampSlots[r * n + c] = -1 }
        }
        self.stampSlots = stampSlots
        linear = EliminationProgram(pivots: linearPivots, below: below, right: right) { slots[$0 * n + $1] }
        orders = []
        if s == 0 {
            orders = [EliminationProgram(pivots: [], below: [], right: []) { _, _ in 0 }]
        } else if let first = makeOrder(blockValues) {
            orders = [first]
        }
        noteSlots(of: orders)
    }

    deinit {
        slots.deallocate()
        stampSlots.deallocate()
    }

    /// Adds what `programs` write to the slots an iteration can change
    private func noteSlots(of programs: [EliminationProgram]) {
        var written = Set(writtenSlots)
        for program in programs { written.formUnion(program.writtenSlots) }
        writtenSlots = written.sorted()
        let s = block.count
        var changing = written
        for i in 0..<(s * s) where blockStructure[i] { changing.insert(Int32(tailStart + i)) }
        changingSlots = changing.sorted()
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
            var a = Array(matrix[0..<(n * n)])
            var mask = Array(pattern[0..<(n * n)])
            let leading = inS.reduce(0) { $1 ? $0 : $0 + 1 }
            let allowed = inS.map { !$0 }
            switch eliminate(&a, &mask, n: n, steps: leading, allowed: allowed) {
            case .stuck(let unknowns):
                for i in unknowns { inS[i] = true }
            case .done(let pivots, let below, let right):
                let block = (0..<n).filter { inS[$0] }
                var blockValues = [Double](repeating: 0, count: block.count * block.count)
                for (i, r) in block.enumerated() {
                    for (j, c) in block.enumerated() { blockValues[i * block.count + j] = a[r * n + c] }
                }
                let plan = SparsePlan(n: n, nonlinear: inS, structure: Array(pattern[0..<(n * n)]), mask: mask,
                                      linearPivots: pivots, below: below, right: right, blockValues: blockValues)
                // a nonlinear block with no pivot order is singular
                return plan.orders.isEmpty ? nil : plan
            }
        }
        return nil
    }

    private enum Elimination {
        case done(pivots: [(row: Int, column: Int)], below: [[Int32]], right: [[Int32]])
        /// No usable pivot was left among the allowed rows and columns: these allowed unknowns could not be pivoted
        case stuck([Int])
    }

    /// Markowitz's rule with threshold pivoting on `a` (dense, n × n, the entries `mask` allows to be non-zero), for
    /// `steps` pivots among the rows and columns `allowed` marks; eliminates as it goes, marking the fill-in in `mask`
    private static func eliminate(_ a: inout [Double], _ mask: inout [Bool], n: Int, steps: Int, allowed: [Bool]) -> Elimination {
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
        var pivots: [(row: Int, column: Int)] = []
        var below: [[Int32]] = []
        var right: [[Int32]] = []
        pivots.reserveCapacity(steps)
        below.reserveCapacity(steps)
        right.reserveCapacity(steps)
        for _ in 0..<steps {
            var best = (row: -1, column: -1)
            var bestCost = Int.max
            var bestRatio = 0.0
            for c in 0..<n where columnLeft[c] && allowed[c] {
                var largest = 0.0
                for r in rowsOfColumn[c] where rowLeft[Int(r)] { largest = max(largest, abs(a[Int(r) * n + c])) }
                guard largest >= 1e-14 else { continue }
                for r32 in rowsOfColumn[c] {
                    let r = Int(r32)
                    guard rowLeft[r] && allowed[r] else { continue }
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
                // allowed rows left without a usable entry in an allowed column; failing that, all that is left
                var stuck: [Int] = []
                for r in 0..<n where rowLeft[r] && allowed[r] {
                    let usable = columnsOfRow[r].contains { c in
                        columnLeft[Int(c)] && allowed[Int(c)] && abs(a[r * n + Int(c)]) >= 1e-14
                    }
                    if !usable { stuck.append(r) }
                }
                if stuck.isEmpty { stuck = (0..<n).filter { rowLeft[$0] && allowed[$0] } }
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
        return .done(pivots: pivots, below: below, right: right)
    }

    /// A pivot order for the nonlinear block with these values (row-major, local), or nil if they are singular
    private func makeOrder(_ values: [Double]) -> EliminationProgram? {
        let s = block.count
        guard s > 0, values.count >= s * s else { return nil }
        var a = Array(values[0..<(s * s)])
        var mask = blockStructure
        for i in 0..<(s * s) where a[i] != 0 { mask[i] = true }
        guard case .done(let pivots, let below, let right) = Self.eliminate(&a, &mask, n: s, steps: s,
                                                                           allowed: [Bool](repeating: true, count: s)) else {
            return nil
        }
        // in the equations' own rows, columns and slots (every entry of the block has one)
        let block = self.block
        let slots = self.slots
        let n = self.n
        return EliminationProgram(pivots: pivots.map { (block[$0.row], block[$0.column]) },
                                  below: below.map { $0.map { Int32(block[Int($0)]) } },
                                  right: right.map { $0.map { Int32(block[Int($0)]) } }) { r, c in slots[r * n + c] }
    }

    // MARK: - Replaying

    /// Factors the nonlinear block of `values` with the first pivot order that suits it, the last one used tried first,
    /// or a new one made for it; `scratch` (as long as the block) keeps the block's values to go back to between tries.
    /// The order used, or nil if the block is singular.
    func factorBlock(_ values: UnsafeMutablePointer<Double>, scratch: UnsafeMutablePointer<Double>) -> EliminationProgram? {
        let count = entryCount - tailStart
        if count == 0 { return orders.first }
        // only what elimination writes changes: that much is kept to go back to
        let written = writtenSlots
        let saved = written.count
        written.withUnsafeBufferPointer { slots in
            for k in 0..<saved { scratch[k] = values[Int(slots[k])] }
        }
        func restore() {
            written.withUnsafeBufferPointer { slots in
                for k in 0..<saved { values[Int(slots[k])] = scratch[k] }
            }
        }
        for (index, order) in orders.enumerated() {
            if index > 0 { restore() }
            if order.factor(values) < 0 {
                if index > 0 { orders.insert(orders.remove(at: index), at: 0) }
                return order
            }
        }
        restore()
        guard let made = makeOrder(Array(UnsafeBufferPointer(start: values + tailStart, count: count))) else { return nil }
        orders.insert(made, at: 0)
        if orders.count > Self.maxOrders { orders.removeLast() }
        noteSlots(of: [made])
        // made for these very values, it suits them (unless they are on the edge of singular)
        guard made.factor(values) < 0 else { return nil }
        return made
    }

    /// Pivot orders made for the nonlinear block so far, at most `maxOrders` kept
    var orderCount: Int { orders.count }

    /// The entries below and right of the pivots the last pivot order used goes through (L and U, without the
    /// diagonal), and the multiply-adds of factoring with it: what each substitution and factoring costs
    var blockFactorSize: (lower: Int, upper: Int, operations: Int) {
        guard let order = orders.first else { return (0, 0, 0) }
        return (Int(order.lStart[order.steps]), Int(order.uStart[order.steps]), order.opCount)
    }

    /// Puts the base matrix's values back where an iteration can have changed them
    func restoreChanging(_ values: UnsafeMutablePointer<Double>, from base: UnsafePointer<Double>) {
        changingSlots.withUnsafeBufferPointer { slots in
            for slot in slots { values[Int(slot)] = base[Int(slot)] }
        }
    }
}

/// Every element's nodes in one block: the loops that run at every Newton-Raphson iteration read an element's without
/// retaining an array of its own (taken into a local first, so the block itself is retained once per loop)
final class NodeLists {
    private let block: UnsafeMutablePointer<Int>
    private let starts: UnsafeMutablePointer<Int>

    init(_ lists: [[Int]] = []) {
        starts = .allocate(capacity: lists.count + 1)
        block = .allocate(capacity: max(lists.reduce(0) { $0 + $1.count }, 1))
        var at = 0
        for (i, list) in lists.enumerated() {
            starts[i] = at
            for node in list {
                block[at] = node
                at += 1
            }
        }
        starts[lists.count] = at
    }

    deinit {
        block.deallocate()
        starts.deallocate()
    }

    @inline(__always) subscript(_ i: Int) -> NodeList {
        NodeList(base: block + starts[i], count: starts[i + 1] - starts[i])
    }
}

/// One element's nodes, as `NodeLists` gives them
struct NodeList {
    let base: UnsafeMutablePointer<Int>
    let count: Int

    @inline(__always) subscript(_ k: Int) -> Int {
        assert(k >= 0 && k < count, "terminal \(k) of \(count)")
        return base[k]
    }
}
