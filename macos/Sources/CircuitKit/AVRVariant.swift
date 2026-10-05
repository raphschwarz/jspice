import Foundation

/// An AVR chip's layout: its memories, where its ports, timers, USARTs, ADC and interrupt registers are, which of its
/// port bits reach the board's pins, and its interrupt vectors. `AVR` runs any of them.
public struct AVRVariant: Sendable {
    public enum TimerKind: Sendable { case standard8, standard16, tiny1 }

    /// A timer/counter and its compare units (two or three)
    struct Timer: Sendable {
        let kind: TimerKind
        /// TCCRnA and TCCRnB (tiny1: TCCR1 and GTCCR)
        let controlA: Int
        let controlB: Int
        /// TCNTn (the low byte of a 16-bit one)
        let count: Int
        /// OCRnA, OCRnB (, OCRnC)
        let compare: [Int]
        let maskRegister: Int
        let flagRegister: Int
        let overflowBit: UInt8
        let compareBits: [UInt8]
        let overflowVector: Int
        let compareVectors: [Int]
        /// Clock divisions by clock select value (0: stopped)
        let prescalers: [Int]
        /// The pin each compare unit drives (-1: not on a pin)
        let pins: [Int]
        var capture = -1
        var captureBit: UInt8 = 0
        var captureVector = -1
        /// tiny1: OCR1C (TOP), and the pins of the inverted outputs
        var top = -1
        var complements: [Int] = []
    }

    struct USART: Sendable {
        /// UCSRnA, then B and C; UBRRnL and H at +4 and +5; UDRn at +6
        let base: Int
        let rxVector: Int
        let udreVector: Int
        let txVector: Int
        let rxPin: Int
        let txPin: Int
        var statusA: Int { base }
        var controlB: Int { base + 1 }
        var controlC: Int { base + 2 }
        var rateLow: Int { base + 4 }
        var rateHigh: Int { base + 5 }
        var dataRegister: Int { base + 6 }
    }

    /// What an ADC channel reads: a pin, or one of these
    static let adcGround = -1
    static let adcBandgap = -2

    struct ADC: Sendable {
        let multiplexer: Int
        let control: Int
        let controlB: Int
        let low: Int
        let high: Int
        let vector: Int
        /// MUX5 in ADCSRB (bit 3) picks channels 8-15
        let mux5: Bool
        /// REFS2 in bit 4 of ADMUX (the ATtiny85)
        let tiny: Bool
        let muxMask: Int
        /// Pin (or adcGround, adcBandgap) by multiplexer value 0-63
        let channels: [Int]
        /// Reference volts by REFS value (0: the supply)
        let references: [Double]
    }

    struct ExternalInterrupt: Sendable {
        let pin: Int
        /// EICRA (EICRB, MCUCR) and the shift of the interrupt's two sense bits
        let control: Int
        let shift: Int
        let mask: Int
        let maskBit: UInt8
        let flag: Int
        let flagBit: UInt8
        let vector: Int
    }

    struct PinChange: Sendable {
        let control: Int
        let controlBit: UInt8
        let flag: Int
        let flagBit: UInt8
        /// PCMSKn, and the pin of each of its bits (-1: none)
        let mask: Int
        let pins: [Int]
        let vector: Int
    }

    public struct PortBit: Sendable, Equatable {
        public let port: Int
        public let bit: Int
    }

    public let name: String
    public let clock: Double
    let flashWords: Int
    let dataSize: Int
    let eepromSize: Int
    /// Where SRAM starts: addresses from 0x20 up to here are I/O registers
    let ioEnd: Int
    /// Bytes of the return address (3 on chips with more than 128 KB of flash)
    let pcBytes: Int
    let vectorWords: Int
    /// The PINx address of each port (DDRx and PORTx follow it)
    let ports: [Int]
    /// The board's pins, in order
    public let pins: [PortBit]
    let timers: [Timer]
    let usarts: [USART]
    let adc: ADC
    let externalInterrupts: [ExternalInterrupt]
    let pinChanges: [PinChange]
    /// EECR, EEDR, EEARL, EEARH
    let eepromRegisters: (control: Int, data: Int, low: Int, high: Int)
    /// Flag registers, whose bits are cleared by writing 1
    let clearOnWrite: [Int]
    /// Interrupt enable registers
    let maskRegisters: [Int]
    /// The SPI and the two-wire interface, on chips that have them
    var spi: SPI? = nil
    var twi: TWI? = nil

    public var pinCount: Int { pins.count }
    public var flashBytes: Int { flashWords * 2 }

    private static let standardPrescalers = [0, 1, 8, 64, 256, 1024, 0, 0]
    private static let timer2Prescalers = [0, 1, 8, 32, 64, 128, 256, 1024]

