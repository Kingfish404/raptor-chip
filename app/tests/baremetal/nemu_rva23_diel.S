.section .text
.globl _start
.option norvc
_start:
  la t0, fail
  csrw mtvec, t0
  li t0, 0x6600
  csrs mstatus, t0
  vsetivli zero, 16, e8, m1, tu, mu
  li s0, 0x0200bff8
  li s1, 0
  li s2, 0
  li s3, 0
  li s4, 32
  li s5, 0x9e3779b97f4a7c15
  li s6, 0
sample:
  vmv.v.x v8, s6
  vmv.v.x v9, s5
  mv t2, s6
  li t3, 2000
  rdcycle a0
  ld a1, 0(s0)
work:
  mul t2, t2, s5
  clmul t2, t2, s5
  vadd.vv v8, v8, v9
  vmul.vv v8, v8, v9
  vsll.vx v8, v8, t2
  addi t3, t3, -1
  bnez t3, work
  ld a2, 0(s0)
  rdcycle a3
  sub a3, a3, a0
  sub a2, a2, a1
  beqz a2, fail
  beqz s1, baseline
  bne a3, s2, fail
  sub t0, a2, s3
  addi t0, t0, 1
  li t1, 2
  bgtu t0, t1, fail
  j next
baseline:
  mv s2, a3
  mv s3, a2
  li t0, 14003
  bne s2, t0, fail
  li t0, 140
  bltu s3, t0, fail
  li t0, 141
  bgtu s3, t0, fail
next:
  add s6, s6, s5
  addi s1, s1, 1
  bltu s1, s4, sample
  li t0, 0x100000
  li t1, 0x5555
  sw t1, 0(t0)
halt:
  j halt
fail:
  li t0, 0x100000
  li t1, 0x13333
  sw t1, 0(t0)
  j halt
