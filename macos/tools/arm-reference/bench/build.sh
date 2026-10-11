#!/bin/sh
# Builds the benchmark firmware (dsp.bin) and the host that runs it (host)
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-${TMPDIR:-/tmp}/cm4-bench}
mkdir -p "$out"
arm-none-eabi-gcc -mcpu=cortex-m4 -mthumb -mfloat-abi=hard -mfpu=fpv4-sp-d16 -O2 -fno-math-errno -nostartfiles \
    -ffreestanding -T "$here/../selftest/selftest.ld" -o "$out/dsp.elf" "$here/dsp.c" -lgcc -lc
arm-none-eabi-objcopy -O binary -j .text -j .ARM.exidx -j .data "$out/dsp.elf" "$out/dsp.bin"
${CC:-cc} -O2 -g -I "$here/../../../Sources/CortexM4/include" "$here/host.c" "$here/../../../Sources/CortexM4/cortex_m4.c" \
    -o "$out/host" -lm
echo "$out/host $out/dsp.bin"
