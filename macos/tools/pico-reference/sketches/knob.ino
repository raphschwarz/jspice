// Raspberry Pi Pico: the pot on GP26 (A0) sets the brightness of the LED on GP15 with PWM; the board's LED blinks
// and the readings go to the serial monitor (USB)
unsigned long lastPrint = 0;

void setup() {
  Serial.begin(115200);
  pinMode(LED_BUILTIN, OUTPUT);
  analogWriteResolution(12);  // as fine as the ADC: 0-4095
}

void loop() {
  int reading = analogRead(A0) * 4;  // analogRead gives 0-1023
  analogWrite(15, reading);
  digitalWrite(LED_BUILTIN, (millis() / 250) % 2);
  if (millis() - lastPrint >= 200) {
    lastPrint = millis();
    Serial.print("A0: ");
    Serial.print(reading);
    Serial.print("  (");
    Serial.print(reading * 3.3 / 4095, 2);
    Serial.println(" V)");
  }
}
