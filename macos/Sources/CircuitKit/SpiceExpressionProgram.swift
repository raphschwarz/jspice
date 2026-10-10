import Foundation

extension SpiceExpression {
    /// The expression and its slopes in every input compiled into one list of steps, each working out one value from
    /// earlier ones. A part the value and its slopes share (the exp(x) of exp(x) and of its slope exp(x)·x') is worked
    /// out once, and running it walks an array instead of trees. It gives what `value` and `slope` give, to the last bit:
    /// the same operations on the same values, in the same order. Its steps are kept in memory of its own, so running it
    /// (at every Newton-Raphson iteration) touches no reference counts.
    public final class Program: @unchecked Sendable {
        /// One step: what it works out, from which earlier steps (by number). The arithmetic operators have steps of
        /// their own, so a step is one dispatch.
        enum Step: Sendable {
            case constant(Double)
            /// An input, as it is (`x`) or as decisions are held at (`d`)
            case input(Int32)
            case decidingInput(Int32)
            case time
            case temperature
            case negate(Int32)
            case not(Int32)
            case add(Int32, Int32)
            case subtract(Int32, Int32)
            case multiply(Int32, Int32)
            case divide(Int32, Int32)
            /// A power, comparison or logical operator
            case binary(Operator, Int32, Int32)
            /// A function of one to three earlier steps (-1 for an argument it does not take)
            case call(Function, Int32, Int32, Int32)
            /// The second step's value where the first's is not 0, else the third's
            case select(Int32, Int32, Int32)
            /// A table's line, or its slope: the argument's step, then where its points' x and y values start in
            /// `data`, and how many there are
            case table(Int32, Int32, Int32, Int32)
            case tableSlope(Int32, Int32, Int32, Int32)
        }

        private let steps: UnsafeMutablePointer<Step>
        private let data: UnsafeMutablePointer<Double>
        /// The step that gives the value, and those that give each input's slope
        public let value: Int
        public let slopes: [Int]
        /// The same as `slopes`, for the simulator's inner loop
        let slopeSteps: UnsafeMutablePointer<Int>
        /// How many values running it writes
        public let count: Int
        /// Whether it reads the time (its value can change while its inputs stay)
        public let readsTime: Bool
        /// Whether it is made of straight lines in its inputs between its decisions: nothing curved (exp, a power, sin…)
        /// of anything that reads an input, and not the time (see `straightReach`)
        public let piecewiseLinear: Bool

        /// What it is made of, without its numbers: the functions, comparisons and tables in it, its steps and inputs,
        /// and whether it is straight lines between decisions (for a report on where evaluation goes)
        public var outline: String {
            var kinds: [String] = []
            for k in 0..<count {
                let kind: String?
                switch steps[k] {
                case let .call(f, _, _, _): kind = f.rawValue
                case let .binary(op, _, _): kind = op.rawValue
                case .select: kind = "if"
                case .table, .tableSlope: kind = "table"
                case .not: kind = "!"
                case .multiply: kind = "*"
                case .divide: kind = "/"
                default: kind = nil
                }
                if let kind, !kinds.contains(kind) { kinds.append(kind) }
            }
            return "\(kinds.joined(separator: " ")); \(count) steps, \(slopes.count) inputs\(piecewiseLinear ? "" : ", curved")"
        }

        /// The functions that are straight lines in their arguments but where they decide (a corner or a jump)
        static let straightFunctions: Set<Function> = [.abs, .u, .sgn, .floor, .ceil, .uramp, .min, .max, .limit]

