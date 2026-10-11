// The STM32F405/407 around the Cortex-M4 core: see STM32F4.h. Peripherals are modelled at their registers, as RM0090
// describes them, and in time: each has its next event (an I2S slot, an ADC conversion's end, a timer's update, a
// byte shifted out) and the core runs until the earliest, when the chip brings its peripherals up to date. DMA streams
// move data as the peripherals ask for it, through the same bus the core uses, so that reading or writing a
// peripheral's data register has the same effects from either.

#include "STM32F4.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

// ------------------------------------------------------------------------------------------------------- constants

enum {
    FLASH_START = 0x08000000u, FLASH_BYTES = 0x100000u,
    SRAM_START = 0x20000000u, SRAM_BYTES = 0x20000u,
    CCM_START = 0x10000000u, CCM_BYTES = 0x10000u,
};

// Interrupt lines (positions in the vector table after the system exceptions)
enum {
    IRQ_EXTI0 = 6, IRQ_EXTI1 = 7, IRQ_EXTI2 = 8, IRQ_EXTI3 = 9, IRQ_EXTI4 = 10,
    IRQ_ADC = 18, IRQ_EXTI9_5 = 23,
    IRQ_TIM1_BRK_TIM9 = 24, IRQ_TIM1_UP_TIM10 = 25, IRQ_TIM1_TRG_COM_TIM11 = 26, IRQ_TIM1_CC = 27,
    IRQ_TIM2 = 28, IRQ_TIM3 = 29, IRQ_TIM4 = 30,
    IRQ_I2C1_EV = 31, IRQ_I2C1_ER = 32, IRQ_I2C2_EV = 33, IRQ_I2C2_ER = 34,
    IRQ_SPI1 = 35, IRQ_SPI2 = 36, IRQ_USART1 = 37, IRQ_USART2 = 38, IRQ_USART3 = 39, IRQ_EXTI15_10 = 40,
    IRQ_TIM8_BRK_TIM12 = 43, IRQ_TIM8_UP_TIM13 = 44, IRQ_TIM8_TRG_COM_TIM14 = 45, IRQ_TIM8_CC = 46,
    IRQ_TIM5 = 50, IRQ_SPI3 = 51, IRQ_UART4 = 52, IRQ_UART5 = 53, IRQ_TIM6_DAC = 54, IRQ_TIM7 = 55,
    IRQ_USART6 = 71, IRQ_I2C3_EV = 72, IRQ_I2C3_ER = 73, IRQ_RNG = 80,
    IRQ_COUNT = 82,
};
static const int dma_irq[2][8] = {{11, 12, 13, 14, 15, 16, 17, 47}, {56, 57, 58, 59, 60, 68, 69, 70}};

// DMA requests: the peripherals' requests, and which stream and channel serve each (RM0090 tables 42 and 43)
enum {
    REQ_NONE = 0,
    REQ_SPI1_RX, REQ_SPI1_TX, REQ_SPI2_RX, REQ_SPI2_TX, REQ_SPI3_RX, REQ_SPI3_TX,
    REQ_I2S2EXT_RX, REQ_I2S2EXT_TX, REQ_I2S3EXT_RX, REQ_I2S3EXT_TX,
    REQ_ADC1, REQ_ADC2, REQ_ADC3, REQ_DAC1, REQ_DAC2,
    REQ_USART1_RX, REQ_USART1_TX, REQ_USART2_RX, REQ_USART2_TX, REQ_USART3_RX, REQ_USART3_TX,
    REQ_UART4_RX, REQ_UART4_TX, REQ_UART5_RX, REQ_UART5_TX, REQ_USART6_RX, REQ_USART6_TX,
    REQ_TIM1_UP, REQ_TIM2_UP, REQ_TIM3_UP, REQ_TIM4_UP, REQ_TIM5_UP, REQ_TIM6_UP, REQ_TIM7_UP, REQ_TIM8_UP,
    REQ_COUNT
};
static const struct { uint8_t request, dma, stream, channel; } dma_map[] = {
    {REQ_SPI3_RX, 0, 0, 0}, {REQ_I2S3EXT_RX, 0, 0, 3}, {REQ_UART5_RX, 0, 0, 4}, {REQ_TIM5_UP, 0, 0, 6},
    {REQ_TIM2_UP, 0, 1, 3}, {REQ_USART3_RX, 0, 1, 4}, {REQ_TIM6_UP, 0, 1, 7},
    {REQ_SPI3_RX, 0, 2, 0}, {REQ_TIM7_UP, 0, 2, 1}, {REQ_I2S3EXT_RX, 0, 2, 2}, {REQ_UART4_RX, 0, 2, 4},
    {REQ_TIM3_UP, 0, 2, 5},
    {REQ_SPI2_RX, 0, 3, 0}, {REQ_I2S2EXT_RX, 0, 3, 3}, {REQ_USART3_TX, 0, 3, 4},
    {REQ_SPI2_TX, 0, 4, 0}, {REQ_TIM7_UP, 0, 4, 1}, {REQ_I2S2EXT_TX, 0, 4, 2}, {REQ_UART4_TX, 0, 4, 4},
    {REQ_USART3_TX, 0, 4, 7},
    {REQ_SPI3_TX, 0, 5, 0}, {REQ_I2S3EXT_TX, 0, 5, 2}, {REQ_USART2_RX, 0, 5, 4}, {REQ_DAC1, 0, 5, 7},
    {REQ_TIM4_UP, 0, 6, 2}, {REQ_USART2_TX, 0, 6, 4}, {REQ_TIM5_UP, 0, 6, 6}, {REQ_DAC2, 0, 6, 7},
    {REQ_SPI3_TX, 0, 7, 0}, {REQ_TIM2_UP, 0, 7, 3}, {REQ_UART5_TX, 0, 7, 4},
    {REQ_ADC1, 1, 0, 0}, {REQ_ADC3, 1, 0, 2}, {REQ_SPI1_RX, 1, 0, 3},
    {REQ_ADC3, 1, 1, 2}, {REQ_USART6_RX, 1, 1, 5}, {REQ_TIM8_UP, 1, 1, 7},
    {REQ_ADC2, 1, 2, 1}, {REQ_SPI1_RX, 1, 2, 3}, {REQ_USART1_RX, 1, 2, 4}, {REQ_USART6_RX, 1, 2, 5},
    {REQ_ADC2, 1, 3, 1}, {REQ_SPI1_TX, 1, 3, 3},
    {REQ_ADC1, 1, 4, 0},
    {REQ_SPI1_TX, 1, 5, 3}, {REQ_USART1_RX, 1, 5, 4}, {REQ_TIM1_UP, 1, 5, 6},
    {REQ_USART6_TX, 1, 6, 5},
    {REQ_USART1_TX, 1, 7, 4}, {REQ_USART6_TX, 1, 7, 5},
};

// Timer channels on pins, through their alternate functions: port, pin, function, timer, channel
static const struct { uint8_t port, pin, af, timer, channel; } timer_pins[] = {
    {0, 8, 1, 1, 1}, {0, 9, 1, 1, 2}, {0, 10, 1, 1, 3}, {0, 11, 1, 1, 4},
    {4, 9, 1, 1, 1}, {4, 11, 1, 1, 2}, {4, 13, 1, 1, 3}, {4, 14, 1, 1, 4},
    {0, 0, 1, 2, 1}, {0, 5, 1, 2, 1}, {0, 15, 1, 2, 1}, {0, 1, 1, 2, 2}, {1, 3, 1, 2, 2},
    {0, 2, 1, 2, 3}, {1, 10, 1, 2, 3}, {0, 3, 1, 2, 4}, {1, 11, 1, 2, 4},
    {0, 6, 2, 3, 1}, {1, 4, 2, 3, 1}, {2, 6, 2, 3, 1}, {0, 7, 2, 3, 2}, {1, 5, 2, 3, 2}, {2, 7, 2, 3, 2},
    {1, 0, 2, 3, 3}, {2, 8, 2, 3, 3}, {1, 1, 2, 3, 4}, {2, 9, 2, 3, 4},
    {1, 6, 2, 4, 1}, {3, 12, 2, 4, 1}, {1, 7, 2, 4, 2}, {3, 13, 2, 4, 2}, {1, 8, 2, 4, 3}, {3, 14, 2, 4, 3},
    {1, 9, 2, 4, 4}, {3, 15, 2, 4, 4},
    {0, 0, 2, 5, 1}, {0, 1, 2, 5, 2}, {0, 2, 2, 5, 3}, {0, 3, 2, 5, 4},
    {2, 6, 3, 8, 1}, {2, 7, 3, 8, 2}, {2, 8, 3, 8, 3}, {2, 9, 3, 8, 4},
    {0, 2, 3, 9, 1}, {0, 3, 3, 9, 2}, {4, 5, 3, 9, 1}, {4, 6, 3, 9, 2},
    {1, 8, 3, 10, 1}, {1, 9, 3, 11, 1},
    {1, 14, 9, 12, 1}, {1, 15, 9, 12, 2}, {0, 6, 9, 13, 1}, {0, 7, 9, 14, 1},
};

// The ADC's channels' pins (16: the temperature sensor, 17: the internal reference, 18: the battery)
static const struct { int8_t port, pin; } adc_pins[16] = {
    {0, 0}, {0, 1}, {0, 2}, {0, 3}, {0, 4}, {0, 5}, {0, 6}, {0, 7},
    {1, 0}, {1, 1}, {2, 0}, {2, 1}, {2, 2}, {2, 3}, {2, 4}, {2, 5},
};

// ----------------------------------------------------------------------------------------------------------- state

#define NEVER UINT64_MAX
#define PORTS 9

typedef struct {
    uint32_t moder, otyper, ospeedr, pupdr, odr, lckr, afr[2];
    uint16_t driven, level;  // the circuit's side
} Gpio;

typedef struct {
    uint32_t cr, ndtr, par, m0ar, m1ar, fcr;
    uint32_t start_ndtr, done;  // items done since the (re)load
} Stream;

typedef struct {
    uint32_t sr, cr1, cr2, smpr1, smpr2, jofr[4], htr, ltr, sqr1, sqr2, sqr3, jsqr, jdr[4], dr;
    int index;          // the conversion in the sequence under way
    uint64_t done_at;   // its end, or NEVER
    bool dma_pending;   // a conversion's result waiting for the DMA
} Adc;

typedef struct {
    uint32_t cr1, cr2, smcr, dier, sr, ccmr1, ccmr2, ccer, psc, arr, rcr, ccr[4], bdtr, dcr, or_;
    uint32_t count;     // CNT when the timer stopped, or at `base`
    uint64_t base;      // the cycle `count` was CNT at, while it runs
    uint64_t next;      // its next update event the chip keeps, or NEVER
    uint32_t wraps_seen;
} Timer;

typedef struct {
    uint32_t cr1, cr2, sr, crcpr, i2scfgr, i2spr;
    uint32_t tx, rx;            // the data register's two sides
    bool tx_full, rx_full;      // (TXE and RXNE, inverted and as is)
    uint32_t shifting;          // SPI: the frame being shifted
    uint64_t done_at;           // SPI: when it is shifted; I2S: the next slot
    double slot_time;           // I2S: the next slot's cycle, exactly
    int slot;                   // I2S: the slot in the frame
    uint32_t out[4], in[4];     // I2S: the frame's halfwords out, and the ones coming in
} Spi;

typedef struct {
    uint32_t cr1, cr2, oar1, oar2, ccr, trise, fltr, sr1, sr2, dr;
    bool sr1_read;              // SR1 read since the last access, for the flags cleared by reading it then another
    bool address_phase;         // after START: the next DR write is the address
    bool reading;
} I2c;

typedef struct {
    uint32_t sr, brr, cr1, cr2, cr3, gtpr;
    uint32_t tx, rx;
    bool tx_full, shifting;
    uint8_t shifting_byte;
    uint64_t done_at;
} Usart;

struct STM32F4 {
    CM4 *core;
    uint8_t *flash, *sram, *ccm;
    STM32F4Devices devices;
    double hse;
    double sysclk, hclk, pclk1, pclk2;
    double time_base;
    uint64_t cycle_base;

    uint32_t rcc[0x88 / 4 + 1];
    uint32_t flash_acr, flash_sr, flash_cr, flash_optcr;
    int flash_keys, option_keys;

