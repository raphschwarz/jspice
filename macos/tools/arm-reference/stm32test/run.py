"""Runs the STM32 test firmware (stm32test.c) on the model and checks what it does"""
import ctypes
import math
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import stm32  # noqa: E402

IMAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "Tests", "CircuitKitTests",
                     "Fixtures", "stm32-test.bin")

LISTENER = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_uint64, ctypes.c_int, ctypes.c_bool)


def main():
    chip = stm32.Chip()
    lib = chip.lib
    flash = lib.stm32_flash(chip.m)
    data = open(IMAGE, "rb").read()
    ctypes.memmove(flash, data, len(data))
    lib.stm32_reset(chip.m)
    # PA0 at half the reference; PC13 left to its pull-up
    volts = (ctypes.c_double * 49)()
    volts[0] = 1.65
    volts[45] = 3.3
    lib.stm32_set_pin_voltages(chip.m, volts, 49, 3.3)
    events = []
    listener = LISTENER(lambda _, cycle, index, high: events.append((cycle, index, high)))
    pins = (ctypes.c_int * 2)(5, 6)
    lib.stm32_watch_pins(chip.m, pins, 2, ctypes.cast(listener, ctypes.c_void_p), None)
    chip.codec.source = lambda frame: (int(16000 * math.sin(2 * math.pi * 440 * frame / 48000)), 0)
    chip.run_for(0.25)
    lib.stm32_usart_input(chip.m, 1, b"hello\n", 6)
    chip.run_for(0.1)
    volts[45] = 0
    lib.stm32_set_pin_voltages(chip.m, volts, 49, 3.3)
    chip.run_for(0.05)
    text = bytes(chip.usart_log).decode()
    print(repr(text[:200]))
    toggles = [e for e in events if e[1] == 5]
    pa6 = [e for e in events if e[1] == 6]
    hclk = lib.stm32_hclk(chip.m)
    period = (toggles[-1][0] - toggles[10][0]) / (len(toggles) - 11) / hclk if len(toggles) > 12 else 0
    out = chip.codec.out
    left = [l for l, r in out[1000:2000]]
    right = [r for l, r in out[1000:2000]]
    print(f"{len(toggles)} PA5 toggles, every {period * 1e3:.3f} ms; PA6 events {pa6[-2:]}")
    print(f"{len(out)} frames; left values {sorted(set(left))}; right peak {max(right)}")
    checks = {
        "boot": text.startswith("boot\n"),
        "i2c": "i2c ack\n" in text and chip.codec.registers.get(6) == 0,
        "flash": "flash 12345678\n" in text,
        "adc": "adc 2048\n" in text,
        "serial input": "HELLO\n" in text,
        "systick": abs(period - 1e-3) < 1e-5,
        "pa6 follows pc13": bool(pa6) and pa6[-1][2] is False,
        "i2s left": sorted(set(left)) == [-8192, 8192],
        "i2s right": 7900 < max(right) <= 8000,
        "frame rate": abs(len(out) / lib.stm32_time(chip.m) - 47990) < 1500,
        "timer compares": any(f"cc {n}\n" in text for n in range(97, 102)),
    }
    for name, ok in checks.items():
        print(f"{name:18} {'ok' if ok else 'FAILED'}")
    return all(checks.values())


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
