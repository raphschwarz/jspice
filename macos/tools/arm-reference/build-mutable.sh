#!/bin/sh
# Builds a Mutable Instruments module's firmware from its repository (GPL-3.0: built where it is used, never kept
# here) with a current arm-none-eabi-gcc, for running it in the STM32 model:
#
#     build-mutable.sh rings [checkout] [toolchain prefix]
#
# The checkout (default: a fresh clone in $TMPDIR) gets pichenettes/eurorack with stmlib. Three things are adjusted for
# a compiler newer than the gcc 4.8 the modules were built with, in the checkout only: C++ as C++98 with warnings not
# fatal, the `__errno` variable the modules define dropped (newer newlib's libm calls a function of that
# name), and the 8-byte unwind index today's libgcc brings dropped from the linker scripts (which do not place it).
# Leaves build/<module>/<module>.hex and .elf in the checkout, and prints the HEX file's path.
set -e
module=$1
checkout=${2:-${TMPDIR:-/tmp}/mutable-eurorack}
prefix=${3:-$(dirname "$(dirname "$(command -v arm-none-eabi-gcc)")")/}
if [ ! -d "$checkout/stmlib" ]; then
    rm -rf "$checkout"
    git clone -q --depth 1 https://github.com/pichenettes/eurorack "$checkout"
    git clone -q --depth 1 https://github.com/pichenettes/stmlib "$checkout/stmlib"
fi
cd "$checkout"
# (a submodule some modules include: Plaits' user data comes in through its decoder)
if [ ! -f stm_audio_bootloader/fsk/packet_decoder.h ]; then
    rm -rf stm_audio_bootloader
    git clone -q --depth 1 https://github.com/pichenettes/stm-audio-bootloader stm_audio_bootloader
fi
# an `int __errno;` the modules define clashes with the __errno() newer newlib's libm calls: libc's is used
grep -l '^int __errno;' "$module"/*.cc 2>/dev/null | while read -r source; do sed -i.orig '/^int __errno;$/d' "$source"; done
# the generated resources are in the repository: not regenerated (their generator is Python 2)
touch "$module"/resources.cc "$module"/resources.h 2>/dev/null || true
for script in stmlib/linker_scripts/*.ld; do
    grep -q 'ARM.exidx' "$script" || printf '\nSECTIONS\n{\n  /DISCARD/ : { *(.ARM.exidx*) *(.ARM.extab*) }\n}\n' >> "$script"
done
# the family's flags, as stmlib's makefile gives them, with warnings not fatal
case $(sed -n 's/^FAMILY *= *//p' "$module"/makefile) in
    f37x) arch="-mcpu=cortex-m4 -mthumb -mfloat-abi=hard -mfpu=fpv4-sp-d16 -mthumb-interwork -funroll-loops --specs=nano.specs" ;;
    f10x) arch="-mcpu=cortex-m3 -mthumb -fno-unroll-loops" ;;
    *) arch="-mcpu=cortex-m4 -mthumb -mfloat-abi=hard -mfpu=fpv4-sp-d16 -mthumb-interwork -funroll-loops" ;;
esac
make -f "$module"/makefile TOOLCHAIN_PATH="$prefix" CPPFLAGS="-fno-exceptions -fno-rtti -std=gnu++98" \
    ARCHFLAGS="$arch -Wno-error" -j4 > "build-$module.log" 2>&1 || { grep -E 'error:|Error [0-9]|undefined reference|overflowed|ld: ' "build-$module.log" | tail -40 >&2; exit 1; }
echo "$checkout/build/$module/$module.hex"