    Gpio gpio[PORTS];
    double volts[PORTS][16];
    uint32_t exti_imr, exti_emr, exti_rtsr, exti_ftsr, exti_pr;
    uint16_t exti_last[PORTS];
    uint32_t syscfg_memrmp, syscfg_pmc, syscfg_exticr[4], syscfg_cmpcr;
    uint32_t pwr_cr, pwr_csr;

    Stream dma[2][8];
    uint32_t dma_isr[2][2];
    int8_t dma_request[2][8][8];

    Adc adc[3];
    uint32_t adc_ccr;

    Timer tim[15];
    Spi spi[3];
    Spi ext[2];                 // I2S2ext, I2S3ext
    I2c i2c[3];
    Usart usart[6];

    uint32_t dac_cr, dac_dhr[2], dac_dor[2], dac_sr;
    uint32_t rng_cr, rng_sr, rng_state;
    uint32_t crc;

    bool irq[IRQ_COUNT];
};

// ------------------------------------------------------------------------------------------------------- utilities

static inline uint64_t now(const STM32F4 *m) { return cm4_cycles(m->core); }

static void set_irq(STM32F4 *m, int line, bool level) {
    if (m->irq[line] == level) return;
    m->irq[line] = level;
    cm4_set_irq(m->core, line, level);
}

/// A run ends at the earliest peripheral event: one scheduled during it (a register written) shortens it
static void schedule(STM32F4 *m, uint64_t at) { cm4_set_deadline(m->core, at); }

/// Core cycles for `ticks` of a clock at `hz`
static inline double cycles_for(const STM32F4 *m, double ticks, double hz) { return ticks * m->hclk / hz; }

static uint32_t bus_read(STM32F4 *m, uint32_t address, uint32_t size) { return cm4_read(m->core, address, size); }
static void bus_write(STM32F4 *m, uint32_t address, uint32_t value, uint32_t size) {
    cm4_write(m->core, address, value, size);
}

// A narrower write to a register: its value in its byte lanes, the others zero. The peripherals' registers the
// standard peripheral library writes in halfwords are 16 bits wide with the other half reserved (or, as GPIO's BSRR,
// two halves acting apart), so that this is what the chip does with them; reading the register to merge would have
// its side effects (a data register's flags cleared).
static inline uint32_t lanes(uint32_t address, uint32_t value, uint32_t size) {
    if (size == 4) return value;
    uint32_t shift = (address & 3) * 8;
    return (value & (size == 2 ? 0xFFFFu : 0xFFu)) << shift;
}

static inline uint32_t sub_read(uint32_t value, uint32_t address, uint32_t size) {
    uint32_t shift = (address & 3) * 8;
    return size == 4 ? value : (value >> shift) & (size == 2 ? 0xFFFFu : 0xFFu);
}

// --------------------------------------------------------------------------------------------------------- clocks

static void update_clocks(STM32F4 *m) {
    uint32_t cr = m->rcc[0], pllcfgr = m->rcc[1], cfgr = m->rcc[2];
    double hsi = 16e6, hse = m->hse;
    double source = (pllcfgr >> 22) & 1 ? hse : hsi;
    uint32_t pllm = pllcfgr & 0x3F, plln = (pllcfgr >> 6) & 0x1FF, pllp = 2 * (((pllcfgr >> 16) & 3) + 1);
    double pll = pllm ? source / pllm * plln / pllp : hsi;
    double sysclk;
    switch (cfgr & 3) {
    case 1: sysclk = (cr & (1u << 16)) ? hse : hsi; break;
    case 2: sysclk = (cr & (1u << 24)) ? pll : hsi; break;
    default: sysclk = hsi; break;
    }
    static const int ahb[8] = {2, 4, 8, 16, 64, 128, 256, 512};
    uint32_t hpre = (cfgr >> 4) & 0xF, ppre1 = (cfgr >> 10) & 7, ppre2 = (cfgr >> 13) & 7;
    double hclk = sysclk / (hpre & 8 ? ahb[hpre & 7] : 1);
    double pclk1 = hclk / (ppre1 & 4 ? (1 << ((ppre1 & 3) + 1)) : 1);
    double pclk2 = hclk / (ppre2 & 4 ? (1 << ((ppre2 & 3) + 1)) : 1);
    if (hclk != m->hclk) {
        uint64_t t = now(m);
        m->time_base += (double)(t - m->cycle_base) / m->hclk;
        m->cycle_base = t;
    }
    m->sysclk = sysclk;
    m->hclk = hclk;
    m->pclk1 = pclk1;
    m->pclk2 = pclk2;
}

/// The clock of the timers on APB1 (`apb2` false) or APB2: twice the bus's when it is divided
static double timer_clock(const STM32F4 *m, bool apb2) {
    uint32_t ppre = apb2 ? (m->rcc[2] >> 13) & 7 : (m->rcc[2] >> 10) & 7;
    double pclk = apb2 ? m->pclk2 : m->pclk1;
    return ppre & 4 ? 2 * pclk : pclk;
}

/// I2S's clock: PLLI2S (from the main PLL's input, divided by PLLM) or the external I2S_CKIN
static double i2s_clock(const STM32F4 *m) {
    uint32_t pllcfgr = m->rcc[1], plli2s = m->rcc[0x84 / 4];
    double source = (pllcfgr >> 22) & 1 ? m->hse : 16e6;
    uint32_t pllm = pllcfgr & 0x3F, n = (plli2s >> 6) & 0x1FF, r = (plli2s >> 28) & 7;
    if (!pllm || !r) return 0;
    return source / pllm * n / r;
}

// ----------------------------------------------------------------------------------------------------------- GPIO

static uint16_t gpio_idr(const STM32F4 *m, int port) {
    const Gpio *g = &m->gpio[port];
    uint16_t idr = 0;
    for (int pin = 0; pin < 16; pin++) {
        uint32_t mode = (g->moder >> (2 * pin)) & 3, pull = (g->pupdr >> (2 * pin)) & 3;
        bool level;
        if (mode == 3) {
            level = false;
        } else if (mode == 1 && !((g->otyper >> pin) & 1)) {
            level = (g->odr >> pin) & 1;
        } else if (mode == 1 && !((g->odr >> pin) & 1)) {
            level = false;  // open drain, pulling low
        } else if ((g->driven >> pin) & 1) {
            level = (g->level >> pin) & 1;
        } else {
            level = pull == 1;
        }
        idr |= (uint16_t)level << pin;
    }
    return idr;
}

static void exti_check(STM32F4 *m, int port);

// ----------------------------------------------------------------------------------------------------------- EXTI

static void exti_update_irqs(STM32F4 *m) {
    uint32_t active = m->exti_pr & m->exti_imr;
    set_irq(m, IRQ_EXTI0, active & 1);
    set_irq(m, IRQ_EXTI1, active & 2);
    set_irq(m, IRQ_EXTI2, active & 4);
    set_irq(m, IRQ_EXTI3, active & 8);
    set_irq(m, IRQ_EXTI4, active & 0x10);
    set_irq(m, IRQ_EXTI9_5, active & 0x3E0);
    set_irq(m, IRQ_EXTI15_10, active & 0xFC00);
}

/// Edges on the lines routed from this port
static void exti_check(STM32F4 *m, int port) {
    uint16_t idr = gpio_idr(m, port), old = m->exti_last[port];
    m->exti_last[port] = idr;
    uint16_t changed = idr ^ old;
    if (!changed) return;
    for (int line = 0; line < 16; line++) {
        if (!((changed >> line) & 1)) continue;
        uint32_t source = (m->syscfg_exticr[line / 4] >> (4 * (line % 4))) & 0xF;
        if ((int)source != port) continue;
        bool rising = (idr >> line) & 1;
        if ((rising && (m->exti_rtsr >> line) & 1) || (!rising && (m->exti_ftsr >> line) & 1)) {
            m->exti_pr |= 1u << line;
        }
    }
    exti_update_irqs(m);
}

// ------------------------------------------------------------------------------------------------------------ DMA

static bool request_active(STM32F4 *m, int request);

static void dma_update_irq(STM32F4 *m, int d, int s) {
    Stream *st = &m->dma[d][s];
    int shift = (s & 1 ? 6 : 0) + (s & 2 ? 16 : 0);
    uint32_t flags = (m->dma_isr[d][s >> 2] >> shift) & 0x3D;
    uint32_t enabled = 0;
    if (st->cr & (1u << 4)) enabled |= 0x20;  // TC
    if (st->cr & (1u << 3)) enabled |= 0x10;  // HT
    if (st->cr & (1u << 2)) enabled |= 0x08;  // TE
    if (st->cr & (1u << 1)) enabled |= 0x04;  // DME
    if (st->fcr & (1u << 7)) enabled |= 0x01; // FE
    set_irq(m, dma_irq[d][s], (flags & enabled) != 0);
}

static void dma_flag(STM32F4 *m, int d, int s, uint32_t flag) {
    int shift = (s & 1 ? 6 : 0) + (s & 2 ? 16 : 0);
    m->dma_isr[d][s >> 2] |= flag << shift;
}

/// One data item moved by a stream; false when it is not enabled
static bool dma_transfer(STM32F4 *m, int d, int s) {
    Stream *st = &m->dma[d][s];
    uint32_t cr = st->cr;
    if (!(cr & 1) || st->ndtr == 0) return false;
    uint32_t dir = (cr >> 6) & 3;
    uint32_t psize = 1u << ((cr >> 11) & 3), msize = 1u << ((cr >> 13) & 3);
    bool direct = !(st->fcr & (1u << 2));
    if (direct) msize = psize;
    if (psize > 4) psize = 4;
    if (msize > 4) msize = 4;
    uint32_t peripheral = st->par + ((cr >> 9) & 1 ? st->done * psize : 0);
    uint32_t memory_base = (cr >> 18) & 1 && (cr >> 19) & 1 ? st->m1ar : st->m0ar;
    uint32_t memory = memory_base + ((cr >> 10) & 1 ? st->done * msize : 0);
    if (dir == 0) {
        bus_write(m, memory, bus_read(m, peripheral, psize), msize);
    } else if (dir == 1) {
        bus_write(m, peripheral, bus_read(m, memory, msize), psize);
    } else {
        // memory to memory: from PAR to M0AR
        uint32_t from = st->par + ((cr >> 9) & 1 ? st->done * psize : 0);
        uint32_t to = st->m0ar + ((cr >> 10) & 1 ? st->done * msize : 0);
        bus_write(m, to, bus_read(m, from, psize), msize);
    }
    st->done++;
    st->ndtr--;
    if (st->ndtr == st->start_ndtr / 2) dma_flag(m, d, s, 0x10);
    if (st->ndtr == 0) {
        dma_flag(m, d, s, 0x20);
        if ((cr >> 18) & 1) {
            st->cr ^= 1u << 19;  // double buffer: the other memory next
            st->ndtr = st->start_ndtr;
            st->done = 0;
        } else if ((cr >> 8) & 1 && dir != 2) {
            st->ndtr = st->start_ndtr;
            st->done = 0;
        } else {
            st->cr &= ~1u;
        }
    }
    dma_update_irq(m, d, s);
    return true;
}

/// Serves a peripheral's request while it stands, on whichever stream is set to its channel
static void pump(STM32F4 *m, int request) {
    for (int d = 0; d < 2; d++) {
        for (int s = 0; s < 8; s++) {
            if (m->dma_request[d][s][(m->dma[d][s].cr >> 25) & 7] != request) continue;
            int guard = 0x10000;
            while (guard-- > 0 && request_active(m, request) && dma_transfer(m, d, s)) {}
        }
    }
}

static uint32_t dma_read(STM32F4 *m, int d, uint32_t offset) {
    if (offset == 0x00) return m->dma_isr[d][0];
    if (offset == 0x04) return m->dma_isr[d][1];
    if (offset < 0x10 || offset >= 0x10 + 8 * 0x18) return 0;
    int s = (int)((offset - 0x10) / 0x18);
    Stream *st = &m->dma[d][s];
    switch ((offset - 0x10) % 0x18) {
    case 0x00: return st->cr;
    case 0x04: return st->ndtr;
    case 0x08: return st->par;
    case 0x0C: return st->m0ar;
    case 0x10: return st->m1ar;
    case 0x14: return st->fcr | (st->cr & 1 ? 0 : 0x20);  // FIFO empty
    }
    return 0;
}

