/* Picolibc console, heap and termination for NPC machine-mode payloads. */
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

static int uart_putc(char c, FILE *stream)
{
    (void)stream;
    volatile uint8_t *uart = (volatile uint8_t *)0x10000000UL;
    while (!(uart[5] & 0x20)) {}
    uart[0] = (uint8_t)c;
    return (unsigned char)c;
}

static FILE console = FDEV_SETUP_STREAM(uart_putc, NULL, NULL, _FDEV_SETUP_WRITE);
FILE *const stdout = &console;
FILE *const stderr = &console;
FILE *const stdin = &console;

void *sbrk(ptrdiff_t increment)
{
    extern char __heap_start[], __heap_end[];
    static char *end;
    if (!end)
        end = __heap_start;
    if ((increment >= 0 && (uintptr_t)increment > (uintptr_t)(__heap_end - end)) ||
        (increment < 0 && (uintptr_t)(-increment) > (uintptr_t)(end - __heap_start))) {
        errno = ENOMEM;
        return (void *)-1;
    }
    char *old = end;
    end += increment;
    return old;
}

__attribute__((noreturn)) void _exit(int status)
{
    printf("RAPTOR EXIT status=%d\n", status);
    *(volatile uint32_t *)0x100000UL = status ? ((uint32_t)status << 16) | 0x3333 : 0x5555;
    for (;;)
        __asm__ volatile("wfi");
}
