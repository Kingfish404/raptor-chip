/*
 * Generic app runtime for LiteX-style bare-metal payloads.
 *
 * This implementation provides a minimal UART-backed stdio subset and a halt
 * routine so small payloads can share one runtime across multiple app suites.
 */

#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

#ifndef UART_BASE
#define UART_BASE 0xf0001800UL
#endif

#ifndef RAPT_RUNTIME_WAIT_TXFULL
#define RAPT_RUNTIME_WAIT_TXFULL 0
#endif

#ifndef RAPT_RUNTIME_HALT_PRINT_STATUS
#define RAPT_RUNTIME_HALT_PRINT_STATUS 0
#endif

#ifndef RAPT_RUNTIME_HALT_WFI
#define RAPT_RUNTIME_HALT_WFI 0
#endif

#ifndef RAPT_RUNTIME_PROVIDE_EXIT
#define RAPT_RUNTIME_PROVIDE_EXIT 1
#endif

#ifndef RAPT_RUNTIME_FINISHER_BASE
#define RAPT_RUNTIME_FINISHER_BASE 0
#endif

#ifndef UART_TXFULL_OFFSET
#define UART_TXFULL_OFFSET 0x04
#endif

#define UART_RXTX (*(volatile uint32_t *)(UART_BASE + 0x00))
#if RAPT_RUNTIME_WAIT_TXFULL
#define UART_TXFULL (*(volatile uint32_t *)(UART_BASE + UART_TXFULL_OFFSET))
#endif

static void uart_putc(char c)
{
#if RAPT_RUNTIME_WAIT_TXFULL
    while (UART_TXFULL) {
    }
#endif
    UART_RXTX = (uint32_t)(uint8_t)c;
}

int putchar(int c)
{
    if (c == '\n') {
        uart_putc('\r');
    }
    uart_putc((char)c);
    return c;
}

int puts(const char *s)
{
    while (*s) {
        putchar(*s++);
    }
    putchar('\n');
    return 0;
}

static int print_unsigned(unsigned long long value, unsigned base, int width,
                          char pad, int uppercase)
{
    char buf[32];
    int len = 0;
    const char *digits = uppercase ? "0123456789ABCDEF" : "0123456789abcdef";

    if (value == 0) {
        buf[len++] = '0';
    } else {
        while (value != 0 && len < (int)sizeof(buf)) {
            buf[len++] = digits[value % base];
            value /= base;
        }
    }

    int count = 0;
    while (len < width) {
        putchar(pad);
        width--;
        count++;
    }
    while (len--) {
        putchar(buf[len]);
        count++;
    }
    return count;
}

static int print_signed(long long value, int width, char pad)
{
    int count = 0;
    if (value < 0) {
        putchar('-');
        value = -value;
        count++;
        if (width > 0) {
            width--;
        }
    }
    return count + print_unsigned((unsigned long long)value, 10, width, pad, 0);
}

int printf(const char *fmt, ...)
{
    va_list ap;
    int count = 0;

    va_start(ap, fmt);
    while (*fmt) {
        if (*fmt != '%') {
            putchar(*fmt++);
            count++;
            continue;
        }

        fmt++;
        char pad = ' ';
        int width = 0;
        if (*fmt == '0') {
            pad = '0';
            fmt++;
        }
        while (*fmt >= '0' && *fmt <= '9') {
            width = width * 10 + (*fmt++ - '0');
        }

        int long_count = 0;
        while (*fmt == 'l') {
            long_count++;
            fmt++;
        }
        if (*fmt == '\0') {
            putchar('%');
            count++;
            break;
        }

        switch (*fmt) {
        case 'd':
        case 'i':
            if (long_count >= 2) {
                count += print_signed(va_arg(ap, long long), width, pad);
            } else if (long_count == 1) {
                count += print_signed(va_arg(ap, long), width, pad);
            } else {
                count += print_signed(va_arg(ap, int), width, pad);
            }
            break;
        case 'u':
            if (long_count >= 2) {
                count += print_unsigned(va_arg(ap, unsigned long long), 10, width, pad, 0);
            } else if (long_count == 1) {
                count += print_unsigned(va_arg(ap, unsigned long), 10, width, pad, 0);
            } else {
                count += print_unsigned(va_arg(ap, unsigned int), 10, width, pad, 0);
            }
            break;
        case 'x':
        case 'X': {
            unsigned long long value;
            if (long_count >= 2) {
                value = va_arg(ap, unsigned long long);
            } else if (long_count == 1) {
                value = va_arg(ap, unsigned long);
            } else {
                value = va_arg(ap, unsigned int);
            }
            count += print_unsigned(value, 16, width, pad, *fmt == 'X');
            break;
        }
        case 'p':
            putchar('0');
            putchar('x');
            count += 2 + print_unsigned((uintptr_t)va_arg(ap, void *), 16,
                                        (int)(sizeof(void *) * 2), '0', 0);
            break;
        case 's': {
            const char *s = va_arg(ap, const char *);
            if (!s) {
                s = "(null)";
            }
            while (*s) {
                putchar(*s++);
                count++;
            }
            break;
        }
        case 'c':
            putchar(va_arg(ap, int));
            count++;
            break;
        case '%':
            putchar('%');
            count++;
            break;
        default:
            putchar('%');
            putchar(*fmt);
            count += 2;
            break;
        }
        if (*fmt) {
            fmt++;
        }
    }
    va_end(ap);
    return count;
}

void _litex_halt(int status)
{
#if RAPT_RUNTIME_HALT_PRINT_STATUS
    if (status == 0) {
        printf("\n[PASS]\n");
    } else {
        printf("\n[FAIL status=%d]\n", status);
    }
#else
    (void)status;
#endif
#if RAPT_RUNTIME_FINISHER_BASE
    *(volatile uint32_t *)(uintptr_t)RAPT_RUNTIME_FINISHER_BASE =
        status == 0 ? 0x5555u : (0x3333u | ((uint32_t)status << 16));
#endif
    while (1) {
#if RAPT_RUNTIME_HALT_WFI
        __asm__ volatile("wfi");
#endif
    }
}

#if RAPT_RUNTIME_PROVIDE_EXIT
void exit(int status)
{
    _litex_halt(status);
}

void _exit(int status)
{
    _litex_halt(status);
}
#endif

#include "libc_min.c"