static void dma_write(STM32F4 *m, int d, uint32_t offset, uint32_t value) {
    if (offset == 0x08 || offset == 0x0C) {
        int half = offset == 0x0C;
        m->dma_isr[d][half] &= ~(value & 0x0F7D0F7Du);
        for (int s = half * 4; s < half * 4 + 4; s++) dma_update_irq(m, d, s);
        return;
    }
    if (offset < 0x10 || offset >= 0x10 + 8 * 0x18) return;
    int s = (int)((offset - 0x10) / 0x18);
    Stream *st = &m->dma[d][s];
    switch ((offset - 0x10) % 0x18) {
    case 0x00: {
        bool was = st->cr & 1;
        st->cr = value & 0x0FEFFFFFu;
        if (!was && (value & 1)) {
            st->start_ndtr = st->ndtr;
            st->done = 0;
            if (st->ndtr == 0) {
                st->cr &= ~1u;
            } else if (((value >> 6) & 3) == 2) {
                while (dma_transfer(m, d, s)) {}  // memory to memory: all at once
            } else {
                int request = m->dma_request[d][s][(st->cr >> 25) & 7];
                if (request) pump(m, request);
            }
        }
        dma_update_irq(m, d, s);
        return;
    }
    case 0x04: if (!(st->cr & 1)) st->ndtr = value & 0xFFFF; return;
    case 0x08: if (!(st->cr & 1)) st->par = value; return;
    case 0x0C: st->m0ar = value; return;
    case 0x10: st->m1ar = value; return;
    case 0x14: st->fcr = (value & 0x87) | (st->fcr & 0x38); return;
    }
}

// ------------------------------------------------------------------------------------------------------------ ADC

static int adc_sample_cycles(const Adc *a, int channel) {
    static const int cycles[8] = {3, 15, 28, 56, 84, 112, 144, 480};
    uint32_t smp = channel >= 10 ? (a->smpr1 >> (3 * (channel - 10))) & 7 : (a->smpr2 >> (3 * channel)) & 7;
    return cycles[smp];
}

static int adc_regular_channel(const Adc *a, int index) {
    if (index < 6) return (a->sqr3 >> (5 * index)) & 0x1F;
    if (index < 12) return (a->sqr2 >> (5 * (index - 6))) & 0x1F;
    return (a->sqr1 >> (5 * (index - 12))) & 0x1F;
}

static int adc_length(const Adc *a) { return a->cr1 & (1u << 8) ? (int)((a->sqr1 >> 20) & 0xF) + 1 : 1; }

static uint32_t adc_value(const STM32F4 *m, const Adc *a, int channel, bool left_align) {
    double volts;
    if (channel < 16) volts = m->volts[adc_pins[channel].port][adc_pins[channel].pin];
    else if (channel == 16) volts = 0.76 + (25 - 25) * 0.0025;  // the temperature sensor at 25 °C
    else if (channel == 17) volts = 1.21;
    else volts = 3.3 / 2;
    int bits = 12 - 2 * (int)((a->cr1 >> 24) & 3);
    double full = (double)((1 << bits) - 1);
    double code = floor(volts / 3.3 * full + 0.5);
    uint32_t value = code < 0 ? 0 : code > full ? (uint32_t)full : (uint32_t)code;
    if (left_align) value <<= bits == 6 ? 2 : 16 - bits;
    return value;
}

static void adc_update_irq(STM32F4 *m) {
    bool any = false;
    for (int i = 0; i < 3; i++) {
        Adc *a = &m->adc[i];
        if ((a->sr & 2) && (a->cr1 & (1u << 5))) any = true;
        if ((a->sr & 4) && (a->cr1 & (1u << 7))) any = true;
        if ((a->sr & 0x20) && (a->cr1 & (1u << 26))) any = true;
    }
    set_irq(m, IRQ_ADC, any);
}

static void adc_start_conversion(STM32F4 *m, int i) {
    Adc *a = &m->adc[i];
    int channel = adc_regular_channel(a, a->index);
    int bits = 12 - 2 * (int)((a->cr1 >> 24) & 3);
    double adcclk = m->pclk2 / (2 * (((m->adc_ccr >> 16) & 3) + 1));
    double ticks = adc_sample_cycles(a, channel) + bits;
    a->done_at = now(m) + (uint64_t)ceil(cycles_for(m, ticks, adcclk));
    a->sr |= 0x10;  // STRT
    schedule(m, a->done_at);
}

static void adc_start(STM32F4 *m, int i) {
    Adc *a = &m->adc[i];
    if (!(a->cr2 & 1) || a->done_at != NEVER) return;
    a->index = 0;
    adc_start_conversion(m, i);
}

static void adc_conversion_done(STM32F4 *m, int i) {
    Adc *a = &m->adc[i];
    a->done_at = NEVER;
    int channel = adc_regular_channel(a, a->index);
    if (a->sr & 2 && !(a->cr2 & (1u << 8))) a->sr |= 0x20;  // overrun: the last result not read
    a->dr = adc_value(m, a, channel, (a->cr2 >> 11) & 1);
    a->index++;
    bool sequence_done = a->index >= adc_length(a);
    if ((a->cr2 & (1u << 10)) || sequence_done) a->sr |= 2;  // EOC (EOCS: after each conversion)
    if (a->cr2 & (1u << 8)) {
        a->dma_pending = true;
        pump(m, REQ_ADC1 + i);
    }
    if (sequence_done) {
        a->index = 0;
        if (a->cr2 & 2) adc_start_conversion(m, i);  // continuous
    } else {
        adc_start_conversion(m, i);
    }
    adc_update_irq(m);
}

/// Injected conversions: done at once, into JDR1-4
static void adc_injected(STM32F4 *m, int i) {
    Adc *a = &m->adc[i];
    int length = (int)((a->jsqr >> 20) & 3) + 1;
    for (int k = 0; k < length; k++) {
        int channel = (a->jsqr >> (5 * (4 - length + k))) & 0x1F;
        a->jdr[k] = adc_value(m, a, channel, (a->cr2 >> 11) & 1);
    }
    a->sr |= 4;  // JEOC
    adc_update_irq(m);
}

static uint32_t adc_read(STM32F4 *m, uint32_t offset) {
    if (offset >= 0x300) {
        if (offset == 0x300) {
            uint32_t csr = 0;
            for (int i = 0; i < 3; i++) csr |= (m->adc[i].sr & 0x3F) << (8 * i);
            return csr;
        }
        if (offset == 0x304) return m->adc_ccr;
        return 0;
    }
    int i = (int)(offset / 0x100);
    if (i > 2) return 0;
    Adc *a = &m->adc[i];
    switch (offset & 0xFF) {
    case 0x00: return a->sr;
    case 0x04: return a->cr1;
    case 0x08: return a->cr2;
    case 0x0C: return a->smpr1;
    case 0x10: return a->smpr2;
    case 0x14: case 0x18: case 0x1C: case 0x20: return a->jofr[((offset & 0xFF) - 0x14) / 4];
    case 0x24: return a->htr;
    case 0x28: return a->ltr;
    case 0x2C: return a->sqr1;
    case 0x30: return a->sqr2;
    case 0x34: return a->sqr3;
    case 0x38: return a->jsqr;
    case 0x3C: case 0x40: case 0x44: case 0x48: return a->jdr[((offset & 0xFF) - 0x3C) / 4];
    case 0x4C:
        a->sr &= ~2u;  // reading the data clears EOC
        a->dma_pending = false;
        adc_update_irq(m);
        return a->dr;
    }
    return 0;
}

static void adc_write(STM32F4 *m, uint32_t offset, uint32_t value) {
    if (offset >= 0x300) {
        if (offset == 0x304) m->adc_ccr = value;
        return;
    }
    int i = (int)(offset / 0x100);
    if (i > 2) return;
    Adc *a = &m->adc[i];
    switch (offset & 0xFF) {
    case 0x00: a->sr &= value | ~0x3Fu; adc_update_irq(m); return;  // rc_w0
    case 0x04: a->cr1 = value; adc_update_irq(m); return;
    case 0x08: {
        uint32_t was = a->cr2;
        a->cr2 = value & ~((1u << 30) | (1u << 22));
        if (!(value & 1)) { a->done_at = NEVER; a->sr &= ~0x10u; }
        if ((value & 1) && (value & (1u << 30))) adc_start(m, i);
        if ((value & 1) && (value & (1u << 22))) adc_injected(m, i);
        // in dual or triple mode, ADC1's start starts the others
        if (i == 0 && (value & (1u << 30)) && (m->adc_ccr & 0x1F)) {
            adc_start(m, 1);
            if ((m->adc_ccr & 0x1F) >= 0x10) adc_start(m, 2);
        }
        if (!(was & (1u << 8)) && (value & (1u << 8)) && a->dma_pending) pump(m, REQ_ADC1 + i);
        return;
    }
    case 0x0C: a->smpr1 = value; return;
    case 0x10: a->smpr2 = value; return;
    case 0x14: case 0x18: case 0x1C: case 0x20: a->jofr[((offset & 0xFF) - 0x14) / 4] = value & 0xFFF; return;
    case 0x24: a->htr = value & 0xFFF; return;
    case 0x28: a->ltr = value & 0xFFF; return;
    case 0x2C: a->sqr1 = value; return;
    case 0x30: a->sqr2 = value; return;
    case 0x34: a->sqr3 = value; return;
    case 0x38: a->jsqr = value; return;
    }
}

/// An external trigger from a timer event (EXTSEL's code) starts the ADCs set to it
static void adc_trigger(STM32F4 *m, uint32_t extsel, bool injected) {
    for (int i = 0; i < 3; i++) {
        Adc *a = &m->adc[i];
        if (!(a->cr2 & 1)) continue;
        if (!injected && ((a->cr2 >> 28) & 3) && ((a->cr2 >> 24) & 0xF) == extsel) adc_start(m, i);
        if (injected && ((a->cr2 >> 20) & 3) && ((a->cr2 >> 16) & 0xF) == extsel) adc_injected(m, i);
    }
}

// --------------------------------------------------------------------------------------------------------- timers

static bool timer_on_apb2(int t) { return t == 1 || t == 8 || t == 9 || t == 10 || t == 11; }
static bool timer_32bit(int t) { return t == 2 || t == 5; }

/// Core cycles per count
static double timer_tick(const STM32F4 *m, int t) {
    return (double)(m->tim[t].psc + 1) * m->hclk / timer_clock(m, timer_on_apb2(t));
}

static uint32_t timer_period(const Timer *tm) { return tm->arr + 1; }

static bool timer_down(const Timer *tm) { return (tm->cr1 >> 4) & 1 && !((tm->cr1 >> 5) & 3); }

/// Counts into the period at `count`: from 0 up, or from ARR down
static uint64_t timer_position(const Timer *tm, uint64_t period) {
    return timer_down(tm) ? period - 1 - tm->count % period : tm->count % period;
}

/// Counts since `base` (while it runs)
static uint64_t timer_elapsed(const STM32F4 *m, int t) {
    const Timer *tm = &m->tim[t];
    if (!(tm->cr1 & 1)) return 0;
    return (uint64_t)((double)(now(m) - tm->base) / timer_tick(m, t));
}

static uint32_t timer_count(const STM32F4 *m, int t) {
    const Timer *tm = &m->tim[t];
    if (!(tm->cr1 & 1)) return tm->count;
    uint64_t period = timer_period(tm);
    if (period == 0) return tm->count;
    uint64_t elapsed = timer_elapsed(m, t);
    if (timer_down(tm)) return (uint32_t)((tm->count + period - elapsed % period) % period);
    return (uint32_t)((tm->count + elapsed) % period);
}

static void timer_update_irq(STM32F4 *m, int t) {
    Timer *tm = &m->tim[t];
    bool update = (tm->sr & 1) && (tm->dier & 1);
    bool compare = (tm->sr & tm->dier & 0x1E) != 0;
    switch (t) {
    case 1:
        set_irq(m, IRQ_TIM1_UP_TIM10, update || ((m->tim[10].sr & m->tim[10].dier & 0x1F) != 0));
        set_irq(m, IRQ_TIM1_CC, compare);
        return;
    case 8:
        set_irq(m, IRQ_TIM8_UP_TIM13, update || ((m->tim[13].sr & m->tim[13].dier & 0x1F) != 0));
        set_irq(m, IRQ_TIM8_CC, compare);
        return;
    case 10: timer_update_irq(m, 1); return;
    case 13: timer_update_irq(m, 8); return;
    }
    bool any = (tm->sr & tm->dier & 0x5F) != 0;
    switch (t) {
    case 2: set_irq(m, IRQ_TIM2, any); break;
    case 3: set_irq(m, IRQ_TIM3, any); break;
    case 4: set_irq(m, IRQ_TIM4, any); break;
    case 5: set_irq(m, IRQ_TIM5, any); break;
    case 6: set_irq(m, IRQ_TIM6_DAC, any); break;
    case 7: set_irq(m, IRQ_TIM7, any); break;
    case 9: set_irq(m, IRQ_TIM1_BRK_TIM9, any); break;
    case 11: set_irq(m, IRQ_TIM1_TRG_COM_TIM11, any); break;
    case 12: set_irq(m, IRQ_TIM8_BRK_TIM12, any); break;
    case 14: set_irq(m, IRQ_TIM8_TRG_COM_TIM14, any); break;
    }
}

