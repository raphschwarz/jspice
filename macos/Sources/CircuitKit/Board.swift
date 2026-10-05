import Foundation

/// A microcontroller board (or bare chip) a part can be: its chip, its pins and how they are drawn, what compiles for
/// it and how its firmware runs
public enum Board: String, CaseIterable, Identifiable, Sendable {
    case uno
    case mega
    case attiny85

    public var id: String { rawValue }

    public init?(kind: ElementKind) {
        switch kind {
        case .atmega328p: self = .uno
        case .atmega2560: self = .mega
        case .attiny85: self = .attiny85
        default: return nil
        }
    }

    public var kind: ElementKind {
        switch self {
        case .uno: return .atmega328p
        case .mega: return .atmega2560
        case .attiny85: return .attiny85
        }
    }

    /// "Arduino Uno"
    public var title: String {
        switch self {
        case .uno: return "Arduino Uno"
        case .mega: return "Arduino Mega 2560"
        case .attiny85: return "ATtiny85"
        }
    }

    /// The chip's name, as on its package
    public var chip: String {
        switch self {
        case .uno: return "ATmega328P"
        case .mega: return "ATmega2560"
        case .attiny85: return "ATtiny85"
        }
    }

    /// What compiling for it takes
    public var family: ChipFamily { .avr }

    /// The AVR layout, for AVR boards
    public var avrVariant: AVRVariant? {
        switch self {
        case .uno: return .atmega328p
        case .mega: return .atmega2560
        case .attiny85: return .attiny85
        }
    }

    public var clock: Double { avrVariant?.clock ?? 0 }

    /// The supply the chip runs from (and its logic high)
    public var supply: Double { 5 }

    /// Bytes of flash a sketch can use (the rest holds the bootloader)
    public var flashSize: Int {
        switch self {
        case .uno: return 32_256
        case .mega: return 253_952
        case .attiny85: return 8192
        }
    }

    /// Whether the board has a serial port the serial monitor shows (the ATtiny85 has none)
    public var hasSerial: Bool { self != .attiny85 }

    /// The terminals' names, in order: as the sketch numbers the pins
    public var terminalNames: [String] {
        switch self {
        case .uno: return (0...13).map { "d\($0)" } + (0...5).map { "a\($0)" }
        case .mega: return (0...53).map { "d\($0)" } + (0...15).map { "a\($0)" }
        case .attiny85: return (0...5).map { "pb\($0)" }
        }
    }

    /// The pin labels drawn on the part
    public var pinLabels: [String] {
        switch self {
        case .uno: return (0...13).map { "D\($0)" } + (0...5).map { "A\($0)" }
        case .mega: return (0...53).map { "D\($0)" } + (0...15).map { "A\($0)" }
        case .attiny85: return (0...5).map { "PB\($0)" }
        }
    }

    /// Where a terminal sits: on the first side of the part (opposite its perpendicular) or the second, and how many
    /// grid units from its start
    public struct PinPlace: Sendable, Equatable {
        public let second: Bool
        public let offset: Int
    }

    public var pinPlaces: [PinPlace] {
        func side(_ second: Bool, _ offsets: ClosedRange<Int>, from start: Int = 0) -> [PinPlace] {
            offsets.map { PinPlace(second: second, offset: start + $0) }
        }
        switch self {
        case .uno:
            return side(false, 0...13) + side(true, 0...5)
        case .mega:
            // D0-D35 down one side; D36-D53, then A0-A15 after a gap, down the other
            return side(false, 0...35) + side(true, 0...17) + side(true, 0...15, from: 19)
        case .attiny85:
            return side(false, 0...2) + side(true, 0...2)
        }
    }

    /// The part's length in grid units
    public var length: Int {
        switch self {
        case .uno: return 13
        case .mega: return 35
        case .attiny85: return 3
        }
    }

    /// The analog inputs, as terminal indices
    public var analogPins: [Int] {
        switch self {
        case .uno: return Array(14...19)
        case .mega: return Array(54...69)
        case .attiny85: return [5, 2, 4, 3]
        }
    }

    /// A chip running `firmware`
    public func makeChip(firmware: [UInt8]) -> Microcontroller {
        AVR(firmware: firmware, variant: avrVariant ?? .atmega328p)
    }

    /// The sketch a new part starts with
    public var blinkSketch: String {
        let pin = self == .attiny85 ? "1" : "LED_BUILTIN"
        return """
            // Runs once when the chip starts
            void setup() {
              pinMode(\(pin), OUTPUT);
            }

            // Runs over and over
            void loop() {
              digitalWrite(\(pin), HIGH);
              delay(500);
              digitalWrite(\(pin), LOW);
              delay(500);
            }
            """
    }

    // MARK: - Compiling

    /// avr-gcc's name for the chip
    public var mcu: String {
        switch self {
        case .uno: return "atmega328p"
        case .mega: return "atmega2560"
        case .attiny85: return "attiny85"
        }
    }

