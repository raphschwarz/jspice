// An ARM Cortex-M4 with its FPU (ARMv7E-M, FPv4-SP-D16): see CortexM4.h. Instructions are decoded as the ARMv7-M
// Architecture Reference Manual (DDI 0403E) tables lay them out, and executed as its pseudocode does; the flags,
// saturation, the DSP extension's GE bits and the FPU's NaN handling and exception flags follow it exactly, checked
// against QEMU's model (tools/arm-reference). Cycles are counted roughly as the Cortex-M4's instruction timings give
// them (a load two, a taken branch three, a divide seven, exception entry twelve): enough for a firmware's timers and
// DMA to keep their rate against the code, not cycle-exact.

#include "CortexM4.h"

#include <fenv.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

// The FPU's rounding modes other than to nearest switch the host's: its floating-point operations must stay between
// the switches
#ifdef __clang__
#pragma STDC FENV_ACCESS ON
#endif

// ------------------------------------------------------------------------------------------------------------ state

typedef struct {
    uint32_t base;
    uint32_t size;
    uint8_t *bytes;
    bool writable;
    bool owned;
} Region;

enum { MAX_REGIONS = 12 };

// exception numbers
enum { EXC_RESET = 1, EXC_NMI = 2, EXC_HARDFAULT = 3, EXC_MEMMANAGE = 4, EXC_BUSFAULT = 5, EXC_USAGEFAULT = 6,
       EXC_SVCALL = 11, EXC_DEBUGMONITOR = 12, EXC_PENDSV = 14, EXC_SYSTICK = 15, EXC_IRQ0 = 16 };
enum { MAX_EXCEPTIONS = 16 + 240 };

// CONTROL bits
enum { CONTROL_NPRIV = 1, CONTROL_SPSEL = 2, CONTROL_FPCA = 4 };

// FPSCR bits
enum { FPSCR_IOC = 1, FPSCR_DZC = 2, FPSCR_OFC = 4, FPSCR_UFC = 8, FPSCR_IXC = 16, FPSCR_IDC = 128,
       FPSCR_RMODE = 3 << 22, FPSCR_FZ = 1 << 24, FPSCR_DN = 1 << 25, FPSCR_AHP = 1 << 26 };
#define FPSCR_WRITABLE 0xF7C0009Fu

// CFSR bits (UsageFault in its top half)
enum { UFSR_UNDEFINSTR = 1 << 16, UFSR_INVSTATE = 1 << 17, UFSR_INVPC = 1 << 18, UFSR_NOCP = 1 << 19,
       UFSR_UNALIGNED = 1 << 24, UFSR_DIVBYZERO = 1 << 25 };

struct CM4 {
    uint32_t r[16];
    /// The stack pointer not in use (R13 is the one in use)
    uint32_t other_sp;
    uint32_t n, z, c, v, q;
    uint32_t ge;
    /// ITSTATE: the condition's top bits and the mask
    uint32_t it;
    uint32_t ipsr;
    uint32_t primask, faultmask, basepri, control;
    uint32_t s[32];
    uint32_t fpscr;

    Region regions[MAX_REGIONS];
    int region_count;
    /// The memory in each megabyte of the address space: NULL where there is none (the peripherals, the system
    /// space), MIXED where more than one shares it
    Region *map[4096];
    /// The memory the code runs from, for fetching: its bytes, where they start, and how far in a word can be read
    const uint8_t *code;
    uint32_t code_base, code_words_end;
    CM4Read io_read;
    CM4Write io_write;
    void *io_context;

    int interrupts;
    int priority_bits;
    uint32_t priority_mask;
    uint8_t priority[MAX_EXCEPTIONS];
    bool pending[MAX_EXCEPTIONS];
    bool active[MAX_EXCEPTIONS];
    bool enabled[MAX_EXCEPTIONS];
    bool level[MAX_EXCEPTIONS];
    /// Whether anything may be pending that could preempt: looked at before each instruction while set
    bool check_exceptions;

    uint32_t vtor, prigroup, scr, ccr, shcsr, cfsr, hfsr, mmfar, bfar, cpacr, fpccr, fpcar, fpdscr;
    uint32_t systick_ctrl, systick_load, systick_calib;
    /// SysTick's counter at `systick_cycle`; it counts down one every cycle (or eighth) from then
    uint32_t systick_value;
    uint64_t systick_cycle;
    /// The cycle SysTick next reaches zero, or UINT64_MAX while it is stopped
    uint64_t systick_wrap;
    uint32_t dwt_ctrl, demcr;
    uint64_t cyccnt_base;

    uint64_t cycles;
    uint64_t instructions;
    uint64_t deadline;
    /// Where the run in progress ends: its length, or the deadline if that comes first (and is set during it)
    uint64_t run_end;
    bool sleeping, event, locked_up;
    /// Exclusive monitor for LDREX/STREX
    bool exclusive;
    uint32_t exclusive_address;

    // the instruction being executed
    uint32_t pc;
    uint32_t next_pc;
    int cost;
    bool stop_breakpoint;
    /// ITSTATE set by the instruction (IT) or by an exception: not advanced after it
    bool it_changed;
    /// Sleeping in WFE (woken by an event as well as an exception), rather than WFI
    bool waiting_for_event;
};

// ----------------------------------------------------------------------------------------------------------- memory

static uint32_t system_read(CM4 *c, uint32_t address, uint32_t size);
static void system_write(CM4 *c, uint32_t address, uint32_t value, uint32_t size);

#define MIXED ((Region *)1)

static Region *find_region_among(CM4 *c, uint32_t address) {
    for (int i = 0; i < c->region_count; i++) {
        Region *r = &c->regions[i];
        if (address - r->base < r->size) return r;
    }
    return NULL;
}

/// The memory holding `address`, if one does
static inline Region *find_region(CM4 *c, uint32_t address) {
    Region *r = c->map[address >> 20];
    if (__builtin_expect(r == MIXED, 0)) return find_region_among(c, address);
    return r && address - r->base < r->size ? r : NULL;
}

static void map_region(CM4 *c, Region *r) {
    for (uint64_t mb = r->base >> 20; mb <= ((uint64_t)r->base + r->size - 1) >> 20 && mb < 4096; mb++) {
        c->map[mb] = c->map[mb] && c->map[mb] != r ? MIXED : r;
    }
}

static uint32_t io_read(CM4 *c, uint32_t address, uint32_t size) {
    if (address >= 0xE0000000u) return system_read(c, address, size);
    // bit-band aliases of SRAM's and the peripherals' first megabyte
    if (address - 0x22000000u < 0x2000000u || address - 0x42000000u < 0x2000000u) {
        uint32_t base = address & 0xF0000000u;
        uint32_t offset = address & 0x01FFFFFFu;
        uint32_t word = base + ((offset >> 5) & ~3u);
        uint32_t bit = ((offset >> 5) & 3) * 8 + ((offset >> 2) & 7);
        return (cm4_read(c, word, 4) >> bit) & 1;
    }
    if (c->io_read) return c->io_read(c->io_context, address, size);
    return 0;
}

static void io_write(CM4 *c, uint32_t address, uint32_t value, uint32_t size) {
    if (address >= 0xE0000000u) {
        system_write(c, address, value, size);
        return;
    }
    if (address - 0x22000000u < 0x2000000u || address - 0x42000000u < 0x2000000u) {
        uint32_t base = address & 0xF0000000u;
        uint32_t offset = address & 0x01FFFFFFu;
        uint32_t word = base + ((offset >> 5) & ~3u);
        uint32_t bit = ((offset >> 5) & 3) * 8 + ((offset >> 2) & 7);
        uint32_t old = cm4_read(c, word, 4);
        cm4_write(c, word, (old & ~(1u << bit)) | ((value & 1) << bit), 4);
        return;
    }
    if (c->io_write) c->io_write(c->io_context, address, value, size);
}

uint32_t cm4_read(CM4 *c, uint32_t address, uint32_t size) {
    Region *r = find_region(c, address);
    if (r && address - r->base <= r->size - size) {
        const uint8_t *p = r->bytes + (address - r->base);
        if (size == 4) { uint32_t v; memcpy(&v, p, 4); return v; }
        if (size == 2) { uint16_t v; memcpy(&v, p, 2); return v; }
        return *p;
    }
    if (r) {
        // an access running off the end of a memory, byte by byte
        uint32_t v = 0;
        for (uint32_t i = 0; i < size; i++) v |= cm4_read(c, address + i, 1) << (8 * i);
        return v;
    }
    return io_read(c, address, size);
}

void cm4_write(CM4 *c, uint32_t address, uint32_t value, uint32_t size) {
    Region *r = find_region(c, address);
    if (r && address - r->base <= r->size - size) {
        if (!r->writable) {
            // a read-only memory's writes go to the chip (a flash being programmed)
            if (c->io_write) c->io_write(c->io_context, address, value, size);
            return;
        }
        uint8_t *p = r->bytes + (address - r->base);
        if (size == 4) memcpy(p, &value, 4);
        else if (size == 2) { uint16_t h = (uint16_t)value; memcpy(p, &h, 2); }
        else *p = (uint8_t)value;
        return;
    }
    if (r) {
        for (uint32_t i = 0; i < size; i++) cm4_write(c, address + i, (value >> (8 * i)) & 0xFF, 1);
        return;
    }
    io_write(c, address, value, size);
}

static inline uint32_t read32(CM4 *c, uint32_t a) { return cm4_read(c, a, 4); }
static inline uint32_t read16(CM4 *c, uint32_t a) { return cm4_read(c, a, 2); }
static inline uint32_t read8(CM4 *c, uint32_t a) { return cm4_read(c, a, 1); }
static inline void write32(CM4 *c, uint32_t a, uint32_t v) { cm4_write(c, a, v, 4); }
static inline void write16(CM4 *c, uint32_t a, uint32_t v) { cm4_write(c, a, v, 2); }
static inline void write8(CM4 *c, uint32_t a, uint32_t v) { cm4_write(c, a, v, 1); }

/// An instruction halfword: from a memory, nearly always
static inline uint32_t fetch16(CM4 *c, uint32_t a) {
    Region *r = find_region(c, a);
    if (r && a - r->base <= r->size - 2) {
        uint16_t v;
        memcpy(&v, r->bytes + (a - r->base), 2);
        return v;
    }
    return cm4_read(c, a, 2);
}

// ----------------------------------------------------------------------------------------------------- arithmetic

enum { SR_LSL = 0, SR_LSR = 1, SR_ASR = 2, SR_ROR = 3, SR_RRX = 4 };

/// Shift_C: the value shifted, and the carry out
static inline uint32_t shift_c(uint32_t value, int type, uint32_t amount, uint32_t carry_in, uint32_t *carry_out) {
    if (type == SR_RRX) {
        *carry_out = value & 1;
        return (carry_in << 31) | (value >> 1);
    }
    if (amount == 0) {
        *carry_out = carry_in;
        return value;
    }
    switch (type) {
    case SR_LSL:
        if (amount >= 32) {
            *carry_out = amount == 32 ? value & 1 : 0;
            return 0;
        }
        *carry_out = (value >> (32 - amount)) & 1;
        return value << amount;
    case SR_LSR:
        if (amount >= 32) {
            *carry_out = amount == 32 ? value >> 31 : 0;
            return 0;
        }
        *carry_out = (value >> (amount - 1)) & 1;
        return value >> amount;
    case SR_ASR:
        if (amount >= 32) {
            *carry_out = value >> 31;
            return (uint32_t)((int32_t)value >> 31);
        }
        *carry_out = ((uint32_t)((int32_t)value >> (amount - 1))) & 1;
        return (uint32_t)((int32_t)value >> amount);
    default: {
        uint32_t m = amount & 31;
        uint32_t result = m ? (value >> m) | (value << (32 - m)) : value;
        *carry_out = result >> 31;
        return result;
    }
    }
}

static inline uint32_t shift(uint32_t value, int type, uint32_t amount, uint32_t carry_in) {
    uint32_t carry;
    return shift_c(value, type, amount, carry_in, &carry);
}

/// DecodeImmShift: the type and amount of a shift by an immediate
static inline void decode_imm_shift(uint32_t type, uint32_t imm5, int *shift_type, uint32_t *amount) {
    switch (type) {
    case 0: *shift_type = SR_LSL; *amount = imm5; break;
    case 1: *shift_type = SR_LSR; *amount = imm5 ? imm5 : 32; break;
    case 2: *shift_type = SR_ASR; *amount = imm5 ? imm5 : 32; break;
    default:
        if (imm5 == 0) { *shift_type = SR_RRX; *amount = 1; }
        else { *shift_type = SR_ROR; *amount = imm5; }
    }
}

/// ThumbExpandImm_C
static inline uint32_t expand_imm_c(uint32_t imm12, uint32_t carry_in, uint32_t *carry_out) {
    if ((imm12 >> 10) == 0) {
        uint32_t imm8 = imm12 & 0xFF;
        *carry_out = carry_in;
        switch ((imm12 >> 8) & 3) {
        case 0: return imm8;
        case 1: return (imm8 << 16) | imm8;
        case 2: return (imm8 << 24) | (imm8 << 8);
        default: return imm8 * 0x01010101u;
        }
    }
    uint32_t unrotated = 0x80 | (imm12 & 0x7F);
    uint32_t amount = imm12 >> 7;
    uint32_t result = (unrotated >> amount) | (unrotated << (32 - amount));
    *carry_out = result >> 31;
    return result;
}

/// AddWithCarry
static inline uint32_t add_with_carry(uint32_t x, uint32_t y, uint32_t carry_in, uint32_t *carry_out, uint32_t *overflow) {
    uint64_t unsigned_sum = (uint64_t)x + y + carry_in;
    int64_t signed_sum = (int64_t)(int32_t)x + (int32_t)y + carry_in;
    uint32_t result = (uint32_t)unsigned_sum;
    *carry_out = (uint32_t)(unsigned_sum >> 32) & 1;
    *overflow = (int64_t)(int32_t)result != signed_sum;
    return result;
}

static inline int32_t signed_sat(int64_t value, int bits, bool *saturated) {
    int64_t max = ((int64_t)1 << (bits - 1)) - 1, min = -((int64_t)1 << (bits - 1));
    if (value > max) { *saturated = true; return (int32_t)max; }
    if (value < min) { *saturated = true; return (int32_t)min; }
    return (int32_t)value;
}

static inline uint32_t unsigned_sat(int64_t value, int bits, bool *saturated) {
    int64_t max = ((int64_t)1 << bits) - 1;
    if (value > max) { *saturated = true; return (uint32_t)max; }
    if (value < 0) { *saturated = true; return 0; }
    return (uint32_t)value;
}

static inline bool condition_passed(CM4 *c, uint32_t cond) {
    bool result;
    switch (cond >> 1) {
    case 0: result = c->z; break;
    case 1: result = c->c; break;
    case 2: result = c->n; break;
    case 3: result = c->v; break;
    case 4: result = c->c && !c->z; break;
    case 5: result = c->n == c->v; break;
    case 6: result = c->n == c->v && !c->z; break;
    default: return true;
    }
    return (cond & 1) ? !result : result;
}

static inline void set_nz(CM4 *c, uint32_t result) {
    c->n = result >> 31;
    c->z = result == 0;
}

static inline bool in_it_block(const CM4 *c) { return (c->it & 0xF) != 0; }

// --------------------------------------------------------------------------------------------- the PC and the stack

static void exception_return(CM4 *c, uint32_t exc_return);
static void usage_fault(CM4 *c, uint32_t why);

/// BranchWritePC: an ADD or MOV to the PC, a B
static inline void branch_write_pc(CM4 *c, uint32_t address) {
    c->next_pc = address & ~1u;
    c->cost += 2;
}

