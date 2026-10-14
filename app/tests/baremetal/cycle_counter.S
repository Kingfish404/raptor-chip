/* Cycle counters follow core clocks, while NEMU advances per instruction.
 * Read the RV32 high alias after forcing a low-half rollover. Instret and
 * WARL-zero HPM reads also check the architectural counter behavior. */
.option norvc
.option norelax
.section .text
.globl _start
_start:
#if __riscv_xlen == 32
  csrw mcycleh, zero
  li t0, -16
  csrw mcycle, t0
  .rept 32
  nop
  .endr
  rdcycleh s0
  beqz s0, fail
  csrr s1, mcycleh
  bne s0, s1, fail
#endif
  rdcycle s0
  rdinstret s1
  nop
  rdinstret s2
  addi s1, s1, 2
  bne s1, s2, fail
  csrr s0, minstret
#if __riscv_xlen == 32
  rdinstreth s0
  csrr s1, minstreth
  bne s0, s1, fail
#endif
  csrr s0, hpmcounter3
  bnez s0, fail
  csrr s0, mhpmcounter31
  bnez s0, fail
#if __riscv_xlen == 32
  csrr s0, hpmcounter3h
  bnez s0, fail
  csrr s0, mhpmcounter31h
  bnez s0, fail
#endif
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
