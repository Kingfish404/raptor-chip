/* Standalone firmware contract. s0/s1 are the host signature mailbox;
 * s2..s7 describe an armed synchronous trap. No runtime or host backdoors. */
.option norvc
.section .text.init
.globl _start
_start:
  li s0,0x10000000
  li s1,0x600d0000
  li s7,0
  li s6,0
  la t0,trap_handler
  csrw mtvec,t0
  j test_main

.macro STAGE
  fence rw,rw
  sw s1,0(s0)
  addi s1,s1,1
.endm
.macro CHECK lhs,rhs
  bne \lhs,\rhs,fail
.endm
.macro ARM cause,pc,value,resume
  li s2,\cause
  la s3,\pc
  li s4,\value
  la s5,\resume
  li s7,1
.endm
.balign 4
trap_handler:
  beqz s7,fail
  csrr t3,mcause
  CHECK t3,s2
  csrr t3,mepc
  CHECK t3,s3
  csrr t3,mtval
  CHECK t3,s4
  csrw mepc,s5
  li s7,0
  addi s6,s6,1
  mret
pass:
  fence rw,rw
  li t0,0xc001c0de
  sw t0,8(s0)
1: j 1b
fail:
  li s0,0x10000000
  csrr t0,mcause
  sw t0,16(s0)
  csrr t0,mepc
  sw t0,40(s0)
  li t0,0xdead
  sw t0,8(s0)
2: j 2b
.section .text
