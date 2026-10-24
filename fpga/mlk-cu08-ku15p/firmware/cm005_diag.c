#include <stdint.h>
#include "cm005_registers.h"

#define UART ((volatile uint8_t *)(uintptr_t)0x10000000u)
#define CSR(offset) (*(volatile uint32_t *)(uintptr_t)(0x18000000u + (offset)))

static void putc_uart(char c)
{
    while (!(UART[5] & 0x20)) {}
    UART[0] = (uint8_t)c;
}

static void puts_uart(const char *s)
{
    while (*s) putc_uart(*s++);
}

static void hex(uint32_t value)
{
    for (int shift = 28; shift >= 0; shift -= 4)
        putc_uart("0123456789abcdef"[(value >> shift) & 15]);
}

static void delay(void)
{
    unsigned long start, now;
    __asm__ volatile ("rdtime %0" : "=r" (start));
    do {
        __asm__ volatile ("rdtime %0" : "=r" (now));
    } while (now - start < 2);
}

static void mdio_bit(uint32_t address, uint32_t value)
{
    CSR(address) = value;
    __asm__ volatile ("fence iorw,iorw" ::: "memory");
    delay();
    CSR(address) = value | 1;
    __asm__ volatile ("fence iorw,iorw" ::: "memory");
    delay();
}

static uint32_t mdio_read(uint32_t w, uint32_t r, unsigned reg)
{
    for (int i = 0; i < 32; i++) mdio_bit(w, 6);
    /* Clause 22: ST=01, OP=10, PHYAD=00000, REGAD, TA=Z0, DATA. */
    uint32_t command = (6u << 10) | reg;
    for (int i = 13; i >= 0; i--) mdio_bit(w, 2 | (((command >> i) & 1) << 2));
    uint32_t value = 0;
    for (int i = 0; i < 18; i++) {
        CSR(w) = 0;
        __asm__ volatile ("fence iorw,iorw" ::: "memory");
        delay();
        /* Sample before the next rising edge advances the PHY's output. */
        value = (value << 1) | (CSR(r) & 1);
        CSR(w) = 1;
        __asm__ volatile ("fence iorw,iorw" ::: "memory");
        delay();
    }
    CSR(w) = 0;
    return value & 0xffff;
}

void cm005_diag(void)
{
    puts_uart("CM005_NATIVE_BEGIN\r\n");
    for (unsigned offset = 0; offset <= CM005_B_TO_A_QUEUED; offset += 4) {
        puts_uart("CSR "); hex(offset); putc_uart(' '); hex(CSR(offset));
        puts_uart("\r\n");
    }
    if (CSR(CM005_BRIDGE_ID) == 0x434d3035u) {
        for (unsigned port = 0; port < 2; port++) {
            unsigned w = port ? CM005_PHY_B_MDIO_W : CM005_PHY_A_MDIO_W;
            unsigned r = port ? CM005_PHY_B_MDIO_R : CM005_PHY_A_MDIO_R;
            for (unsigned reg = 0; reg <= 3; reg++) {
                if (reg == 1) (void)mdio_read(w, r, reg); /* Clear latched link-down. */
                puts_uart("PHY "); hex(port); putc_uart(' '); hex(reg); putc_uart(' ');
                hex(mdio_read(w, r, reg)); puts_uart("\r\n");
            }
        }
    }
    puts_uart("CM005_NATIVE_END\r\n");
    while (!(UART[5] & 0x40)) {}
}
