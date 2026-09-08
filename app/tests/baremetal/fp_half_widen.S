/* Reference table generated independently with SoftFloat by recovery235.
 * Full FPR stores check boxed single results on RV32 and RV64. */
.option norvc
.option norelax
#if CASE_KIND == 0
#define FUNCT7 0x20
#else
#define FUNCT7 0x21
#endif
.macro probe rm, mode
  li t0, ((\mode << 5) | 8)
  csrw fcsr, t0
  fld ft0, 0(s1)
  .word ((FUNCT7 << 25) | (2 << 20) | (\rm << 12) | (2 << 7) | 0x53)
  csrr t0, fcsr
  lw t1, 16(s1)
  ori t1, t1, ((\mode << 5) | 8)
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 8(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 12(s1)
  bne t0, t1, fail
.endm
.macro illegal rm, mode
  li t0, ((\mode << 5) | 8)
  csrw fcsr, t0
  fld ft2, 0(s3)
  li s4, 1
  .word ((FUNCT7 << 25) | (2 << 20) | (\rm << 12) | (2 << 7) | 0x53)
  bnez s4, fail
  csrr t0, fcsr
  li t1, ((\mode << 5) | 8)
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 0(s3)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 4(s3)
  bne t0, t1, fail
.endm
.section .text
.globl _start
_start:
  la t0, trap
  csrw mtvec, t0
  csrw mie, zero
  li t0, 0x6000
  csrs mstatus, t0
  li s4, 0
  li s5, 0
  la s0, result
  la s1, cases
  li s2, 800
loop:
  probe 0, 1
  probe 1, 2
  probe 2, 3
  probe 3, 4
  probe 4, 0
  probe 7, 0
  probe 7, 1
  probe 7, 2
  probe 7, 3
  probe 7, 4
  addi s1, s1, 24
  addi s2, s2, -1
  bnez s2, loop
  la s3, sentinel
  illegal 5, 0
  illegal 6, 0
  illegal 7, 5
  illegal 7, 6
  illegal 7, 7
  li t0, 5
  bne s5, t0, fail
  li a0, 0
  ebreak
1: j 1b
trap:
  beqz s4, fail
  csrr t0, mcause
  li t1, 2
  bne t0, t1, fail
  li s4, 0
  addi s5, s5, 1
  csrr t0, mepc
  addi t0, t0, 4
  csrw mepc, t0
  mret
fail:
  li a0, 1
  ebreak
2: j 2b
.section .data
.balign 8
result: .quad 0
sentinel: .quad 0x0123456789abcdef
cases:
#include "half_widen_cases.inc"
