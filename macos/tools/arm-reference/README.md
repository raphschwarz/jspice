# ARM reference

The tools used to check JSpice's Cortex-M4 core (`Sources/CortexM4`), which is written in C so that it can be built
and run here as it is in the app:

- `cm4.py`: the core as a shared library (built with the host's C compiler, `CC` to choose it) through ctypes, and
  QEMU's Cortex-M4 through [Unicorn](https://www.unicorn-engine.org) set up with the same memories.
- `fuzz.py`: random states and random instructions run in both, one instruction (or one IT block) at a time,
  comparing the registers, flags, S0-S31, FPSCR and RAM after each. Kinds: `16` and `32` (Thumb and Thumb-2), `fp`
  (the FPU's instructions, from operands chosen to reach NaNs, infinities, denormals and rounding), `mem` (loads and
  stores near the state's pointers), `it` (IT blocks), `all`. Encodings the architecture leaves UNPREDICTABLE are
  not compared; ones the core finds UNDEFINED where QEMU runs them (ARMv8's VRINT, STREX encodings ARMv7-M leaves
  undefined) are listed apart.
- `selftest/`: a program for the core (`build.sh` builds it with arm-none-eabi-gcc into
  `Tests/CircuitKitTests/Fixtures/cm4-selftest.bin`) checking what QEMU cannot check one instruction at a time:
  SysTick, the NVIC's priorities and nesting, SVC and PendSV, BASEPRI, the process stack, bit-banding, and an
  interrupt using the FPU while the code it interrupted does. `run.py` runs it and computes each expected result
  apart; `CortexM4Tests.swift` holds them.

- `bench/`: a firmware shaped like an audio module's (float biquad and state-variable filters, a wavetable oscillator,
  Q15 mixing, block copies, under a SysTick interrupt) and a host that runs it on the core and prints its speed:
  `bench/build.sh` builds both.

- `stm32.py`: the STM32F405 model (`Sources/CortexM4/stm32f4.c`) with stand-ins for a module's board: a WM8731 on
  I2C and I2S (its register writes kept, its audio written to a WAV file, its input a sine or following a pin, as an
  unpatched input normalled to a module's probe), SPI and USART logs, pins held and voltages for the ADCs.
- `build-mutable.sh`: builds a Mutable Instruments module's firmware from its repository with today's
  arm-none-eabi-gcc (the code is GPL-3.0, so it is built where it is used, never kept here).

```
pip install unicorn capstone numpy
python3 fuzz.py all 5000 1        # kind, trials, seed
python3 selftest/run.py
hex=$(./build-mutable.sh rings)
python3 stm32.py $hex 2 --trigger A2 --every 0.5 --normal C8 --all-volts 1.65 --wav rings.wav
```

Mutable's F405 modules (Rings, Clouds, Elements, Warps, Marbles) boot and run on the model as they are built: Rings,
strummed, plays its resonator into the codec at 48 kHz, Clouds and Elements run at 32 kHz, Warps at 96 kHz, and
Marbles streams its quad DAC's words over I2S3.

Unicorn (QEMU) quirks the harness works around: code rewritten in place needs QEMU's translation dropped
(`ctl_remove_cache`); after a fault it keeps the exception pending, so a fresh instance is made; it runs an IT block
as one unit whatever the instruction count asked for, so IT blocks run to their end; and it runs the M4 as if it had
the Security Extension, creating a new FP context (FPSCR from FPDSCR) unless CONTROL.SFPA is set with FPCA.
