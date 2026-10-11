// A firmware for testing the STM32F405 model (Sources/CortexM4/stm32f4.c) and its part: register by register, as
// RM0090 gives them, no library. It starts the PLL (168 MHz from an 8 MHz crystal), then:
//   - prints "boot" on USART1 (PA9, 115200 baud), and each line it receives back in capitals
//   - toggles PA5 every millisecond from SysTick, and copies PC13 (pulled up) onto PA6
//   - writes a WM8731's power register over I2C2 (PB10, PB11), and prints whether it acknowledged
//   - runs I2S2 as master at 48 kHz (PB12 WS, PB13 CK, PB15 SD, PB14 the extension's SD in), both ways by DMA:
//     left out a 1 kHz square wave of +-8192, right out the left input, halved
//   - reads PA0 with ADC1 every 100 ms and prints it ("adc 2048")
//   - programs a word into flash sector 11 and prints it back ("flash 12345678")
// Built by build.sh with arm-none-eabi-gcc; CircuitKitTests runs the image it leaves (Fixtures/stm32-test.bin).
#include <stdint.h>

#define REG(address) (*(volatile uint32_t *)(address))
#define RCC 0x40023800u
#define FLASH_IF 0x40023C00u
#define GPIOA 0x40020000u
#define GPIOB 0x40020400u
#define GPIOC 0x40020800u
#define USART1 0x40011000u
#define I2C2 0x40005800u
#define SPI2 0x40003800u
#define I2S2EXT 0x40003400u
#define DMA1 0x40026000u
#define ADC1 0x40012000u
#define NVIC_ISER0 0xE000E100u
#define BLOCK 32

volatile uint32_t milliseconds;
static volatile char received[64];
static volatile uint32_t received_head, received_tail;
static int16_t tx[4 * BLOCK], rx[4 * BLOCK];
static uint32_t phase;

static void put(char c) {
    while (!(REG(USART1 + 0x00) & 0x80)) {}
    REG(USART1 + 0x04) = (uint8_t)c;
}

static void print(const char *text) { while (*text) put(*text++); }

static void print_number(uint32_t value, int base) {
    char digits[12];
    int n = 0;
    do {
        uint32_t d = value % base;
        digits[n++] = (char)(d < 10 ? '0' + d : 'a' + d - 10);
        value /= base;
    } while (value);
    while (n) put(digits[--n]);
}

void usart1_handler(void) {
    if (REG(USART1 + 0x00) & 0x20) {
        received[received_head % 64] = (char)REG(USART1 + 0x04);
        received_head++;
    }
}

void systick_handler(void) {
    milliseconds++;
    REG(GPIOA + 0x14) ^= 1u << 5;
}

// half and whole of the receive buffer done: fill the matching half of the transmit one
void dma1_stream3_handler(void) {
    uint32_t isr = REG(DMA1 + 0x00);
    int half = (isr & (1u << 27)) ? 1 : 0;  // TCIF3: the second half
    REG(DMA1 + 0x08) = (1u << 27) | (1u << 26);  // clear TCIF3, HTIF3
    int16_t *out = &tx[half * 2 * BLOCK], *in = &rx[half * 2 * BLOCK];
    for (int i = 0; i < BLOCK; i++) {
        phase += 1;
        out[2 * i] = (phase % 48) < 24 ? 8192 : -8192;
        out[2 * i + 1] = in[2 * i] / 2;
    }
}

static void clock_init(void) {
    REG(RCC + 0x00) |= 1u << 16;  // HSE on
    while (!(REG(RCC + 0x00) & (1u << 17))) {}
    REG(FLASH_IF + 0x00) = 0x705;  // 5 wait states, caches
    // PLL: 8 MHz / 8 * 336 / 2 = 168 MHz; PLLQ 7
    REG(RCC + 0x04) = 8 | (336 << 6) | (0 << 16) | (1u << 22) | (7u << 24);
    REG(RCC + 0x08) = (0 << 4) | (5u << 10) | (4u << 13);  // AHB /1, APB1 /4, APB2 /2
    REG(RCC + 0x00) |= 1u << 24;
    while (!(REG(RCC + 0x00) & (1u << 25))) {}
    REG(RCC + 0x08) = (REG(RCC + 0x08) & ~3u) | 2;
    while ((REG(RCC + 0x08) & 0xC) != 8) {}
}

