// Two slow waves from an MCP4822 over SPI: a 2 Hz sine on output A and a 2 Hz triangle on output B, each between
// about 0.04 V and 2 V (its 2.048 V reference, gain 1): control voltages for a synth
#include <SPI.h>

const int csPin = 10;

void writeDAC(byte channel, int code) {
  // bit 15 picks the channel, 13 sets gain 1, 12 turns it on; then the 12-bit code
  unsigned int word = (channel ? 0x8000 : 0) | 0x3000 | (code & 0x0FFF);
  digitalWrite(csPin, LOW);
  SPI.transfer16(word);
  digitalWrite(csPin, HIGH);
}

void setup() {
  pinMode(csPin, OUTPUT);
  digitalWrite(csPin, HIGH);
  SPI.begin();
  SPI.beginTransaction(SPISettings(8000000, MSBFIRST, SPI_MODE0));
}

void loop() {
  float cycles = millis() / 500.0;  // 2 Hz
  float sine = sin(2 * PI * cycles);
  float triangle = 4 * fabs(cycles - floor(cycles + 0.5)) - 1;
  writeDAC(0, 2048 + 2000 * sine);
  writeDAC(1, 2048 + 2000 * triangle);
}
