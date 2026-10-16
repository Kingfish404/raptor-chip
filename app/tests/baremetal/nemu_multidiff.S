.option norvc
#ifndef NEMU_MULTIDIFF_ITERATIONS
#define NEMU_MULTIDIFF_ITERATIONS 64
#endif
.section .text
.globl _start
_start:
  csrr s0, mhartid
#if defined(NEMU_TEST_H_GSTAGE) && defined(NEMU_TEST_VECTOR_DATA)
  li s5, 0
#endif
#if defined(NEMU_TEST_H_GSTAGE) && defined(NEMU_TEST_H_SVNAPOT)
  li s11, 0
#endif
#ifdef REPLAY_FAULTS
  li s6, 0
#endif
  la t0, trap
  csrw mtvec, t0
#ifdef NEGATIVE_FINISHER
  li t0, 0x100000
  li t1, 0x3333
  sw t1, 0(t0)
#endif
#ifdef NEGATIVE_MMIO
  li t0, 0x10000000
  lw t1, 0(t0)
#endif
#ifdef NEGATIVE_WFI
  wfi
#endif
#ifdef NEGATIVE_TIME
  rdtime t0
#endif
#ifdef NEGATIVE_IRQ
  li t0, 2
  csrs mip, t0
  csrs mie, t0
  csrsi mstatus, 8
#endif
  li s1, 0
  ecall
  li t0, 1
  bne s1, t0, fail
  li t0, 0x6000
  csrs mstatus, t0
  addi t0, s0, 1
  fcvt.d.w f0, t0
  fadd.d f1, f0, f0
  fcvt.w.d t1, f1
  slli t0, t0, 1
  bne t0, t1, fail
  la s2, counters
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0xf
  csrw pmpcfg0, t0
#ifdef NEMU_TEST_SSCOFPMF
  csrr t0, 0xda0
  bnez t0, fail
  li t0, 0x2000
  csrw mideleg, t0
  csrr t1, mideleg
#ifdef NEMU_TEST_RVA23
  li t2, 0x2444
  bne t2, t1, fail
#else
  bne t0, t1, fail
#endif
  csrw mie, t0
  csrr t1, sie
  bne t0, t1, fail
  csrw mie, zero
  csrw mip, t0
  csrr t1, sip
  bne t0, t1, fail
  csrw sip, zero
  csrr t1, mip
  and t1, t1, t0
  bnez t1, fail
  csrw mideleg, zero
#endif
#ifdef NEMU_TEST_SMSTATEEN
#if __riscv_xlen == 64
  li t0, 0xc000000000000000
  csrw 0x30c, t0
  csrr t1, 0x30c
#else
  li t0, 0xc0000000
  csrw 0x31c, t0
  csrr t1, 0x31c
#endif
  bne t0, t1, fail
  csrr t1, 0x10c
  bnez t1, fail
  csrw 0x10c, t0
  csrr t1, 0x10c
  bnez t1, fail
#if __riscv_xlen == 64
  csrw 0x30c, zero
  csrr t1, 0x30c
#else
  csrw 0x31c, zero
  csrr t1, 0x31c
#endif
  bnez t1, fail
#endif
#ifdef NEMU_TEST_H_STATEEN
  li t0, 0xc000000000000000
  csrw 0x30c, t0
  csrw 0x60c, t0
  csrr t1, 0x60c
  bne t0, t1, fail
  csrw 0x30c, zero
  csrr t1, 0x60c
  bnez t1, fail
  li t0, 0xc000000000000000
  csrw 0x30c, t0
  csrw 0x60c, t0
  li t0, 0x40
  csrw 0x10a, t0
  li t0, 7
  csrw 0x106, t0
  la t0, h_stateen_guest
  csrw mepc, t0
  csrr t0, mstatus
  li t1, 0x1800
  not t1, t1
  and t0, t0, t1
  li t1, 0x8000000800
  or t0, t0, t1
  csrw mstatus, t0
  mret
h_stateen_guest:
  csrr t0, 0x106
  li t1, 7
  bne t0, t1, fail
  csrr t0, 0x10a
  li t1, 0x40
  bne t0, t1, fail
  csrr t0, 0x10c
  bnez t0, fail
  ecall
h_stateen_guest_done:
  csrr t0, 0x10a
  li t1, 0x40
  bne t0, t1, fail
#endif
#ifdef NEMU_TEST_H_GSTAGE
  la t0, h_gstage_roots
  slli t1, s0, 14
  add t0, t0, t1
  la t2, h_gstage_middles
  slli t1, s0, 12
  add t2, t2, t1
  la t3, h_gstage_leaves
  add t3, t3, t1
  srli t1, t2, 12
  slli t1, t1, 10
  ori t1, t1, 1
  sd t1, 8(t0)
  srli t1, t3, 12
  slli t1, t1, 10
  ori t1, t1, 1
  sd t1, 64(t2)
  la t6, h_gstage_scratch
  slli t1, s0, 3
  add t6, t6, t1
  srli t1, t6, 12
  slli t1, t1, 10
  ori t1, t1, 0xdf
  sd t1, 0(t3)
  srli t0, t0, 12
  li t1, 0x8000000000000000
  or t0, t0, t1
  csrw 0x680, t0
  .word 0x62000073
  li t0, 0xfff
  and t4, t6, t0
  li t0, 0x41000000
  add t4, t4, t0
  addi t5, s0, 1
  slli t5, t5, 8
  .word 0x6a004073 | (30 << 20) | (29 << 15)
  .word 0x68004073 | (29 << 15) | (31 << 7)
  bne t6, t5, fail
  la t0, h_gstage_scratch
  slli t1, s0, 3
  add t0, t0, t1
  lw t1, 0(t0)
  bne t1, t5, fail
  srli t1, t0, 12
  slli t1, t1, 10
  ori t1, t1, 0xd9
  sd t1, 0(t3)
  .word 0x62000073
  .word 0x68304073 | (29 << 15) | (31 << 7)
  bne t6, t5, fail
  srli t1, t0, 12
  slli t1, t1, 10
  ori t1, t1, 0xdf
  sd t1, 0(t3)
  la t6, h_gstage_vs_leaves
  slli t1, s0, 12
  add t6, t6, t1
  srli t1, t6, 12
  slli t1, t1, 10
  ori t1, t1, 1
  sd t1, 0(t2)
  la t0, h_vstage_roots
  slli t1, s0, 12
  add t0, t0, t1
  srli t1, t0, 12
  slli t1, t1, 10
  ori t1, t1, 0xdf
  sd t1, 0(t6)
  li t1, 0x40001000
  srli t1, t1, 12
  slli t1, t1, 10
  ori t1, t1, 1
  sd t1, 8(t0)
  la t0, h_vstage_middles
  slli t1, s0, 12
  add t0, t0, t1
  srli t1, t0, 12
  slli t1, t1, 10
  ori t1, t1, 0xdf
  sd t1, 8(t6)
  li t1, 0x40002000
  srli t1, t1, 12
  slli t1, t1, 10
  ori t1, t1, 1
  sd t1, 256(t0)
  la t0, h_vstage_leaves
  slli t1, s0, 12
  add t0, t0, t1
  srli t1, t0, 12
  slli t1, t1, 10
  ori t1, t1, 0xdf
  sd t1, 16(t6)
  li t1, 0x41000000
  srli t1, t1, 12
  slli t1, t1, 10
  ori t1, t1, 0xd7
  sd t1, 0(t0)
  li t1, 0x40000000
  srli t1, t1, 12
  li t0, 0x8000000000000000
  or t1, t1, t0
  csrw 0x280, t1
  .word 0x22000073
  li t1, 0x3000000
  add t4, t4, t1
  .word 0x68004073 | (29 << 15) | (31 << 7)
  bne t6, t5, fail
  addi t5, t5, 1
  .word 0x6a004073 | (30 << 20) | (29 << 15)
  .word 0x68004073 | (29 << 15) | (31 << 7)
  bne t6, t5, fail
  addi t4, t4, 1
  .word 0x68104073 | (29 << 15) | (31 << 7)
  srli t0, t5, 8
  bne t6, t0, fail
  .word 0x6a004073 | (30 << 20) | (29 << 15)
  .word 0x68104073 | (29 << 15) | (31 << 7)
  bne t6, t5, fail
  addi t4, t4, -1
  .word 0x6a004073 | (30 << 20) | (29 << 15)
  csrr t0, mstatus
  li t1, -0x1801
  and t1, t0, t1
  li t2, 0x8000020000
  or t1, t1, t2
  csrw mstatus, t1
  lw t6, 0(t4)
  bne t6, t5, fail
  sw t5, 0(t4)
  csrw mstatus, t0
