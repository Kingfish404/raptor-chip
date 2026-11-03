.option norvc
.section .text.start
.globl _start
_start:
  li t0, 0x00100000
  li t1, 0x5555
  sw t1, 0(t0)
  fence iorw, iorw
  j counter_loop
.org 0x40
counter_loop:
.rept 64
  addi s0, s0, 1
.endr
  j counter_loop
