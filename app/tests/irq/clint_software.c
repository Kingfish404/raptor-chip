/* Directed CLINT register and machine-software-interrupt coverage. */
#include "test_common.h"

static volatile uint32_t software_irq_count;

void trap_handler(void)
{
    uint32_t cause = csr_read(mcause);
    if (cause != MCAUSE_M_SW_INT) {
        puts_("unexpected mcause=");
        put_hex32(cause);
        putc_('\n');
        test_fail("mcause not M_SW_INT");
    }

    software_irq_count++;
    MMIO32(CLINT_MSIP) = 0;
    csr_clear(mie, MIE_MSIE);
}

int main(void)
{
    const uint32_t cmp_lo = 0x89abcdefu;
    const uint32_t cmp_hi = 0x76543210u;

    puts_("clint_software: start\n");
    csr_clear(mstatus, MSTATUS_MIE);
    csr_clear(mie, MIE_MSIE);

    MMIO32(CLINT_MSIP) = 0;
    TEST_ASSERT(MMIO32(CLINT_MSIP) == 0, "MSIP reset readback");

    MMIO32(CLINT_MTIMECMP) = cmp_lo;
    MMIO32(CLINT_MTIMECMP + 4) = cmp_hi;
    TEST_ASSERT(MMIO32(CLINT_MTIMECMP) == cmp_lo, "mtimecmp low readback");
    TEST_ASSERT(MMIO32(CLINT_MTIMECMP + 4) == cmp_hi,
                "mtimecmp high readback");

    MMIO32(CLINT_MSIP) = 1;
    TEST_ASSERT(MMIO32(CLINT_MSIP) == 1, "MSIP set readback");
    TEST_ASSERT((csr_read(mip) & MIP_MSIP) != 0, "mip.MSIP not asserted");

    csr_set(mie, MIE_MSIE);
    csr_set(mstatus, MSTATUS_MIE);
    for (int i = 0; i < 100000 && software_irq_count == 0; i++)
        __asm__ volatile ("nop");

    TEST_ASSERT(software_irq_count == 1, "machine software IRQ never fired");
    TEST_ASSERT(MMIO32(CLINT_MSIP) == 0, "handler did not clear MSIP");
    TEST_ASSERT((csr_read(mip) & MIP_MSIP) == 0, "mip.MSIP still asserted");

    test_pass();
    return 0;
}
