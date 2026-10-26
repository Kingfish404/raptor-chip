#include "common.h"
test_main:
  ARM 11,ecall_pc,0,after_ecall
ecall_pc:
  ecall
after_ecall:
  li a0,1
  CHECK a0,s6
  STAGE
  ARM 2,illegal_pc,0xffffffff,after_illegal
illegal_pc:
  .word 0xffffffff
after_illegal:
  li a0,2
  CHECK a0,s6
  STAGE
  // U-mode ecall and MRET. PMP permits the ROM and signature MMIO.
  li t0,-1
  csrw pmpaddr0,t0
  li t0,0x1f
  csrw pmpcfg0,t0
  ARM 8,user_ecall,0,user_resume
  la t0,user_entry
  csrw mepc,t0
  li t0,0x1800
  csrc mstatus,t0
  mret
user_entry:
  li a0,7
  li a1,9
  mul a2,a0,a1
  li a3,63
  CHECK a2,a3
user_ecall:
  ecall
user_resume:
  li a0,3
  CHECK a0,s6
  STAGE
  j pass
