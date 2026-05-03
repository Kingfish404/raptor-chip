/* app/tests/irq/u_ptw_ecall.c
 *
 * Focused Sv32 regression: enter U-mode with page tables enabled, touch a
 * non-identity virtual alias through the hardware PTW, ecall to M-mode, then
 * return to U-mode and verify M-mode physical writes are visible through the
 * alias mapping.
 */
#include "test_common.h"

#define MCAUSE_U_ECALL 8u

#define SATP_MODE_SV32 (1u << 31)
#define PTE_V          (1u << 0)
#define PTE_R          (1u << 1)
#define PTE_W          (1u << 2)
#define PTE_X          (1u << 3)
#define PTE_U          (1u << 4)
#define PTE_A          (1u << 6)
#define PTE_D          (1u << 7)
#define PTE_RWXUAD     (PTE_V | PTE_R | PTE_W | PTE_X | PTE_U | PTE_A | PTE_D)

#define USER_ALIAS     0x40000000u

static uint32_t root_pt[1024] __attribute__((aligned(4096)));
static uint32_t alias_leaf_pt[1024] __attribute__((aligned(4096)));
static volatile uint32_t alias_page[1024] __attribute__((aligned(4096)));
static volatile uint32_t m_ecall_count;

static uint32_t pte_of(uint32_t paddr, uint32_t flags) {
    return ((paddr >> 12) << 10) | flags;
}

static void map_superpage(uint32_t vaddr, uint32_t paddr) {
    root_pt[vaddr >> 22] = pte_of(paddr, PTE_RWXUAD);
}

static void setup_page_tables(void) {
    for (int i = 0; i < 1024; i++) {
        root_pt[i] = 0;
        alias_leaf_pt[i] = 0;
    }

    map_superpage(0x80000000u, 0x80000000u);
    map_superpage(0x80400000u, 0x80400000u);
    map_superpage(0x80800000u, 0x80800000u);
    map_superpage(0x80c00000u, 0x80c00000u);

    root_pt[USER_ALIAS >> 22] = pte_of((uint32_t)(uintptr_t)alias_leaf_pt, PTE_V);
    alias_leaf_pt[(USER_ALIAS >> 12) & 0x3ff] =
        pte_of((uint32_t)(uintptr_t)alias_page, PTE_RWXUAD);
}

void user_entry(void) {
    volatile uint32_t *alias = (volatile uint32_t *)(uintptr_t)USER_ALIAS;

    alias[0] = 0x11223344u;
    __asm__ volatile ("ecall");

    if (alias[2] == 0xa5a55a5au) {
        alias[1] = 0x55667788u;
    } else {
        alias[1] = 0xdeaddeadu;
    }
    __asm__ volatile ("ecall");

    while (1) {
        __asm__ volatile ("wfi");
    }
}

void trap_handler(void) {
    uint32_t cause = csr_read(mcause);
    uint32_t status = csr_read(mstatus);

    if (cause != MCAUSE_U_ECALL) {
        puts_("unexpected mcause=");
        put_hex32(cause);
        putc_('\n');
        test_fail("expected U ecall");
    }
    TEST_ASSERT((status & MSTATUS_MPP_MASK) == MSTATUS_MPP_U,
                "U ecall did not save MPP=U");

    m_ecall_count++;
    if (m_ecall_count == 1) {
        TEST_ASSERT(alias_page[0] == 0x11223344u,
                    "U store through PTW alias not visible in M");
        alias_page[2] = 0xa5a55a5au;
        csr_write(mepc, csr_read(mepc) + 4);
        return;
    }

    if (m_ecall_count == 2) {
        TEST_ASSERT(alias_page[1] == 0x55667788u,
                    "U load after M write through PTW alias failed");
        test_pass();
    }

    test_fail("too many U ecalls");
}

int main(void) {
    puts_("u_ptw_ecall: start\n");

    csr_write(pmpaddr0, 0xffffffffu);
    csr_write(pmpcfg0, 0x0000001fu);

    setup_page_tables();
    csr_write(satp, SATP_MODE_SV32 | ((uint32_t)(uintptr_t)root_pt >> 12));
    __asm__ volatile ("sfence.vma zero, zero" ::: "memory");

    csr_write(mepc, (uint32_t)(uintptr_t)user_entry);
    csr_write(mstatus, (csr_read(mstatus) & ~MSTATUS_MPP_MASK) | MSTATUS_MPP_U);
    __asm__ volatile ("mret");

    test_fail("mret returned to M-mode");
    return 0;
}