/// Whether anything listens to the timer's update events (its interrupt, DMA, or a trigger output to an ADC or the
/// DAC): only then does the chip keep them as events; otherwise its flag is worked out when read
static bool timer_watched(const STM32F4 *m, int t) {
    const Timer *tm = &m->tim[t];
    if (tm->dier & 0x101) return true;
    return ((tm->cr2 >> 4) & 7) == 2;  // TRGO on update
}

static void timer_schedule(STM32F4 *m, int t) {
    Timer *tm = &m->tim[t];
    tm->next = NEVER;
    if (!(tm->cr1 & 1) || !timer_watched(m, t)) return;
    uint64_t period = timer_period(tm);
    if (period == 0) return;
    uint64_t elapsed = timer_elapsed(m, t);
    uint64_t to_wrap = period - (timer_position(tm, period) + elapsed) % period;
    double tick = timer_tick(m, t);
    double at = (double)tm->base + ceil((double)(elapsed + to_wrap) * tick);
    tm->next = (uint64_t)at;
    schedule(m, tm->next);
}

static void dac_trigger(STM32F4 *m, uint32_t tsel);

/// The timer's update event: its flag, interrupt, DMA request and trigger output
static void timer_update_event(STM32F4 *m, int t) {
    Timer *tm = &m->tim[t];
    tm->sr |= 1;
    timer_update_irq(m, t);
    if (tm->dier & 0x100) {
        static const int requests[15] = {0, REQ_TIM1_UP, REQ_TIM2_UP, REQ_TIM3_UP, REQ_TIM4_UP, REQ_TIM5_UP,
                                         REQ_TIM6_UP, REQ_TIM7_UP, REQ_TIM8_UP, 0, 0, 0, 0, 0, 0};
        if (requests[t]) pump(m, requests[t]);
    }
    if (((tm->cr2 >> 4) & 7) == 2) {
        // ADC regular triggers on TRGO: TIM2 (6), TIM3 (8), TIM8 (14); the DAC's: TIM6 0, TIM8 1, TIM7 2, TIM5 3,
        // TIM2 4, TIM4 5
        if (t == 2) adc_trigger(m, 6, false);
        if (t == 3) adc_trigger(m, 8, false);
        if (t == 8) adc_trigger(m, 14, false);
        if (t == 1) adc_trigger(m, 0, true);
        static const int dac_tsel[15] = {-1, -1, 4, -1, 5, 3, 0, 2, 1, -1, -1, -1, -1, -1, -1};
        if (dac_tsel[t] >= 0) dac_trigger(m, (uint32_t)dac_tsel[t]);
    }
}

/// Brings the timer's count to now (its `base` moved up), before its settings change
static void timer_settle(STM32F4 *m, int t) {
    Timer *tm = &m->tim[t];
    if (!(tm->cr1 & 1)) return;
    uint64_t elapsed = timer_elapsed(m, t);
    uint64_t period = timer_period(tm);
    // a wrap not kept as an event (nothing listens): its flag
    if (period && !timer_watched(m, t) && timer_position(tm, period) + elapsed >= period) tm->sr |= 1;
    tm->count = timer_count(m, t);
    tm->base += (uint64_t)((double)elapsed * timer_tick(m, t));
}

static uint32_t timer_read(STM32F4 *m, int t, uint32_t offset) {
    Timer *tm = &m->tim[t];
    switch (offset) {
    case 0x00: return tm->cr1;
    case 0x04: return tm->cr2;
    case 0x08: return tm->smcr;
    case 0x0C: return tm->dier;
    case 0x10:
        if (!timer_watched(m, t)) timer_settle(m, t);
        return tm->sr;
    case 0x18: return tm->ccmr1;
    case 0x1C: return tm->ccmr2;
    case 0x20: return tm->ccer;
    case 0x24: return timer_count(m, t);
    case 0x28: return tm->psc;
    case 0x2C: return tm->arr;
    case 0x30: return tm->rcr;
    case 0x34: case 0x38: case 0x3C: case 0x40: return tm->ccr[(offset - 0x34) / 4];
    case 0x44: return tm->bdtr;
    case 0x48: return tm->dcr;
    case 0x50: return tm->or_;
    }
    return 0;
}

static void timer_write(STM32F4 *m, int t, uint32_t offset, uint32_t value) {
    Timer *tm = &m->tim[t];
    uint32_t mask = timer_32bit(t) ? 0xFFFFFFFFu : 0xFFFFu;
    timer_settle(m, t);
    switch (offset) {
    case 0x00: {
        bool was = tm->cr1 & 1;
        tm->cr1 = value & 0x3FF;
        if (!was && (value & 1)) tm->base = now(m);
        break;
    }
    case 0x04: tm->cr2 = value; break;
    case 0x08: tm->smcr = value; break;
    case 0x0C: tm->dier = value; timer_update_irq(m, t); break;
    case 0x10: tm->sr &= value; timer_update_irq(m, t); break;  // rc_w0
    case 0x14:
        if (value & 1) {
            // UG: the counter restarts, and an update event (unless URS keeps it from the flag)
            tm->count = timer_down(tm) ? tm->arr : 0;
            tm->base = now(m);
            if (!((tm->cr1 >> 2) & 1)) timer_update_event(m, t);
        }
        tm->sr |= value & 0x1E;
        timer_update_irq(m, t);
        break;
    case 0x18: tm->ccmr1 = value; break;
    case 0x1C: tm->ccmr2 = value; break;
    case 0x20: tm->ccer = value; break;
    case 0x24: tm->count = value & mask; tm->base = now(m); break;
    case 0x28: tm->psc = value & 0xFFFF; break;
    case 0x2C: tm->arr = value & mask; break;
    case 0x30: tm->rcr = value & 0xFF; break;
    case 0x34: case 0x38: case 0x3C: case 0x40: tm->ccr[(offset - 0x34) / 4] = value & mask; break;
    case 0x44: tm->bdtr = value; break;
    case 0x48: tm->dcr = value; break;
    case 0x50: tm->or_ = value; break;
    }
    timer_schedule(m, t);
}

/// A timer channel's output: its level now, and its duty (the fraction of the period it is high)
static double timer_output_duty(const STM32F4 *m, int t, int channel, bool *level) {
    const Timer *tm = &m->tim[t];
    uint32_t ccmr = channel <= 2 ? tm->ccmr1 : tm->ccmr2;
    uint32_t mode = (ccmr >> (channel & 1 ? 4 : 12)) & 7;
    bool enabled = (tm->ccer >> (4 * (channel - 1))) & 1;
    bool inverted = (tm->ccer >> (4 * (channel - 1) + 1)) & 1;
    if ((t == 1 || t == 8) && !(tm->bdtr & (1u << 15))) enabled = false;  // MOE
    double duty;
    uint32_t count = timer_count(m, t), compare = tm->ccr[channel - 1], period = timer_period(tm);
    switch (mode) {
    case 4: duty = 0; *level = false; break;
    case 5: duty = 1; *level = true; break;
    case 6:
        duty = period ? (compare >= period ? 1.0 : (double)compare / period) : 0;
        *level = count < compare;
        break;
    case 7:
        duty = period ? (compare >= period ? 0.0 : 1.0 - (double)compare / period) : 1;
        *level = count >= compare;
        break;
    default: duty = 0; *level = false; break;
    }
    if (!enabled) { *level = false; return 0; }
    if (inverted) { *level = !*level; duty = 1 - duty; }
    return duty;
}

// ----------------------------------------------------------------------------------------------------- SPI and I2S

static void spi_update_irq(STM32F4 *m, int i) {
    Spi *p = &m->spi[i];
    bool any = ((p->cr2 & 0x80) && !p->tx_full) || ((p->cr2 & 0x40) && p->rx_full) ||
               ((p->cr2 & 0x20) && (p->sr & 0x68));
    if (i == 1 || i == 2) {
        Spi *e = &m->ext[i - 1];
        any = any || ((e->cr2 & 0x80) && !e->tx_full) || ((e->cr2 & 0x40) && e->rx_full);
    }
    static const int lines[3] = {IRQ_SPI1, IRQ_SPI2, IRQ_SPI3};
    set_irq(m, lines[i], any);
}

static int spi_rx_request(int i) { static const int r[3] = {REQ_SPI1_RX, REQ_SPI2_RX, REQ_SPI3_RX}; return r[i]; }
static int spi_tx_request(int i) { static const int r[3] = {REQ_SPI1_TX, REQ_SPI2_TX, REQ_SPI3_TX}; return r[i]; }

static bool i2s_mode(const Spi *p) { return (p->i2scfgr >> 11) & 1; }

/// SPI as a master: a frame starts shifting
static void spi_start_frame(STM32F4 *m, int i) {
    Spi *p = &m->spi[i];
    p->shifting = p->tx;
    p->tx_full = false;
    int bits = (p->cr1 >> 11) & 1 ? 16 : 8;
    double pclk = i == 0 ? m->pclk2 : m->pclk1;
    double divider = (double)(2 << ((p->cr1 >> 3) & 7));
    p->done_at = now(m) + (uint64_t)ceil(cycles_for(m, bits * divider, pclk));
    schedule(m, p->done_at);
}

static void spi_frame_done(STM32F4 *m, int i) {
    Spi *p = &m->spi[i];
    int bits = (p->cr1 >> 11) & 1 ? 16 : 8;
    uint32_t in = m->devices.spi_exchange ? m->devices.spi_exchange(m->devices.context, i + 1, p->shifting, bits)
                                          : 0xFFFF;
    in &= bits == 16 ? 0xFFFFu : 0xFFu;
    p->done_at = NEVER;
    if (!((p->cr1 >> 10) & 1) || 1) {
        if (p->rx_full) p->sr |= 0x40;  // OVR
        p->rx = in;
        p->rx_full = true;
    }
    if (p->tx_full) spi_start_frame(m, i);
    if (p->cr2 & 1) pump(m, spi_rx_request(i));
    if (p->cr2 & 2) pump(m, spi_tx_request(i));
    spi_update_irq(m, i);
}

/// I2S: the frame rate and slots per frame as configured; 0 when it is not running
static double i2s_slot_cycles(const STM32F4 *m, const Spi *p, int *slots) {
    uint32_t cfg = p->i2scfgr, pr = p->i2spr;
    bool chlen32 = cfg & 1;
    uint32_t datlen = (cfg >> 1) & 3;
    int halfwords = datlen == 0 ? 1 : 2;
    *slots = 2 * halfwords;
    double fs;
    bool master = ((cfg >> 8) & 3) >= 2;
    if (master) {
        double clock = i2s_clock(m);
        uint32_t div = pr & 0xFF, odd = (pr >> 8) & 1;
        double divider = 2.0 * div + odd;
        if (div < 2 || clock <= 0) return 0;
        if ((pr >> 9) & 1) fs = chlen32 ? clock / (64 * divider * 4) : clock / (32 * divider * 8);
        else fs = chlen32 ? clock / (64 * divider) : clock / (32 * divider);
    } else {
        fs = 48000;  // a codec as master: its usual rate
    }
    return m->hclk / fs / *slots;
}

static void i2s_start(STM32F4 *m, int i) {
    Spi *p = &m->spi[i];
    int slots;
    double cycles = i2s_slot_cycles(m, p, &slots);
    if (cycles <= 0) return;
    p->slot = 0;
    p->slot_time = (double)now(m) + cycles;
    p->done_at = (uint64_t)ceil(p->slot_time);
    schedule(m, p->done_at);
}

static int32_t i2s_sample(const Spi *p, const uint32_t *halfwords) {
    uint32_t datlen = (p->i2scfgr >> 1) & 3;
    if (datlen == 0) return (int16_t)halfwords[0];
    uint32_t word = (halfwords[0] << 16) | (halfwords[1] & 0xFFFF);
    if (datlen == 1) return (int32_t)word >> 8;
    return (int32_t)word;
}

