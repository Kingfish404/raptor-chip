/* ============================================================================
 * minilib.c: Minimal freestanding libc for Embench-IoT on LiteX
 *
 * Derived from ../coremark/portme/minilib.c. Adds: printf alias, putchar,
 * strncmp, strncpy, strchr, simple bump malloc/free, abort/exit stubs.
 * UART output via LiteX UART CSR.
 * ============================================================================ */

#include <stdint.h>
#include <stddef.h>
#include <stdarg.h>

/* ---- LiteX UART CSR (memory-mapped) ---- */
#ifndef UART_BASE
#define UART_BASE 0xf0001800UL
#endif

#define UART_RXTX (*(volatile uint32_t *)(UART_BASE + 0x00))
#define UART_TXFULL (*(volatile uint32_t *)(UART_BASE + 0x04))
#define UART_RXEMPTY (*(volatile uint32_t *)(UART_BASE + 0x08))

static void uart_putc(char c)
{
    while (UART_TXFULL)
        ;
    UART_RXTX = (uint32_t)(unsigned char)c;
}

static void uart_puts(const char *s)
{
    while (*s)
    {
        if (*s == '\n')
            uart_putc('\r');
        uart_putc(*s++);
    }
}

/* ---- Minimal printf: %d %i %u %x %X %p %s %c %f %l(l) %% ---- */