    /// The board's define, as the Arduino IDE passes it
    var boardDefine: String {
        switch self {
        case .uno: return "-DARDUINO_AVR_UNO"
        case .mega: return "-DARDUINO_AVR_MEGA2560"
        case .attiny85: return "-DARDUINO_AVR_ATTINYX5"
        }
    }

    /// The Arduino AVR core's pin map for the board (nil: JSpice's own, `variantHeader`)
    var coreVariant: String? {
        switch self {
        case .uno: return "standard"
        case .mega: return "mega"
        case .attiny85: return nil
        }
    }

    /// JSpice's pin map for a board the Arduino AVR core has none for (tools/avr-reference/variants/<board> holds the
    /// same file)
    public var variantHeader: String {
        switch self {
        case .attiny85: return Board.tiny85Header
        default: return ""
        }
    }

    static let tiny85Header = """
// JSpice's pin map for the ATtiny85 with the Arduino AVR core (the same numbering as the common ATtiny cores):
// D0-D5 are PB0-PB5, and A0-A3 (also 6-9) are the analog inputs ADC0-ADC3 on PB5, PB2, PB4 and PB3.
//
//                 +-\/-+
//  A0 (D5) PB5  1|    |8  VCC
//  A3 (D3) PB3  2|    |7  PB2 (D2) A1
//  A2 (D4) PB4  3|    |6  PB1 (D1) PWM
//          GND  4|    |5  PB0 (D0) PWM
//                 +----+
// PWM: D0 and D1 (timer 0), D4 (timer 1). No hardware serial port: use SoftwareSerial.
#ifndef Pins_Arduino_h
#define Pins_Arduino_h

#include <avr/pgmspace.h>

#define NUM_DIGITAL_PINS 6
#define NUM_ANALOG_INPUTS 4
#define analogInputToDigitalPin(p) (((p) == 0) ? 5 : ((p) == 1) ? 2 : ((p) == 2) ? 4 : ((p) == 3) ? 3 : -1)
#define digitalPinHasPWM(p) ((p) == 0 || (p) == 1 || (p) == 4)

#define PIN_A0 (6)
#define PIN_A1 (7)
#define PIN_A2 (8)
#define PIN_A3 (9)
static const uint8_t A0 = PIN_A0;
static const uint8_t A1 = PIN_A1;
static const uint8_t A2 = PIN_A2;
static const uint8_t A3 = PIN_A3;

#define LED_BUILTIN 1

#define digitalPinToPCICR(p) (((p) >= 0 && (p) <= 5) ? (&GIMSK) : ((uint8_t *)0))
#define digitalPinToPCICRbit(p) (PCIE)
#define digitalPinToPCMSK(p) (((p) >= 0 && (p) <= 5) ? (&PCMSK) : ((uint8_t *)0))
#define digitalPinToPCMSKbit(p) (p)
#define digitalPinToInterrupt(p) ((p) == 2 ? 0 : NOT_AN_INTERRUPT)

#define analogPinToChannel(p) ((p) < 6 ? (p) : (p) - 6)

// timer 1 PWM on PB4 (OC1B): the core's analogWrite sets COM1B1 in "TCCR1A", which is GTCCR here
#define TCCR1A GTCCR

#ifdef ARDUINO_MAIN

void initVariant() {
    GTCCR |= (1 << PWM1B);
}

const uint16_t PROGMEM port_to_mode_PGM[] = {NOT_A_PORT, NOT_A_PORT, (uint16_t)&DDRB};
const uint16_t PROGMEM port_to_output_PGM[] = {NOT_A_PORT, NOT_A_PORT, (uint16_t)&PORTB};
const uint16_t PROGMEM port_to_input_PGM[] = {NOT_A_PIN, NOT_A_PIN, (uint16_t)&PINB};

const uint8_t PROGMEM digital_pin_to_port_PGM[] = {PB, PB, PB, PB, PB, PB, PB, PB, PB, PB};
const uint8_t PROGMEM digital_pin_to_bit_mask_PGM[] = {
    _BV(0), _BV(1), _BV(2), _BV(3), _BV(4), _BV(5),  // D0-D5
    _BV(5), _BV(2), _BV(4), _BV(3),                  // A0-A3
};
const uint8_t PROGMEM digital_pin_to_timer_PGM[] = {
    TIMER0A, TIMER0B, NOT_ON_TIMER, NOT_ON_TIMER, TIMER1B, NOT_ON_TIMER,
    NOT_ON_TIMER, NOT_ON_TIMER, NOT_ON_TIMER, NOT_ON_TIMER,
};

#endif

#endif
"""
}

extension ElementKind {
    /// The board a microcontroller part is
    public var board: Board? { Board(kind: self) }

    public var isMicrocontroller: Bool { board != nil }
}
