// SPI and I2C as a master: two SPI transfers (the test loops MOSI back to MISO), then an I2C scan of three addresses
// and a two-byte read from the device the test plays at 0x42
#include <SPI.h>
#include <Wire.h>

void setup() {
  Serial.begin(115200);
  SPI.begin();
  SPI.beginTransaction(SPISettings(1000000, MSBFIRST, SPI_MODE0));
  byte a = SPI.transfer(0xA5);
  byte b = SPI.transfer(0x3C);
  SPI.endTransaction();
  Serial.print("spi ");
  Serial.print(a, HEX);
  Serial.print(" ");
  Serial.println(b, HEX);
  Wire.begin();
  for (byte address = 0x41; address <= 0x43; address++) {
    Wire.beginTransmission(address);
    Wire.write(0x10);
    Serial.print("i2c ");
    Serial.print(address, HEX);
    Serial.print(" ");
    Serial.println(Wire.endTransmission());
  }
  Wire.requestFrom(0x42, 2);
  Serial.print("read");
  while (Wire.available()) {
    Serial.print(" ");
    Serial.print(Wire.read(), HEX);
  }
  Serial.println();
}

void loop() {}