static void i2s_halfwords(const Spi *p, int32_t sample, uint32_t *halfwords) {
    uint32_t datlen = (p->i2scfgr >> 1) & 3;
    if (datlen == 0) { halfwords[0] = (uint32_t)sample & 0xFFFF; return; }
    uint32_t word = datlen == 1 ? (uint32_t)sample << 8 : (uint32_t)sample;
    halfwords[0] = word >> 16;
    halfwords[1] = word & 0xFFFF;
}

/// One I2S slot (a halfword each way): the transmitter takes the data register's halfword, the full-duplex
/// extension's receiver gets the next one in; after a frame's last, the codec is given it and gives one back
static void i2s_slot(STM32F4 *m, int i) {
    Spi *p = &m->spi[i];
    Spi *e = (i == 1 || i == 2) ? &m->ext[i - 1] : NULL;
    int slots;
    double cycles = i2s_slot_cycles(m, p, &slots);
    int slot = p->slot;
    bool transmitter = ((p->i2scfgr >> 8) & 3) == 0 || ((p->i2scfgr >> 8) & 3) == 2;
    // the main block: transmit (or receive)
    if (transmitter) {
        if (p->tx_full) {
            p->out[slot] = p->tx;
            p->tx_full = false;
        } else {
            p->out[slot] = 0;
            p->sr |= 0x08;  // underrun
        }
        p->sr = (p->sr & ~4u) | (slot >= slots / 2 ? 4u : 0);
        if (p->cr2 & 2) pump(m, spi_tx_request(i));
    } else {
        if (p->rx_full) p->sr |= 0x40;
        p->rx = p->in[slot];
        p->rx_full = true;
        if (p->cr2 & 1) pump(m, spi_rx_request(i));
    }
    // the extension: the other way
    if (e && ((e->i2scfgr >> 10) & 1)) {
        if (e->rx_full) e->sr |= 0x40;
        e->rx = p->in[slot];
        e->rx_full = true;
        e->sr = (e->sr & ~4u) | (slot >= slots / 2 ? 4u : 0);
        if (e->cr2 & 1) pump(m, i == 1 ? REQ_I2S2EXT_RX : REQ_I2S3EXT_RX);
    }
    spi_update_irq(m, i);
    p->slot++;
    if (p->slot >= slots) {
        p->slot = 0;
        int half = slots / 2;
        int32_t left = i2s_sample(p, &p->out[0]), right = i2s_sample(p, &p->out[half]);
        int32_t in_left = 0, in_right = 0;
        if (m->devices.i2s_frame) m->devices.i2s_frame(m->devices.context, i + 1, left, right, &in_left, &in_right);
        i2s_halfwords(p, in_left, &p->in[0]);
        i2s_halfwords(p, in_right, &p->in[half]);
    }
    if (cycles > 0 && ((p->i2scfgr >> 10) & 1)) {
        p->slot_time += cycles;
        p->done_at = (uint64_t)ceil(p->slot_time);
        if (p->done_at <= now(m)) p->done_at = now(m) + 1;
        schedule(m, p->done_at);
    } else {
        p->done_at = NEVER;
    }
}

static uint32_t spi_read(STM32F4 *m, Spi *p, uint32_t offset) {
    bool ext = p >= m->ext && p < m->ext + 2;
    int i = ext ? (int)(p - m->ext) + 1 : (int)(p - m->spi);
    switch (offset) {
    case 0x00: return p->cr1;
    case 0x04: return p->cr2;
    case 0x08: {
        uint32_t sr = p->sr & ~3u;
        if (p->rx_full) sr |= 1;
        if (!p->tx_full) sr |= 2;
        if (!ext && !i2s_mode(p) && p->done_at != NEVER) sr |= 0x80;  // BSY
        return sr;
    }
    case 0x0C: {
        uint32_t value = p->rx;
        p->rx_full = false;
        p->sr &= ~0x40u;  // OVR cleared by reading DR (then SR)
        spi_update_irq(m, i);
        return value;
    }
    case 0x10: return p->crcpr;
    case 0x1C: return p->i2scfgr;
    case 0x20: return p->i2spr;
    }
    return 0;
}

static void spi_write(STM32F4 *m, Spi *p, uint32_t offset, uint32_t value) {
    bool ext = p >= m->ext && p < m->ext + 2;
    int i = ext ? (int)(p - m->ext) + 1 : (int)(p - m->spi);
    switch (offset) {
    case 0x00: p->cr1 = value & 0xFFFF; return;
    case 0x04:
        p->cr2 = value & 0xF7;
        if (ext) {
            if ((value & 1) && p->rx_full) pump(m, i == 1 ? REQ_I2S2EXT_RX : REQ_I2S3EXT_RX);
            if ((value & 2) && !p->tx_full) pump(m, i == 1 ? REQ_I2S2EXT_TX : REQ_I2S3EXT_TX);
        } else {
            if ((value & 1) && p->rx_full) pump(m, spi_rx_request(i));
            if ((value & 2) && !p->tx_full) pump(m, spi_tx_request(i));
        }
        spi_update_irq(m, i);
        return;
    case 0x08: p->sr &= ~(~value & 0x10u); return;  // CRCERR is rc_w0
    case 0x0C:
        p->tx = value & 0xFFFF;
        p->tx_full = true;
        if (!ext && !i2s_mode(p) && (p->cr1 & 0x44) == 0x44 && p->done_at == NEVER) spi_start_frame(m, i);
        spi_update_irq(m, i);
        return;
    case 0x10: p->crcpr = value & 0xFFFF; return;
    case 0x1C: {
        bool was = (p->i2scfgr >> 10) & 1;
        p->i2scfgr = value & 0x0FBF;
        bool on = (value >> 10) & 1;
        if (!ext && i2s_mode(p) && on && !was) i2s_start(m, i);
        if (!ext && !on) p->done_at = NEVER;
        return;
    }
    case 0x20: p->i2spr = value & 0x3FF; return;
    }
}

static bool spi_request_active(STM32F4 *m, int request) {
    switch (request) {
    case REQ_SPI1_RX: case REQ_SPI2_RX: case REQ_SPI3_RX: {
        Spi *p = &m->spi[(request - REQ_SPI1_RX) / 2];
        return (p->cr2 & 1) && p->rx_full;
    }
    case REQ_SPI1_TX: case REQ_SPI2_TX: case REQ_SPI3_TX: {
        Spi *p = &m->spi[(request - REQ_SPI1_TX) / 2];
        return (p->cr2 & 2) && !p->tx_full && (i2s_mode(p) ? (p->i2scfgr >> 10) & 1 : (p->cr1 >> 6) & 1);
    }
    case REQ_I2S2EXT_RX: case REQ_I2S3EXT_RX: {
        Spi *e = &m->ext[request == REQ_I2S3EXT_RX];
        return (e->cr2 & 1) && e->rx_full;
    }
    case REQ_I2S2EXT_TX: case REQ_I2S3EXT_TX: {
        Spi *e = &m->ext[request == REQ_I2S3EXT_TX];
        return (e->cr2 & 2) && !e->tx_full && ((e->i2scfgr >> 10) & 1);
    }
    }
    return false;
}

// ------------------------------------------------------------------------------------------------------------ I2C

// I2C as a master, its bytes taking no time: the flags the standard peripheral library waits on are set as the
// register accesses that cause them are made

static void i2c_update_irq(STM32F4 *m, int i) {
    I2c *b = &m->i2c[i];
    bool event = (b->cr2 & (1u << 9)) && (b->sr1 & 0x1F);
    bool buffer = (b->cr2 & (1u << 9)) && (b->cr2 & (1u << 10)) && (b->sr1 & 0xC0);
    bool error = (b->cr2 & (1u << 8)) && (b->sr1 & 0xDF00);
    static const int ev[3] = {IRQ_I2C1_EV, IRQ_I2C2_EV, IRQ_I2C3_EV}, er[3] = {IRQ_I2C1_ER, IRQ_I2C2_ER, IRQ_I2C3_ER};
    set_irq(m, ev[i], event || buffer);
    set_irq(m, er[i], error);
}

static void i2c_receive(STM32F4 *m, int i) {
    I2c *b = &m->i2c[i];
    bool ack = (b->cr1 >> 10) & 1;
    b->dr = m->devices.i2c_read ? m->devices.i2c_read(m->devices.context, i + 1, ack) : 0xFF;
    b->sr1 |= 0x40;  // RXNE
}

static uint32_t i2c_read(STM32F4 *m, int i, uint32_t offset) {
    I2c *b = &m->i2c[i];
    switch (offset) {
    case 0x00: return b->cr1;
    case 0x04: return b->cr2;
    case 0x08: return b->oar1;
    case 0x0C: return b->oar2;
    case 0x10: {
        uint32_t value = b->dr;
        b->sr1 &= ~0x44u;  // RXNE, BTF
        b->sr1_read = false;
        if (b->reading && (b->sr2 & 1)) i2c_receive(m, i);
        i2c_update_irq(m, i);
        return value;
    }
    case 0x14: b->sr1_read = true; return b->sr1;
    case 0x18: {
        uint32_t value = b->sr2;
        if (b->sr1_read && (b->sr1 & 2)) {
            // ADDR cleared by reading SR1 then SR2: a receiver gets its first byte
            b->sr1 &= ~2u;
            if (b->reading) i2c_receive(m, i);
        }
        b->sr1_read = false;
        i2c_update_irq(m, i);
        return value;
    }
    case 0x1C: return b->ccr;
    case 0x20: return b->trise;
    case 0x24: return b->fltr;
    }
    return 0;
}

static void i2c_write(STM32F4 *m, int i, uint32_t offset, uint32_t value) {
    I2c *b = &m->i2c[i];
    switch (offset) {
    case 0x00:
        if (value & (1u << 15)) {
            // software reset
            memset(b, 0, sizeof *b);
            b->trise = 2;
            b->cr1 = value & (1u << 15);
            return;
        }
        b->cr1 = value & 0xBFFF & ~(0x300u);
        if (!(value & 1)) {
            b->sr1 = 0;
            b->sr2 = 0;
            return;
        }
        if (value & (1u << 8)) {
            // START (or a repeated start)
            b->sr1 |= 1;
            b->sr2 |= 3;  // MSL, BUSY
            b->address_phase = true;
        }
        if (value & (1u << 9)) {
            // STOP
            if (m->devices.i2c_stop && (b->sr2 & 1)) m->devices.i2c_stop(m->devices.context, i + 1);
            b->sr2 = 0;
            b->sr1 &= ~0x87u;
            b->reading = false;
        }
        i2c_update_irq(m, i);
        return;
    case 0x04: b->cr2 = value & 0x1F3F; i2c_update_irq(m, i); return;
    case 0x08: b->oar1 = value; return;
    case 0x0C: b->oar2 = value; return;
    case 0x10:
        b->dr = value & 0xFF;
        if (b->address_phase && (b->sr1 & 1)) {
            b->address_phase = false;
            b->sr1 &= ~1u;
            bool read = value & 1;
            bool ack = m->devices.i2c_start ? m->devices.i2c_start(m->devices.context, i + 1, (uint8_t)(value >> 1), read)
                                            : false;
            if (ack) {
                b->sr1 |= 2;  // ADDR
                b->reading = read;
                if (read) b->sr2 &= ~4u;
                else {
                    b->sr2 |= 4;    // TRA
                    b->sr1 |= 0x80; // TXE
                }
            } else {
                b->sr1 |= 0x400;  // AF
            }
        } else if (b->sr2 & 4) {
            bool ack = m->devices.i2c_write ? m->devices.i2c_write(m->devices.context, i + 1, (uint8_t)value) : false;
            b->sr1 |= 0x84;  // TXE, BTF: shifted out at once
            if (!ack) b->sr1 |= 0x400;
        }
        b->sr1_read = false;
        i2c_update_irq(m, i);
        return;
    case 0x14: b->sr1 &= value | 0xFFu; i2c_update_irq(m, i); return;  // the error flags are rc_w0
    case 0x1C: b->ccr = value; return;
    case 0x20: b->trise = value; return;
    case 0x24: b->fltr = value; return;
    }
}

// ---------------------------------------------------------------------------------------------------------- USART

static int usart_irq(int i) {
    static const int lines[6] = {IRQ_USART1, IRQ_USART2, IRQ_USART3, IRQ_UART4, IRQ_UART5, IRQ_USART6};
    return lines[i];
}

