#include <stdint.h>
#define UART_BASE 0x10000000L
#define UART_TX 0x0L
void _start()
{
    *(volatile char *)(UART_BASE + UART_TX) = 'A';
    *(volatile char *)(UART_BASE + UART_TX) = '\n';
    asm volatile(
        "mv x1, %0\n"
        // "ld x2, 0(x1)\n"
        :
        : "r"(0x20000000)
        :);
    asm volatile("ebreak");
    while (1)
        ;
}