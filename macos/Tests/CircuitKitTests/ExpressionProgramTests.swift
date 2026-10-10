import XCTest
@testable import CircuitKit

/// A behavioural source's expression compiled into a program gives what walking its tree gives, to the last bit: its
/// value and every slope, at inputs as they are and with its decisions held elsewhere
final class ExpressionProgramTests: XCTestCase {
    static let texts = [
        "V(a)*2 + 1",
        "exp(V(a)*V(b)) - 1",
        "V(a,b) > 0.5 ? V(c) : -V(c)",
        "if(V(a) > 0, V(a)^2, 0.1*V(b))",
        "limit(V(a), -1, 1) * 3 + limit(V(b), V(c), -V(c))",
        "min(V(a), V(b)) + max(V(a), V(c))",
        "table(V(a), -1, -2, 0, 0, 1, 3, 2, 3.5)",
        "u(V(a)) * V(b) + uramp(V(a) - 0.2) + stp(V(c))",
        "sgn(V(a)) * abs(V(b))",
        "tanh(V(a)*10) + atan(V(b))",
        "pwr(V(a), 1.5) + pwrs(V(b), 0.5) + pow(abs(V(c)) + 1, V(a))",
        "V(a)/V(b) + V(c)/(V(a) - V(a))",
        "ln(V(a)) + log10(abs(V(b)) + 1) + log(V(c))",
        "sqrt(V(a)) + sin(time*1000) + temper/100",
        "(V(a) > 0 && V(b) < 0) || V(c) == 0 ? 1 : 0",
        "!(V(a) > 0) * V(b) + (V(a) != V(b)) - (V(c) <= 0) + (V(a) >= V(c))",
        "floor(V(a)) + ceil(V(b)) + int(V(c))",
        "atan2(V(a), V(b))",
        "sinh(V(a)) + cosh(V(b)) + tan(V(c)) + asin(V(a)/10) + acos(V(b)/10) + cos(V(c))",
        "I(V1) * 1k + V(a)",
        "V(a)^V(b)",
        "exp(V(a)) * exp(V(a)) / (1 + exp(V(a)))",
        "0.5*V(a) + 2*table(V(b)*V(c), 0, 0, 1, 1)",
    ]

    /// Deterministic inputs from -3 to 3, a few of them exactly 0
    private struct Draws {
        var state: UInt64 = 0x9e37_79b9_7f4a_7c15
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let u = Double(state >> 11) / Double(1 << 53)
            return u < 0.05 ? 0 : (u - 0.5) * 6
        }
    }

    private func same(_ a: Double, _ b: Double) -> Bool { a.bitPattern == b.bitPattern || (a.isNaN && b.isNaN) }

    private func check(_ expression: SpiceExpression, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let program = SpiceExpression.Program(expression)
        XCTAssertEqual(program.slopes.count, expression.inputs.count, label, file: file, line: line)
        let n = max(expression.inputs.count, 1)
        var draws = Draws()
        var results = [Double](repeating: .nan, count: max(program.count, 1))
        for trial in 0..<200 {
            let x = (0..<n).map { _ in draws.next() }
            let held = (0..<n).map { _ in draws.next() }
            let time = Double(trial) * 1e-4, celsius = 27 + Double(trial % 7)
            for holding in [false, true] {
                x.withUnsafeBufferPointer { x in held.withUnsafeBufferPointer { held in
                    let deciding = holding ? held.baseAddress! : nil
                    results.withUnsafeMutableBufferPointer { program.run(x.baseAddress!, deciding: deciding, time: time, celsius: celsius, into: $0.baseAddress!) }
                    let value = expression.value(x.baseAddress!, deciding: deciding, time: time, celsius: celsius)
                    XCTAssertTrue(same(results[program.value], value), "\(label) at \(Array(x)) (held \(holding)): \(results[program.value]) for \(value)",
                                  file: file, line: line)
                    for k in expression.inputs.indices {
                        let slope = expression.slope(k, x.baseAddress!, deciding: deciding, time: time, celsius: celsius)
                        XCTAssertTrue(same(results[program.slopes[k]], slope),
                                      "\(label), slope \(k) at \(Array(x)) (held \(holding)): \(results[program.slopes[k]]) for \(slope)",
                                      file: file, line: line)
                    }
                } }
            }
        }
    }

    func testAProgramGivesWhatTheTreeGivesToTheBit() throws {
        for text in Self.texts {
            check(try SpiceExpression(parsing: text), text)
        }
        // a POLY of the second degree in two inputs, and an expression without inputs
        check(SpiceExpression.polynomial(dimensions: 2, coefficients: [0.1, 2, -3, 0.5, 0.25, -0.125],
                                         inputs: [.voltage("a", nil), .voltage("b", nil)]), "POLY(2)")
        check(try SpiceExpression(parsing: "1k*2 + 3"), "constant")
    }

    /// A part the value and its slopes share is worked out once: exp(V(a)·V(b)) for the value and both slopes
    func testSharedPartsAreWorkedOutOnce() throws {
        let expression = try SpiceExpression(parsing: "exp(V(a)*V(b))")
        let program = SpiceExpression.Program(expression)
        func size(_ node: SpiceExpression.Node) -> Int {
            switch node {
            case .constant, .input, .time, .temperature: return 1
            case let .negate(a), let .not(a), let .live(a), let .table(a, _, _), let .tableSlope(a, _, _): return 1 + size(a)
            case let .binary(_, a, b): return 1 + size(a) + size(b)
            case let .call(_, args): return 1 + args.map(size).reduce(0, +)
            case let .conditional(c, a, b): return 1 + size(c) + size(a) + size(b)
            }
        }
        let trees = size(expression.root) + expression.slopes.map(size).reduce(0, +)
        XCTAssertLessThan(program.count, trees)
        XCTAssertLessThanOrEqual(program.count, 7, "\(program.count) steps")
    }
}
