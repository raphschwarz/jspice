import Foundation

/// A chip drawn as a box with its pins down two sides: a microcontroller, or a CMOS counter, flip-flop or multiplexer
public struct ChipPackage: Sendable {
    /// The name printed on the box
    public let name: String
    /// The terminals' names, in the order of the element's posts
    public let terminalNames: [String]
    /// The pin labels drawn inside the box
    public let pinLabels: [String]
    public let pinPlaces: [Board.PinPlace]
    /// Length in grid units
    public let length: Int
}

extension Board {
    public var chipPackage: ChipPackage {
        ChipPackage(name: chip, terminalNames: terminalNames, pinLabels: pinLabels, pinPlaces: pinPlaces, length: length)
    }
}

extension ElementKind {
    /// How the part is drawn and where its pins are, for parts drawn as a box with pins down its sides
    public var chipPackage: ChipPackage? {
        if let board { return board.chipPackage }
        // inputs down the second side, outputs (and a multiplexer's common terminal and select inputs) down the first
        func first(_ offset: Int) -> Board.PinPlace { Board.PinPlace(second: false, offset: offset) }
        func second(_ offset: Int) -> Board.PinPlace { Board.PinPlace(second: true, offset: offset) }
        switch self {
        case .flipFlop:
            return ChipPackage(name: "CD4013", terminalNames: ["d", "clock", "set", "reset", "q", "qbar"],
                               pinLabels: ["D", "CLK", "S", "R", "Q", "Q̄"],
                               pinPlaces: [second(0), second(1), second(2), second(3), first(0), first(3)], length: 3)
        case .decadeCounter:
            return ChipPackage(name: "CD4017", terminalNames: ["clock", "inhibit", "reset"] + (0...9).map { "q\($0)" } + ["carry"],
                               pinLabels: ["CLK", "INH", "RST"] + (0...9).map { "Q\($0)" } + ["CO"],
                               pinPlaces: [second(0), second(1), second(2)] + (0...10).map(first), length: 10)
        case .binaryCounter:
            return ChipPackage(name: "CD4040", terminalNames: ["clock", "reset"] + (1...12).map { "q\($0)" },
                               pinLabels: ["CLK", "RST"] + (1...12).map { "Q\($0)" },
                               pinPlaces: [second(0), second(1)] + (0...11).map(first), length: 11)
        case .analogMux:
            return ChipPackage(name: "CD4051", terminalNames: (0...7).map { "x\($0)" } + ["a", "b", "c", "inhibit", "x"],
                               pinLabels: (0...7).map { "X\($0)" } + ["A", "B", "C", "INH", "X"],
                               pinPlaces: (0...7).map(second) + [first(4), first(5), first(6), first(7), first(0)], length: 7)
        case .analogSelector:
            return ChipPackage(name: "CD4053", terminalNames: ["x0", "x1", "select", "inhibit", "x"],
                               pinLabels: ["X0", "X1", "SEL", "INH", "X"],
                               pinPlaces: [second(0), second(1), first(2), first(3), first(0)], length: 3)
        default:
            return nil
        }
    }

    /// CMOS logic: gates, flip-flops, counters and multiplexers. Their inputs read the circuit against thresholds, their
    /// state changes when an input crosses one, and their outputs drive towards the hidden supply or ground.
    public var isLogic: Bool {
        switch self {
        case .logicGate, .flipFlop, .decadeCounter, .binaryCounter, .analogMux, .analogSelector: return true
        default: return false
        }
    }

    /// The terminals a logic part reads as logic inputs, as indices into its terminals
    var logicInputs: [Int] {
        switch self {
        case .logicGate: return [0, 1]
        case .flipFlop: return [0, 1, 2, 3]
        case .decadeCounter: return [0, 1, 2]
        case .binaryCounter: return [0, 1]
        case .analogMux: return [8, 9, 10, 11]
        case .analogSelector: return [2, 3]
        default: return []
        }
    }