/// BXWritePC (and LoadWritePC): interworking, and exception return from Handler mode
static inline void bx_write_pc(CM4 *c, uint32_t address) {
    if (c->ipsr != 0 && (address >> 28) == 0xF) {
        exception_return(c, address);
        return;
    }
    if (!(address & 1)) {
        // EPSR.T cleared: the next instruction faults
        c->next_pc = address & ~1u;
        usage_fault(c, UFSR_INVSTATE);
        return;
    }
    c->next_pc = address & ~1u;
    c->cost += 2;
}

static inline uint32_t xpsr(const CM4 *c) {
    uint32_t it = c->it;
    return (c->n << 31) | (c->z << 30) | (c->c << 29) | (c->v << 28) | (c->q << 27) | ((it & 3) << 25) | (1u << 24) |
           (c->ge << 16) | (((it >> 2) & 0x3F) << 10) | c->ipsr;
}

static inline void set_apsr(CM4 *c, uint32_t value) {
    c->n = value >> 31;
    c->z = (value >> 30) & 1;
    c->c = (value >> 29) & 1;
    c->v = (value >> 28) & 1;
    c->q = (value >> 27) & 1;
}

/// The stack pointers: the one in use is R13
static inline uint32_t msp(const CM4 *c) {
    bool process = c->ipsr == 0 && (c->control & CONTROL_SPSEL);
    return process ? c->other_sp : c->r[13];
}

static inline uint32_t psp(const CM4 *c) {
    bool process = c->ipsr == 0 && (c->control & CONTROL_SPSEL);
    return process ? c->r[13] : c->other_sp;
}

/// Switches which stack pointer R13 is: after a change of mode or of CONTROL.SPSEL
static void select_sp(CM4 *c, bool was_process, bool process) {
    if (was_process == process) return;
    uint32_t t = c->r[13];
    c->r[13] = c->other_sp;
    c->other_sp = t;
}

static inline bool using_psp(const CM4 *c) { return c->ipsr == 0 && (c->control & CONTROL_SPSEL); }

// --------------------------------------------------------------------------------------------------- exceptions

static inline uint32_t group_priority(const CM4 *c, int priority) {
    if (priority < 0) return (uint32_t)priority;
    uint32_t subgroup_mask = (2u << c->prigroup) - 1;
    return (uint32_t)priority & ~subgroup_mask;
}

static inline int exception_priority(const CM4 *c, int number) {
    if (number == EXC_RESET) return -3;
    if (number == EXC_NMI) return -2;
    if (number == EXC_HARDFAULT) return -1;
    return c->priority[number];
}

/// The priority the core runs at: its active exceptions' and the masks'
static int execution_priority(const CM4 *c) {
    int highest = 256;
    for (int i = 1; i < 16 + c->interrupts; i++) {
        if (!c->active[i]) continue;
        int p = exception_priority(c, i);
        int g = p < 0 ? p : (int)group_priority(c, p);
        if (g < highest) highest = g;
    }
    int boosted = 256;
    if (c->basepri & c->priority_mask) boosted = (int)group_priority(c, (int)(c->basepri & c->priority_mask));
    if (c->primask & 1) boosted = 0;
    if (c->faultmask & 1) boosted = -1;
    return boosted < highest ? boosted : highest;
}

/// The pending exception that would be taken next, and whether it preempts what runs now (0: none)
static int pending_exception(const CM4 *c, bool *preempts) {
    int best = 0, best_priority = 1 << 16;
    for (int i = 1; i < 16 + c->interrupts; i++) {
        if (!c->pending[i]) continue;
        if (i >= EXC_IRQ0 && !c->enabled[i]) continue;
        int p = exception_priority(c, i);
        if (p < best_priority) {
            best_priority = p;
            best = i;
        }
    }
    if (best) {
        int g = best_priority < 0 ? best_priority : (int)group_priority(c, best_priority);
        *preempts = g < execution_priority(c);
    } else {
        *preempts = false;
    }
    return best;
}

static void push_frame(CM4 *c, uint32_t return_address) {
    bool fp = (c->control & CONTROL_FPCA) != 0;
    uint32_t frame_size = fp ? 0x68 : 0x20;
    bool force_align = (c->ccr >> 9) & 1;
    uint32_t sp = c->r[13];
    uint32_t align = ((sp >> 2) & 1) & force_align;
    uint32_t frame = (sp - frame_size) & ~(force_align << 2);
    uint32_t psr = xpsr(c) | (align << 9);
    write32(c, frame, c->r[0]);
    write32(c, frame + 4, c->r[1]);
    write32(c, frame + 8, c->r[2]);
    write32(c, frame + 12, c->r[3]);
    write32(c, frame + 16, c->r[12]);
    write32(c, frame + 20, c->r[14]);
    write32(c, frame + 24, return_address);
    write32(c, frame + 28, psr);
    if (fp) {
        // (stacked at once, as with lazy stacking off: the same frame, the same values)
        for (int i = 0; i < 16; i++) write32(c, frame + 0x20 + 4 * i, c->s[i]);
        write32(c, frame + 0x60, c->fpscr);
    }
    c->r[13] = frame;
    uint32_t mode = c->ipsr != 0 ? 0x1 : (c->control & CONTROL_SPSEL) ? 0xD : 0x9;
    c->r[14] = 0xFFFFFFE0u | (fp ? 0 : 0x10) | mode;
}

/// ExceptionEntry: the frame on the stack in use, then the handler
static void exception_entry(CM4 *c, int number, uint32_t return_address) {
    push_frame(c, return_address);
    bool was_process = using_psp(c);
    c->ipsr = (uint32_t)number;
    c->control &= ~(uint32_t)(CONTROL_FPCA | CONTROL_SPSEL);
    select_sp(c, was_process, false);
    c->it = 0;
    c->it_changed = true;
    c->pending[number] = false;
    c->active[number] = true;
    c->exclusive = false;
    c->event = true;
    uint32_t vector = read32(c, (c->vtor & ~0x7Fu) + 4u * (uint32_t)number);
    c->next_pc = vector & ~1u;
    c->r[15] = c->next_pc;
    c->cost += 12;
    c->check_exceptions = true;
}

static int active_count(const CM4 *c) {
    int n = 0;
    for (int i = 1; i < 16 + c->interrupts; i++) n += c->active[i];
    return n;
}

static void exception_return(CM4 *c, uint32_t exc_return) {
    int returning = (int)c->ipsr;
    uint32_t mode = exc_return & 0xF;
    if (mode != 0x1 && mode != 0x9 && mode != 0xD) {
        usage_fault(c, UFSR_INVPC);
        return;
    }
    c->active[returning] = false;
    if (returning >= EXC_IRQ0 && c->level[returning]) c->pending[returning] = true;
    if (returning == EXC_NMI || returning == EXC_HARDFAULT) c->faultmask = 0;
    c->it_changed = true;
    bool to_process = mode == 0xD;
    // the frame is on the stack the return names
    uint32_t frame = to_process ? c->other_sp : c->r[13];
    bool fp = !(exc_return & 0x10);
    uint32_t frame_size = fp ? 0x68 : 0x20;
    c->r[0] = read32(c, frame);
    c->r[1] = read32(c, frame + 4);
    c->r[2] = read32(c, frame + 8);
    c->r[3] = read32(c, frame + 12);
    c->r[12] = read32(c, frame + 16);
    c->r[14] = read32(c, frame + 20);
    uint32_t pc = read32(c, frame + 24);
    uint32_t psr = read32(c, frame + 28);
    if (fp) {
        for (int i = 0; i < 16; i++) c->s[i] = read32(c, frame + 0x20 + 4 * i);
        c->fpscr = read32(c, frame + 0x60) & FPSCR_WRITABLE;
        c->control |= CONTROL_FPCA;
    } else {
        c->control &= ~(uint32_t)CONTROL_FPCA;
    }
    bool force_align = (c->ccr >> 9) & 1;
    uint32_t sp = (frame + frame_size) | ((((psr >> 9) & 1) & force_align) << 2);
    // back to the mode and stack the return names
    if (to_process) {
        // R13 was MSP (Handler mode): it becomes PSP
        c->other_sp = c->r[13];
        c->r[13] = sp;
        c->control |= CONTROL_SPSEL;
    } else {
        c->r[13] = sp;
        c->control &= ~(uint32_t)CONTROL_SPSEL;
    }
    set_apsr(c, psr);
    c->ge = (psr >> 16) & 0xF;
    c->ipsr = mode == 0x1 ? (psr & 0x1FF) : 0;
    c->it = ((psr >> 25) & 3) | (((psr >> 10) & 0x3F) << 2);
    c->next_pc = pc & ~1u;
    c->exclusive = false;
    c->cost += 10;
    c->check_exceptions = true;
    if (c->ipsr == 0 && (c->scr & 2) && active_count(c) == 0) c->sleeping = true;
}

/// A fault, escalated to HardFault where its own handler is off or cannot run; a fault in HardFault locks up
static void raise_fault(CM4 *c, int number, uint32_t status) {
    c->cfsr |= status;
    uint32_t enable_bit = number == EXC_MEMMANAGE ? 1u << 16 : number == EXC_BUSFAULT ? 1u << 17 : 1u << 18;
    bool enabled = (c->shcsr & enable_bit) != 0;
    int priority = exception_priority(c, number);
    if (!enabled || (priority < 256 && (int)group_priority(c, priority) >= execution_priority(c))) {
        if (c->ipsr == EXC_HARDFAULT || c->ipsr == EXC_NMI || execution_priority(c) < 0) {
            c->locked_up = true;
            return;
        }
        c->hfsr |= 1u << 30;  // FORCED
        number = EXC_HARDFAULT;
    }
    // taken at once, in place of the faulting instruction: its address is the return address
    c->pending[number] = true;
    exception_entry(c, number, c->pc);
}

static void usage_fault(CM4 *c, uint32_t why) { raise_fault(c, EXC_USAGEFAULT, why); }

static void undefined(CM4 *c) { usage_fault(c, UFSR_UNDEFINSTR); }

// ------------------------------------------------------------------------------------------------------- SysTick

static inline uint64_t systick_period(const CM4 *c) {
    // CLKSOURCE 1: the core clock; 0: the external reference, HCLK / 8 on an STM32
    return (c->systick_ctrl & 4) ? 1 : 8;
}

static void systick_schedule(CM4 *c) {
    if (!(c->systick_ctrl & 1)) {
        c->systick_wrap = UINT64_MAX;
        return;
    }
    // reaching 0 from `systick_value` (a value of 0 reloads at the next count)
    uint64_t ticks = c->systick_value ? c->systick_value : (uint64_t)(c->systick_load & 0xFFFFFF) + 1;
    if (c->systick_value == 0 && (c->systick_load & 0xFFFFFF) == 0) {
        c->systick_wrap = UINT64_MAX;
        return;
    }
    c->systick_wrap = c->systick_cycle + ticks * systick_period(c);
}

/// SysTick brought up to the present cycle: each time it reaches 0 it sets COUNTFLAG and, with TICKINT, pends
static void systick_update(CM4 *c) {
    while (c->cycles >= c->systick_wrap) {
        c->systick_cycle = c->systick_wrap;
        c->systick_value = 0;
        c->systick_ctrl |= 1u << 16;
        if (c->systick_ctrl & 2) {
            c->pending[EXC_SYSTICK] = true;
            c->check_exceptions = true;
        }
        // reloads on the next tick
        uint32_t load = c->systick_load & 0xFFFFFF;
        if (load == 0) {
            c->systick_wrap = UINT64_MAX;
            break;
        }
        c->systick_cycle += systick_period(c);
        c->systick_value = load;
        c->systick_wrap = c->systick_cycle + (uint64_t)load * systick_period(c);
    }
}

static uint32_t systick_current(CM4 *c) {
    systick_update(c);
    if (!(c->systick_ctrl & 1)) return c->systick_value;
    uint64_t elapsed = (c->cycles - c->systick_cycle) / systick_period(c);
    if (c->systick_value == 0) return 0;
    return c->systick_value - (uint32_t)elapsed;
}

// --------------------------------------------------------------------------------------- the system control space

static uint32_t icsr(CM4 *c) {
    bool preempts;
    int next = pending_exception(c, &preempts);
    bool any_pending_irq = false;
    for (int i = EXC_IRQ0; i < 16 + c->interrupts; i++) if (c->pending[i]) { any_pending_irq = true; break; }
    uint32_t value = c->ipsr & 0x1FF;
    if (active_count(c) <= 1) value |= 1u << 11;  // RETTOBASE
    value |= (uint32_t)(next & 0x1FF) << 12;
    if (any_pending_irq) value |= 1u << 22;
    if (c->pending[EXC_PENDSV]) value |= 1u << 28;
    if (c->pending[EXC_SYSTICK]) value |= 1u << 26;
    if (c->pending[EXC_NMI]) value |= 1u << 31;
    return value;
}

static uint32_t system_read_word(CM4 *c, uint32_t address) {
    if (address >= 0xE000E100u && address < 0xE000E120u) {
        uint32_t base = EXC_IRQ0 + (address - 0xE000E100u) * 8, v = 0;
        for (int i = 0; i < 32; i++) if (base + i < MAX_EXCEPTIONS && c->enabled[base + i]) v |= 1u << i;
        return v;
    }
    if (address >= 0xE000E180u && address < 0xE000E1A0u) return system_read_word(c, address - 0x80);
    if (address >= 0xE000E200u && address < 0xE000E220u) {
        uint32_t base = EXC_IRQ0 + (address - 0xE000E200u) * 8, v = 0;
        for (int i = 0; i < 32; i++) if (base + i < MAX_EXCEPTIONS && c->pending[base + i]) v |= 1u << i;
        return v;
    }
    if (address >= 0xE000E280u && address < 0xE000E2A0u) return system_read_word(c, address - 0x80);
    if (address >= 0xE000E300u && address < 0xE000E320u) {
        uint32_t base = EXC_IRQ0 + (address - 0xE000E300u) * 8, v = 0;
        for (int i = 0; i < 32; i++) if (base + i < MAX_EXCEPTIONS && c->active[base + i]) v |= 1u << i;
        return v;
    }
    if (address >= 0xE000E400u && address < 0xE000E4F0u) {
        uint32_t base = EXC_IRQ0 + (address - 0xE000E400u), v = 0;
        for (int i = 0; i < 4; i++) if (base + i < MAX_EXCEPTIONS) v |= (uint32_t)c->priority[base + i] << (8 * i);
        return v;
    }
    switch (address) {
    case 0xE000E004: return (uint32_t)((c->interrupts + 31) / 32) - 1;  // ICTR
    case 0xE000E010: {
        systick_update(c);
        uint32_t v = c->systick_ctrl;
        c->systick_ctrl &= ~(1u << 16);  // COUNTFLAG clears on reading
        return v;
    }
    case 0xE000E014: return c->systick_load;
    case 0xE000E018: return systick_current(c);
    case 0xE000E01C: return c->systick_calib;
    case 0xE000ED00: return 0x410FC241;  // CPUID: Cortex-M4 r0p1
    case 0xE000ED04: return icsr(c);
    case 0xE000ED08: return c->vtor;
    case 0xE000ED0C: return 0xFA050000u | (c->prigroup << 8);
    case 0xE000ED10: return c->scr;
    case 0xE000ED14: return c->ccr;
    case 0xE000ED18: case 0xE000ED1C: case 0xE000ED20: {
        uint32_t base = 4 + (address - 0xE000ED18u), v = 0;
        for (int i = 0; i < 4; i++) v |= (uint32_t)c->priority[base + i] << (8 * i);
        return v;
    }
    case 0xE000ED24: {
        uint32_t v = c->shcsr & 0x70000;
        if (c->active[EXC_MEMMANAGE]) v |= 1;
        if (c->active[EXC_BUSFAULT]) v |= 2;
        if (c->active[EXC_USAGEFAULT]) v |= 8;
        if (c->active[EXC_SVCALL]) v |= 1 << 7;
        if (c->active[EXC_DEBUGMONITOR]) v |= 1 << 8;
        if (c->active[EXC_PENDSV]) v |= 1 << 10;
        if (c->active[EXC_SYSTICK]) v |= 1 << 11;
        if (c->pending[EXC_USAGEFAULT]) v |= 1 << 12;
        if (c->pending[EXC_MEMMANAGE]) v |= 1 << 13;
        if (c->pending[EXC_BUSFAULT]) v |= 1 << 14;
        if (c->pending[EXC_SVCALL]) v |= 1 << 15;
        return v;
    }
    case 0xE000ED28: return c->cfsr;
    case 0xE000ED2C: return c->hfsr;
    case 0xE000ED34: return c->mmfar;
    case 0xE000ED38: return c->bfar;
    case 0xE000ED88: return c->cpacr;
    case 0xE000EF34: return c->fpccr;
    case 0xE000EF38: return c->fpcar;
    case 0xE000EF3C: return c->fpdscr;
    case 0xE000EF40: return 0x10110021;  // MVFR0: single precision, square root, divide
    case 0xE000EF44: return 0x11000011;  // MVFR1: FTZ, default NaN, half precision, FMA
    case 0xE0001000: return c->dwt_ctrl;
    case 0xE0001004: return (c->dwt_ctrl & 1) ? (uint32_t)(c->cycles - c->cyccnt_base) : (uint32_t)c->cyccnt_base;
    case 0xE000EDFC: return c->demcr;
    default: return 0;
    }
}

