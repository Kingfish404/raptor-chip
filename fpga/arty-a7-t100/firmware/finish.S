.section .text
.globl _start
_start:
  // a0 is the AM halt return code. This stub replaces only a terminal EBREAK.
  li t0, 0x00100000
  beqz a0, 1f
  slli t1, a0, 16
  li t2, 0x3333
  or t1, t1, t2
  j 2f
1:
  li t1, 0x5555
2:
  sw t1, 0(t0)
  fence iorw, iorw
3:
  j 3b
