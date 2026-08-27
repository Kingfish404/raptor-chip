.section .text
.globl _start
_start:
  la t0, one_float
  flw ft0, 0(t0)
  fmv.x.w t1, ft0
  li t2, 0x3f800000
  bne t1, t2, fail

  fsgnjn.s ft1, ft0, ft0
  fmv.x.w t1, ft1
  li t2, -1082130432
  bne t1, t2, fail

  la t0, result_float
  fsw ft1, 0(t0)
  lw t1, 0(t0)
  bne t1, t2, fail

  csrr t1, fcsr
  andi t1, t1, 0xe0
  bnez t1, fail

  li a0, 0
  ebreak

fail:
  li a0, 1
  ebreak

.section .data
.align 2
one_float:
  .word 0x3f800000
result_float:
  .word 0
