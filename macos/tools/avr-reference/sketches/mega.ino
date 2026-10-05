// Exercises the Mega 2560's own parts: timers 3-5, Serial1, analog inputs A8-A15 (MUX5), INT4 and far flash
#include <avr/pgmspace.h>
const uint8_t padding[30000] PROGMEM = {1, 2, 3, 4};
const uint8_t padding2[30000] PROGMEM = {5, 6};
const uint8_t padding3[30000] PROGMEM = {7, 8};
const char farText[] PROGMEM = "far flash";
volatile long changes = 0;
void changed() { changes++; }
const uint8_t pwmPins[] = {2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 44, 45, 46};

void setup() {
  Serial.begin(115200);
  Serial1.begin(9600);
  for (uint8_t i = 0; i < sizeof(pwmPins); i++) analogWrite(pwmPins[i], 10 + i * 17);
  pinMode(21, INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(21), changed, CHANGE);
  Serial.println(analogRead(A0));
  Serial.println(analogRead(A9));
  Serial.println(analogRead(A15));
  Serial1.println("serial one");
  uint_farptr_t text = pgm_get_far_address(farText);
  for (uint8_t i = 0; i < 9; i++) Serial.write(pgm_read_byte_far(text + i));
  Serial.println();
  Serial.println(pgm_read_byte_far(pgm_get_far_address(padding) + 2));
  Serial.println(pgm_read_byte(&padding2[1]) + pgm_read_byte_far(pgm_get_far_address(padding3) + 1));
}

void loop() {
  static uint8_t n = 0;
  Serial.print(millis());
  Serial.print(' ');
  Serial.println(changes);
  digitalWrite(13, n & 1);
  if (++n > 5) { noInterrupts(); while (1); }
  delay(5);
}
