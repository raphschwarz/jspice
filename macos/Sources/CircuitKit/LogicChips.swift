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
    /// Whether the part has a `chipPackage`, without building one (it is read as a circuit runs)
    public var hasChipPackage: Bool { Self.packagedKinds.contains(self) }
    private static let packagedKinds = Set(allCases.filter { $0.chipPackage != nil })

    /// How the part is drawn and where its pins are, for parts drawn as a box with pins down its sides
    public var chipPackage: ChipPackage? {
        if let board { return board.chipPackage }
        if let package = audioChipPackage { return package }
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
        case .shiftRegister:
            return ChipPackage(name: "74HC595", terminalNames: ["ser", "srclk", "rclk", "oe", "srclr"] + (0...7).map { "q\($0)" } + ["q7s"],
                               pinLabels: ["SER", "SRCLK", "RCLK", "OE", "SRCLR"] + (0...7).map { "Q\($0)" } + ["Q7S"],
                               pinPlaces: (0...4).map(second) + (0...8).map(first), length: 8)
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
        case .dualDac:
            return ChipPackage(name: "MCP4822", terminalNames: ["cs", "sck", "sdi", "ldac", "outA", "outB"],
                               pinLabels: ["CS", "SCK", "SDI", "LDAC", "VOUT A", "VOUT B"],
                               pinPlaces: [second(0), second(1), second(2), second(3), first(0), first(1)], length: 3)
        case .spiAdc:
            return ChipPackage(name: "MCP3008", terminalNames: ["cs", "clk", "din", "dout", "vref"] + (0...7).map { "ch\($0)" },
                               pinLabels: ["CS", "CLK", "DIN", "DOUT", "VREF"] + (0...7).map { "CH\($0)" },
                               pinPlaces: [first(3), first(2), first(1), first(0), first(5)] + (0...7).map(second), length: 7)
        case .i2cDac:
            return ChipPackage(name: "MCP4725", terminalNames: ["scl", "sda", "a0", "out"], pinLabels: ["SCL", "SDA", "A0", "VOUT"],
                               pinPlaces: [second(0), second(1), second(2), first(0)], length: 2)
        case .i2sDac:
            return ChipPackage(name: "PCM5102", terminalNames: ["bck", "din", "lrck", "outL", "outR"],
                               pinLabels: ["BCK", "DIN", "LRCK", "OUT L", "OUT R"],
                               pinPlaces: [second(0), second(1), second(2), first(0), first(1)], length: 2)
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
        case .logicGate, .flipFlop, .decadeCounter, .binaryCounter, .shiftRegister, .analogMux, .analogSelector, .pll, .dac,
             .dualDac, .spiAdc, .i2cDac, .i2sDac: return true
        default: return false
        }
    }

    /// Converters a microcontroller talks to that answer within a transfer (an ADC's DOUT, an I²C target's
    /// acknowledge): they follow the chip's pins as it runs, and what they drive back reaches it at once
    public var isBusDevice: Bool { self == .spiAdc || self == .i2cDac }

    /// The terminals a logic part reads as logic inputs, as indices into its terminals
    var logicInputs: [Int] {
        switch self {
        case .logicGate: return [0, 1]
        case .flipFlop: return [0, 1, 2, 3]
        case .decadeCounter: return [0, 1, 2]
        case .binaryCounter: return [0, 1]
        case .shiftRegister: return [0, 1, 2, 3, 4]
        case .analogMux: return [8, 9, 10, 11]
        case .analogSelector: return [2, 3]
        case .pll: return [0, 1, 3]
        case .dac, .dualDac: return [0, 1, 2, 3]
        case .spiAdc, .i2cDac, .i2sDac: return [0, 1, 2]
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
        case .shiftRegister: return Array(5...13)
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
    static func next(_ kind: ElementKind, _ old: LogicState, inputs: UInt32, function: Int = 0) -> LogicState {
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
        case .shiftRegister:
            // SER (DATA), SRCLK (CLOCK), RCLK, OE, SRCLR (RESET): each rising clock moves the stages along one and takes
            // SER into the first. A CD4015 half has four stages and clears while RESET is high; a 74HC595 has eight,
            // clears while SRCLR is low, and copies the stages to its latch on RCLK's rising edge (as they were before
            // a clock edge at the same moment, so with the clocks joined the latch is a stage behind)
            if function == 0 {
                if level(4) {
                    state.shift = 0
                } else if rose(1) {
                    state.shift = (old.shift << 1 | (level(0) ? 1 : 0)) & 0xF
                }
                state.count = Int(state.shift)
            } else {
                if !level(4) {
                    state.shift = 0
                } else if rose(1) {
                    state.shift = (old.shift << 1 | (level(0) ? 1 : 0)) & 0xFF
                }
                if rose(2) { state.latch = old.shift }
                state.count = Int(state.latch)
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
        case .dualDac:
            // CS, SCK, SDI, LDAC: as the MCP4921, but bit 15 picks the channel (0 A, 1 B), each with its own registers:
            // A's in the low half of the input and output registers, B's in the high half
            if fell(0) {
                state.shift = 0
                state.bits = 0
            }
            if !level(0) && rose(1) && state.bits < 16 {
                state.shift = state.shift << 1 | (level(2) ? 1 : 0)
                state.bits += 1
            }
            if rose(0) {
                if state.bits == 16 {
                    let word = state.shift & 0xFFFF
                    state.latch = word & 0x8000 == 0 ? state.latch & 0xFFFF_0000 | word : state.latch & 0xFFFF | word << 16
                }
                state.bits = 0
            }
            if !level(3) { state.count = Int(state.latch) }
        case .spiAdc:
            // CS, CLK, DIN: with CS low, DIN is read on each rising edge of CLK. After a start bit (the first high) come
            // SGL/DIFF and the channel, D2–D0; the input is sampled as D0 comes in (the circuit puts the code in `latch`
            // while `phase` asks for it). On the falling edges after the next rising one DOUT gives a null bit, then the
            // code's ten bits, MSB first, then zeros. `bits` counts rising edges from the start bit (0 waiting for it),
            // `count` is DOUT's level.
            if level(0) {
                state.bits = 0
                state.shift = 0
                state.count = 0
            } else {
                if rose(1) {
                    if state.bits == 0 {
                        if level(2) { state.bits = 1 }
                    } else {
                        state.bits += 1
                        if state.bits <= 5 { state.shift = state.shift << 1 | (level(2) ? 1 : 0) }
                        if state.bits == 5 { state.phase = 1 }
                    }
                }
                if fell(1) && state.bits >= 6 {
                    let index = state.bits - 6
                    state.count = index >= 1 && index <= 10 && state.latch & (1 << UInt32(10 - index)) != 0 ? 1 : 0
                }
            }
        case .i2cDac:
            state = i2cTarget(old, inputs: inputs)
        case .i2sDac:
            // BCK, DIN, LRCK (I²S): DIN is read on each rising edge of BCK, MSB first, a word for each half of LRCK's
            // cycle (low the left channel, high the right), starting one BCK after LRCK changes: so the first bit read
            // after a change ends the other channel's word, which then goes out, kept left-justified in 32 bits (the
            // left in `latch`, the right in `count`); `phase` is the channel being read (1 right)
            if rose(0) {
                let bit: UInt32 = level(1) ? 1 : 0
                let right = level(2)
                let wasRight = old.phase >= 0.5
                if right != wasRight {
                    var word = old.shift
                    var bits = old.bits
                    if bits < 32 {
                        word = word << 1 | bit
                        bits += 1
                    }
                    let justified = bits >= 32 ? word : word << UInt32(32 - bits)
                    if wasRight { state.count = Int(Int32(bitPattern: justified)) } else { state.latch = justified }
                    state.shift = 0
                    state.bits = 0
                    state.phase = right ? 1 : 0
                } else if old.bits < 32 {
                    state.shift = old.shift << 1 | bit
                    state.bits = old.bits + 1
                }
            }
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
        case .shiftRegister:
            if function == 0 {
                // a CD4015 half's Q1–Q4 (the last also its serial output)
                return (0..<8).map { $0 < 4 && state.shift & (UInt32(1) << UInt32($0)) != 0 } + [state.shift & 0x8 != 0]
            }
            // a 74HC595's latch, driven while OE is low (the chip lets its outputs float otherwise: here they are held
            // low), and Q7S, the last stage, always
            let enabled = !level(3)
            return (0..<8).map { enabled && state.latch & (UInt32(1) << UInt32($0)) != 0 } + [state.shift & 0x80 != 0]
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

    /// An I²C target's bit-level state: `bits` counted in the byte (9 during the acknowledge clock), `shift` the byte,
    /// `count` the output register (code | power-down bits << 12), and in `latch` the transaction: the byte number
    /// (bits 0–7), whether it was addressed (8), whether it is holding SDA low (9), whether a START began it (10), the
    /// write-DAC command rather than fast mode (11), and the data bytes so far (16–31)
    static let i2cAddressed: UInt32 = 1 << 8, i2cAcknowledging: UInt32 = 1 << 9, i2cActive: UInt32 = 1 << 10, i2cWriteCommand: UInt32 = 1 << 11

    /// Whether an I²C target holds SDA low
    static func acknowledging(_ state: LogicState) -> Bool { state.latch & i2cAcknowledging != 0 }

    /// An MCP4725 on SCL, SDA and A0: answers at 0x60 + A0 (the MCP4725A0's address, its A2 and A1 0). START is SDA
    /// falling while SCL is high, STOP SDA rising while SCL is high; between them each byte is read on SCL's rising
    /// edges, MSB first, and acknowledged by holding SDA low through the ninth clock if it is the address written to, or
    /// a byte after it. Fast mode (0 0 PD1 PD0 D11–D8, then D7–D0, repeated) and the write-DAC command (0 1 0 x x PD1 PD0
    /// x, D11–D4, D3–D0 x x x x; or 0 1 1 for DAC and EEPROM) set the output register. SDA as the bus has it: low while
    /// it acknowledges, whatever the master does.
    private static func i2cTarget(_ old: LogicState, inputs: UInt32) -> LogicState {
        var state = old
        state.inputs = inputs
        let holding = old.latch & i2cAcknowledging != 0
        let sclWas = old.inputs & 1 != 0, scl = inputs & 1 != 0
        let sdaWas = old.inputs & 2 != 0 && !holding, sda = inputs & 2 != 0 && !holding
        if sclWas && scl && sdaWas != sda {
            if !sda {
                // START (or a repeated one): the address comes next
                state.latch = i2cActive
                state.bits = 0
                state.shift = 0
            } else {
                state.latch &= ~(i2cActive | i2cAcknowledging)
            }
            return state
        }
        guard old.latch & i2cActive != 0 else { return state }
        if !sclWas && scl && state.bits < 8 {
            state.shift = state.shift << 1 | (sda ? 1 : 0)
            state.bits += 1
        } else if sclWas && !scl {
            if state.bits == 8 {
                // the byte is in: acknowledge it, or let the transaction go
                let byte = state.shift & 0xFF
                let index = state.latch & 0xFF
                var latch = state.latch & ~UInt32(0xFF) | (index + 1) & 0xFF
                if index == 0 {
                    let address = UInt32(0x60) | (inputs & 4 != 0 ? 1 : 0)
                    guard byte >> 1 == address && byte & 1 == 0 else {
                        state.latch = 0
                        return state
                    }
                    latch |= i2cAddressed
                } else {
                    // data bytes: the first says which command; the output register takes the code when it is whole
                    let data = latch >> 16
                    if index == 1 {
                        if byte >> 6 == 0 {
                            latch = latch & ~i2cWriteCommand & 0xFFFF | byte << 16
                        } else {
                            latch = latch | i2cWriteCommand
                            latch = latch & 0xFFFF | byte << 16
                        }
                    } else if latch & i2cWriteCommand == 0 {
                        // fast mode: pairs of bytes, the first in `data`
                        if index % 2 == 1 {
                            latch = latch & 0xFFFF | byte << 16
                        } else {
                            state.count = Int((data >> 4 & 0x3) << 12 | (data & 0xF) << 8 | byte)
                        }
                    } else if index == 2 {
                        latch = latch & 0xFFFF | (data << 8 | byte) << 16
                    } else if index == 3 {
                        let command = data >> 8
                        state.count = Int((command >> 1 & 0x3) << 12 | (data & 0xFF) << 4 | byte >> 4)
                    }
                }
                state.latch = latch | i2cAcknowledging
                state.bits = 9
            } else if state.bits == 9 {
                // the acknowledge clock is over: let SDA go, ready for the next byte
                state.latch &= ~i2cAcknowledging
                state.bits = 0
                state.shift = 0
            }
        }
        return state
    }

    /// An MCP4725's output for its output register: the supply times the code over 4096, or 0 V powered down
    static func i2cDacOutput(_ register: Int, supply: Double) -> Double {
        guard register >> 12 & 0x3 == 0 else { return 0 }
        return supply * Double(register & 0xFFF) / 4096
    }

    /// An MCP4822 channel's output (0 A, 1 B) for its output registers: its 2.048 V reference times the code over 4096,
    /// times two unless the GA bit is set
    static func dualDacOutput(_ registers: Int, channel: Int, supply: Double) -> Double {
        dacOutput(registers >> (16 * channel) & 0xFFFF, reference: 2.048, supply: supply)
    }

    /// A PCM5102's output for a left-justified 32-bit sample: 2.1 V RMS at full scale, about ground
    static func i2sOutput(_ sample: Int32) -> Double { Double(sample) / 2_147_483_648 * 2.1 * 2.squareRoot() }

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