static void usart_update_irq(STM32F4 *m, int i) {
    Usart *u = &m->usart[i];
    uint32_t sr = u->sr;
    bool any = ((u->cr1 & 0x80) && (sr & 0x80)) || ((u->cr1 & 0x40) && (sr & 0x40)) ||
               ((u->cr1 & 0x20) && (sr & 0x28));
    set_irq(m, usart_irq(i), any);
}

static double usart_pclk(const STM32F4 *m, int i) { return (i == 0 || i == 5) ? m->pclk2 : m->pclk1; }

static void usart_start(STM32F4 *m, int i) {
    Usart *u = &m->usart[i];
    u->shifting_byte = (uint8_t)u->tx;
    u->tx_full = false;
    u->shifting = true;
    u->sr |= 0x80;   // TXE
    u->sr &= ~0x40u; // TC
    double bits = (u->cr1 & (1u << 12)) ? 11 : 10;
    double baud_divider = u->brr ? (double)u->brr : 16;
    if (u->cr1 & (1u << 15)) baud_divider = (double)(((u->brr >> 4) << 3) | (u->brr & 7));
    u->done_at = now(m) + (uint64_t)ceil(cycles_for(m, bits * baud_divider, usart_pclk(m, i)));
    schedule(m, u->done_at);
}

static void usart_done(STM32F4 *m, int i) {
    Usart *u = &m->usart[i];
    u->done_at = NEVER;
    u->shifting = false;
    if (m->devices.usart_send) m->devices.usart_send(m->devices.context, i + 1, u->shifting_byte);
    if (u->tx_full) usart_start(m, i);
    else u->sr |= 0x40;  // TC
    if (u->cr3 & 0x80) {
        static const int requests[6] = {REQ_USART1_TX, REQ_USART2_TX, REQ_USART3_TX, REQ_UART4_TX, REQ_UART5_TX,
                                        REQ_USART6_TX};
        pump(m, requests[i]);
    }
    usart_update_irq(m, i);
}

static uint32_t usart_read(STM32F4 *m, int i, uint32_t offset) {
    Usart *u = &m->usart[i];
    switch (offset) {
    case 0x00: return u->sr;
    case 0x04: u->sr &= ~0x20u; usart_update_irq(m, i); return u->rx;
    case 0x08: return u->brr;
    case 0x0C: return u->cr1;
    case 0x10: return u->cr2;
    case 0x14: return u->cr3;
    case 0x18: return u->gtpr;
    }
    return 0;
}

static void usart_write(STM32F4 *m, int i, uint32_t offset, uint32_t value) {
    Usart *u = &m->usart[i];
    switch (offset) {
    case 0x00: u->sr &= value | ~0x360u; usart_update_irq(m, i); return;  // rc_w0 on CTS, LBD, TC, RXNE
    case 0x04:
        u->tx = value & 0x1FF;
        u->tx_full = true;
        u->sr &= ~0x80u;
        if ((u->cr1 & 0x2008) == 0x2008 && !u->shifting) usart_start(m, i);
        usart_update_irq(m, i);
        return;
    case 0x08: u->brr = value & 0xFFFF; return;
    case 0x0C: u->cr1 = value & 0xBFFF; usart_update_irq(m, i); return;
    case 0x10: u->cr2 = value; return;
    case 0x14: u->cr3 = value; return;
    case 0x18: u->gtpr = value; return;
    }
}

static bool usart_request_active(STM32F4 *m, int request) {
    static const int tx[6] = {REQ_USART1_TX, REQ_USART2_TX, REQ_USART3_TX, REQ_UART4_TX, REQ_UART5_TX, REQ_USART6_TX};
    for (int i = 0; i < 6; i++) {
        if (request == tx[i]) return (m->usart[i].cr3 & 0x80) && !m->usart[i].tx_full && (m->usart[i].cr1 & 0x2008) == 0x2008;
    }
    return false;
}

// ------------------------------------------------------------------------------------------------------------ DAC

static void dac_load(STM32F4 *m, int channel) {
    m->dac_dor[channel] = m->dac_dhr[channel] & 0xFFF;
    if (m->dac_cr & (1u << (12 + 16 * channel))) pump(m, channel ? REQ_DAC2 : REQ_DAC1);
}

static void dac_trigger(STM32F4 *m, uint32_t tsel) {
    for (int channel = 0; channel < 2; channel++) {
        uint32_t cr = m->dac_cr >> (16 * channel);
        if ((cr & 1) && (cr & 4) && ((cr >> 3) & 7) == tsel) dac_load(m, channel);
    }
}

static void dac_write(STM32F4 *m, uint32_t offset, uint32_t value) {
    switch (offset) {
    case 0x00: m->dac_cr = value & 0x3FFF3FFF; return;
    case 0x04:
        for (int channel = 0; channel < 2; channel++) {
            if ((value >> channel) & 1) {
                uint32_t cr = m->dac_cr >> (16 * channel);
                if ((cr & 4) && ((cr >> 3) & 7) == 7) dac_load(m, channel);
            }
        }
        return;
    case 0x08: m->dac_dhr[0] = value & 0xFFF; break;
    case 0x0C: m->dac_dhr[0] = (value >> 4) & 0xFFF; break;
    case 0x10: m->dac_dhr[0] = (value & 0xFF) << 4; break;
    case 0x14: m->dac_dhr[1] = value & 0xFFF; break;
    case 0x18: m->dac_dhr[1] = (value >> 4) & 0xFFF; break;
    case 0x1C: m->dac_dhr[1] = (value & 0xFF) << 4; break;
    case 0x20: m->dac_dhr[0] = value & 0xFFF; m->dac_dhr[1] = (value >> 16) & 0xFFF; break;
    case 0x24: m->dac_dhr[0] = (value >> 4) & 0xFFF; m->dac_dhr[1] = (value >> 20) & 0xFFF; break;
    case 0x28: m->dac_dhr[0] = (value & 0xFF) << 4; m->dac_dhr[1] = ((value >> 8) & 0xFF) << 4; break;
    case 0x34: m->dac_sr &= ~(value & 0x20002000u); return;
    default: return;
    }
    // without a trigger, the output follows the holding register
    for (int channel = 0; channel < 2; channel++) {
        if (!((m->dac_cr >> (16 * channel + 2)) & 1)) m->dac_dor[channel] = m->dac_dhr[channel];
    }
}

static uint32_t dac_read(STM32F4 *m, uint32_t offset) {
    switch (offset) {
    case 0x00: return m->dac_cr;
    case 0x08: return m->dac_dhr[0];
    case 0x14: return m->dac_dhr[1];
    case 0x2C: return m->dac_dor[0];
    case 0x30: return m->dac_dor[1];
    case 0x34: return m->dac_sr;
    }
    return 0;
}

static bool dac_request_active(STM32F4 *m, int request) {
    // a request is made on each trigger and served at once: none stands
    (void)m;
    (void)request;
    return false;
}

// --------------------------------------------------------------------------------------------------------- flash

static const uint32_t flash_sectors[12][2] = {
    {0x00000, 0x4000}, {0x04000, 0x4000}, {0x08000, 0x4000}, {0x0C000, 0x4000}, {0x10000, 0x10000},
    {0x20000, 0x20000}, {0x40000, 0x20000}, {0x60000, 0x20000}, {0x80000, 0x20000}, {0xA0000, 0x20000},
    {0xC0000, 0x20000}, {0xE0000, 0x20000},
};

static void flash_write_register(STM32F4 *m, uint32_t offset, uint32_t value) {
    switch (offset) {
    case 0x00: m->flash_acr = value & 0x1F07; return;
    case 0x04:
        if (m->flash_keys == 0 && value == 0x45670123u) m->flash_keys = 1;
        else if (m->flash_keys == 1 && value == 0xCDEF89ABu) { m->flash_keys = 2; m->flash_cr &= ~(1u << 31); }
        else m->flash_keys = 0;
        return;
    case 0x08:
        if (m->option_keys == 0 && value == 0x08192A3Bu) m->option_keys = 1;
        else if (m->option_keys == 1 && value == 0x4C5D6E7Fu) { m->option_keys = 2; m->flash_optcr &= ~1u; }
        else m->option_keys = 0;
        return;
    case 0x0C: m->flash_sr &= ~(value & 0xF3u); return;
    case 0x10: {
        if (m->flash_cr & (1u << 31)) return;  // locked
        m->flash_cr = value & 0x8301037Fu;
        if (value & (1u << 31)) { m->flash_keys = 0; return; }
        if (value & (1u << 16)) {
            // STRT: a sector or the whole flash erased, done at once
            if (value & 4) {
                memset(m->flash, 0xFF, FLASH_BYTES);
            } else if (value & 2) {
                uint32_t sector = (value >> 3) & 0xF;
                if (sector < 12) memset(m->flash + flash_sectors[sector][0], 0xFF, flash_sectors[sector][1]);
            }
            m->flash_cr &= ~(1u << 16);
            m->flash_sr |= 1;  // EOP
        }
        return;
    }
    case 0x14: if (!(m->flash_optcr & 1) || (value & 1)) m->flash_optcr = value; return;
    }
}

static uint32_t flash_read_register(STM32F4 *m, uint32_t offset) {
    switch (offset) {
    case 0x00: return m->flash_acr;
    case 0x0C: return m->flash_sr;
    case 0x10: return m->flash_cr;
    case 0x14: return m->flash_optcr;
    }
    return 0;
}

/// A write to the flash's memory: programmed (bits only cleared) while PG is set and it is unlocked
static void flash_program(STM32F4 *m, uint32_t address, uint32_t value, uint32_t size) {
    if ((m->flash_cr & 0x80000001u) != 1) {
        m->flash_sr |= 0x80;  // PGSERR
        return;
    }
    uint32_t offset = address - FLASH_START;
    if (address < FLASH_START) offset = address;  // through the alias at 0
    if (offset + size > FLASH_BYTES) return;
    for (uint32_t k = 0; k < size; k++) m->flash[offset + k] &= (uint8_t)(value >> (8 * k));
    m->flash_sr |= 1;
}

// ------------------------------------------------------------------------------------------------------- RCC etc.

static void reset_peripherals(STM32F4 *m, int bus, uint32_t bits);

static uint32_t rcc_read(STM32F4 *m, uint32_t offset) {
    if (offset > 0x88) return 0;
    uint32_t value = m->rcc[offset / 4];
    if (offset == 0x00) {
        // ready flags follow their clocks at once
        value &= ~((1u << 1) | (1u << 17) | (1u << 25) | (1u << 27));
        value |= (value & 1) << 1 | ((value >> 16) & 1) << 17 | ((value >> 24) & 1) << 25 | ((value >> 26) & 1) << 27;
    } else if (offset == 0x08) {
        value = (value & ~0xCu) | ((value & 3) << 2);
    }
    return value;
}

static void rcc_write(STM32F4 *m, uint32_t offset, uint32_t value) {
    if (offset > 0x88) return;
    switch (offset) {
    case 0x10: case 0x14: case 0x18: case 0x20: case 0x24: {
        uint32_t rising = value & ~m->rcc[offset / 4];
        m->rcc[offset / 4] = value;
        if (rising) reset_peripherals(m, (int)offset, rising);
        return;
    }
    case 0x74: m->rcc[offset / 4] = (value & (1u << 24)) ? (m->rcc[offset / 4] & 0x00FFFFFFu) : value; return;
    }
    m->rcc[offset / 4] = value;
    if (offset == 0x00 || offset == 0x04 || offset == 0x08 || offset == 0x84) update_clocks(m);
}

static uint32_t crc_update(uint32_t crc, uint32_t data) {
    crc ^= data;
    for (int i = 0; i < 32; i++) crc = (crc & 0x80000000u) ? (crc << 1) ^ 0x04C11DB7u : crc << 1;
    return crc;
}

static uint32_t rng_next(STM32F4 *m) {
    uint32_t x = m->rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return m->rng_state = x;
}

// ------------------------------------------------------------------------------------------------------- the bus

static uint32_t gpio_read(STM32F4 *m, int port, uint32_t offset) {
    Gpio *g = &m->gpio[port];
    switch (offset) {
    case 0x00: return g->moder;
    case 0x04: return g->otyper;
    case 0x08: return g->ospeedr;
    case 0x0C: return g->pupdr;
    case 0x10: return gpio_idr(m, port);
    case 0x14: return g->odr;
    case 0x18: return 0;
    case 0x1C: return g->lckr;
    case 0x20: return g->afr[0];
    case 0x24: return g->afr[1];
    }
    return 0;
}