#ifdef NEMU_TEST_H_PBMT
  li t0, 0x4000000000000000
  csrw 0x30a, t0
  csrw 0x60a, t0
  la t0, h_vstage_leaves
  slli t1, s0, 12
  add t0, t0, t1
  ld t1, 0(t0)
  li t2, 0x2000000000000000
  or t1, t1, t2
  sd t1, 0(t0)
  .word 0x68004073 | (29 << 15) | (31 << 7)
  bne t6, t5, fail
  not t2, t2
  and t1, t1, t2
  sd t1, 0(t0)
  csrw 0x60a, zero
  csrw 0x30a, zero
#endif
#ifdef NEMU_TEST_H_MMIO
  ld t2, 0(t3)
  li t0, 0x100000
  srli t0, t0, 12
  slli t0, t0, 10
  ori t0, t0, 0xdf
  sd t0, 0(t3)
  .word 0x62000073
  mv t1, t4
  li t4, 0x44000000
  .word 0x68004073 | (29 << 15) | (31 << 7)
  bnez t6, fail
  mv t4, t1
  sd t2, 0(t3)
  .word 0x62000073
#endif
#ifdef NEMU_TEST_H_POINTER_MASK
  li t0, 0x200000000
  csrw 0x60a, t0
  li t0, 0x100
  csrw 0x600, t0
  li t0, 0x40000
  csrw 0x200, t0
  li t0, 0xaa00000000000000
  or t4, t4, t0
  .word 0x68004073 | (29 << 15) | (31 << 7)
  bne t6, t5, fail
  csrw 0x60a, zero
  csrw 0x600, zero
  csrw 0x200, zero
#endif
#ifdef NEMU_TEST_H_SVNAPOT
  la t0, h_napot_data
  li t1, 0xffff
  add t0, t0, t1
  not t1, t1
  and t0, t0, t1
  slli t1, s0, 16
  add t0, t0, t1
  addi t5, s0, 0x100
  sw t5, 0(t0)
  li t1, 0x8000
  add t1, t0, t1
  addi t5, t5, 8
  sw t5, 0(t1)
  li t1, 0xf000
  add t1, t0, t1
  addi t5, t5, 7
  sw t5, 0(t1)
  srli t1, t0, 12
  ori t1, t1, 8
  slli t1, t1, 10
  ori t1, t1, 0xdf
  li t2, 0x8000000000000000
  or t1, t1, t2
  la t3, h_gstage_leaves
  slli t2, s0, 12
  add t3, t3, t2
  li t2, 16
1:
  sd t1, 0(t3)
  addi t3, t3, 8
  addi t2, t2, -1
  bnez t2, 1b
  li t1, 0x41000000
  srli t1, t1, 12
  ori t1, t1, 8
  slli t1, t1, 10
  ori t1, t1, 0xd7
  li t2, 0x8000000000000000
  or t1, t1, t2
  la t3, h_vstage_leaves
  slli t2, s0, 12
  add t3, t3, t2
  li t2, 16
2:
  sd t1, 0(t3)
  addi t3, t3, 8
  addi t2, t2, -1
  bnez t2, 2b
  .word 0x62000073
  .word 0x22000073
  li t4, 0x44000000
  addi t5, s0, 0x100
  .word 0x68004073 | (29 << 15) | (31 << 7)
  bne t6, t5, fail
  li t1, 0x8000
  add t4, t4, t1
  addi t5, t5, 8
  .word 0x68004073 | (29 << 15) | (31 << 7)
  bne t6, t5, fail
  li t1, 0x7000
  add t4, t4, t1
  addi t5, t5, 7
  .word 0x68004073 | (29 << 15) | (31 << 7)
  bne t6, t5, fail
  la t3, h_vstage_leaves
  slli t1, s0, 12
  add t3, t3, t1
  ld t2, 0(t3)
  xori t1, t2, 0x400
  sd t1, 0(t3)
  .word 0x22000073
  li t4, 0x44000000
  li s11, 1
  .word 0x68004073 | (29 << 15) | (31 << 7)
  li t0, 2
  bne s11, t0, fail
  sd t2, 0(t3)
  .word 0x22000073
  la t3, h_gstage_leaves
  slli t1, s0, 12
  add t3, t3, t1
  ld t2, 0(t3)
  xori t1, t2, 0x400
  sd t1, 0(t3)
  .word 0x62000073
  li s11, 3
  .word 0x68004073 | (29 << 15) | (31 << 7)
  li t0, 4
  bne s11, t0, fail
  sd t2, 0(t3)
  .word 0x62000073
  li s11, 0
#endif
  csrw 0x280, zero
  csrw 0x680, zero
