.option norelax
.section .text
.globl _start
_start:
  call main
  li a7, 94
  ecall
halt:
  j halt
