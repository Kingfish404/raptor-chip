/* Sv39 4 KiB <-> 2 MiB / 1 GiB instruction mapping replacement.
 * Immutable code returns 1 through a superpage and 2 through 4 KiB pages.
 * Six instruction offsets, 16 replacements each, two calls per replacement.
 * TEST_LEVEL=1 or 2; TEST_INVALIDATION=0 SFENCE / 1 Svinval sequence.
 * TEST_GLOBAL=1 marks the superpage leaf global. Omission is sensitivity only.
 */
#if __riscv_xlen != 64
#error This Sv39 test requires RV64
#endif
#ifndef TEST_LEVEL
#define TEST_LEVEL 1
#endif
#ifndef TEST_INVALIDATION
#define TEST_INVALIDATION 0
#endif
#ifndef TEST_GLOBAL
#define TEST_GLOBAL 0
#endif
#define TEST_GBIT (TEST_GLOBAL * 0x20)
#if TEST_LEVEL != 1 && TEST_LEVEL != 2
#error Invalid superpage level
#endif
.macro INVALIDATE
#if TEST_INVALIDATION == 0
  sfence.vma zero, zero
#elif TEST_INVALIDATION == 1
  sfence.w.inval
  sinval.vma zero, zero
  sfence.inval.ir
#else
#error Invalid invalidation mode
#endif
.endm
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
  li t0, 0x200000cf
  sd t0, 16(t3) /* Independent identity mapping for supervisor execution. */
  la t1, level1
  la t0, leaves
  srli t0, t0, 2
  ori t0, t0, 1
  sd t0, 8(t1) /* VA 0x40200000 uses VPN[1]=1. */
  la t1, leaves
  li t0, (0x80400000 >> 2) | 0x4b | TEST_GBIT
  sd t0, 0(t1)
  addi t0, t0, 1024
  sd t0, 8(t1)
  la t0, level1
  srli t0, t0, 2
  ori t0, t0, 1
  sd t0, 8(t3)
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
  li s0, 0x80200000
  li s1, 0x80400000
  la s2, offsets
  li s3, 6
  li s6, 0
  la s7, root
#if TEST_LEVEL == 1
  la s7, level1
#endif
  addi s7, s7, 8
next_site:
  lw t0, 0(s2)
  add t1, s0, t0
  add t2, s1, t0
  li s5, 0x40200000
  add s5, s5, t0
  li t3, 0x00008067
  sw t3, 4(t1)
  sw t3, 4(t2)
  li t3, 0x00100513
  sw t3, 0(t1)
  li t3, 0x00200513
  sw t3, 0(t2)
  fence.i /* Code bytes are fixed throughout the following remap loop. */
  li s8, 1
  jal ra, install_mapping
  jalr ra, s5, 0
  li t0, 1
  bne a0, t0, fail
  li s4, 0
remap:
  andi t0, s4, 1
  beqz t0, choose_new
  li s8, 1
  j install
choose_new:
  li s8, 2
install:
  jal ra, install_mapping
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
/* Replace a leaf with a non-leaf or vice versa. Clear V and globally
 * invalidate before installing the replacement, then order the new PTE.
 * No instruction access occurs in the deliberately invalid interval. */
install_mapping:
#ifndef OMIT_REMAP_INVALIDATION
  sd zero, 0(s7)
  INVALIDATE
#endif
  li t0, 1
  beq s8, t0, install_large
#if TEST_LEVEL == 2
  la t0, level1
#else
  la t0, leaves
#endif
  srli t0, t0, 2
  ori t0, t0, 1
  j write_pte
install_large:
#if TEST_LEVEL == 2
  li t0, (0x80000000 >> 2) | 0x4b | TEST_GBIT
#else
  li t0, (0x80200000 >> 2) | 0x4b | TEST_GBIT
#endif
write_pte:
  sd t0, 0(s7)
#ifndef OMIT_REMAP_INVALIDATION
  INVALIDATE
#endif
  ret
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
root: .zero 4096
level1: .zero 4096
leaves: .zero 4096