        public init(_ expression: SpiceExpression) {
            var compiler = Compiler()
            value = compiler.compile(expression.root, .normal)
            slopes = expression.slopes.map { compiler.compile($0, .normal) }
            count = compiler.steps.count
            readsTime = compiler.steps.contains { if case .time = $0 { return true } else { return false } }
            // which steps read an input, and whether any of those is curved
            var reads = [Bool](repeating: false, count: compiler.steps.count)
            var straight = !readsTime
            for (k, step) in compiler.steps.enumerated() {
                switch step {
                case .input, .decidingInput: reads[k] = true
                case .constant, .time, .temperature: reads[k] = false
                case let .negate(a), let .not(a): reads[k] = reads[Int(a)]
                case let .add(a, b), let .subtract(a, b), let .multiply(a, b), let .divide(a, b):
                    reads[k] = reads[Int(a)] || reads[Int(b)]
                case let .binary(op, a, b):
                    reads[k] = reads[Int(a)] || reads[Int(b)]
                    if op == .power && reads[k] { straight = false }
                case let .call(f, a, b, c):
                    reads[k] = reads[Int(a)] || (b >= 0 && reads[Int(b)]) || (c >= 0 && reads[Int(c)])
                    if reads[k] && !Self.straightFunctions.contains(f) { straight = false }
                case let .select(c, a, b): reads[k] = reads[Int(c)] || reads[Int(a)] || reads[Int(b)]
                case let .table(a, _, _, _), let .tableSlope(a, _, _, _): reads[k] = reads[Int(a)]
                }
            }
            piecewiseLinear = straight
            steps = .allocate(capacity: max(count, 1))
            steps.initialize(from: compiler.steps, count: count)
            data = .allocate(capacity: max(compiler.data.count, 1))
            data.initialize(from: compiler.data, count: compiler.data.count)
            slopeSteps = .allocate(capacity: max(slopes.count, 1))
            slopeSteps.initialize(from: slopes, count: slopes.count)
        }

        deinit {
            steps.deallocate()
            data.deallocate()
            slopeSteps.deallocate()
        }

        /// Runs it at inputs `x`, with decisions made at `deciding` (at `x` when nil), writing each step's value to
        /// `results` (at least `count` long): the value is `results[value]`, input k's slope `results[slopes[k]]`
        public func run(_ x: UnsafePointer<Double>, deciding: UnsafePointer<Double>? = nil, time: Double = 0, celsius: Double = 27,
                        into results: UnsafeMutablePointer<Double>) {
            let d = deciding ?? x
            let r = results
            let steps = self.steps, table = self.data
            for k in 0..<count {
                switch steps[k] {
                case let .constant(c): r[k] = c
                case let .input(j): r[k] = x[Int(j)]
                case let .decidingInput(j): r[k] = d[Int(j)]
                case .time: r[k] = time
                case .temperature: r[k] = celsius
                case let .negate(a): r[k] = -r[Int(a)]
                case let .not(a): r[k] = r[Int(a)] != 0 ? 0 : 1
                case let .add(a, b): r[k] = r[Int(a)] + r[Int(b)]
                case let .subtract(a, b): r[k] = r[Int(a)] - r[Int(b)]
                case let .multiply(a, b): r[k] = r[Int(a)] * r[Int(b)]
                case let .divide(a, b): r[k] = SpiceExpression.arithmetic(.divide, r[Int(a)], r[Int(b)])
                case let .binary(op, a, b): r[k] = SpiceExpression.arithmetic(op, r[Int(a)], r[Int(b)])
                case let .call(f, a, b, c):
                    r[k] = SpiceExpression.apply(f, r[Int(a)], b >= 0 ? r[Int(b)] : 0, c >= 0 ? r[Int(c)] : 0)
                case let .select(c, a, b): r[k] = r[Int(c)] != 0 ? r[Int(a)] : r[Int(b)]
                case let .table(a, xs, ys, n):
                    r[k] = SpiceExpression.lookup(r[Int(a)], table + Int(xs), table + Int(ys), Int(n))
                case let .tableSlope(a, xs, ys, n):
                    r[k] = SpiceExpression.lookupSlope(r[Int(a)], table + Int(xs), table + Int(ys), Int(n))
                }
            }
        }

