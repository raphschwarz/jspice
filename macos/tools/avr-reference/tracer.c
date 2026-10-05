// Runs an AVR ELF in simavr one instruction at a time and prints the state before each instruction:
// cycle pc sreg sp r0..r31 (hex), so another emulator can be compared with it in lockstep.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <simavr/sim_avr.h>
#include <simavr/sim_elf.h>
#include <simavr/avr_uart.h>
#include <simavr/avr_adc.h>
#include <simavr/sim_irq.h>

static void uart_out(struct avr_irq_t *irq, uint32_t value, void *param) {
    fprintf(stderr, "UART %llu %02x\n", (unsigned long long)((avr_t *)param)->cycle, value & 0xff);
}

static int sreg(avr_t *avr) { int v = 0; for (int b = 0; b < 8; b++) if (avr->sreg[b]) v |= 1 << b; return v; }

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: tracer firmware.elf instructions [adc_mv] [quiet]\n"
                            "  MCU (default atmega328p) and FREQUENCY (default 16000000) from the environment\n"); return 1; }
    elf_firmware_t f = {0};
    if (elf_read_firmware(argv[1], &f)) { fprintf(stderr, "cannot read %s\n", argv[1]); return 1; }
    const char *mcu = getenv("MCU") ? getenv("MCU") : "atmega328p";
    strcpy(f.mmcu, mcu);
    f.frequency = getenv("FREQUENCY") ? atol(getenv("FREQUENCY")) : 16000000;
    avr_t *avr = avr_make_mcu_by_name(f.mmcu);
    avr_init(avr);
    avr_load_firmware(avr, &f);
    avr->log = 0;
    long n = atol(argv[2]);
    int quiet = argc > 4;
    avr_irq_t *out = avr_io_getirq(avr, AVR_IOCTL_UART_GETIRQ('0'), UART_IRQ_OUTPUT);
    if (out) avr_irq_register_notify(out, uart_out, avr);
    if (argc > 3) {
        int mv = atoi(argv[3]);
        for (int ch = 0; ch < 16; ch++) avr_raise_irq(avr_io_getirq(avr, AVR_IOCTL_ADC_GETIRQ, ch), mv);
    }
    for (long i = 0; i < n; i++) {
        if (avr->state == cpu_Done || avr->state == cpu_Crashed) break;
        if (!quiet) {
            printf("%llu %05x %02x %04x", (unsigned long long)avr->cycle, avr->pc / 2, sreg(avr),
                   avr->data[0x5d] | (avr->data[0x5e] << 8));
            for (int r = 0; r < 32; r++) printf(" %02x", avr->data[r]);
            printf("\n");
        }
        avr_run(avr);
    }
    if (quiet) printf("cycle %llu pc %04x portb %02x\n", (unsigned long long)avr->cycle, avr->pc / 2, avr->data[0x25]);
    return 0;
}
