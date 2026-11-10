#include "rapt_io25.h"

.section .text.start
.globl _start
_start:
    csrw mie, zero
    csrw mstatus, zero
    la t0, trap_handler
    csrw mtvec, t0
    li s0, RAPT_IO25_GPIO_BASE
    sw zero, RAPT_IO25_GPIO_OUTPUT(s0)
    sw zero, RAPT_IO25_GPIO_OPEN_DRAIN(s0)
    li t0, 7
    sw t0, RAPT_IO25_GPIO_ENABLE(s0)
    li s1, RAPT_IO25_UART0_BASE
    li s2, RAPT_IO25_UART1_BASE
    li t0, 0x83
    sb t0, RAPT_IO25_UART_LCR(s1)
    sb t0, RAPT_IO25_UART_LCR(s2)
    li t0, 1
    sb t0, RAPT_IO25_UART_DATA(s1)
    sb t0, RAPT_IO25_UART_DATA(s2)
    sb zero, RAPT_IO25_UART_IER(s1)
    sb zero, RAPT_IO25_UART_IER(s2)
    li t0, 3
    sb t0, RAPT_IO25_UART_LCR(s1)
    sb t0, RAPT_IO25_UART_LCR(s2)
    li t0, 1
    sw t0, RAPT_IO25_GPIO_OUTPUT(s0)
1:
    lbu t0, RAPT_IO25_UART_LSR(s1)
    andi t0, t0, 1
    beqz t0, 1b
    lbu t0, RAPT_IO25_UART_DATA(s1)
    li t1, 0x5a
    bne t0, t1, failed
2:
    lbu t0, RAPT_IO25_UART_LSR(s2)
    andi t0, t0, 1
    beqz t0, 2b
    lbu t0, RAPT_IO25_UART_DATA(s2)
    li t1, 0x96
    bne t0, t1, failed
    li t0, 0xa6
    sb t0, RAPT_IO25_UART_DATA(s1)
    li t0, 0x39
    sb t0, RAPT_IO25_UART_DATA(s2)
3:
    lbu t0, RAPT_IO25_UART_LSR(s1)
    lbu t1, RAPT_IO25_UART_LSR(s2)
    and t0, t0, t1
    andi t0, t0, 0x40
    beqz t0, 3b
    li t0, 3
    sw t0, RAPT_IO25_GPIO_OUTPUT(s0)
.globl good_trap
good_trap:
    ebreak
    j failed
.balign 4
trap_handler:
    csrr t0, mcause
    li t1, 3
    bne t0, t1, failed
    csrr t0, mepc
    la t1, good_trap
    bne t0, t1, failed
    li t0, 5
    sw t0, RAPT_IO25_GPIO_OUTPUT(s0)
4:
    j 4b
failed:
    li s0, RAPT_IO25_GPIO_BASE
    li t0, 2
    sw t0, RAPT_IO25_GPIO_OUTPUT(s0)

5:
    j 5b
