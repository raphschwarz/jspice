# AVR reference

The tools used to check JSpice's ATmega328P emulator (`Sources/CircuitKit/AVR.swift`):

- `avr.py`: a reference model of the chip in Python, from which the Swift emulator was ported line by line.
- `tracer.c`: runs firmware in [simavr](https://github.com/buserror/simavr) one instruction at a time, printing the
  cycle count, PC, SREG, SP and registers before each instruction. Build with
  `gcc -O2 -o tracer tracer.c -lsimavr -lelf` (Debian/Ubuntu: `apt install libsimavr-dev libelf-dev`).
- `lockstep.py`: runs firmware in both and stops at the first difference.
- `build.py`: compiles an Arduino sketch the way JSpice does (function prototypes, the Arduino AVR core, avr-gcc), into
  `sketch.elf`, `sketch.bin` and `sketch.hex`. Needs avr-gcc and a checkout of
  [ArduinoCore-avr](https://github.com/arduino/ArduinoCore-avr) next to this folder.
- `sketches/`: the sketches the tests run (`Tests/CircuitKitTests/AVRTests.swift` holds them compiled).

```
python3 build.py sketches/kitchen.ino out/kitchen
python3 lockstep.py out/kitchen/sketch.elf out/kitchen/sketch.bin 4000000 2500
```

Where simavr differs from the datasheet, the emulator follows the datasheet and `simavr_mode()` (Swift:
`simavrMode()`) switches to simavr's behaviour for comparing: interrupt entry takes 4 cycles on the chip and none in
simavr; after SEI or RETI one instruction runs before an interrupt on the chip and two in simavr; the chip's transmitter
is double-buffered; writing 1 to ADIF clears it on the chip.
