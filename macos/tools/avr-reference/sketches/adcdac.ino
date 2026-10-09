// Reads the knob on CH0 of an MCP3008 (SPI) and sets an MCP4725 (I2C) to the same voltage: the DAC's output follows
// the knob. The readings go to the serial monitor.
#include <SPI.h>
#include <Wire.h>

const int csPin = 10;
unsigned long lastPrint = 0;

int readADC(int channel) {
  digitalWrite(csPin, LOW);
  SPI.transfer(0x01);                                  // the start bit
  byte high = SPI.transfer(0x80 | (channel << 4));     // single-ended, the channel; back: the code's top two bits
  byte low = SPI.transfer(0);                          // back: its low eight
  digitalWrite(csPin, HIGH);
  return (high & 0x03) << 8 | low;
}

void writeDAC(int code) {
  Wire.beginTransmission(0x60);
  Wire.write(0x40);                // write the DAC register
  Wire.write(code >> 4);           // D11-D4
  Wire.write((code & 0x0F) << 4);  // D3-D0
  Wire.endTransmission();
}

void setup() {
  Serial.begin(9600);
  pinMode(csPin, OUTPUT);
  digitalWrite(csPin, HIGH);
  SPI.begin();
  SPI.beginTransaction(SPISettings(1000000, MSBFIRST, SPI_MODE0));
  Wire.begin();
  Wire.setClock(400000);
}

void loop() {
  int reading = readADC(0);  // 0-1023 of VREF
  writeDAC(reading * 4);     // 0-4092 of VDD
  if (millis() - lastPrint >= 200) {
    lastPrint = millis();
    Serial.print("CH0: ");
    Serial.println(reading);
  }
}
