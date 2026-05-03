/* app/tests/irq/plic_priority.c
 *
 * Two simultaneously-pending sources at different priorities: claim must
 * return the higher-priority one first.
 */
#include "test_common.h"

#define SRC_LO   1u   /* priority 3 */
#define SRC_HI   2u   /* priority 7 */
#define CTX_M    0

static volatile int  irq_count;
static volatile uint32_t claim_seq[4];

void trap_handler(void) {
    uint32_t cause = csr_read(mcause);
    if (cause != MCAUSE_M_EXT_INT) test_fail("mcause not M_EXT_INT");
    uint32_t id = MMIO32(PLIC_CLAIM(CTX_M));
    if (irq_count < 4) claim_seq[irq_count] = id;
    irq_count++;
    if (id != 0) MMIO32(PLIC_CLAIM(CTX_M)) = id;
    if (id == 0) {
        /* Spurious wake — disable to break the loop. */
        csr_clear(mstatus, MSTATUS_MIE);
    }
}

int main(void) {
    puts_("plic_priority: start\n");

    MMIO32(PLIC_PRIORITY(SRC_LO)) = 3;
    MMIO32(PLIC_PRIORITY(SRC_HI)) = 7;
    MMIO32(PLIC_THRESHOLD(CTX_M)) = 0;
    MMIO32(PLIC_ENABLE_W0(CTX_M)) = (1u << SRC_LO) | (1u << SRC_HI);

    csr_set(mie, MIE_MEIE);
    csr_set(mstatus, MSTATUS_MIE);

    /* Raise both at once. */
    MMIO32(PLIC_PENDING_W0) = (1u << SRC_LO) | (1u << SRC_HI);

    /* Expect two consecutive trap entries: HI first, then LO. */
    for (int i = 0; i < 200000 && irq_count < 2; i++) {
        __asm__ volatile ("nop");
    }

    TEST_ASSERT(irq_count >= 2, "did not take two external IRQs");
    TEST_ASSERT(claim_seq[0] == SRC_HI, "first claim was not high-priority src");
    TEST_ASSERT(claim_seq[1] == SRC_LO, "second claim was not low-priority src");

    test_pass();
    return 0;
}
