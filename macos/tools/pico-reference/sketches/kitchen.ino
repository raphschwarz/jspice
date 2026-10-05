// Exercises what the Pico emulator has to get right: a pin-change interrupt, the ADC, PWM, USB serial in and out,
// floating point, 64-bit and hardware division, micros() and the timer alarms behind delay()
volatile int edges = 0;
unsigned long last = 0;

void onEdge() { edges++; }

void setup() {
  Serial.begin(115200);
  pinMode(2, INPUT_PULLUP);
  pinMode(3, OUTPUT);
  attachInterrupt(digitalPinToInterrupt(2), onEdge, FALLING);
  analogWriteFreq(2000);
  analogWriteRange(255);
  analogWrite(4, 64);
}

void loop() {
  static int round = 0;
  digitalWrite(3, round & 1);
  int raw = analogRead(A0);
  float volts = raw * 3.3f / 1023.0f;
  long long big = (long long)raw * 1234567891LL / (round + 7);
  int q = (raw * 1000 + 17) / (round + 3);
  analogWrite(4, (raw >> 2) & 255);
  Serial.print("r=");
  Serial.print(round);
  Serial.print(" adc=");
  Serial.print(raw);
  Serial.print(" v=");
  Serial.print(volts, 3);
  Serial.print(" sqrt=");
  Serial.print(sqrtf(volts + 1.0f), 4);
  Serial.print(" big=");
  Serial.print((long)(big % 1000003));
  Serial.print(" q=");
  Serial.print(q);
  Serial.print(" edges=");
  Serial.println(edges);
  while (Serial.available()) {
    int c = Serial.read();
    Serial.print("echo ");
    Serial.println((char)toupper(c));
  }
  round++;
  delay(25);
}
