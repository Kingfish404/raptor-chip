/* CLINT platform byte/halfword accesses preserve byte addresses and all
 * unselected bytes. Standard word/doubleword accesses remain supported. */
#ifndef CLINT_SUBWORD_CASE
#define CLINT_SUBWORD_CASE 0
#endif
#include "clint_subword_translate.h"
.option norvc
.option norelax
.section .text
.globl _start
_start:
  csrw mstatus, zero
  csrw mie, zero
  la t0, fail
  csrw mtvec, t0
  clint_subword_translation_setup
  li s0, (0x02004000 + CLINT_VA_DELTA)
  la s1, expected
  lw t0, 0(s1)
  sw t0, 0(s0)
  lw t0, 4(s1)
  sw t0, 4(s0)
  fence iorw,iorw
#if CLINT_SUBWORD_CASE == 0
  call check_bytes
  li s2, 0
read_halves:
  add t0, s0, s2
  lhu t1, 0(t0)
  add t0, s1, s2
  lhu t2, 0(t0)
  bne t1, t2, fail
  addi s2, s2, 2
  li t0, 8
  bltu s2, t0, read_halves
#elif CLINT_SUBWORD_CASE == 1
  li s2, 0
write_bytes:
  addi t1, s2, 0xa0
  add t0, s0, s2
  sb t1, 0(t0)
  add t0, s1, s2
  sb t1, 0(t0)
  fence iorw,iorw
  call check_bytes
  addi s2, s2, 1
  li t0, 8
  bltu s2, t0, write_bytes
  li s2, 0
write_halves:
  li t1, 0x5a00
  add t1, t1, s2
  add t0, s0, s2
  sh t1, 0(t0)
  add t0, s1, s2
  sh t1, 0(t0)
  fence iorw,iorw
  call check_bytes
  addi s2, s2, 2
  li t0, 8
  bltu s2, t0, write_halves
#elif CLINT_SUBWORD_CASE == 2
  li s0, (0x0200bff8 + CLINT_VA_DELTA)
  li t0, 0x12
  sb t0, 7(s0)
  fence iorw,iorw
  lbu t1, 7(s0)
  bne t1, t0, fail
  li t0, 0x2345
  sh t0, 6(s0)
  fence iorw,iorw
  lhu t1, 6(s0)
  bne t1, t0, fail
#if __riscv_xlen == 64
  rdtime t1
  srli t1, t1, 48
#else
  rdtimeh t1
  srli t1, t1, 16
#endif
  bne t1, t0, fail
#elif CLINT_SUBWORD_CASE == 3
  /* The MSIP high bytes are read-only zero; writing them leaves bit 0. */
  li s0, (0x02000000 + CLINT_VA_DELTA)
  li t0, 1
  sb t0, 0(s0)
  sb zero, 1(s0)
  sh zero, 2(s0)
  fence iorw,iorw
  lw t1, 0(s0)
  bne t1, t0, fail
  lbu t1, 1(s0)
  bnez t1, fail
  lhu t1, 2(s0)
  bnez t1, fail
  sb zero, 0(s0)
  fence iorw,iorw
  lw t1, 0(s0)
  bnez t1, fail
#else
#error unsupported CLINT_SUBWORD_CASE
#endif
  li a0, 0
  ebreak
check_bytes:
#if CLINT_SUBWORD_CASE == 1
  /* Verify writes through known-good word reads, independently of the
   * subword read path exercised by CASE 0. */
  lw t0, 0(s0)
  lw t1, 0(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 4(s1)
  bne t0, t1, fail
  ret
#else
  li t0, 0
1:
  add t1, s0, t0
  lbu t2, 0(t1)
  add t1, s1, t0
  lbu t3, 0(t1)
  bne t2, t3, fail
  addi t0, t0, 1
  li t1, 8
  bltu t0, t1, 1b
  ret
#endif
fail:
  li a0, 1
  ebreak
  j fail
.section .data
.balign 8
expected:
  .dword 0xf0debc9a78563412
