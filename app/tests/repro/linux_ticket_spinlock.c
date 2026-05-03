/* app/tests/repro/linux_ticket_spinlock.c
 *
 * Minimal single-hart reproducer for the Linux RISC-V combo spinlock path
 * observed stuck at do_raw_spin_lock+0x80. The hot sequence is:
 *   amoadd.w.aqrl old, 0x10000, (lock)   // allocate ticket in high 16 bits
 *   lw lock                               // poll low 16-bit owner
 *   fence rw,w; sh owner+1, 0(lock)       // release ticket owner
 */
#include "test_common.h"

#define TICKET_SHIFT 16u
#define TICKET_INC   (1u << TICKET_SHIFT)
#define SPIN_LIMIT   10000u
#define ITERS        5000u
#define TIMER_DELTA  3u
#define PRESSURE_WORDS 64u

static volatile uint32_t ticket_lock_word __attribute__((aligned(4)));
static volatile uint16_t mmiowb_state_depth __attribute__((aligned(2)));
static volatile uint32_t store_pressure[PRESSURE_WORDS] __attribute__((aligned(64)));
static volatile uint32_t sink;
static volatile uint32_t timer_stress_enabled;
static volatile uint32_t timer_irq_count;
static uint8_t opensbi_scratch_area[1024] __attribute__((aligned(16)));

static uint64_t clint_mtime_read(void) {
    uint32_t hi0, lo, hi1;
    do {
        hi0 = MMIO32(CLINT_MTIME + 4);
        lo  = MMIO32(CLINT_MTIME);
        hi1 = MMIO32(CLINT_MTIME + 4);
    } while (hi0 != hi1);
    return ((uint64_t)hi1 << 32) | lo;
}

static void clint_mtimecmp_write(uint64_t value) {
    MMIO32(CLINT_MTIMECMP + 4) = 0xffffffffu;
    MMIO32(CLINT_MTIMECMP)     = (uint32_t)value;
    MMIO32(CLINT_MTIMECMP + 4) = (uint32_t)(value >> 32);
}

void trap_handler(void) {
    uint32_t cause = csr_read(mcause);
    if (timer_stress_enabled && cause == MCAUSE_M_TIMER_INT) {
        timer_irq_count++;
        clint_mtimecmp_write(clint_mtime_read() + TIMER_DELTA);
        return;
    }

    puts_("unexpected mcause=");
    put_hex32(cause);
    putc_('\n');
    test_fail("unexpected trap");
}

uint32_t *opensbi_like_trap_handler(uint32_t *ctx) {
    uint32_t cause = ctx[35];
    if (timer_stress_enabled && cause == MCAUSE_M_TIMER_INT) {
        timer_irq_count++;
        clint_mtimecmp_write(clint_mtime_read() + TIMER_DELTA);
        return ctx;
    }

    puts_("opensbi-like unexpected mcause=");
    put_hex32(cause);
    putc_('\n');
    test_fail("unexpected opensbi-like trap");
    return ctx;
}

