#!/usr/bin/env python3
"""Random instructions in the C Cortex-M4 core and in QEMU's (through Unicorn), from the same random state, compared
after each: the registers, the flags, GE and IT, the FPU's registers and FPSCR, and memory. Instructions QEMU faults
on are skipped (faults are tested on their own).

    fuzz.py [kind] [count] [seed]

kind: 16 (16-bit Thumb), 32 (32-bit Thumb-2 but the FPU), fp (the FPU), mem (loads and stores, every register
pointing into SRAM), it (IT blocks), all (the default: each in turn)
"""
import random
import struct
import sys

import cm4

try:
    import capstone
    DISASSEMBLER = capstone.Cs(capstone.CS_ARCH_ARM, capstone.CS_MODE_THUMB | capstone.CS_MODE_MCLASS)
except Exception:
    DISASSEMBLER = None

CODE = 0x100
PC = cm4.FLASH + CODE
SP = cm4.RAM + 0x10000
XPSR_COMPARED = 0xF80F0000 | 0x0600FC00


def disassemble(code):
    if not DISASSEMBLER:
        return code.hex()
    return "; ".join(f"{i.mnemonic} {i.op_str}" for i in DISASSEMBLER.disasm(code, PC)) or code.hex()


def random_float_bits(rng):
    kind = rng.random()
    if kind < 0.08:
        return rng.choice([0, 0x80000000, 0x7F800000, 0xFF800000, 0x7FC00000, 0x7F800001, 0xFFC00001, 0x00000001,
                           0x80000001, 0x007FFFFF, 0x00800000, 0x7F7FFFFF, 0x3F800000, 0xBF800000])
    if kind < 0.6:
        # ordinary values, of every size
        return struct.unpack("<I", struct.pack("<f", rng.uniform(-1, 1) * 2.0 ** rng.randint(-40, 40)))[0]
    if kind < 0.7:
        return rng.randint(0, 0x7FFFFF) | (rng.getrandbits(1) << 31)  # denormal
    return rng.getrandbits(32)


def random_state(rng, memory):
    if memory:
        regs = [cm4.RAM + 0x1000 + rng.randint(0, 0xE000) for _ in range(13)]
        for i in range(13):
            if rng.random() < 0.2:
                regs[i] = rng.randint(0, 64)  # an index or offset
    else:
        regs = [rng.choice([rng.getrandbits(32), rng.randint(0, 40), 0x80000000, 0x7FFFFFFF, 0xFFFFFFFF, 0x8000,
                            0x7FFF, rng.getrandbits(16)]) if rng.random() < 0.3 else rng.getrandbits(32) for _ in range(13)]
    regs += [SP, rng.getrandbits(32) | 1, PC]
    xpsr = (rng.getrandbits(5) << 27) | (rng.getrandbits(4) << 16)
    sregs = [random_float_bits(rng) for _ in range(32)]
    fpscr = rng.getrandbits(4) << 28
    if rng.random() < 0.3:
        fpscr |= rng.choice([1 << 24, 1 << 25, 1 << 22, 2 << 22, 3 << 22, 3 << 24])
    return regs, xpsr, sregs, fpscr


def random_instruction(rng, kind):
    if kind == "16":
        while True:
            op = rng.getrandbits(16)
            if op >= 0xE800:
                continue
            if (op & 0xFF00) in (0xBE00, 0xDE00, 0xDF00):  # BKPT, UDF, SVC
                continue
            if (op & 0xFF00) == 0xBF00:  # IT and hints (tested apart)
                continue
            if (op & 0xFFE0) == 0xB660:  # CPS
                continue
            return struct.pack("<H", op)
    if kind == "fp":
        hw1 = rng.choice([0xEC00, 0xED00, 0xEE00, 0xEE00, 0xEE00]) | rng.getrandbits(8)
        hw2 = (rng.getrandbits(4) << 12) | (rng.choice([0xA, 0xA, 0xA, 0xB]) << 8) | rng.getrandbits(8)
        return struct.pack("<HH", hw1, hw2)
    while True:
        hw1 = 0xE800 + rng.randint(0, 0x17FF)
        hw2 = rng.getrandbits(16)
        if kind == "32" and ((hw1 & 0xEC00) == 0xEC00):  # the coprocessor space: the FPU's
            continue
        if kind == "mem":
            # loads and stores: single, dual, multiple
            hw1 = rng.choice([0xF800 | rng.getrandbits(9), 0xE840 | rng.getrandbits(6) | (rng.getrandbits(2) << 7),
                              0xE880 | rng.getrandbits(4) | (rng.getrandbits(2) << 4), 0xE900 | rng.getrandbits(6),
                              0xED00 | rng.getrandbits(8), 0xEC80 | rng.getrandbits(7)])
            if (hw1 & 0xFE00) == 0xEC00 or (hw1 & 0xFF00) == 0xED00:
                hw2 = (hw2 & 0xF0FF) | (rng.choice([0xA, 0xB]) << 8)
        if (hw1 & 0xF800) == 0xF000 and (hw2 & 0x8000):
            # branches and misc control: keep the branches, not MSR, MRS, hints, CPS
            if (hw2 & 0x5000) == 0 and ((hw1 >> 7) & 7) == 7:
                continue
        return struct.pack("<HH", hw1, hw2)


