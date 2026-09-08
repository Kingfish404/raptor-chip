/* FENCE.I visibility: warm old code, patch, then execute without an extra
 * data FENCE. Halfword offsets include 32-bit instructions straddling a
 * 64-byte block and a 4-KiB boundary. Bare M/S/U, single hart. */
#ifndef TEST_PRIV
#define TEST_PRIV 3
#endif
#if __riscv_xlen == 64
#define PTE_S sd
#define PTE_BYTES 8
#else
#define PTE_S sw
#define PTE_BYTES 4
#endif
#if TEST_PRIV == 0
#define PTE_USER 0x10
#else
#define PTE_USER 0
#endif
#ifdef TEST_TRANSLATED_ALIAS
#define EXEC_REG s5
#else
#define EXEC_REG s3
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
#ifdef TEST_TRANSLATED_ALIAS
#if TEST_PRIV == 3
#error Translated alias test requires S or U mode
#endif
  la t3, root
  /* Identity map test text, data and page tables in the main RAM region. */
  li t0, (0x200000cf | PTE_USER)
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
  la t1, leaves
  la t0, code
  srli t0, t0, 2
  li t2, (0xc7 | PTE_USER)
  or t2, t2, t0
  PTE_S t2, 0(t1) /* VA 40000000 RW, not executable. */
  addi t2, t2, 1024
  PTE_S t2, PTE_BYTES(t1)
  li t2, (0x4b | PTE_USER)
  or t2, t2, t0
  PTE_S t2, (2*PTE_BYTES)(t1) /* VA 40002000 RX, not writable. */
  addi t2, t2, 1024
  PTE_S t2, (3*PTE_BYTES)(t1)
  srli t0, t3, 12
#if __riscv_xlen == 64
  li t1, 0x8000000000000000
#else
  li t1, 0x80000000
#endif
  or t0, t0, t1
  csrw satp, t0
  sfence.vma
#endif
  li t0, (TEST_PRIV << 11)
  csrw mstatus, t0
  la t0, run
  csrw mepc, t0
  mret
run:
#ifdef TEST_TRANSLATED_ALIAS
  li s0, 0x40000000
#else
  la s0, code
#endif
  la s1, offsets
  li s2, 6
  li s6, 0
next_site:
  lw t0, 0(s1)
  add s3, s0, t0
#ifdef TEST_TRANSLATED_ALIAS
  li s5, 8192
  add s5, s3, s5
#endif
  li t0, 0x00008067 /* jalr x0, ra, 0 */
  sw t0, 4(s3)
  li t0, 0x00100513 /* addi a0, x0, 1 */
  sw t0, 0(s3)
  fence.i
  jalr ra, EXEC_REG, 0
  li t0, 1
  bne a0, t0, fail
  li s4, 2
patch:
  slli t0, s4, 20
  ori t0, t0, 0x513
  sw t0, 0(s3)
#ifdef OMIT_PATCH_FENCE
  nop
#else
  fence.i
#endif
  jalr ra, EXEC_REG, 0
  bne a0, s4, fail
  /* A second call checks that the updated instruction remains cached. */
  jalr ra, EXEC_REG, 0
  bne a0, s4, fail
  addi s6, s6, 1
  addi s4, s4, 1
  li t0, 18
  bltu s4, t0, patch
  addi s1, s1, 4
  addi s2, s2, -1
  bnez s2, next_site
  li a0, 0
  ecall
fail:
  li a0, 1
  ecall
trap:
  bnez a0, bad
  csrr t0, mcause
  li t1, (8 + TEST_PRIV)
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
code: .zero 8192

#ifdef TEST_TRANSLATED_ALIAS
.balign 4096
root: .zero 4096
level1: .zero 4096
leaves: .zero 4096
#endif
