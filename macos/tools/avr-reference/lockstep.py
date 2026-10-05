"""Runs a firmware in simavr and in avr.py side by side and reports the first difference in PC, SREG, SP or registers.
python3 lockstep.py sketch.elf sketch.bin instructions [adc_mv] [variant]"""
import os, subprocess, sys
import avr as emu
elf, binary, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
mv = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] != '-' else None
variant = sys.argv[5] if len(sys.argv) > 5 else 'atmega328p'
args = ['./tracer', elf, str(count)] + ([mv] if mv else [])
env = dict(os.environ, MCU=variant, FREQUENCY=str(emu.VARIANTS[variant].clock))
proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=env)
cpu = emu.load(binary, variant)
cpu.simavr_mode()
if mv:
    cpu.vcc = 3.3  # simavr's AVCC (and VCC, when it is not set)
    cpu.pin_volts = [int(mv) / 1000] * cpu.pin_count  # the ADC only: simavr leaves the digital levels low
    if variant == 'atmega2560': cpu.pin_volts[62:70] = [0.0] * 8  # simavr 1.6 ignores ADC8-ADC15
n = 0
prev = 0
for line in proc.stdout:
    parts = line.split()
    if len(parts) < 36 or not parts[0].isdigit(): continue
    cyc, pc, sreg, sp = int(parts[0]), int(parts[1], 16), int(parts[2], 16), int(parts[3], 16)
    regs = [int(x, 16) for x in parts[4:36]]
    mine_sp = cpu.data[emu.SPL] | cpu.data[emu.SPH] << 8
    if (pc, sreg, sp, regs) != (cpu.pc, cpu.data[emu.SREG], mine_sp, cpu.data[:32]) or cyc != cpu.cycles:
        print(f"difference at instruction {n}")
        print(f"  simavr: cycle {cyc} pc {pc:05x} sreg {sreg:02x} sp {sp:04x} regs {' '.join('%02x' % r for r in regs)}")
        print(f"  mine:   cycle {cpu.cycles} pc {cpu.pc:05x} sreg {cpu.data[emu.SREG]:02x} sp {mine_sp:04x} regs {' '.join('%02x' % r for r in cpu.data[:32])}")
        print(f"  opcode at previous pc: {cpu.flash[prev]:04x} (pc {prev:05x})")
        proc.kill()
        sys.exit(1)
    prev = cpu.pc
    cpu.step()
    if cpu.interrupt_ready(): cpu.step()  # simavr enters an interrupt in the same run as the instruction before
    n += 1
print(f"{n} instructions identical, cycle {cpu.cycles}")
print("serial:", bytes(cpu.serial_out).decode(errors="replace")[:300])
