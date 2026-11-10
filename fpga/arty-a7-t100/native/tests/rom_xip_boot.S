/* Both RV32 and RV64 execute these RV32I instructions at the fixed XIP entry. */
.option norvc
.option norelax
.section .text
.globl _start
_start:
  csrw mie, zero
  csrw mstatus, zero
  la t0, park
  csrw mtvec, t0
  li t0, 0x00100800
  li t2, 0x00800000
  lw t1, 0x30(t0)
  bne t1, t2, fail
  lw t1, 0x34(t0)
  bne t1, t2, fail
  li t2, 0x01000000
  lw t1, 0x38(t0)
  bne t1, t2, fail
  li t1, 0x524f4d31
  j finish
fail:
  li t1, 0x0badcafe
finish:
  li t0, 0x0f001f00
  sw t1, 0(t0)
  fence iorw, iorw
  ebreak
park:
  j park
