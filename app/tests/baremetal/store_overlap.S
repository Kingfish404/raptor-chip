/* A nonaligned store overlaps a later aligned-word byte load.
 * Warm the load line before the store; no interposed fence is required. */
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, fail
  csrw mtvec, t0
  csrw mstatus, zero
  la s0, area
#if __riscv_xlen == 64
  sd zero, 0(s0)
  sd zero, 8(s0)
#define NEXT 8
#define LAST 7
#else
  sw zero, 0(s0)
  sw zero, 4(s0)
#define NEXT 4
#define LAST 3
#endif
  fence rw,rw
  lbu t0, NEXT(s0)
  li s1, 0x11223344
  li s2, 32
1:
#if __riscv_xlen == 64
  sd s1, LAST(s0)
#else
  sw s1, LAST(s0)
#endif
  lbu t2, NEXT(s0)
  srli t3, s1, 8
  andi t3, t3, 255
  bne t2, t3, fail
  addi s1, s1, 256
  addi s2, s2, -1
  bnez s2, 1b
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
  j fail
.section .data
.balign 64
area: .zero 64
