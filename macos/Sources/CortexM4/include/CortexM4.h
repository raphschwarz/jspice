// An ARM Cortex-M4 core with its floating-point unit (ARMv7E-M: Thumb-2, the DSP extension and FPv4-SP), with the
// system control space every Cortex-M4 has: the NVIC, SysTick, the SCB's registers, the FPU's, and DWT's cycle
// counter. The chip around it (its memories and peripherals) is given to it: memories as regions it reads and writes
// directly, everything else through the chip's read and write functions.
//
// It is written in C, not Swift, so that it can be built and checked instruction by instruction against a reference
// (QEMU's Cortex-M4, through Unicorn: tools/arm-reference) where it is developed, and so that its interpreter loop is
// as plain as it can be.

#ifndef CORTEX_M4_H
#define CORTEX_M4_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CM4 CM4;

/// A peripheral register read or write, of `size` bytes (1, 2 or 4) at `address`
typedef uint32_t (*CM4Read)(void *context, uint32_t address, uint32_t size);
typedef void (*CM4Write)(void *context, uint32_t address, uint32_t value, uint32_t size);

/// Why a run stopped
typedef enum {
    CM4_RAN = 0,       ///< it ran the cycles asked for
    CM4_SLEEPING = 1,  ///< in WFI or WFE with nothing to wake it before the end of the run
    CM4_BREAKPOINT = 2,///< a BKPT instruction
    CM4_LOCKUP = 3,    ///< a fault in a fault handler: the core has stopped
    CM4_RESET = 4,     ///< the firmware asked for a system reset (SYSRESETREQ): the core has reset itself
    CM4_HALTED = 5,    ///< halted by a debugger (a breakpoint, a step done): its clock ran on, no instructions
} CM4Stop;

CM4 *cm4_create(void);
void cm4_destroy(CM4 *cpu);

/// A memory at `base`, `size` bytes (both multiples of 4), read and written directly; returns its bytes, zeroed. The
/// same bytes can appear at a second address (flash at 0 as well as at its own address): cm4_alias.
uint8_t *cm4_add_memory(CM4 *cpu, uint32_t base, uint32_t size, bool writable);
/// The memory added at `base` seen at `alias` as well
void cm4_alias(CM4 *cpu, uint32_t alias, uint32_t base);
/// Everything that is neither a memory nor the system control space: the chip's peripherals. Writes to a read-only
/// memory come here too (a flash being programmed).
void cm4_set_io(CM4 *cpu, CM4Read read, CM4Write write, void *context);
/// The chip's number of external interrupt lines (up to 240) and the bits of priority it implements (4 on an STM32)
void cm4_configure(CM4 *cpu, int interrupts, int priority_bits);

/// Power-on reset: SP and PC from the vector table at 0, the system registers at their reset values
void cm4_reset(CM4 *cpu);
/// Runs whole instructions until at least `cycles` more have passed (or it stops); returns why it stopped
CM4Stop cm4_run(CM4 *cpu, uint64_t cycles);
/// One instruction (or one exception entry); returns why it stopped, CM4_RAN when it did not
CM4Stop cm4_step(CM4 *cpu);
/// A debugger's control: halting the core (before its next instruction: its clock runs on, the chip's peripherals
/// with it, it runs no instructions), resuming it (past the breakpoint it halted at), having the next run run one
/// instruction (or one exception entry) and halt again, and breakpoints (up to 16 instructions' addresses), where it
/// halts before running the instruction. A reset leaves all of them as they are.
void cm4_halt(CM4 *cpu);
void cm4_resume(CM4 *cpu);
bool cm4_halted(const CM4 *cpu);
void cm4_step_once(CM4 *cpu);
bool cm4_set_breakpoint(CM4 *cpu, uint32_t address, bool on);
/// Cycles run since reset
uint64_t cm4_cycles(const CM4 *cpu);
/// The cycle a run stops at, at the latest, for the chip to update its peripherals (a timer's next event); set during
/// a run (from a peripheral's register being written), the run stops there
void cm4_set_deadline(CM4 *cpu, uint64_t cycle);

/// An external interrupt line (0 is exception 16) raised or lowered by a peripheral: raising it makes it pending
void cm4_set_irq(CM4 *cpu, int line, bool level);
/// An event for WFE (an SEV from outside)
void cm4_send_event(CM4 *cpu);

/// Registers: 0-12, 13 SP, 14 LR, 15 PC
uint32_t cm4_reg(const CM4 *cpu, int n);
void cm4_set_reg(CM4 *cpu, int n, uint32_t value);
/// xPSR: the flags, GE, IT and T bits and the exception number
uint32_t cm4_xpsr(const CM4 *cpu);
void cm4_set_xpsr(CM4 *cpu, uint32_t value);
/// S0-S31 as their bits, and FPSCR
uint32_t cm4_sreg(const CM4 *cpu, int n);
void cm4_set_sreg(CM4 *cpu, int n, uint32_t value);
uint32_t cm4_fpscr(const CM4 *cpu);
void cm4_set_fpscr(CM4 *cpu, uint32_t value);
/// Special registers: MSP, PSP, PRIMASK, BASEPRI, FAULTMASK, CONTROL
enum { CM4_MSP = 0, CM4_PSP = 1, CM4_PRIMASK = 2, CM4_BASEPRI = 3, CM4_FAULTMASK = 4, CM4_CONTROL = 5 };
uint32_t cm4_special(const CM4 *cpu, int which);
void cm4_set_special(CM4 *cpu, int which, uint32_t value);

/// Memory as the core sees it (for tests and the host): through its memories, the system control space or the chip
uint32_t cm4_read(CM4 *cpu, uint32_t address, uint32_t size);
void cm4_write(CM4 *cpu, uint32_t address, uint32_t value, uint32_t size);

/// Instructions retired since reset
uint64_t cm4_instructions(const CM4 *cpu);

#ifdef __cplusplus
}
#endif

#endif
