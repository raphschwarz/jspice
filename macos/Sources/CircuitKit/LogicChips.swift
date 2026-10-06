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
        case .dac:
            return ChipPackage(name: "MCP4921", terminalNames: ["cs", "sck", "sdi", "ldac", "vref", "out"],
                               pinLabels: ["CS", "SCK", "SDI", "LDAC", "VREF", "OUT"],
                               pinPlaces: [second(0), second(1), second(2), second(3), second(4), first(0)], length: 4)
        case .pll:
            return ChipPackage(name: "CD4046", terminalNames: ["signal", "comparator", "vco_in", "inhibit", "vco_out", "pc1", "pc2"],
                               pinLabels: ["SIG", "COMP", "VCO IN", "INH", "VCO", "PC1", "PC2"],
                               pinPlaces: [second(0), second(1), second(2), second(3), first(0), first(1), first(2)], length: 3)
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
        case .logicGate, .flipFlop, .decadeCounter, .binaryCounter, .analogMux, .analogSelector, .pll, .dac: return true
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
        case .pll: return [0, 1, 3]
        case .dac: return [0, 1, 2, 3]
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
        case .pll: return [4, 5]
        default: return []
        }
    }
}

/// What a logic part remembers: the level of each input as last read (bit k for its k-th logic input), its count (a
/// counter's count, a flip-flop's Q, a PLL's phase comparator 2: 1 pumping up, -1 down, 0 off), a PLL's VCO phase (0 to
/// 1), and a DAC's shift register and the bits shifted into it
public struct LogicState: Equatable, Sendable {
    public var inputs: UInt32 = 0
    public var count = 0
    public var phase = 0.0
    public var shift: UInt32 = 0
    public var bits = 0
    /// A DAC's input register
    public var latch: UInt32 = 0

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
        var state = old
        state.inputs = inputs
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
        case .dac:
            // CS, SCK, SDI, LDAC. While CS is low, SDI is shifted in on each rising edge of SCK; when CS goes high after
            // sixteen bits they become the input register (unless bit 15, which picks DAC B, is set: the MCP4921 has
            // only A), and the output takes the input register while LDAC is low
            if fell(0) {
                state.shift = 0
                state.bits = 0
            }
            if !level(0) && rose(1) && state.bits < 16 {
                state.shift = state.shift << 1 | (level(2) ? 1 : 0)
                state.bits += 1
            }
            if rose(0) {
                if state.bits == 16 && state.shift & 0x8000 == 0 { state.latch = state.shift & 0xFFFF }
                state.bits = 0
            }
            if !level(3) { state.count = Int(state.latch) }
        case .pll:
            // phase comparator 2: a rising edge of the signal pumps up (or ends pumping down), one of the comparator
            // input pumps down (or ends pumping up), so the output stays off once the two are in phase
            if rose(0) { state.count = state.count < 0 ? 0 : 1 }
            if rose(1) { state.count = state.count > 0 ? 0 : -1 }
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
        case .pll:
            // the VCO (stopped low while inhibited), and phase comparator 1: the XOR of the signal and comparator inputs
            return [!level(2) && state.phase < 0.5, level(0) != level(1)]
        default:
            return []
        }
    }

    /// An MCP4921's output for the word in its output register: the reference times the 12-bit code over 4096, times
    /// two unless the GA bit (13) is set; 0 V while shut down (the SHDN bit, 12, clear)
    static func dacOutput(_ word: Int, reference: Double, supply: Double) -> Double {
        guard word & 0x1000 != 0 else { return 0 }
        let gain = word & 0x2000 != 0 ? 1.0 : 2.0
        return min(max(reference * Double(word & 0xFFF) / 4096 * gain, 0), supply)
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
