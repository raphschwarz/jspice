// Exercises the ATtiny85: timers 0 and 1 (PWM on D0, D1, D4), the ADC, INT0, EEPROM and code without MUL
#include <EEPROM.h>
volatile uint8_t presses = 0;
volatile uint32_t result = 0;
volatile float root = 0;
void pressed() { presses++; }

void setup() {
  pinMode(3, OUTPUT);
  pinMode(2, INPUT_PULLUP);
  analogWrite(0, 50);
  analogWrite(1, 150);
  analogWrite(4, 99);
  attachInterrupt(0, pressed, FALLING);
  EEPROM.write(3, 42);
  result = EEPROM.read(3) + analogRead(A1) + analogRead(A2) + analogRead(A3);
}

void loop() {
  static uint32_t x = 12345;
  x = x * 1103515245UL + 12345;
  root = sqrt((float)(x & 0xFFFF));
  result += x % 1000 + presses;
  digitalWrite(3, (millis() / 3) & 1);
  delay(1);
}