        /// How far the inputs can move (the largest change of any of them, and of the inputs its decisions are made at)
        /// from those of the run that wrote `results` with every decision in it staying as it was: the value and its
        /// slopes are straight lines in the inputs that far, the slopes the same, so a stamp made from the run stays
        /// exactly as it was. Infinity where nothing in it decides; 0 where something curves (a product of two moving
        /// values) or is not a number.
        ///
        /// Each step's rate, the most its value can move for each volt the inputs move, goes into `rates` (at least
        /// `count` long), and each decision's margin bounds the reach: how far its argument is from where it flips,
        /// over the argument's rate.
        public func straightReach(_ results: UnsafePointer<Double>, rates: UnsafeMutablePointer<Double>) -> Double {
            guard piecewiseLinear, results[value].isFinite else { return 0 }
            for k in 0..<slopes.count where !results[slopeSteps[k]].isFinite { return 0 }
            let r = results, s = rates
            let steps = self.steps, table = self.data
            var reach = Double.infinity
            var unsure = false
            func margin(_ distance: Double, _ rate: Double) {
                if rate == 0 { return }
                let m = Swift.abs(distance) / rate
                if m < reach { reach = m } else if m.isNaN { unsure = true }
            }
            for k in 0..<count {
                switch steps[k] {
                case .constant, .time, .temperature: s[k] = 0
                case .input, .decidingInput: s[k] = 1
                case let .negate(a): s[k] = s[Int(a)]
                case let .not(a):
                    margin(r[Int(a)], s[Int(a)])
                    s[k] = 0
                case let .add(a, b), let .subtract(a, b): s[k] = s[Int(a)] + s[Int(b)]
                case let .multiply(a, b):
                    let (sa, sb) = (s[Int(a)], s[Int(b)])
                    if sa == 0 {
                        s[k] = sb == 0 ? 0 : Swift.abs(r[Int(a)]) * sb
                    } else if sb == 0 {
                        s[k] = Swift.abs(r[Int(b)]) * sa
                    } else {
                        return 0
                    }
                case let .divide(a, b):
                    let (sa, sb) = (s[Int(a)], s[Int(b)])
                    guard sb == 0 else { return 0 }
                    if sa == 0 {
                        s[k] = 0
                    } else {
                        // (by 0, the quotient jumps from one huge value to the other as its numerator's sign changes)
                        let denominator = Swift.abs(r[Int(b)])
                        guard denominator > 0 else { return 0 }
                        s[k] = sa / denominator
                    }
                case let .binary(op, a, b):
                    let (sa, sb) = (s[Int(a)], s[Int(b)])
                    switch op {
                    case .less, .greater, .lessEqual, .greaterEqual, .equal, .notEqual:
                        margin(r[Int(a)] - r[Int(b)], sa + sb)
                    case .and, .or:
                        margin(r[Int(a)], sa)
                        margin(r[Int(b)], sb)
                    default:
                        // a power, of values that do not move
                        guard sa == 0 && sb == 0 else { return 0 }
                    }
                    s[k] = 0
                case let .call(f, a, b, c):
                    let sa = s[Int(a)], sb = b >= 0 ? s[Int(b)] : 0, sc = c >= 0 ? s[Int(c)] : 0
                    let va = r[Int(a)]
                    switch f {
                    case .abs, .uramp:
                        margin(va, sa)
                        s[k] = sa
                    case .u, .sgn:
                        margin(va, sa)
                        s[k] = 0
                    case .floor, .ceil:
                        margin(Swift.min(va - va.rounded(.down), va.rounded(.up) - va), sa)
                        s[k] = 0
                    case .min, .max:
                        margin(va - (b >= 0 ? r[Int(b)] : 0), sa + sb)
                        s[k] = Swift.max(sa, sb)
                    case .limit:
                        let (vb, vc) = (b >= 0 ? r[Int(b)] : 0, c >= 0 ? r[Int(c)] : 0)
                        margin(vb - vc, sb + sc)
                        margin(va - vb, sa + sb)
                        margin(va - vc, sa + sc)
                        s[k] = Swift.max(Swift.max(sa, sb), sc)
                    default:
                        // curved, of values that do not move
                        guard sa == 0 && sb == 0 && sc == 0 else { return 0 }
                        s[k] = 0
                    }
                case let .select(c, a, b):
                    margin(r[Int(c)], s[Int(c)])
                    s[k] = r[Int(c)] != 0 ? s[Int(a)] : s[Int(b)]
                case let .table(a, first, second, n), let .tableSlope(a, first, second, n):
                    let sa = s[Int(a)], v = r[Int(a)], points = Int(n)
                    let xs = table + Int(first), ys = table + Int(second)
                    // the distance to the nearest point, where the line's slope changes, and the slope
                    var slope = 0.0
                    if points > 0 && v <= xs[0] {
                        margin(xs[0] - v, sa)
                    } else if points > 0 && v >= xs[points - 1] {
                        margin(v - xs[points - 1], sa)
                    } else if points > 1 {
                        var lo = 0, hi = points - 1
                        while hi - lo > 1 {
                            let mid = (lo + hi) / 2
                            if xs[mid] <= v { lo = mid } else { hi = mid }
                        }
                        margin(Swift.min(v - xs[lo], xs[hi] - v), sa)
                        slope = Swift.abs((ys[hi] - ys[lo]) / (xs[hi] - xs[lo]))
                    }
                    if case .table = steps[k] { s[k] = sa == 0 ? 0 : slope * sa } else { s[k] = 0 }
                }
            }
            return unsure || reach.isNaN ? 0 : reach
        }
    }

