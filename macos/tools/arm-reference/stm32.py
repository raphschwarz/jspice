"""The STM32F405 model (Sources/CortexM4/stm32f4.c, around the core) through ctypes, with stand-ins for what a
module's board connects it to: a WM8731 codec on I2C and I2S, an SPI device, a USART's receiver. For running
Mutable Instruments' firmware here, where the model is developed:

    python3 stm32.py rings.hex 2.0 --wav out.wav --trigger A2 --every 0.5

runs Rings for two seconds of its time, strumming it through its trigger input (PA2, active low) twice a second,
and writes what it sends its codec to out.wav."""
import argparse
import ctypes
import math
import os
import struct
import subprocess
import sys
import tempfile
import time
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "..", "..", "Sources", "CortexM4")
FLASH = 0x08000000

I2C_START = ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_int, ctypes.c_uint8, ctypes.c_bool)
I2C_WRITE = ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_int, ctypes.c_uint8)
I2C_READ = ctypes.CFUNCTYPE(ctypes.c_uint8, ctypes.c_void_p, ctypes.c_int, ctypes.c_bool)
I2C_STOP = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_int)
SPI_EXCHANGE = ctypes.CFUNCTYPE(ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int, ctypes.c_uint32, ctypes.c_int)
I2S_FRAME = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_int, ctypes.c_int32, ctypes.c_int32,
                             ctypes.POINTER(ctypes.c_int32), ctypes.POINTER(ctypes.c_int32))
USART_SEND = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_int, ctypes.c_uint8)


class Devices(ctypes.Structure):
    _fields_ = [("context", ctypes.c_void_p), ("i2c_start", I2C_START), ("i2c_write", I2C_WRITE),
                ("i2c_read", I2C_READ), ("i2c_stop", I2C_STOP), ("spi_exchange", SPI_EXCHANGE),
                ("i2s_frame", I2S_FRAME), ("usart_send", USART_SEND)]


def build():
    out = os.path.join(tempfile.gettempdir(), "jspice-cm4", "libstm32f4.so")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    sources = [os.path.join(SOURCE, f) for f in ("cortex_m4.c", "stm32f4.c")]
    headers = [os.path.join(SOURCE, "include", f) for f in ("CortexM4.h", "STM32F4.h")]
    if not os.path.exists(out) or any(os.path.getmtime(s) > os.path.getmtime(out) for s in sources + headers):
        subprocess.check_call([os.environ.get("CC", "gcc"), "-O2", "-g", "-shared", "-fPIC", "-I",
                               os.path.join(SOURCE, "include")] + sources + ["-o", out, "-lm"])
    lib = ctypes.CDLL(out)
    p, u32, u64, b, i, d = ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint64, ctypes.c_bool, ctypes.c_int, ctypes.c_double
    for name, res, args in [
        ("stm32f4_create", p, [d]), ("stm32f4_destroy", None, [p]), ("stm32f4_core", p, [p]),
        ("stm32f4_set_devices", None, [p, ctypes.POINTER(Devices)]),
        ("stm32f4_flash", ctypes.POINTER(ctypes.c_uint8), [p]), ("stm32f4_reset", None, [p]),
        ("stm32f4_run", i, [p, u64]), ("stm32f4_hclk", d, [p]), ("stm32f4_time", d, [p]),
        ("stm32f4_set_input", None, [p, i, i, b, b]), ("stm32f4_set_voltage", None, [p, i, i, d]),
        ("stm32f4_pin_mode", i, [p, i, i]), ("stm32f4_pin_level", b, [p, i, i]),
        ("stm32f4_pin_driven", b, [p, i, i]), ("stm32f4_dac_volts", d, [p, i]),
        ("stm32f4_usart_input", None, [p, i, ctypes.c_char_p, i]), ("stm32f4_usart_input_waiting", i, [p, i]),
        ("stm32f4_set_pin_voltages", None, [p, ctypes.POINTER(d), i, d]),
        ("stm32f4_pin_states", None, [p, ctypes.POINTER(ctypes.c_uint8), i]),
        ("stm32f4_watch_pins", None, [p, ctypes.POINTER(i), i, ctypes.c_void_p, p]),
        ("cm4_reg", u32, [p, i]), ("cm4_cycles", u64, [p]), ("cm4_instructions", u64, [p]),
        ("cm4_read", u32, [p, u32, u32]), ("cm4_xpsr", u32, [p]),
    ]:
        f = getattr(lib, name)
        f.restype = res
        f.argtypes = args
    return lib


