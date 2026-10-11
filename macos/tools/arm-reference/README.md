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

```
pip install unicorn capstone numpy
python3 fuzz.py all 5000 1        # kind, trials, seed
python3 selftest/run.py
```

Unicorn (QEMU) quirks the harness works around: code rewritten in place needs QEMU's translation dropped
(`ctl_remove_cache`); after a fault it keeps the exception pending, so a fresh instance is made; it runs an IT block
as one unit whatever the instruction count asked for, so IT blocks run to their end; and it runs the M4 as if it had
the Security Extension, creating a new FP context (FPSCR from FPDSCR) unless CONTROL.SFPA is set with FPCA.