static uint32_t system_read(CM4 *c, uint32_t address, uint32_t size) {
    uint32_t aligned = address & ~3u;
    uint32_t word = system_read_word(c, aligned);
    return (word >> (8 * (address & 3))) & (size == 4 ? 0xFFFFFFFFu : size == 2 ? 0xFFFFu : 0xFFu);
}

static void set_priority(CM4 *c, int number, uint32_t value) {
    if (number >= 0 && number < MAX_EXCEPTIONS) c->priority[number] = (uint8_t)(value & c->priority_mask);
}

static void system_write_word(CM4 *c, uint32_t address, uint32_t value) {
    if (address >= 0xE000E100u && address < 0xE000E120u) {
        uint32_t base = EXC_IRQ0 + (address - 0xE000E100u) * 8;
        for (int i = 0; i < 32; i++) if ((value >> i) & 1 && base + i < MAX_EXCEPTIONS) c->enabled[base + i] = true;
        c->check_exceptions = true;
        return;
    }
    if (address >= 0xE000E180u && address < 0xE000E1A0u) {
        uint32_t base = EXC_IRQ0 + (address - 0xE000E180u) * 8;
        for (int i = 0; i < 32; i++) if ((value >> i) & 1 && base + i < MAX_EXCEPTIONS) c->enabled[base + i] = false;
        return;
    }
    if (address >= 0xE000E200u && address < 0xE000E220u) {
        uint32_t base = EXC_IRQ0 + (address - 0xE000E200u) * 8;
        for (int i = 0; i < 32; i++) if ((value >> i) & 1 && base + i < MAX_EXCEPTIONS) c->pending[base + i] = true;
        c->check_exceptions = true;
        return;
    }
    if (address >= 0xE000E280u && address < 0xE000E2A0u) {
        uint32_t base = EXC_IRQ0 + (address - 0xE000E280u) * 8;
        for (int i = 0; i < 32; i++) {
            // a line still high stays pending
            if ((value >> i) & 1 && base + i < MAX_EXCEPTIONS) c->pending[base + i] = c->level[base + i];
        }
        return;
    }
    switch (address) {
    case 0xE000E010:
        systick_update(c);
        if ((value & 1) && !(c->systick_ctrl & 1)) c->systick_cycle = c->cycles;
        else if (!(value & 1) && (c->systick_ctrl & 1)) {
            c->systick_value = systick_current(c);
            c->systick_cycle = c->cycles;
        }
        c->systick_ctrl = (c->systick_ctrl & (1u << 16)) | (value & 7);
        systick_schedule(c);
        return;
    case 0xE000E014: c->systick_load = value & 0xFFFFFF; return;
    case 0xE000E018:
        // any write clears the counter and COUNTFLAG; it reloads at the next tick
        c->systick_value = 0;
        c->systick_cycle = c->cycles;
        c->systick_ctrl &= ~(1u << 16);
        systick_schedule(c);
        return;
    case 0xE000ED04:
        if (value & (1u << 31)) c->pending[EXC_NMI] = true;
        if (value & (1u << 28)) c->pending[EXC_PENDSV] = true;
        if (value & (1u << 27)) c->pending[EXC_PENDSV] = false;
        if (value & (1u << 26)) c->pending[EXC_SYSTICK] = true;
        if (value & (1u << 25)) c->pending[EXC_SYSTICK] = false;
        c->check_exceptions = true;
        return;
    case 0xE000ED08: c->vtor = value & 0xFFFFFF80u; return;
    case 0xE000ED0C:
        if ((value >> 16) == 0x05FA) {
            c->prigroup = (value >> 8) & 7;
            if (value & 4) cm4_reset(c);  // SYSRESETREQ
        }
        return;
    case 0xE000ED10: c->scr = value & 0x16; return;
    case 0xE000ED14: c->ccr = (value & 0x31B) | 0x200; return;
    case 0xE000ED24: c->shcsr = value & 0x70000; return;
    case 0xE000ED28: c->cfsr &= ~value; return;
    case 0xE000ED2C: c->hfsr &= ~value; return;
    case 0xE000ED88: c->cpacr = value & (0xFu << 20); return;
    case 0xE000EF34: c->fpccr = (c->fpccr & 0x1FF) | (value & 0xC0000000u); return;
    case 0xE000EF38: c->fpcar = value & ~7u; return;
    case 0xE000EF3C: c->fpdscr = value & 0x07C00000u; return;
    case 0xE000EF00: {
        int line = (int)(value & 0x1FF);
        if (line < c->interrupts) c->pending[EXC_IRQ0 + line] = true;
        c->check_exceptions = true;
        return;
    }
    case 0xE0001000:
        if ((value & 1) && !(c->dwt_ctrl & 1)) c->cyccnt_base = c->cycles - c->cyccnt_base;
        else if (!(value & 1) && (c->dwt_ctrl & 1)) c->cyccnt_base = c->cycles - c->cyccnt_base;
        c->dwt_ctrl = (c->dwt_ctrl & ~1u) | (value & 1);
        return;
    case 0xE0001004:
        c->cyccnt_base = (c->dwt_ctrl & 1) ? c->cycles - value : value;
        return;
    case 0xE000EDFC: c->demcr = value; return;
    default: return;
    }
}

static void system_write(CM4 *c, uint32_t address, uint32_t value, uint32_t size) {
    // priorities are byte registers; everything else is written as words
    if (size != 4 && ((address >= 0xE000E400u && address < 0xE000E4F0u) || (address >= 0xE000ED18u && address < 0xE000ED24u))) {
        for (uint32_t i = 0; i < size; i++) {
            uint32_t a = address + i;
            uint32_t byte = (value >> (8 * i)) & 0xFF;
            if (a >= 0xE000E400u && a < 0xE000E4F0u) set_priority(c, EXC_IRQ0 + (int)(a - 0xE000E400u), byte);
            else if (a >= 0xE000ED18u && a < 0xE000ED24u) set_priority(c, 4 + (int)(a - 0xE000ED18u), byte);
        }
        c->check_exceptions = true;
        return;
    }
    if (address >= 0xE000E400u && address < 0xE000E4F0u) {
        for (int i = 0; i < 4; i++) set_priority(c, EXC_IRQ0 + (int)(address - 0xE000E400u) + i, (value >> (8 * i)) & 0xFF);
        c->check_exceptions = true;
        return;
    }
    if (address >= 0xE000ED18u && address < 0xE000ED24u) {
        for (int i = 0; i < 4; i++) set_priority(c, 4 + (int)(address - 0xE000ED18u) + i, (value >> (8 * i)) & 0xFF);
        c->check_exceptions = true;
        return;
    }
    system_write_word(c, address & ~3u, value);
}

// ------------------------------------------------------------------------------------------------ 16-bit Thumb

/// A register as an operand: the PC reads as the instruction's address plus 4
static inline uint32_t reg(const CM4 *c, uint32_t n) { return n == 15 ? c->pc + 4 : c->r[n]; }

static inline uint32_t align4(uint32_t a) { return a & ~3u; }

static inline void set_logical_flags(CM4 *c, uint32_t result, uint32_t carry) {
    set_nz(c, result);
    c->c = carry;
}

static inline void set_arith_flags(CM4 *c, uint32_t result, uint32_t carry, uint32_t overflow) {
    set_nz(c, result);
    c->c = carry;
    c->v = overflow;
}

static void exec_push_pop(CM4 *c, uint32_t list, bool pop) {
    int count = __builtin_popcount(list);
    if (pop) {
        uint32_t address = c->r[13];
        c->r[13] = address + 4u * (uint32_t)count;
        uint32_t loaded_pc = 0;
        bool has_pc = false;
        for (int i = 0; i < 16; i++) {
            if (!((list >> i) & 1)) continue;
            uint32_t value = read32(c, address);
            address += 4;
            if (i == 15) { loaded_pc = value; has_pc = true; }
            else if (i != 13) c->r[i] = value;
        }
        c->cost += count;
        if (has_pc) bx_write_pc(c, loaded_pc);
    } else {
        uint32_t address = c->r[13] - 4u * (uint32_t)count;
        c->r[13] = address;
        for (int i = 0; i < 16; i++) {
            if (!((list >> i) & 1)) continue;
            write32(c, address, reg(c, (uint32_t)i));
            address += 4;
        }
        c->cost += count;
    }
}

/// LDM / STM increment after (and decrement before) with an optional writeback; returns false where undefined
static void exec_ldm_stm(CM4 *c, uint32_t rn, uint32_t list, bool load, bool writeback, bool decrement) {
    int count = __builtin_popcount(list);
    uint32_t base = c->r[rn];
    uint32_t address = decrement ? base - 4u * (uint32_t)count : base;
    uint32_t final = decrement ? base - 4u * (uint32_t)count : base + 4u * (uint32_t)count;
    if (load) {
        uint32_t loaded_pc = 0;
        bool has_pc = false;
        for (int i = 0; i < 16; i++) {
            if (!((list >> i) & 1)) continue;
            uint32_t value = read32(c, address);
            address += 4;
            if (i == 15) { loaded_pc = value; has_pc = true; }
            else c->r[i] = value;
        }
        if (writeback && !((list >> rn) & 1)) c->r[rn] = final;
        c->cost += count;
        if (has_pc) bx_write_pc(c, loaded_pc);
    } else {
        for (int i = 0; i < 16; i++) {
            if (!((list >> i) & 1)) continue;
            write32(c, address, reg(c, (uint32_t)i));
            address += 4;
        }
        if (writeback) c->r[rn] = final;
        c->cost += count;
    }
}