__asm__(
"  .balign 4\n"
"  .globl opensbi_like_trap_entry\n"
"  .type  opensbi_like_trap_entry, @function\n"
"opensbi_like_trap_entry:\n"
"  csrrw tp, mscratch, tp\n"
"  sw    t0, 48(tp)\n"
"  csrr  t0, mstatus\n"
"  srli  t0, t0, 11\n"
"  andi  t0, t0, 3\n"
"  slti  t0, t0, 3\n"
"  addi  t0, t0, -1\n"
"  xor   sp, sp, tp\n"
"  and   t0, t0, sp\n"
"  xor   sp, sp, tp\n"
"  xor   t0, tp, t0\n"
"  sw    sp, -168(t0)\n"
"  addi  sp, t0, -176\n"
"  lw    t0, 48(tp)\n"
"  sw    t0, 20(sp)\n"
"  csrrw tp, mscratch, tp\n"
"  csrr  t0, mepc\n"
"  sw    t0, 128(sp)\n"
"  csrr  t0, mstatus\n"
"  sw    t0, 132(sp)\n"
"  sw    zero, 136(sp)\n"
"  sw    zero, 0(sp)\n"
"  sw    ra, 4(sp)\n"
"  sw    gp, 12(sp)\n"
"  sw    tp, 16(sp)\n"
"  sw    t1, 24(sp)\n"
"  sw    t2, 28(sp)\n"
"  sw    s0, 32(sp)\n"
"  sw    s1, 36(sp)\n"
"  sw    a0, 40(sp)\n"
"  sw    a1, 44(sp)\n"
"  sw    a2, 48(sp)\n"
"  sw    a3, 52(sp)\n"
"  sw    a4, 56(sp)\n"
"  sw    a5, 60(sp)\n"
"  sw    a6, 64(sp)\n"
"  sw    a7, 68(sp)\n"
"  sw    s2, 72(sp)\n"
"  sw    s3, 76(sp)\n"
"  sw    s4, 80(sp)\n"
"  sw    s5, 84(sp)\n"
"  sw    s6, 88(sp)\n"
"  sw    s7, 92(sp)\n"
"  sw    s8, 96(sp)\n"
"  sw    s9, 100(sp)\n"
"  sw    s10, 104(sp)\n"
"  sw    s11, 108(sp)\n"
"  sw    t3, 112(sp)\n"
"  sw    t4, 116(sp)\n"
"  sw    t5, 120(sp)\n"
"  sw    t6, 124(sp)\n"
"  csrr  t0, mcause\n"
"  sw    t0, 140(sp)\n"
"  csrr  t0, mtval\n"
"  sw    t0, 144(sp)\n"
"  sw    zero, 148(sp)\n"
"  sw    zero, 152(sp)\n"
"  sw    zero, 156(sp)\n"
"  mv    a0, sp\n"
"  call  opensbi_like_trap_handler\n"
"  lw    ra, 4(a0)\n"
"  lw    sp, 8(a0)\n"
"  lw    gp, 12(a0)\n"
"  lw    tp, 16(a0)\n"
"  lw    t1, 24(a0)\n"
"  lw    t2, 28(a0)\n"
"  lw    s0, 32(a0)\n"
"  lw    s1, 36(a0)\n"
"  lw    a1, 44(a0)\n"
"  lw    a2, 48(a0)\n"
"  lw    a3, 52(a0)\n"
"  lw    a4, 56(a0)\n"
"  lw    a5, 60(a0)\n"
"  lw    a6, 64(a0)\n"
"  lw    a7, 68(a0)\n"
"  lw    s2, 72(a0)\n"
"  lw    s3, 76(a0)\n"
"  lw    s4, 80(a0)\n"
"  lw    s5, 84(a0)\n"
"  lw    s6, 88(a0)\n"
"  lw    s7, 92(a0)\n"
"  lw    s8, 96(a0)\n"
"  lw    s9, 100(a0)\n"
"  lw    s10, 104(a0)\n"
"  lw    s11, 108(a0)\n"
"  lw    t3, 112(a0)\n"
"  lw    t4, 116(a0)\n"
"  lw    t5, 120(a0)\n"
"  lw    t6, 124(a0)\n"
"  lw    t0, 132(a0)\n"
"  csrw  mstatus, t0\n"
"  lw    t0, 128(a0)\n"
"  csrw  mepc, t0\n"
"  lw    t0, 20(a0)\n"
"  lw    a0, 40(a0)\n"
"  mret\n"
);

extern void opensbi_like_trap_entry(void);

static inline uint32_t linux_amoadd_ticket(volatile uint32_t *lock) {
    uint32_t old;
    __asm__ volatile (
        "amoadd.w.aqrl %0, %2, %1"
        : "=r"(old), "+A"(*lock)
        : "r"(TICKET_INC)
        : "memory");
    return old;
}

static inline void linux_cpu_relax(void) {
    __asm__ volatile (".word 0x0100000f" ::: "memory");
}

static inline uint32_t linux_irqsave(void) {
    uint32_t flags;

    __asm__ volatile ("csrrci %0, sstatus, 2" : "=r"(flags) :: "memory");
    return flags;
}

static inline void linux_irqrestore(uint32_t flags) {
    uint32_t sie = flags & MSTATUS_SIE;

    __asm__ volatile ("csrs sstatus, %0" :: "r"(sie) : "memory");
}

static inline void linux_ticket_unlock(volatile uint32_t *lock) {
    uint32_t value = *lock;
    uint32_t next_owner = (uint16_t)(value + 1u);

    __asm__ volatile (
        "fence rw,w\n"
        "sh %1, 0(%0)"
        :: "r"(lock), "r"(next_owner)
        : "memory");
}

static inline void linux_mmiowb_depth_inc(volatile uint16_t *depth) {
    uint32_t value;

    __asm__ volatile (
        "lhu %0, 0(%1)\n"
        "addi %0, %0, 1\n"
        "sh %0, 0(%1)"
        : "=&r"(value)
        : "r"(depth)
        : "memory");
}

