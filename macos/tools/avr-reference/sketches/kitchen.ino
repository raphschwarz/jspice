#include <avr/pgmspace.h>
const char message[] PROGMEM = "flash string";
volatile uint8_t ticks = 0;
typedef long (*Operation)(long, long);
long add(long a, long b) { return a + b; }
long mul(long a, long b) { return a * b; }
long dv(long a, long b) { return b ? a / b : 0; }
Operation operations[] = {add, mul, dv};

unsigned long fib(unsigned char n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

int classify(int v) {
  switch (v % 7) {
    case 0: return 10; case 1: return 21; case 2: return 33; case 3: return 47;
    case 4: return 52; case 5: return 68; default: return 99;
  }
}

void setup() {
  Serial.begin(115200);
  pinMode(13, OUTPUT);
  analogWrite(9, 77);
  analogWrite(5, 200);
  analogWrite(11, 31);
  char buffer[20];
  strcpy_P(buffer, message);
  Serial.println(buffer);
  long x = 123456789L;
  for (int i = 0; i < 3; i++) Serial.println(operations[i](x, 1234));
  Serial.println(fib(15));
  float f = 3.14159f;
  Serial.println(sin(f / 3), 5);
  Serial.println(sqrt(2.0), 6);
  Serial.println(pow(1.5, 7.25), 4);
  Serial.println(f * 1e6, 2);
  Serial.println(-12345.678f / 7.0f, 3);
  int sum = 0;
  for (int i = -50; i < 50; i++) sum += classify(i) * (i & 3) - (i >> 2);
  Serial.println(sum);
  uint32_t h = 2166136261UL;
  for (uint8_t i = 0; i < 200; i++) { h ^= i; h *= 16777619UL; }
  Serial.println(h, HEX);
  int16_t s16 = -30000; s16 = s16 / 7 + (s16 % 13);
  Serial.println(s16);
  uint8_t bits = 0xA5; bits = (bits << 3) | (bits >> 5);
  Serial.println(bits, BIN);
  Serial.println(analogRead(A0));
  Serial.println(analogRead(A3));
  Serial.println(millis());
}

void loop() {
  digitalWrite(13, !digitalRead(13));
  Serial.println(micros());
  delay(3);
}
