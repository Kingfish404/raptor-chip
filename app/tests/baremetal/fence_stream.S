/* Executed FENCE/FENCE.TSO streams in M/S/U with delayed memory responses.
 * Checks decode, retirement, register preservation and liveness. A single
 * hart's final values do not prove external memory ordering; see composed TB. */
#ifndef TEST_PRIV
#define TEST_PRIV 3
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
  li t0, (TEST_PRIV << 11)
  csrw mstatus, t0
  la t0, run
  csrw mepc, t0
  mret
.macro stream encoding
  sw s2, 0(s0)
  .word \encoding
  lw t1, 0(s0)
  bne t1, s2, fail
  .word \encoding
#ifdef TEST_MSIP
  sw zero, 0(s0)
  lw t2, 0(s0)
  bnez t2, fail
#else
  sw t1, 8(s0)
  lw t2, 8(s0)
  bne t1, t2, fail
#endif
  addi s1, s1, 1
#ifndef TEST_MSIP
  addi s2, s2, 1
#endif
.endm
run:
#ifdef TEST_MSIP
  li s0, 0x02000000 /* CLINT MSIP; interrupts remain disabled. */
#else
  la s0, area
#endif
  li s1, 0
  li s2, 1
  li s3, 128
1:
  stream 0x0330000f
  stream 0x8330000f
  stream 0x0ff0000f
#ifndef TEST_MSIP
  addi s0, s0, 64
#endif
  addi s3, s3, -1
  bnez s3, 1b
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
  li t0, 384
  bne s1, t0, bad
  li a0, 0
  ebreak
bad:
  li a0, 1
  ebreak
  j bad
.section .data
.balign 4096
area: .zero 8192