static void exec16(CM4 *c, uint32_t op) {
    bool setflags = !in_it_block(c);
    uint32_t carry, overflow, result;
    switch (op >> 12) {
    case 0x0: case 0x1: {
        uint32_t rd = op & 7, rm = (op >> 3) & 7;
        uint32_t kind = (op >> 11) & 3;
        if (kind != 3) {
            // LSL, LSR, ASR (immediate); LSL #0 is MOVS
            int type;
            uint32_t amount;
            decode_imm_shift(kind, (op >> 6) & 0x1F, &type, &amount);
            result = shift_c(c->r[rm], type, amount, c->c, &carry);
            c->r[rd] = result;
            if (setflags) set_logical_flags(c, result, carry);
        } else {
            uint32_t rn = (op >> 3) & 7;
            uint32_t operand = (op & 0x400) ? (op >> 6) & 7 : c->r[(op >> 6) & 7];
            if (op & 0x200) result = add_with_carry(c->r[rn], ~operand, 1, &carry, &overflow);
            else result = add_with_carry(c->r[rn], operand, 0, &carry, &overflow);
            c->r[rd] = result;
            if (setflags) set_arith_flags(c, result, carry, overflow);
        }
        return;
    }
    case 0x2: case 0x3: {
        uint32_t rdn = (op >> 8) & 7, imm = op & 0xFF;
        switch ((op >> 11) & 3) {
        case 0:  // MOV
            c->r[rdn] = imm;
            if (setflags) set_nz(c, imm);
            break;
        case 1:  // CMP
            result = add_with_carry(c->r[rdn], ~imm, 1, &carry, &overflow);
            set_arith_flags(c, result, carry, overflow);
            break;
        case 2:  // ADD
            result = add_with_carry(c->r[rdn], imm, 0, &carry, &overflow);
            c->r[rdn] = result;
            if (setflags) set_arith_flags(c, result, carry, overflow);
            break;
        default:  // SUB
            result = add_with_carry(c->r[rdn], ~imm, 1, &carry, &overflow);
            c->r[rdn] = result;
            if (setflags) set_arith_flags(c, result, carry, overflow);
        }
        return;
    }
    case 0x4: {
        if ((op & 0xFC00) == 0x4000) {
            // data processing
            uint32_t rdn = op & 7, rm = (op >> 3) & 7;
            uint32_t a = c->r[rdn], b = c->r[rm];
            switch ((op >> 6) & 0xF) {
            case 0x0: result = a & b; c->r[rdn] = result; if (setflags) set_nz(c, result); break;
            case 0x1: result = a ^ b; c->r[rdn] = result; if (setflags) set_nz(c, result); break;
            case 0x2: case 0x3: case 0x4: case 0x7: {
                static const int types[8] = {0, 0, SR_LSL, SR_LSR, SR_ASR, 0, 0, SR_ROR};
                result = shift_c(a, types[(op >> 6) & 7], b & 0xFF, c->c, &carry);
                c->r[rdn] = result;
                if (setflags) set_logical_flags(c, result, carry);
                break;
            }
            case 0x5:
                result = add_with_carry(a, b, c->c, &carry, &overflow);
                c->r[rdn] = result;
                if (setflags) set_arith_flags(c, result, carry, overflow);
                break;
            case 0x6:
                result = add_with_carry(a, ~b, c->c, &carry, &overflow);
                c->r[rdn] = result;
                if (setflags) set_arith_flags(c, result, carry, overflow);
                break;
            case 0x8: set_nz(c, a & b); break;
            case 0x9:  // RSB #0
                result = add_with_carry(~b, 0, 1, &carry, &overflow);
                c->r[rdn] = result;
                if (setflags) set_arith_flags(c, result, carry, overflow);
                break;
            case 0xA:
                result = add_with_carry(a, ~b, 1, &carry, &overflow);
                set_arith_flags(c, result, carry, overflow);
                break;
            case 0xB:
                result = add_with_carry(a, b, 0, &carry, &overflow);
                set_arith_flags(c, result, carry, overflow);
                break;
            case 0xC: result = a | b; c->r[rdn] = result; if (setflags) set_nz(c, result); break;
            case 0xD: result = a * b; c->r[rdn] = result; if (setflags) set_nz(c, result); break;
            case 0xE: result = a & ~b; c->r[rdn] = result; if (setflags) set_nz(c, result); break;
            default: result = ~b; c->r[rdn] = result; if (setflags) set_nz(c, result); break;
            }
            return;
        }
        if ((op & 0xFC00) == 0x4400) {
            // special data processing and branch exchange
            uint32_t rm = (op >> 3) & 0xF;
            uint32_t rdn = (op & 7) | ((op >> 4) & 8);
            switch ((op >> 8) & 3) {
            case 0:  // ADD (register)
                result = reg(c, rdn) + reg(c, rm);
                if (rdn == 15) branch_write_pc(c, result);
                else c->r[rdn] = result;
                break;
            case 1:  // CMP (register)
                result = add_with_carry(reg(c, rdn), ~reg(c, rm), 1, &carry, &overflow);
                set_arith_flags(c, result, carry, overflow);
                break;
            case 2:  // MOV (register)
                if (rdn == 15) branch_write_pc(c, reg(c, rm));
                else c->r[rdn] = reg(c, rm);
                break;
            default: {
                uint32_t target = reg(c, rm);
                if (op & 0x80) c->r[14] = (c->pc + 2) | 1;  // BLX
                bx_write_pc(c, target);
            }
            }
            return;
        }
        // LDR (literal)
        uint32_t rt = (op >> 8) & 7;
        c->r[rt] = read32(c, align4(c->pc + 4) + (op & 0xFF) * 4);
        c->cost += 1;
        return;
    }
    case 0x5: {
        uint32_t rt = op & 7, rn = (op >> 3) & 7, rm = (op >> 6) & 7;
        uint32_t address = c->r[rn] + c->r[rm];
        switch ((op >> 9) & 7) {
        case 0: write32(c, address, c->r[rt]); break;
        case 1: write16(c, address, c->r[rt]); break;
        case 2: write8(c, address, c->r[rt]); break;
        case 3: c->r[rt] = (uint32_t)(int8_t)read8(c, address); break;
        case 4: c->r[rt] = read32(c, address); break;
        case 5: c->r[rt] = read16(c, address); break;
        case 6: c->r[rt] = read8(c, address); break;
        default: c->r[rt] = (uint32_t)(int16_t)read16(c, address); break;
        }
        c->cost += 1;
        return;
    }
    case 0x6: case 0x7: {
        uint32_t rt = op & 7, rn = (op >> 3) & 7, imm5 = (op >> 6) & 0x1F;
        bool byte = (op >> 12) & 1, load = (op >> 11) & 1;
        uint32_t address = c->r[rn] + (byte ? imm5 : imm5 * 4);
        if (load) c->r[rt] = byte ? read8(c, address) : read32(c, address);
        else if (byte) write8(c, address, c->r[rt]);
        else write32(c, address, c->r[rt]);
        c->cost += 1;
        return;
    }
    case 0x8: {
        uint32_t rt = op & 7, rn = (op >> 3) & 7;
        uint32_t address = c->r[rn] + ((op >> 6) & 0x1F) * 2;
        if (op & 0x800) c->r[rt] = read16(c, address);
        else write16(c, address, c->r[rt]);
        c->cost += 1;
        return;
    }
    case 0x9: {
        uint32_t rt = (op >> 8) & 7;
        uint32_t address = c->r[13] + (op & 0xFF) * 4;
        if (op & 0x800) c->r[rt] = read32(c, address);
        else write32(c, address, c->r[rt]);
        c->cost += 1;
        return;
    }
    case 0xA: {
        uint32_t rd = (op >> 8) & 7, imm = (op & 0xFF) * 4;
        c->r[rd] = (op & 0x800) ? c->r[13] + imm : align4(c->pc + 4) + imm;
        return;
    }
    case 0xB: {
        if ((op & 0xFF00) == 0xB000) {
            uint32_t imm = (op & 0x7F) * 4;
            c->r[13] = (op & 0x80) ? c->r[13] - imm : c->r[13] + imm;
            return;
        }
        if ((op & 0xF500) == 0xB100) {
            // CBZ, CBNZ
            uint32_t rn = op & 7;
            uint32_t offset = (((op >> 9) & 1) << 6) | (((op >> 3) & 0x1F) << 1);
            bool nonzero = (op >> 11) & 1;
            if ((c->r[rn] != 0) == nonzero) branch_write_pc(c, c->pc + 4 + offset);
            return;
        }
        if ((op & 0xFF00) == 0xB200) {
            uint32_t rd = op & 7, m = c->r[(op >> 3) & 7];
            switch ((op >> 6) & 3) {
            case 0: c->r[rd] = (uint32_t)(int16_t)m; break;
            case 1: c->r[rd] = (uint32_t)(int8_t)m; break;
            case 2: c->r[rd] = m & 0xFFFF; break;
            default: c->r[rd] = m & 0xFF; break;
            }
            return;
        }
        if ((op & 0xFE00) == 0xB400) {
            exec_push_pop(c, (op & 0xFF) | ((op & 0x100) ? 1u << 14 : 0), false);
            return;
        }
        if ((op & 0xFFE8) == 0xB660) {
            // CPSIE / CPSID
            bool disable = (op >> 4) & 1;
            if (op & 2) c->primask = disable;
            if (op & 1) c->faultmask = disable && c->ipsr != EXC_NMI;
            c->check_exceptions = true;
            return;
        }
        if ((op & 0xFF00) == 0xBA00) {
            uint32_t rd = op & 7, m = c->r[(op >> 3) & 7];
            switch ((op >> 6) & 3) {
            case 0: c->r[rd] = __builtin_bswap32(m); return;
            case 1: c->r[rd] = ((m >> 8) & 0x00FF00FFu) | ((m << 8) & 0xFF00FF00u); return;
            case 3: c->r[rd] = (uint32_t)(int16_t)(((m & 0xFF) << 8) | ((m >> 8) & 0xFF)); return;
            default: undefined(c); return;
            }
        }
        if ((op & 0xFE00) == 0xBC00) {
            exec_push_pop(c, (op & 0xFF) | ((op & 0x100) ? 1u << 15 : 0), true);
            return;
        }
        if ((op & 0xFF00) == 0xBE00) {
            c->stop_breakpoint = true;
            c->next_pc = c->pc;
            return;
        }
        if ((op & 0xFF00) == 0xBF00) {
            if (op & 0xF) {
                // IT
                c->it = op & 0xFF;
                c->it_changed = true;
                return;
            }
            switch ((op >> 4) & 0xF) {
            case 2:  // WFE
                if (c->event) c->event = false;
                else { c->sleeping = true; c->waiting_for_event = true; }
                return;
            case 3: c->sleeping = true; return;  // WFI
            case 4: c->event = true; return;     // SEV
            default: return;                     // NOP, YIELD
            }
        }
        undefined(c);
        return;
    }
    case 0xC: {
        uint32_t rn = (op >> 8) & 7, list = op & 0xFF;
        if (op & 0x800) exec_ldm_stm(c, rn, list, true, !((list >> rn) & 1), false);
        else exec_ldm_stm(c, rn, list, false, true, false);
        return;
    }
    case 0xD: {
        uint32_t cond = (op >> 8) & 0xF;
        if (cond == 0xE) { undefined(c); return; }
        if (cond == 0xF) {
            // SVC: taken as the next instruction would be
            c->pending[EXC_SVCALL] = true;
            c->check_exceptions = true;
            return;
        }
        if (condition_passed(c, cond)) branch_write_pc(c, c->pc + 4 + (uint32_t)((int32_t)(int8_t)(op & 0xFF) * 2));
        return;
    }
    default: {
        // B (unconditional)
        int32_t offset = ((int32_t)((op & 0x7FF) << 21)) >> 20;
        branch_write_pc(c, c->pc + 4 + (uint32_t)offset);
        return;
    }
    }
}

// ------------------------------------------------------------------------------------------------ 32-bit Thumb-2

static void exec_fp(CM4 *c, uint32_t hw1, uint32_t hw2);

/// The data-processing operations of the modified-immediate and shifted-register encodings
static void data_processing(CM4 *c, uint32_t op, uint32_t rn, uint32_t rd, uint32_t operand, uint32_t shifter_carry, bool s) {
    uint32_t a = reg(c, rn), result, carry, overflow;
    switch (op) {
    case 0x0: case 0x1: case 0x2: case 0x3: case 0x4:
        switch (op) {
        case 0x0: result = a & operand; break;
        case 0x1: result = a & ~operand; break;
        case 0x2: result = rn == 15 ? operand : a | operand; break;
        case 0x3: result = rn == 15 ? ~operand : a | ~operand; break;
        default: result = a ^ operand; break;
        }
        if (rd != 15) c->r[rd] = result;
        if (s) set_logical_flags(c, result, shifter_carry);
        return;
    case 0x8: result = add_with_carry(a, operand, 0, &carry, &overflow); break;
    case 0xA: result = add_with_carry(a, operand, c->c, &carry, &overflow); break;
    case 0xB: result = add_with_carry(a, ~operand, c->c, &carry, &overflow); break;
    case 0xD: result = add_with_carry(a, ~operand, 1, &carry, &overflow); break;
    case 0xE: result = add_with_carry(~a, operand, 1, &carry, &overflow); break;
    default: undefined(c); return;
    }
    if (rd != 15) c->r[rd] = result;
    if (s) set_arith_flags(c, result, carry, overflow);
}

static void exec_load_store_single(CM4 *c, uint32_t hw1, uint32_t hw2) {
    bool sign = (hw1 >> 8) & 1, imm12_form = (hw1 >> 7) & 1, load = (hw1 >> 4) & 1;
    uint32_t size = (hw1 >> 5) & 3, rn = hw1 & 0xF, rt = hw2 >> 12;
    if (size == 3 || (!load && sign)) { undefined(c); return; }
    uint32_t address, offset_address = 0;
    bool writeback = false;
    if (load && rn == 15) {
        uint32_t base = align4(c->pc + 4), imm = hw2 & 0xFFF;
        address = imm12_form ? base + imm : base - imm;
    } else if (imm12_form) {
        address = c->r[rn] + (hw2 & 0xFFF);
    } else if (hw2 & 0x800) {
        uint32_t imm8 = hw2 & 0xFF;
        bool p = (hw2 >> 10) & 1, u = (hw2 >> 9) & 1, w = (hw2 >> 8) & 1;
        if (!p && !w) { undefined(c); return; }
        offset_address = u ? c->r[rn] + imm8 : c->r[rn] - imm8;
        address = p ? offset_address : c->r[rn];
        writeback = w;
    } else {
        if (hw2 & 0x7C0) { undefined(c); return; }
        address = c->r[rn] + (c->r[hw2 & 0xF] << ((hw2 >> 4) & 3));
    }
    c->cost += 1;
    if (load) {
        uint32_t value;
        switch (size) {
        case 0: value = read8(c, address); if (sign) value = (uint32_t)(int8_t)value; break;
        case 1: value = read16(c, address); if (sign) value = (uint32_t)(int16_t)value; break;
        default: value = read32(c, address); break;
        }
        if (writeback) c->r[rn] = offset_address;
        if (rt == 15) {
            // a word into the PC branches; a byte or halfword "into the PC" is a preload hint
            if (size == 2) bx_write_pc(c, value);
        } else {
            c->r[rt] = value;
        }
    } else {
        uint32_t value = c->r[rt];
        switch (size) {
        case 0: write8(c, address, value); break;
        case 1: write16(c, address, value); break;
        default: write32(c, address, value); break;
        }
        if (writeback) c->r[rn] = offset_address;
    }
}

static void exec_dual_exclusive(CM4 *c, uint32_t hw1, uint32_t hw2) {
    bool p = (hw1 >> 8) & 1, u = (hw1 >> 7) & 1, w = (hw1 >> 5) & 1, load = (hw1 >> 4) & 1;
    uint32_t rn = hw1 & 0xF, rt = hw2 >> 12, rt2 = (hw2 >> 8) & 0xF;
    if (p || w) {
        // LDRD, STRD
        uint32_t imm = (hw2 & 0xFF) << 2;
        uint32_t base = rn == 15 ? align4(c->pc + 4) : c->r[rn];
        uint32_t offset_address = u ? base + imm : base - imm;
        uint32_t address = p ? offset_address : base;
        if (load) {
            uint32_t a = read32(c, address), b = read32(c, address + 4);
            c->r[rt] = a;
            c->r[rt2] = b;
        } else {
            write32(c, address, c->r[rt]);
            write32(c, address + 4, c->r[rt2]);
        }
        if (w) c->r[rn] = offset_address;
        c->cost += 2;
        return;
    }
    if (!u) {
        uint32_t address = c->r[rn] + ((hw2 & 0xFF) << 2);
        if (load) {
            c->r[rt] = read32(c, address);
            c->exclusive = true;
            c->exclusive_address = address;
        } else {
            uint32_t rd = (hw2 >> 8) & 0xF;
            if (c->exclusive && c->exclusive_address == address) {
                write32(c, address, c->r[rt]);
                c->r[rd] = 0;
            } else {
                c->r[rd] = 1;
            }
            c->exclusive = false;
        }
        c->cost += 1;
        return;
    }
    uint32_t op3 = (hw2 >> 4) & 0xF;
    if (load) {
        switch (op3) {
        case 0: case 1: {
            // TBB, TBH
            uint32_t base = reg(c, rn), index = c->r[hw2 & 0xF];
            uint32_t half = op3 ? read16(c, base + index * 2) : read8(c, base + index);
            branch_write_pc(c, c->pc + 4 + 2 * half);
            c->cost += 1;
            return;
        }
        case 4: case 5: {
            uint32_t address = c->r[rn];
            c->r[rt] = op3 == 4 ? read8(c, address) : read16(c, address);
            c->exclusive = true;
            c->exclusive_address = address;
            c->cost += 1;
            return;
        }
        default: undefined(c); return;
        }
    }
    if (op3 == 4 || op3 == 5) {
        uint32_t address = c->r[rn], rd = hw2 & 0xF;
        if (c->exclusive && c->exclusive_address == address) {
            if (op3 == 4) write8(c, address, c->r[rt]);
            else write16(c, address, c->r[rt]);
            c->r[rd] = 0;
        } else {
            c->r[rd] = 1;
        }
        c->exclusive = false;
        c->cost += 1;
        return;
    }
    undefined(c);
}

static void exec_dp_shifted(CM4 *c, uint32_t hw1, uint32_t hw2) {
    uint32_t op = (hw1 >> 5) & 0xF, rn = hw1 & 0xF, rd = (hw2 >> 8) & 0xF, rm = hw2 & 0xF;
    bool s = (hw1 >> 4) & 1;
    uint32_t imm5 = ((hw2 >> 10) & 0x1C) | ((hw2 >> 6) & 3);
    int type;
    uint32_t amount, carry;
    decode_imm_shift((hw2 >> 4) & 3, imm5, &type, &amount);
    uint32_t shifted = shift_c(reg(c, rm), type, amount, c->c, &carry);
    if (op == 0x6) {
        // PKHBT, PKHTB
        uint32_t n = reg(c, rn);
        if ((hw2 >> 5) & 1) c->r[rd] = (n & 0xFFFF0000u) | (shifted & 0xFFFF);
        else c->r[rd] = (shifted & 0xFFFF0000u) | (n & 0xFFFF);
        return;
    }
    data_processing(c, op, rn, rd, shifted, carry, s);
}

static void exec_dp_immediate(CM4 *c, uint32_t hw1, uint32_t hw2) {
    uint32_t op = (hw1 >> 5) & 0xF, rn = hw1 & 0xF, rd = (hw2 >> 8) & 0xF;
    bool s = (hw1 >> 4) & 1;
    uint32_t imm12 = ((hw1 >> 10) & 1) << 11 | ((hw2 >> 12) & 7) << 8 | (hw2 & 0xFF);
    uint32_t carry;
    uint32_t imm32 = expand_imm_c(imm12, c->c, &carry);
    data_processing(c, op, rn, rd, imm32, carry, s);
}