#endif
#ifdef NEMU_TEST_VECTOR_CONTROL
  li t0, 0x200
  csrs mstatus, t0
  csrr t1, 0xc21
#if __riscv_xlen == 64
  li t2, 0x8000000000000000
#else
  li t2, 0x80000000
#endif
  bne t1, t2, fail
  csrr t1, 0xc22
  li t2, 16
  bne t1, t2, fail
  addi t0, s0, 3
  .word (0xc0 << 20) | (5 << 15) | (7 << 12) | (6 << 7) | 0x57
  bne t1, t0, fail
  csrr t1, 0xc20
  bne t1, t0, fail
  csrr t1, 0xc21
  li t2, 0xc0
  bne t1, t2, fail
  csrr t1, mstatus
  li t2, 0x600
  and t1, t1, t2
  bne t1, t2, fail
  li t0, 7
  csrw 0x00f, t0
  csrr t1, 0x00a
  li t2, 3
  bne t1, t2, fail
  csrr t1, 0x009
  li t2, 1
  bne t1, t2, fail
#endif
#ifdef NEMU_TEST_VECTOR_DATA
  li t0, 0x200
  csrs mstatus, t0
  addi t0, s0, 3
  .word (0xc0 << 20) | (5 << 15) | (7 << 12) | (6 << 7) | 0x57
  li t5, 0x5a
  .word (0x10 << 26) | (1 << 25) | (30 << 15) | (6 << 12) | (30 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (30 << 20) | (2 << 12) | (7 << 7) | 0x57
  bne t2, t5, fail
  csrw 0x009, zero
  li t5, 255
  .word (0x17 << 26) | (1 << 25) | (30 << 15) | (4 << 12) | (9 << 7) | 0x57
  li t5, 1
  .word (0x20 << 26) | (1 << 25) | (9 << 20) | (30 << 15) | (4 << 12) | (10 << 7) | 0x57
  csrr t6, 0x009
  bne t6, t5, fail
  csrr t6, 0x00f
  bne t6, t5, fail
  .word (0x10 << 26) | (1 << 25) | (10 << 20) | (2 << 12) | (31 << 7) | 0x57
  li t5, -1
  bne t6, t5, fail
  li t0, 0x5a
  .word (0x17 << 26) | (1 << 25) | (5 << 15) | (4 << 12) | (27 << 7) | 0x57
  li t0, 2
  csrw 0x008, t0
  .word (0x27 << 26) | (1 << 25) | (9 << 20) | (3 << 12) | (27 << 7) | 0x57
  csrr t0, 0x008
  bnez t0, fail
  .word (0x10 << 26) | (1 << 25) | (27 << 20) | (2 << 12) | (7 << 7) | 0x57
  li t0, 0x5a
  bne t2, t0, fail
  .word (0x0f << 26) | (1 << 25) | (27 << 20) | (2 << 15) | (3 << 12) | (28 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (28 << 20) | (2 << 12) | (7 << 7) | 0x57
  li t0, -1
  bne t2, t0, fail
  .word (0x30 << 26) | (1 << 25) | (9 << 20) | (10 << 15) | (2 << 12) | (24 << 7) | 0x57
  .word (0x31 << 26) | (1 << 25) | (9 << 20) | (10 << 15) | (2 << 12) | (26 << 7) | 0x57
  .word (0x3c << 26) | (1 << 25) | (9 << 20) | (10 << 15) | (2 << 12) | (24 << 7) | 0x57
  li t0, 1
  .word (0xc8 << 20) | (5 << 15) | (7 << 12) | 0x57
  .word (0x10 << 26) | (1 << 25) | (24 << 20) | (2 << 12) | (7 << 7) | 0x57
  li t4, -1
  bne t2, t4, fail
  .word (0x10 << 26) | (1 << 25) | (26 << 20) | (2 << 12) | (7 << 7) | 0x57
  li t4, -2
  bne t2, t4, fail
  .word (0x12 << 26) | (1 << 25) | (9 << 20) | (6 << 15) | (2 << 12) | (28 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (28 << 20) | (2 << 12) | (7 << 7) | 0x57
  li t4, 255
  bne t2, t4, fail
  addi t0, s0, 3
  .word (0xc0 << 20) | (5 << 15) | (7 << 12) | (6 << 7) | 0x57
  .word (0x2d << 26) | (1 << 25) | (24 << 20) | (12 << 15) | (3 << 12) | (28 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (28 << 20) | (2 << 12) | (7 << 7) | 0x57
  li t4, -1
  bne t2, t4, fail
  .word (0x17 << 26) | (1 << 25) | (5 << 15) | (4 << 12) | (1 << 7) | 0x57
  .word (1 << 25) | (1 << 20) | (1 << 15) | (2 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (2 << 20) | (2 << 12) | (7 << 7) | 0x57
  slli t1, t0, 1
  bne t2, t1, fail
  li t5, 16
  csrw 0x008, t5
  .word (1 << 25) | (1 << 20) | (1 << 15) | (2 << 7) | 0x57
  csrr t5, 0x008
  bnez t5, fail
  .word (0x10 << 26) | (1 << 25) | (2 << 20) | (2 << 12) | (7 << 7) | 0x57
  bne t2, t1, fail
  .word (0x2d << 26) | (1 << 25) | (1 << 20) | (1 << 15) | (2 << 12) | (2 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (2 << 20) | (2 << 12) | (7 << 7) | 0x57
  mul t4, t0, t0
  add t4, t4, t1
  bne t2, t4, fail
  .word (0x2f << 26) | (1 << 25) | (1 << 20) | (1 << 15) | (2 << 12) | (2 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (2 << 20) | (2 << 12) | (7 << 7) | 0x57
  bne t2, t1, fail
  li t5, 1
  .word (0x29 << 26) | (1 << 25) | (1 << 20) | (30 << 15) | (6 << 12) | (2 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (2 << 20) | (2 << 12) | (7 << 7) | 0x57
  add t4, t0, t1
  bne t2, t4, fail
  .word (0x2b << 26) | (1 << 25) | (1 << 20) | (30 << 15) | (6 << 12) | (2 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (2 << 20) | (2 << 12) | (7 << 7) | 0x57
  neg t4, t1
  bne t2, t4, fail
  .word (1 << 25) | (1 << 20) | (1 << 15) | (2 << 7) | 0x57
  la t3, vector_scratch
  slli t4, s0, 4
  add t3, t3, t4
  .word (1 << 25) | (28 << 15) | (2 << 7) | 0x27
  .word (1 << 25) | (28 << 15) | (3 << 7) | 0x07
  .word (0x10 << 26) | (1 << 25) | (3 << 20) | (2 << 12) | (7 << 7) | 0x57
  bne t2, t1, fail
  li t5, 16
  csrw 0x008, t5
  addi t3, t3, 1
  .word (1 << 25) | (28 << 15) | (5 << 12) | (2 << 7) | 0x07
  addi t3, t3, -1
  csrr t5, 0x008
  bnez t5, fail
  .word (0x10 << 26) | (1 << 25) | (2 << 20) | (2 << 12) | (7 << 7) | 0x57
  bne t2, t1, fail
  .word (0x17 << 26) | (1 << 25) | (10 << 15) | (3 << 12) | 0x57
  .word (0x17 << 26) | (1 << 25) | (1 << 15) | (3 << 12) | (4 << 7) | 0x57
  .word (1 << 20) | (1 << 15) | (4 << 7) | 0x57
  .word (1 << 25) | (28 << 15) | (4 << 7) | 0x27
  lbu t2, 0(t3)
  li t4, 1
  bne t2, t4, fail
  lbu t2, 1(t3)
  bne t2, t1, fail
  lbu t2, 2(t3)
  bne t2, t4, fail
  .word (28 << 15) | (5 << 7) | 0x07
  .word (1 << 25) | (28 << 15) | (5 << 7) | 0x27
  lbu t2, 0(t3)
  bnez t2, fail
  lbu t2, 1(t3)
  bne t2, t1, fail
  lbu t2, 2(t3)
  bnez t2, fail
  .word (0xff << 20) | (5 << 15) | (7 << 12) | (6 << 7) | 0x57
  csrr t2, 0xc20
  bnez t2, fail
  .word (1 << 25) | (8 << 20) | (28 << 15) | (2 << 7) | 0x27
  .word (1 << 25) | (8 << 20) | (28 << 15) | (6 << 7) | 0x07
  .word (0xc0 << 20) | (5 << 15) | (7 << 12) | (6 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (6 << 20) | (2 << 12) | (7 << 7) | 0x57
  slli t1, t0, 1
  bne t2, t1, fail
  .word (0x27 << 26) | (1 << 25) | (6 << 20) | (3 << 12) | (7 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (7 << 20) | (2 << 12) | (7 << 7) | 0x57
  bne t2, t1, fail
  la t3, vector_scratch
  slli t4, s0, 4
  add t3, t3, t4
  addi t3, t3, 1
  li t0, 3
  .word (0xc0 << 20) | (5 << 15) | (7 << 12) | 0x57
  .word (1 << 25) | (16 << 20) | (28 << 15) | (8 << 7) | 0x07
  .word (0x10 << 26) | (1 << 25) | (8 << 20) | (2 << 12) | (7 << 7) | 0x57
  bne t2, t1, fail
  la t3, vector_scratch
  slli t4, s0, 4
  add t3, t3, t4
  addi t3, t3, 8
  li t4, 2
  li t0, 3
  .word (0xc0 << 20) | (5 << 15) | (7 << 12) | 0x57
  .word (2 << 26) | (1 << 25) | (29 << 20) | (28 << 15) | (4 << 7) | 0x27
  lbu t2, 0(t3)
  li t0, 1
  bne t2, t0, fail
  lbu t2, 2(t3)
  bne t2, t1, fail
  lbu t2, 4(t3)
  bne t2, t0, fail
  .word (2 << 26) | (1 << 25) | (29 << 20) | (28 << 15) | (11 << 7) | 0x07
  .word (0x10 << 26) | (1 << 25) | (11 << 20) | (2 << 12) | (7 << 7) | 0x57
  bne t2, t0, fail
  addi t3, t3, 4
  li t4, -2
  .word (2 << 26) | (1 << 25) | (29 << 20) | (28 << 15) | (12 << 7) | 0x07
  la t3, vector_scratch
  slli t4, s0, 4
  add t3, t3, t4
  sb zero, 0(t3)
  li t4, 2
  sb t4, 1(t3)
  li t4, 4
  sb t4, 2(t3)
  .word (1 << 25) | (28 << 15) | (13 << 7) | 0x07
  addi t3, t3, 8
  .word (1 << 26) | (1 << 25) | (13 << 20) | (28 << 15) | (14 << 7) | 0x07
  .word (0x10 << 26) | (1 << 25) | (14 << 20) | (2 << 12) | (7 << 7) | 0x57
  li t0, 1
  bne t2, t0, fail
  .word (3 << 26) | (1 << 25) | (13 << 20) | (28 << 15) | (14 << 7) | 0x27
  la t3, vector_scratch
  slli t4, s0, 4
  add t3, t3, t4
  li t0, 1
  sb t0, 0(t3)
  li t0, 2
  sb t0, 1(t3)
  li t0, 3
  sb t0, 2(t3)
  li t0, 4
  sb t0, 3(t3)
  li t0, 5
  sb t0, 4(t3)
  li t0, 6
  sb t0, 5(t3)
  li t0, 3
  .word (0xc0 << 20) | (5 << 15) | (7 << 12) | 0x57
  .word (1 << 29) | (1 << 25) | (28 << 15) | (16 << 7) | 0x07
  addi t3, t3, 8
  .word (1 << 29) | (1 << 25) | (28 << 15) | (16 << 7) | 0x27
  lbu t2, 0(t3)
  li t4, 1
  bne t2, t4, fail
  lbu t2, 1(t3)
  li t4, 2
  bne t2, t4, fail
  lbu t2, 4(t3)
  li t4, 5
  bne t2, t4, fail
  lbu t2, 5(t3)
  li t4, 6
  bne t2, t4, fail
  .word (0x17 << 26) | (1 << 25) | (1 << 15) | (3 << 12) | 0x57
  .word (0x10 << 26) | (16 << 20) | (17 << 15) | (20 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (20 << 20) | (2 << 12) | (7 << 7) | 0x57
  li t4, 4
  bne t2, t4, fail
  .word (0x19 << 26) | (1 << 25) | (2 << 12) | (22 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (22 << 20) | (2 << 12) | (7 << 7) | 0x57
  andi t2, t2, 1
  li t4, 1
  bne t2, t4, fail
  .word (1 << 25) | (16 << 20) | (17 << 15) | (2 << 12) | (23 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (23 << 20) | (2 << 12) | (7 << 7) | 0x57
  li t4, 11
  bne t2, t4, fail
  .word (0x25 << 26) | (1 << 25) | (16 << 20) | (17 << 15) | (2 << 12) | (24 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (24 << 20) | (2 << 12) | (7 << 7) | 0x57
  li t4, 2
  bne t2, t4, fail
  .word (0x20 << 26) | (1 << 25) | (17 << 20) | (16 << 15) | (2 << 12) | (25 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (25 << 20) | (2 << 12) | (7 << 7) | 0x57
  bne t2, t4, fail
  .word (0x10 << 26) | (1 << 25) | (16 << 20) | (16 << 15) | (2 << 12) | (7 << 7) | 0x57
  li t4, 1
  bne t2, t4, fail
  .word (0x10 << 26) | (16 << 20) | (17 << 15) | (2 << 12) | (7 << 7) | 0x57
  bnez t2, fail
  .word (0x0f << 26) | (1 << 25) | (16 << 20) | (1 << 15) | (3 << 12) | (26 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (26 << 20) | (2 << 12) | (7 << 7) | 0x57
  li t4, 3
  bne t2, t4, fail
  .word (0x0c << 26) | (1 << 25) | (16 << 20) | (17 << 15) | (27 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (27 << 20) | (2 << 12) | (7 << 7) | 0x57
  li t4, 5
  bne t2, t4, fail
  .word (0x14 << 26) | (1 << 25) | (17 << 20) | (1 << 15) | (2 << 12) | (28 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (28 << 20) | (2 << 12) | (7 << 7) | 0x57
  andi t2, t2, 7
  li t4, 1
  bne t2, t4, fail
  .word (0x14 << 26) | (1 << 25) | (17 << 20) | (16 << 15) | (2 << 12) | (29 << 7) | 0x57
  .word (0x0f << 26) | (1 << 25) | (29 << 20) | (2 << 15) | (3 << 12) | (30 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (30 << 20) | (2 << 12) | (7 << 7) | 0x57
  bne t2, t4, fail
  .word (0x14 << 26) | (1 << 25) | (17 << 15) | (2 << 12) | (31 << 7) | 0x57
  .word (0x0f << 26) | (1 << 25) | (31 << 20) | (2 << 15) | (3 << 12) | (30 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (30 << 20) | (2 << 12) | (7 << 7) | 0x57
  li t4, 2
  bne t2, t4, fail
  .word (0x17 << 26) | (1 << 25) | (16 << 20) | (17 << 15) | (2 << 12) | (28 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (28 << 20) | (2 << 12) | (7 << 7) | 0x57
  li t4, 3
  bne t2, t4, fail
  bnez s0, vector_fof_done
  li t3, 0xbffffffe
  li t4, 0x41
  sb t4, 0(t3)
  sb t4, 1(t3)
  li t0, 4
  .word (0xc0 << 20) | (5 << 15) | (7 << 12) | 0x57
  .word (1 << 25) | (16 << 20) | (28 << 15) | (9 << 7) | 0x07
  csrr t2, 0xc20
  li t4, 2
  bne t2, t4, fail
  csrr t2, 0x008
  bnez t2, fail
  .word (0x10 << 26) | (1 << 25) | (9 << 20) | (2 << 12) | (7 << 7) | 0x57
  li t4, 0x41
  bne t2, t4, fail
  li t0, 4
  .word (0xc0 << 20) | (5 << 15) | (7 << 12) | 0x57
  .word (1 << 29) | (1 << 25) | (16 << 20) | (28 << 15) | (18 << 7) | 0x07
  csrr t2, 0xc20
  li t4, 1
  bne t2, t4, fail
  csrr t2, 0x008
  bnez t2, fail
  .word (0x10 << 26) | (1 << 25) | (18 << 20) | (2 << 12) | (7 << 7) | 0x57
  li t4, 0x41
  bne t2, t4, fail
  .word (0x10 << 26) | (1 << 25) | (19 << 20) | (2 << 12) | (7 << 7) | 0x57
  bne t2, t4, fail
vector_fof_done:
  li t4, 0x6000
  csrs mstatus, t4
  addi t1, s0, 3
  slli t1, t1, 1
  fmv.w.x f5, t1
  li t0, 2
  .word (0xd0 << 20) | (5 << 15) | (7 << 12) | 0x57
  .word (0x17 << 26) | (1 << 25) | (5 << 15) | (5 << 12) | (24 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (24 << 20) | (1 << 12) | (6 << 7) | 0x57
  fmv.x.w t2, f6
  bne t2, t1, fail
  .word (0x10 << 26) | (1 << 25) | (5 << 15) | (5 << 12) | (25 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (25 << 20) | (1 << 12) | (6 << 7) | 0x57
  fmv.x.w t2, f6
  bne t2, t1, fail
  li t1, 0x3f800000
  fmv.w.x f5, t1
  .word (0x17 << 26) | (1 << 25) | (5 << 15) | (5 << 12) | (24 << 7) | 0x57
  li t1, 0x40000000
  fmv.w.x f5, t1
  .word (0x17 << 26) | (1 << 25) | (5 << 15) | (5 << 12) | (25 << 7) | 0x57
  li t1, 0x40400000
  fmv.w.x f5, t1
  .word (0x2c << 26) | (1 << 25) | (25 << 20) | (5 << 15) | (5 << 12) | (24 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (24 << 20) | (1 << 12) | (6 << 7) | 0x57
  fmv.x.w t2, f6
  li t4, 0x40e00000
  bne t2, t4, fail
  .word (0x13 << 26) | (1 << 25) | (24 << 20) | (16 << 15) | (1 << 12) | (26 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (26 << 20) | (1 << 12) | (6 << 7) | 0x57
  fmv.x.w t2, f6
  li t4, 0x40
  bne t2, t4, fail
  .word (0x12 << 26) | (1 << 25) | (26 << 20) | (2 << 15) | (1 << 12) | (27 << 7) | 0x57
  .word (0x12 << 26) | (1 << 25) | (27 << 20) | (28 << 7) | (1 << 12) | 0x57
  .word (0x10 << 26) | (1 << 25) | (28 << 20) | (1 << 12) | (6 << 7) | 0x57
  fmv.x.w t2, f6
  bne t2, t4, fail
  .word (0x12 << 26) | (1 << 25) | (27 << 20) | (12 << 15) | (1 << 12) | (28 << 7) | 0x57
  .word (0x12 << 26) | (1 << 25) | (28 << 20) | (20 << 15) | (1 << 12) | (30 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (30 << 20) | (1 << 12) | (6 << 7) | 0x57
  fmv.x.w t2, f6
  li t4, 0x42800000
  bne t2, t4, fail
  .word (0x34 << 26) | (1 << 25) | (28 << 20) | (30 << 15) | (1 << 12) | (28 << 7) | 0x57
  .word (0x12 << 26) | (1 << 25) | (28 << 20) | (20 << 15) | (1 << 12) | (30 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (30 << 20) | (1 << 12) | (6 << 7) | 0x57
  fmv.x.w t2, f6
  li t4, 0x43000000
  bne t2, t4, fail
  .word (0x12 << 26) | (1 << 25) | (30 << 20) | (9 << 15) | (1 << 12) | (28 << 7) | 0x57
  .word (0x12 << 26) | (1 << 25) | (28 << 20) | (19 << 15) | (1 << 12) | (30 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (30 << 20) | (1 << 12) | (6 << 7) | 0x57
  fmv.x.w t2, f6
  bne t2, t4, fail
  .word (0x03 << 26) | (1 << 25) | (30 << 20) | (27 << 15) | (1 << 12) | (31 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (31 << 20) | (1 << 12) | (6 << 7) | 0x57
  fmv.x.w t2, f6
  li t4, 0x43a00000
  bne t2, t4, fail
  .word (0x12 << 26) | (1 << 25) | (27 << 20) | (12 << 15) | (1 << 12) | (28 << 7) | 0x57
  .word (0x33 << 26) | (1 << 25) | (30 << 20) | (28 << 15) | (1 << 12) | (26 << 7) | 0x57
  .word (0x12 << 26) | (1 << 25) | (26 << 20) | (20 << 15) | (1 << 12) | (30 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (30 << 20) | (1 << 12) | (6 << 7) | 0x57
  fmv.x.w t2, f6
  bne t2, t4, fail
  csrw 0x003, zero
  fmv.w.x f5, zero
  .word (0x17 << 26) | (1 << 25) | (5 << 15) | (5 << 12) | (24 << 7) | 0x57
  .word (0x13 << 26) | (1 << 25) | (24 << 20) | (5 << 15) | (1 << 12) | (25 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (25 << 20) | (1 << 12) | (6 << 7) | 0x57
  fmv.x.w t2, f6
  li t4, 0x7f800000
  bne t2, t4, fail
  csrr t2, 0x003
  andi t2, t2, 31
  li t4, 8
  bne t2, t4, fail
  li t0, 4
  .word (0xc0 << 20) | (5 << 15) | (7 << 12) | 0x57
  la t3, vector_scratch
  slli t4, s0, 4
  add t3, t3, t4
  li t4, 0x12345678
  sw t4, 0(t3)
  li t4, 0x6abcdef0
  sw t4, 4(t3)
  li t4, 0x11223344
  sw t4, 8(t3)
  li t4, 0x55667788
  sw t4, 12(t3)
  li t0, 2
  .word (0xd8 << 20) | (5 << 15) | (7 << 12) | (6 << 7) | 0x57
  .word (1 << 25) | (28 << 15) | (7 << 12) | (8 << 7) | 0x07
  sw zero, 0(t3)
  sw zero, 4(t3)
  sw zero, 8(t3)
  sw zero, 12(t3)
  .word (1 << 25) | (28 << 15) | (7 << 12) | (8 << 7) | 0x27
  lw t2, 0(t3)
  li t4, 0x12345678
  bne t2, t4, fail
  lw t2, 4(t3)
  li t4, 0x6abcdef0
  bne t2, t4, fail
  lw t2, 8(t3)
  li t4, 0x11223344
  bne t2, t4, fail
  lw t2, 12(t3)
  li t4, 0x55667788
  bne t2, t4, fail
  li t0, 4
  .word (0xc0 << 20) | (5 << 15) | (7 << 12) | 0x57
#endif
#if defined(NEMU_TEST_H_GSTAGE) && defined(NEMU_TEST_VECTOR_DATA)
  la t3, h_gstage_fof_data
  slli t4, s0, 12
  add t3, t3, t4
  li t4, 4094
  add t4, t3, t4
  li t0, 0x11
  sb t0, 0(t4)
  li t0, 0x22
  sb t0, 1(t4)
  la t4, h_gstage_leaves
  slli t0, s0, 12
  add t4, t4, t0
  srli t0, t3, 12
  slli t0, t0, 10
  ori t0, t0, 0xdf
  sd t0, 0(t4)
  sd zero, 8(t4)
  la t4, h_vstage_leaves
  slli t0, s0, 12
  add t4, t4, t0
  li t0, 0x41001000
  srli t0, t0, 12
  slli t0, t0, 10
  ori t0, t0, 0xd7
  sd t0, 8(t4)
  la t0, h_gstage_roots
  slli t1, s0, 14
  add t0, t0, t1
  srli t0, t0, 12
  li t1, 0x8000000000000000
  or t0, t0, t1
  csrw 0x680, t0
  .word 0x62000073
  li t0, 0x40000000
  srli t0, t0, 12
  li t1, 0x8000000000000000
  or t0, t0, t1
  csrw 0x280, t0
  .word 0x22000073
  li t0, 4
  .word (0xc0 << 20) | (5 << 15) | (7 << 12) | (6 << 7) | 0x57
  li t3, 0x44000ffe
  csrr t5, mstatus
  li t6, -0x1801
  and t6, t5, t6
  li t4, 0x8000020000
  or t6, t6, t4
  csrw mstatus, t6
  .word (1 << 25) | (16 << 20) | (28 << 15) | (30 << 7) | 0x07
  csrw mstatus, t5
  csrr t0, 0xc20
  li t1, 2
  bne t0, t1, fail
  csrr t0, 0x008
  bnez t0, fail
  la t3, vector_scratch
  slli t4, s0, 4
  add t3, t3, t4
  .word (1 << 25) | (28 << 15) | (30 << 7) | 0x27
  lbu t0, 0(t3)
  li t1, 0x11
  bne t0, t1, fail
  lbu t0, 1(t3)
  li t1, 0x22
  bne t0, t1, fail
  li t0, 4
  .word (0xc0 << 20) | (5 << 15) | (7 << 12) | (6 << 7) | 0x57
  li t3, 0x44001000
  li s5, 1
  csrr t5, mstatus
  li t6, -0x1801
  and t6, t5, t6
  li t4, 0x8000020000
  or t6, t6, t4
  csrw mstatus, t6
  .word (1 << 25) | (16 << 20) | (28 << 15) | (30 << 7) | 0x07
  csrw mstatus, t5
  li t0, 2
  bne s5, t0, fail
  li s5, 0
  csrr t0, 0xc20
  li t1, 4
  bne t0, t1, fail
  csrr t0, 0x008
  bnez t0, fail
  csrw 0x280, zero
  csrw 0x680, zero
#endif
#ifdef NEMU_TEST_VECTOR_FP
  li t0, 0x200
  csrs mstatus, t0
  csrw fcsr, zero
  addi t0, s0, 1
  fcvt.s.w f2, t0
  li t1, 4
  .word (0xd0 << 20) | (6 << 15) | (7 << 12) | (6 << 7) | 0x57
  .word (0x17 << 26) | (1 << 25) | (2 << 15) | (5 << 12) | (8 << 7) | 0x57
  .word (1 << 25) | (8 << 20) | (2 << 15) | (5 << 12) | (10 << 7) | 0x57
  .word (0x24 << 26) | (1 << 25) | (10 << 20) | (2 << 15) | (5 << 12) | (12 << 7) | 0x57
  .word (0x20 << 26) | (1 << 25) | (12 << 20) | (2 << 15) | (5 << 12) | (14 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (14 << 20) | (1 << 12) | (3 << 7) | 0x57
  fcvt.w.s t2, f3
  slli t3, t0, 1
  bne t2, t3, fail
  li t4, 3
  fcvt.s.w f4, t4
  .word (0x20 << 26) | (1 << 25) | (8 << 20) | (4 << 15) | (5 << 12) | (24 << 7) | 0x57
  li t5, 2
  sub t5, s0, t5
  snez t5, t5
  csrr t2, fflags
  bne t2, t5, fail
  csrw fflags, zero
  fcvt.d.w f2, t0
  li t1, 2
  .word (0xd8 << 20) | (6 << 15) | (7 << 12) | (6 << 7) | 0x57
  .word (0x17 << 26) | (1 << 25) | (2 << 15) | (5 << 12) | (16 << 7) | 0x57
  .word (1 << 25) | (16 << 20) | (2 << 15) | (5 << 12) | (18 << 7) | 0x57
  .word (0x24 << 26) | (1 << 25) | (18 << 20) | (2 << 15) | (5 << 12) | (20 << 7) | 0x57
  .word (0x20 << 26) | (1 << 25) | (20 << 20) | (2 << 15) | (5 << 12) | (22 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (22 << 20) | (1 << 12) | (3 << 7) | 0x57
  fcvt.w.d t2, f3
  bne t2, t3, fail
  fcvt.d.w f4, t4
  .word (0x20 << 26) | (1 << 25) | (16 << 20) | (4 << 15) | (5 << 12) | (26 << 7) | 0x57
  csrr t2, fflags
  bne t2, t5, fail
#endif
#ifdef NEMU_TEST_ZVBB
  li t4, 0x200
  csrs mstatus, t4
  addi t0, s0, 1
  .word (0xc0 << 20) | (5 << 15) | (7 << 12) | (6 << 7) | 0x57
  .word (0x17 << 26) | (1 << 25) | (5 << 15) | (4 << 12) | (8 << 7) | 0x57
  .word (0x12 << 26) | (1 << 25) | (8 << 20) | (8 << 15) | (2 << 12) | (9 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (9 << 20) | (2 << 12) | (7 << 7) | 0x57
  andi t2, t2, 255
  andi t3, t0, 1
  slli t3, t3, 7
  andi t4, t0, 2
  slli t4, t4, 5
  or t3, t3, t4
  andi t4, t0, 4
  slli t4, t4, 3
  or t3, t3, t4
  bne t2, t3, fail
  .word (0x12 << 26) | (1 << 25) | (8 << 20) | (12 << 15) | (2 << 12) | (10 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (10 << 20) | (2 << 12) | (7 << 7) | 0x57
  sltiu t3, t0, 2
  sltiu t4, t0, 4
  add t3, t3, t4
  addi t3, t3, 5
  bne t2, t3, fail
  .word (0x14 << 26) | (1 << 25) | (8 << 20) | (1 << 15) | (3 << 12) | (11 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (11 << 20) | (2 << 12) | (7 << 7) | 0x57
  andi t2, t2, 255
  srli t3, t0, 1
  andi t4, t0, 1
  slli t4, t4, 7
  or t3, t3, t4
  bne t2, t3, fail
  .word (0x35 << 26) | (1 << 25) | (8 << 20) | (3 << 15) | (3 << 12) | (12 << 7) | 0x57
  .word (0xc8 << 20) | (5 << 15) | (7 << 12) | (6 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (12 << 20) | (2 << 12) | (7 << 7) | 0x57
  slli t3, t0, 3
  bne t2, t3, fail
#endif
#ifdef NEMU_TEST_ZVFHMIN
  li t4, 0x200
  csrs mstatus, t4
  addi t0, s0, 1
  .word (0xc8 << 20) | (5 << 15) | (7 << 12) | (6 << 7) | 0x57
  la t3, zvfhmin_inputs
  slli t4, s0, 1
  add t3, t3, t4
  lhu t4, 0(t3)
  .word (0x17 << 26) | (1 << 25) | (29 << 15) | (4 << 12) | (8 << 7) | 0x57
  .word (0x12 << 26) | (1 << 25) | (8 << 20) | (12 << 15) | (1 << 12) | (10 << 7) | 0x57
  .word (0x12 << 26) | (1 << 25) | (10 << 20) | (20 << 15) | (1 << 12) | (12 << 7) | 0x57
  .word (0x10 << 26) | (1 << 25) | (12 << 20) | (2 << 12) | (7 << 7) | 0x57
  bne t2, t4, fail
  csrr t2, 0x003
  andi t2, t2, 31
  bnez t2, fail
#endif
  slli t0, s0, 12
  la t1, roots
  add t1, t1, t0
#if __riscv_xlen == 64
  la t2, leaves
  add t2, t2, t0
  srli t3, t2, 12
  slli t3, t3, 10
  ori t3, t3, 1
  sd t3, 0(t1)
  slli t3, s0, 21
#else
  mv t2, t1
  slli t3, s0, 22
#endif
  li t4, 0x80000000
  add t3, t3, t4
  li t4, 0x10000
  add t4, t4, t3
  addi t5, s0, 0x100
  sw t5, 0(t4)
  srli t3, t3, 12
  slli t3, t3, 10
  ori t3, t3, 0xc7
#if __riscv_xlen == 64
  sd t3, 0(t2)
  li t3, 0x8000000000000000
#else
  sw t3, 0(t2)
  li t3, 0x80000000
#endif
  srli t1, t1, 12
  or t1, t1, t3
  csrw satp, t1
  sfence.vma
#ifdef REPLAY_FAULTS
  csrr s9, mstatus
  li s8, 0
  li s7, 0x40000000
  li t0, -6145
  and s10, s9, t0
  li t0, 0x20800
  or s10, s10, t0
  csrw mstatus, s10
  li s6, 15
  sw zero, 0(s7)
  csrw mstatus, s10
  amoadd.w zero, zero, (s7)
  csrw mstatus, s10
  li s6, 13
  lw zero, 0(s7)
  csrw mstatus, s9
  li s6, 0
  li t0, 3
  bne s8, t0, fail
#endif
  li s3, NEMU_MULTIDIFF_ITERATIONS
count_loop:
  csrr s4, mstatus
  li t0, -6145
  and t0, s4, t0
  li t1, 0x20800
  or t0, t0, t1
  csrw mstatus, t0
  li t0, 0x10000
  lw t1, 0(t0)
  csrw mstatus, s4
  bne t1, t5, fail
  li t0, 1
  amoadd.w.aqrl zero, t0, (s2)
  addi t1, s2, 4
retry:
  lr.w.aq t2, (t1)
#ifdef NEMU_TEST_ZAWRS
  .word 0x00d00073
  .word 0x01d00073
#endif
  addi t2, t2, 1
  sc.w.rl t3, t2, (t1)
  bnez t3, retry
  addi s3, s3, -1
  bnez s3, count_loop
#ifdef NEMU_TEST_VECTOR_DATA
  .word (0x10 << 26) | (1 << 25) | (2 << 20) | (2 << 12) | (7 << 7) | 0x57
  addi t0, s0, 3
  slli t0, t0, 1
  bne t2, t0, fail
  li t0, 1
#endif
  addi t1, s2, 8
  amoadd.w.aqrl zero, t0, (t1)
wait_done:
  lw t2, 8(s2)
  li t3, HARTS
  bne t2, t3, wait_done
#if HARTS > 1
  beqz s0, reserve
  li t0, 1
  bne s0, t0, wait_finish
wait_reserved:
  lw t0, 12(s2)
  beqz t0, wait_reserved
  sb zero, 19(s2)
  li t0, 2
  sw t0, 12(s2)
  j wait_finish
reserve:
  addi t0, s2, 16
  lr.w t1, (t0)
  li t2, 1
  sw t2, 12(s2)
wait_interference:
  lw t2, 12(s2)
  li t3, 2
  bne t2, t3, wait_interference
#ifdef NEMU_TEST_ZAWRS
  .word 0x00d00073
  .word 0x01d00073
#endif
  sc.w t2, t1, (t0)
  beqz t2, fail
#endif
  bnez s0, wait_finish
  li t0, HARTS * NEMU_MULTIDIFF_ITERATIONS
  lw t1, 0(s2)
  bne t0, t1, fail
  lw t1, 4(s2)
  bne t0, t1, fail
  fence rw, rw
  li t0, 0x100000
  li t1, 0x5555
  sw t1, 0(t0)
wait_finish:
  j wait_finish
fail:
  li t0, 0x100000
  li t1, 0x3333
  sw t1, 0(t0)
  j fail
trap:
#if defined(NEMU_TEST_H_GSTAGE) && defined(NEMU_TEST_VECTOR_DATA)
  bnez s5, h_vector_fof_trap
#endif
#if defined(NEMU_TEST_H_GSTAGE) && defined(NEMU_TEST_H_SVNAPOT)
  bnez s11, h_napot_trap
#endif
#ifdef REPLAY_FAULTS
  beqz s6, ecall_trap
  csrr t0, mcause
  bne t0, s6, fail
  csrr t0, mtval
  bne t0, s7, fail
  csrr t0, mepc
  addi t0, t0, 4
  csrw mepc, t0
  addi s8, s8, 1
  mret
ecall_trap:
#endif
  csrr t0, mcause
#ifdef NEMU_TEST_H_STATEEN
  li t1, 10
  beq t0, t1, h_stateen_guest_ecall
#endif
  li t1, 11
  bne t0, t1, fail
  csrr t0, mepc
  addi t0, t0, 4
  csrw mepc, t0
  addi s1, s1, 1
  mret
#if defined(NEMU_TEST_H_GSTAGE) && defined(NEMU_TEST_H_SVNAPOT)
h_napot_trap:
  csrr t0, mcause
  li t1, 1
  beq s11, t1, h_napot_vs_fault
  li t1, 3
  bne s11, t1, fail
  li t1, 21
  bne t0, t1, fail
  csrr t0, 0x34b
  li t1, 0x10400000
  bne t0, t1, fail
  li s11, 4
  j h_napot_fault_address
h_napot_vs_fault:
  li t1, 13
  bne t0, t1, fail
  li s11, 2
h_napot_fault_address:
  csrr t0, mtval
  li t1, 0x44000000
  bne t0, t1, fail
  csrr t0, mepc
  addi t0, t0, 4
  csrw mepc, t0
  mret
#endif
#if defined(NEMU_TEST_H_GSTAGE) && defined(NEMU_TEST_VECTOR_DATA)
h_vector_fof_trap:
  li t0, 1
  bne s5, t0, fail
  csrr t0, mcause
  li t1, 21
  bne t0, t1, fail
  csrr t0, mtval
  li t1, 0x44001000
  bne t0, t1, fail
  csrr t0, 0x34b
  li t1, 0x10400400
  bne t0, t1, fail
  csrr t0, mepc
  addi t0, t0, 4
  csrw mepc, t0
  li s5, 2
  mret
#endif
#ifdef NEMU_TEST_H_STATEEN
h_stateen_guest_ecall:
  csrr t0, mstatus
  li t1, 0x8000001800
  not t1, t1
  and t0, t0, t1
  li t1, 0x1800
  or t0, t0, t1
  csrw mstatus, t0
  la t0, h_stateen_guest_done
  csrw mepc, t0
  mret
#endif
.section .data
.balign 64
counters:
  .word 0, 0, 0, 0, 0
#ifdef NEMU_TEST_ZVFHMIN
.balign 2
zvfhmin_inputs:
  .half 0x3c00, 0x4000, 0x4200, 0x4400
#endif
.section .bss
.balign 4096
roots:
  .skip 16384
leaves:
  .skip 16384
#ifdef NEMU_TEST_H_GSTAGE
.balign 16384
h_gstage_roots:
  .skip HARTS * 16384
.balign 4096
h_gstage_middles:
  .skip HARTS * 4096
.balign 4096
h_gstage_leaves:
  .skip HARTS * 4096
.balign 4096
h_gstage_scratch:
  .skip HARTS * 8
.balign 4096
h_gstage_vs_leaves:
  .skip HARTS * 4096
.balign 4096
h_vstage_roots:
  .skip HARTS * 4096
.balign 4096
h_vstage_middles:
  .skip HARTS * 4096
.balign 4096
h_vstage_leaves:
  .skip HARTS * 4096
#ifdef NEMU_TEST_H_SVNAPOT
.balign 4096
h_napot_data:
  .skip (HARTS + 1) * 65536
#endif
#ifdef NEMU_TEST_VECTOR_DATA
.balign 4096
h_gstage_fof_data:
  .skip HARTS * 4096
#endif
#endif
#ifdef NEMU_TEST_VECTOR_DATA
.balign 16
vector_scratch:
  .skip HARTS * 16
#endif
