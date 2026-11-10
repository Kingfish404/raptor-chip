/* ROM-XIP, aperture guards, and a claimed/completed pad IRQ in both XLENs. */
.option norvc
.option norelax
.section .text
.globl _start
_start:
  csrw mie, zero
  csrw mstatus, zero
  la t0, handler
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
  li t0, 0x0c000004
  li t1, 1
  sw t1, 0(t0)
  li t0, 0x0c002000
  li t1, 2
  sw t1, 0(t0)
  li t0, 0x0c200000
  sw zero, 0(t0)
  li t0, 0x10000200
  sw zero, 12(t0)
  li t1, 7
  sw t1, 8(t0)
  li t1, 1
  sw t1, 4(t0)
  li t0, 0x800
  csrw mie, t0
  csrsi mstatus, 8
  fence iorw, iorw
  ebreak
park:
  j park
.balign 4
handler:
  csrr t0, mcause
  li t1, 3
  beq t0, t1, breakpoint
  bgez t0, fail
  slli t0, t0, 1
  srli t0, t0, 1
  li t1, 11
  bne t0, t1, fail
  li t0, 0x0c200004
  lw t1, 0(t0)
  li t2, 1
  bne t1, t2, fail
  sw t1, 0(t0)
  li t0, 0x10000204
  li t1, 5
  sw t1, 0(t0)
  fence iorw, iorw
  mret
breakpoint:
  la t0, park
  csrw mepc, t0
  mret
fail:
  li t0, 0x10000200
  sw zero, 12(t0)
  li t1, 7
  sw t1, 8(t0)
  li t1, 2
  sw t1, 4(t0)
  fence iorw, iorw
  ebreak
  j fail
