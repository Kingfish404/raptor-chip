/*
 * Tiny I/O helpers for Raptor LiteX microbenchmarks.
 *
 * Everything inline so there's no linker graph to worry about.
 *   - putchar  -> LiteX sim UART at 0xf0001800 (TXFULL at 0xf0001804)
 *   - rdcycle  -> standard Zicntr cycle CSR (32-bit read pair for RV32)
 *   - print_*  -> minimal no-libc string/dec formatting
 */
#ifndef RAPTOR_LITEX_TESTS_IO_H
#define RAPTOR_LITEX_TESTS_IO_H

#include <stdint.h>

#define UART_RXTX    0xf0001800u
#define UART_TXFULL  0xf0001804u

static inline void putc_uart(char c) {
    volatile uint32_t *txfull = (volatile uint32_t *)UART_TXFULL;
    volatile uint32_t *rxtx   = (volatile uint32_t *)UART_RXTX;
    while (*txfull) { }
    *rxtx = (uint32_t)(unsigned char)c;
}

static inline void puts_uart(const char *s) {
    while (*s) putc_uart(*s++);
}

/* 64-bit cycle read via Zicntr cycleh:cycle. Robust against counter
 * roll-over at the 32-bit boundary. */
static inline uint64_t rdcycle64(void) {
    uint32_t hi1, lo, hi2;
    do {
        __asm__ volatile ("csrr %0, cycleh" : "=r"(hi1));
        __asm__ volatile ("csrr %0, cycle"  : "=r"(lo));
        __asm__ volatile ("csrr %0, cycleh" : "=r"(hi2));
    } while (hi1 != hi2);
    return ((uint64_t)hi2 << 32) | lo;
}

static inline void print_udec(uint64_t v) {
    char buf[24];
    int n = 0;
    if (v == 0) { putc_uart('0'); return; }
    while (v > 0 && n < (int)sizeof(buf)) {
        buf[n++] = '0' + (char)(v % 10);
        v /= 10;
    }
    while (n--) putc_uart(buf[n]);
}

static inline void print_hex32(uint32_t v) {
    static const char hex[] = "0123456789abcdef";
    putc_uart('0'); putc_uart('x');
    for (int i = 7; i >= 0; i--) {
        putc_uart(hex[(v >> (i * 4)) & 0xf]);
    }
}

static inline void print_cycles(const char *tag, uint64_t c) {
    puts_uart(tag);
    puts_uart(": ");
    print_udec(c);
    puts_uart(" cycles\n");
}

#endif /* RAPTOR_LITEX_TESTS_IO_H */
