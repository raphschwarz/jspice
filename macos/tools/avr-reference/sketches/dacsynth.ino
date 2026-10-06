// A sawtooth from a phase accumulator, a new sample every 125 µs (8 kHz), sent to an MCP4921 DAC on SPI (CS on
// pin 10), playing an A minor arpeggio: a quarter of a second a note
#include <SPI.h>

const int CS = 10;
// the phase step for each note: 65536 * frequency / 8000
const uint16_t steps[] = {901, 1072, 1350, 1802};
uint16_t phase = 0;
int note = 0;
unsigned int samples = 0;
unsigned long next;

void writeDac(uint16_t code) {
  digitalWrite(CS, LOW);
  SPI.transfer16(0x3000 | code);  // DAC A, unbuffered, gain 1, on
  digitalWrite(CS, HIGH);
}

void setup() {
  pinMode(CS, OUTPUT);
  digitalWrite(CS, HIGH);
  SPI.begin();
  SPI.beginTransaction(SPISettings(8000000, MSBFIRST, SPI_MODE0));
  next = micros();
}

void loop() {
  while ((long)(micros() - next) < 0) {}
  next += 125;
  writeDac(phase >> 4);
  phase += steps[note];
  if (++samples == 2000) {
    samples = 0;
    note = (note + 1) % 4;
  }
}
