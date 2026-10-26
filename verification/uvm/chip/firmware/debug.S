#include "common.h"
test_main:
  li t6,0
  STAGE
  li a0,1
  sw a0,24(s0)
1:
  lw a1,32(s0)
  bne a1,a0,1b
  li a2,0x12345678
  CHECK t6,a2
  STAGE
  li a0,0x80000000
  sw t6,0(a0)
  lw a1,0(a0)
  CHECK a1,t6
  STAGE
  j pass
