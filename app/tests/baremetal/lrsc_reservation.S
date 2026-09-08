/* Reservation lifecycle and bounded constrained-loop progress in main RAM.
 * Mixed-width success is observed, not required: unconstrained LR/SC may fail.
 * This test has no external writer and does not prove DMA coherence/fairness. */
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, fail
  csrw mtvec, t0
  csrw mie, zero
  csrw mstatus, zero
  li s7, 0
  li s8, 0
  la s0, area
  addi s0, s0, 64
  addi s1, s0, 64
  sw zero, 0(s0)
  sw zero, 0(s1)
  li t2, 0x55
  /* No LR: SC fails, and cannot write memory. */
  sc.w t1, t2, (s0)
  beqz t1, fail
  lw t3, 0(s0)
  bnez t3, fail
  /* Most recent LR replaces the previous non-overlapping reservation. */
  lr.w t0, (s0)
  lr.w t0, (s1)
  sc.w t1, t2, (s0)
  beqz t1, fail
  /* Even a failed SC to a different address consumes the reservation. */
  sc.w t1, t2, (s1)
  beqz t1, fail
  lw t3, 0(s0)
  bnez t3, fail
  lw t3, 0(s1)
  bnez t3, fail
  /* A successful SC must also consume the reservation. */
  li t6, 1024
1:
  lr.w t0, (s0)
  sc.w t1, t2, (s0)
  beqz t1, 2f
  addi t6, t6, -1
  bnez t6, 1b
  j fail
2:
  sc.w t1, zero, (s0)
  beqz t1, fail
  lw t3, 0(s0)
  bne t3, t2, fail
#if __riscv_xlen == 64
  /* A wider SC at the same base is legal only if covered by the set.
   * Either success or failure is architecturally permitted here. */
  sd zero, 0(s0)
  li t2, 0x1122334455667788
  lr.w t0, (s0)
  sc.d t1, t2, (s0)
  ld t3, 0(s0)
  bnez t1, 3f
#ifdef REQUIRE_EXACT_LR_EXTENT
  j fail /* Platform contract: LR.W cannot reserve an SC.D-sized span. */
#endif
  bne t3, t2, fail
  addi s8, s8, 1
  j 4f
3:
  bnez t3, fail
4:
  sc.d t1, zero, (s0)
  beqz t1, fail
#endif
#if __riscv_xlen == 64 && defined(REQUIRE_EXACT_LR_EXTENT)
  /* A contained SC.W at LR.D+4 is supported by the platform policy. */
  sd zero, 0(s0)
  addi s1, s0, 4
  li t2, 0x55
  lr.d t0, (s0)
  sc.w t1, t2, (s1)
  bnez t1, fail
  ld t3, 0(s0)
  slli t2, t2, 32
  bne t3, t2, fail
  sc.w t1, zero, (s0)
  beqz t1, fail
#endif
  /* Reset 128 bytes straddling a page boundary; test every aligned word. */
  la s4, area
  li t0, 4032
  add s4, s4, t0
  addi s5, s4, 128
  mv s0, s4
5:
  sw zero, 0(s0)
  addi s0, s0, 4
  bltu s0, s5, 5b
  li s3, 0
6:
  mv s0, s4
7:
  li t6, 1024
8:
  lr.w.aq t0, (s0)
  addi t2, t0, 1
  sc.w.rl t1, t2, (s0)
  beqz t1, 9f
  addi t6, t6, -1
  bnez t6, 8b
  j fail
9:
  bne t0, s3, fail
  lw t3, 0(s0)
  bne t3, t2, fail
  addi s7, s7, 1
  addi s0, s0, 4
  bltu s0, s5, 7b
  addi s3, s3, 1
  li t0, 4
  bltu s3, t0, 6b
#if __riscv_xlen == 64
  mv s0, s4
10:
  sd zero, 0(s0)
  addi s0, s0, 8
  bltu s0, s5, 10b
  li s3, 0
11:
  mv s0, s4
12:
  li t6, 1024
13:
  lr.d.aq t0, (s0)
  addi t2, t0, 1
  sc.d.rl t1, t2, (s0)
  beqz t1, 14f
  addi t6, t6, -1
  bnez t6, 13b
  j fail
14:
  bne t0, s3, fail
  ld t3, 0(s0)
  bne t3, t2, fail
  addi s7, s7, 1
  addi s0, s0, 8
  bltu s0, s5, 12b
  addi s3, s3, 1
  li t0, 4
  bltu s3, t0, 11b
  li t0, 192
#else
  li t0, 128
#endif
  bne s7, t0, fail
.globl pass
pass:
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
  j fail
.section .data
.balign 4096
area: .zero 8192
