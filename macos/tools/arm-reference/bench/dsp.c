// A benchmark for the Cortex-M4 core: the kinds of loops an audio module's firmware spends its time in (a float
// biquad and a float state-variable filter over a block, a fixed-point oscillator reading a wavetable with
// interpolation, Q15 saturating mixing with the DSP extension, a block copy), block after block, with a SysTick
// interrupt as a firmware's timebase. Ends on BKPT after a fixed number of blocks.
#include <stdint.h>
#include <string.h>

#define BLOCK 32
#define BLOCKS 2000
#define REG(address) (*(volatile uint32_t *)(address))

static float in[BLOCK], out[BLOCK], aux[BLOCK];
static int16_t wave[257];
static int16_t mixed[BLOCK];
volatile uint32_t ticks;
volatile uint32_t checksum;

void systick_handler(void) { ticks++; }

typedef struct { float b0, b1, b2, a1, a2, x1, x2, y1, y2; } Biquad;
typedef struct { float lp, bp, f, damp; } Svf;

static void biquad(Biquad *q, const float *x, float *y, int n) {
    for (int i = 0; i < n; i++) {
        float v = q->b0 * x[i] + q->b1 * q->x1 + q->b2 * q->x2 - q->a1 * q->y1 - q->a2 * q->y2;
        q->x2 = q->x1; q->x1 = x[i]; q->y2 = q->y1; q->y1 = v;
        y[i] = v;
    }
}

static void svf(Svf *s, const float *x, float *y, int n) {
    float lp = s->lp, bp = s->bp;
    for (int i = 0; i < n; i++) {
        float hp = x[i] - lp - s->damp * bp;
        bp += s->f * hp;
        lp += s->f * bp;
        y[i] = lp;
    }
    s->lp = lp; s->bp = bp;
}

static uint32_t phase, increment = 0x01234567;

static void oscillator(int16_t *y, int n) {
    for (int i = 0; i < n; i++) {
        phase += increment;
        uint32_t index = phase >> 24, fraction = (phase >> 8) & 0xFFFF;
        int32_t a = wave[index], b = wave[index + 1];
        y[i] = (int16_t)(a + (((b - a) * (int32_t)fraction) >> 16));
    }
}

static void mix(int16_t *y, const float *x, int n) {
    for (int i = 0; i < n; i++) {
        int32_t sample = (int32_t)(x[i] * 16384.0f);
        int32_t sum;
        __asm__("qadd16 %0, %1, %2" : "=r"(sum) : "r"(sample), "r"((int32_t)y[i]));
        y[i] = (int16_t)sum;
    }
}

int main(void) {
    for (int i = 0; i < 257; i++) wave[i] = (int16_t)((i * 37 % 256 - 128) * 200);
    REG(0xE000E014) = 167999;
    REG(0xE000E018) = 0;
    REG(0xE000E010) = 7;
    Biquad q = { 0.2f, 0.4f, 0.2f, -0.5f, 0.3f, 0, 0, 0, 0 };
    Svf s = { 0, 0, 0.1f, 0.5f };
    uint32_t noise = 1;
    for (int block = 0; block < BLOCKS; block++) {
        for (int i = 0; i < BLOCK; i++) {
            noise = noise * 1664525u + 1013904223u;
            in[i] = (float)(int32_t)noise * (1.0f / 2147483648.0f);
        }
        biquad(&q, in, out, BLOCK);
        svf(&s, out, aux, BLOCK);
        oscillator(mixed, BLOCK);
        mix(mixed, aux, BLOCK);
        memcpy(in, aux, sizeof in);
        uint32_t sum = 0;
        for (int i = 0; i < BLOCK; i++) sum = sum * 31 + (uint16_t)mixed[i];
        checksum += sum;
    }
    return 0;
}

extern uint32_t _data, _edata, _data_load, _bss, _ebss, _stack_top;

__attribute__((naked, noreturn)) void reset(void) {
    __asm__ volatile("ldr r0, =0xE000ED88\nldr r1, [r0]\norr r1, r1, #(0xF << 20)\nstr r1, [r0]\ndsb\nisb\nb start\n");
}

__attribute__((noreturn)) void start(void) {
    for (uint32_t *from = &_data_load, *to = &_data; to < &_edata;) *to++ = *from++;
    for (uint32_t *to = &_bss; to < &_ebss;) *to++ = 0;
    main();
    __asm__ volatile("bkpt #0");
    for (;;) {}
}

void default_handler(void) { __asm__ volatile("bkpt #1"); for (;;) {} }

__attribute__((section(".vectors"), used)) const void *vectors[16] = {
    &_stack_top, reset, default_handler, default_handler, default_handler, default_handler, default_handler, 0, 0, 0,
    0, default_handler, default_handler, 0, default_handler, systick_handler,
};
