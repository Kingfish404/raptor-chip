#include "common.h"
test_main:
  li a0,0
  li a1,1000
  li a2,0
3:
  add a2,a2,a0
  addi a0,a0,1
  blt a0,a1,3b
  li a3,499500
  CHECK a2,a3
  // Repeated direction changes and dependent divide/branch resolution.
  li a0,100
4:
  andi a1,a0,1
  beqz a1,5f
  li a2,21
  li a3,7
  div a4,a2,a3
  li a5,3
  CHECK a4,a5
  j 6f
5:
  li a2,-21
  li a3,7
  div a4,a2,a3
  li a5,-3
  CHECK a4,a5
6:
  addi a0,a0,-1
  bnez a0,4b
  STAGE
  // Precise wrong-path side effects must never reach the external pins.
  li a0,49
  li a1,7
  div a2,a0,a1
  beq a2,a1,7f
  sw zero,48(s0)
  j fail
7:
  li a0,0
  jal ra,subroutine
  li a1,3
  CHECK a0,a1
  STAGE
  .option rvc
  c.li a0,1
  c.addi a0,1
  c.slli a0,3
  c.mv a1,a0
  c.add a0,a1
  .option norvc
  li a1,32
  CHECK a0,a1
  // Self-modifying RAM code and instruction-cache invalidation.
  li a0,0x80040000
  li a1,0x00700513 // addi a0,zero,7
  sw a1,0(a0)
  li a1,0x00008067 // ret
  sw a1,4(a0)
  fence.i
  jalr ra,a0,0
  li a1,7
  CHECK a0,a1
  li a0,0x80040000
  li a1,0x00b00513 // addi a0,zero,11
  sw a1,0(a0)
  fence.i
  jalr ra,a0,0
  li a1,11
  CHECK a0,a1
  STAGE
  j pass
subroutine:
  addi a0,a0,1
  mv a6,ra
  jal ra,nested
  mv ra,a6
  addi a0,a0,1
  ret
nested:
  addi a0,a0,1
  ret