static void gpio_write(STM32F4 *m, int port, uint32_t offset, uint32_t value) {
    Gpio *g = &m->gpio[port];
    switch (offset) {
    case 0x00: g->moder = value; break;
    case 0x04: g->otyper = value & 0xFFFF; break;
    case 0x08: g->ospeedr = value; break;
    case 0x0C: g->pupdr = value; break;
    case 0x14: g->odr = value & 0xFFFF; break;
    case 0x18: g->odr = (g->odr | (value & 0xFFFF)) & ~(value >> 16); break;
    case 0x1C: g->lckr = value; break;
    case 0x20: g->afr[0] = value; break;
    case 0x24: g->afr[1] = value; break;
    default: return;
    }
    exti_check(m, port);
}

static uint32_t io_read(void *context, uint32_t address, uint32_t size) {
    STM32F4 *m = context;
    uint32_t base = address & ~3u, offset;
    uint32_t value = 0;
    if (address >= 0x40000000u && address < 0x40008000u) {
        uint32_t block = (address - 0x40000000u) >> 10;
        offset = base & 0x3FF;
        static const int apb1_timers[9] = {2, 3, 4, 5, 6, 7, 12, 13, 14};
        if (block < 9) value = timer_read(m, apb1_timers[block], offset);
        else if (block == 0x0D) value = spi_read(m, &m->ext[0], offset);
        else if (block == 0x0E) value = spi_read(m, &m->spi[1], offset);
        else if (block == 0x0F) value = spi_read(m, &m->spi[2], offset);
        else if (block == 0x10) value = spi_read(m, &m->ext[1], offset);
        else if (block >= 0x11 && block <= 0x14) value = usart_read(m, (int)(block - 0x11) + 1, offset);
        else if (block >= 0x15 && block <= 0x17) value = i2c_read(m, (int)(block - 0x15), offset);
        else if (block == 0x1C) value = offset == 0 ? m->pwr_cr : offset == 4 ? m->pwr_csr : 0;
        else if (block == 0x1D) value = dac_read(m, offset);
    } else if (address >= 0x40010000u && address < 0x40015000u) {
        uint32_t block = (address - 0x40010000u) >> 10;
        offset = base & 0x3FF;
        switch (block) {
        case 0x00: value = timer_read(m, 1, offset); break;
        case 0x01: value = timer_read(m, 8, offset); break;
        case 0x04: value = usart_read(m, 0, offset); break;
        case 0x05: value = usart_read(m, 5, offset); break;
        case 0x08: value = adc_read(m, base - 0x40012000u); break;
        case 0x0C: value = spi_read(m, &m->spi[0], offset); break;
        case 0x0E:
            if (offset == 0x00) value = m->syscfg_memrmp;
            else if (offset == 0x04) value = m->syscfg_pmc;
            else if (offset >= 0x08 && offset <= 0x14) value = m->syscfg_exticr[(offset - 8) / 4];
            else if (offset == 0x20) value = m->syscfg_cmpcr | ((m->syscfg_cmpcr & 1) << 8);
            break;
        case 0x0F:
            switch (offset) {
            case 0x00: value = m->exti_imr; break;
            case 0x04: value = m->exti_emr; break;
            case 0x08: value = m->exti_rtsr; break;
            case 0x0C: value = m->exti_ftsr; break;
            case 0x14: value = m->exti_pr; break;
            }
            break;
        case 0x10: value = timer_read(m, 9, offset); break;
        case 0x11: value = timer_read(m, 10, offset); break;
        case 0x12: value = timer_read(m, 11, offset); break;
        }
    } else if (address >= 0x40020000u && address < 0x40026800u) {
        uint32_t block = (address - 0x40020000u) >> 10;
        offset = base & 0x3FF;
        if (block < PORTS) value = gpio_read(m, (int)block, offset);
        else if (block == 0x0C) value = offset == 0 ? m->crc : 0;
        else if (block == 0x0E) value = rcc_read(m, offset);
        else if (block == 0x0F) value = flash_read_register(m, offset);
        else if (block == 0x18) value = dma_read(m, 0, offset);
        else if (block == 0x19) value = dma_read(m, 1, offset);
    } else if (address >= 0x50060800u && address < 0x50060C00u) {
        offset = base & 0x3FF;
        if (offset == 0x00) value = m->rng_cr;
        else if (offset == 0x04) value = (m->rng_cr & 4) ? 1 : 0;
        else if (offset == 0x08) value = (m->rng_cr & 4) ? rng_next(m) : 0;
    } else if (address >= 0x1FFF7A10u && address < 0x1FFF7A1Cu) {
        static const uint32_t id[3] = {0x00320041u, 0x3436470Bu, 0x31383930u};
        value = id[(base - 0x1FFF7A10u) / 4];
    } else if (base == 0x1FFF7A20u) {
        value = 1024u << 16;  // the flash's size in KB
    }
    return sub_read(value, address, size);
}

static void io_write(void *context, uint32_t address, uint32_t value, uint32_t size) {
    STM32F4 *m = context;
    if (address < FLASH_START + FLASH_BYTES && (address >= FLASH_START || address < FLASH_BYTES)) {
        flash_program(m, address, value, size);
        return;
    }
    uint32_t base = address & ~3u, offset = base & 0x3FF;
    value = lanes(address, value, size);
    if (address >= 0x40000000u && address < 0x40008000u) {
        uint32_t block = (address - 0x40000000u) >> 10;
        static const int apb1_timers[9] = {2, 3, 4, 5, 6, 7, 12, 13, 14};
        if (block < 9) timer_write(m, apb1_timers[block], offset, value);
        else if (block == 0x0D) spi_write(m, &m->ext[0], offset, value);
        else if (block == 0x0E) spi_write(m, &m->spi[1], offset, value);
        else if (block == 0x0F) spi_write(m, &m->spi[2], offset, value);
        else if (block == 0x10) spi_write(m, &m->ext[1], offset, value);
        else if (block >= 0x11 && block <= 0x14) usart_write(m, (int)(block - 0x11) + 1, offset, value);
        else if (block >= 0x15 && block <= 0x17) i2c_write(m, (int)(block - 0x15), offset, value);
        else if (block == 0x1C) {
            if (offset == 0) m->pwr_cr = value;
            else if (offset == 4) m->pwr_csr = (m->pwr_csr & ~0x300u) | (value & 0x300);
        } else if (block == 0x1D) dac_write(m, offset, value);
    } else if (address >= 0x40010000u && address < 0x40015000u) {
        uint32_t block = (address - 0x40010000u) >> 10;
        switch (block) {
        case 0x00: timer_write(m, 1, offset, value); break;
        case 0x01: timer_write(m, 8, offset, value); break;
        case 0x04: usart_write(m, 0, offset, value); break;
        case 0x05: usart_write(m, 5, offset, value); break;
        case 0x08: adc_write(m, base - 0x40012000u, value); break;
        case 0x0C: spi_write(m, &m->spi[0], offset, value); break;
        case 0x0E:
            if (offset == 0x00) m->syscfg_memrmp = value & 3;
            else if (offset == 0x04) m->syscfg_pmc = value;
            else if (offset >= 0x08 && offset <= 0x14) m->syscfg_exticr[(offset - 8) / 4] = value & 0xFFFF;
            else if (offset == 0x20) m->syscfg_cmpcr = value & 1;
            break;
        case 0x0F:
            switch (offset) {
            case 0x00: m->exti_imr = value & 0x7FFFFF; break;
            case 0x04: m->exti_emr = value & 0x7FFFFF; break;
            case 0x08: m->exti_rtsr = value & 0x7FFFFF; break;
            case 0x0C: m->exti_ftsr = value & 0x7FFFFF; break;
            case 0x10: m->exti_pr |= value & m->exti_imr; break;  // SWIER
            case 0x14: m->exti_pr &= ~value; break;
            }
            exti_update_irqs(m);
            break;
        case 0x10: timer_write(m, 9, offset, value); break;
        case 0x11: timer_write(m, 10, offset, value); break;
        case 0x12: timer_write(m, 11, offset, value); break;
        }
    } else if (address >= 0x40020000u && address < 0x40026800u) {
        uint32_t block = (address - 0x40020000u) >> 10;
        if (block < PORTS) gpio_write(m, (int)block, offset, value);
        else if (block == 0x0C) {
            if (offset == 0x00) m->crc = crc_update(m->crc, value);
            else if (offset == 0x08 && (value & 1)) m->crc = 0xFFFFFFFFu;
        } else if (block == 0x0E) rcc_write(m, offset, value);
        else if (block == 0x0F) flash_write_register(m, offset, value);
        else if (block == 0x18) dma_write(m, 0, offset, value);
        else if (block == 0x19) dma_write(m, 1, offset, value);
    } else if (address >= 0x50060800u && address < 0x50060C00u) {
        if (offset == 0x00) m->rng_cr = value & 0xC;
    }
}

static bool request_active(STM32F4 *m, int request) {
    if (request >= REQ_ADC1 && request <= REQ_ADC3) {
        Adc *a = &m->adc[request - REQ_ADC1];
        return a->dma_pending && (a->cr2 & (1u << 8));
    }
    if (request >= REQ_SPI1_RX && request <= REQ_I2S3EXT_TX) return spi_request_active(m, request);
    if (request >= REQ_USART1_RX && request <= REQ_USART6_TX) return usart_request_active(m, request);
    if (request == REQ_DAC1 || request == REQ_DAC2) return dac_request_active(m, request);
    // a timer's update request: made on the event, served once
    return false;
}

// ------------------------------------------------------------------------------------------------------- resets

static void reset_spi(Spi *p) {
    memset(p, 0, sizeof *p);
    p->sr = 2;
    p->crcpr = 7;
    p->i2spr = 2;
    p->done_at = NEVER;
}

static void reset_timer(Timer *tm) {
    memset(tm, 0, sizeof *tm);
    tm->arr = 0xFFFF;
    tm->next = NEVER;
}

static void reset_usart(Usart *u) {
    memset(u, 0, sizeof *u);
    u->sr = 0xC0;
    u->done_at = NEVER;
}

static void reset_adcs(STM32F4 *m) {
    for (int i = 0; i < 3; i++) {
        memset(&m->adc[i], 0, sizeof m->adc[i]);
        m->adc[i].done_at = NEVER;
    }
    m->adc_ccr = 0;
}

static void reset_i2c(I2c *b) {
    memset(b, 0, sizeof *b);
    b->trise = 2;
}

/// The peripherals whose reset bits were just set in AHB1RSTR (0x10) ... APB2RSTR (0x24)
static void reset_peripherals(STM32F4 *m, int bus, uint32_t bits) {
    switch (bus) {
    case 0x10:
        for (int port = 0; port < PORTS; port++) {
            if ((bits >> port) & 1) {
                Gpio *g = &m->gpio[port];
                g->moder = g->otyper = g->ospeedr = g->pupdr = g->odr = g->lckr = g->afr[0] = g->afr[1] = 0;
                exti_check(m, port);
            }
        }
        if (bits & (1u << 12)) m->crc = 0xFFFFFFFFu;
        for (int d = 0; d < 2; d++) {
            if ((bits >> (21 + d)) & 1) {
                memset(m->dma[d], 0, sizeof m->dma[d]);
                m->dma_isr[d][0] = m->dma_isr[d][1] = 0;
                for (int s = 0; s < 8; s++) { m->dma[d][s].fcr = 0x21; dma_update_irq(m, d, s); }
            }
        }
        break;
    case 0x20: {
        static const int timers[9] = {2, 3, 4, 5, 6, 7, 12, 13, 14};
        for (int k = 0; k < 9; k++) if ((bits >> k) & 1) reset_timer(&m->tim[timers[k]]);
        if (bits & (1u << 14)) { reset_spi(&m->spi[1]); reset_spi(&m->ext[0]); m->ext[0].i2spr = 0; }
        if (bits & (1u << 15)) { reset_spi(&m->spi[2]); reset_spi(&m->ext[1]); m->ext[1].i2spr = 0; }
        for (int k = 0; k < 4; k++) if ((bits >> (17 + k)) & 1) reset_usart(&m->usart[k + 1]);
        for (int k = 0; k < 3; k++) if ((bits >> (21 + k)) & 1) reset_i2c(&m->i2c[k]);
        if (bits & (1u << 29)) { m->dac_cr = 0; m->dac_dhr[0] = m->dac_dhr[1] = m->dac_dor[0] = m->dac_dor[1] = 0; }
        break;
    }
    case 0x24:
        if (bits & 1) reset_timer(&m->tim[1]);
        if (bits & 2) reset_timer(&m->tim[8]);
        if (bits & (1u << 4)) reset_usart(&m->usart[0]);
        if (bits & (1u << 5)) reset_usart(&m->usart[5]);
        if (bits & (1u << 8)) reset_adcs(m);
        if (bits & (1u << 12)) reset_spi(&m->spi[0]);
        if (bits & (1u << 16)) reset_timer(&m->tim[9]);
        if (bits & (1u << 17)) reset_timer(&m->tim[10]);
        if (bits & (1u << 18)) reset_timer(&m->tim[11]);
        break;
    }
}