    /// Where a node is worked out from: the inputs as they are, with decisions at the held inputs (`normal`, as `value`
    /// starts); everything at the held inputs (`decided`, inside a decision); or everything at the inputs as they are
    /// (`live`, a continuous function's slope's condition)
    enum Reading: Hashable {
        case normal, decided, live

        /// Inside a decision: `evaluate(a, d, d)`
        var deciding: Reading { self == .normal ? .decided : self }
        /// Inside `live`: `evaluate(a, x, x)`
        var living: Reading { self == .normal ? .live : self }
    }

    private struct Compiler {
        struct Key: Hashable {
            var node: Node
            var reading: Reading
        }

        var steps: [Program.Step] = []
        var data: [Double] = []
        var made: [Key: Int] = [:]

        mutating func emit(_ step: Program.Step) -> Int {
            steps.append(step)
            return steps.count - 1
        }

        /// The step that gives `node`'s value read as `reading` says, made once for each node and reading
        mutating func compile(_ node: Node, _ reading: Reading) -> Int {
            let key = Key(node: node, reading: reading)
            if let made = made[key] { return made }
            let step: Int
            switch node {
            case let .constant(c):
                step = emit(.constant(c))
            case let .input(k):
                step = emit(reading == .decided ? .decidingInput(Int32(k)) : .input(Int32(k)))
            case .time:
                step = emit(.time)
            case .temperature:
                step = emit(.temperature)
            case let .negate(a):
                let u = compile(a, reading)
                step = emit(.negate(Int32(u)))
            case let .not(a):
                let u = compile(a, reading.deciding)
                step = emit(.not(Int32(u)))
            case let .live(a):
                step = compile(a, reading.living)
            case let .binary(op, a, b):
                let operands: Reading
                switch op {
                case .add, .subtract, .multiply, .divide, .power: operands = reading
                default: operands = reading.deciding
                }
                let u = Int32(compile(a, operands))
                let v = Int32(compile(b, operands))
                switch op {
                case .add: step = emit(.add(u, v))
                case .subtract: step = emit(.subtract(u, v))
                case .multiply: step = emit(.multiply(u, v))
                case .divide: step = emit(.divide(u, v))
                default: step = emit(.binary(op, u, v))
                }
            case let .call(f, args):
                switch f {
                case .u, .sgn, .floor, .ceil:
                    let u = compile(args[0], reading.deciding)
                    step = emit(.call(f, Int32(u), -1, -1))
                default:
                    let u = compile(args[0], reading)
                    let v = args.count > 1 ? compile(args[1], reading) : -1
                    let w = args.count > 2 ? compile(args[2], reading) : -1
                    step = emit(.call(f, Int32(u), Int32(v), Int32(w)))
                }
            case let .conditional(c, a, b):
                let condition: Int
                if case let .live(inner) = c {
                    condition = compile(inner, reading.living)
                } else {
                    condition = compile(c, reading.deciding)
                }
                let u = compile(a, reading)
                let v = compile(b, reading)
                step = emit(.select(Int32(condition), Int32(u), Int32(v)))
            case let .table(a, xs, ys), let .tableSlope(a, xs, ys):
                let u = compile(a, reading)
                let start = data.count
                data += xs
                data += ys
                let (argument, first, second, points) = (Int32(u), Int32(start), Int32(start + xs.count), Int32(xs.count))
                if case .table = node {
                    step = emit(.table(argument, first, second, points))
                } else {
                    step = emit(.tableSlope(argument, first, second, points))
                }
            }
            made[key] = step
            return step
        }
    }
}
