.section .text
.globl _start
_start:
  li t0, 0x6000
  csrs mstatus, t0

  li t0, 0x3ff0000000000000
  fmv.d.x ft0, t0
  li t0, 0x4000000000000000
  fmv.d.x ft1, t0
  fsgnj.d ft2, ft0, ft1
  fmv.x.d t1, ft2
  li t2, 0x3ff0000000000000
  bne t1, t2, fail

  li t0, 0x00100000
  li t1, 1
  sw t1, 0(t0)
fail:
  li t0, 0x00100000
  li t1, 1
  sw t1, 0(t0)
