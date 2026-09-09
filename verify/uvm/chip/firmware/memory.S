#include "common.h"
test_main:
  // Width/lane/sign extension and forwarding through the complete LSU.
  li a0,0x80000000
  li a1,-1
#if __riscv_xlen == 64
  sd zero,0(a0)
  sd a1,8(a0)
  ld a2,8(a0)
  CHECK a1,a2
#endif
  sw zero,0(a0)
  sb a1,3(a0)
  lb a2,3(a0)
  CHECK a1,a2
  lbu a2,3(a0)
  li a3,255
  CHECK a2,a3
  sh a1,2(a0)
  lh a2,2(a0)
  CHECK a1,a2
  lhu a2,2(a0)
  li a3,65535
  CHECK a2,a3
  sw a1,0(a0)
  lw a2,0(a0)
  CHECK a1,a2
#if __riscv_xlen == 64
  lwu a2,0(a0)
  li a3,0xffffffff
  CHECK a2,a3
#endif
  // Exercise every physical byte lane on both bus widths.
  li a0,0x80000000
  li a1,0
9:
  add a2,a0,a1
  addi a3,a1,17
  sb a3,0(a2)
  lbu a4,0(a2)
  CHECK a3,a4
  addi a1,a1,1
  li a5,(__riscv_xlen/8)
  blt a1,a5,9b
  STAGE
  // Store/refill/evict a 128 KiB working set, then verify every word.
  li a0,0x80000000
  li a1,2048
  li a2,0
3:
  xor a3,a0,a2
  sw a3,0(a0)
  addi a0,a0,64
  addi a2,a2,1
  blt a2,a1,3b
  fence rw,rw
  li a0,0x80000000
  li a2,0
4:
  xor a3,a0,a2
  lw a4,0(a0)
#if __riscv_xlen == 64
  sext.w a3,a3
#endif
  CHECK a3,a4
  addi a0,a0,64
  addi a2,a2,1
  blt a2,a1,4b
  STAGE
  li a0,0x80000000
  li a1,10
  sw a1,0(a0)
  lr.w a2,(a0)
  CHECK a1,a2
  li a1,20
  sc.w a3,a1,(a0)
  bnez a3,fail
  lw a2,0(a0)
  CHECK a1,a2
  sc.w a3,a1,(a0)
  beqz a3,fail
  li a1,3
  amoadd.w.aqrl a2,a1,(a0)
  li a3,20
  CHECK a2,a3
  lw a2,0(a0)
  li a3,23
  CHECK a2,a3
  li a1,-7
  amomin.w a2,a1,(a0)
  CHECK a2,a3
  lw a2,0(a0)
  CHECK a1,a2
#if __riscv_xlen == 64
  li a1,0x123456789abcdef
  sd a1,0(a0)
  lr.d a2,(a0)
  CHECK a1,a2
  sc.d a3,zero,(a0)
  bnez a3,fail
  amoadd.d a2,a1,(a0)
  bnez a2,fail
  ld a2,0(a0)
  CHECK a1,a2
#endif
  STAGE
  j pass
