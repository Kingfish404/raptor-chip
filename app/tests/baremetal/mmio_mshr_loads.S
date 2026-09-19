/* Independent cache misses must retain values through replay and stores. */
.option norvc
.section .text
.globl _start
_start:
  la t0, values
  lw a0, 0(t0)
  lw a1, 64(t0)
  lw a2, 128(t0)
  lw a3, 192(t0)
  lw a4, 256(t0)
  lw a5, 320(t0)
  lw a6, 384(t0)
  lw a7, 448(t0)
  add t1, a0, a1
  add t1, t1, a2
  add t1, t1, a3
  add t1, t1, a4
  add t1, t1, a5
  add t1, t1, a6
  add t1, t1, a7
  li t2, 36
  bne t1, t2, fail
  /* Store must invalidate an already completed refill buffer. */
  li t1, 77
  sw t1, 0(t0)
  fence rw,rw
  lw t2, 0(t0)
  bne t1, t2, fail
  /* Multiple word consumers of one line, including a split access. */
  lw t1, 64(t0)
  lw t2, 68(t0)
  li t3, 2
  bne t1, t3, fail
  bnez t2, fail
  lw t1, 65(t0)
  bnez t1, fail
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
.section .data
.balign 4096
values:
.set n,1
.rept 8
  .word n
  .zero 60
  .set n,n+1
.endr
