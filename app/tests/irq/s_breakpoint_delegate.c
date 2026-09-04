/* Directed S-mode breakpoint delegation and SPP/sepc state coverage. */
#include "test_common.h"

#define MCAUSE_BREAKPOINT 3u

static volatile uint32_t breakpoint_count;

void trap_handler(void)
{
    puts_("unexpected M-mode mcause=");
    put_hex32(csr_read(mcause));
    putc_('\n');
    test_fail("breakpoint was not delegated");
}

void s_trap_handler(void)
{
    uint32_t cause = csr_read(scause);
    uint32_t status = csr_read(sstatus);

    TEST_ASSERT(cause == MCAUSE_BREAKPOINT, "scause not breakpoint");
    TEST_ASSERT((status & MSTATUS_SPP) != 0, "S breakpoint did not save SPP=1");
    breakpoint_count++;
    csr_write(sepc, csr_read(sepc) + 4);
}

__asm__(
"  .balign 4\n"
"  .globl s_trap_entry\n"
"s_trap_entry:\n"
"  addi sp, sp, -16\n"
"  sw   ra, 0(sp)\n"
"  sw   a0, 4(sp)\n"
"  sw   a1, 8(sp)\n"
"  sw   a2, 12(sp)\n"
"  call s_trap_handler\n"
"  lw   ra, 0(sp)\n"
"  lw   a0, 4(sp)\n"
"  lw   a1, 8(sp)\n"
"  lw   a2, 12(sp)\n"
"  addi sp, sp, 16\n"
"  sret\n"
);

extern void s_trap_entry(void);

void s_mode_entry(void)
{
    /* Emit the uncompressed four-byte instruction because the handler advances
     * sepc by four bytes. */
    __asm__ volatile (".word 0x00100073");
    TEST_ASSERT(breakpoint_count == 1, "delegated breakpoint handler count");
    test_pass();
}

int main(void)
{
    puts_("s_breakpoint_delegate: start\n");

    csr_write(pmpaddr0, 0xffffffffu);
    csr_write(pmpcfg0, 0x0000001fu);
    csr_set(medeleg, 1u << MCAUSE_BREAKPOINT);
    csr_write(stvec, (uint32_t)(uintptr_t)s_trap_entry);
    csr_write(mepc, (uint32_t)(uintptr_t)s_mode_entry);
    csr_write(mstatus,
              (csr_read(mstatus) & ~MSTATUS_MPP_MASK) | MSTATUS_MPP_S);
    __asm__ volatile ("mret");

    test_fail("mret returned to M-mode");
    return 0;
}