static inline void linux_mmiowb_depth_dec(volatile uint16_t *depth) {
    uint32_t value;

    __asm__ volatile (
        "lhu %0, 0(%1)\n"
        "addi %0, %0, -1\n"
        "sh %0, 0(%1)"
        : "=&r"(value)
        : "r"(depth)
        : "memory");
}

static void dump_lock_state(const char *label, uint32_t iter, uint32_t old,
                            uint32_t current, uint32_t ticket) {
    puts_(label);
    puts_(" iter="); put_hex32(iter);
    puts_(" old="); put_hex32(old);
    puts_(" cur="); put_hex32(current);
    puts_(" ticket="); put_hex32(ticket);
    putc_('\n');
}

static void pressure_store_queue(uint32_t iter) {
    for (uint32_t i = 0; i < PRESSURE_WORDS; i++)
        store_pressure[(iter + i) & (PRESSURE_WORDS - 1u)] = iter ^ (i << 16);
}

static void ticket_lock_acquire(uint32_t iter) {
    uint32_t old = linux_amoadd_ticket(&ticket_lock_word);
    uint32_t ticket = old >> TICKET_SHIFT;
    uint32_t current = old;

    for (uint32_t spins = 0; ; spins++) {
        uint32_t owner = current & 0xffffu;
        if (owner == (ticket & 0xffffu))
            break;

        if (spins > SPIN_LIMIT) {
            dump_lock_state("ticket spin timeout", iter, old, current, ticket);
            test_fail("ticket owner did not advance");
        }

        linux_cpu_relax();
        current = ticket_lock_word;
    }

    __asm__ volatile ("fence r,r\nfence rw,rw" ::: "memory");
    linux_mmiowb_depth_inc(&mmiowb_state_depth);
}

static void check_halfword_unlock_visibility(void) {
    ticket_lock_word = 0x00320031u;
    sink = ticket_lock_word;

    linux_ticket_unlock(&ticket_lock_word);
    uint32_t current = ticket_lock_word;
    if (current != 0x00320032u) {
        dump_lock_state("bad sh visibility", 0, 0x00320031u, current, 0x32u);
        test_fail("halfword unlock not visible to lw");
    }

    ticket_lock_word = 0;
    sink = ticket_lock_word;
    if (sink != 0)
        test_fail("word clear not visible");
}

static void check_ticket_loop(void) {
    ticket_lock_word = 0;
    mmiowb_state_depth = 0;

    for (uint32_t i = 0; i < ITERS; i++) {
        ticket_lock_acquire(i);
        linux_mmiowb_depth_dec(&mmiowb_state_depth);
        linux_ticket_unlock(&ticket_lock_word);

        uint32_t current = ticket_lock_word;
        uint32_t owner = current & 0xffffu;
        uint32_t next = current >> TICKET_SHIFT;
        if (owner != next) {
            dump_lock_state("bad unlocked ticket", i, 0, current, next);
            test_fail("owner/next mismatch after unlock");
        }

        if (mmiowb_state_depth != 0) {
            dump_lock_state("bad mmiowb depth", i, 0, current, mmiowb_state_depth);
            test_fail("mmiowb depth mismatch");
        }
    }
}

static void check_unlock_reacquire_no_drain(void) {
    ticket_lock_word = 0;
    mmiowb_state_depth = 0;

    ticket_lock_acquire(0);
    linux_mmiowb_depth_dec(&mmiowb_state_depth);

    for (uint32_t i = 0; i < ITERS; i++) {
        pressure_store_queue(i);
        linux_ticket_unlock(&ticket_lock_word);

        uint32_t old = linux_amoadd_ticket(&ticket_lock_word);
        uint32_t ticket = old >> TICKET_SHIFT;
        uint32_t current = old;

        for (uint32_t spins = 0; ; spins++) {
            uint32_t owner = current & 0xffffu;
            if (owner == (ticket & 0xffffu))
                break;

            if (spins > SPIN_LIMIT) {
                dump_lock_state("reacquire spin timeout", i, old, current, ticket);
                test_fail("unlock/reacquire missed owner");
            }

            linux_cpu_relax();
            current = ticket_lock_word;
        }

        __asm__ volatile ("fence r,r\nfence rw,rw" ::: "memory");
        linux_mmiowb_depth_inc(&mmiowb_state_depth);
        linux_mmiowb_depth_dec(&mmiowb_state_depth);

        if (mmiowb_state_depth != 0) {
            dump_lock_state("reacquire bad mmiowb depth", i, old, current,
                            mmiowb_state_depth);
            test_fail("reacquire mmiowb depth mismatch");
        }
    }

    linux_ticket_unlock(&ticket_lock_word);

    uint32_t current = ticket_lock_word;
    uint32_t owner = current & 0xffffu;
    uint32_t next = current >> TICKET_SHIFT;
    if (owner != next) {
        dump_lock_state("reacquire bad final ticket", ITERS, 0, current, next);
        test_fail("reacquire final owner/next mismatch");
    }
}

