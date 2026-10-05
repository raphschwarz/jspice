// SPI and I2C as a master: two SPI transfers on SPI0 (GP16 MISO, GP18 SCK, GP19 MOSI; the test loops MOSI back to
// MISO), then Wire (GP4 SDA, GP5 SCL) writing a byte to three addresses (only 0x42 answers) and reading two bytes back.
// The report is printed over and over, so it reaches USB serial whenever the computer has enumerated it.
#include <SPI.h>
#include <Wire.h>

String report;

void setup() {
  SPI.begin();
  SPI.beginTransaction(SPISettings(1000000, MSBFIRST, SPI_MODE0));
  byte a = SPI.transfer(0xA5);
  byte b = SPI.transfer(0x3C);
  SPI.endTransaction();
  report = "spi " + String(a, HEX) + " " + String(b, HEX) + "\r\n";
  Wire.begin();
  for (byte address = 0x41; address <= 0x43; address++) {
    Wire.beginTransmission(address);
    Wire.write(0x10);
    report += "i2c " + String(address, HEX) + " " + String(Wire.endTransmission()) + "\r\n";
  }
  Wire.requestFrom(0x42, 2);
  report += "read";
  while (Wire.available()) report += " " + String(Wire.read(), HEX);
  report += "\r\n";
}

void loop() {
  Serial.print(report);
  delay(50);
}
