// A self-test for the Cortex-M4 core (Sources/CortexM4): integer, DSP and floating-point arithmetic, exclusives,
// bit-banding, and the system around the core (SysTick, SVC, PendSV, priorities and BASEPRI, the process stack, an
// interrupt that uses the FPU while the code it interrupted does). Each check writes a result the test compares;
// the program ends on BKPT.
//
// Built by build.sh with arm-none-eabi-gcc; CircuitKitTests runs the image it leaves (Fixtures/cm4-selftest.bin).

#include <stdint.h>

#define REG(address) (*(volatile uint32_t *)(address))
#define SYST_CSR REG(0xE000E010)
#define SYST_RVR REG(0xE000E014)
#define SYST_CVR REG(0xE000E018)
#define ICSR REG(0xE000ED04)
#define SHPR3 REG(0xE000ED20)
#define CPACR REG(0xE000ED88)
#define NVIC_ISER0 REG(0xE000E100)
#define NVIC_ISPR0 REG(0xE000E200)
#define NVIC_IPR(n) (*(volatile uint8_t *)(0xE000E400 + (n)))
#define STIR REG(0xE000EF00)

enum {
    R_MARKER, R_CRC, R_HARMONIC, R_SQRT, R_FMA, R_DIV64_LO, R_DIV64_HI, R_SERIES, R_TICKS_OK, R_HANDLER_FLOAT,
    R_SVC, R_PENDSV, R_BASEPRI, R_BITBAND, R_EXCLUSIVE, R_DSP, R_BITS, R_PSP, R_CONVERT, R_UDIV0, R_IRQ_ORDER,
    R_SATURATE, R_DONE, R_COUNT
};
__attribute__((section(".results"))) volatile uint32_t results[32];

static inline uint32_t float_bits(float f) { union { float f; uint32_t u; } x = { f }; return x.u; }

volatile uint32_t ticks;
volatile float handler_sum;
volatile uint32_t pendsv_ran;
volatile uint32_t irq_order[4];
volatile uint32_t irq_count;

void systick_handler(void) {
    ticks++;
    // floating point in a handler, while the interrupted code is in the middle of its own
    float x = handler_sum;
    for (int i = 0; i < 3; i++) x = x * 0.5f + 1.25f;
    handler_sum = x;
}

void pendsv_handler(void) { pendsv_ran = 0x50;  }

// SVC: the caller's r0 (in its stacked frame) multiplied by the SVC's number
__attribute__((naked)) void svc_handler(void) {
    __asm__ volatile(
        "tst lr, #4\n"
        "ite eq\n"
        "mrseq r0, msp\n"
        "mrsne r0, psp\n"
        "b svc_body\n");
}
void svc_body(uint32_t *frame) {
    uint16_t instruction = *(uint16_t *)(frame[6] - 2);
    frame[0] = frame[0] * (instruction & 0xFF);
}

// external interrupts 0 and 1: 1 is pended from 0's handler at a higher priority, so it runs inside it
void irq0_handler(void) {
    irq_order[irq_count++] = 0;
    NVIC_ISPR0 = 1u << 1;
    irq_order[irq_count++] = 2;
}
void irq1_handler(void) { irq_order[irq_count++] = 1; }

void default_handler(void) {
    results[R_DONE] = 0xBAD0BAD0;
    __asm__ volatile("bkpt #1");
    for (;;) {}
}

static uint32_t svc5(uint32_t value) {
    register uint32_t r0 __asm__("r0") = value;
    __asm__ volatile("svc #5" : "+r"(r0) : : "memory");
    return r0;
}

static uint32_t crc32(const char *text) {
    uint32_t crc = 0xFFFFFFFF;
    for (; *text; text++) {
        crc ^= (uint8_t)*text;
        for (int bit = 0; bit < 8; bit++) crc = (crc >> 1) ^ (0xEDB88320 & -(crc & 1));
    }
    return ~crc;
}

volatile float volatile_two = 2.0f, volatile_a = 1.1f, volatile_b = 3.3f, volatile_c = -0.7f;
volatile float volatile_negative = -3.7f, volatile_big = 5e9f;
volatile uint64_t volatile_dividend = 0x0123456789ABCDEFull;
volatile uint32_t volatile_divisor = 12345, volatile_zero = 0;