static void check_ticket_loop_with_timer(void) {
    ticket_lock_word = 0;
    mmiowb_state_depth = 0;
    timer_irq_count = 0;

    csr_clear(mstatus, MSTATUS_MIE);
    csr_clear(mie, MIE_MTIE);
    clint_mtimecmp_write(clint_mtime_read() + TIMER_DELTA);
    timer_stress_enabled = 1;
    csr_set(mie, MIE_MTIE);
    csr_set(mstatus, MSTATUS_MIE);

    for (uint32_t i = 0; i < ITERS; i++) {
        ticket_lock_acquire(i);
        linux_mmiowb_depth_dec(&mmiowb_state_depth);
        linux_ticket_unlock(&ticket_lock_word);

        uint32_t current = ticket_lock_word;
        uint32_t owner = current & 0xffffu;
        uint32_t next = current >> TICKET_SHIFT;
        if (owner != next) {
            dump_lock_state("timer bad unlocked ticket", i, 0, current, next);
            test_fail("timer owner/next mismatch after unlock");
        }

        if (mmiowb_state_depth != 0) {
            dump_lock_state("timer bad mmiowb depth", i, 0, current, mmiowb_state_depth);
            test_fail("timer mmiowb depth mismatch");
        }
    }

    csr_clear(mstatus, MSTATUS_MIE);
    csr_clear(mie, MIE_MTIE);
    timer_stress_enabled = 0;
    clint_mtimecmp_write(~0ull);
    TEST_ASSERT(timer_irq_count != 0, "timer stress did not interrupt");
}

void s_mode_ticket_timer_entry(void) {
    puts_("linux_ticket_spinlock: s-mode timer stress\n");

    ticket_lock_word = 0;
    mmiowb_state_depth = 0;
    uint32_t start_irqs = timer_irq_count;

    for (uint32_t i = 0; i < ITERS; i++) {
        uint32_t flags = linux_irqsave();
        ticket_lock_acquire(i);
        linux_mmiowb_depth_dec(&mmiowb_state_depth);
        linux_ticket_unlock(&ticket_lock_word);
        linux_irqrestore(flags);

        uint32_t current = ticket_lock_word;
        uint32_t owner = current & 0xffffu;
        uint32_t next = current >> TICKET_SHIFT;
        if (owner != next) {
            dump_lock_state("s timer bad unlocked ticket", i, 0, current, next);
            test_fail("s timer owner/next mismatch after unlock");
        }

        if (mmiowb_state_depth != 0) {
            dump_lock_state("s timer bad mmiowb depth", i, 0, current, mmiowb_state_depth);
            test_fail("s timer mmiowb depth mismatch");
        }
    }

    TEST_ASSERT(timer_irq_count != start_irqs, "s-mode timer stress did not interrupt");
    test_pass();
}

static void enter_s_mode_timer_stress(void) {
    csr_clear(mstatus, MSTATUS_MIE);
    csr_clear(mie, MIE_MTIE);
    clint_mtimecmp_write(~0ull);

    csr_write(pmpaddr0, 0xffffffffu);
    csr_write(pmpcfg0, 0x0000001fu);

    timer_irq_count = 0;
    timer_stress_enabled = 1;
    clint_mtimecmp_write(clint_mtime_read() + TIMER_DELTA);
    csr_set(mie, MIE_MTIE);

    csr_write(mscratch, (uint32_t)(uintptr_t)&opensbi_scratch_area[768]);
    csr_write(mtvec, (uint32_t)(uintptr_t)opensbi_like_trap_entry);

    csr_write(mepc, (uint32_t)(uintptr_t)s_mode_ticket_timer_entry);
    csr_write(mstatus, (csr_read(mstatus) & ~MSTATUS_MPP_MASK) | MSTATUS_MPP_S);
    __asm__ volatile ("mret");

    test_fail("s-mode timer stress returned to M-mode");
}

int main(void) {
    puts_("linux_ticket_spinlock: start\n");
    check_halfword_unlock_visibility();
    check_ticket_loop();
    check_unlock_reacquire_no_drain();
    check_ticket_loop_with_timer();
    enter_s_mode_timer_stress();
    return 0;
}