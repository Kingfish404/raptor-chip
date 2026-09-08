/* PLIC 1.0 claim is independent of threshold. Completion checks the full
 * source ID and the destination context's enable mask, not claim ownership. */
#ifndef PLIC_CASE
#define PLIC_CASE 0
#endif
.option norvc
.option norelax
.section .text
.globl _start
_start:
  csrw mstatus, zero
  csrw mie, zero
  la t0, fail
  csrw mtvec, t0
  li s0, 0x0c000004
  li s1, 0x0c002000
  li s2, 0x0c001000
  li s3, 0x0c200004
  li t0, 2
  sw t0, 0(s0)
  sw t0, 0(s1)
#if PLIC_CASE == 0
  li t0, 7
  sw t0, -4(s3)
#endif
  li t0, 2
  sw t0, 0(s2)
  fence iorw,iorw
  lw t1, 0(s3)
  li t2, 1
  bne t1, t2, fail
#if PLIC_CASE == 1
  li t0, 33
  sw t0, 0(s3)
#elif PLIC_CASE == 2
  li s4, 0x0c201004
  li t0, 1
  sw t0, 0(s4)
#endif
#if PLIC_CASE != 0
  li t0, 2
  sw t0, 0(s2)
  fence iorw,iorw
  lw t1, 0(s2)
  bnez t1, fail
#if PLIC_CASE == 2
  /* Another enabled context may complete this source despite not claiming. */
  sw t0, 128(s1)
  li t0, 1
  sw t0, 0(s4)
#else
  li t0, 1
  sw t0, 0(s3)
#endif
  li t0, 2
  sw t0, 0(s2)
  fence iorw,iorw
  lw t1, 0(s3)
  li t2, 1
  bne t1, t2, fail
#endif
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
  j fail
