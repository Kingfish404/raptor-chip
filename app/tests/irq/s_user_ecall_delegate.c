/* app/tests/irq/s_user_ecall_delegate.c
 *
 * Regression for delegated U-mode traps: when a U-mode exception is delegated
 * to S-mode, hardware must write sstatus.SPP=0. A stale SPP=1 would make the
 * S-mode handler's sret return to S instead of U.
 */
#include "test_common.h"

#define MCAUSE_U_ECALL 8u
#define MCAUSE_S_ECALL 9u

static volatile uint32_t s_ecall_count;
static volatile uint32_t m_ecall_count;

void user_entry(void);

void trap_handler(void) {
    uint32_t cause = csr_read(mcause);
    uint32_t status = csr_read(mstatus);

    if (m_ecall_count == 0 && cause == MCAUSE_U_ECALL) {
        TEST_ASSERT((status & MSTATUS_MPRV) == 0, "mret did not clear MPRV");
        TEST_ASSERT((status & MSTATUS_MPP_MASK) == MSTATUS_MPP_U, "U ecall did not save MPP=U");

        m_ecall_count++;
        csr_set(medeleg, (1u << MCAUSE_U_ECALL) | (1u << MCAUSE_S_ECALL));
        csr_set(mstatus, MSTATUS_SPP);
        csr_write(mepc, csr_read(mepc) + 4);
        return;
    }

    puts_("unexpected M trap mcause=");
    put_hex32(cause);
    puts_(" mstatus=");
    put_hex32(status);
    putc_('\n');
    test_fail("unexpected M-mode trap");
}

void s_trap_handler(void) {
    uint32_t cause = csr_read(scause);
    uint32_t status = csr_read(sstatus);

    if (cause != MCAUSE_U_ECALL) {
        puts_("unexpected S trap scause=");
        put_hex32(cause);
        puts_(" sstatus=");
        put_hex32(status);
        putc_('\n');
        if (cause == MCAUSE_S_ECALL) test_fail("sret returned to S-mode");
        test_fail("expected delegated U ecall");
    }

    TEST_ASSERT((status & MSTATUS_SPP) == 0, "delegated U trap did not clear SPP");

    s_ecall_count++;
    if (s_ecall_count == 257) test_pass();

    csr_write(sepc, csr_read(sepc) + 4);
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

__asm__(
"  .balign 4\n"
"  .globl user_entry\n"
"  .type  user_entry, @function\n"
"user_entry:\n"
"  ecall\n"
"  j user_s_stage\n"
"user_s_stage:\n"
"  li    t0, 257\n"
"2:\n"
"  li    a0, 1\n"
"  li    a1, 0x111dc\n"
"  li    a2, 1\n"
"  li    a7, 64\n"
"  ecall\n"
"  addi  t0, t0, -1\n"
"  bnez  t0, 2b\n"
"1:\n"
"  j 1b\n"
);

int main(void) {
    puts_("s_user_ecall_delegate: start\n");

    csr_write(pmpaddr0, 0xffffffffu);
    csr_write(pmpcfg0, 0x0000001fu);

    csr_write(stvec, (uint32_t)(uintptr_t)s_trap_entry);
    csr_clear(medeleg, (1u << MCAUSE_U_ECALL) | (1u << MCAUSE_S_ECALL));

    uint32_t mstatus = csr_read(mstatus);
    mstatus &= ~MSTATUS_MPP_MASK;
    mstatus |= MSTATUS_MPP_U | MSTATUS_SPP | MSTATUS_MPRV;
    csr_write(mstatus, mstatus);
    TEST_ASSERT((csr_read(mstatus) & MSTATUS_SPP) != 0, "failed to pre-set SPP");
    TEST_ASSERT((csr_read(mstatus) & MSTATUS_MPRV) != 0, "failed to pre-set MPRV");

    csr_write(mepc, (uint32_t)(uintptr_t)user_entry);
    __asm__ volatile ("mret");

    test_fail("mret returned to M-mode");
    return 0;
}