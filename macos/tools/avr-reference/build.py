"""Builds an Arduino sketch the way the app does (prototypes, the Arduino AVR core, avr-gcc, a flash image) for the
Uno (ATmega328P), the Mega 2560 or an ATtiny85 (with JSpice's own pin map in variants/tiny85)"""
import re, subprocess, sys, os, glob
CORE = os.path.abspath(os.environ.get('ARDUINO_CORE', '../ArduinoCore-avr'))
HERE = os.path.dirname(os.path.abspath(__file__))
BOARDS = {
    'uno': ('atmega328p', 16000000, '-DARDUINO_AVR_UNO', CORE + '/variants/standard'),
    'mega': ('atmega2560', 16000000, '-DARDUINO_AVR_MEGA2560', CORE + '/variants/mega'),
    'tiny85': ('attiny85', 8000000, '-DARDUINO_AVR_ATTINYX5', HERE + '/variants/tiny85'),
}

def flags(board):
    mcu, clock, define, variant = BOARDS[board]
    return ['-mmcu=' + mcu, '-DF_CPU=%dL' % clock, '-DARDUINO=10607', define, '-DARDUINO_ARCH_AVR',
            '-I' + CORE + '/cores/arduino', '-I' + variant, '-Os', '-w', '-ffunction-sections', '-fdata-sections']
CPP = ['-std=gnu++11', '-fpermissive', '-fno-exceptions', '-fno-threadsafe-statics']

KEYWORDS = {'if', 'for', 'while', 'switch', 'return', 'else', 'do', 'sizeof'}
HEADER = re.compile(r'^(?P<type>[A-Za-z_][\w\s\*&:<>,]*?[\s\*&]+)(?P<name>[A-Za-z_]\w*)\s*\((?P<params>[^()]*)\)\s*(const\s*)?$', re.S)

def blank(text):
    """Comments, string and character literals and preprocessor lines become spaces (newlines kept)"""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith('//', i):
            j = text.find('\n', i); j = n if j < 0 else j
            out.append(' ' * (j - i)); i = j
        elif text.startswith('/*', i):
            j = text.find('*/', i + 2); j = n if j < 0 else j + 2
            out.append(''.join(ch if ch == '\n' else ' ' for ch in text[i:j])); i = j
        elif c in '"\'':
            j = i + 1
            while j < n and text[j] != c and text[j] != '\n':
                j += 2 if text[j] == '\\' else 1
            j = min(j + 1, n)
            out.append(' ' * (j - i)); i = j
        elif c == '#' and (i == 0 or text[i - 1] == '\n' or text[:i].split('\n')[-1].strip() == ''):
            j = i
            while True:
                k = text.find('\n', j); k = n if k < 0 else k
                if k > 0 and text[k - 1] == '\\' and k < n: j = k + 1; continue
                break
            out.append(''.join(ch if ch == '\n' else ' ' for ch in text[i:k])); i = k
        else:
            out.append(c); i += 1
    return ''.join(out)

def prototypes(source):
    """Arduino lets a function be used before it is defined: declares each top-level function. Returns the
    prototypes and the offset of the first function definition, where they go."""
    text = blank(source)
    found, first, depth, start = [], None, 0, 0
    for i, c in enumerate(text):
        if c == '{':
            if depth == 0:
                header = ' '.join(text[start:i].split())
                m = HEADER.match(header)
                if m and m.group('name') not in KEYWORDS and '=' not in header and not re.search(r'\b(struct|class|enum|union|namespace|typedef)\b', header):
                    if '=' not in m.group('params'):
                        found.append(f"{' '.join(m.group('type').split())} {m.group('name')}({m.group('params').strip()});")
                    if first is None:
                        first = start + (len(text[start:i]) - len(text[start:i].lstrip()))
            depth += 1
        elif c == '}':
            depth = max(0, depth - 1)
            if depth == 0: start = i + 1
        elif c == ';' and depth == 0:
            start = i + 1
    return found, first

def build(sketch_path, out, board='uno'):
    FLAGS = flags(board)
    libraries = []
    source = open(sketch_path).read()
    protos, first = prototypes(source)
    os.makedirs(out, exist_ok=True)
    cpp = os.path.join(out, 'sketch.cpp')
    if first is None: first = len(source)
    line = source[:first].count('\n') + 1
    with open(cpp, 'w') as f:
        f.write('#include <Arduino.h>\n#line 1 "sketch.ino"\n' + source[:first] + '\n'.join(protos) +
                f'\n#line {line} "sketch.ino"\n' + source[first:])
    objs = []
    for name in re.findall(r'#include\s*<(\w+)\.h>', source):
        folder = os.path.join(CORE, 'libraries', name, 'src')
        if os.path.isdir(folder):
            FLAGS.append('-I' + folder)
            libraries += sorted(glob.glob(folder + '/**/*.cpp', recursive=True) + glob.glob(folder + '/**/*.c', recursive=True))
    sources = [cpp] + libraries + sorted(glob.glob(CORE + '/cores/arduino/*.c')) + sorted(glob.glob(CORE + '/cores/arduino/*.cpp')) + sorted(glob.glob(CORE + '/cores/arduino/*.S'))
    for s in sources:
        o = os.path.join(out, os.path.basename(s) + '.o')
        if s.endswith('.c'): cmd = ['avr-gcc', '-c', '-std=gnu11'] + FLAGS + [s, '-o', o]
        elif s.endswith('.S'): cmd = ['avr-gcc', '-c', '-x', 'assembler-with-cpp'] + FLAGS + [s, '-o', o]
        else: cmd = ['avr-g++', '-c'] + CPP + FLAGS + [s, '-o', o]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode: print(r.stderr); sys.exit(1)
        objs.append(o)
    elf = os.path.join(out, 'sketch.elf')
    r = subprocess.run(['avr-gcc', '-mmcu=' + BOARDS[board][0], '-Os', '-Wl,--gc-sections', '-o', elf] + objs + ['-lm'], capture_output=True, text=True)
    if r.returncode: print(r.stderr); sys.exit(1)
    subprocess.run(['avr-objcopy', '-O', 'binary', '-R', '.eeprom', elf, os.path.join(out, 'sketch.bin')], check=True)
    subprocess.run(['avr-objcopy', '-O', 'ihex', '-R', '.eeprom', elf, os.path.join(out, 'sketch.hex')], check=True)
    print(sketch_path, os.path.getsize(os.path.join(out, 'sketch.bin')), 'bytes')

if __name__ == '__main__':
    build(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else 'uno')
