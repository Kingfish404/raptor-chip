.section .text.start
.globl _start
_start:
  li sp, 0x8003f000
  la t0, trap
  csrw mtvec, t0
  call main
  li t0, 0x00100000
  beqz a0, 1f
  slli a0, a0, 16
  li t1, 0x3333
  or t1, t1, a0
  j 2f
1:
  li t1, 0x5555
2:
  sw t1, 0(t0)
  fence iorw, iorw
3:
  j 3b
.balign 4
trap:
  csrr a0, mcause
  addi a0, a0, 1
  li t0, 0x00100000
  slli a0, a0, 16
  li t1, 0x3333
  or t1, t1, a0
  sw t1, 0(t0)
4:
  j 4b