    private static func channelTable(_ entries: [Int: Int]) -> [Int] {
        var table = [Int](repeating: adcGround, count: 64)
        for (mux, source) in entries { table[mux] = source }
        return table
    }

    private static func referenceTable(_ entries: [Int: Double]) -> [Double] {
        var table = [Double](repeating: 0, count: 8)
        for (refs, volts) in entries { table[refs] = volts }
        return table
    }

    /// The Arduino Uno's chip: D0-D7 are PD0-7, D8-D13 are PB0-5, A0-A5 (14-19) are PC0-5
    public static let atmega328p: AVRVariant = {
        var pins: [PortBit] = []
        for bit in 0..<8 { pins.append(PortBit(port: 2, bit: bit)) }
        for bit in 0..<6 { pins.append(PortBit(port: 0, bit: bit)) }
        for bit in 0..<6 { pins.append(PortBit(port: 1, bit: bit)) }
        var channels: [Int: Int] = [14: adcBandgap, 15: adcGround]
        for channel in 0..<6 { channels[channel] = 14 + channel }
        return AVRVariant(
            name: "ATmega328P", clock: 16_000_000, flashWords: 16_384, dataSize: 0x900, eepromSize: 1024, ioEnd: 0x100,
            pcBytes: 2, vectorWords: 2, ports: [0x23, 0x26, 0x29], pins: pins,
            timers: [
                Timer(kind: .standard8, controlA: 0x44, controlB: 0x45, count: 0x46, compare: [0x47, 0x48],
                      maskRegister: 0x6E, flagRegister: 0x35, overflowBit: 1, compareBits: [2, 4], overflowVector: 16,
                      compareVectors: [14, 15], prescalers: standardPrescalers, pins: [6, 5]),
                Timer(kind: .standard16, controlA: 0x80, controlB: 0x81, count: 0x84, compare: [0x88, 0x8A],
                      maskRegister: 0x6F, flagRegister: 0x36, overflowBit: 1, compareBits: [2, 4], overflowVector: 13,
                      compareVectors: [11, 12], prescalers: standardPrescalers, pins: [9, 10],
                      capture: 0x86, captureBit: 0x20, captureVector: 10),
                Timer(kind: .standard8, controlA: 0xB0, controlB: 0xB1, count: 0xB2, compare: [0xB3, 0xB4],
                      maskRegister: 0x70, flagRegister: 0x37, overflowBit: 1, compareBits: [2, 4], overflowVector: 9,
                      compareVectors: [7, 8], prescalers: timer2Prescalers, pins: [11, 3]),
            ],
            usarts: [USART(base: 0xC0, rxVector: 18, udreVector: 19, txVector: 20, rxPin: 0, txPin: 1)],
            adc: ADC(multiplexer: 0x7C, control: 0x7A, controlB: 0x7B, low: 0x78, high: 0x79, vector: 21, mux5: false,
                     tiny: false, muxMask: 0x0F, channels: channelTable(channels),
                     references: referenceTable([3: 1.1])),
            externalInterrupts: [
                ExternalInterrupt(pin: 2, control: 0x69, shift: 0, mask: 0x3D, maskBit: 1, flag: 0x3C, flagBit: 1, vector: 1),
                ExternalInterrupt(pin: 3, control: 0x69, shift: 2, mask: 0x3D, maskBit: 2, flag: 0x3C, flagBit: 2, vector: 2),
            ],
            pinChanges: [
                PinChange(control: 0x68, controlBit: 1, flag: 0x3B, flagBit: 1, mask: 0x6B,
                          pins: [8, 9, 10, 11, 12, 13, -1, -1], vector: 3),
                PinChange(control: 0x68, controlBit: 2, flag: 0x3B, flagBit: 2, mask: 0x6C,
                          pins: [14, 15, 16, 17, 18, 19, -1, -1], vector: 4),
                PinChange(control: 0x68, controlBit: 4, flag: 0x3B, flagBit: 4, mask: 0x6D,
                          pins: [0, 1, 2, 3, 4, 5, 6, 7], vector: 5),
            ],
            eepromRegisters: (0x3F, 0x40, 0x41, 0x42),
            clearOnWrite: [0x35, 0x36, 0x37, 0x3B, 0x3C],
            maskRegisters: [0x6E, 0x6F, 0x70, 0x3D, 0x68],
            spi: SPI(control: 0x4C, vector: 17, sck: 13, mosi: 11, miso: 12, ss: 10),
            twi: TWI(rate: 0xB8, vector: 24, sda: 18, scl: 19))
    }()

