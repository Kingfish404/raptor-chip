/* A first guest CSR write must survive the post-trampoline bookkeeping. */
.section .text
.globl _start, roi_start, roi_end
_start:
  csrw mie, zero
  li s0, 0x12345678
  csrw mepc, zero
  li s1, 1024
roi_start:
  csrw mepc, s0
loop:
  csrr t0, mepc
  bne t0, s0, failed
  addi s1, s1, -1
  bnez s1, loop
roi_end:
  li a0, 0
  ebreak
failed:
  li a0, 1
  ebreak
