#!/bin/sh
# Builds the Cortex-M4 self-test into the image CircuitKitTests runs
set -e
here=$(cd "$(dirname "$0")" && pwd)
out="$here/../../../Tests/CircuitKitTests/Fixtures/cm4-selftest.bin"
arm-none-eabi-gcc -mcpu=cortex-m4 -mthumb -mfloat-abi=hard -mfpu=fpv4-sp-d16 -O2 -ffp-contract=off -fno-math-errno -nostartfiles \
    -ffreestanding -T "$here/selftest.ld" -o "${TMPDIR:-/tmp}/cm4-selftest.elf" "$here/selftest.c" -lgcc
arm-none-eabi-objcopy -O binary -j .text -j .ARM.exidx -j .data "${TMPDIR:-/tmp}/cm4-selftest.elf" "$out"
echo "$out: $(wc -c < "$out") bytes"
