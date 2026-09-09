.option norvc
.section .text.init
.globl _start
_start:
  la t0, fail
  csrw mtvec,t0
  li s0,0x10000000
  li s1,0x600d0000
  sw s1,0(s0)
  li t0,17
  li t1,31
  mul t2,t0,t1
  li t3,527
  bne t2,t3,fail
  div t2,t2,t0
  bne t2,t1,fail
  li t0,0x80000000
  li t1,0x12345678
  sw t1,0(t0)
  lw t2,0(t0)
  bne t1,t2,fail
  li t1,0x5a
  sb t1,1(t0)
  lbu t2,1(t0)
  bne t1,t2,fail
  fence rw,rw
  addi s1,s1,1
  sw s1,0(s0)
  li t0,0x02000000
  li t1,1
  sw t1,0(t0)
  lw t2,0(t0)
  bne t1,t2,fail
  sw zero,0(t0)
  lw t2,0(t0)
  bnez t2,fail
  li t0,0x0c000004
  li t1,3
  sw t1,0(t0)
  lw t2,0(t0)
  bne t1,t2,fail
  addi s1,s1,1
  sw s1,0(s0)
  li t0,0xc001c0de
  sw t0,8(s0)
1: j 1b
.balign 4
fail:
  li s0,0x10000000
  csrr t1,mcause
  sw t1,16(s0)
  li t0,0xdead
  sw t0,8(s0)
2: j 2b
