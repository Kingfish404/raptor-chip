/* LR/SC misalignment must trap, including offsets that ordinary LSU splits.
 * Either address-misaligned or access-fault is permitted by A 2.1. */
.option norvc
.option norelax
.macro CHECK_ATOMIC op, addr, cause
  mv s0, \addr
  li s2, \cause
  li s4, 0
  li t0, 0x6a
  \op t0, (s0)
  beqz s4, fail
  li t1, 0x6a
  bne t0, t1, fail
  addi s3, s3, 1
.endm
.macro CHECK_SC op, addr
  mv s0, \addr
  li s2, 6
  li s4, 0
  li t0, 0x6a
  li t2, 0x55
  \op t0, t2, (s0)
  beqz s4, fail
  li t1, 0x6a
  bne t0, t1, fail
  addi s3, s3, 1
.endm
.section .text
.globl _start
_start:
  la t0, handler
  csrw mtvec, t0
  csrw mie, zero
  csrw mstatus, zero
#ifdef TEST_TRANSLATED_LRSC
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
  la t0, root
  li t1, 0x200000cf
#if __riscv_xlen == 64
  sd t1, 16(t0)
  srli t0, t0, 12
  li t1, 0x8000000000000000
#else
  li t2, 2048
  add t2, t0, t2
  sw t1, 0(t2)
  srli t0, t0, 12
  li t1, 0x80000000
#endif
  or t0, t0, t1
  csrw satp, t0
  sfence.vma
  li t0, 0x800
  csrw mstatus, t0
  la t0, supervisor
  csrw mepc, t0
  mret
supervisor:
#endif
  li s3, 0
  la s1, area
  li s5, 1
word_loop:
  add s6, s1, s5
  CHECK_ATOMIC lr.w, s6, 4
  CHECK_SC sc.w, s6
  addi s5, s5, 1
  li t0, 4
  bltu s5, t0, word_loop
#if __riscv_xlen == 64
  li s5, 1
double_loop:
  add s6, s1, s5
  CHECK_ATOMIC lr.d, s6, 4
  CHECK_SC sc.d, s6
  addi s5, s5, 1
  li t0, 8
  bltu s5, t0, double_loop
#endif
  /* Last byte of page: crosses both word and page boundaries. */
  li t0, 4095
  add s6, s1, t0
  CHECK_ATOMIC lr.w, s6, 4
  CHECK_SC sc.w, s6
#if __riscv_xlen == 64
  CHECK_ATOMIC lr.d, s6, 4
  CHECK_SC sc.d, s6
  li t0, 24
#else
  li t0, 8
#endif
  bne s3, t0, fail
  la t0, area
  li t1, 8192
memory_check:
  lbu t2, 0(t0)
  bnez t2, fail
  addi t0, t0, 1
  addi t1, t1, -1
  bnez t1, memory_check
.globl pass
pass:
  li a0, 0
  ebreak
handler:
  csrr t3, mcause
  beq t3, s2, cause_ok
  addi t4, s2, 1
  bne t3, t4, fail
cause_ok:
  csrr t3, mtval
  bne t3, s0, fail
  li s4, 1
  csrr t3, mepc
  addi t3, t3, 4
  csrw mepc, t3
  mret
fail:
  li a0, 1
  ebreak
  j fail
.section .data
.balign 4096
area: .zero 8192

#ifdef TEST_TRANSLATED_LRSC
.balign 4096
root: .zero 4096
#endif
