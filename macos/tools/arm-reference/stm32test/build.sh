#!/bin/sh
# Builds the STM32 test firmware into the image CircuitKitTests runs
set -e
here=$(cd "$(dirname "$0")" && pwd)
out="$here/../../../Tests/CircuitKitTests/Fixtures/stm32-test.bin"
elf="${TMPDIR:-/tmp}/stm32-test.elf"
arm-none-eabi-gcc -mcpu=cortex-m4 -mthumb -mfloat-abi=hard -mfpu=fpv4-sp-d16 -O2 -nostartfiles -ffreestanding \
    -T "$here/../selftest/selftest.ld" -o "$elf" "$here/stm32test.c" -lgcc
arm-none-eabi-objcopy -O binary -j .text -j .ARM.exidx -j .data "$elf" "$out"
echo "$out: $(wc -c < "$out") bytes"
