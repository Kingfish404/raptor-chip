/* Exercise live M/S/U counter enable changes, with independent trap checks. */
.option norvc
.option norelax
#ifndef COUNTER_PRIV
#define COUNTER_PRIV 0
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
  csrw mcounteren, s0
  csrw scounteren, s1
  la t0, body
  csrw mepc, t0
  li t0, (COUNTER_PRIV << 11)
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
.macro counter addr, bit, high
#if COUNTER_PRIV == 3
  li t2, 1
#elif COUNTER_PRIV == 1
  srli t2, s0, \bit
  andi t2, t2, 1
#else
  and t2, s0, s1
  srli t2, t2, \bit
  andi t2, t2, 1
#endif
#if __riscv_xlen == 64
  .if \high
    li t2, 0
  .endif
#endif
  probe t2, csrrs a0, \addr, zero
  probe t2, csrrci zero, \addr, 0
  li t2, 0
  probe t2, csrrw zero, \addr, zero
  li a1, 0 /* non-x0 zero operand still expresses write intent */
  probe t2, csrrs a0, \addr, a1
.endm
body:
  counter 0xc00, 0, 0
  counter 0xc01, 1, 0
  counter 0xc02, 2, 0
  counter 0xc80, 0, 1
  counter 0xc81, 1, 1
  counter 0xc82, 2, 1
  li s5, 0
  la s7, done_body
done_body:
  ecall
  j fail
next:
  addi s1, s1, 1
  li t0, 8
  blt s1, t0, enter
  li s1, 0
  addi s0, s0, 1
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
  li t4, (8 + COUNTER_PRIV)
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
