/* app/tests/irq/test_common.h: shared helpers for bare-metal IRQ tests. */
#ifndef _IRQ_TEST_COMMON_H
#define _IRQ_TEST_COMMON_H

#include <stdint.h>

/* ---- Platform addresses (raptor NPC SoC, see rapt_soc.svh). ---- */
#ifdef RAPT_LITEX_FPGA
#define UART_BASE 0xf0001800UL
#define UART_TXFULL (UART_BASE + 0x4UL)
#else
#define UART_BASE 0x10000000UL
#endif
#define UART_TX 0x0UL

#define FINISHER 0x00100000UL
#define FINISH_PASS 0x5555
#define FINISH_FAIL 0x3333

#define PLIC_BASE 0x0c000000UL
#define PLIC_PRIORITY(src) (PLIC_BASE + 4UL * (src))
#define PLIC_PENDING_W0 (PLIC_BASE + 0x001000UL)
#define PLIC_ENABLE_W0(ctx) (PLIC_BASE + 0x002000UL + 0x80UL * (ctx))
#define PLIC_THRESHOLD(ctx) (PLIC_BASE + 0x200000UL + 0x1000UL * (ctx))
#define PLIC_CLAIM(ctx) (PLIC_BASE + 0x200000UL + 0x1000UL * (ctx) + 4)

#define CLINT_BASE 0x02000000UL
#define CLINT_MSIP CLINT_BASE
#define CLINT_MTIMECMP (CLINT_BASE + 0x4000UL)
#define CLINT_MTIME (CLINT_BASE + 0xbff8UL)

#define MMIO32(a) (*(volatile uint32_t *)(uintptr_t)(a))
#define MMIO8(a) (*(volatile uint8_t *)(uintptr_t)(a))

/* ---- Tiny printer (UART byte poke). ---- */
static inline void putc_(char c) {
#ifdef RAPT_LITEX_FPGA
    while (MMIO32(UART_TXFULL)) { }
    MMIO32(UART_BASE + UART_TX) = (uint32_t)(uint8_t)c;
#else
    MMIO8(UART_BASE + UART_TX) = (uint8_t)c;
#endif
}

static inline void puts_(const char *s)
{
    while (*s)
        putc_(*s++);
}

static inline void put_hex32(uint32_t v)
{
    putc_('0');
    putc_('x');
    for (int i = 7; i >= 0; i--)
    {
        unsigned d = (v >> (i * 4)) & 0xf;
        putc_(d < 10 ? '0' + d : 'a' + (d - 10));
    }
}

/* ---- Test exit. ---- */
static inline void test_pass(void)
{
    puts_("PASS\n");
#ifndef RAPT_LITEX_FPGA
    MMIO32(FINISHER) = FINISH_PASS;
#endif
    while (1)
    __asm__ volatile ("wfi");
}

static inline void test_fail(const char *msg)
{
    puts_("FAIL: ");
    puts_(msg);
    putc_('\n');
#ifndef RAPT_LITEX_FPGA
    MMIO32(FINISHER) = FINISH_FAIL;
#endif
    while (1)
        __asm__ volatile ("wfi");
}

#define TEST_ASSERT(cond, msg) \
    do                         \
    {                          \
        if (!(cond))           \
            test_fail(msg);    \
    } while (0)

/* ---- M-mode CSR helpers. ---- */
#define csr_read(reg) ({ uint32_t v; \
    __asm__ volatile ("csrr %0, " #reg : "=r"(v)); v; })
#define csr_write(reg, v) \
    __asm__ volatile("csrw " #reg ", %0" ::"r"((uint32_t)(v)))
#define csr_set(reg, v) \
    __asm__ volatile("csrs " #reg ", %0" ::"r"((uint32_t)(v)))
#define csr_clear(reg, v) \
    __asm__ volatile("csrc " #reg ", %0" ::"r"((uint32_t)(v)))
#define csr_read_num(csr_num) ({ uint32_t v; \
    __asm__ volatile ("csrr %0, %1" : "=r"(v) : "i"(csr_num)); v; })
#define csr_write_num(csr_num, v) \
    __asm__ volatile ("csrw %0, %1" :: "i"(csr_num), "r"((uint32_t)(v)))

/* mstatus bits */
#define MSTATUS_SIE (1u << 1)
#define MSTATUS_MIE (1u << 3)
#define MSTATUS_SPP (1u << 8)
#define MSTATUS_MPRV (1u << 17)
#define MSTATUS_MPP_MASK (3u << 11)
#define MSTATUS_MPP_U (0u << 11)
#define MSTATUS_MPP_S (1u << 11)
/* mie / mip bits */
#define MIE_STIE (1u << 5)
#define MIE_MSIE (1u << 3)
#define MIE_MEIE (1u << 11)
#define MIE_MTIE (1u << 7)
#define MIP_STIP (1u << 5)
#define MIP_MSIP (1u << 3)
#define MIP_MEIP (1u << 11)
#define MIP_MTIP (1u << 7)

/* mcause: interrupt bit + code */
#define MCAUSE_INT_BIT (1u << 31)
#define MCAUSE_M_SW_INT (MCAUSE_INT_BIT | 3u)
#define MCAUSE_S_TIMER_INT (MCAUSE_INT_BIT | 5u)
#define MCAUSE_M_EXT_INT (MCAUSE_INT_BIT | 11u)
#define MCAUSE_M_TIMER_INT (MCAUSE_INT_BIT | 7u)

#endif