static void print_uint(unsigned long val, int base, int uppercase, int width, char pad)
{
    char buf[24];
    int i = 0;
    const char *digits = uppercase ? "0123456789ABCDEF" : "0123456789abcdef";
    if (val == 0)
    {
        buf[i++] = '0';
    }
    else
    {
        while (val)
        {
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
    if (val < 0)
    {
        uart_putc('-');
        val = -val;
        if (width > 0)
            width--;
    }
    print_uint((unsigned long)val, 10, 0, width, pad);
}

static void print_float(double val)
{
    if (val < 0)
    {
        uart_putc('-');
        val = -val;
    }
    unsigned long integer = (unsigned long)val;
    print_uint(integer, 10, 0, 0, '0');
    uart_putc('.');
    double frac = val - (double)integer;
    for (int i = 0; i < 6; i++)
    {
        frac *= 10.0;
        int d = (int)frac;
        uart_putc('0' + d);
        frac -= d;
    }
}

int vprintf_core(const char *fmt, va_list ap)
{
    int count = 0;
    while (*fmt)
    {
        if (*fmt != '%')
        {
            if (*fmt == '\n')
                uart_putc('\r');
            uart_putc(*fmt++);
            count++;
            continue;
        }
        fmt++;
        char pad = ' ';
        int width = 0;
        /* optional '-' / '+' flags — ignore */
        if (*fmt == '-' || *fmt == '+')
            fmt++;
        if (*fmt == '0')
        {
            pad = '0';
            fmt++;
        }
        while (*fmt >= '0' && *fmt <= '9')
        {
            width = width * 10 + (*fmt - '0');
            fmt++;
        }
        /* optional precision — ignore, consume */
        if (*fmt == '.')
        {
            fmt++;
            while (*fmt >= '0' && *fmt <= '9')
                fmt++;
        }
        int is_long = 0;
        if (*fmt == 'l')
        {
            is_long = 1;
            fmt++;
            if (*fmt == 'l')
                fmt++;
        }
        else if (*fmt == 'z' || *fmt == 'j' || *fmt == 't')
        {
            is_long = 1;
            fmt++;
        }
        else if (*fmt == 'h')
        {
            fmt++;
            if (*fmt == 'h')
                fmt++;
        }
        switch (*fmt)
        {
        case 'd':
        case 'i':
        {
            long val = is_long ? va_arg(ap, long) : (long)va_arg(ap, int);
            print_int(val, width, pad);
            break;
        }
        case 'u':
        {
            unsigned long val = is_long ? va_arg(ap, unsigned long)
                                        : (unsigned long)va_arg(ap, unsigned int);
            print_uint(val, 10, 0, width, pad);
            break;
        }
        case 'x':
        {
            unsigned long val = is_long ? va_arg(ap, unsigned long)
                                        : (unsigned long)va_arg(ap, unsigned int);
            print_uint(val, 16, 0, width, pad);
            break;
        }
        case 'X':
        {
            unsigned long val = is_long ? va_arg(ap, unsigned long)
                                        : (unsigned long)va_arg(ap, unsigned int);
            print_uint(val, 16, 1, width, pad);
            break;
        }
        case 'p':
        {
            uart_putc('0');
            uart_putc('x');
            unsigned long val = (unsigned long)va_arg(ap, void *);
            print_uint(val, 16, 0, sizeof(void *) * 2, '0');
            break;
        }
        case 's':
        {
            const char *s = va_arg(ap, const char *);
            if (!s)
                s = "(null)";
            uart_puts(s);
            break;
        }
        case 'c':
        {
            char c = (char)va_arg(ap, int);
            uart_putc(c);
            break;
        }
        case 'f':
        case 'g':
        case 'e':
        {
            double val = va_arg(ap, double);
            print_float(val);
            break;
        }
        case '%':
            uart_putc('%');
            break;
        default:
            uart_putc('%');
            if (*fmt)
                uart_putc(*fmt);
            break;
        }
        if (*fmt)
            fmt++;
        count++;
    }
    return count;
}

int printf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    int n = vprintf_core(fmt, ap);
    va_end(ap);
    return n;
}

int vprintf(const char *fmt, va_list ap) { return vprintf_core(fmt, ap); }

int putchar(int c)
{
    uart_putc((char)c);
    return c;
}
int puts(const char *s)
{
    uart_puts(s);
    uart_putc('\r');
    uart_putc('\n');
    return 0;
}

/* ---- mem/string ---- */

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
    while (n--)
    {
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
    if (d < s)
    {
        while (n--)
            *d++ = *s++;
    }
    else
    {
        d += n;
        s += n;
        while (n--)
            *--d = *--s;
    }
    return dst;
}

void *memchr(const void *s, int c, size_t n)
{
    const uint8_t *p = (const uint8_t *)s;
    while (n--)
    {
        if (*p == (uint8_t)c)
            return (void *)p;
        p++;
    }
    return NULL;
}

size_t strlen(const char *s)
{
    const char *p = s;
    while (*p)
        p++;
    return (size_t)(p - s);
}

int strcmp(const char *s1, const char *s2)
{
    while (*s1 && *s1 == *s2)
    {
        s1++;
        s2++;
    }
    return *(const unsigned char *)s1 - *(const unsigned char *)s2;
}

int strncmp(const char *s1, const char *s2, size_t n)
{
    while (n && *s1 && *s1 == *s2)
    {
        s1++;
        s2++;
        n--;
    }
    if (!n)
        return 0;
    return *(const unsigned char *)s1 - *(const unsigned char *)s2;
}

char *strcpy(char *dst, const char *src)
{
    char *d = dst;
    while ((*d++ = *src++))
        ;
    return dst;
}

char *strncpy(char *dst, const char *src, size_t n)
{
    char *d = dst;
    while (n && (*d = *src))
    {
        d++;
        src++;
        n--;
    }
    while (n--)
        *d++ = '\0';
    return dst;
}

char *strchr(const char *s, int c)
{
    while (*s)
    {
        if (*s == (char)c)
            return (char *)s;
        s++;
    }
    return (c == 0) ? (char *)s : NULL;
}

char *strcat(char *dst, const char *src)
{
    char *d = dst;
    while (*d)
        d++;
    while ((*d++ = *src++))
        ;
    return dst;
}

/* ---- stdlib shims ---- */

int abs(int x) { return x < 0 ? -x : x; }
long labs(long x) { return x < 0 ? -x : x; }

static unsigned long __rand_state = 1;
int rand(void)
{
    __rand_state = __rand_state * 1103515245UL + 12345UL;
    return (int)((__rand_state >> 16) & 0x7FFFU);
}
void srand(unsigned int s) { __rand_state = s; }

int atoi(const char *s)
{
    int sign = 1, v = 0;
    while (*s == ' ' || *s == '\t')
        s++;
    if (*s == '-')
    {
        sign = -1;
        s++;
    }
    else if (*s == '+')
        s++;
    while (*s >= '0' && *s <= '9')
    {
        v = v * 10 + (*s - '0');
        s++;
    }
    return sign * v;
}

/* Simple bump allocator backed by a static .bss heap. Embench benchmarks
 * only call malloc a handful of times via init_heap_beebs/malloc_beebs
 * (which already manage their own arena), so standalone malloc is rarely
 * exercised — but GCC or beebsc may still reference it. */
#ifndef EMBENCH_HEAP_SIZE
#define EMBENCH_HEAP_SIZE (128 * 1024)
#endif
static uint8_t __heap[EMBENCH_HEAP_SIZE] __attribute__((aligned(16)));
static size_t __heap_off = 0;

void *malloc(size_t n)
{
    n = (n + 15) & ~((size_t)15);
    if (__heap_off + n > EMBENCH_HEAP_SIZE)
        return NULL;
    void *p = &__heap[__heap_off];
    __heap_off += n;
    return p;
}

void *calloc(size_t nmemb, size_t size)
{
    size_t n = nmemb * size;
    void *p = malloc(n);
    if (p)
        memset(p, 0, n);
    return p;
}

void free(void *p) { (void)p; }

/* No-op stubs for exit / abort / assert */
__attribute__((noreturn)) void exit(int status)
{
    (void)status;
    for (;;)
        __asm__ volatile("nop");
}

__attribute__((noreturn)) void abort(void)
{
    for (;;)
        __asm__ volatile("nop");
}

void __assert_func(const char *file, int line, const char *func, const char *expr)
{
    (void)file;
    (void)line;
    (void)func;
    (void)expr;
    printf("assert failed\n");
    abort();
}

/* ---- newlib's _ctype_ table ----
 * slre (and a few other benches) use the macro form of isdigit/isspace/…,
 * which in newlib expands to `_ctype_[c+1] & MASK`. Provide the same 257-byte
 * table so the freestanding link resolves. Constants match newlib
 * (libc/ctype/ctype_.c): _U=0x01 _L=0x02 _N=0x04 _S=0x08 _P=0x10 _C=0x20
 * _X=0x40 _B=0x80.
 */
const char _ctype_[1 + 256] = {
    0,
    /* 0x00 */ 0x20,
    0x20,
    0x20,
    0x20,
    0x20,
    0x20,
    0x20,
    0x20,
    /* 0x08 */ 0x20,
    0x28,
    0x28,
    0x28,
    0x28,
    0x28,
    0x20,
    0x20,
    /* 0x10 */ 0x20,
    0x20,
    0x20,
    0x20,
    0x20,
    0x20,
    0x20,
    0x20,
    /* 0x18 */ 0x20,
    0x20,
    0x20,
    0x20,
    0x20,
    0x20,
    0x20,
    0x20,
    /* 0x20 (sp) */ 0x88,
    0x10,
    0x10,
    0x10,
    0x10,
    0x10,
    0x10,
    0x10,
    /* 0x28 ( ) */ 0x10,
    0x10,
    0x10,
    0x10,
    0x10,
    0x10,
    0x10,
    0x10,
    /* 0x30 (0) */ 0x04,
    0x04,
    0x04,
    0x04,
    0x04,
    0x04,
    0x04,
    0x04,
    /* 0x38 (8) */ 0x04,
    0x04,
    0x10,
    0x10,
    0x10,
    0x10,
    0x10,
    0x10,
    /* 0x40 (@) */ 0x10,
    0x41,
    0x41,
    0x41,
    0x41,
    0x41,
    0x41,
    0x01,
    /* 0x48 (H) */ 0x01,
    0x01,
    0x01,
    0x01,
    0x01,
    0x01,
    0x01,
    0x01,
    /* 0x50 (P) */ 0x01,
    0x01,
    0x01,
    0x01,
    0x01,
    0x01,
    0x01,
    0x01,
    /* 0x58 (X) */ 0x01,
    0x01,
    0x01,
    0x10,
    0x10,
    0x10,
    0x10,
    0x10,
    /* 0x60 (`) */ 0x10,
    0x42,
    0x42,
    0x42,
    0x42,
    0x42,
    0x42,
    0x02,
    /* 0x68 (h) */ 0x02,
    0x02,
    0x02,
    0x02,
    0x02,
    0x02,
    0x02,
    0x02,
    /* 0x70 (p) */ 0x02,
    0x02,
    0x02,
    0x02,
    0x02,
    0x02,
    0x02,
    0x02,
    /* 0x78 (x) */ 0x02,
    0x02,
    0x02,
    0x10,
    0x10,
    0x10,
    0x10,
    0x20,
    /* 0x80 */ 0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    /* 0x90 */ 0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    /* 0xa0 */ 0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    /* 0xb0 */ 0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    /* 0xc0 */ 0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    /* 0xd0 */ 0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    /* 0xe0 */ 0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    /* 0xf0 */ 0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
};

/* Some newlib macro helpers reference `__ctype_ptr__` instead of `_ctype_`. */
const char *__ctype_ptr__ = _ctype_ + 1;

int toupper(int c) { return (c >= 'a' && c <= 'z') ? c - 32 : c; }
int tolower(int c) { return (c >= 'A' && c <= 'Z') ? c + 32 : c; }

/* Minimal sqrt for wikisort (Newton-Raphson). */
double sqrt(double x)
{
    if (x <= 0.0)
        return 0.0;

    double g = (x > 1.0) ? x : 1.0;
    for (int i = 0; i < 24; i++)
    {
        g = 0.5 * (g + x / g);
    }
    return g;
}