int main(void) {
    results[R_MARKER] = 0xC0FFEE;
    results[R_CRC] = crc32("The quick brown fox jumps over the lazy dog");

    float harmonic = 0;
    for (int k = 1; k <= 1000; k++) harmonic += 1.0f / (float)k;
    results[R_HARMONIC] = float_bits(harmonic);
    results[R_SQRT] = float_bits(__builtin_sqrtf(volatile_two));
    results[R_FMA] = float_bits(__builtin_fmaf(volatile_a, volatile_b, volatile_c));

    uint64_t quotient = volatile_dividend / volatile_divisor;
    results[R_DIV64_LO] = (uint32_t)quotient;
    results[R_DIV64_HI] = (uint32_t)(quotient >> 32);

    // SysTick every 1000 cycles while a float series runs: the series must come out as it would without them
    SHPR3 = (0x40u << 24) | (0xF0u << 16);  // SysTick 0x40, PendSV lowest
    SYST_RVR = 999;
    SYST_CVR = 0;
    SYST_CSR = 7;
    float series = 1.0f;
    for (int i = 0; i < 20000; i++) series = series * 0.99993f + 0.0007f;
    results[R_SERIES] = float_bits(series);
    while (ticks < 100) __asm__ volatile("wfi");
    results[R_TICKS_OK] = ticks >= 100;
    SYST_CSR = 0;
    results[R_HANDLER_FLOAT] = float_bits(handler_sum);

    results[R_SVC] = svc5(7);

    ICSR = 1u << 28;  // PENDSVSET
    __asm__ volatile("dsb\nisb");
    results[R_PENDSV] = pendsv_ran;

    // BASEPRI at SysTick's priority holds it off; lowering it lets it in
    uint32_t before = ticks;
    __asm__ volatile("msr basepri, %0" : : "r"(0x40u));
    SYST_CVR = 0;
    SYST_RVR = 99;
    SYST_CSR = 7;
    for (volatile int i = 0; i < 2000; i++) {}
    uint32_t held = ticks - before;
    __asm__ volatile("msr basepri, %0" : : "r"(0u));
    __asm__ volatile("isb");
    for (volatile int i = 0; i < 2000; i++) {}
    SYST_CSR = 0;
    results[R_BASEPRI] = (held == 0) | ((ticks - before > 0) << 1);

    // bit-band: bit 5 of a RAM word set through its alias
    static volatile uint32_t banded;
    banded = 0x100;
    uint32_t alias = 0x22000000 + ((uint32_t)&banded - 0x20000000) * 32 + 5 * 4;
    REG(alias) = 1;
    results[R_BITBAND] = banded | (REG(alias + 4) << 16);

    // an exclusive increment
    static volatile uint32_t counter = 41;
    uint32_t value, failed;
    do {
        __asm__ volatile("ldrex %0, [%1]" : "=r"(value) : "r"(&counter));
        value++;
        __asm__ volatile("strex %0, %2, [%1]" : "=&r"(failed) : "r"(&counter), "r"(value) : "memory");
    } while (failed);
    results[R_EXCLUSIVE] = counter;

    uint32_t dsp;
    __asm__ volatile("smlad %0, %1, %2, %3" : "=r"(dsp) : "r"(0x00030004), "r"(0x00050006), "r"(100));
    uint32_t sum8;
    __asm__ volatile("uadd8 %0, %1, %2" : "=r"(sum8) : "r"(0x80FF0102), "r"(0x80020304));
    uint32_t selected;
    __asm__ volatile("sel %0, %1, %2" : "=r"(selected) : "r"(0xAAAAAAAA), "r"(0x55555555));
    results[R_DSP] = dsp ^ (sum8 << 8) ^ selected;

    uint32_t bits = __builtin_clz(0x00F00000) | (__builtin_bswap32(0x11223344) & 0xFF00);
    uint32_t reversed;
    __asm__("rbit %0, %1" : "=r"(reversed) : "r"(0x00000001));
    results[R_BITS] = bits ^ reversed;

    // the thread on the process stack: an SVC from it, and back
    static uint32_t process_stack[64];
    __asm__ volatile("msr psp, %0" : : "r"(&process_stack[64]));
    __asm__ volatile("msr control, %0\nisb" : : "r"(2u));
    uint32_t from_process = svc5(9);
    uint32_t control;
    __asm__ volatile("mrs %0, control" : "=r"(control));
    __asm__ volatile("msr control, %0\nisb" : : "r"(0u));
    results[R_PSP] = from_process | ((control & 2) << 15);

    results[R_CONVERT] = (uint32_t)(int32_t)volatile_negative ^ ((uint32_t)volatile_big << 4);
    results[R_UDIV0] = volatile_divisor / volatile_zero;

    // nested external interrupts: IRQ 1 above IRQ 0
    NVIC_IPR(0) = 0x80;
    NVIC_IPR(1) = 0x20;
    NVIC_ISER0 = 3;
    STIR = 0;
    __asm__ volatile("dsb\nisb");
    results[R_IRQ_ORDER] = irq_count | irq_order[0] << 4 | irq_order[1] << 8 | irq_order[2] << 12;

    int32_t saturated;
    __asm__("ssat %0, #8, %1" : "=r"(saturated) : "r"(1000));
    uint32_t q;
    __asm__ volatile("qadd %0, %1, %2" : "=r"(q) : "r"(0x7FFFFFF0), "r"(0x100));
    uint32_t apsr;
    __asm__ volatile("mrs %0, apsr" : "=r"(apsr));
    results[R_SATURATE] = (uint32_t)saturated ^ q ^ (apsr & 0x08000000);

    results[R_DONE] = 0xD0D0;
    return 0;
}

extern uint32_t _data, _edata, _data_load, _bss, _ebss, _stack_top;

__attribute__((naked, noreturn)) void reset(void) {
    __asm__ volatile(
        "ldr r0, =0xE000ED88\n"
        "ldr r1, [r0]\n"
        "orr r1, r1, #(0xF << 20)\n"  // the FPU on
        "str r1, [r0]\n"
        "dsb\n"
        "isb\n"
        "b start\n");
}

__attribute__((noreturn)) void start(void) {
    for (uint32_t *from = &_data_load, *to = &_data; to < &_edata;) *to++ = *from++;
    for (uint32_t *to = &_bss; to < &_ebss;) *to++ = 0;
    main();
    __asm__ volatile("bkpt #0");
    for (;;) {}
}

__attribute__((section(".vectors"), used)) const void *vectors[16 + 2] = {
    &_stack_top, reset, default_handler, default_handler, default_handler, default_handler, default_handler, 0, 0, 0,
    0, svc_handler, default_handler, 0, pendsv_handler, systick_handler, irq0_handler, irq1_handler,
};
