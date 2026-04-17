/* ============================================================================
 * minilib.c: Minimal freestanding libc for CoreMark on LiteX
 *
 * Provides: ee_printf (via UART CSR), memcpy, memset, memcmp, strlen
 * No external dependencies beyond GCC freestanding headers.
 * ============================================================================ */

#include <stdint.h>
#include <stddef.h>
#include <stdarg.h>

/* ---- LiteX UART CSR (memory-mapped) ----
 * Default LiteX CSR base = 0xf0000000, UART is typically the first peripheral.
 * CSR registers are 32-bit aligned, 8-bit values in bits [7:0].
 *
 * These addresses match the default LiteX SoC configuration.
 * If your SoC has different CSR layout, override UART_BASE via -D flag.
 */
#ifndef UART_BASE
#define UART_BASE 0xf0001800UL
#endif

#define UART_RXTX   (*(volatile uint32_t *)(UART_BASE + 0x00))
#define UART_TXFULL  (*(volatile uint32_t *)(UART_BASE + 0x04))
#define UART_RXEMPTY (*(volatile uint32_t *)(UART_BASE + 0x08))

static void uart_putc(char c)
{
    while (UART_TXFULL)
        ;
    UART_RXTX = (uint32_t)(unsigned char)c;
}

static void uart_puts(const char *s)
{
    while (*s) {
        if (*s == '\n')
            uart_putc('\r');
        uart_putc(*s++);
    }
}

/* ---- Minimal printf ----
 * Supports: %d, %u, %x, %X, %p, %s, %c, %f (simple), %l (long), %% */

static void print_uint(unsigned long val, int base, int uppercase, int width, char pad)
{
    char buf[20];
    int i = 0;
    const char *digits = uppercase ? "0123456789ABCDEF" : "0123456789abcdef";

    if (val == 0) {
        buf[i++] = '0';
    } else {
        while (val) {
            buf[i++] = digits[val % base];
            val /= base;
        }
    }
    while (i < width)
        buf[i++] = pad;
    while (i--)
        uart_putc(buf[i]);
}

static void print_int(long val, int width, char pad)
{
    if (val < 0) {
        uart_putc('-');
        val = -val;
        if (width > 0) width--;
    }
    print_uint((unsigned long)val, 10, 0, width, pad);
}

/* Simple fixed-point %f: 6 decimal places */
static void print_float(double val)
{
    if (val < 0) {
        uart_putc('-');
        val = -val;
    }
    unsigned long integer = (unsigned long)val;
    print_uint(integer, 10, 0, 0, '0');
    uart_putc('.');

    double frac = val - (double)integer;
    for (int i = 0; i < 6; i++) {
        frac *= 10.0;
        int d = (int)frac;
        uart_putc('0' + d);
        frac -= d;
    }
}

int ee_printf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    int count = 0;

    while (*fmt) {
        if (*fmt != '%') {
            if (*fmt == '\n')
                uart_putc('\r');
            uart_putc(*fmt++);
            count++;
            continue;
        }
        fmt++; /* skip '%' */

        /* Parse width and padding */
        char pad = ' ';
        int width = 0;
        if (*fmt == '0') {
            pad = '0';
            fmt++;
        }
        while (*fmt >= '0' && *fmt <= '9') {
            width = width * 10 + (*fmt - '0');
            fmt++;
        }

        /* Parse length modifier */
        int is_long = 0;
        if (*fmt == 'l') {
            is_long = 1;
            fmt++;
            if (*fmt == 'l') { /* %llu etc. — treat same as long on RV32 */
                fmt++;
            }
        }

        switch (*fmt) {
        case 'd':
        case 'i': {
            long val = is_long ? va_arg(ap, long) : (long)va_arg(ap, int);
            print_int(val, width, pad);
            break;
        }
        case 'u': {
            unsigned long val = is_long ? va_arg(ap, unsigned long) : (unsigned long)va_arg(ap, unsigned int);
            print_uint(val, 10, 0, width, pad);
            break;
        }
        case 'x': {
            unsigned long val = is_long ? va_arg(ap, unsigned long) : (unsigned long)va_arg(ap, unsigned int);
            print_uint(val, 16, 0, width, pad);
            break;
        }
        case 'X': {
            unsigned long val = is_long ? va_arg(ap, unsigned long) : (unsigned long)va_arg(ap, unsigned int);
            print_uint(val, 16, 1, width, pad);
            break;
        }
        case 'p': {
            uart_putc('0'); uart_putc('x');
            unsigned long val = (unsigned long)va_arg(ap, void *);
            print_uint(val, 16, 0, sizeof(void *) * 2, '0');
            break;
        }
        case 's': {
            const char *s = va_arg(ap, const char *);
            if (!s) s = "(null)";
            uart_puts(s);
            break;
        }
        case 'c': {
            char c = (char)va_arg(ap, int);
            uart_putc(c);
            break;
        }
        case 'f': {
            double val = va_arg(ap, double);
            print_float(val);
            break;
        }
        case '%':
            uart_putc('%');
            break;
        default:
            uart_putc('%');
            uart_putc(*fmt);
            break;
        }
        fmt++;
        count++;
    }

    va_end(ap);
    return count;
}

/* ---- String/memory functions ---- */

void *memcpy(void *dst, const void *src, size_t n)
{
    uint8_t *d = (uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;
    while (n--)
        *d++ = *s++;
    return dst;
}

void *memset(void *dst, int c, size_t n)
{
    uint8_t *d = (uint8_t *)dst;
    while (n--)
        *d++ = (uint8_t)c;
    return dst;
}

int memcmp(const void *s1, const void *s2, size_t n)
{
    const uint8_t *a = (const uint8_t *)s1;
    const uint8_t *b = (const uint8_t *)s2;
    while (n--) {
        if (*a != *b)
            return *a - *b;
        a++;
        b++;
    }
    return 0;
}

void *memmove(void *dst, const void *src, size_t n)
{
    uint8_t *d = (uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;
    if (d < s) {
        while (n--)
            *d++ = *s++;
    } else {
        d += n;
        s += n;
        while (n--)
            *--d = *--s;
    }
    return dst;
}

size_t strlen(const char *s)
{
    const char *p = s;
    while (*p) p++;
    return (size_t)(p - s);
}

int strcmp(const char *s1, const char *s2)
{
    while (*s1 && *s1 == *s2) {
        s1++;
        s2++;
    }
    return *(const unsigned char *)s1 - *(const unsigned char *)s2;
}

char *strcpy(char *dst, const char *src)
{
    char *d = dst;
    while ((*d++ = *src++))
        ;
    return dst;
}
