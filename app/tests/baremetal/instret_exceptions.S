/* Synchronous exceptions do not retire. Snapshot immediately before each
 * attempt, then read instret as the handler's first instruction. */
#ifndef INSTRET_PRIV
#define INSTRET_PRIV 3
#endif
.option norvc
.option norelax
.section .text
.globl _start
_start:
  csrw mstatus, zero
  csrw mie, zero
  csrw medeleg, zero
  csrw satp, zero
  la t0, handler
  csrw mtvec, t0
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
  li t0, 7
  csrw mcounteren, t0
  csrw scounteren, t0
  li s10, 0
  li s5, 0
  li a0, 1
  la t0, body
  csrw mepc, t0
  li t0, (INSTRET_PRIV << 11)
  csrw mstatus, t0
  mret
.macro prepare cause
  bnez s5, fail
  la s5, 991f
  la s11, 992f
  li s4, \cause
  li s6, 1
  csrr s0, instret
991:
.endm
body:
  prepare (8 + INSTRET_PRIV)
  ecall
992:
  prepare 3
  ebreak
992:
  prepare 3
  .hword 0x9002
992:
  prepare 2
  .word 0xfe000033
992:
  prepare 2
  .hword 0x0000
992:
  li s3, 0xc0001000
  prepare 5
#ifdef TEST_LOAD_X0
  /* Discarding the value must not suppress the access fault or retirement check. */
  lw zero, 0(s3)
#else
  lw a5, 0(s3)
#endif
992:
  li s3, 0x20001000
  prepare 7
  sw zero, 0(s3)
992:
  bnez s5, fail
  li s5, 0x02000000 /* non-executable CLINT */
  la s11, after_fetch
  li s4, 1
  li s6, 2 /* snapshot CSR and JALR retire; failed target fetch does not */
  csrr s0, instret
  jalr zero, s5, 0
  j fail
after_fetch:
  bnez s5, fail
  li t0, 8
  bne s10, t0, fail
  csrr s0, instret
  nop
  csrr s1, instret
  addi s0, s0, 2
  bne s0, s1, fail
  li t0, 0x100000
  li t1, 0x5555
  sw t1, 0(t0)
1: j 1b
.balign 4
handler:
  csrr s1, instret
  add t0, s0, s6
  bne s1, t0, fail
  csrr t0, mcause
  bne t0, s4, fail
  csrr t0, mepc
  bne t0, s5, fail
  csrr t0, mstatus
  srli t0, t0, 11
  andi t0, t0, 3
  li t1, INSTRET_PRIV
  bne t0, t1, fail
  csrw mepc, s11
  li s5, 0
  addi s10, s10, 1
  mret
fail:
  li t0, 0x100000
  li t1, 0x3333
  sw t1, 0(t0)
2: j 2b
