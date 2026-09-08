/* Exercise the FP/system shared completion endpoint on a bare RV32 core. */
.section .text
.globl _start
_start:
  li t5, 0x6000           /* mstatus.FS=Dirty: enable architectural FP state */
  csrs mstatus, t5
  li t0, 0x3fc00000       /* 1.5f */
  li t1, 0x40100000       /* 2.25f */
  fmv.w.x ft0, t0
  fmv.w.x ft1, t1
  fadd.s ft2, ft0, ft1
  fmv.x.w t2, ft2
  li t3, 0x40700000       /* 3.75f */
  bne t2, t3, fail
  csrr t4, fflags
  bnez t4, fail
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
