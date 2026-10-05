// Blink and count on the Pico: the LED on GP25 toggles every 100 ms, and Serial (USB) prints the count
int count = 0;

void setup() {
  Serial.begin(115200);
  pinMode(LED_BUILTIN, OUTPUT);
  pinMode(15, OUTPUT);
}

void loop() {
  digitalWrite(LED_BUILTIN, count & 1);
  digitalWrite(15, count & 1);
  Serial.print("count ");
  Serial.println(count++);
  delay(100);
}
