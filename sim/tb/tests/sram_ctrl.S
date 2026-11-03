// Behavioral chip regression: ordinary core loads/stores to the local control word.
// Arbitrary test settings here are for simulation only.
.section .text
.globl _start
_start:
  li t0, 0x00100804
  lw t1, 0(t0)
  li t2, 0x0608
  bne t1, t2, fail
  li t1, -1
  fence
  sw t1, 0(t0)
  lw t1, 0(t0)
  li t2, 0x7fff
  bne t1, t2, fail
  li t1, 0x1234
  fence
  sw t1, 0(t0)
  lw t2, 0(t0)
  bne t1, t2, fail
  li t1, 0x0608
  fence
  sw t1, 0(t0)
  lw t2, 0(t0)
  bne t1, t2, fail
  li t0, 0x00100000
  li t1, 0x5555
  sw t1, 0(t0)
1:
  j 1b
fail:
  li t0, 0x00100000
  li t1, 0x13333
  sw t1, 0(t0)
2:
  j 2b
