// Runs a firmware image on the core and prints how fast: cc -O2 -I ../../../Sources/CortexM4/include host.c
// ../../../Sources/CortexM4/cortex_m4.c -lm && ./a.out dsp.bin
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "CortexM4.h"

int main(int argc, char **argv) {
    FILE *f = fopen(argv[1], "rb");
    if (!f) return 1;
    static uint8_t image[1 << 20];
    size_t n = fread(image, 1, sizeof image, f);
    fclose(f);
    int repeats = argc > 2 ? atoi(argv[2]) : 3;
    double best = 0;
    for (int rep = 0; rep < repeats; rep++) {
        CM4 *c = cm4_create();
        uint8_t *flash = cm4_add_memory(c, 0x08000000, 0x100000, false);
        cm4_alias(c, 0, 0x08000000);
        cm4_add_memory(c, 0x20000000, 0x20000, true);
        memcpy(flash, image, n);
        cm4_configure(c, 82, 4);
        cm4_reset(c);
        struct timespec a, b;
        clock_gettime(CLOCK_MONOTONIC, &a);
        CM4Stop stop;
        while ((stop = cm4_run(c, 10000000)) <= CM4_SLEEPING) {}
        clock_gettime(CLOCK_MONOTONIC, &b);
        double seconds = (b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) * 1e-9;
        double mips = cm4_instructions(c) / seconds / 1e6;
        if (mips > best) best = mips;
        printf("stop %d r0 %08x: %llu instructions, %llu cycles, %.3f s: %.1f M instructions/s, %.2f x real time at 168 MHz\n",
               stop, cm4_reg(c, 0), (unsigned long long)cm4_instructions(c), (unsigned long long)cm4_cycles(c), seconds,
               mips, cm4_cycles(c) / seconds / 168e6);
        cm4_destroy(c);
    }
    printf("best %.1f M instructions/s\n", best);
    return 0;
}
