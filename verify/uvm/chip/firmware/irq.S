#include "common.h"
test_main:
  la t0,irq_handler
  csrw mtvec,t0
  li s6,0
  li s9,3
  li t0,8
  csrw mie,t0
  csrs mstatus,t0
  li t0,0x02000000
  li t1,1
  sw t1,0(t0)
1: beqz s6,1b
  li t0,1
  CHECK s6,t0
  STAGE
  // Timer interrupt from the shared CLINT, with a future compare value.
  li s9,7
  li t0,0x0200bff8
  lw t1,0(t0)
  addi t1,t1,100
  li t0,0x02004000
  li t2,-1
  sw t2,4(t0)
  sw t1,0(t0)
  sw zero,4(t0)
  li t0,128
  csrw mie,t0
2:
  li t0,2
  bne s6,t0,2b
  STAGE
  // PLIC threshold masks source 1, then claim/complete via real core loads.
  li t0,0x0c000004
  li t1,3
  sw t1,0(t0)
  li t0,0x0c002000
  li t1,2
  sw t1,0(t0)
  li t0,0x0c200000
  li t1,3
  sw t1,0(t0)
  li t0,1
  sw t0,24(s0)
3:
  lw t1,32(s0)
  bne t0,t1,3b
  csrr t0,mip
  li t1,0x800
  and t0,t0,t1
  bnez t0,fail
  li s9,11
  li t0,0x0c200000
  sw zero,0(t0)
  li t0,0x800
  csrw mie,t0
4:
  li t0,3
  bne s6,t0,4b
  li t0,1
  CHECK s8,t0
  li t0,2
  sw t0,24(s0)
5:
  lw t1,32(s0)
  bne t0,t1,5b
  li t0,0x0c200004
  sw s8,0(t0)
  // Exercise the legacy interrupt pin's routing into the same PLIC source.
  li t0,3
  sw t0,24(s0)
6:
  lw t1,32(s0)
  bne t0,t1,6b
  li t0,0x800
  csrw mie,t0
7:
  li t0,4
  bne s6,t0,7b
  li t0,4
  sw t0,24(s0)
8:
  lw t1,32(s0)
  bne t0,t1,8b
  li t0,0x0c200004
  sw s8,0(t0)
  STAGE
  j pass
.balign 4
irq_handler:
  csrr t3,mcause
  li t4,1
  slli t4,t4,(__riscv_xlen-1)
  or t4,t4,s9
  CHECK t3,t4
  csrw mie,zero
  li t3,3
  beq s9,t3,clear_software
  li t3,7
  beq s9,t3,clear_timer
  li t3,0x0c200004
  lw s8,0(t3)
  li t4,1
  CHECK s8,t4
  j irq_return
clear_software:
  li t3,0x02000000
  sw zero,0(t3)
  j irq_return
clear_timer:
  li t3,0x02004000
  li t4,-1
  sw t4,0(t3)
  sw t4,4(t3)
irq_return:
  addi s6,s6,1
  mret
