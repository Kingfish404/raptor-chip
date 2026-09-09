#include "common.h"
test_main:
  li t0,-1
  csrw pmpaddr0,t0
  li t0,0x1f
  csrw pmpcfg0,t0
  li t0,256
  csrw medeleg,t0
  la t0,s_handler
  csrw stvec,t0
  la t0,s_entry
  csrw mepc,t0
  li t0,0x1800
  csrc mstatus,t0
  li t0,0x800
  csrs mstatus,t0
  mret
s_entry:
  STAGE
  la t0,u_entry
  csrw sepc,t0
  li t0,256
  csrc sstatus,t0
  sret
u_entry:
  li s6,0
  la s3,u_ecall1
u_ecall1:
  ecall
  li a0,1
  CHECK s6,a0
  STAGE
  la s3,u_ecall2
u_ecall2:
  ecall
  li a0,2
  CHECK s6,a0
  STAGE
  j pass
.balign 4
s_handler:
  csrr t3,scause
  li t4,8
  CHECK t3,t4
  csrr t3,sepc
  CHECK t3,s3
  csrr t3,stval
  bnez t3,fail
  csrr t3,sstatus
  andi t3,t3,256
  bnez t3,fail
  addi t3,s3,4
  csrw sepc,t3
  addi s6,s6,1
  sret
