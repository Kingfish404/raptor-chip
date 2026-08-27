.section .text
.globl _start
_start:
  li t0, 0x6000
  csrs mstatus, t0

  li t0, 0x3f800000
  fmv.w.x ft0, t0
  fadd.s ft1, ft0, ft0
  fmv.x.w t1, ft1
  li t2, 0x40000000
  bne t1, t2, fail_fadd

  fsub.s ft2, ft1, ft0
  fmv.x.w t1, ft2
  li t2, 0x3f800000
  bne t1, t2, fail_fsub

  li t0, 0x3fc00000
  fmv.w.x ft3, t0
  li t0, 0x40000000
  fmv.w.x ft4, t0
  fmul.s ft5, ft3, ft4
  fmv.x.w t1, ft5
  li t2, 0x40400000
  bne t1, t2, fail_fmul

  li t0, 0x00100000
  li t1, 0x5555
  sw t1, 0(t0)
fail_fadd:
  li t0, 0x00100000
  li t1, 0x00013333
  sw t1, 0(t0)

fail_fsub:
  li t0, 0x00100000
  li t1, 0x00023333
  sw t1, 0(t0)

fail_fmul:
  li t0, 0x00100000
  li t1, 0x00033333
  sw t1, 0(t0)
