#define UART_BASE 0x10000000L
#define UART_TX 0x0L
void _start()
{
    *(volatile char *)(UART_BASE + UART_TX) = 'A';
    *(volatile char *)(UART_BASE + UART_TX) = '\n';
    while (1)
        ;
}