def unpredictable(code):
    """Encodings whose register use the architecture leaves UNPREDICTABLE (QEMU does one thing, the manual allows
    any): not compared"""
    if len(code) < 4:
        hw1 = struct.unpack("<H", code[:2])[0]
        return False
    hw1, hw2 = struct.unpack("<HH", code[:4])
    if hw1 < 0xE800:
        return False
    rn = hw1 & 0xF
    # VMOV between two core registers and two singles or a double: SP or the PC as a core register
    if (hw1 & 0xFFE0) == 0xEC40 and (hw2 & 0x0E00) == 0x0A00 and (rn in (13, 15) or (hw2 >> 12) in (13, 15)):
        return True
    # LDM / STM (wide): SP in the list, the PC in a store's, the PC and LR in a load's, writeback with Rn in the list
    if (hw1 & 0xFE40) == 0xE800 and ((hw1 >> 7) & 3) in (1, 2):
        load, writeback = (hw1 >> 4) & 1, (hw1 >> 5) & 1
        if hw2 & 0x2000 or (not load and hw2 & 0x8000) or (load and (hw2 & 0xC000) == 0xC000):
            return True
        if writeback and (hw2 >> rn) & 1 or bin(hw2).count("1") < 2 or rn == 15:
            return True
    # LDRD / STRD / exclusives / table branches
    if (hw1 & 0xFE40) == 0xE840:
        rt, rt2 = hw2 >> 12, (hw2 >> 8) & 0xF
        p, w = (hw1 >> 8) & 1, (hw1 >> 5) & 1
        if (p or w) and (rt in (13, 15) or rt2 in (13, 15) or (w and (rn == 15 or rn in (rt, rt2))) or
                         ((hw1 >> 4) & 1 and rt == rt2)):
            return True
        if not (p or w) and (rt in (13, 15) or rn == 15 or (hw2 & 0xF) in (13, 15)):
            return True
    # loads and stores: Rt or Rn the PC or SP where not allowed, writeback to the base loaded
    if (hw1 & 0xFE00) == 0xF800:
        rt, load = hw2 >> 12, (hw1 >> 4) & 1
        if (hw1 & 0xFF10) == 0xF900:
            return True  # a store with the sign bit: Advanced SIMD in ARMv7-A, which QEMU decodes as such
        if not load and (rt == 15 or rn == 15):
            return True
        if (hw1 & 0x80) == 0 and (hw2 & 0x800) and (hw2 & 0x100) and (rn == 15 or rn == rt):
            return True
        if (hw1 & 0x80) == 0 and not (hw2 & 0x800) and (hw2 & 0xF) in (13, 15):
            return True
    # data processing and multiplies writing SP or the PC, or reading SP or the PC where it is not allowed
    if (hw1 & 0xFE00) == 0xEA00 or (hw1 & 0xF800) == 0xF000 and not (hw2 & 0x8000) or (hw1 & 0xFF00) in (0xFA00, 0xFB00):
        rd = (hw2 >> 8) & 0xF
        if rd in (13, 15) or (hw1 & 0xFF00) in (0xFA00, 0xFB00) and (rn in (13, 15) or (hw2 & 0xF) in (13, 15) or
                                                                   (hw2 >> 12) in (13,)):
            return True
        if (hw1 & 0xFE00) == 0xEA00 and (hw2 & 0xF) in (13, 15):
            return True
        if (hw1 & 0xFF00) == 0xFB80 and (hw2 >> 12) in (13, 15):
            return True
    return False


def breaks_it_block(code, last):
    """An instruction that may not be in an IT block, or only as its last (one that writes the PC)"""
    hw = struct.unpack("<H", code[:2])[0]
    if len(code) == 2:
        if (hw & 0xF000) == 0xD000 or (hw & 0xF500) == 0xB100 or (hw & 0xFF00) == 0xBE00 or (hw & 0xFFE0) == 0xB660:
            return True  # conditional branches, SVC, UDF, CBZ, BKPT, CPS
        if (hw & 0xFF00) == 0xBF00 and hw & 0xF:
            return True  # IT
        writes_pc = ((hw & 0xF800) == 0xE000 or (hw & 0xFF00) == 0x4700 or (hw & 0xFF00) == 0xBD00 or
                     ((hw & 0xFD00) == 0x4400 and (hw & 0x87) == 0x87))
        return writes_pc and not last
    hw2 = struct.unpack("<H", code[2:4])[0]
    if (hw & 0xF800) == 0xF000 and hw2 & 0x8000:
        return not last or (hw & 0xFFE0) == 0xF3E0 or (hw2 & 0xD000) == 0x8000 and ((hw >> 6) & 0xE) != 0xE
    writes_pc = (((hw & 0xFF70) == 0xF850 or (hw & 0xFFF0) == 0xF8D0) and hw2 >> 12 == 15 or
                 (hw & 0xFE50) == 0xE810 and hw2 & 0x8000 or (hw & 0xFFF0) == 0xE8D0 and (hw2 & 0xFFE0) == 0xF000)
    return writes_pc and not last


