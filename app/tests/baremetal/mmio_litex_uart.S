/* LiteX RXTX is an 8-bit payload in a 32-bit CSR; one SW emits one byte. */
.option norvc
.section .text
.globl _start
_start:
  li t0, 0xf0001000
  li t1, 0x3e3e4e42
  sw t1, 0(t0)
  fence iorw,iorw
  li t1, 0x44434241
  sw t1, 0(t0)
  fence iorw,iorw
  li a0, 0
  ebreak
