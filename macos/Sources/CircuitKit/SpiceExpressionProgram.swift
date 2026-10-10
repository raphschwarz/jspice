import Foundation

extension SpiceExpression {
    /// The expression and its slopes in every input compiled into one list of steps, each working out one value from
    /// earlier ones. A part the value and its slopes share (the exp(x) of exp(x) and of its slope exp(x)·x') is worked
    /// out once, and running it walks an array instead of trees. It gives what `value` and `slope` give, to the last bit:
    /// the same operations on the same values, in the same order. Its steps are kept in memory of its own, so running it
    /// (at every Newton-Raphson iteration) touches no reference counts.
    public final class Program: @unchecked Sendable {
        enum Step: Sendable {
            case constant(Double)
            /// An input, as it is (`x`) or as decisions are held at (`d`)
            case input(Int)
            case decidingInput(Int)
            case time
            case temperature
            case negate(Int)
            case not(Int)
            case binary(Operator, Int, Int)
            /// A function of one to three earlier steps (-1 for an argument it does not take)
            case call(Function, Int, Int, Int)
            /// The second step's value where the first's is not 0, else the third's
            case select(Int, Int, Int)
            /// A table's line, or its slope: the argument's step, then where its points' x and y values start in
            /// `data`, and how many there are
            case table(Int, Int, Int, Int)
            case tableSlope(Int, Int, Int, Int)
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

        public init(_ expression: SpiceExpression) {
            var compiler = Compiler()
            value = compiler.compile(expression.root, .normal)
            slopes = expression.slopes.map { compiler.compile($0, .normal) }
            count = compiler.steps.count
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
                case let .input(j): r[k] = x[j]
                case let .decidingInput(j): r[k] = d[j]
                case .time: r[k] = time
                case .temperature: r[k] = celsius
                case let .negate(a): r[k] = -r[a]
                case let .not(a): r[k] = r[a] != 0 ? 0 : 1
                case let .binary(op, a, b): r[k] = SpiceExpression.arithmetic(op, r[a], r[b])
                case let .call(f, a, b, c):
                    r[k] = SpiceExpression.apply(f, r[a], b >= 0 ? r[b] : 0, c >= 0 ? r[c] : 0)
                case let .select(c, a, b): r[k] = r[c] != 0 ? r[a] : r[b]
                case let .table(a, xs, ys, n):
                    r[k] = SpiceExpression.lookup(r[a], table + xs, table + ys, n)
                case let .tableSlope(a, xs, ys, n):
                    r[k] = SpiceExpression.lookupSlope(r[a], table + xs, table + ys, n)
                }
            }
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
                step = emit(reading == .decided ? .decidingInput(k) : .input(k))
            case .time:
                step = emit(.time)
            case .temperature:
                step = emit(.temperature)
            case let .negate(a):
                let u = compile(a, reading)
                step = emit(.negate(u))
            case let .not(a):
                let u = compile(a, reading.deciding)
                step = emit(.not(u))
            case let .live(a):
                step = compile(a, reading.living)
            case let .binary(op, a, b):
                let operands: Reading
                switch op {
                case .add, .subtract, .multiply, .divide, .power: operands = reading
                default: operands = reading.deciding
                }
                let u = compile(a, operands)
                let v = compile(b, operands)
                step = emit(.binary(op, u, v))
            case let .call(f, args):
                switch f {
                case .u, .sgn, .floor, .ceil:
                    let u = compile(args[0], reading.deciding)
                    step = emit(.call(f, u, -1, -1))
                default:
                    let u = compile(args[0], reading)
                    let v = args.count > 1 ? compile(args[1], reading) : -1
                    let w = args.count > 2 ? compile(args[2], reading) : -1
                    step = emit(.call(f, u, v, w))
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
                step = emit(.select(condition, u, v))
            case let .table(a, xs, ys), let .tableSlope(a, xs, ys):
                let u = compile(a, reading)
                let start = data.count
                data += xs
                data += ys
                if case .table = node {
                    step = emit(.table(u, start, start + xs.count, xs.count))
                } else {
                    step = emit(.tableSlope(u, start, start + xs.count, xs.count))
                }
            }
            made[key] = step
            return step
        }
    }
}
