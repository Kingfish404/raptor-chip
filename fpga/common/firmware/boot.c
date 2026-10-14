#include <stdint.h>
#include "native_map.h"

#define UART ((volatile uint8_t *)(uintptr_t)UART_BASE)
#define CHUNK_LIMIT 4096u

static void putc_uart(uint8_t c)
{
    while (!(UART[5] & 0x20)) {}
    UART[0] = c;
}

static void puts_uart(const char *s)
{
    while (*s) putc_uart((uint8_t)*s++);
}

static uint32_t ticks(void)
{
    unsigned long value;
    __asm__ volatile ("rdtime %0" : "=r" (value));
    return (uint32_t)value;
}

static int getbyte(int timeout)
{
    uint32_t start = ticks();
    while (!(UART[5] & 1)) {
        if (timeout && (uint32_t)(ticks() - start) >= 2000000u) return -1;
    }
    return UART[0];
}

static uint32_t crc_byte(uint32_t crc, uint8_t value)
{
    crc ^= value;
    for (int i = 0; i < 8; i++) crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1)));
    return crc;
}

static int ram_range(uint32_t addr, uint32_t count)
{
    return count != 0 && addr >= RAM_BASE && count <= RAM_BYTES &&
           addr - RAM_BASE <= RAM_BYTES - count;
}

static uint32_t word(const uint8_t *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static void hex(unsigned long value)
{
    for (int i = (int)sizeof(value) * 2 - 1; i >= 0; i--)
        putc_uart("0123456789abcdef"[(value >> (i * 4)) & 15]);
}

void boot_trap(unsigned long cause, unsigned long pc, unsigned long address)
{
    puts_uart("\r\nBOOT TRAP cause=");
    hex(cause);
    puts_uart(" pc=");
    hex(pc);
    puts_uart(" addr=");
    hex(address);
    puts_uart("\r\n");
    for (;;) __asm__ volatile ("wfi");
}

extern void boot_jump(uintptr_t entry, uintptr_t dtb) __attribute__((noreturn));

void boot_main(void)
{
    UART[1] = 0;
    UART[3] = 0x80;
    UART[0] = UART_DIVISOR & 255;
    UART[1] = UART_DIVISOR >> 8;
    UART[3] = 3;
    UART[2] = 6;
    puts_uart("Raptor native " NATIVE_BOARD_STRING " RV" NATIVE_XLEN_STRING "\r\nRAPT ready\r\n");
    for (;;) {
        // Framing resynchronizes on the next RAPT marker after a timeout/error.
        static const char magic[] = "RAPT";
        unsigned matched = 0;
        while (matched < 4) {
            int c = getbyte(0);
            matched = c == magic[matched] ? matched + 1 : (c == 'R' ? 1 : 0);
        }
        uint8_t h[13];
        unsigned i;
        for (i = 0; i < sizeof(h); i++) {
            int c = getbyte(1);
            if (c < 0) break;
            h[i] = (uint8_t)c;
        }
        uint8_t error = 0;
        if (i != sizeof(h)) error = 1;
        else {
            uint32_t addr = word(h + 1), count = word(h + 5), expected = word(h + 9);
            if (h[0] == 1) {
                if (!ram_range(addr, count) || count > CHUNK_LIMIT) error = 2;
                else {
                    volatile uint8_t *dest = (volatile uint8_t *)(uintptr_t)addr;
                    uint32_t crc = ~0u;
                    for (i = 0; i < count; i++) {
                        int c = getbyte(1);
                        if (c < 0) break;
                        dest[i] = (uint8_t)c;
                        crc = crc_byte(crc, (uint8_t)c);
                    }
                    if (i != count) error = 1;
                    else if (~crc != expected) error = 3;
                }
            } else if (h[0] == 2) {
                // count carries the DTB physical address for the GO command.
                if ((addr & 1) || !ram_range(addr, 4) ||
                    (count != 0 && ((count & 7) || !ram_range(count, 40)))) error = 2;
                else {
                    putc_uart('K');
                    while (!(UART[5] & 0x40)) {}
                    boot_jump((uintptr_t)addr, (uintptr_t)count);
                }
            } else if (h[0] == 3) {
                if ((addr & 3) || (count & 3) || !ram_range(addr, count)) error = 2;
                else {
                    volatile uint32_t *dest = (volatile uint32_t *)(uintptr_t)addr;
                    for (uint32_t pass = 0; pass < 2; pass++) {
                        for (i = 0; i < count / 4; i++) dest[i] = (addr + i * 4) ^ (pass ? ~0u : 0u);
                        __asm__ volatile ("fence rw,rw" ::: "memory");
                        for (i = 0; i < count / 4; i++)
                            if (dest[i] != ((addr + i * 4) ^ (pass ? ~0u : 0u))) error = 4;
                    }
                }
            } else error = 5;
        }
        if (error) {
            putc_uart('E');
            putc_uart(error);
        } else putc_uart('K');
    }
}
