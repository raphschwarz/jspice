import Foundation

/// An expression of a behavioural source: SPICE's B source (`V=` or `I=`), and E, F, G and H sources with `VALUE`,
/// `POLY` or `TABLE`. It reads voltages between nets (`V(a)`, `V(a,b)`), currents through voltage sources (`I(Vx)`), the
/// time and the temperature, with SPICE's operators and functions. It is parsed once into a tree, and differentiated
/// symbolically in each input once, so that Newton-Raphson gets exact slopes and evaluating allocates nothing.
public struct SpiceExpression: Hashable, Sendable {
    /// What an input is: the voltage of a net (to ground, or to a second net), or the current through a named source
    public enum Input: Hashable, Sendable {
        case voltage(String, String?)
        case current(String)
    }

    public indirect enum Node: Hashable, Sendable {
        case constant(Double)
        case input(Int)
        case time
        case temperature
        case negate(Node)
        case not(Node)
        case binary(Operator, Node, Node)
        case call(Function, [Node])
        case conditional(Node, Node, Node)
        /// Straight lines between points (x ascending), flat beyond the ends
        case table(Node, [Double], [Double])
        /// The slope of the line a table's argument is on (0 beyond the ends)
        case tableSlope(Node, [Double], [Double])
    }

    public enum Operator: String, Hashable, Sendable {
        case add = "+", subtract = "-", multiply = "*", divide = "/", power = "^"
        case less = "<", greater = ">", lessEqual = "<=", greaterEqual = ">=", equal = "==", notEqual = "!="
        case and = "&&", or = "||"
    }

    public enum Function: String, Hashable, Sendable, CaseIterable {
        case abs, sqrt, exp, ln, log, log10, sin, cos, tan, asin, acos, atan, sinh, cosh, tanh, min, max, pow, pwr, pwrs
        case limit, u, uramp, sgn, floor, ceil, atan2
    }

    public enum ParseError: Error, CustomStringConvertible {
        case unexpected(String, at: String)
        case unknown(String)
        public var description: String {
            switch self {
            case let .unexpected(what, at): return "unexpected \(what) at \"\(at)\""
            case let .unknown(name): return "unknown \(name)"
            }
        }
    }

    public let root: Node
    public let inputs: [Input]
    /// The derivative of the expression in each input, in order
    public let slopes: [Node]

    public init(root: Node, inputs: [Input]) {
        self.root = Self.fold(root)
        self.inputs = inputs
        slopes = inputs.indices.map { Self.fold(Self.derivative(of: root, in: $0)) }
    }

    /// Parses SPICE's syntax (`{` `}` around it are left out); names in `parameters` are constants
    public init(parsing text: String, parameters: [String: Double] = [:]) throws {
        var parser = Parser(text, parameters: parameters)
        let root = try parser.parseExpression()
        guard parser.atEnd else { throw ParseError.unexpected("text", at: parser.rest) }
        self.init(root: root, inputs: parser.inputs)
    }

    /// A SPICE POLY(n): the polynomial of `values` (the inputs, in order) with coefficients `coefficients` in SPICE's order:
    /// the constant, the linear terms, then the products of two in order (x1², x1 x2, …, x2², …), then of three
    public static func polynomial(dimensions n: Int, coefficients: [Double], inputs: [Input]) -> SpiceExpression {
        var terms: [Node] = []
        var k = 0
        func term(_ factors: [Int]) {
            defer { k += 1 }
            guard k < coefficients.count, coefficients[k] != 0 else { return }
            var node = Node.constant(coefficients[k])
            for f in factors { node = .binary(.multiply, node, .input(f)) }
            terms.append(node)
        }
        term([])
        var degree = 1
        var combinations: [[Int]] = [[]]
        while k < coefficients.count && degree <= 6 {
            // the next degree's products, each a non-decreasing list of inputs, in SPICE's order
            var next: [[Int]] = []
            for c in combinations {
                for j in (c.last ?? 0)..<n { next.append(c + [j]) }
            }
            combinations = next
            for c in combinations { term(c) }
            degree += 1
        }
        let root = terms.dropFirst().reduce(terms.first ?? .constant(0)) { .binary(.add, $0, $1) }
        return SpiceExpression(root: root, inputs: inputs)
    }

    // MARK: Evaluation

