/* Native reset-PC firmware. Mutable state is only in the chip's 8 KiB RAM. */
#ifndef NATIVE_UART_DIVISOR
#define NATIVE_UART_DIVISOR 11
#endif
.option norvc
.section .text
.globl _start
_start:
  csrw mie, zero
  csrci mstatus, 8
  la t0, park
  csrw mtvec, t0
  li t0, 0x0f001f00
  li t1, 0x524a5331
  sw t1, 0(t0)
  li t2, 0x10000100
  li t3, 0x83
  sb t3, 3(t2)
  li t3, NATIVE_UART_DIVISOR
  sb t3, 0(t2)
  sb zero, 1(t2)
  li t3, 3
  sb t3, 3(t2)
  la t3, message
next:
  lbu t4, 0(t3)
  beqz t4, drain
wait_tx:
  lbu t5, 5(t2)
  andi t5, t5, 0x20
  beqz t5, wait_tx
  sb t4, 0(t2)
  addi t3, t3, 1
  j next
drain:
  lbu t5, 5(t2)
  andi t5, t5, 0x40
  beqz t5, drain
  li t1, 0x524a5332
  sw t1, 4(t0)
  fence iorw, iorw
park:
  j park
message:
  .asciz "JESD1\n"
