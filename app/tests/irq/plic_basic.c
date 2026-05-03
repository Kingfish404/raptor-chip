/* app/tests/irq/plic_basic.c
 *
 * End-to-end PLIC IRQ flow: configure source 1, raise it via the
 * SW pending-set extension, verify the M-mode external interrupt
 * fires, claim returns id 1, complete clears the IRQ.
 */
#include "test_common.h"

#define SRC_ID  1u
#define CTX_M   0   /* hart 0 M-mode */

static volatile int  irq_count;
static volatile uint32_t last_claim_id;

void trap_handler(void) {
    uint32_t cause = csr_read(mcause);
    if (cause != MCAUSE_M_EXT_INT) {
        puts_("unexpected mcause=");
        put_hex32(cause);
        putc_('\n');
        test_fail("mcause not M_EXT_INT");
    }
    /* Claim. */
    uint32_t id = MMIO32(PLIC_CLAIM(CTX_M));
    last_claim_id = id;
    if (id == 0) {
        test_fail("claim returned 0 inside trap");
    }
    irq_count++;
    /* Complete (write back same id). */
    MMIO32(PLIC_CLAIM(CTX_M)) = id;
}

int main(void) {
    puts_("plic_basic: start\n");

    /* 1. Reset PLIC config. */
    MMIO32(PLIC_PRIORITY(SRC_ID)) = 0;
    MMIO32(PLIC_THRESHOLD(CTX_M)) = 0;
    MMIO32(PLIC_ENABLE_W0(CTX_M)) = 0;
    /* (pending word is RW under the SW pending-set extension; nothing to clear
     *  yet — claim will clear after IRQ is taken). */

    /* 2. Sanity: claim with nothing pending returns 0. */
    {
        uint32_t id = MMIO32(PLIC_CLAIM(CTX_M));
        TEST_ASSERT(id == 0, "claim with no pending should be 0");
    }

    /* 3. Configure: priority=5, threshold=0, enable bit SRC_ID. */
    MMIO32(PLIC_PRIORITY(SRC_ID)) = 5;
    MMIO32(PLIC_THRESHOLD(CTX_M)) = 0;
    MMIO32(PLIC_ENABLE_W0(CTX_M)) = (1u << SRC_ID);

    /* Read-back checks. */
    TEST_ASSERT(MMIO32(PLIC_PRIORITY(SRC_ID)) == 5, "priority readback");
    TEST_ASSERT(MMIO32(PLIC_THRESHOLD(CTX_M)) == 0, "threshold readback");
    TEST_ASSERT((MMIO32(PLIC_ENABLE_W0(CTX_M)) & (1u << SRC_ID)) != 0,
                "enable readback");

    /* 4. Enable M-mode external interrupts. */
    csr_set(mie, MIE_MEIE);
    csr_set(mstatus, MSTATUS_MIE);

    /* 5. Raise the IRQ via SW pending-set. */
    MMIO32(PLIC_PENDING_W0) = (1u << SRC_ID);

    /* 6. Wait for the trap handler. Use a bounded loop. */
    for (int i = 0; i < 100000 && irq_count == 0; i++) {
        __asm__ volatile ("nop");
    }

    TEST_ASSERT(irq_count == 1, "external IRQ never fired");
    TEST_ASSERT(last_claim_id == SRC_ID, "claim returned wrong id");

    /* 7. After complete, claim should return 0 again. */
    {
        uint32_t id = MMIO32(PLIC_CLAIM(CTX_M));
        TEST_ASSERT(id == 0, "claim after complete should be 0");
    }

    /* 8. mip.MEIP should now be clear. */
    TEST_ASSERT((csr_read(mip) & MIP_MEIP) == 0, "MEIP still asserted");

    test_pass();
    return 0;
}
