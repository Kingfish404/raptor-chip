/* Renamed F/D chains with f0 WAW/WAR, FMA third-source dependencies, FP/GPR
 * round trips, store-data versions, and a precise illegal-rounding exception.
 * Run with NEMU difftest and varied memory response delays in both XLENs.
 */
.section .text
.globl _start
.option norvc
_start:
  li t0, 0x6000
  csrs mstatus, t0
  la t0, trap_handler
  csrw mtvec, t0
  li t0, 7
  fcvt.d.w f1, t0
  li t0, 3
  fcvt.d.w f2, t0
  fcvt.d.w f31, zero
  la s0, output
  li s1, 64
again:
  csrwi fflags, 0
  fdiv.d f0, f1, f2
  fmadd.d f4, f2, f2, f0
  fsd f0, 0(s0)
  fadd.d f0, f1, f2
  fadd.d f5, f0, f2
  fsd f0, 8(s0)
  fsd f4, 16(s0)
  fsd f5, 24(s0)
  fcvt.w.d t0, f0
  addi t0, t0, 1
  fcvt.s.w f6, t0
  fmul.s f7, f6, f6
  fsw f7, 32(s0)
  fcvt.d.s f8, f7
  fsd f8, 40(s0)
  fld f11, 0(s0)
  fld f12, 8(s0)
  fld f13, 16(s0)
  fld f14, 24(s0)
  fsd f11, 48(s0)
  fsd f12, 56(s0)
  fsd f13, 64(s0)
  fsd f14, 72(s0)
  csrr t0, fflags
  li t1, 1
  bne t0, t1, fail
  la t0, expected
  mv t1, s0
  li t2, 20
check_words:
  lw t3, 0(t0)
  lw t4, 0(t1)
  bne t3, t4, fail
  addi t0, t0, 4
  addi t1, t1, 4
  addi t2, t2, -1
  bnez t2, check_words
  addi s1, s1, -1
  bnez s1, again

  /* A fast younger result must remain speculative while a slow older divide
   * and an illegal instruction wait for in-order retirement. */
  fsgnj.d f10, f31, f31
  csrwi fflags, 0
  fdiv.d f15, f1, f2
illegal_rounding:
  .word 0x0220d4d3 /* FADD.D f9,f1,f2,rm=5 */
  fadd.d f10, f1, f1
  fsd f10, 80(s0)
  j fail
trap_handler:
  csrr t0, mcause
  li t1, 2
  bne t0, t1, fail
  csrr t0, mepc
  la t1, illegal_rounding
  bne t0, t1, fail
  csrr t0, fflags
  li t1, 1
  bne t0, t1, fail
  feq.d t0, f10, f31
  li t1, 1
  bne t0, t1, fail
  lw t0, 80(s0)
  lw t1, 84(s0)
  or t0, t0, t1
  bnez t0, fail
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
.section .rodata
.balign 8
expected:
  .quad 0x4002aaaaaaaaaaab, 0x4024000000000000
  .quad 0x4026aaaaaaaaaaab, 0x402a000000000000
  .quad 0x0000000042f20000, 0x405e400000000000
  .quad 0x4002aaaaaaaaaaab, 0x4024000000000000
  .quad 0x4026aaaaaaaaaaab, 0x402a000000000000
.section .data
.balign 64
output:
  .zero 88