def compare(a, b, before):
    problems = []
    for i in range(16):
        if a["r"][i] != b["r"][i]:
            problems.append(f"R{i}: {a['r'][i]:#010x} vs {b['r'][i]:#010x} (was {before['r'][i]:#010x})")
    if (a["xpsr"] ^ b["xpsr"]) & XPSR_COMPARED:
        problems.append(f"xPSR: {a['xpsr']:#010x} vs {b['xpsr']:#010x} (was {before['xpsr']:#010x})")
    for i in range(32):
        if a["s"][i] != b["s"][i]:
            problems.append(f"S{i}: {a['s'][i]:#010x} vs {b['s'][i]:#010x} (was {before['s'][i]:#010x})")
    if a["fpscr"] != b["fpscr"]:
        problems.append(f"FPSCR: {a['fpscr']:#010x} vs {b['fpscr']:#010x} (was {before['fpscr']:#010x})")
    return problems


def run(kind, count, seed):
    from unicorn import UcError
    rng = random.Random(seed)
    core = cm4.Core()
    ref = cm4.Reference()
    ram = bytes(rng.getrandbits(8) for _ in range(cm4.RAM_SIZE))
    tested = skipped = failed = 0
    undefined_here = []
    for trial in range(count):
        memory = kind == "mem"
        if kind == "it":
            first = rng.randint(0, 13)
            mask = rng.randint(1, 15)
            code = struct.pack("<H", 0xBF00 | (first << 4) | mask)
            steps = 1 + (4 - ((mask & -mask).bit_length() - 1))
            block = [random_instruction(rng, rng.choice(["16", "32"])) for _ in range(4)]
            code += b"".join(block)
            # (no branches, even last: QEMU is run to the block's end)
            if any(unpredictable(i) or breaks_it_block(i, False) for i in block[:steps - 1]):
                continue
            block_end = CODE + 2 + sum(len(i) for i in block[:steps - 1])
        else:
            code = random_instruction(rng, kind)
            steps = 1
        code += b"\x00\xbf" * 8  # NOPs after
        regs, xpsr, sregs, fpscr = random_state(rng, memory or rng.random() < 0.15)
        core.load_flash(CODE, code)
        ref.load_flash(CODE, code)
        core.set_ram(ram)
        ref.set_ram(ram)
        if kind != "it" and unpredictable(code):
            continue
        core.set_state(regs, xpsr, sregs, fpscr)
        ref.set_state(regs, xpsr, sregs, fpscr)
        before = core.state()
        ok = True
        for k in range(1 if kind == "it" else steps):
            pc_core = core.state()["r"][15]
            try:
                # (QEMU runs an IT block as a whole: the core runs its instructions and is compared at the end)
                if kind == "it":
                    ref.run_to(ref.state()["r"][15], cm4.FLASH + block_end)
                else:
                    ref.step(ref.state()["r"][15])
                if kind == "it":
                    for _ in range(steps - 1):
                        core.step()
            except UcError:
                skipped += 1
                ok = False
                # (QEMU keeps the exception pending: a fresh one for the next trial)
                ref = cm4.Reference()
                break
            core.step()
            a, b = core.state(), ref.state()
            if core.lib.cm4_read(core.c, 0xE000ED28, 4) & (1 << 16):
                # this core found it UNDEFINED where QEMU ran it: listed apart
                undefined_here.append(code[:4].hex() + " " + disassemble(code[:4]))
                ok = False
                break
            problems = compare(a, b, before)
            if not problems and core.ram_bytes() != ref.ram_bytes():
                ca, rb = core.ram_bytes(), ref.ram_bytes()
                where = [i for i in range(len(ca)) if ca[i] != rb[i]]
                problems.append(f"memory differs at {len(where)} bytes, first {cm4.RAM + where[0]:#010x}: "
                                f"{ca[where[0]]:#04x} vs {rb[where[0]]:#04x}")
            if problems:
                failed += 1
                ok = False
                print(f"[{kind} #{trial} step {k}] {disassemble(code[:12] if kind == 'it' else code[:4])} "
                      f"({code[:4].hex()}) at {pc_core:#x}")
                for p in problems[:6]:
                    print("   ", p)
                break
        if ok:
            tested += 1
    if undefined_here:
        print(f"undefined here but run by QEMU ({len(undefined_here)}):", ", ".join(undefined_here[:12]))
    print(f"{kind}: {tested} agreed, {failed} differed, {skipped} skipped (QEMU faulted), {len(undefined_here)} undefined here")
    return failed


def main():
    kind = sys.argv[1] if len(sys.argv) > 1 else "all"
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 2000
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    kinds = ["16", "32", "fp", "mem", "it"] if kind == "all" else [kind]
    failures = sum(run(k, count, seed) for k in kinds)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
