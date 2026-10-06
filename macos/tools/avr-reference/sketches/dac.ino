// An MCP4921 on SPI (CS on pin 10, at 8 MHz): five codes, each held for 5 ms
#include <SPI.h>

const int CS = 10;
const uint16_t codes[] = {0, 1024, 2048, 3072, 4095};

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
}

void loop() {
  for (int k = 0; k < 5; k++) {
    writeDac(codes[k]);
    delay(5);
  }
}
