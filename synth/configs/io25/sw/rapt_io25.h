#ifndef RAPT_IO25_H
#define RAPT_IO25_H

#define RAPT_IO25_UART0_BASE 0x10000000
#define RAPT_IO25_UART1_BASE 0x10000100
#define RAPT_IO25_GPIO_BASE 0x10000200
#define RAPT_IO25_UART0_IRQ 2
#define RAPT_IO25_UART1_IRQ 3

/* UARTs use byte-spaced 16550 registers and fixed 8N1 framing. */
#define RAPT_IO25_UART_DATA 0
#define RAPT_IO25_UART_IER 1
#define RAPT_IO25_UART_IIR_FCR 2
#define RAPT_IO25_UART_LCR 3
#define RAPT_IO25_UART_LSR 5
#define RAPT_IO25_UART_SCRATCH 7

/* GPIO registers require aligned, single-beat, 32-bit accesses. */
#define RAPT_IO25_GPIO_INPUT 0x00
#define RAPT_IO25_GPIO_OUTPUT 0x04
#define RAPT_IO25_GPIO_ENABLE 0x08
#define RAPT_IO25_GPIO_OPEN_DRAIN 0x0c

#endif