static void exec_plain_immediate(CM4 *c, uint32_t hw1, uint32_t hw2) {
    uint32_t op = (hw1 >> 4) & 0x1F, rn = hw1 & 0xF, rd = (hw2 >> 8) & 0xF;
    uint32_t imm12 = ((hw1 >> 10) & 1) << 11 | ((hw2 >> 12) & 7) << 8 | (hw2 & 0xFF);
    uint32_t shift_amount = ((hw2 >> 10) & 0x1C) | ((hw2 >> 6) & 3);
    switch (op) {
    case 0x00: c->r[rd] = rn == 15 ? align4(c->pc + 4) + imm12 : reg(c, rn) + imm12; return;
    case 0x0A: c->r[rd] = rn == 15 ? align4(c->pc + 4) - imm12 : reg(c, rn) - imm12; return;
    case 0x04: c->r[rd] = ((hw1 & 0xF) << 12) | imm12; return;
    case 0x0C: c->r[rd] = (((hw1 & 0xF) << 12 | imm12) << 16) | (c->r[rd] & 0xFFFF); return;
    case 0x10: case 0x12: {
        bool saturated = false;
        if (op == 0x12 && shift_amount == 0) {
            // SSAT16
            int bits = (int)(hw2 & 0xF) + 1;
            uint32_t n = reg(c, rn);
            int32_t lo = signed_sat((int16_t)(n & 0xFFFF), bits, &saturated);
            int32_t hi = signed_sat((int16_t)(n >> 16), bits, &saturated);
            c->r[rd] = ((uint32_t)hi << 16) | ((uint32_t)lo & 0xFFFF);
        } else {
            int bits = (int)(hw2 & 0x1F) + 1;
            uint32_t operand = shift(reg(c, rn), op == 0x12 ? SR_ASR : SR_LSL, shift_amount, c->c);
            c->r[rd] = (uint32_t)signed_sat((int32_t)operand, bits, &saturated);
        }
        if (saturated) c->q = 1;
        return;
    }
    case 0x18: case 0x1A: {
        bool saturated = false;
        if (op == 0x1A && shift_amount == 0) {
            int bits = (int)(hw2 & 0xF);
            uint32_t n = reg(c, rn);
            uint32_t lo = unsigned_sat((int16_t)(n & 0xFFFF), bits, &saturated);
            uint32_t hi = unsigned_sat((int16_t)(n >> 16), bits, &saturated);
            c->r[rd] = (hi << 16) | lo;
        } else {
            int bits = (int)(hw2 & 0x1F);
            uint32_t operand = shift(reg(c, rn), op == 0x1A ? SR_ASR : SR_LSL, shift_amount, c->c);
            c->r[rd] = unsigned_sat((int32_t)operand, bits, &saturated);
        }
        if (saturated) c->q = 1;
        return;
    }
    case 0x14: case 0x1C: {
        // SBFX, UBFX
        uint32_t lsb = shift_amount, width = (hw2 & 0x1F) + 1;
        if (lsb + width > 32) { undefined(c); return; }
        uint32_t field = width == 32 ? reg(c, rn) : (reg(c, rn) >> lsb) & ((1u << width) - 1);
        if (op == 0x14 && width < 32) field = (uint32_t)(((int32_t)(field << (32 - width))) >> (32 - width));
        c->r[rd] = field;
        return;
    }
    case 0x16: {
        // BFI, BFC
        uint32_t lsb = shift_amount, msb = hw2 & 0x1F;
        if (msb < lsb) { undefined(c); return; }
        uint32_t width = msb - lsb + 1;
        uint32_t mask = (width == 32 ? 0xFFFFFFFFu : ((1u << width) - 1)) << lsb;
        uint32_t source = rn == 15 ? 0 : reg(c, rn) << lsb;
        c->r[rd] = (c->r[rd] & ~mask) | (source & mask);
        return;
    }
    default: undefined(c); return;
    }
}

static uint32_t read_special(CM4 *c, uint32_t sysm) {
    switch (sysm) {
    case 0: case 1: case 2: case 3: case 5: case 6: case 7: {
        uint32_t value = 0;
        if (!(sysm & 4)) value |= (c->n << 31) | (c->z << 30) | (c->c << 29) | (c->v << 28) | (c->q << 27) | (c->ge << 16);
        if (sysm & 1) value |= c->ipsr;
        return value;
    }
    case 8: return msp(c);
    case 9: return psp(c);
    case 16: return c->primask & 1;
    case 17: case 18: return c->basepri;
    case 19: return c->faultmask & 1;
    case 20: return c->control;
    default: return 0;
    }
}

static void write_special(CM4 *c, uint32_t sysm, uint32_t mask, uint32_t value) {
    bool privileged = c->ipsr != 0 || !(c->control & CONTROL_NPRIV);
    if (sysm < 8) {
        if (!(sysm & 4)) {
            if (mask & 2) set_apsr(c, value);
            if (mask & 1) c->ge = (value >> 16) & 0xF;
        }
        return;
    }
    if (!privileged) return;
    switch (sysm) {
    case 8:
        if (using_psp(c)) c->other_sp = value & ~3u;
        else c->r[13] = value & ~3u;
        return;
    case 9:
        if (using_psp(c)) c->r[13] = value & ~3u;
        else c->other_sp = value & ~3u;
        return;
    case 16: c->primask = value & 1; break;
    case 17: c->basepri = value & c->priority_mask; break;
    case 18: {
        uint32_t v = value & c->priority_mask;
        if (v != 0 && (v < c->basepri || c->basepri == 0)) c->basepri = v;
        break;
    }
    case 19: if (execution_priority(c) > -1) c->faultmask = value & 1; break;
    case 20: {
        bool was_process = using_psp(c);
        uint32_t keep = c->control;
        uint32_t control = (keep & ~(uint32_t)(CONTROL_NPRIV | CONTROL_FPCA)) | (value & (CONTROL_NPRIV | CONTROL_FPCA));
        if (c->ipsr == 0) control = (control & ~(uint32_t)CONTROL_SPSEL) | (value & CONTROL_SPSEL);
        c->control = control;
        select_sp(c, was_process, using_psp(c));
        break;
    }
    default: return;
    }
    c->check_exceptions = true;
}

static void exec_branch_misc(CM4 *c, uint32_t hw1, uint32_t hw2) {
    uint32_t op1 = (hw2 >> 12) & 7;
    uint32_t s = (hw1 >> 10) & 1, j1 = (hw2 >> 13) & 1, j2 = (hw2 >> 11) & 1;
    if ((op1 & 5) == 0) {
        uint32_t cond = (hw1 >> 6) & 0xF;
        if ((cond & 0xE) != 0xE) {
            uint32_t imm = (s << 20) | (j2 << 19) | (j1 << 18) | ((hw1 & 0x3F) << 12) | ((hw2 & 0x7FF) << 1);
            int32_t offset = ((int32_t)(imm << 11)) >> 11;
            if (condition_passed(c, cond)) branch_write_pc(c, c->pc + 4 + (uint32_t)offset);
            return;
        }
        uint32_t op = (hw1 >> 4) & 0x7F;
        if ((op & 0x7E) == 0x38) {
            write_special(c, hw2 & 0xFF, (hw2 >> 10) & 3, c->r[hw1 & 0xF]);
            return;
        }
        if (op == 0x3A) {
            switch (hw2 & 0xFF) {
            case 2: if (c->event) c->event = false; else { c->sleeping = true; c->waiting_for_event = true; } return;
            case 3: c->sleeping = true; return;
            case 4: c->event = true; return;
            default: return;
            }
        }
        if (op == 0x3B) {
            if (((hw2 >> 4) & 0xF) == 2) c->exclusive = false;  // CLREX; DSB, DMB, ISB do nothing here
            return;
        }
        if ((op & 0x7E) == 0x3E) {
            c->r[(hw2 >> 8) & 0xF] = read_special(c, hw2 & 0xFF);
            return;
        }
        undefined(c);
        return;
    }
    uint32_t i1 = !(j1 ^ s), i2 = !(j2 ^ s);
    uint32_t imm = (s << 24) | (i1 << 23) | (i2 << 22) | ((hw1 & 0x3FF) << 12) | ((hw2 & 0x7FF) << 1);
    int32_t offset = ((int32_t)(imm << 7)) >> 7;
    if ((op1 & 5) == 1) {
        branch_write_pc(c, c->pc + 4 + (uint32_t)offset);
        return;
    }
    if ((op1 & 5) == 5) {
        c->r[14] = (c->pc + 4) | 1;
        branch_write_pc(c, c->pc + 4 + (uint32_t)offset);
        return;
    }
    undefined(c);
}

/// The DSP extension's parallel additions and subtractions: op (hw1[6:4]) the operation, prefix (hw2[6:4]) signed or
/// unsigned, modulo (setting GE), saturating or halving
static void exec_parallel(CM4 *c, uint32_t op, uint32_t prefix, uint32_t rd, uint32_t n, uint32_t m) {
    bool bytes = op == 0 || op == 4;
    if (op == 3 || op == 7 || (prefix & 3) == 3) { undefined(c); return; }
    bool is_signed = !(prefix & 4);
    int mode = (int)(prefix & 3);
    int width = bytes ? 8 : 16, lanes = bytes ? 4 : 2;
    uint32_t lane_mask = bytes ? 0xFF : 0xFFFF;
    uint32_t result = 0, ge = 0;
    for (int i = 0; i < lanes; i++) {
        int64_t a, b;
        bool add;
        int cross_lane = i;
        // ASX: lane 0 Rn.lo - Rm.hi, lane 1 Rn.hi + Rm.lo; SAX: the other way round
        if (op == 2) { cross_lane = 1 - i; add = i == 1; }
        else if (op == 6) { cross_lane = 1 - i; add = i == 0; }
        else add = op == 0 || op == 1;
        uint32_t ua = (n >> (i * width)) & lane_mask, ub = (m >> (cross_lane * width)) & lane_mask;
        if (is_signed) {
            a = bytes ? (int8_t)ua : (int16_t)ua;
            b = bytes ? (int8_t)ub : (int16_t)ub;
        } else {
            a = ua;
            b = ub;
        }
        int64_t r = add ? a + b : a - b;
        uint32_t lane;
        if (mode == 0) {
            lane = (uint32_t)r & lane_mask;
            bool flag = is_signed ? r >= 0 : (add ? r >= ((int64_t)1 << width) : r >= 0);
            if (flag) ge |= (bytes ? 1u : 3u) << (i * (bytes ? 1 : 2));
        } else if (mode == 1) {
            bool saturated = false;
            lane = (is_signed ? (uint32_t)signed_sat(r, width, &saturated) : unsigned_sat(r, width, &saturated)) & lane_mask;
        } else {
            lane = (uint32_t)(r >> 1) & lane_mask;
        }
        result |= lane << (i * width);
    }
    c->r[rd] = result;
    if (mode == 0) c->ge = ge;
}

static void exec_dp_register(CM4 *c, uint32_t hw1, uint32_t hw2) {
    uint32_t op1 = (hw1 >> 4) & 0xF, op2 = (hw2 >> 4) & 0xF;
    uint32_t rn = hw1 & 0xF, rd = (hw2 >> 8) & 0xF, rm = hw2 & 0xF;
    if (!(op1 & 8) && op2 == 0) {
        static const int types[4] = {SR_LSL, SR_LSR, SR_ASR, SR_ROR};
        uint32_t carry;
        uint32_t result = shift_c(reg(c, rn), types[(op1 >> 1) & 3], reg(c, rm) & 0xFF, c->c, &carry);
        c->r[rd] = result;
        if (op1 & 1) set_logical_flags(c, result, carry);
        return;
    }
    if (!(op1 & 8) && (op2 & 8)) {
        uint32_t rotated = shift(reg(c, rm), SR_ROR, ((hw2 >> 4) & 3) * 8, 0);
        uint32_t add = rn == 15 ? 0 : c->r[rn];
        switch (op1 & 7) {
        case 0: c->r[rd] = add + (uint32_t)(int16_t)rotated; return;
        case 1: c->r[rd] = add + (rotated & 0xFFFF); return;
        case 2: {
            uint32_t lo = (uint32_t)(int8_t)rotated + add;
            uint32_t hi = (uint32_t)(int8_t)(rotated >> 16) + (add >> 16);
            c->r[rd] = (hi << 16) | (lo & 0xFFFF);
            return;
        }
        case 3: {
            uint32_t lo = (rotated & 0xFF) + add;
            uint32_t hi = ((rotated >> 16) & 0xFF) + (add >> 16);
            c->r[rd] = (hi << 16) | (lo & 0xFFFF);
            return;
        }
        case 4: c->r[rd] = add + (uint32_t)(int8_t)rotated; return;
        case 5: c->r[rd] = add + (rotated & 0xFF); return;
        default: undefined(c); return;
        }
    }
    if ((op1 & 8) && !(op2 & 8)) {
        exec_parallel(c, op1 & 7, op2 & 7, rd, reg(c, rn), reg(c, rm));
        return;
    }
    if ((op1 & 0xC) == 8 && (op2 & 0xC) == 8) {
        uint32_t m = reg(c, rm), n = reg(c, rn);
        switch (((op1 & 3) << 2) | (op2 & 3)) {
        case 0x0: case 0x1: case 0x2: case 0x3: {
            // QADD, QDADD, QSUB, QDSUB: Rd = Rm ± Rn (doubled)
            bool saturated = false;
            int64_t operand = (int32_t)n;
            if (op2 & 1) operand = signed_sat(2 * operand, 32, &saturated);
            int64_t value = (op2 & 2) ? (int64_t)(int32_t)m - operand : (int64_t)(int32_t)m + operand;
            c->r[rd] = (uint32_t)signed_sat(value, 32, &saturated);
            if (saturated) c->q = 1;
            return;
        }
        case 0x4: c->r[rd] = __builtin_bswap32(m); return;
        case 0x5: c->r[rd] = ((m >> 8) & 0x00FF00FFu) | ((m << 8) & 0xFF00FF00u); return;
        case 0x6: {
            uint32_t r = 0;
            for (int i = 0; i < 32; i++) r |= ((m >> i) & 1) << (31 - i);
            c->r[rd] = r;
            return;
        }
        case 0x7: c->r[rd] = (uint32_t)(int16_t)(((m & 0xFF) << 8) | ((m >> 8) & 0xFF)); return;
        case 0x8: {
            uint32_t r = 0;
            for (int i = 0; i < 4; i++) r |= (((c->ge >> i) & 1) ? n : m) & (0xFFu << (8 * i));
            c->r[rd] = r;
            return;
        }
        case 0xC: c->r[rd] = m ? (uint32_t)__builtin_clz(m) : 32; return;
        default: undefined(c); return;
        }
    }
    undefined(c);
}

static inline int32_t half(uint32_t value, bool top) { return top ? (int16_t)(value >> 16) : (int16_t)value; }