    /// The terminals a logic part drives, as indices into its terminals
    var logicOutputs: [Int] {
        switch self {
        case .logicGate: return [2]
        case .flipFlop: return [4, 5]
        case .decadeCounter: return Array(3...13)
        case .binaryCounter: return Array(2...13)
        default: return []
        }
    }
}

/// What a logic part remembers: the level of each input as last read (bit k for its k-th logic input), and its count
/// (a counter's count, a flip-flop's Q)
public struct LogicState: Equatable, Sendable {
    public var inputs: UInt32 = 0
    public var count = 0

    public init(inputs: UInt32 = 0, count: Int = 0) {
        self.inputs = inputs
        self.count = count
    }
}

/// The logic of the CMOS parts, apart from the circuit: what each does when its inputs change, and what it puts out
enum Logic {
    /// The two-input functions a logic gate can have, in the order of its "function" parameter
    static let gateFunctions = ["NAND", "NOR", "AND", "OR", "XOR", "XNOR"]

    static func gate(_ function: Int, _ x: Bool, _ y: Bool) -> Bool {
        switch function {
        case 1: return !(x || y)
        case 2: return x && y
        case 3: return x || y
        case 4: return x != y
        case 5: return x == y
        default: return !(x && y)
        }
    }

    /// The state after the inputs change from `old.inputs` to `inputs` (edges are what changed between the two)
    static func next(_ kind: ElementKind, _ old: LogicState, inputs: UInt32) -> LogicState {
        func level(_ k: Int) -> Bool { inputs & (1 << UInt32(k)) != 0 }
        func rose(_ k: Int) -> Bool { level(k) && old.inputs & (1 << UInt32(k)) == 0 }
        func fell(_ k: Int) -> Bool { !level(k) && old.inputs & (1 << UInt32(k)) != 0 }
        var state = LogicState(inputs: inputs, count: old.count)
        switch kind {
        case .flipFlop:
            // D, CLK, S, R: set and reset act at once, whatever the clock; otherwise Q takes D on the clock's rising edge
            if level(2) || level(3) {
                state.count = level(2) ? 1 : 0
            } else if rose(1) {
                state.count = level(0) ? 1 : 0
            }
        case .decadeCounter:
            // CLK, INH, RST: counts on the clock's rising edge while not inhibited, and on the inhibit's falling edge
            // while the clock is high; reset holds it at 0
            if level(2) {
                state.count = 0
            } else if (rose(0) && !level(1)) || (fell(1) && level(0)) {
                state.count = (old.count + 1) % 10
            }
        case .binaryCounter:
            // CLK, RST: counts on the clock's falling edge; reset holds it at 0
            if level(1) {
                state.count = 0
            } else if fell(0) {
                state.count = (old.count + 1) & 0xFFF
            }
        default:
            break
        }
        return state
    }

    /// Whether each output (in `logicOutputs` order) is high
    static func outputs(_ kind: ElementKind, _ state: LogicState, function: Int) -> [Bool] {
        func level(_ k: Int) -> Bool { state.inputs & (1 << UInt32(k)) != 0 }
        switch kind {
        case .logicGate:
            return [gate(function, level(0), level(1))]
        case .flipFlop:
            // set and reset together make both outputs high, as on the CD4013
            if level(2) && level(3) { return [true, true] }
            return [state.count == 1, state.count != 1]
        case .decadeCounter:
            // one-hot Q0-Q9, and the carry out high for counts 0 to 4
            return (0...9).map { state.count == $0 } + [state.count < 5]
        case .binaryCounter:
            return (0..<12).map { state.count & (1 << $0) != 0 }
        default:
            return []
        }
    }

    /// The channel a multiplexer or selector connects to its common terminal, or nil while inhibited
    static func channel(_ kind: ElementKind, _ state: LogicState) -> Int? {
        switch kind {
        case .analogMux:
            // A, B, C, INH
            return state.inputs & 0b1000 != 0 ? nil : Int(state.inputs & 0b111)
        case .analogSelector:
            // SEL, INH
            return state.inputs & 0b10 != 0 ? nil : Int(state.inputs & 1)
        default:
            return nil
        }
    }
}
