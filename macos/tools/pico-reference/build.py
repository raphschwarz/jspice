"""Builds an Arduino sketch for the Raspberry Pi Pico the way the app does: arduino-pico's recipe (platform.txt) for
the rpipico board with its default menu choices, except 125 MHz. Needs the arduino-pico core and its arm-none-eabi gcc:
PICO_CORE and PICO_GCC (the folder with bin/arm-none-eabi-gcc). Writes sketch.elf and sketch.bin (from 0x10000000).

python3 build.py sketch.ino out_folder
"""
import glob, os, re, subprocess, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '../avr-reference'))
from build import prototypes  # the same sketch preprocessing as for AVR

CORE = os.path.abspath(os.environ.get('PICO_CORE', '/opt/pico/rp2040-6.2.0'))
GCC = os.path.abspath(os.environ.get('PICO_GCC', '/opt/pico/arm-none-eabi')) + '/bin/arm-none-eabi-'
F_CPU = '125000000L'
FLASH = dict(total=2097152, length=2093056, eeprom=270528512, fs_start=270528512, fs_end=270528512)

def defines():
    p = CORE + '/'
    return ['-Werror=return-type', '-Wno-psabi',
            '-DUSBD_PID=0x000a', '-DUSBD_VID=0x2e8a', '-DUSBD_MAX_POWER_MA=250',
            '-DUSB_MANUFACTURER="Raspberry Pi"', '-DUSB_PRODUCT="Pico"',
            '-DLWIP_IPV6=0', '-DLWIP_IPV4=1', '-DLWIP_IGMP=1', '-DLWIP_CHECKSUM_CTRL_PER_NETIF=1',
            '-DFILE_COPY_CONSTRUCTOR_SELECT=FILE_COPY_CONSTRUCTOR_PUBLIC', '-DUSE_UTF8_LONG_NAMES=1', '-DDISABLE_FS_H_WARNING=1',
            '-DARDUINO_VARIANT="rpipico"', '-DPICO_FLASH_SIZE_BYTES=%d' % FLASH['total'],
            '-DFS_START=%d' % FLASH['fs_start'], '-DFS_END=%d' % FLASH['fs_end'],
            '@' + p + 'lib/platform_def.txt', '@' + p + 'lib/rp2040/platform_def.txt']

def includes():
    p = CORE + '/'
    return ['-iprefix' + p, '@' + p + 'lib/rp2040/platform_inc.txt', '@' + p + 'lib/core_inc.txt', '-I' + p + 'include']

ARCH = ['-march=armv6-m', '-mcpu=cortex-m0plus', '-mthumb']
COMMON = ARCH + ['-ffunction-sections', '-fdata-sections', '-fno-exceptions']
BOARD = ['-DF_CPU=' + F_CPU, '-DARDUINO=10819', '-DARDUINO_RASPBERRY_PI_PICO', '-DBOARD_NAME="RASPBERRY_PI_PICO"',
         '-DARDUINO_ARCH_RP2040', '-Os']

def compile_one(source, obj, extra_includes):
    variant = ['-I' + CORE + '/cores/rp2040', '-I' + CORE + '/variants/rpipico'] + extra_includes
    if source.endswith('.c'):
        cmd = [GCC + 'gcc', '-c'] + defines() + COMMON + ['-MMD'] + includes() + ['-std=gnu23', '-g', '-pipe'] + BOARD + variant
    elif source.endswith('.S'):
        cmd = [GCC + 'gcc', '-c'] + defines() + ['-g', '-x', 'assembler-with-cpp', '-MMD'] + includes() + ARCH + ['-g'] + BOARD[:-1] + variant
    else:
        cmd = [GCC + 'g++', '-c'] + defines() + COMMON + ['-MMD'] + includes() + ['-fno-rtti', '-std=gnu++23', '-g', '-pipe', '-Wno-volatile'] + BOARD + variant
    r = subprocess.run(cmd + [source, '-o', obj], capture_output=True, text=True)
    if r.returncode:
        print(r.stderr[-3000:]); sys.exit(1)

def sources(folder):
    found = []
    for ext in ('c', 'cpp', 'S'):
        found += glob.glob(folder + '/**/*.' + ext, recursive=True)
    return sorted(found)

def core_archive(cache):
    archive = os.path.join(cache, 'core.a')
    if os.path.exists(archive): return archive
    os.makedirs(cache, exist_ok=True)
    objs = []
    for k, s in enumerate(sources(CORE + '/cores/rp2040')):
        o = os.path.join(cache, '%d-%s.o' % (k, os.path.basename(s)))
        compile_one(s, o, [])
        objs.append(o)
    subprocess.run([GCC + 'ar', 'rcs', archive] + objs, check=True)
    return archive

