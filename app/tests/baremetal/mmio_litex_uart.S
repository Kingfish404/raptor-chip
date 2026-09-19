/* LiteX RXTX is an 8-bit payload in a 32-bit CSR; one SW emits one byte. */
#ifndef UART_BASE
#define UART_BASE 0xf0001000
#endif
.option norvc
.section .text
.globl _start
_start:
  li t0, UART_BASE
  li t1, 0x3e3e4e42
  sw t1, 0(t0)
  fence iorw,iorw
  li t1, 0x44434241
  sw t1, 0(t0)
  fence iorw,iorw
  li a0, 0
  ebreak
