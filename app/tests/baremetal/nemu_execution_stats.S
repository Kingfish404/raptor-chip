.option norvc
.section .text
.globl _start
_start:
  la t0, fail
  csrw mtvec, t0
  li t0, 0x0200bff8
  lw t1, 0(t0)
  addi t1, t1, 1000
  li t2, 0x02004000
  sw t1, 0(t2)
  sw zero, 4(t2)
  li t2, 128
  csrs mie, t2
wait:
  wfi
  lw t2, 0(t0)
  bltu t2, t1, wait
  li t0, 0x100000
  li t1, 0x5555
  sw t1, 0(t0)
halt:
  j halt
fail:
  li t0, 0x100000
  li t1, 0x13333
  sw t1, 0(t0)
  j halt
