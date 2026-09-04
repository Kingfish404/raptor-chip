/* Directed RV32 PMP packing, WARL, lock, and configuration-CSR coverage. */
#include "test_common.h"

#define CSR_SCOUNTEREN 0x106
#define CSR_SENVCFG    0x10a
#define CSR_STIMECMP   0x14d
#define CSR_STIMECMPH  0x15d
#define CSR_MISA       0x301
#define CSR_MCOUNTEREN 0x306
#define CSR_MENVCFG    0x30a
#define CSR_MSTATUSH   0x310
#define CSR_MINSTRET   0xb02
#define CSR_MINSTRETH  0xb82
#define CSR_PMPCFG0    0x3a0
#define CSR_PMPCFG1    0x3a1
#define CSR_PMPCFG2    0x3a2
#define CSR_PMPCFG3    0x3a3
#define CSR_PMPADDR0   0x3b0
#define CSR_MVENDORID  0xf11
#define CSR_MIMPID     0xf13

void trap_handler(void)
{
    puts_("unexpected mcause=");
    put_hex32(csr_read(mcause));
    putc_('\n');
    test_fail("unexpected trap in PMP/CSR test");
}

static void write_pmp_addresses(void)
{
    for (unsigned i = 0; i < 16; i++) {
        /* CSR operands must be compile-time constants, hence the switch. */
        uint32_t value = 0x20000000u + i * 0x1000u;
        switch (i) {
#define WRITE_PMPADDR(n) case n: csr_write_num(CSR_PMPADDR0 + n, value); break
        WRITE_PMPADDR(0);  WRITE_PMPADDR(1);  WRITE_PMPADDR(2);  WRITE_PMPADDR(3);
        WRITE_PMPADDR(4);  WRITE_PMPADDR(5);  WRITE_PMPADDR(6);  WRITE_PMPADDR(7);
        WRITE_PMPADDR(8);  WRITE_PMPADDR(9);  WRITE_PMPADDR(10); WRITE_PMPADDR(11);
        WRITE_PMPADDR(12); WRITE_PMPADDR(13); WRITE_PMPADDR(14); WRITE_PMPADDR(15);
#undef WRITE_PMPADDR
        }
    }
}

int main(void)
{
    const uint32_t cfg0 = 0x1109001fu; /* NAPOT, OFF, TOR, NA4 */
    const uint32_t cfg1 = 0x11890019u; /* entry 6: locked TOR */
    const uint32_t cfg2 = 0x19110900u; /* OFF, TOR, NA4, NAPOT */
    const uint32_t cfg3 = 0x000f131du; /* RV32-only packed entries 12..15 */

    puts_("pmp_csr: start\n");
    write_pmp_addresses();

    /* Entry 0 is first-priority, all-memory NAPOT RWX, so later entries can
     * safely exercise every A-mode without restricting this test program. */
    csr_write_num(CSR_PMPADDR0, 0xffffffffu);
    csr_write_num(CSR_PMPCFG0, cfg0);
    csr_write_num(CSR_PMPCFG1, cfg1);
    csr_write_num(CSR_PMPCFG2, cfg2);
    csr_write_num(CSR_PMPCFG3, cfg3);

    TEST_ASSERT(csr_read_num(CSR_PMPCFG0) == cfg0, "pmpcfg0 readback");
    TEST_ASSERT(csr_read_num(CSR_PMPCFG1) == cfg1, "pmpcfg1 RV32 readback");
    TEST_ASSERT(csr_read_num(CSR_PMPCFG2) == cfg2, "pmpcfg2 readback");
    TEST_ASSERT(csr_read_num(CSR_PMPCFG3) == cfg3, "pmpcfg3 RV32 readback");

    /* Locked TOR entry 6 locks both its own address and entry 5's lower
     * bound. It also ignores later writes to its configuration byte. */
    uint32_t addr5 = csr_read_num(CSR_PMPADDR0 + 5);
    uint32_t addr6 = csr_read_num(CSR_PMPADDR0 + 6);
    csr_write_num(CSR_PMPADDR0 + 5, 0x11111111u);
    csr_write_num(CSR_PMPADDR0 + 6, 0x22222222u);
    csr_write_num(CSR_PMPCFG1, cfg1 ^ 0x00800000u);
    TEST_ASSERT(csr_read_num(CSR_PMPADDR0 + 5) == addr5, "TOR lower bound lock");
    TEST_ASSERT(csr_read_num(CSR_PMPADDR0 + 6) == addr6, "PMP self lock");
    TEST_ASSERT(csr_read_num(CSR_PMPCFG1) == cfg1, "PMP cfg lock");

    /* RV32-specific high halves and less frequently used config CSRs. */
    csr_write_num(CSR_SENVCFG, 0xffffffffu);
    TEST_ASSERT(csr_read_num(CSR_SENVCFG) == 0x000000f0u, "senvcfg WARL mask");
    csr_write_num(CSR_MENVCFG, 0xffffffffu);
    TEST_ASSERT(csr_read_num(CSR_MENVCFG) == 0x000000f0u, "menvcfg WARL mask");
    csr_write_num(CSR_MCOUNTEREN, 0xffffffffu);
    csr_write_num(CSR_SCOUNTEREN, 0xffffffffu);
    TEST_ASSERT(csr_read_num(CSR_MCOUNTEREN) == 7u, "mcounteren WARL mask");
    TEST_ASSERT(csr_read_num(CSR_SCOUNTEREN) == 7u, "scounteren WARL mask");
    csr_write_num(CSR_MSTATUSH, 0xffffffffu);
    TEST_ASSERT(csr_read_num(CSR_MSTATUSH) == 0, "mstatush endian WARL");
    TEST_ASSERT(csr_read_num(CSR_MISA) != 0, "misa configuration");
    csr_write_num(CSR_STIMECMP, 0x01234567u);
    csr_write_num(CSR_STIMECMPH, 0x89abcdefu);
    TEST_ASSERT(csr_read_num(CSR_STIMECMP) == 0x01234567u, "stimecmp low");
    TEST_ASSERT(csr_read_num(CSR_STIMECMPH) == 0x89abcdefu, "stimecmp high");

    csr_write_num(CSR_MINSTRETH, 0x12345678u);
    TEST_ASSERT(csr_read_num(CSR_MINSTRETH) == 0x12345678u, "minstreth write");
    csr_write_num(CSR_MINSTRET, 0u);
    (void)csr_read_num(CSR_MINSTRET); /* low half advances as instructions retire */
    TEST_ASSERT(csr_read_num(CSR_MVENDORID) == 0, "mvendorid");
    TEST_ASSERT(csr_read_num(CSR_MIMPID) == 0, "mimpid");

    test_pass();
    return 0;
}