static void reset_all(STM32F4 *m) {
    memset(m->rcc, 0, sizeof m->rcc);
    m->rcc[0x00 / 4] = 0x00000083;
    m->rcc[0x04 / 4] = 0x24003010;
    m->rcc[0x30 / 4] = 0x00100000;
    m->rcc[0x50 / 4] = 0x7E6791FF;
    m->rcc[0x54 / 4] = 0xF1;
    m->rcc[0x58 / 4] = 1;
    m->rcc[0x60 / 4] = 0x36FEC9FF;
    m->rcc[0x64 / 4] = 0x00075F33;
    m->rcc[0x74 / 4] = 0x0E000000;
    m->rcc[0x84 / 4] = 0x20003000;
    m->hclk = 0;
    m->time_base = 0;
    m->cycle_base = now(m);
    m->hclk = 16e6;
    update_clocks(m);

    m->flash_acr = 0;
    m->flash_sr = 0;
    m->flash_cr = 0x80000000u;
    m->flash_optcr = 0x0FFFAAEDu;
    m->flash_keys = m->option_keys = 0;

    for (int port = 0; port < PORTS; port++) {
        Gpio *g = &m->gpio[port];
        uint16_t driven = g->driven, level = g->level;
        memset(g, 0, sizeof *g);
        g->driven = driven;
        g->level = level;
    }
    m->gpio[0].moder = 0xA8000000u;
    m->gpio[0].pupdr = 0x64000000u;
    m->gpio[0].ospeedr = 0x0C000000u;
    m->gpio[1].moder = 0x00000280u;
    m->gpio[1].pupdr = 0x00000100u;
    m->gpio[1].ospeedr = 0x000000C0u;
    m->exti_imr = m->exti_emr = m->exti_rtsr = m->exti_ftsr = m->exti_pr = 0;
    m->syscfg_memrmp = m->syscfg_pmc = m->syscfg_cmpcr = 0;
    memset(m->syscfg_exticr, 0, sizeof m->syscfg_exticr);
    for (int port = 0; port < PORTS; port++) m->exti_last[port] = gpio_idr(m, port);
    m->pwr_cr = 0x4000;
    m->pwr_csr = 1u << 14;  // VOSRDY

    memset(m->dma, 0, sizeof m->dma);
    memset(m->dma_isr, 0, sizeof m->dma_isr);
    for (int d = 0; d < 2; d++) for (int s = 0; s < 8; s++) m->dma[d][s].fcr = 0x21;
    reset_adcs(m);
    for (int t = 0; t < 15; t++) reset_timer(&m->tim[t]);
    for (int i = 0; i < 3; i++) reset_spi(&m->spi[i]);
    for (int i = 0; i < 2; i++) { reset_spi(&m->ext[i]); m->ext[i].i2spr = 0; }
    for (int i = 0; i < 3; i++) reset_i2c(&m->i2c[i]);
    for (int i = 0; i < 6; i++) reset_usart(&m->usart[i]);
    m->dac_cr = m->dac_sr = 0;
    m->dac_dhr[0] = m->dac_dhr[1] = m->dac_dor[0] = m->dac_dor[1] = 0;
    m->rng_cr = 0;
    m->rng_state = 0x2545F491u;
    m->crc = 0xFFFFFFFFu;
    memset(m->irq, 0, sizeof m->irq);
}

// ------------------------------------------------------------------------------------------------------ running

/// The peripherals' events due by now, in turn
static void service(STM32F4 *m) {
    for (int round = 0; round < 64; round++) {
        uint64_t t = now(m);
        bool any = false;
        for (int i = 0; i < 3; i++) {
            Spi *p = &m->spi[i];
            if (p->done_at <= t) {
                any = true;
                if (i2s_mode(p)) i2s_slot(m, i);
                else spi_frame_done(m, i);
            }
        }
        for (int i = 0; i < 3; i++) if (m->adc[i].done_at <= t) { any = true; adc_conversion_done(m, i); }
        for (int k = 1; k < 15; k++) {
            Timer *tm = &m->tim[k];
            if (tm->next <= t) {
                any = true;
                timer_update_event(m, k);
                // the count wraps there: the next period from it
                tm->count = timer_down(tm) ? tm->arr : 0;
                tm->base = tm->next;
                timer_schedule(m, k);
            }
        }
        for (int i = 0; i < 6; i++) if (m->usart[i].done_at <= t) { any = true; usart_done(m, i); }
        if (!any) return;
    }
}

static uint64_t next_event(const STM32F4 *m) {
    uint64_t next = NEVER;
    for (int i = 0; i < 3; i++) {
        if (m->spi[i].done_at < next) next = m->spi[i].done_at;
        if (m->adc[i].done_at < next) next = m->adc[i].done_at;
    }
    for (int k = 1; k < 15; k++) if (m->tim[k].next < next) next = m->tim[k].next;
    for (int i = 0; i < 6; i++) if (m->usart[i].done_at < next) next = m->usart[i].done_at;
    return next;
}

CM4Stop stm32f4_run(STM32F4 *m, uint64_t cycles) {
    uint64_t end = now(m) + cycles;
    CM4Stop stop = CM4_RAN;
    for (;;) {
        service(m);
        uint64_t t = now(m);
        if (t >= end) return stop;
        uint64_t next = next_event(m);
        if (next > end) next = end;
        if (next <= t) next = t + 1;
        cm4_set_deadline(m->core, next);
        stop = cm4_run(m->core, next - t);
        if (stop == CM4_BREAKPOINT || stop == CM4_LOCKUP) {
            cm4_set_deadline(m->core, NEVER);
            return stop;
        }
    }
}

// ----------------------------------------------------------------------------------------------------------- API

STM32F4 *stm32f4_create(double hse_hz) {
    STM32F4 *m = calloc(1, sizeof *m);
    if (!m) return NULL;
    m->core = cm4_create();
    if (!m->core) { free(m); return NULL; }
    m->hse = hse_hz > 0 ? hse_hz : 8e6;
    m->flash = cm4_add_memory(m->core, FLASH_START, FLASH_BYTES, false);
    cm4_alias(m->core, 0, FLASH_START);
    m->ccm = cm4_add_memory(m->core, CCM_START, CCM_BYTES, true);
    m->sram = cm4_add_memory(m->core, SRAM_START, SRAM_BYTES, true);
    if (!m->flash || !m->ccm || !m->sram) { stm32f4_destroy(m); return NULL; }
    memset(m->flash, 0xFF, FLASH_BYTES);
    cm4_configure(m->core, IRQ_COUNT, 4);
    cm4_set_io(m->core, io_read, io_write, m);
    // which request each stream's channel serves
    for (size_t k = 0; k < sizeof dma_map / sizeof dma_map[0]; k++) {
        m->dma_request[dma_map[k].dma][dma_map[k].stream][dma_map[k].channel] = (int8_t)dma_map[k].request;
    }
    m->hclk = 16e6;
    stm32f4_reset(m);
    return m;
}

void stm32f4_destroy(STM32F4 *m) {
    if (!m) return;
    cm4_destroy(m->core);
    free(m);
}

CM4 *stm32f4_core(STM32F4 *m) { return m->core; }
uint8_t *stm32f4_flash(STM32F4 *m) { return m->flash; }

void stm32f4_set_devices(STM32F4 *m, const STM32F4Devices *devices) {
    if (devices) m->devices = *devices;
    else memset(&m->devices, 0, sizeof m->devices);
}

static uint32_t flash_word(const STM32F4 *m, uint32_t offset) {
    uint32_t v;
    memcpy(&v, m->flash + offset, 4);
    return v;
}

void stm32f4_reset(STM32F4 *m) {
    memset(m->sram, 0, SRAM_BYTES);
    memset(m->ccm, 0, CCM_BYTES);
    cm4_set_deadline(m->core, NEVER);
    cm4_reset(m->core);
    m->cycle_base = now(m);
    reset_all(m);
    if (flash_word(m, 0) == 0xFFFFFFFFu) {
        // no bootloader where the chip boots: the first vector table found after it
        for (uint32_t offset = 0x4000; offset < FLASH_BYTES; offset += 0x4000) {
            uint32_t sp = flash_word(m, offset), pc = flash_word(m, offset + 4);
            bool stack = (sp > SRAM_START && sp <= SRAM_START + SRAM_BYTES) || (sp > CCM_START && sp <= CCM_START + CCM_BYTES);
            if (stack && (pc & 1) && pc >= FLASH_START + offset && pc < FLASH_START + FLASH_BYTES) {
                cm4_set_special(m->core, CM4_MSP, sp);
                cm4_set_reg(m->core, 15, pc & ~1u);
                cm4_write(m->core, 0xE000ED08, FLASH_START + offset, 4);
                break;
            }
        }
    }
}

double stm32f4_hclk(const STM32F4 *m) { return m->hclk; }

double stm32f4_time(const STM32F4 *m) { return m->time_base + (double)(now(m) - m->cycle_base) / m->hclk; }

void stm32f4_set_input(STM32F4 *m, int port, int pin, bool driven, bool high) {
    if (port < 0 || port >= PORTS || pin < 0 || pin > 15) return;
    Gpio *g = &m->gpio[port];
    uint16_t bit = (uint16_t)(1u << pin);
    g->driven = driven ? g->driven | bit : g->driven & ~bit;
    g->level = high ? g->level | bit : g->level & ~bit;
    exti_check(m, port);
}

void stm32f4_set_voltage(STM32F4 *m, int port, int pin, double volts) {
    if (port < 0 || port >= PORTS || pin < 0 || pin > 15) return;
    m->volts[port][pin] = volts;
}

int stm32f4_pin_mode(const STM32F4 *m, int port, int pin) {
    if (port < 0 || port >= PORTS || pin < 0 || pin > 15) return STM32F4_INPUT;
    return (int)((m->gpio[port].moder >> (2 * pin)) & 3);
}

static bool timer_pin(const STM32F4 *m, int port, int pin, int *timer, int *channel) {
    const Gpio *g = &m->gpio[port];
    uint32_t af = (g->afr[pin / 8] >> (4 * (pin % 8))) & 0xF;
    for (size_t k = 0; k < sizeof timer_pins / sizeof timer_pins[0]; k++) {
        if (timer_pins[k].port == port && timer_pins[k].pin == pin && timer_pins[k].af == af) {
            *timer = timer_pins[k].timer;
            *channel = timer_pins[k].channel;
            return true;
        }
    }
    return false;
}

bool stm32f4_pin_level(const STM32F4 *m, int port, int pin) {
    if (port < 0 || port >= PORTS || pin < 0 || pin > 15) return false;
    const Gpio *g = &m->gpio[port];
    int mode = stm32f4_pin_mode(m, port, pin);
    if (mode == STM32F4_OUTPUT) return (g->odr >> pin) & 1;
    if (mode == STM32F4_ALTERNATE) {
        int timer, channel;
        if (timer_pin(m, port, pin, &timer, &channel)) {
            bool level;
            timer_output_duty(m, timer, channel, &level);
            return level;
        }
        return true;  // a bus's pin, idle
    }
    return (gpio_idr(m, port) >> pin) & 1;
}

bool stm32f4_pin_driven(const STM32F4 *m, int port, int pin) {
    if (port < 0 || port >= PORTS || pin < 0 || pin > 15) return false;
    const Gpio *g = &m->gpio[port];
    int mode = stm32f4_pin_mode(m, port, pin);
    if (mode == STM32F4_OUTPUT) return !((g->otyper >> pin) & 1) || !((g->odr >> pin) & 1);
    if (mode == STM32F4_ALTERNATE) {
        int timer, channel;
        return timer_pin(m, port, pin, &timer, &channel);
    }
    return false;
}

double stm32f4_dac_volts(const STM32F4 *m, int channel) {
    if (channel < 1 || channel > 2) return -1;
    if (!((m->dac_cr >> (16 * (channel - 1))) & 1)) return -1;
    return m->dac_dor[channel - 1] / 4095.0 * 3.3;
}
