// Raspberry Pi Pico: tone() plays a tune on GP5, from one of the RP2040's PIO state machines
const int notes[] = {262, 294, 330, 349, 392, 440, 494, 523, 0, 523, 392, 330, 262};
const int beats[] = {1, 1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 2};

void setup() {
  pinMode(LED_BUILTIN, OUTPUT);
}

void loop() {
  for (int i = 0; i < 13; i++) {
    digitalWrite(LED_BUILTIN, notes[i] != 0);
    if (notes[i]) {
      tone(5, notes[i]);
    } else {
      noTone(5);
    }
    delay(200 * beats[i]);
  }
  noTone(5);
  digitalWrite(LED_BUILTIN, LOW);
  delay(800);
}
