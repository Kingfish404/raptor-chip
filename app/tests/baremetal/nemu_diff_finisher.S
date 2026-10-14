#ifndef FINISH_HART
#define FINISH_HART 0
#endif
.section .text
.globl _start
_start:
  csrr s0, mhartid
  li t0, 0x100000
#ifdef BAD_WIDTH
  lbu t1, 0(t0)
#elif defined(BAD_ADDRESS)
  lw t1, 4(t0)
#else
  lw t1, 0(t0)
#endif
  bnez t1, fail
  la t0, arrived
  li t1, 1
  amoadd.w.aqrl zero, t1, (t0)
wait:
  lw t1, 0(t0)
  li t2, HARTS
  bne t1, t2, wait
  li t2, FINISH_HART
  bne s0, t2, park
  li t0, 0x100000
  lw t1, 0(t0)
  li t2, -65536
  and t1, t1, t2
  li t2, 0x5555
  or t1, t1, t2
#ifdef BAD_WRITE
  li t1, 1
#endif
  sw t1, 0(t0)
park:
  j park
fail:
  li t0, 0x100000
  li t1, 0x3333
  sw t1, 0(t0)
  j park

.section .data
.balign 4
arrived:
  .word 0