static void exec_multiply(CM4 *c, uint32_t hw1, uint32_t hw2) {
    uint32_t op1 = (hw1 >> 4) & 7, op2 = (hw2 >> 4) & 3;
    uint32_t rn = hw1 & 0xF, ra = hw2 >> 12, rd = (hw2 >> 8) & 0xF, rm = hw2 & 0xF;
    uint32_t n = reg(c, rn), m = reg(c, rm);
    bool accumulate = ra != 15;
    int32_t acc = accumulate ? (int32_t)reg(c, ra) : 0;
    switch (op1) {
    case 0:
        if (op2 == 0) c->r[rd] = n * m + (accumulate ? reg(c, ra) : 0);
        else if (op2 == 1) c->r[rd] = reg(c, ra) - n * m;
        else undefined(c);
        return;
    case 1: {
        int64_t result = (int64_t)half(n, (hw2 >> 5) & 1) * half(m, (hw2 >> 4) & 1) + acc;
        c->r[rd] = (uint32_t)result;
        if (result != (int32_t)result) c->q = 1;
        return;
    }
    case 2: case 4: {
        if (op2 & 2) { undefined(c); return; }
        bool swap = op2 & 1;
        uint32_t operand = swap ? (m >> 16) | (m << 16) : m;
        int64_t p1 = (int64_t)half(n, false) * half(operand, false);
        int64_t p2 = (int64_t)half(n, true) * half(operand, true);
        int64_t result = (op1 == 2 ? p1 + p2 : p1 - p2) + acc;
        c->r[rd] = (uint32_t)result;
        if (result != (int32_t)result) c->q = 1;
        return;
    }
    case 3: {
        if (op2 & 2) { undefined(c); return; }
        int64_t result = (int64_t)(int32_t)n * half(m, op2 & 1) + ((int64_t)acc << 16);
        c->r[rd] = (uint32_t)(result >> 16);
        if ((result >> 16) != (int32_t)(result >> 16)) c->q = 1;
        return;
    }
    case 5: case 6: {
        if (op2 & 2) { undefined(c); return; }
        int64_t product = (int64_t)(int32_t)n * (int32_t)m;
        int64_t result = ((int64_t)acc << 32);
        result = op1 == 5 ? (int64_t)((uint64_t)result + (uint64_t)product) : (int64_t)((uint64_t)result - (uint64_t)product);
        if (op2 & 1) result = (int64_t)((uint64_t)result + 0x80000000u);
        c->r[rd] = (uint32_t)((uint64_t)result >> 32);
        return;
    }
    default: {
        if (op2 != 0) { undefined(c); return; }
        uint32_t sum = 0;
        for (int i = 0; i < 4; i++) {
            int32_t a = (int32_t)((n >> (8 * i)) & 0xFF), b = (int32_t)((m >> (8 * i)) & 0xFF);
            sum += (uint32_t)(a > b ? a - b : b - a);
        }
        c->r[rd] = sum + (accumulate ? reg(c, ra) : 0);
        return;
    }
    }
}

static void exec_long_multiply(CM4 *c, uint32_t hw1, uint32_t hw2) {
    uint32_t op1 = (hw1 >> 4) & 7, op2 = (hw2 >> 4) & 0xF;
    uint32_t rn = hw1 & 0xF, rdlo = hw2 >> 12, rdhi = (hw2 >> 8) & 0xF, rm = hw2 & 0xF;
    uint32_t n = reg(c, rn), m = reg(c, rm);
    uint64_t acc = ((uint64_t)c->r[rdhi] << 32) | c->r[rdlo];
    uint64_t result;
    switch (op1) {
    case 0: if (op2) { undefined(c); return; } result = (uint64_t)((int64_t)(int32_t)n * (int32_t)m); break;
    case 2: if (op2) { undefined(c); return; } result = (uint64_t)n * m; break;
    case 1: case 3: {
        if (op2 != 0xF) { undefined(c); return; }
        uint32_t rd = rdhi;
        if (m == 0) {
            if (c->ccr & 0x10) { usage_fault(c, UFSR_DIVBYZERO); return; }
            c->r[rd] = 0;
        } else if (op1 == 1) {
            if (n == 0x80000000u && m == 0xFFFFFFFFu) c->r[rd] = 0x80000000u;
            else c->r[rd] = (uint32_t)((int32_t)n / (int32_t)m);
        } else {
            c->r[rd] = n / m;
        }
        c->cost += 6;
        return;
    }
    case 4:
        if (op2 == 0) result = acc + (uint64_t)((int64_t)(int32_t)n * (int32_t)m);
        else if ((op2 & 0xC) == 8) result = acc + (uint64_t)((int64_t)half(n, (op2 >> 1) & 1) * half(m, op2 & 1));
        else if ((op2 & 0xE) == 0xC) {
            uint32_t operand = (op2 & 1) ? (m >> 16) | (m << 16) : m;
            int64_t p = (int64_t)half(n, false) * half(operand, false) + (int64_t)half(n, true) * half(operand, true);
            result = acc + (uint64_t)p;
        } else { undefined(c); return; }
        break;
    case 5:
        if ((op2 & 0xE) == 0xC) {
            uint32_t operand = (op2 & 1) ? (m >> 16) | (m << 16) : m;
            int64_t p = (int64_t)half(n, false) * half(operand, false) - (int64_t)half(n, true) * half(operand, true);
            result = acc + (uint64_t)p;
        } else { undefined(c); return; }
        break;
    case 6:
        if (op2 == 0) result = acc + (uint64_t)n * m;
        else if (op2 == 6) result = (uint64_t)n * m + c->r[rdhi] + c->r[rdlo];
        else { undefined(c); return; }
        break;
    default: undefined(c); return;
    }
    c->r[rdlo] = (uint32_t)result;
    c->r[rdhi] = (uint32_t)(result >> 32);
}

__attribute__((noinline)) static void exec32(CM4 *c, uint32_t hw1, uint32_t hw2) {
    uint32_t op1 = (hw1 >> 11) & 3, op2 = (hw1 >> 4) & 0x7F;
    if (op1 == 1) {
        if ((op2 & 0x64) == 0x00) {
            uint32_t op = (hw1 >> 7) & 3;
            bool load = (hw1 >> 4) & 1, writeback = (hw1 >> 5) & 1;
            if (op == 1 || op == 2) exec_ldm_stm(c, hw1 & 0xF, hw2 & (load ? 0xDFFFu : 0x5FFFu), load, writeback, op == 2);
            else undefined(c);
            return;
        }
        if ((op2 & 0x64) == 0x04) { exec_dual_exclusive(c, hw1, hw2); return; }
        if ((op2 & 0x60) == 0x20) { exec_dp_shifted(c, hw1, hw2); return; }
        exec_fp(c, hw1, hw2);
        return;
    }
    if (op1 == 2) {
        if (hw2 & 0x8000) { exec_branch_misc(c, hw1, hw2); return; }
        if (op2 & 0x20) exec_plain_immediate(c, hw1, hw2);
        else exec_dp_immediate(c, hw1, hw2);
        return;
    }
    if ((op2 & 0x60) == 0x00) { exec_load_store_single(c, hw1, hw2); return; }
    if ((op2 & 0x70) == 0x20) { exec_dp_register(c, hw1, hw2); return; }
    if ((op2 & 0x78) == 0x30) { exec_multiply(c, hw1, hw2); return; }
    if ((op2 & 0x78) == 0x38) { exec_long_multiply(c, hw1, hw2); return; }
    if (op2 & 0x40) { exec_fp(c, hw1, hw2); return; }
    undefined(c);
}

// ---------------------------------------------------------------------------------------------- floating point
//
// Single-precision values are computed with the host's IEEE arithmetic (as exact as the FPU's for +, -, *, /, sqrt
// and fused multiply-add), around which ARM's rules are applied by hand: NaN propagation (a signalling NaN first,
// quietened; then a quiet one; the default NaN 0x7FC00000 where an operation has no NaN operand, or with DN), flush
// to zero of denormal inputs and of results tiny before rounding (FZ), and the cumulative exception flags, tininess
// detected before rounding as on ARM.

#define DEFAULT_NAN 0x7FC00000u

static inline bool f_is_nan(uint32_t x) { return (x & 0x7F800000u) == 0x7F800000u && (x & 0x7FFFFFu); }
static inline bool f_is_snan(uint32_t x) { return f_is_nan(x) && !(x & 0x400000u); }
static inline bool f_is_inf(uint32_t x) { return (x & 0x7FFFFFFFu) == 0x7F800000u; }
static inline bool f_is_zero(uint32_t x) { return (x & 0x7FFFFFFFu) == 0; }
static inline bool f_is_denormal(uint32_t x) { return (x & 0x7F800000u) == 0 && (x & 0x7FFFFFu); }

static inline float as_float(uint32_t bits) { float f; memcpy(&f, &bits, 4); return f; }
static inline uint32_t as_bits(float f) { uint32_t b; memcpy(&b, &f, 4); return b; }

static inline uint32_t fp_input(CM4 *c, uint32_t x) {
    if ((c->fpscr & FPSCR_FZ) && f_is_denormal(x)) {
        c->fpscr |= FPSCR_IDC;
        return x & 0x80000000u;
    }
    return x;
}

static inline uint32_t fp_nan(CM4 *c, uint32_t x) {
    if (f_is_snan(x)) {
        c->fpscr |= FPSCR_IOC;
        x |= 0x400000u;
    }
    return (c->fpscr & FPSCR_DN) ? DEFAULT_NAN : x;
}

static inline bool fp_nans2(CM4 *c, uint32_t a, uint32_t b, uint32_t *result) {
    if (f_is_snan(a)) { *result = fp_nan(c, a); return true; }
    if (f_is_snan(b)) { *result = fp_nan(c, b); return true; }
    if (f_is_nan(a)) { *result = fp_nan(c, a); return true; }
    if (f_is_nan(b)) { *result = fp_nan(c, b); return true; }
    return false;
}

static inline uint32_t fp_invalid(CM4 *c) {
    c->fpscr |= FPSCR_IOC;
    return DEFAULT_NAN;
}

/// Rounds in FPSCR's mode: the host's is switched only for the modes other than to nearest
static inline int fp_round_begin(CM4 *c) {
    int mode = (int)((c->fpscr >> 22) & 3);
    if (mode) {
        static const int modes[4] = {FE_TONEAREST, FE_UPWARD, FE_DOWNWARD, FE_TOWARDZERO};
        fesetround(modes[mode]);
    }
    return mode;
}

static inline void fp_round_end(int mode) {
    if (mode) fesetround(FE_TONEAREST);
}

/// The flags of a rounded result `r` whose exact value is `exact` (or, where that is not exactly known, nearly it,
/// with `inexact` saying whether rounding changed it); flushes a result tiny before rounding to zero with FZ
static uint32_t fp_finish(CM4 *c, float r, double exact, bool inexact) {
    uint32_t bits = as_bits(r);
    double magnitude = fabs(exact);
    if (isfinite(exact) && magnitude > 0 && magnitude < 0x1p-126) {
        if (c->fpscr & FPSCR_FZ) {
            c->fpscr |= FPSCR_UFC;
            return bits & 0x80000000u;
        }
        if (inexact) c->fpscr |= FPSCR_UFC;
    }
    if (isfinite(exact) && !isfinite(r)) {
        c->fpscr |= FPSCR_OFC | FPSCR_IXC;
        return bits;
    }
    if (isfinite(exact) && magnitude > 0x1.fffffep127) c->fpscr |= FPSCR_OFC;
    if (inexact) c->fpscr |= FPSCR_IXC;
    return bits;
}

// The common case, fast: both operands normal numbers, rounding to nearest, and the inexact flag already set (it is
// sticky, and set by a firmware's first inexact operation). Then the host's result is the FPU's whenever it is a
// normal number above the smallest binade (where a result tiny before rounding could have rounded up), and it sets no
// flag that is not set already. Anything else takes the full path.
static inline bool f_plain(uint32_t x) { return ((x >> 23) & 0xFF) - 1u < 0xFEu; }
static inline bool fp_plain_operands(const CM4 *c, uint32_t a, uint32_t b) {
    return (c->fpscr & (FPSCR_RMODE | FPSCR_IXC)) == FPSCR_IXC && f_plain(a) && f_plain(b);
}
static inline bool fp_plain_result(uint32_t r) { return ((r >> 23) & 0xFF) - 2u < 0xFDu; }

static uint32_t fp_add_full(CM4 *c, uint32_t a, uint32_t b);

static inline uint32_t fp_add(CM4 *c, uint32_t a, uint32_t b) {
    if (fp_plain_operands(c, a, b)) {
        uint32_t r = as_bits(as_float(a) + as_float(b));
        if (fp_plain_result(r)) return r;
    }
    return fp_add_full(c, a, b);
}

static uint32_t fp_add_full(CM4 *c, uint32_t a, uint32_t b) {
    a = fp_input(c, a);
    b = fp_input(c, b);
    uint32_t result;
    if (fp_nans2(c, a, b, &result)) return result;
    if (f_is_inf(a) && f_is_inf(b) && ((a ^ b) >> 31)) return fp_invalid(c);
    if (f_is_inf(a) || f_is_inf(b)) return f_is_inf(a) ? a : b;
    float x = as_float(a), y = as_float(b);
    int mode = fp_round_begin(c);
    float r = x + y;
    fp_round_end(mode);
    // Knuth's two-sum: the rounding error of r, exactly
    double exact = (double)x + (double)y;
    bool inexact;
    if (isfinite(r)) {
        float bb = r - x;
        float error = (x - (r - bb)) + (y - bb);
        inexact = error != 0 || (double)r != exact;
    } else {
        inexact = true;
    }
    return fp_finish(c, r, exact, inexact);
}

static inline uint32_t fp_neg(uint32_t a) { return a ^ 0x80000000u; }

static uint32_t fp_sub(CM4 *c, uint32_t a, uint32_t b) {
    if (fp_plain_operands(c, a, b)) {
        uint32_t r = as_bits(as_float(a) - as_float(b));
        if (fp_plain_result(r)) return r;
    }
    // (NaN processing on the operands as given, before the negation)
    uint32_t a2 = fp_input(c, a), b2 = fp_input(c, b), result;
    if (fp_nans2(c, a2, b2, &result)) return result;
    return fp_add(c, a2, fp_neg(b2));
}

static uint32_t fp_mul(CM4 *c, uint32_t a, uint32_t b) {
    if (fp_plain_operands(c, a, b)) {
        uint32_t r = as_bits(as_float(a) * as_float(b));
        if (fp_plain_result(r)) return r;
    }
    a = fp_input(c, a);
    b = fp_input(c, b);
    uint32_t result;
    if (fp_nans2(c, a, b, &result)) return result;
    if ((f_is_inf(a) && f_is_zero(b)) || (f_is_zero(a) && f_is_inf(b))) return fp_invalid(c);
    float x = as_float(a), y = as_float(b);
    int mode = fp_round_begin(c);
    float r = x * y;
    fp_round_end(mode);
    if (f_is_inf(a) || f_is_inf(b)) return as_bits(r);
    double exact = (double)x * (double)y;
    return fp_finish(c, r, exact, (double)r != exact);
}

static uint32_t fp_div(CM4 *c, uint32_t a, uint32_t b) {
    if (fp_plain_operands(c, a, b)) {
        uint32_t r = as_bits(as_float(a) / as_float(b));
        if (fp_plain_result(r)) return r;
    }
    a = fp_input(c, a);
    b = fp_input(c, b);
    uint32_t result;
    if (fp_nans2(c, a, b, &result)) return result;
    if ((f_is_inf(a) && f_is_inf(b)) || (f_is_zero(a) && f_is_zero(b))) return fp_invalid(c);
    if (f_is_inf(a) || f_is_zero(a) || f_is_inf(b)) {
        uint32_t sign = (a ^ b) & 0x80000000u;
        return sign | ((f_is_inf(a)) ? 0x7F800000u : 0);
    }
    if (f_is_zero(b)) {
        c->fpscr |= FPSCR_DZC;
        return ((a ^ b) & 0x80000000u) | 0x7F800000u;
    }
    float x = as_float(a), y = as_float(b);
    int mode = fp_round_begin(c);
    float r = x / y;
    fp_round_end(mode);
    double exact = (double)x / (double)y;
    bool inexact = !isfinite(r) || (double)r * (double)y != (double)x;
    return fp_finish(c, r, exact, inexact);
}

