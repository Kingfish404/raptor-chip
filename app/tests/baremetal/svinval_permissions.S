/* Svinval M/S/U and TVM transitions; independent precise illegal-trap checks. */
.option norvc
.option norelax
#ifndef SINVAL_PRIV
#define SINVAL_PRIV 0
#endif
.section .text
.globl _start
_start:
  la t0, handler
  csrw mtvec, t0
  csrw mie, zero
  csrw medeleg, zero
  csrw satp, zero
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
  li s0, 0
  li s1, 0
  li s10, 0
enter:
  la t0, body
  csrw mepc, t0
  li t0, (SINVAL_PRIV << 11)
  slli t1, s0, 20 /* TVM */
  or t0, t0, t1
  csrw mstatus, t0
  mret
.macro probe allow, instruction:vararg
  la s5, 991f
  la s7, 992f
  xori s6, \allow, 1
  li a0, 0x123
991:
  \instruction
992:
  bnez s6, fail
.endm
body:
#if SINVAL_PRIV == 3
  li t2, 1
#elif SINVAL_PRIV == 1
  xori t2, s0, 1
#else
  li t2, 0
#endif
  probe t2, .word 0x16000073 /* SINVAL.VMA x0,x0 */
  li a1, 0x40000000
  li a2, 511
  probe t2, .word 0x16c58073 /* SINVAL.VMA a1,a2 */
#if SINVAL_PRIV == 0
  li t2, 0
#else
  li t2, 1
#endif
  probe t2, .word 0x18000073 /* SFENCE.W.INVAL */
  probe t2, .word 0x18100073 /* SFENCE.INVAL.IR */
  li t2, 0
  probe t2, .word 0x16000573 /* reserved nonzero rd */
  probe t2, .word 0x18000573
  probe t2, .word 0x18100573
  li s5, 0
  la s7, done_body
done_body:
  ecall
  j fail
next:
  addi s0, s0, 1
  li t0, 2
  blt s0, t0, enter
  bnez s6, fail
  li t0, 0x100000
  li t1, 0x5555
  sw t1, 0(t0)
1: j 1b
.balign 4
handler:
  beqz s5, finish_mode
  li t3, 1
  bne s6, t3, fail
  csrr t3, mcause
  li t4, 2
  bne t3, t4, fail
  csrr t3, mepc
  bne t3, s5, fail
  lw t4, 0(s5)
#if __riscv_xlen == 64
  slli t4, t4, 32
  srli t4, t4, 32
#endif
  csrr t3, mtval
  bne t3, t4, fail
  li t3, 0x123
  bne a0, t3, fail
  li s6, 0
  addi s10, s10, 1
  csrw mepc, s7
  mret
finish_mode:
  csrr t3, mcause
  li t4, (8 + SINVAL_PRIV)
  bne t3, t4, fail
  csrr t3, mepc
  bne t3, s7, fail
  li t3, (3 << 11)
  csrs mstatus, t3
  la t3, next
  csrw mepc, t3
  mret
fail:
  li t0, 0x100000
  li t1, 0x3333
  sw t1, 0(t0)
2: j 2b
