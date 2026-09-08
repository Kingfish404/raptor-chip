/* Real Sv39 page tables: VA synonyms and remapping to a different PA.
 * Different-VA LR/SC may succeed or fail; verify memory for either outcome.
 * This is not a proof of RsrvEventual or reservation-set geometry. */
#if __riscv_xlen != 64
#error Sv39 requires RV64
#endif
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, fail
  csrw mtvec, t0
  csrw stvec, t0
  csrw mie, zero
  csrw medeleg, zero
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
  la s0, root
  li t0, 0x200000cf
  sd t0, 16(s0)
  la t0, l1
  srli t0, t0, 2
  ori t0, t0, 1
  sd t0, 8(s0)
  la t1, l1
  la t0, l0
  srli t0, t0, 2
  ori t0, t0, 1
  sd t0, 0(t1)
  la s1, l0
  la t0, page0
  srli t0, t0, 2
  ori t0, t0, 0xc7
  sd t0, 0(s1)
  sd t0, 8(s1)
  la t0, page1
  srli t0, t0, 2
  ori t0, t0, 0xc7
  sd t0, 16(s1)
  srli t0, s0, 12
  li t1, 0x8000000000000000
  or t0, t0, t1
  csrw satp, t0
  sfence.vma
  li t0, 0x800
  csrw mstatus, t0
  la t0, supervisor
  csrw mepc, t0
  mret
supervisor:
  li s0, 0x40000000
  li s2, 0x40001000
  li s3, 0x40002000
  li s7, 0
  li s8, 0
  li s9, 4
  li s10, 0
next:
  sd zero, 0(s0)
  sd zero, 0(s3)
  li t2, 0x55
  li t6, 8
  beq s9, t6, double_alias
  lr.w t0, (s0)
  sc.w t1, t2, (s2)
  j alias_check
double_alias:
  lr.d t0, (s0)
  sc.d t1, t2, (s2)
alias_check:
  ld t3, 0(s0)
  bnez t1, alias_failed
  bne t3, t2, fail
  addi s8, s8, 1
  j consumed
alias_failed:
  bnez t3, fail
consumed:
  sc.d t1, zero, (s0)
  beqz t1, fail
  addi s7, s7, 1
  /* A new LR at a different physical page replaces the old one. */
  lr.d t0, (s0)
  lr.d t0, (s3)
  sc.d t1, zero, (s2)
  beqz t1, fail
  ld t4, 0(s0)
  bne t4, t3, fail
  sc.d t1, t2, (s3)
  beqz t1, fail
  ld t4, 0(s3)
  bnez t4, fail
  addi s7, s7, 1
  /* Warm the alias TLB, then remap it. LR uses the old physical page;
   * SC through the same alias must use the new mapping after SFENCE. */
  ld t0, 0(s2)
  la t0, page1
  srli t0, t0, 2
  ori t0, t0, 0xc7
  sd t0, 8(s1)
#ifndef OMIT_REMAP_SFENCE
  sfence.vma s2, zero
#endif
  lr.d t0, (s0)
  sc.d t1, t2, (s2)
  beqz t1, fail
  ld t4, 0(s3)
  bnez t4, fail
  ld t4, 0(s0)
  bne t4, t3, fail
  addi s7, s7, 1
  la t0, page0
  srli t0, t0, 2
  ori t0, t0, 0xc7
  sd t0, 8(s1)
  sfence.vma s2, zero
  addi s10, s10, 1
  li t0, 4
  bltu s10, t0, next
  li t0, 8
  beq s9, t0, done
  mv s9, t0
  li s10, 0
  j next
done:
  li t0, 24
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
root: .zero 4096
l1: .zero 4096
l0: .zero 4096
page0: .zero 4096
page1: .zero 4096