def read_hex(path):
    """An Intel HEX file's data: {address: bytes}"""
    chunks, base = {}, 0
    for line in open(path):
        line = line.strip()
        if not line.startswith(":"):
            continue
        data = bytes.fromhex(line[1:])
        count, address, kind = data[0], (data[1] << 8) | data[2], data[3]
        payload = data[4:4 + count]
        if kind == 0:
            chunks[base + address] = payload
        elif kind == 2:
            base = int.from_bytes(payload, "big") << 4
        elif kind == 4:
            base = int.from_bytes(payload, "big") << 16
        elif kind == 1:
            break
    return chunks


class WM8731:
    """The codec's control port (its registers, written in pairs of bytes) and its audio: what the chip sends kept,
    what it receives from `source`"""

    def __init__(self, source=None):
        self.registers = {}
        self.pending = []
        self.out = []
        self.source = source
        self.frames = 0

    def start(self, address, read):
        self.pending = []
        return address == 0x1A

    def write(self, byte):
        self.pending.append(byte)
        if len(self.pending) == 2:
            register = self.pending[0] >> 1
            self.registers[register] = ((self.pending[0] & 1) << 8) | self.pending[1]
        return True

    def frame(self, left, right):
        # (left-justified in 32 bits: kept as 16)
        self.out.append((left >> 16, right >> 16))
        self.frames += 1
        if self.source:
            l, r = self.source(self.frames)
            return ctypes.c_int32(l << 16).value, ctypes.c_int32(r << 16).value
        return 0, 0


