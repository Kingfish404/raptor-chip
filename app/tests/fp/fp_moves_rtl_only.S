.section .text
.globl _start
_start:
  li t0, 0x3f800000
  fmv.w.x ft0, t0
  fmv.x.w t1, ft0
  bne t1, t0, fail
    li t0, 0x00100000
    li t1, 1
    sw t1, 0(t0)
fail:
    li t0, 0x00100000
    li t1, 1
    sw t1, 0(t0)
