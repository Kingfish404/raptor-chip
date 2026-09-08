/* Immutable code, changing leaf mappings: no FENCE.I between remaps.
 * TEST_INVALIDATION: 0=global SFENCE.VMA, 1=per-page SFENCE.VMA,
 * 2=SFENCE.W.INVAL + per-page SINVAL.VMA + SFENCE.INVAL.IR.
 * OMIT_REMAP_INVALIDATION is a test-sensitivity control, not an ISA rule
 * requiring stale translations in implementations without explicit fences. */
#ifndef TEST_INVALIDATION
#define TEST_INVALIDATION 0
#endif
#if __riscv_xlen == 64
#define PTE_S sd
#define PTE_BYTES 8
#else
#define PTE_S sw
#define PTE_BYTES 4
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
  la t3, root
  li t0, 0x200000cf /* Identity-map RAM for supervisor text/data/PTEs. */
#if __riscv_xlen == 64
  sd t0, 16(t3)
  la t0, level1
  srli t0, t0, 2
  ori t0, t0, 1
  sd t0, 8(t3)
  la t1, level1
  la t0, leaves
  srli t0, t0, 2
  ori t0, t0, 1
  sd t0, 0(t1)
#else
  li t1, 2048
  add t1, t3, t1
  sw t0, 0(t1)
  la t0, leaves
  srli t0, t0, 2
  ori t0, t0, 1
  sw t0, 1024(t3)
#endif
  srli t0, t3, 12
#if __riscv_xlen == 64
  li t1, 0x8000000000000000
#else
  li t1, 0x80000000
#endif
  or t0, t0, t1
  csrw satp, t0
  sfence.vma
  li t0, (1 << 11)
  csrw mstatus, t0
  la t0, run
  csrw mepc, t0
  mret
run:
  la s0, code_old
  la s1, code_new
  la s2, offsets
  li s3, 6
  li s6, 0
  la s7, leaves
next_site:
  lw t0, 0(s2)
  add t1, s0, t0
  add t2, s1, t0
  li s5, 0x40000000
  add s5, s5, t0
  li t3, 0x00008067
  sw t3, 4(t1)
  sw t3, 4(t2)
  li t3, 0x00100513
  sw t3, 0(t1)
  li t3, 0x00200513
  sw t3, 0(t2)
  fence.i /* Code bytes are fixed throughout the following remap loop. */
  srli t0, s0, 2
  ori t0, t0, 0x4b
  PTE_S t0, 0(s7)
  addi t0, t0, 1024
  PTE_S t0, PTE_BYTES(s7)
  sfence.vma
  jalr ra, s5, 0
  li t0, 1
  bne a0, t0, fail
  li s4, 0
remap:
  andi t0, s4, 1
  beqz t0, choose_new
  mv t0, s0
  li s8, 1
  j install
choose_new:
  mv t0, s1
  li s8, 2
install:
  srli t0, t0, 2
  ori t0, t0, 0x4b
  PTE_S t0, 0(s7)
  addi t0, t0, 1024
  PTE_S t0, PTE_BYTES(s7)
#ifndef OMIT_REMAP_INVALIDATION
#if TEST_INVALIDATION == 0
  sfence.vma
#elif TEST_INVALIDATION == 1
  li t0, 0x40000000
  sfence.vma t0, zero
  li t0, 0x40001000
  sfence.vma t0, zero
#elif TEST_INVALIDATION == 2
  sfence.w.inval
  li t0, 0x40000000
  sinval.vma t0, zero
  li t0, 0x40001000
  sinval.vma t0, zero
  sfence.inval.ir
#else
#error Unsupported TEST_INVALIDATION
#endif
#endif
  jalr ra, s5, 0
  bne a0, s8, fail
  jalr ra, s5, 0
  bne a0, s8, fail
  addi s6, s6, 1
  addi s4, s4, 1
  li t0, 16
  bltu s4, t0, remap
  addi s2, s2, 4
  addi s3, s3, -1
  bnez s3, next_site
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
.section .data
.balign 4
offsets: .word 0, 2, 60, 62, 4092, 4094
.balign 4096
code_old: .zero 8192
code_new: .zero 8192
root: .zero 4096
level1: .zero 4096
leaves: .zero 4096
