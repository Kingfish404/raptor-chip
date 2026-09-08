/* Reassociate ASIDs 0, 1 and 511 with two different page-table roots.
 * TEST_GLOBAL: 0=local, 1=leaf G, 2=ancestor G.
 * TEST_SINVAL selects the split invalidation sequence. Global replacements
 * always use rs2=x0; local recycling uses a non-x0 ASID operand, even for 0.
 * Both roots map the supervisor test identically. Code bytes never change. */
#ifndef TEST_GLOBAL
#define TEST_GLOBAL 0
#endif
#ifndef TEST_SINVAL
#define TEST_SINVAL 0
#endif
#if TEST_GLOBAL == 1
#define LEAF_FLAGS 0x6b
#else
#define LEAF_FLAGS 0x4b
#endif
#if TEST_GLOBAL == 2
#define POINTER_FLAGS 0x21
#else
#define POINTER_FLAGS 1
#endif
#if __riscv_xlen == 64
#define PTE_S sd
#define ASID_SHIFT 44
#define MODE_BITS 0x8000000000000000
#else
#define PTE_S sw
#define ASID_SHIFT 22
#define MODE_BITS 0x80000000
#endif
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, trap
  csrw mtvec, t0
  csrw mie, zero
  csrw medeleg, zero
  csrw satp, zero
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 15
  csrw pmpcfg0, t0
  la t3, roots
  la t4, code_old
  li t5, 2
init_root:
  li t0, 0x200000cf
#if __riscv_xlen == 64
  sd t0, 16(t3)
  li t1, 4096
  add t1, t3, t1
  srli t0, t1, 2
  ori t0, t0, POINTER_FLAGS
  sd t0, 8(t3)
  li t2, 8192
  add t2, t3, t2
  srli t0, t2, 2
  ori t0, t0, 1
  sd t0, 0(t1)
#else
  li t1, 2048
  add t1, t3, t1
  sw t0, 0(t1)
  li t2, 8192
  add t2, t3, t2
  srli t0, t2, 2
  ori t0, t0, POINTER_FLAGS
  sw t0, 1024(t3)
#endif
  srli t0, t4, 2
  ori t0, t0, LEAF_FLAGS
  PTE_S t0, 0(t2)
  li t0, 12288
  add t3, t3, t0
  la t4, code_new
  addi t5, t5, -1
  bnez t5, init_root
  la s0, roots
  srli s0, s0, 12
  li t0, MODE_BITS
  or s0, s0, t0
  addi s1, s0, 3
  csrw satp, s0
  sfence.vma
  fence.i
  li t0, (1 << 11)
  csrw mstatus, t0
  la t0, run
  csrw mepc, t0
  mret
run:
  la s2, asids
  li s3, 3
  li s5, 0x40000000
  li s6, 0
next_asid:
  lw s7, 0(s2)
  slli s8, s7, ASID_SHIFT
  or t0, s0, s8
  csrw satp, t0
  sfence.vma /* Establish the first root for this ASID and warm its code. */
  jalr ra, s5, 0
  li t0, 1
  bne a0, t0, fail
  li s4, 0
recycle:
  andi t0, s4, 1
  beqz t0, use_new
  mv t0, s0
  li s9, 1
  j switch_root
use_new:
  mv t0, s1
  li s9, 2
switch_root:
  or t0, t0, s8
  csrw satp, t0
  csrr t1, satp
  bne t0, t1, fail
#ifndef OMIT_RECYCLE_INVALIDATION
#if TEST_SINVAL
  sfence.w.inval
#if TEST_GLOBAL
  sinval.vma zero, zero
#else
  sinval.vma zero, s7
#endif
  sfence.inval.ir
#else
#if TEST_GLOBAL
  sfence.vma zero, zero
#else
  sfence.vma zero, s7
#endif
#endif
#endif
  jalr ra, s5, 0
  bne a0, s9, fail
  jalr ra, s5, 0
  bne a0, s9, fail
  addi s6, s6, 1
  addi s4, s4, 1
  li t0, 32
  bltu s4, t0, recycle
  addi s2, s2, 4
  addi s3, s3, -1
  bnez s3, next_asid
  li a0, 0
  ecall
fail:
  li a0, 1
  ecall
trap:
  bnez a0, bad
  csrr t0, mcause
  li t1, 9
  bne t0, t1, bad
  li t0, 96
  bne s6, t0, bad
  li a0, 0
  ebreak
bad:
  li a0, 1
  ebreak
  j bad
.balign 4096
code_old:
  li a0, 1
  ret
.balign 4096
code_new:
  li a0, 2
  ret
.section .data
.balign 4
asids: .word 0, 1, 511
.balign 4096
roots: .zero 24576