class Chip:
    PORTS = "ABCDEFGHI"

    def __init__(self, hse=8e6):
        self.lib = build()
        self.m = self.lib.stm32f4_create(hse)
        self.core = self.lib.stm32f4_core(self.m)
        self.codec = WM8731()
        self.spi_log = []
        self.usart_log = bytearray()
        self.i2c_log = []
        lib = self.lib

        def i2c_start(_, bus, address, read):
            self.i2c_log.append(("start", bus, address, read))
            return self.codec.start(address, read)

        def i2c_write(_, bus, byte):
            return self.codec.write(byte)

        def i2c_read(_, bus, ack):
            return 0xFF

        def i2c_stop(_, bus):
            pass

        def spi_exchange(_, spi, frame, bits):
            self.spi_log.append((spi, frame, bits, lib.stm32f4_time(self.m)))
            return 0

        def i2s_frame(_, spi, left, right, in_left, in_right):
            l, r = self.codec.frame(left, right)
            in_left[0] = l
            in_right[0] = r

        def usart_send(_, usart, byte):
            self.usart_log.append(byte)

        self.callbacks = [I2C_START(i2c_start), I2C_WRITE(i2c_write), I2C_READ(i2c_read), I2C_STOP(i2c_stop),
                          SPI_EXCHANGE(spi_exchange), I2S_FRAME(i2s_frame), USART_SEND(usart_send)]
        self.devices = Devices(None, *self.callbacks)
        lib.stm32f4_set_devices(self.m, ctypes.byref(self.devices))

    def load(self, path):
        flash = self.lib.stm32f4_flash(self.m)
        if path.endswith(".hex"):
            for address, data in read_hex(path).items():
                ctypes.memmove(ctypes.addressof(flash.contents) + address - FLASH, data, len(data))
        else:
            data = open(path, "rb").read()
            ctypes.memmove(ctypes.addressof(flash.contents) + 0x8000, data, len(data))
        self.lib.stm32f4_reset(self.m)

    def pin(self, name):
        return self.PORTS.index(name[0].upper()), int(name[1:])

    def set_input(self, name, level, driven=True):
        port, pin = self.pin(name)
        self.lib.stm32f4_set_input(self.m, port, pin, driven, level)

    def set_voltage(self, name, volts):
        port, pin = self.pin(name)
        self.lib.stm32f4_set_voltage(self.m, port, pin, volts)

    def run_for(self, seconds):
        lib = self.lib
        target = lib.stm32f4_time(self.m) + seconds
        while lib.stm32f4_time(self.m) < target:
            remaining = target - lib.stm32f4_time(self.m)
            cycles = max(1, int(min(remaining, 0.001) * lib.stm32f4_hclk(self.m)))
            stop = lib.stm32f4_run(self.m, cycles)
            if stop >= 2:
                return stop
        return 0

    def where(self):
        lib, c = self.lib, self.core
        return f"pc {lib.cm4_reg(c, 15):#010x} lr {lib.cm4_reg(c, 14):#010x} sp {lib.cm4_reg(c, 13):#010x} " \
               f"xpsr {lib.cm4_xpsr(c):#010x}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("firmware")
    parser.add_argument("seconds", type=float)
    parser.add_argument("--wav")
    parser.add_argument("--trigger", help="a pin pulsed low (a trigger input, active low)")
    parser.add_argument("--every", type=float, default=0.5)
    parser.add_argument("--high", action="append", default=[], help="pins held high")
    parser.add_argument("--low", action="append", default=[], help="pins held low")
    parser.add_argument("--volts", action="append", default=[], help="pin=volts for the ADCs")
    parser.add_argument("--sine", type=float, help="a sine at the codec's input, Hz")
    parser.add_argument("--all-volts", type=float, help="every ADC pin at this voltage (before --volts)")
    parser.add_argument("--normal", help="a pin whose level the codec's input follows (a jack's normalling probe, "
                                         "as an unpatched input on Mutable's modules)")
    args = parser.parse_args()

    chip = Chip()
    chip.load(args.firmware)
    for name in args.high:
        chip.set_input(name, True)
    for name in args.low:
        chip.set_input(name, False)
    if args.all_volts is not None:
        for port in "ABC":
            for pin in range(16):
                chip.set_voltage(f"{port}{pin}", args.all_volts)
    if args.sine:
        chip.codec.source = lambda frame: (int(8000 * math.sin(2 * math.pi * args.sine * frame / 48000)),) * 2
    for item in args.volts:
        name, volts = item.split("=")
        chip.set_voltage(name, float(volts))
    if args.trigger:
        chip.set_input(args.trigger, True)
    if args.normal:
        port, pin = chip.pin(args.normal)
        chip.codec.source = lambda frame: (-8192, -8192) if chip.lib.stm32f4_pin_level(chip.m, port, pin) else (8192, 8192)

    started = time.time()
    t, step = 0.0, 0.01
    next_trigger = 0.1
    while t < args.seconds:
        if args.trigger and t >= next_trigger:
            chip.set_input(args.trigger, False)
            stop = chip.run_for(0.005)
            chip.set_input(args.trigger, True)
            next_trigger += args.every
            t += 0.005
        else:
            stop = chip.run_for(step)
            t += step
        if stop:
            print(f"stopped ({stop}) at {t:.3f} s: {chip.where()}")
            break
    elapsed = time.time() - started
    lib = chip.lib
    out = chip.codec.out
    print(f"{args.seconds} s in {elapsed:.1f} s ({args.seconds / elapsed:.2f}x real time), "
          f"{lib.cm4_instructions(chip.core) / elapsed / 1e6:.0f} M instructions/s, HCLK {lib.stm32f4_hclk(chip.m) / 1e6:.0f} MHz")
    print(f"codec registers: { {k: hex(v) for k, v in sorted(chip.codec.registers.items())} }")
    print(f"{len(out)} frames sent ({len(out) / max(lib.stm32f4_time(chip.m), 1e-9):.0f} a second)")
    if out:
        peak = max(max(abs(l), abs(r)) for l, r in out)
        rms = math.sqrt(sum(l * l + r * r for l, r in out) / (2 * len(out)))
        print(f"output peak {peak}, rms {rms:.1f}")
    if chip.spi_log:
        print(f"{len(chip.spi_log)} SPI frames, the first: {[(s, hex(f), b) for s, f, b, _ in chip.spi_log[:8]]}")
    if chip.usart_log:
        print("usart:", bytes(chip.usart_log[:200]))
    print(chip.where())
    if args.wav and out:
        with wave.open(args.wav, "wb") as w:
            w.setnchannels(2)
            w.setsampwidth(2)
            w.setframerate(48000)
            w.writeframes(b"".join(struct.pack("<hh", max(-32768, min(32767, l)), max(-32768, min(32767, r)))
                                   for l, r in out))


if __name__ == "__main__":
    main()
