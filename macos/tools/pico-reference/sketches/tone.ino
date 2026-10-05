// tone() runs on a PIO state machine: 440 Hz on GP5 for half a second, then 1 kHz
void setup() {
  tone(5, 440);
  delay(500);
  tone(5, 1000);
}

void loop() {}
