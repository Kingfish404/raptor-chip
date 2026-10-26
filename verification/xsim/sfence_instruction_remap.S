/* Full-core RV64 SFENCE remap regression. Static code pages need no FENCE.I.
 * Train branch/return predictions, replace the PTE, then retire every mixed-
 * width arithmetic instruction at the same VA. Covers all SFENCE operand
 * forms at ASID 7. Define SFENCE_REMAP_SUPERPAGE for 2 MiB leaves.
 * Exit a0=0 succeeds; 1..4 identify result checks, >=64 identifies a trap.
 */
#ifndef SFENCE_REMAP_ASID
#define SFENCE_REMAP_ASID 7
#endif
.option norvc
.option norelax
.section .text
.global _start
_start:
  la sp, stack_top
  la t0, trap
  csrw mtvec, t0
  csrw stvec, t0
  csrw medeleg, zero
  csrw mideleg, zero
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x0f
  csrw pmpcfg0, t0
  la t0, tables
  li t1, 1536
1:
  sd zero, 0(t0)
  addi t0, t0, 8
  addi t1, t1, -1
  bnez t1, 1b
  la t0, root
  li t1, 0x200000cf
  sd t1, 16(t0)                 # Identity 1 GiB leaf, PA 0x80000000.
  la t1, middle
  srli t1, t1, 2
  ori t1, t1, 1
  sd t1, 8(t0)                  # VA 0x40000000, root[1].
  la t0, middle
  la t1, leaves
  srli t1, t1, 2
  ori t1, t1, 1
  sd t1, 0(t0)
  la t0, root
  srli t0, t0, 12
  li t1, (0x8000000000000000 | (SFENCE_REMAP_ASID << 44))
  or t0, t0, t1
  csrw satp, t0
  sfence.vma zero, zero
  la t0, supervisor
  csrw mepc, t0
  li t0, 0x1800
  csrc mstatus, t0
  li t0, 0x800
  csrs mstatus, t0
  mret
supervisor:
#ifdef SFENCE_REMAP_SUPERPAGE
  li s0, 0x40001000
#else
  li s0, 0x40000000
#endif
  addi s1, s0, 64
#ifdef SFENCE_REMAP_SUPERPAGE
  la s2, middle
#else
  la s2, leaves
#endif
  li s3, 1
  la s4, old_page
#ifdef SFENCE_REMAP_SUPERPAGE
  srli s4, s4, 21
  slli s4, s4, 19
#else
  srli s4, s4, 2
#endif
  ori s4, s4, 0xcb
  la s5, new_page
#ifdef SFENCE_REMAP_SUPERPAGE
  srli s5, s5, 21
  slli s5, s5, 19
#else
  srli s5, s5, 2
#endif
  ori s5, s5, 0xcb
  li s6, 0
  li s8, 0
round:
  sd s4, 0(s2)
  call do_sfence
  li s7, 64
train:
  li a0, 0
  jalr ra, s0, 0
  li t0, 1
  bne a0, t0, fail_old
  li a0, 0
  jalr ra, s1, 0
  bnez a0, fail_return
  addi s7, s7, -1
  bnez s7, train
  sd s5, 0(s2)
  call do_sfence
  li s7, 8
check_new:
  li a0, 0
  jalr ra, s0, 0
  li t0, 31
  bne a0, t0, fail_new
  li a0, 0
  jalr ra, s1, 0
  li t0, 31
  bne a0, t0, fail_new_return
  addi s7, s7, -1
  bnez s7, check_new
  addi s8, s8, 1
  addi s6, s6, 1
  andi s6, s6, 3
  li t0, 16
  bltu s8, t0, round
  li a0, 0
  ebreak
halt:
  j halt

do_sfence:
  li t0, SFENCE_REMAP_ASID
  beqz s6, fence_all
  li t1, 1
  beq s6, t1, fence_va
  li t1, 2
  beq s6, t1, fence_asid
  sfence.vma s0, t0
  ret
fence_all:
  sfence.vma zero, zero
  ret
fence_va:
  sfence.vma s0, zero
  ret
fence_asid:
  sfence.vma zero, t0
  ret
fail_old:
  li a0, 1
  ebreak
fail_return:
  li a0, 2
  ebreak
fail_new:
  li a0, 3
  ebreak
fail_new_return:
  li a0, 4
  ebreak
trap:
  csrr a0, mcause
  addi a0, a0, 64
  ebreak

.balign 4096
old_page:
  bnez s3, old_target
  addi a0, a0, 100
  nop
  nop
old_target:
  addi a0, a0, 1
  ret
.balign 64
old_return:
  ret
#ifdef SFENCE_REMAP_SUPERPAGE
.org 0x201000 # Same 4 KiB offset in the next physical 2 MiB region.
#else
.balign 4096
#endif
new_page:
.option rvc
  c.addi a0, 1
  c.addi a0, 2
.option norvc
  addi a0, a0, 4
  addi a0, a0, 8
  nop
  addi a0, a0, 16
  ret
.balign 64
new_return:
.option rvc
  c.addi a0, 1
  c.addi a0, 2
.option norvc
  addi a0, a0, 4
  addi a0, a0, 8
  nop
  addi a0, a0, 16
  ret
.section .data
.balign 4096
tables:
root:
  .space 4096
middle:
  .space 4096
leaves:
  .space 4096
.balign 16
  .space 4096
stack_top:
