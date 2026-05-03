/* app/tests/irq/plic_threshold.c
 *
 * Source priority below context threshold must NOT raise MEIP.
 * Then drop the threshold and verify the IRQ does fire.
 */
#include "test_common.h"

#define SRC_ID 1u
#define CTX_M  0

static volatile int irq_count;

void trap_handler(void) {
    uint32_t cause = csr_read(mcause);
    if (cause != MCAUSE_M_EXT_INT) test_fail("mcause not M_EXT_INT");
    uint32_t id = MMIO32(PLIC_CLAIM(CTX_M));
    irq_count++;
    if (id != 0) MMIO32(PLIC_CLAIM(CTX_M)) = id;
}

int main(void) {
    puts_("plic_threshold: start\n");

    /* Phase 1: priority(2) <= threshold(3) -> blocked. */
    MMIO32(PLIC_PRIORITY(SRC_ID)) = 2;
    MMIO32(PLIC_THRESHOLD(CTX_M)) = 3;
    MMIO32(PLIC_ENABLE_W0(CTX_M)) = (1u << SRC_ID);

    csr_set(mie, MIE_MEIE);
    csr_set(mstatus, MSTATUS_MIE);

    MMIO32(PLIC_PENDING_W0) = (1u << SRC_ID);

    for (int i = 0; i < 50000; i++) __asm__ volatile ("nop");

    TEST_ASSERT(irq_count == 0, "IRQ fired despite threshold");
    TEST_ASSERT((csr_read(mip) & MIP_MEIP) == 0, "MEIP set despite threshold");

    /* Phase 2: lower threshold below priority -> IRQ should fire. */
    MMIO32(PLIC_THRESHOLD(CTX_M)) = 1;

    for (int i = 0; i < 50000 && irq_count == 0; i++) __asm__ volatile ("nop");

    TEST_ASSERT(irq_count == 1, "IRQ did not fire after threshold lowered");

    test_pass();
    return 0;
}
