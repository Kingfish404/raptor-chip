.option norvc
.section .text.start
.globl _start
_start:
  // Position-independent function; caller supplies a0 and return address.
  li t0, 16
1:
  add a0, a0, t0
  addi t0, t0, -1
  bnez t0, 1b
  nop
  nop
  nop
  ret