static void gpio_mode(uint32_t port, int pin, uint32_t mode, uint32_t af) {
    REG(port + 0x00) = (REG(port + 0x00) & ~(3u << (2 * pin))) | (mode << (2 * pin));
    if (mode == 2) {
        uint32_t reg = port + 0x20 + (pin / 8) * 4;
        REG(reg) = (REG(reg) & ~(0xFu << (4 * (pin % 8)))) | (af << (4 * (pin % 8)));
    }
}

static int i2c_write_register(uint8_t address, uint8_t reg, uint16_t value) {
    REG(I2C2 + 0x00) |= 1u << 8;  // START
    while (!(REG(I2C2 + 0x14) & 1)) {}
    REG(I2C2 + 0x10) = address << 1;
    uint32_t sr1;
    while (!((sr1 = REG(I2C2 + 0x14)) & 0x402)) {}
    if (sr1 & 0x400) {
        REG(I2C2 + 0x14) = ~0x400u;
        REG(I2C2 + 0x00) |= 1u << 9;
        return 0;
    }
    (void)REG(I2C2 + 0x18);  // ADDR cleared
    REG(I2C2 + 0x10) = (reg << 1) | ((value >> 8) & 1);
    while (!(REG(I2C2 + 0x14) & 0x80)) {}
    REG(I2C2 + 0x10) = value & 0xFF;
    while (!(REG(I2C2 + 0x14) & 0x04)) {}
    REG(I2C2 + 0x00) |= 1u << 9;  // STOP
    return 1;
}

static uint32_t adc_read(int channel) {
    REG(ADC1 + 0x34) = channel;          // SQR3: one conversion
    REG(ADC1 + 0x08) |= 1u << 30;        // SWSTART
    while (!(REG(ADC1 + 0x00) & 2)) {}
    return REG(ADC1 + 0x4C);
}

static void flash_test(void) {
    REG(FLASH_IF + 0x04) = 0x45670123;
    REG(FLASH_IF + 0x04) = 0xCDEF89AB;
    REG(FLASH_IF + 0x10) = (2u << 8) | (11u << 3) | 2;  // 32-bit, sector 11, SER
    REG(FLASH_IF + 0x10) |= 1u << 16;
    while (REG(FLASH_IF + 0x0C) & (1u << 16)) {}
    REG(FLASH_IF + 0x10) = (2u << 8) | 1;  // PG
    REG(0x080E0000) = 0x12345678;
    while (REG(FLASH_IF + 0x0C) & (1u << 16)) {}
    REG(FLASH_IF + 0x10) = 1u << 31;  // lock
    print("flash ");
    print_number(REG(0x080E0000), 16);
    print("\n");
}

static void audio_init(void) {
    // PLLI2S: 8 MHz / 8 * 258 / 3 = 86 MHz; I2S2 at 86 MHz / 256 / 7 = 47.99 kHz
    REG(RCC + 0x84) = (258u << 6) | (3u << 28);
    REG(RCC + 0x00) |= 1u << 26;
    while (!(REG(RCC + 0x00) & (1u << 27))) {}
    gpio_mode(GPIOB, 12, 2, 5);
    gpio_mode(GPIOB, 13, 2, 5);
    gpio_mode(GPIOB, 15, 2, 5);
    gpio_mode(GPIOB, 14, 2, 6);
    gpio_mode(GPIOC, 6, 2, 5);
    REG(SPI2 + 0x20) = 3 | (1u << 8) | (1u << 9);       // I2SDIV 3, ODD, MCKOE
    REG(SPI2 + 0x1C) = (1u << 11) | (2u << 8);           // I2S, master transmit, Philips, 16 bits
    REG(I2S2EXT + 0x1C) = (1u << 11) | (1u << 8);        // the extension: slave receive
    REG(SPI2 + 0x04) = 2;                                // TXDMAEN
    REG(I2S2EXT + 0x04) = 1;                             // RXDMAEN
    // DMA1 stream 4 channel 0: memory to SPI2, circular, 16 bits; stream 3 channel 3: I2S2ext to memory, half and
    // whole interrupts
    REG(DMA1 + 0x10 + 4 * 0x18 + 0x04) = 4 * BLOCK;
    REG(DMA1 + 0x10 + 4 * 0x18 + 0x08) = SPI2 + 0x0C;
    REG(DMA1 + 0x10 + 4 * 0x18 + 0x0C) = (uint32_t)tx;
    REG(DMA1 + 0x10 + 4 * 0x18 + 0x00) = (0u << 25) | (1u << 13) | (1u << 11) | (1u << 10) | (1u << 8) | (1u << 6);
    REG(DMA1 + 0x10 + 3 * 0x18 + 0x04) = 4 * BLOCK;
    REG(DMA1 + 0x10 + 3 * 0x18 + 0x08) = I2S2EXT + 0x0C;
    REG(DMA1 + 0x10 + 3 * 0x18 + 0x0C) = (uint32_t)rx;
    REG(DMA1 + 0x10 + 3 * 0x18 + 0x00) = (3u << 25) | (1u << 13) | (1u << 11) | (1u << 10) | (1u << 8) | (1u << 4) | (1u << 3);
    REG(DMA1 + 0x10 + 4 * 0x18 + 0x00) |= 1;
    REG(DMA1 + 0x10 + 3 * 0x18 + 0x00) |= 1;
    REG(NVIC_ISER0) = 1u << 14;  // DMA1 stream 3
    REG(I2S2EXT + 0x1C) |= 1u << 10;
    REG(SPI2 + 0x1C) |= 1u << 10;
}

