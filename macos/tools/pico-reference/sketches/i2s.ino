// Raspberry Pi Pico: a 440 Hz sine to a PCM5102 I2S DAC. The I2S library's own PIO program sends the bits (BCK on
// GP20, LRCK on GP21, DIN on GP22), each frame a 32-bit word (left in the top half, right in the bottom) that the
// sketch puts in the state machine's FIFO itself, about 21.9 kHz (125 MHz over 89 × 64)
#include <I2S.h>
#include "pio_i2s.pio.h"

const float rate = 125e6 / (89 * 64);
const int bck = 20, din = 22;
PIO pio = pio0;
uint sm;
float phase = 0;

void setup() {
  sm = pio_claim_unused_sm(pio, true);
  uint offset = pio_add_program(pio, &pio_i2s_out_program);
  pio_i2s_out_program_init(pio, sm, offset, 0, din, bck, 16, 2);
  // two PIO cycles a bit, 16 bits a channel, two channels: 64 cycles a frame
  pio_sm_set_clkdiv_int_frac(pio, sm, 89, 0);
  pio_sm_set_enabled(pio, sm, true);
}

void loop() {
  int16_t sample = (int16_t)(sinf(phase) * 16000);
  phase += 2 * PI * 440 / rate;
  if (phase > 2 * PI) phase -= 2 * PI;
  // waits while the FIFO is full: the PIO takes a word every frame
  pio_sm_put_blocking(pio, sm, (uint32_t)(uint16_t)sample << 16 | (uint16_t)sample);
}