    /// The Arduino Mega 2560's pins D0-D69 (A0-A15 are D54-D69), as port and bit
    static let megaPins = ["E0", "E1", "E4", "E5", "G5", "E3", "H3", "H4", "H5", "H6", "B4", "B5", "B6", "B7", "J1",
                           "J0", "H1", "H0", "D3", "D2", "D1", "D0", "A0", "A1", "A2", "A3", "A4", "A5", "A6", "A7",
                           "C7", "C6", "C5", "C4", "C3", "C2", "C1", "C0", "D7", "G2", "G1", "G0", "L7", "L6", "L5",
                           "L4", "L3", "L2", "L1", "L0", "B3", "B2", "B1", "B0", "F0", "F1", "F2", "F3", "F4", "F5",
                           "F6", "F7", "K0", "K1", "K2", "K3", "K4", "K5", "K6", "K7"]

    /// The Arduino Mega 2560's chip: 256 KB of flash (a 3-byte return address), ports A-L, six timers, four USARTs,
    /// sixteen analog inputs
    public static let atmega2560: AVRVariant = {
        let portNames = Array("ABCDEFGHJKL")
        let pins = megaPins.map { PortBit(port: portNames.firstIndex(of: $0.first!)!, bit: Int(String($0.last!))!) }
        func pin(_ name: String) -> Int { megaPins.firstIndex(of: name)! }
        var channels: [Int: Int] = [0x1E: adcBandgap, 0x1F: adcGround]
        for channel in 0..<8 {
            channels[channel] = 54 + channel
            channels[0x20 + channel] = 62 + channel
        }
        func timer16(_ base: Int, mask: Int, flag: Int, vectors: (capture: Int, a: Int, b: Int, c: Int, overflow: Int),
                     pins: [String]) -> Timer {
            Timer(kind: .standard16, controlA: base, controlB: base + 1, count: base + 4,
                  compare: [base + 8, base + 10, base + 12], maskRegister: mask, flagRegister: flag, overflowBit: 1,
                  compareBits: [2, 4, 8], overflowVector: vectors.overflow, compareVectors: [vectors.a, vectors.b, vectors.c],
                  prescalers: standardPrescalers, pins: pins.map(pin), capture: base + 6, captureBit: 0x20,
                  captureVector: vectors.capture)
        }
        func external(_ name: String, _ control: Int, _ shift: Int, _ bit: Int, _ vector: Int) -> ExternalInterrupt {
            ExternalInterrupt(pin: pin(name), control: control, shift: shift, mask: 0x3D, maskBit: UInt8(1 << bit),
                              flag: 0x3C, flagBit: UInt8(1 << bit), vector: vector)
        }
        return AVRVariant(
            name: "ATmega2560", clock: 16_000_000, flashWords: 131_072, dataSize: 0x2200, eepromSize: 4096, ioEnd: 0x200,
            pcBytes: 3, vectorWords: 2,
            ports: [0x20, 0x23, 0x26, 0x29, 0x2C, 0x2F, 0x32, 0x100, 0x103, 0x106, 0x109], pins: pins,
            timers: [
                Timer(kind: .standard8, controlA: 0x44, controlB: 0x45, count: 0x46, compare: [0x47, 0x48],
                      maskRegister: 0x6E, flagRegister: 0x35, overflowBit: 1, compareBits: [2, 4], overflowVector: 23,
                      compareVectors: [21, 22], prescalers: standardPrescalers, pins: [pin("B7"), pin("G5")]),
                timer16(0x80, mask: 0x6F, flag: 0x36, vectors: (16, 17, 18, 19, 20), pins: ["B5", "B6", "B7"]),
                Timer(kind: .standard8, controlA: 0xB0, controlB: 0xB1, count: 0xB2, compare: [0xB3, 0xB4],
                      maskRegister: 0x70, flagRegister: 0x37, overflowBit: 1, compareBits: [2, 4], overflowVector: 15,
                      compareVectors: [13, 14], prescalers: timer2Prescalers, pins: [pin("B4"), pin("H6")]),
                timer16(0x90, mask: 0x71, flag: 0x38, vectors: (31, 32, 33, 34, 35), pins: ["E3", "E4", "E5"]),
                timer16(0xA0, mask: 0x72, flag: 0x39, vectors: (41, 42, 43, 44, 45), pins: ["H3", "H4", "H5"]),
                timer16(0x120, mask: 0x73, flag: 0x3A, vectors: (46, 47, 48, 49, 50), pins: ["L3", "L4", "L5"]),
            ],
            usarts: [
                USART(base: 0xC0, rxVector: 25, udreVector: 26, txVector: 27, rxPin: pin("E0"), txPin: pin("E1")),
                USART(base: 0xC8, rxVector: 36, udreVector: 37, txVector: 38, rxPin: pin("D2"), txPin: pin("D3")),
                USART(base: 0xD0, rxVector: 51, udreVector: 52, txVector: 53, rxPin: pin("H0"), txPin: pin("H1")),
                USART(base: 0x130, rxVector: 54, udreVector: 55, txVector: 56, rxPin: pin("J0"), txPin: pin("J1")),
            ],
            adc: ADC(multiplexer: 0x7C, control: 0x7A, controlB: 0x7B, low: 0x78, high: 0x79, vector: 29, mux5: true,
                     tiny: false, muxMask: 0x1F, channels: channelTable(channels),
                     references: referenceTable([2: 1.1, 3: 2.56])),
            externalInterrupts: [
                external("D0", 0x69, 0, 0, 1), external("D1", 0x69, 2, 1, 2), external("D2", 0x69, 4, 2, 3),
                external("D3", 0x69, 6, 3, 4), external("E4", 0x6A, 0, 4, 5), external("E5", 0x6A, 2, 5, 6),
            ],
            pinChanges: [
                PinChange(control: 0x68, controlBit: 1, flag: 0x3B, flagBit: 1, mask: 0x6B,
                          pins: (0..<8).map { pin("B\($0)") }, vector: 9),
                PinChange(control: 0x68, controlBit: 2, flag: 0x3B, flagBit: 2, mask: 0x6C,
                          pins: [pin("E0"), pin("J0"), pin("J1"), -1, -1, -1, -1, -1], vector: 10),
                PinChange(control: 0x68, controlBit: 4, flag: 0x3B, flagBit: 4, mask: 0x6D,
                          pins: (0..<8).map { pin("K\($0)") }, vector: 11),
            ],
            eepromRegisters: (0x3F, 0x40, 0x41, 0x42),
            clearOnWrite: [0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C],
            maskRegisters: [0x6E, 0x6F, 0x70, 0x71, 0x72, 0x73, 0x3D, 0x68],
            spi: SPI(control: 0x4C, vector: 24, sck: pin("B1"), mosi: pin("B2"), miso: pin("B3"), ss: pin("B0")),
            twi: TWI(rate: 0xB8, vector: 39, sda: pin("D1"), scl: pin("D0")))
    }()

