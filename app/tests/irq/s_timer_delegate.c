/* app/tests/irq/s_timer_delegate.c
 *
 * OpenSBI-style S-timer delivery: M-mode injects mip.STIP, S-mode observes it
 * through sip/sie/mideleg and takes an S-mode timer interrupt.
 */
#include "test_common.h"

static volatile int s_timer_count;

void trap_handler(void) {
    puts_("unexpected mcause=");
    put_hex32(csr_read(mcause));
    putc_('\n');
    test_fail("unexpected M-mode trap");
}

void s_trap_handler(void) {
    uint32_t cause = csr_read(scause);
    if (cause != MCAUSE_S_TIMER_INT) {
        puts_("unexpected scause=");
        put_hex32(cause);
        putc_('\n');
        test_fail("scause not S_TIMER_INT");
    }

    s_timer_count++;
    csr_clear(sie, MIE_STIE);
}

__asm__(
"  .balign 4\n"
"  .globl s_trap_entry\n"
"  .type  s_trap_entry, @function\n"
"s_trap_entry:\n"
"  addi  sp, sp, -64\n"
"  sw    ra,  0(sp)\n"
"  sw    t0,  4(sp)\n"
"  sw    t1,  8(sp)\n"
"  sw    t2, 12(sp)\n"
"  sw    a0, 16(sp)\n"
"  sw    a1, 20(sp)\n"
"  sw    a2, 24(sp)\n"
"  sw    a3, 28(sp)\n"
"  sw    a4, 32(sp)\n"
"  sw    a5, 36(sp)\n"
"  sw    a6, 40(sp)\n"
"  sw    a7, 44(sp)\n"
"  sw    t3, 48(sp)\n"
"  sw    t4, 52(sp)\n"
"  sw    t5, 56(sp)\n"
"  sw    t6, 60(sp)\n"
"  call  s_trap_handler\n"
"  lw    ra,  0(sp)\n"
"  lw    t0,  4(sp)\n"
"  lw    t1,  8(sp)\n"
"  lw    t2, 12(sp)\n"
"  lw    a0, 16(sp)\n"
"  lw    a1, 20(sp)\n"
"  lw    a2, 24(sp)\n"
"  lw    a3, 28(sp)\n"
"  lw    a4, 32(sp)\n"
"  lw    a5, 36(sp)\n"
"  lw    a6, 40(sp)\n"
"  lw    a7, 44(sp)\n"
"  lw    t3, 48(sp)\n"
"  lw    t4, 52(sp)\n"
"  lw    t5, 56(sp)\n"
"  lw    t6, 60(sp)\n"
"  addi  sp, sp, 64\n"
"  sret\n"
);

extern void s_trap_entry(void);

void s_mode_entry(void) {
    TEST_ASSERT((csr_read(sip) & MIP_STIP) != 0, "STIP not visible in sip");

    csr_set(sie, MIE_STIE);
    csr_set(sstatus, MSTATUS_SIE);

    for (int i = 0; i < 100000 && s_timer_count == 0; i++) {
        __asm__ volatile ("nop");
    }

    TEST_ASSERT(s_timer_count == 1, "S timer IRQ never fired");
    test_pass();
}

int main(void) {
    puts_("s_timer_delegate: start\n");

    csr_clear(mstatus, MSTATUS_MIE);
    csr_clear(mie, MIE_STIE);
    csr_clear(mip, MIP_STIP);

    csr_write(pmpaddr0, 0xffffffffu);
    csr_write(pmpcfg0, 0x0000001fu);

    csr_set(mideleg, MIP_STIP);
    csr_set(mip, MIP_STIP);
    TEST_ASSERT((csr_read(sip) & MIP_STIP) != 0, "mip.STIP not reflected in sip");

    csr_write(stvec, (uint32_t)(uintptr_t)s_trap_entry);
    csr_write(mepc, (uint32_t)(uintptr_t)s_mode_entry);
    csr_write(mstatus, (csr_read(mstatus) & ~MSTATUS_MPP_MASK) | MSTATUS_MPP_S);

    __asm__ volatile ("mret");

    test_fail("mret returned to M-mode");
    return 0;
}