volatile int presses = 0;
void count() { presses++; }
void setup() {
  pinMode(2, INPUT_PULLUP);
  pinMode(13, OUTPUT);
  attachInterrupt(digitalPinToInterrupt(2), count, FALLING);
  Serial.begin(9600);
}
void loop() {
  digitalWrite(13, presses & 1);
  static int last = -1;
  if (presses != last) { last = presses; Serial.println(presses); }
}