static uint32_t fp_sqrt(CM4 *c, uint32_t a) {
    a = fp_input(c, a);
    if (f_is_nan(a)) return fp_nan(c, a);
    if (f_is_zero(a)) return a;
    if (a >> 31) return fp_invalid(c);
    if (f_is_inf(a)) return a;
    float x = as_float(a);
    int mode = fp_round_begin(c);
    float r = sqrtf(x);
    fp_round_end(mode);
    return fp_finish(c, r, sqrt((double)x), (double)r * (double)r != (double)x);
}

/// Fused multiply-add: addend + n * m, rounded once
static uint32_t fp_muladd(CM4 *c, uint32_t addend, uint32_t n, uint32_t m) {
    if ((c->fpscr & (FPSCR_RMODE | FPSCR_IXC)) == FPSCR_IXC && f_plain(addend) && f_plain(n) && f_plain(m)) {
        uint32_t r = as_bits(fmaf(as_float(n), as_float(m), as_float(addend)));
        if (fp_plain_result(r)) return r;
    }
    addend = fp_input(c, addend);
    n = fp_input(c, n);
    m = fp_input(c, m);
    bool inf_zero = (f_is_inf(n) && f_is_zero(m)) || (f_is_zero(n) && f_is_inf(m));
    // ARM's order: the addend first
    if (f_is_snan(addend)) return fp_nan(c, addend);
    if (f_is_snan(n)) return fp_nan(c, n);
    if (f_is_snan(m)) return fp_nan(c, m);
    if (f_is_nan(addend)) {
        if (inf_zero) return fp_invalid(c);
        return fp_nan(c, addend);
    }
    if (f_is_nan(n)) return fp_nan(c, n);
    if (f_is_nan(m)) return fp_nan(c, m);
    if (inf_zero) return fp_invalid(c);
    bool product_inf = f_is_inf(n) || f_is_inf(m);
    uint32_t product_sign = (n ^ m) & 0x80000000u;
    if (product_inf && f_is_inf(addend) && product_sign != (addend & 0x80000000u)) return fp_invalid(c);
    if (product_inf) return product_sign | 0x7F800000u;
    if (f_is_inf(addend)) return addend;
    float x = as_float(n), y = as_float(m), z = as_float(addend);
    int mode = fp_round_begin(c);
    float r = fmaf(x, y, z);
    fp_round_end(mode);
    double product = (double)x * (double)y;  // exact
    double sum = product + (double)z;
    // two-sum in double: whether the exact result is a double at all
    double bb = sum - product;
    double error = (product - (sum - bb)) + ((double)z - bb);
    bool inexact = error != 0 || (double)r != sum;
    return fp_finish(c, r, sum, inexact);
}

static void fp_compare(CM4 *c, uint32_t a, uint32_t b, bool signal_quiet) {
    a = fp_input(c, a);
    b = fp_input(c, b);
    uint32_t nzcv;
    if (f_is_nan(a) || f_is_nan(b)) {
        nzcv = 0x3;
        if (signal_quiet || f_is_snan(a) || f_is_snan(b)) c->fpscr |= FPSCR_IOC;
    } else {
        float x = as_float(a), y = as_float(b);
        nzcv = x == y ? 0x6 : x < y ? 0x8 : 0x2;
    }
    c->fpscr = (c->fpscr & 0x0FFFFFFFu) | (nzcv << 28);
}

static double fp_round_to_integer(CM4 *c, double x, bool round_zero) {
    if (round_zero) return trunc(x);
    switch ((c->fpscr >> 22) & 3) {
    case 0: {
        double r = nearbyint(x);  // the host is in round-to-nearest-even here
        return r;
    }
    case 1: return ceil(x);
    case 2: return floor(x);
    default: return trunc(x);
    }
}

static uint32_t fp_to_int(CM4 *c, uint32_t a, bool is_signed, bool round_zero) {
    a = fp_input(c, a);
    if (f_is_nan(a)) {
        c->fpscr |= FPSCR_IOC;
        return 0;
    }
    double x = as_float(a);
    double r = fp_round_to_integer(c, x, round_zero);
    if (is_signed) {
        if (r > 2147483647.0) { c->fpscr |= FPSCR_IOC; return 0x7FFFFFFFu; }
        if (r < -2147483648.0) { c->fpscr |= FPSCR_IOC; return 0x80000000u; }
    } else {
        if (r > 4294967295.0) { c->fpscr |= FPSCR_IOC; return 0xFFFFFFFFu; }
        if (r < 0) { c->fpscr |= FPSCR_IOC; return 0; }
    }
    if (r != x) c->fpscr |= FPSCR_IXC;
    return is_signed ? (uint32_t)(int32_t)r : (uint32_t)r;
}

/// A value exactly known as a double, rounded to single in FPSCR's mode
static uint32_t fp_from_double(CM4 *c, double exact) {
    int mode = fp_round_begin(c);
    float r = (float)exact;
    fp_round_end(mode);
    return fp_finish(c, r, exact, (double)r != exact);
}

/// The fixed-point conversions: to fixed (rounding towards zero, saturating), or from fixed
/// 2^e as a double (|e| well inside its exponent's range): scaling by it is exact
static inline double pow2(int e) {
    uint64_t bits = (uint64_t)(1023 + e) << 52;
    double d;
    memcpy(&d, &bits, 8);
    return d;
}

static uint32_t fp_to_fixed(CM4 *c, uint32_t a, int size, int fraction, bool is_unsigned) {
    a = fp_input(c, a);
    if (f_is_nan(a)) {
        c->fpscr |= FPSCR_IOC;
        return 0;
    }
    double x = (double)as_float(a) * pow2(fraction);
    double r = trunc(x);
    double max = is_unsigned ? pow2(size) - 1 : pow2(size - 1) - 1;
    double min = is_unsigned ? 0 : -pow2(size - 1);
    if (r > max) { c->fpscr |= FPSCR_IOC; r = max; }
    else if (r < min) { c->fpscr |= FPSCR_IOC; r = min; }
    else if (r != x) c->fpscr |= FPSCR_IXC;
    int64_t value = (int64_t)r;
    if (size == 16) return is_unsigned ? (uint32_t)(value & 0xFFFF) : (uint32_t)(int32_t)(int16_t)value;
    return (uint32_t)value;
}

static uint32_t fp_from_fixed(CM4 *c, uint32_t bits, int size, int fraction, bool is_unsigned) {
    int64_t value;
    if (size == 16) value = is_unsigned ? (int64_t)(bits & 0xFFFF) : (int64_t)(int16_t)bits;
    else value = is_unsigned ? (int64_t)bits : (int64_t)(int32_t)bits;
    return fp_from_double(c, (double)value * pow2(-fraction));
}

/// Half precision to single (exact); AHP: the alternative format, without infinities or NaNs
static uint32_t half_to_single(CM4 *c, uint32_t h, bool ahp) {
    uint32_t sign = (h & 0x8000u) << 16, exp = (h >> 10) & 0x1F, frac = h & 0x3FF;
    if (exp == 0x1F && !ahp) {
        if (frac == 0) return sign | 0x7F800000u;
        // a NaN: its payload widened, quietened
        uint32_t nan = sign | 0x7F800000u | (frac << 13);
        if (!(frac & 0x200)) c->fpscr |= FPSCR_IOC;
        nan |= 0x400000u;
        return (c->fpscr & FPSCR_DN) ? DEFAULT_NAN : nan;
    }
    double value = ldexp((double)(exp ? (frac | 0x400) : frac), (exp ? (int)exp : 1) - 25);
    uint32_t bits = as_bits((float)value);
    return sign | bits;
}

/// Single to half precision, rounded in FPSCR's mode
static uint32_t single_to_half(CM4 *c, uint32_t a, bool ahp) {
    a = fp_input(c, a);
    uint32_t sign = (a >> 16) & 0x8000u;
    if (f_is_nan(a)) {
        if (ahp) { c->fpscr |= FPSCR_IOC; return sign; }
        if (f_is_snan(a)) c->fpscr |= FPSCR_IOC;
        if (c->fpscr & FPSCR_DN) return 0x7E00;
        return sign | 0x7E00 | ((a >> 13) & 0x3FF);
    }
    if (f_is_inf(a)) {
        if (ahp) { c->fpscr |= FPSCR_IOC; return sign | 0x7FFF; }
        return sign | 0x7C00;
    }
    if (f_is_zero(a)) return sign;
    double x = fabs((double)as_float(a));
    int e;
    frexp(x, &e);  // x = m * 2^e, m in [0.5, 1)
    int exponent = e - 1;  // x in [2^exponent, 2^(exponent+1))
    int quantum = exponent < -14 ? -24 : exponent - 10;
    double scaled = ldexp(x, -quantum);
    double rounded;
    switch ((c->fpscr >> 22) & 3) {
    case 0: rounded = nearbyint(scaled); break;
    case 1: rounded = sign ? floor(scaled) : ceil(scaled); break;
    case 2: rounded = sign ? ceil(scaled) : floor(scaled); break;
    default: rounded = floor(scaled); break;
    }
    bool inexact = rounded != scaled;
    double value = ldexp(rounded, quantum);
    double max = ahp ? 131008.0 : 65504.0;
    if (value > max) {
        if (ahp) {
            c->fpscr |= FPSCR_IOC;
            return sign | 0x7FFF;
        }
        c->fpscr |= FPSCR_OFC | FPSCR_IXC;
        int mode = (int)((c->fpscr >> 22) & 3);
        bool to_inf = mode == 0 || (mode == 1 && !sign) || (mode == 2 && sign);
        return sign | (to_inf ? 0x7C00 : 0x7BFF);
    }
    if (x < 0x1p-14 && inexact) c->fpscr |= FPSCR_UFC;
    if (inexact) c->fpscr |= FPSCR_IXC;
    if (value == 0) return sign;
    frexp(value, &e);
    exponent = e - 1;
    uint32_t h;
    if (exponent < -14) {
        h = (uint32_t)ldexp(value, 24);
    } else {
        uint32_t frac = (uint32_t)(ldexp(value, -exponent) * 1024.0) - 1024;
        h = ((uint32_t)(exponent + 15) << 10) | frac;
    }
    return sign | h;
}

static inline uint32_t vfp_expand_imm(uint32_t imm8) {
    uint32_t sign = (imm8 >> 7) & 1, b6 = (imm8 >> 6) & 1;
    uint32_t exp = ((b6 ^ 1) << 7) | (b6 ? 0x7C : 0) | ((imm8 >> 4) & 3);
    return (sign << 31) | (exp << 23) | ((imm8 & 0xF) << 19);
}

static void exec_fp_data(CM4 *c, uint32_t hw1, uint32_t hw2) {
    if ((hw1 & 0xFF00) != 0xEE00 || ((hw2 >> 8) & 1)) { undefined(c); return; }  // single precision only
    uint32_t opc1 = (hw1 >> 4) & 0xB;
    bool op = (hw2 >> 6) & 1;
    uint32_t d = ((hw2 >> 12) & 0xF) << 1 | ((hw1 >> 6) & 1);
    uint32_t n = (hw1 & 0xF) << 1 | ((hw2 >> 7) & 1);
    uint32_t m = (hw2 & 0xF) << 1 | ((hw2 >> 5) & 1);
    uint32_t *s = c->s;
    switch (opc1) {
    case 0x0: {
        // VMLA, VMLS: rounded product added
        uint32_t product = fp_mul(c, s[n], s[m]);
        s[d] = fp_add(c, s[d], op ? fp_neg(product) : product);
        c->cost += 2;
        return;
    }
    case 0x1: {
        // VNMLS (op 0), VNMLA (op 1)
        uint32_t product = fp_mul(c, s[n], s[m]);
        s[d] = fp_add(c, fp_neg(s[d]), op ? fp_neg(product) : product);
        c->cost += 2;
        return;
    }
    case 0x2: {
        uint32_t product = fp_mul(c, s[n], s[m]);
        s[d] = op ? fp_neg(product) : product;
        return;
    }
    case 0x3:
        s[d] = op ? fp_sub(c, s[n], s[m]) : fp_add(c, s[n], s[m]);
        return;
    case 0x8:
        if (op) { undefined(c); return; }
        s[d] = fp_div(c, s[n], s[m]);
        c->cost += 13;
        return;
    case 0x9:
        // VFNMS (op 0): -d + n * m; VFNMA (op 1): -d - n * m
        s[d] = fp_muladd(c, fp_neg(s[d]), op ? fp_neg(s[n]) : s[n], s[m]);
        c->cost += 2;
        return;
    case 0xA:
        // VFMA (op 0): d + n * m; VFMS (op 1): d - n * m
        s[d] = fp_muladd(c, s[d], op ? fp_neg(s[n]) : s[n], s[m]);
        c->cost += 2;
        return;
    default:
        break;
    }
    if (!op) {
        s[d] = vfp_expand_imm(((hw1 & 0xF) << 4) | (hw2 & 0xF));
        return;
    }
    uint32_t opc2 = hw1 & 0xF;
    bool top = (hw2 >> 7) & 1;
    switch (opc2) {
    case 0x0: s[d] = top ? s[m] & 0x7FFFFFFFu : s[m]; return;
    case 0x1:
        if (top) { s[d] = fp_sqrt(c, s[m]); c->cost += 13; }
        else s[d] = fp_neg(s[m]);
        return;
    case 0x2: {
        // VCVTB, VCVTT: half to single, from the bottom or top half
        uint32_t h = top ? s[m] >> 16 : s[m] & 0xFFFF;
        s[d] = half_to_single(c, h, (c->fpscr & FPSCR_AHP) != 0);
        return;
    }
    case 0x3: {
        uint32_t h = single_to_half(c, s[m], (c->fpscr & FPSCR_AHP) != 0);
        s[d] = top ? (s[d] & 0xFFFF) | (h << 16) : (s[d] & 0xFFFF0000u) | h;
        return;
    }
    case 0x4: fp_compare(c, s[d], s[m], top); return;
    case 0x5: fp_compare(c, s[d], 0, top); return;
    case 0x8: {
        uint32_t value = s[m];
        s[d] = fp_from_double(c, top ? (double)(int32_t)value : (double)value);
        return;
    }
    case 0xC: case 0xD:
        s[d] = fp_to_int(c, s[m], opc2 == 0xD, top);
        return;
    case 0xA: case 0xB: case 0xE: case 0xF: {
        int size = top ? 32 : 16;
        int imm = (int)(((hw2 & 0xF) << 1) | ((hw2 >> 5) & 1));
        int fraction = size - imm;
        if (fraction < 0) { undefined(c); return; }
        bool to_fixed = (opc2 & 4) != 0, is_unsigned = opc2 & 1;
        s[d] = to_fixed ? fp_to_fixed(c, s[d], size, fraction, is_unsigned) : fp_from_fixed(c, s[d], size, fraction, is_unsigned);
        return;
    }
    default: undefined(c); return;
    }
}