def build(sketch_path, out):
    source = open(sketch_path).read()
    protos, first = prototypes(source)
    os.makedirs(out, exist_ok=True)
    if first is None: first = len(source)
    line = source[:first].count('\n') + 1
    cpp = os.path.join(out, 'sketch.cpp')
    with open(cpp, 'w') as f:
        f.write('#include <Arduino.h>\n#line 1 "sketch.ino"\n' + source[:first] + '\n'.join(protos) +
                f'\n#line {line} "sketch.ino"\n' + source[first:])
    extra, library_sources = [], []
    for name in re.findall(r'#include\s*[<"](\w+)\.h[>"]', source):
        folder = os.path.join(CORE, 'libraries', name, 'src')
        if os.path.isdir(folder):
            extra.append('-I' + folder)
            library_sources += sources(folder)
    archive = core_archive(os.path.join(os.path.dirname(os.path.abspath(out)), 'pico-core-cache'))
    objs = []
    for k, s in enumerate([cpp] + library_sources):
        o = os.path.join(out, '%d.o' % k)
        compile_one(s, o, extra)
        objs.append(o)
    # the linker script with this flash layout, and the second-stage bootloader
    ld = open(CORE + '/lib/rp2040/memmap_default.ld').read()
    for key, value in (('__FLASH_LENGTH__', FLASH['length']), ('__EEPROM_START__', FLASH['eeprom']),
                       ('__FS_START__', FLASH['fs_start']), ('__FS_END__', FLASH['fs_end']), ('__RAM_LENGTH__', '256k'),
                       ('__PSRAM_LENGTH__', 0)):
        ld = ld.replace(key, str(value))
    open(os.path.join(out, 'memmap_default.ld'), 'w').write(ld)
    boot2 = os.path.join(out, 'boot2.o')
    r = subprocess.run([GCC + 'gcc'] + defines() + COMMON + ['-Os', '-u', '_printf_float', '-u', '_scanf_float', '-c',
                        CORE + '/boot2/rp2040/boot2_w25q080_2_padded_checksum.S',
                        '-I' + CORE + '/pico-sdk/src/rp2040/hardware_regs/include/',
                        '-I' + CORE + '/pico-sdk/src/common/pico_binary_info/include', '-o', boot2], capture_output=True, text=True)
    if r.returncode: print(r.stderr); sys.exit(1)
    elf = os.path.join(out, 'sketch.elf')
    lib = CORE + '/lib/rp2040/'
    link = ([GCC + 'g++', '-L' + out] + defines() + COMMON + ['-Os', '-u', '_printf_float', '-u', '_scanf_float',
            '@' + lib + 'platform_wrap.txt', '@' + CORE + '/lib/core_wrap.txt',
            '-Wl,--cref', '-Wl,--check-sections', '-Wl,--gc-sections', '-Wl,--unresolved-symbols=report-all',
            '-Wl,--warn-common'] +
            ['-Wl,--undefined=' + u for u in ('runtime_init_install_ram_vector_table', '__pre_init_runtime_init_clocks',
             '__pre_init_runtime_init_bootrom_reset', '__pre_init_runtime_init_early_resets', '__pre_init_runtime_init_usb_power_down',
             '__pre_init_runtime_init_post_clock_resets', '__pre_init_runtime_init_spin_locks_reset',
             '__pre_init_runtime_init_boot_locks_reset', '__pre_init_runtime_init_bootrom_locking_enable',
             '__pre_init_runtime_init_mutex', '__pre_init_runtime_init_default_alarm_pool', '__pre_init_first_per_core_initializer',
             '__pre_init_runtime_init_per_core_bootrom_reset', '__pre_init_runtime_init_per_core_h3_irq_registers',
             '__pre_init_runtime_init_per_core_irq_priorities')] +
            ['-Wl,--script=' + os.path.join(out, 'memmap_default.ld'), '-Wl,-Map,' + os.path.join(out, 'sketch.map'),
             '-o', elf, '-Wl,--no-warn-rwx-segments', '-Wl,--start-group'] + objs +
            [archive, boot2, lib + 'ota.o', lib + 'libpico.a', lib + 'liblwip.a', lib + 'libbearssl.a', '-lm', '-lc', '-lstdc++', '-lc',
             '-Wl,--end-group'])
    r = subprocess.run(link, capture_output=True, text=True)
    if r.returncode: print(r.stderr[-4000:]); sys.exit(1)
    subprocess.run([GCC + 'objcopy', '-Obinary', elf, os.path.join(out, 'sketch.bin')], check=True)
    print(sketch_path, os.path.getsize(os.path.join(out, 'sketch.bin')), 'bytes')

if __name__ == '__main__':
    build(sys.argv[1], sys.argv[2])
