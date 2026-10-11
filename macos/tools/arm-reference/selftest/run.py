"""Runs the self-test image on the C core and checks each result against values computed here (selftest.c says
what each is)"""
import os
import struct
import sys
from fractions import Fraction

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import cm4  # noqa: E402

IMAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "Tests", "CircuitKitTests",
                     "Fixtures", "cm4-selftest.bin")
NAMES = ["marker", "crc", "harmonic", "sqrt", "fma", "div64_lo", "div64_hi", "series", "ticks_ok", "handler_float",
         "svc", "pendsv", "basepri", "bitband", "exclusive", "dsp", "bits", "psp", "convert", "udiv0", "irq_order",
         "saturate", "done"]


def f32(x):
    return np.float32(x)


def bits(x):
    return struct.unpack("<I", struct.pack("<f", float(x)))[0]


def fma_f32(a, b, c):
    exact = Fraction(float(a)) * Fraction(float(b)) + Fraction(float(c))
    guess = np.float32(float(exact))
    candidates = [np.nextafter(guess, np.float32(-np.inf)), guess, np.nextafter(guess, np.float32(np.inf))]
    return min(candidates, key=lambda v: abs(Fraction(float(v)) - exact))


def expected():
    harmonic = f32(0)
    for k in range(1, 1001):
        harmonic = f32(harmonic + f32(f32(1) / f32(k)))
    series = f32(1)
    for _ in range(20000):
        series = f32(f32(series * f32(0.99993)) + f32(0.0007))
    quotient = 0x0123456789ABCDEF // 12345
    return {
        "marker": 0xC0FFEE, "crc": 0x414FA339, "harmonic": bits(harmonic), "sqrt": 0x3FB504F3,
        "fma": bits(fma_f32(f32(1.1), f32(3.3), f32(-0.7))), "div64_lo": quotient & 0xFFFFFFFF,
        "div64_hi": quotient >> 32, "series": bits(series), "ticks_ok": 1, "handler_float": bits(2.5),
        "svc": 35, "pendsv": 0x50, "basepri": 3, "bitband": 0x120, "exclusive": 42,
        "dsp": 0x8B ^ 0x01040600 ^ 0xAAAA5555, "bits": 0x80002208, "psp": 0x1002D, "convert": 0x0D, "udiv0": 0,
        "irq_order": 0x2103, "saturate": 0x77FFFF80, "done": 0xD0D0,
    }


def main():
    image = open(IMAGE, "rb").read()
    core = cm4.Core(image)
    lib, c = core.lib, core.c
    lib.cm4_configure(c, 82, 4)
    lib.cm4_reset(c)
    stop = 0
    for _ in range(2000):
        stop = lib.cm4_run(c, 100_000)
        if stop != 0 and stop != 1:
            break
    words = struct.unpack("<32I", core.ram_bytes()[:128])
    want = expected()
    failed = 0
    for i, name in enumerate(NAMES):
        ok = words[i] == want[name]
        failed += not ok
        print(f"{name:14} {words[i]:#010x} {'ok' if ok else f'expected {want[name]:#010x}'}")
    print(f"stop {stop}, {lib.cm4_instructions(c)} instructions, {lib.cm4_cycles(c)} cycles, pc {lib.cm4_reg(c, 15):#x}")
    return failed


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
