"""The C Cortex-M4 core (Sources/CortexM4) through ctypes, built here with the host's C compiler, and Unicorn's
(QEMU's) Cortex-M4 set up the same way, for comparing the two instruction by instruction."""
import ctypes
import os
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "..", "..", "Sources", "CortexM4")

FLASH, FLASH_SIZE = 0x08000000, 0x100000
RAM, RAM_SIZE = 0x20000000, 0x20000


def build():
    """The core as a shared library, rebuilt when its source is newer"""
    out = os.path.join(tempfile.gettempdir(), "jspice-cm4", "libcm4.so")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    sources = [os.path.join(SOURCE, "cortex_m4.c"), os.path.join(SOURCE, "include", "CortexM4.h")]
    if not os.path.exists(out) or any(os.path.getmtime(s) > os.path.getmtime(out) for s in sources):
        subprocess.check_call([os.environ.get("CC", "gcc"), "-O2", "-g", "-shared", "-fPIC", "-I", os.path.join(SOURCE, "include"),
                               os.path.join(SOURCE, "cortex_m4.c"), "-o", out, "-lm"])
    lib = ctypes.CDLL(out)
    u32, u64, p = ctypes.c_uint32, ctypes.c_uint64, ctypes.c_void_p
    for name, res, args in [
        ("cm4_create", p, []), ("cm4_destroy", None, [p]),
        ("cm4_add_memory", ctypes.POINTER(ctypes.c_uint8), [p, u32, u32, ctypes.c_bool]),
        ("cm4_alias", None, [p, u32, u32]), ("cm4_reset", None, [p]),
        ("cm4_step", ctypes.c_int, [p]), ("cm4_run", ctypes.c_int, [p, u64]),
        ("cm4_cycles", u64, [p]), ("cm4_instructions", u64, [p]),
        ("cm4_reg", u32, [p, ctypes.c_int]), ("cm4_set_reg", None, [p, ctypes.c_int, u32]),
        ("cm4_xpsr", u32, [p]), ("cm4_set_xpsr", None, [p, u32]),
        ("cm4_sreg", u32, [p, ctypes.c_int]), ("cm4_set_sreg", None, [p, ctypes.c_int, u32]),
        ("cm4_fpscr", u32, [p]), ("cm4_set_fpscr", None, [p, u32]),
        ("cm4_special", u32, [p, ctypes.c_int]), ("cm4_set_special", None, [p, ctypes.c_int, u32]),
        ("cm4_read", u32, [p, u32, u32]), ("cm4_write", None, [p, u32, u32, u32]),
        ("cm4_configure", None, [p, ctypes.c_int, ctypes.c_int]), ("cm4_set_irq", None, [p, ctypes.c_int, ctypes.c_bool]),
    ]:
        f = getattr(lib, name)
        f.restype = res
        f.argtypes = args
    return lib


LIB = None


class Core:
    """The C core with flash at 0x08000000 (and 0) and SRAM at 0x20000000"""

    def __init__(self, image=b"", ram_size=RAM_SIZE):
        global LIB
        if LIB is None:
            LIB = build()
        self.lib = LIB
        self.c = LIB.cm4_create()
        self.flash = LIB.cm4_add_memory(self.c, FLASH, FLASH_SIZE, False)
        LIB.cm4_alias(self.c, 0, FLASH)
        self.ram = LIB.cm4_add_memory(self.c, RAM, ram_size, True)
        self.ram_size = ram_size
        ctypes.memmove(self.flash, image, len(image))
        # the FPU on, as a firmware's startup turns it on
        LIB.cm4_reset(self.c)
        LIB.cm4_write(self.c, 0xE000ED88, 0xF << 20, 4)

    def __del__(self):
        if getattr(self, "c", None):
            self.lib.cm4_destroy(self.c)

    def load_flash(self, offset, data):
        ctypes.memmove(ctypes.addressof(self.flash.contents) + offset, data, len(data))

    def ram_bytes(self):
        return ctypes.string_at(self.ram, self.ram_size)

    def set_ram(self, data):
        ctypes.memmove(self.ram, data, len(data))

    def state(self):
        lib, c = self.lib, self.c
        return {
            "r": [lib.cm4_reg(c, i) for i in range(16)],
            "xpsr": lib.cm4_xpsr(c),
            "s": [lib.cm4_sreg(c, i) for i in range(32)],
            "fpscr": lib.cm4_fpscr(c),
        }

    def set_state(self, regs, xpsr, sregs, fpscr):
        # from reset: no exception active or pending, the FPU on
        self.lib.cm4_reset(self.c)
        self.lib.cm4_write(self.c, 0xE000ED88, 0xF << 20, 4)
        for i, v in enumerate(regs):
            self.lib.cm4_set_reg(self.c, i, v)
        self.lib.cm4_set_xpsr(self.c, xpsr)
        for i, v in enumerate(sregs):
            self.lib.cm4_set_sreg(self.c, i, v)
        self.lib.cm4_set_special(self.c, 5, 4)  # CONTROL.FPCA
        self.lib.cm4_set_fpscr(self.c, fpscr)

    def step(self):
        return self.lib.cm4_step(self.c)