int main(void) {
    clock_init();
    REG(RCC + 0x30) |= 0x7 | (1u << 21);           // GPIOA-C, DMA1
    REG(RCC + 0x40) |= (1u << 14) | (1u << 22);    // SPI2, I2C2
    REG(RCC + 0x44) |= (1u << 4) | (1u << 8);      // USART1, ADC1
    gpio_mode(GPIOA, 5, 1, 0);
    gpio_mode(GPIOA, 6, 1, 0);
    REG(GPIOC + 0x0C) |= 1u << 26;                 // PC13 pulled up
    gpio_mode(GPIOA, 9, 2, 7);
    gpio_mode(GPIOA, 10, 2, 7);
    gpio_mode(GPIOA, 0, 3, 0);
    REG(USART1 + 0x08) = 729;                      // 84 MHz / 115200
    REG(USART1 + 0x0C) = (1u << 13) | (1u << 5) | (1u << 3) | (1u << 2);  // RXNE interrupt
    REG(NVIC_ISER0 + 4) = 1u << (37 - 32);
    print("boot\n");

    gpio_mode(GPIOB, 10, 2, 4);
    gpio_mode(GPIOB, 11, 2, 4);
    REG(GPIOB + 0x04) |= (1u << 10) | (1u << 11);  // open drain
    REG(I2C2 + 0x04) = 42;
    REG(I2C2 + 0x1C) = 210;
    REG(I2C2 + 0x00) = 1;
    print(i2c_write_register(0x1A, 6, 0x00) ? "i2c ack\n" : "i2c nack\n");

    REG(ADC1 + 0x08) = 1;                          // ADON
    flash_test();
    audio_init();
    REG(0xE000E014) = 168000 - 1;                  // SysTick every millisecond
    REG(0xE000E018) = 0;
    REG(0xE000E010) = 7;

    char line[32];
    int length = 0;
    uint32_t next_report = 100;
    for (;;) {
        if (REG(GPIOC + 0x10) & (1u << 13)) REG(GPIOA + 0x18) = 1u << 6;
        else REG(GPIOA + 0x18) = 1u << (6 + 16);
        while (received_tail != received_head) {
            char c = received[received_tail % 64];
            received_tail++;
            if (c == '\n' || length == 31) {
                line[length] = 0;
                for (int i = 0; i < length; i++) if (line[i] >= 'a' && line[i] <= 'z') line[i] -= 32;
                print(line);
                put('\n');
                length = 0;
            } else {
                line[length++] = c;
            }
        }
        if (milliseconds >= next_report) {
            next_report += 100;
            print("adc ");
            print_number(adc_read(0), 10);
            put('\n');
        }
        __asm__ volatile("wfi");
    }
}

extern uint32_t _data, _edata, _data_load, _bss, _ebss, _stack_top;

__attribute__((naked, noreturn)) void reset(void) {
    __asm__ volatile("ldr r0, =0xE000ED88\nldr r1, [r0]\norr r1, r1, #(0xF << 20)\nstr r1, [r0]\ndsb\nisb\nb start\n");
}

__attribute__((noreturn)) void start(void) {
    for (uint32_t *from = &_data_load, *to = &_data; to < &_edata;) *to++ = *from++;
    for (uint32_t *to = &_bss; to < &_ebss;) *to++ = 0;
    main();
    for (;;) {}
}

void default_handler(void) { __asm__ volatile("bkpt #1"); for (;;) {} }

__attribute__((section(".vectors"), used)) const void *vectors[16 + 82] = {
    &_stack_top, reset, default_handler, default_handler, default_handler, default_handler, default_handler, 0, 0, 0,
    0, default_handler, default_handler, 0, default_handler, systick_handler,
    [16 + 14] = dma1_stream3_handler,
    [16 + 37] = usart1_handler,
};