static void exec_fp(CM4 *c, uint32_t hw1, uint32_t hw2) {
    uint32_t coprocessor = (hw2 >> 8) & 0xF;
    if ((coprocessor & 0xE) != 0xA || !((c->cpacr >> 20) & 3)) {
        usage_fault(c, UFSR_NOCP);
        return;
    }
    if ((c->fpccr & (1u << 31)) && !(c->control & CONTROL_FPCA)) {
        // a new floating-point context (automatic state preservation on): its modes from FPDSCR
        c->fpscr = c->fpdscr;
        c->control |= CONTROL_FPCA;
    }
    uint32_t op1 = (hw1 >> 4) & 0x3F;
    bool op = (hw2 >> 4) & 1;
    bool double_registers = coprocessor & 1;
    if (!(op1 & 0x20)) {
        if ((op1 & 0x3E) == 0x00) { undefined(c); return; }
        if ((op1 & 0x3E) == 0x04) {
            // VMOV between two core registers and two singles or a double
            uint32_t rt = (hw2 >> 12) & 0xF, rt2 = hw1 & 0xF;
            uint32_t m = double_registers ? (((hw2 >> 5) & 1) << 4 | (hw2 & 0xF)) * 2 : ((hw2 & 0xF) << 1 | ((hw2 >> 5) & 1));
            if (m + 1 >= 32) { undefined(c); return; }
            if (op1 & 1) {
                c->r[rt] = c->s[m];
                c->r[rt2] = c->s[m + 1];
            } else {
                c->s[m] = c->r[rt];
                c->s[m + 1] = c->r[rt2];
            }
            return;
        }
        // VLDR, VSTR, VLDM, VSTM, VPUSH, VPOP
        bool p = (hw1 >> 8) & 1, u = (hw1 >> 7) & 1, w = (hw1 >> 5) & 1, load = (hw1 >> 4) & 1;
        uint32_t rn = hw1 & 0xF, vd = (hw2 >> 12) & 0xF, D = (hw1 >> 6) & 1, imm8 = hw2 & 0xFF;
        uint32_t first = double_registers ? (D << 4 | vd) * 2 : (vd << 1 | D);
        if (p && !w) {
            uint32_t base = rn == 15 ? align4(c->pc + 4) : c->r[rn];
            uint32_t address = u ? base + imm8 * 4 : base - imm8 * 4;
            int words = double_registers ? 2 : 1;
            for (int i = 0; i < words; i++) {
                if (load) c->s[first + (uint32_t)i] = read32(c, address + 4u * (uint32_t)i);
                else write32(c, address + 4u * (uint32_t)i, c->s[first + (uint32_t)i]);
            }
            c->cost += words;
            return;
        }
        if (p == u) { undefined(c); return; }
        uint32_t words = double_registers ? imm8 & ~1u : imm8;
        if (words == 0 || first + words > 32) { undefined(c); return; }
        uint32_t address = p ? reg(c, rn) - imm8 * 4 : reg(c, rn);
        for (uint32_t i = 0; i < words; i++) {
            if (load) c->s[first + i] = read32(c, address);
            else write32(c, address, c->s[first + i]);
            address += 4;
        }
        if (w) c->r[rn] = u ? c->r[rn] + imm8 * 4 : c->r[rn] - imm8 * 4;
        c->cost += (int)words;
        return;
    }
    if ((op1 & 0x30) != 0x20) { undefined(c); return; }
    if (!op) {
        exec_fp_data(c, hw1, hw2);
        return;
    }
    // transfers between core registers and the FPU's
    uint32_t rt = (hw2 >> 12) & 0xF;
    bool to_core = (hw1 >> 4) & 1;
    if (!double_registers) {
        if ((hw1 & 0xFFEF) == 0xEEE1 && (hw2 & 0xFFF) == 0xA10) {
            if (to_core) {
                if (rt == 15) {
                    uint32_t flags = c->fpscr >> 28;
                    c->n = (flags >> 3) & 1;
                    c->z = (flags >> 2) & 1;
                    c->c = (flags >> 1) & 1;
                    c->v = flags & 1;
                } else {
                    c->r[rt] = c->fpscr;
                }
            } else {
                c->fpscr = c->r[rt] & FPSCR_WRITABLE;
            }
            return;
        }
        if ((hw1 & 0xFFE0) == 0xEEE0) {
            // VMRS / VMSR of other system registers: FPSID and the MVFRs read, nothing written
            if (to_core && rt != 15) {
                uint32_t which = hw1 & 0xF;
                c->r[rt] = which == 0 ? 0x41023041u : which == 7 ? 0x10110021u : which == 6 ? 0x11000011u : 0;
            }
            return;
        }
        if ((hw1 & 0xFFE0) == 0xEE00 && (hw2 & 0x6F) == 0) {
            uint32_t n = (hw1 & 0xF) << 1 | ((hw2 >> 7) & 1);
            if (to_core) c->r[rt] = c->s[n];
            else c->s[n] = c->r[rt];
            return;
        }
        undefined(c);
        return;
    }
    // VMOV between a core register and half a double (32-bit scalars)
    if ((hw1 & 0xFFC0) == 0xEE00 && (hw2 & 0x6F) == 0) {
        uint32_t index = (hw1 >> 5) & 1;
        uint32_t dreg = ((hw2 >> 7) & 1) << 4 | (hw1 & 0xF);
        if (dreg >= 16) { undefined(c); return; }
        if (to_core) c->r[rt] = c->s[dreg * 2 + index];
        else c->s[dreg * 2 + index] = c->r[rt];
        return;
    }
    undefined(c);
}

// -------------------------------------------------------------------------------------------------------- running

static inline void it_advance(CM4 *c) {
    if ((c->it & 7) == 0) c->it = 0;
    else c->it = (c->it & 0xE0) | ((c->it << 1) & 0x1F);
}

/// Takes the pending exception that preempts what runs, if one does
static bool take_exception(CM4 *c) {
    bool preempts;
    int number = pending_exception(c, &preempts);
    if (number && preempts) {
        c->cost = 0;
        c->pc = c->r[15];
        exception_entry(c, number, c->r[15]);
        c->r[15] = c->next_pc;
        c->cycles += (uint64_t)c->cost;
        return true;
    }
    c->check_exceptions = false;
    return false;
}

/// Whether a sleeping core wakes: an exception that would preempt (with PRIMASK ignored, as WFI wakes for one), or
/// for WFE an event
static bool wakes(CM4 *c) {
    if (c->waiting_for_event && c->event) {
        c->event = false;
        return true;
    }
    uint32_t primask = c->primask;
    c->primask = 0;
    bool preempts;
    int number = pending_exception(c, &preempts);
    c->primask = primask;
    return number && preempts;
}

__attribute__((always_inline)) static inline CM4Stop step(CM4 *c) {
    if (c->cycles >= c->systick_wrap) systick_update(c);
    if (c->check_exceptions && take_exception(c)) return CM4_RAN;
    uint32_t pc = c->r[15];
    c->pc = pc;
    c->cost = 1;
    c->it_changed = false;
    bool in_block = in_it_block(c);
    bool run = !in_block || condition_passed(c, c->it >> 4);
    // the instruction's first halfword and the next (the second of a 32-bit one): from the code's memory, nearly always
    uint32_t hw1, hw2, offset = pc - c->code_base;
    if (__builtin_expect(offset >= c->code_words_end, 0)) {
        Region *r = find_region(c, pc);
        if (r && r->size >= 4) {
            c->code = r->bytes;
            c->code_base = r->base;
            c->code_words_end = r->size - 3;
            offset = pc - r->base;
        }
    }
    if (__builtin_expect(offset < c->code_words_end, 1)) {
        uint32_t word;
        memcpy(&word, c->code + offset, 4);
        hw1 = word & 0xFFFF;
        hw2 = word >> 16;
    } else {
        hw1 = fetch16(c, pc);
        hw2 = hw1 >= 0xE800 ? fetch16(c, pc + 2) : 0;
    }
    if (hw1 >= 0xE800) {
        c->next_pc = pc + 4;
        if (run) exec32(c, hw1, hw2);
    } else {
        c->next_pc = pc + 2;
        if (run) exec16(c, hw1);
    }
    if (in_block && !c->it_changed) it_advance(c);
    c->instructions++;
    if (c->stop_breakpoint) {
        c->stop_breakpoint = false;
        return CM4_BREAKPOINT;
    }
    c->r[15] = c->next_pc;
    c->cycles += (uint64_t)c->cost;
    if (c->locked_up) return CM4_LOCKUP;
    return CM4_RAN;
}

CM4Stop cm4_step(CM4 *c) {
    if (c->locked_up) return CM4_LOCKUP;
    if (c->sleeping) {
        if (!wakes(c)) return CM4_SLEEPING;
        c->sleeping = c->waiting_for_event = false;
    }
    return step(c);
}

CM4Stop cm4_run(CM4 *c, uint64_t cycles) {
    uint64_t end = c->cycles + cycles;
    if (c->deadline < end) end = c->deadline > c->cycles ? c->deadline : c->cycles;
    c->run_end = end;
    while (c->cycles < c->run_end) {
        end = c->run_end;
        if (c->locked_up) return CM4_LOCKUP;
        if (c->sleeping) {
            if (c->cycles >= c->systick_wrap) systick_update(c);
            if (wakes(c)) {
                c->sleeping = c->waiting_for_event = false;
                continue;
            }
            // nothing to do until SysTick or the end of the run
            uint64_t next = c->systick_wrap < end ? c->systick_wrap : end;
            c->cycles = next > c->cycles ? next : c->cycles;
            if (c->cycles >= end) return CM4_SLEEPING;
            continue;
        }
        CM4Stop stop = step(c);
        if (stop != CM4_RAN) return stop;
    }
    return CM4_RAN;
}

// ------------------------------------------------------------------------------------------------------------ API

CM4 *cm4_create(void) {
    CM4 *c = calloc(1, sizeof(CM4));
    if (!c) return NULL;
    c->interrupts = 240;
    c->priority_bits = 8;
    c->priority_mask = 0xFF;
    c->deadline = UINT64_MAX;
    c->systick_wrap = UINT64_MAX;
    c->ccr = 0x200;
    return c;
}

void cm4_destroy(CM4 *c) {
    if (!c) return;
    for (int i = 0; i < c->region_count; i++) if (c->regions[i].owned) free(c->regions[i].bytes);
    free(c);
}

uint8_t *cm4_add_memory(CM4 *c, uint32_t base, uint32_t size, bool writable) {
    if (c->region_count >= MAX_REGIONS) return NULL;
    uint8_t *bytes = calloc(1, size);
    if (!bytes) return NULL;
    c->regions[c->region_count] = (Region){base, size, bytes, writable, true};
    map_region(c, &c->regions[c->region_count++]);
    return bytes;
}

void cm4_alias(CM4 *c, uint32_t alias, uint32_t base) {
    if (c->region_count >= MAX_REGIONS) return;
    for (int i = 0; i < c->region_count; i++) {
        if (c->regions[i].base == base) {
            Region r = c->regions[i];
            r.base = alias;
            r.owned = false;
            c->regions[c->region_count] = r;
            map_region(c, &c->regions[c->region_count++]);
            return;
        }
    }
}

void cm4_set_io(CM4 *c, CM4Read read, CM4Write write, void *context) {
    c->io_read = read;
    c->io_write = write;
    c->io_context = context;
}

void cm4_configure(CM4 *c, int interrupts, int priority_bits) {
    c->interrupts = interrupts < 0 ? 0 : interrupts > 240 ? 240 : interrupts;
    c->priority_bits = priority_bits < 1 ? 1 : priority_bits > 8 ? 8 : priority_bits;
    c->priority_mask = (0xFFu << (8 - c->priority_bits)) & 0xFF;
}

void cm4_reset(CM4 *c) {
    memset(c->r, 0, sizeof(c->r));
    memset(c->s, 0, sizeof(c->s));
    c->n = c->z = c->c = c->v = c->q = c->ge = c->it = 0;
    c->ipsr = c->primask = c->faultmask = c->basepri = c->control = 0;
    c->other_sp = 0;
    memset(c->priority, 0, sizeof(c->priority));
    memset(c->pending, 0, sizeof(c->pending));
    memset(c->active, 0, sizeof(c->active));
    memset(c->enabled, 0, sizeof(c->enabled));
    c->vtor = c->prigroup = c->scr = c->shcsr = c->cfsr = c->hfsr = c->mmfar = c->bfar = 0;
    c->ccr = 0x200;
    c->cpacr = 0;
    c->fpccr = 0xC0000000u;
    c->fpcar = c->fpdscr = 0;
    c->fpscr = 0;
    c->systick_ctrl = 4;
    c->systick_load = c->systick_value = 0;
    c->systick_calib = 0x40000000u;
    c->systick_cycle = c->cycles;
    c->systick_wrap = UINT64_MAX;
    c->dwt_ctrl = 0x40000000u;
    c->demcr = 0;
    c->cyccnt_base = 0;
    c->sleeping = c->waiting_for_event = c->event = c->locked_up = c->exclusive = false;
    c->check_exceptions = false;
    c->stop_breakpoint = false;
    c->r[13] = read32(c, 0) & ~3u;
    c->r[15] = read32(c, 4) & ~1u;
    // lines still raised are pending again
    for (int i = EXC_IRQ0; i < 16 + c->interrupts; i++) if (c->level[i]) c->pending[i] = true;
}

uint64_t cm4_cycles(const CM4 *c) { return c->cycles; }
uint64_t cm4_instructions(const CM4 *c) { return c->instructions; }
void cm4_set_deadline(CM4 *c, uint64_t cycle) {
    c->deadline = cycle;
    // (from a peripheral during a run: the run stops there, after the instruction in progress)
    if (cycle < c->run_end) c->run_end = cycle > c->cycles ? cycle : c->cycles;
}

void cm4_set_irq(CM4 *c, int line, bool level) {
    if (line < 0 || line >= c->interrupts) return;
    int number = EXC_IRQ0 + line;
    c->level[number] = level;
    if (level) {
        c->pending[number] = true;
        c->check_exceptions = true;
    }
}

void cm4_send_event(CM4 *c) { c->event = true; }

uint32_t cm4_reg(const CM4 *c, int n) { return (n >= 0 && n < 16) ? c->r[n] : 0; }
void cm4_set_reg(CM4 *c, int n, uint32_t value) { if (n >= 0 && n < 16) c->r[n] = value; }

uint32_t cm4_xpsr(const CM4 *c) { return xpsr(c); }

void cm4_set_xpsr(CM4 *c, uint32_t value) {
    set_apsr(c, value);
    c->ge = (value >> 16) & 0xF;
    c->it = ((value >> 25) & 3) | (((value >> 10) & 0x3F) << 2);
    c->ipsr = value & 0x1FF;
}

uint32_t cm4_sreg(const CM4 *c, int n) { return (n >= 0 && n < 32) ? c->s[n] : 0; }
void cm4_set_sreg(CM4 *c, int n, uint32_t value) { if (n >= 0 && n < 32) c->s[n] = value; }
uint32_t cm4_fpscr(const CM4 *c) { return c->fpscr; }
void cm4_set_fpscr(CM4 *c, uint32_t value) { c->fpscr = value & FPSCR_WRITABLE; }

uint32_t cm4_special(const CM4 *c, int which) {
    switch (which) {
    case CM4_MSP: return msp(c);
    case CM4_PSP: return psp(c);
    case CM4_PRIMASK: return c->primask;
    case CM4_BASEPRI: return c->basepri;
    case CM4_FAULTMASK: return c->faultmask;
    case CM4_CONTROL: return c->control;
    default: return 0;
    }
}

void cm4_set_special(CM4 *c, int which, uint32_t value) {
    switch (which) {
    case CM4_MSP: if (using_psp(c)) c->other_sp = value; else c->r[13] = value; break;
    case CM4_PSP: if (using_psp(c)) c->r[13] = value; else c->other_sp = value; break;
    case CM4_PRIMASK: c->primask = value & 1; break;
    case CM4_BASEPRI: c->basepri = value & c->priority_mask; break;
    case CM4_FAULTMASK: c->faultmask = value & 1; break;
    case CM4_CONTROL: {
        bool was_process = using_psp(c);
        c->control = value & 7;
        select_sp(c, was_process, using_psp(c));
        break;
    }
    default: break;
    }
    c->check_exceptions = true;
}
