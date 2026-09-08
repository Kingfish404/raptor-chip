/* Single-port ordered FPQ: mixed GPR/load inputs, FP arithmetic and reuse.
 * RV32/RV64 use the simulator's a0 + ebreak termination contract.
 */
.section .text
.globl _start
_start:
  li t0, 0x6000
  csrs mstatus, t0
  csrwi fcsr, 0
  la s0, input_word
  li s1, 32
loop:
  lw t0, 0(s0)
  fmv.w.x ft0, t0         /* 4.0 */
  fsqrt.s ft1, ft0        /* 2.0 */
  fdiv.s ft2, ft0, ft1    /* 2.0 */
  fmadd.s ft3, ft1, ft2, ft0 /* 8.0 */
  fmv.x.w t1, ft3
  li t2, 0x41000000
  bne t1, t2, fail
  fcvt.d.s ft4, ft3
  fmul.d ft5, ft4, ft4    /* 64.0 */
  fsqrt.d ft6, ft5        /* 8.0 */
  fdiv.d ft7, ft5, ft6    /* 8.0 */
  fmadd.d ft8, ft6, ft7, ft4 /* 72.0 */
  fcvt.w.d t1, ft8, rtz
  li t2, 72
  bne t1, t2, fail
  addi s1, s1, -1
  bnez s1, loop
  csrr t0, fflags
  bnez t0, fail
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
.section .rodata
.balign 4
input_word:
  .word 0x40800000