    /// The value, with `inputs` the values of the inputs in order
    @inline(__always) public func value(_ inputs: UnsafePointer<Double>, time: Double = 0, celsius: Double = 27) -> Double {
        Self.evaluate(root, inputs, time, celsius)
    }

    /// The slope in input `k`
    @inline(__always) public func slope(_ k: Int, _ inputs: UnsafePointer<Double>, time: Double = 0, celsius: Double = 27) -> Double {
        Self.evaluate(slopes[k], inputs, time, celsius)
    }

    /// The value with no inputs (a parameter's, or a constant element value's)
    public var constantValue: Double? {
        guard inputs.isEmpty else { return nil }
        return withUnsafePointer(to: 0.0) { value($0) }
    }

    static func evaluate(_ node: Node, _ x: UnsafePointer<Double>, _ time: Double, _ celsius: Double) -> Double {
        switch node {
        case let .constant(c): return c
        case let .input(k): return x[k]
        case .time: return time
        case .temperature: return celsius
        case let .negate(a): return -evaluate(a, x, time, celsius)
        case let .not(a): return evaluate(a, x, time, celsius) != 0 ? 0 : 1
        case let .binary(op, a, b):
            let u = evaluate(a, x, time, celsius)
            // the logical operators look at their second operand only when they must
            switch op {
            case .and: return u != 0 && evaluate(b, x, time, celsius) != 0 ? 1 : 0
            case .or: return u != 0 || evaluate(b, x, time, celsius) != 0 ? 1 : 0
            default: break
            }
            let v = evaluate(b, x, time, celsius)
            switch op {
            case .add: return u + v
            case .subtract: return u - v
            case .multiply: return u * v
            case .divide: return v == 0 ? (u == 0 ? 0 : u.sign == .minus ? -1e300 : 1e300) : u / v
            case .power: return pow(u, v)
            case .less: return u < v ? 1 : 0
            case .greater: return u > v ? 1 : 0
            case .lessEqual: return u <= v ? 1 : 0
            case .greaterEqual: return u >= v ? 1 : 0
            case .equal: return u == v ? 1 : 0
            case .notEqual: return u != v ? 1 : 0
            case .and, .or: return 0
            }
        case let .call(f, args):
            let a = evaluate(args[0], x, time, celsius)
            switch f {
            case .abs: return Swift.abs(a)
            case .sqrt: return a > 0 ? a.squareRoot() : 0
            case .exp: return Foundation.exp(Swift.min(a, 700))
            case .ln, .log: return a > 0 ? Foundation.log(a) : -1e300
            case .log10: return a > 0 ? Foundation.log10(a) : -1e300
            case .sin: return Foundation.sin(a)
            case .cos: return Foundation.cos(a)
            case .tan: return Foundation.tan(a)
            case .asin: return Foundation.asin(Swift.min(Swift.max(a, -1), 1))
            case .acos: return Foundation.acos(Swift.min(Swift.max(a, -1), 1))
            case .atan: return Foundation.atan(a)
            case .sinh: return Foundation.sinh(Swift.min(Swift.max(a, -700), 700))
            case .cosh: return Foundation.cosh(Swift.min(Swift.max(a, -700), 700))
            case .tanh: return Foundation.tanh(a)
            case .min: return Swift.min(a, evaluate(args[1], x, time, celsius))
            case .max: return Swift.max(a, evaluate(args[1], x, time, celsius))
            case .pow: return Foundation.pow(a, evaluate(args[1], x, time, celsius))
            case .pwr: return Foundation.pow(Swift.abs(a), evaluate(args[1], x, time, celsius))
            case .pwrs:
                let p = Foundation.pow(Swift.abs(a), evaluate(args[1], x, time, celsius))
                return a < 0 ? -p : p
            case .limit:
                let lo = evaluate(args[1], x, time, celsius), hi = evaluate(args[2], x, time, celsius)
                return Swift.min(Swift.max(a, Swift.min(lo, hi)), Swift.max(lo, hi))
            case .u: return a > 0 ? 1 : 0
            case .uramp: return a > 0 ? a : 0
            case .sgn: return a > 0 ? 1 : a < 0 ? -1 : 0
            case .floor: return a.rounded(.down)
            case .ceil: return a.rounded(.up)
            case .atan2: return Foundation.atan2(a, evaluate(args[1], x, time, celsius))
            }
        case let .conditional(c, a, b):
            return evaluate(c, x, time, celsius) != 0 ? evaluate(a, x, time, celsius) : evaluate(b, x, time, celsius)
        case let .table(a, xs, ys):
            let v = evaluate(a, x, time, celsius)
            guard let first = xs.first, let last = xs.last else { return 0 }
            if v <= first { return ys[0] }
            if v >= last { return ys[ys.count - 1] }
            var lo = 0, hi = xs.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if xs[mid] <= v { lo = mid } else { hi = mid }
            }
            return ys[lo] + (v - xs[lo]) / (xs[hi] - xs[lo]) * (ys[hi] - ys[lo])
        case let .tableSlope(a, xs, ys):
            let v = evaluate(a, x, time, celsius)
            guard xs.count > 1, v > xs[0], v < xs[xs.count - 1] else { return 0 }
            var lo = 0, hi = xs.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if xs[mid] <= v { lo = mid } else { hi = mid }
            }
            return (ys[hi] - ys[lo]) / (xs[hi] - xs[lo])
        }
    }

    /// A node without inputs evaluated
    private static func constant(_ node: Node) -> Double {
        withUnsafePointer(to: 0.0) { evaluate(node, $0, 0, 27) }
    }

    // MARK: Differentiation

    static func derivative(of node: Node, in k: Int) -> Node {
        func d(_ n: Node) -> Node { derivative(of: n, in: k) }
        func mul(_ a: Node, _ b: Node) -> Node { .binary(.multiply, a, b) }
        func add(_ a: Node, _ b: Node) -> Node { .binary(.add, a, b) }
        func sub(_ a: Node, _ b: Node) -> Node { .binary(.subtract, a, b) }
        func div(_ a: Node, _ b: Node) -> Node { .binary(.divide, a, b) }
        func call(_ f: Function, _ args: Node...) -> Node { .call(f, args) }
        switch node {
        case .constant, .time, .temperature, .not, .tableSlope: return .constant(0)
        case let .input(j): return .constant(j == k ? 1 : 0)
        case let .negate(a): return .negate(d(a))
        case let .binary(op, a, b):
            switch op {
            case .add: return add(d(a), d(b))
            case .subtract: return sub(d(a), d(b))
            case .multiply: return add(mul(d(a), b), mul(a, d(b)))
            case .divide: return div(sub(mul(d(a), b), mul(a, d(b))), mul(b, b))
            case .power:
                // a^b (b' ln a + b a' / a); with a constant exponent, b a^(b-1) a'
                if fold(d(b)) == .constant(0) {
                    return mul(mul(b, .binary(.power, a, sub(b, .constant(1)))), d(a))
                }
                return mul(node, add(mul(d(b), call(.ln, a)), div(mul(b, d(a)), a)))
            default: return .constant(0)
            }
        case let .call(f, args):
            let a = args[0], da = d(a)
            switch f {
            case .abs: return mul(call(.sgn, a), da)
            case .sqrt: return div(da, mul(.constant(2), node))
            case .exp: return mul(node, da)
            case .ln, .log: return div(da, a)
            case .log10: return div(da, mul(a, .constant(Foundation.log(10))))
            case .sin: return mul(call(.cos, a), da)
            case .cos: return .negate(mul(call(.sin, a), da))
            case .tan: return div(da, mul(call(.cos, a), call(.cos, a)))
            case .asin: return div(da, call(.sqrt, sub(.constant(1), mul(a, a))))
            case .acos: return .negate(div(da, call(.sqrt, sub(.constant(1), mul(a, a)))))
            case .atan: return div(da, add(.constant(1), mul(a, a)))
            case .sinh: return mul(call(.cosh, a), da)
            case .cosh: return mul(call(.sinh, a), da)
            case .tanh: return mul(sub(.constant(1), mul(node, node)), da)
            case .min: return .conditional(.binary(.lessEqual, a, args[1]), da, d(args[1]))
            case .max: return .conditional(.binary(.greaterEqual, a, args[1]), da, d(args[1]))
            case .pow:
                return derivative(of: .binary(.power, a, args[1]), in: k)
            case .pwr, .pwrs:
                // |a|^b: b |a|^(b-1) sgn(a) a' (for pwrs, b |a|^(b-1) a'), plus the exponent's part
                let b = args[1]
                let base = mul(b, call(.pwr, a, sub(b, .constant(1))))
                let first = f == .pwr ? mul(mul(base, call(.sgn, a)), da) : mul(base, da)
                return add(first, mul(mul(node, call(.ln, call(.abs, a))), d(b)))
            case .limit:
                let lo = args[1], hi = args[2]
                let low = call(.min, lo, hi), high = call(.max, lo, hi)
                return .conditional(.binary(.less, a, low), d(.call(.min, [lo, hi])),
                                    .conditional(.binary(.greater, a, high), d(.call(.max, [lo, hi])), da))
            case .uramp: return mul(call(.u, a), da)
            case .u, .sgn, .floor, .ceil: return .constant(0)
            case .atan2:
                let b = args[1]
                return div(sub(mul(b, da), mul(a, d(b))), add(mul(a, a), mul(b, b)))
            }
        case let .conditional(c, a, b): return .conditional(c, d(a), d(b))
        case let .table(a, xs, ys): return mul(.tableSlope(a, xs, ys), d(a))
        case .tableSlope: return .constant(0)
        }
    }

    /// Constants folded, and additions of 0 and multiplications by 0 or 1 left out
    static func fold(_ node: Node) -> Node {
        switch node {
        case let .negate(a):
            let f = fold(a)
            if case let .constant(c) = f { return .constant(-c) }
            return .negate(f)
        case let .not(a):
            let f = fold(a)
            if case let .constant(c) = f { return .constant(c != 0 ? 0 : 1) }
            return .not(f)
        case let .binary(op, a, b):
            let fa = fold(a), fb = fold(b)
            if case .constant = fa, case .constant = fb {
                return .constant(constant(.binary(op, fa, fb)))
            }
            switch op {
            case .add:
                if fa == .constant(0) { return fb }
                if fb == .constant(0) { return fa }
            case .subtract:
                if fb == .constant(0) { return fa }
                if fa == .constant(0) { return .negate(fb) }
            case .multiply:
                if fa == .constant(0) || fb == .constant(0) { return .constant(0) }
                if fa == .constant(1) { return fb }
                if fb == .constant(1) { return fa }
            case .divide:
                if fa == .constant(0) { return .constant(0) }
                if fb == .constant(1) { return fa }
            default: break
            }
            return .binary(op, fa, fb)
        case let .call(f, args):
            let folded = args.map(fold)
            if folded.allSatisfy({ if case .constant = $0 { return true } else { return false } }) {
                return .constant(constant(.call(f, folded)))
            }
            return .call(f, folded)
        case let .conditional(c, a, b):
            let fc = fold(c), fa = fold(a), fb = fold(b)
            if case let .constant(v) = fc { return v != 0 ? fa : fb }
            if fa == fb { return fa }
            return .conditional(fc, fa, fb)
        case let .table(a, xs, ys):
            let fa = fold(a)
            if case .constant = fa { return .constant(constant(.table(fa, xs, ys))) }
            return .table(fa, xs, ys)
        case let .tableSlope(a, xs, ys):
            let fa = fold(a)
            if case .constant = fa { return .constant(constant(.tableSlope(fa, xs, ys))) }
            return .tableSlope(fa, xs, ys)
        default:
            return node
        }
    }

    // MARK: Text

    /// The expression in SPICE's syntax, inputs written as `name(k)` names them
    public func text(_ name: (Input) -> String) -> String {
        func write(_ n: Node, _ outer: Int) -> String {
            switch n {
            case let .constant(c): return c < 0 ? "(\(String(format: "%.12g", c)))" : String(format: "%.12g", c)
            case let .input(k): return name(inputs[k])
            case .time: return "time"
            case .temperature: return "temper"
            case let .negate(a): return "-" + write(a, 6)
            case let .not(a): return "!" + write(a, 6)
            case let .binary(op, a, b):
                let level: Int
                switch op {
                case .or: level = 1
                case .and: level = 2
                case .less, .greater, .lessEqual, .greaterEqual, .equal, .notEqual: level = 3
                case .add, .subtract: level = 4
                case .multiply, .divide: level = 5
                case .power: level = 7
                }
                let s = write(a, level) + op.rawValue + write(b, level + 1)
                return level < outer ? "(" + s + ")" : s
            case let .call(f, args): return f.rawValue + "(" + args.map { write($0, 0) }.joined(separator: ",") + ")"
            case let .conditional(c, a, b): return "(" + write(c, 0) + " ? " + write(a, 0) + " : " + write(b, 0) + ")"
            case let .table(a, xs, ys):
                return "table(" + write(a, 0) + "," + zip(xs, ys).map { String(format: "%.12g,%.12g", $0, $1) }.joined(separator: ",") + ")"
            case .tableSlope:
                return "0"
            }
        }
        return write(root, 0)
    }

    // MARK: Parsing

    struct Parser {
        private let characters: [Character]
        private var position = 0
        private let parameters: [String: Double]
        private(set) var inputs: [Input] = []

        init(_ text: String, parameters: [String: Double]) {
            var t = text.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("{") && t.hasSuffix("}") { t = String(t.dropFirst().dropLast()) }
            characters = Array(t.replacingOccurrences(of: "**", with: "^"))
            var lowered: [String: Double] = [:]
            for (k, v) in parameters { lowered[k.lowercased()] = v }
            self.parameters = lowered
        }

        var atEnd: Bool {
            var p = position
            while p < characters.count && characters[p].isWhitespace { p += 1 }
            return p >= characters.count
        }
        var rest: String { String(characters[min(position, characters.count)...]) }

        private mutating func skipSpace() {
            while position < characters.count && characters[position].isWhitespace { position += 1 }
        }
        private mutating func peek(_ s: String) -> Bool {
            skipSpace()
            let chars = Array(s)
            guard position + chars.count <= characters.count else { return false }
            return Array(characters[position..<position + chars.count]) == chars
        }
        private mutating func take(_ s: String) -> Bool {
            guard peek(s) else { return false }
            position += s.count
            return true
        }
        private mutating func expect(_ s: String) throws {
            guard take(s) else { throw ParseError.unexpected("text, \"\(s)\" expected", at: rest) }
        }

        mutating func parseExpression() throws -> Node {
            let c = try parseOr()
            if take("?") {
                let a = try parseExpression()
                try expect(":")
                let b = try parseExpression()
                return .conditional(c, a, b)
            }
            return c
        }
        private mutating func parseOr() throws -> Node {
            var a = try parseAnd()
            while take("||") { a = .binary(.or, a, try parseAnd()) }
            return a
        }
        private mutating func parseAnd() throws -> Node {
            var a = try parseComparison()
            while take("&&") { a = .binary(.and, a, try parseComparison()) }
            return a
        }
        private mutating func parseComparison() throws -> Node {
            var a = try parseSum()
            while true {
                if take("<=") { a = .binary(.lessEqual, a, try parseSum()) }
                else if take(">=") { a = .binary(.greaterEqual, a, try parseSum()) }
                else if take("==") { a = .binary(.equal, a, try parseSum()) }
                else if take("!=") { a = .binary(.notEqual, a, try parseSum()) }
                else if take("<") { a = .binary(.less, a, try parseSum()) }
                else if take(">") { a = .binary(.greater, a, try parseSum()) }
                else { return a }
            }
        }
        private mutating func parseSum() throws -> Node {
            var a = try parseProduct()
            while true {
                if take("+") { a = .binary(.add, a, try parseProduct()) }
                else if peek("-") && !peek("->") { position += 1; a = .binary(.subtract, a, try parseProduct()) }
                else { return a }
            }
        }
        private mutating func parseProduct() throws -> Node {
            var a = try parseUnary()
            while true {
                if take("*") { a = .binary(.multiply, a, try parseUnary()) }
                else if take("/") { a = .binary(.divide, a, try parseUnary()) }
                else { return a }
            }
        }
        private mutating func parseUnary() throws -> Node {
            if take("-") { return .negate(try parseUnary()) }
            if take("+") { return try parseUnary() }
            if take("!") { return .not(try parseUnary()) }
            return try parsePower()
        }
        private mutating func parsePower() throws -> Node {
            let base = try parseAtom()
            if take("^") { return .binary(.power, base, try parseUnary()) }
            return base
        }
        private mutating func parseAtom() throws -> Node {
            skipSpace()
            guard position < characters.count else { throw ParseError.unexpected("end", at: "") }
            let c = characters[position]
            if c == "(" || c == "{" {
                position += 1
                let inner = try parseExpression()
                try expect(c == "(" ? ")" : "}")
                return inner
            }
            if c.isNumber || c == "." { return .constant(try parseNumber()) }
            guard c.isLetter || c == "_" else { throw ParseError.unexpected("\"\(c)\"", at: rest) }
            let name = parseName()
            let lower = name.lowercased()
            if take("(") {
                // V(a), V(a,b), I(Vx), and functions
                if lower == "v" {
                    let a = parseNet()
                    var b: String?
                    if take(",") { b = parseNet() }
                    try expect(")")
                    return input(.voltage(a, b))
                }
                if lower == "i" {
                    let source = parseNet()
                    try expect(")")
                    return input(.current(source))
                }
                var args: [Node] = []
                if !take(")") {
                    repeat { args.append(try parseExpression()) } while take(",")
                    try expect(")")
                }
                if lower == "if" && args.count == 3 { return .conditional(args[0], args[1], args[2]) }
                if lower == "table" && args.count >= 3 && args.count % 2 == 1 {
                    return try table(args[0], Array(args.dropFirst()))
                }
                let aliases: [String: Function] = ["sign": .sgn, "stp": .u, "int": .floor, "log": .ln, "ln": .ln]
                guard let f = Function(rawValue: lower) ?? aliases[lower] else { throw ParseError.unknown("function \(name)") }
                let needed: [Function: Int] = [.min: 2, .max: 2, .pow: 2, .pwr: 2, .pwrs: 2, .atan2: 2, .limit: 3]
                guard args.count == (needed[f] ?? 1) else { throw ParseError.unexpected("arguments of \(name)", at: rest) }
                return .call(f, args)
            }
            switch lower {
            case "time": return .time
            case "temper", "temp": return .temperature
            case "pi": return .constant(Double.pi)
            case "e" where parameters["e"] == nil: return .constant(M_E)
            default:
                guard let value = parameters[lower] else { throw ParseError.unknown("parameter \(name)") }
                return .constant(value)
            }
        }

        private mutating func input(_ i: Input) -> Node {
            if let k = inputs.firstIndex(of: i) { return .input(k) }
            inputs.append(i)
            return .input(inputs.count - 1)
        }

        private mutating func table(_ argument: Node, _ points: [Node]) throws -> Node {
            var xs: [Double] = [], ys: [Double] = []
            for k in stride(from: 0, to: points.count - 1, by: 2) {
                let x = SpiceExpression.fold(points[k]), y = SpiceExpression.fold(points[k + 1])
                guard case let .constant(xv) = x, case let .constant(yv) = y else {
                    throw ParseError.unexpected("table point", at: rest)
                }
                xs.append(xv)
                ys.append(yv)
            }
            return .table(argument, xs, ys)
        }

        private mutating func parseName() -> String {
            let start = position
            while position < characters.count && (characters[position].isLetter || characters[position].isNumber
                                                  || characters[position] == "_" || characters[position] == ".") {
                position += 1
            }
            return String(characters[start..<position])
        }

        /// A net or source name inside V( ) or I( ): anything up to a comma or the closing parenthesis
        private mutating func parseNet() -> String {
            skipSpace()
            let start = position
            while position < characters.count && characters[position] != "," && characters[position] != ")" { position += 1 }
            return String(characters[start..<position]).trimmingCharacters(in: .whitespaces)
        }

        /// A number with SPICE's scale suffixes (1k, 2.2u, 10meg), and letters after them (a unit) skipped
        private mutating func parseNumber() throws -> Double {
            let start = position
            while position < characters.count && (characters[position].isNumber || characters[position] == ".") { position += 1 }
            if position < characters.count && (characters[position] == "e" || characters[position] == "E") {
                let save = position
                position += 1
                if position < characters.count && (characters[position] == "+" || characters[position] == "-") { position += 1 }
                if position < characters.count && characters[position].isNumber {
                    while position < characters.count && characters[position].isNumber { position += 1 }
                } else {
                    position = save
                }
            }
            let mantissa = String(characters[start..<position])
            let suffixStart = position
            while position < characters.count && characters[position].isLetter { position += 1 }
            let suffix = String(characters[suffixStart..<position])
            guard let value = SpiceNetlist.value(mantissa + suffix) else { throw ParseError.unexpected("number", at: mantissa) }
            return value
        }
    }
}