class Reference:
    """QEMU's Cortex-M4 (through Unicorn) with the same memories"""

    def __init__(self, image=b"", ram_size=RAM_SIZE):
        from unicorn import Uc, UC_ARCH_ARM, UC_MODE_THUMB, UC_MODE_MCLASS
        from unicorn import arm_const as a
        self.a = a
        self.mu = Uc(UC_ARCH_ARM, UC_MODE_THUMB | UC_MODE_MCLASS)
        self.mu.ctl_set_cpu_model(a.UC_CPU_ARM_CORTEX_M4)
        self.mu.mem_map(FLASH, FLASH_SIZE)
        self.mu.mem_map(RAM, ram_size)
        self.mu.mem_write(FLASH, image)
        self.ram_size = ram_size
        self.regs = [getattr(a, f"UC_ARM_REG_R{i}") for i in range(13)] + [a.UC_ARM_REG_SP, a.UC_ARM_REG_LR, a.UC_ARM_REG_PC]
        self.sregs = [getattr(a, f"UC_ARM_REG_S{i}") for i in range(32)]

    def load_flash(self, offset, data):
        self.mu.mem_write(FLASH + offset, data)
        # (QEMU keeps the code it translated: new code at the same place needs it dropped)
        self.mu.ctl_remove_cache(FLASH + offset, FLASH + offset + len(data))

    def ram_bytes(self):
        return bytes(self.mu.mem_read(RAM, self.ram_size))

    def set_ram(self, data):
        self.mu.mem_write(RAM, data)

    def state(self):
        mu, a = self.mu, self.a
        regs = [mu.reg_read(r) for r in self.regs]
        return {
            "r": regs,
            "xpsr": mu.reg_read(a.UC_ARM_REG_XPSR),
            "s": [mu.reg_read(r) for r in self.sregs],
            "fpscr": mu.reg_read(a.UC_ARM_REG_FPSCR),
        }

    def set_state(self, regs, xpsr, sregs, fpscr):
        mu, a = self.mu, self.a
        for r, v in zip(self.regs, regs):
            mu.reg_write(r, v | 1 if r == a.UC_ARM_REG_PC else v)
        mu.reg_write(a.UC_ARM_REG_XPSR_NZCVQG, xpsr & 0xF80F0000)
        for r, v in zip(self.sregs, sregs):
            mu.reg_write(r, v)
        # an FP context already active (CONTROL.FPCA), so that the first FP instruction keeps FPSCR's modes
        mu.reg_write(a.UC_ARM_REG_CONTROL, 0xC)  # (QEMU runs this M4 as if Secure: SFPA too)
        mu.reg_write(a.UC_ARM_REG_FPSCR, fpscr)

    def step(self, pc):
        """One instruction at `pc`; raises UcError where QEMU faults"""
        self.mu.emu_start(pc | 1, 0xFFFFFFFF, count=1)

    def run_to(self, pc, end):
        """From `pc` to `end` (QEMU runs an IT block as a whole, its skipped instructions uncounted)"""
        self.mu.emu_start(pc | 1, end, count=64)
