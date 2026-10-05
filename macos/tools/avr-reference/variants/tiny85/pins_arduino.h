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
