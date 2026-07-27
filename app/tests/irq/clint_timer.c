/* app/tests/irq/clint_timer.c
 *
 * End-to-end CLINT timer flow after CLINT moved behind the cluster AXI router:
 * write mtimecmp through MMIO, observe mip.MTIP, take an M-timer interrupt,
 * then push mtimecmp forward and verify MTIP deasserts.
 */
#include "test_common.h"

static volatile int timer_count;

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
    if (cause != MCAUSE_M_TIMER_INT) {
        puts_("unexpected mcause=");
        put_hex32(cause);
        putc_('\n');
        test_fail("mcause not M_TIMER_INT");
    }

    timer_count++;
    clint_mtimecmp_write(clint_mtime_read() + 1000000u);
    csr_clear(mie, MIE_MTIE);
}

int main(void) {
    puts_("clint_timer: start\n");

    csr_clear(mstatus, MSTATUS_MIE);
    csr_clear(mie, MIE_MTIE);
    clint_mtimecmp_write(UINT64_MAX);

    for (int i = 0; i < 128; i++) __asm__ volatile ("nop");
    TEST_ASSERT((csr_read(mip) & MIP_MTIP) == 0, "MTIP set with max mtimecmp");

    clint_mtimecmp_write(clint_mtime_read() + 32u);
    csr_set(mie, MIE_MTIE);
    csr_set(mstatus, MSTATUS_MIE);

    for (int i = 0; i < 100000 && timer_count == 0; i++) {
        __asm__ volatile ("nop");
    }

    TEST_ASSERT(timer_count == 1, "M-timer IRQ never fired");
    TEST_ASSERT((csr_read(mip) & MIP_MTIP) == 0, "MTIP still asserted after handler");

    test_pass();
    return 0;
}