#define UART_BASE 0x10000000L
#define UART_TX 0x0L

#define MAIN_RAM 0x80000000L // Base address of main_ram

extern char raptor_dtb[];
extern unsigned int raptor_dtb_len;

void _start()
{
    asm volatile(
        "la a1, raptor_dtb\n"
        "csrr   a0, mhartid\n"
        "jalr %0\n"
        :
        : "r"(MAIN_RAM)
        :);
    while (1)
        ;
    *(volatile char *)(UART_BASE + UART_TX) = 'A';
    *(volatile char *)(UART_BASE + UART_TX) = '\n';
}