    /// The ATtiny85 at 8 MHz (its internal oscillator): D0-D5 are PB0-PB5; no USART
    public static let attiny85: AVRVariant = {
        AVRVariant(
            name: "ATtiny85", clock: 8_000_000, flashWords: 4096, dataSize: 0x260, eepromSize: 512, ioEnd: 0x60,
            pcBytes: 2, vectorWords: 1, ports: [0x36], pins: (0..<6).map { PortBit(port: 0, bit: $0) },
            timers: [
                // TIFR/TIMSK: OCF1A 6, OCF1B 5, OCF0A 4, OCF0B 3, TOV1 2, TOV0 1
                Timer(kind: .standard8, controlA: 0x4A, controlB: 0x53, count: 0x52, compare: [0x49, 0x48],
                      maskRegister: 0x59, flagRegister: 0x58, overflowBit: 2, compareBits: [16, 8], overflowVector: 5,
                      compareVectors: [10, 11], prescalers: standardPrescalers, pins: [0, 1]),
                Timer(kind: .tiny1, controlA: 0x50, controlB: 0x4C, count: 0x4F, compare: [0x4E, 0x4B],
                      maskRegister: 0x59, flagRegister: 0x58, overflowBit: 4, compareBits: [64, 32], overflowVector: 4,
                      compareVectors: [3, 9], prescalers: [0] + (0..<15).map { 1 << $0 }, pins: [1, 4],
                      top: 0x4D, complements: [0, 3]),
            ],
            usarts: [],
            adc: ADC(multiplexer: 0x27, control: 0x26, controlB: 0x23, low: 0x24, high: 0x25, vector: 8, mux5: false,
                     tiny: true, muxMask: 0x0F,
                     channels: channelTable([0: 5, 1: 2, 2: 4, 3: 3, 12: adcBandgap, 13: adcGround]),
                     references: referenceTable([2: 1.1, 6: 2.56, 7: 2.56])),
            externalInterrupts: [
                ExternalInterrupt(pin: 2, control: 0x55, shift: 0, mask: 0x5B, maskBit: 64, flag: 0x5A, flagBit: 64, vector: 1),
            ],
            pinChanges: [
                PinChange(control: 0x5B, controlBit: 32, flag: 0x5A, flagBit: 32, mask: 0x35,
                          pins: [0, 1, 2, 3, 4, 5, -1, -1], vector: 2),
            ],
            eepromRegisters: (0x3C, 0x3D, 0x3E, 0x3F),
            clearOnWrite: [0x58, 0x5A],
            maskRegisters: [0x59, 0x5B])
    }()
}
