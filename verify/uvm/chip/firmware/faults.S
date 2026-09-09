#include "common.h"
test_main:
  li a2,0x80070000
  ARM 5,load_fault,0x80070000,after_load
load_fault:
  lw a3,0(a2)
  j fail
after_load:
  li a0,1
  CHECK a0,s6
  STAGE
  // Posted stores have already retired at B response time. The platform
  // reports these through machine interrupt 16 and MBERR, not a precise trap.
  la t0,store_irq
  csrw mtvec,t0
  li t0,0x10000
  csrw mie,t0
  li t0,8
  csrs mstatus,t0
  sw zero,0(a2)
  fence rw,rw
after_store:
  li a0,2
  bne a0,s6,after_store
  la t0,trap_handler
  csrw mtvec,t0
  STAGE
  li s2,1
  li s3,0x80070000
  li s4,0x80070000
  la s5,after_fetch
  li s7,1
  jr a2
after_fetch:
  li a0,3
  CHECK a0,s6
  STAGE
  j pass

.balign 4
store_irq:
  csrr t3,mcause
  li t4,1
  slli t4,t4,(__riscv_xlen-1)
  ori t4,t4,16
  CHECK t3,t4
  csrr t3,mtval
  bnez t3,fail
  csrr t3,0xfc0
  li t4,0x80070000
  CHECK t3,t4
  csrr t3,0x7c0
  li t4,0xf01
  CHECK t3,t4
  li t3,3
  csrw 0x7c0,t3
  csrr t3,mip
  li t4,0x10000
  and t3,t3,t4
  bnez t3,fail
  csrw mie,zero
  addi s6,s6,1
  mret
