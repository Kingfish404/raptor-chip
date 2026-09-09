#include "common.h"
test_main:
  li a2,0x80000000
  li a3,7
  sw a3,0(a2)
  lr.w a4,(a2)
  CHECK a4,a3
  li a0,1
  sw a0,24(s0)
1:
  lw a1,32(s0)
  bne a0,a1,1b
  // An overlapping device write invalidates the existing reservation.
  sc.w a4,zero,(a2)
  beqz a4,fail
  lw a4,0(a2)
  CHECK a4,a3
  STAGE
  lr.w a4,(a2)
  li a0,2
  sw a0,24(s0)
2:
  lw a1,32(s0)
  bne a0,a1,2b
  // A notification at a disjoint address must preserve the reservation.
  sc.w a4,zero,(a2)
  bnez a4,fail
  lw a4,0(a2)
  bnez a4,fail
  STAGE
  lr.w a4,(a2)
  li a3,9
  sc.w a4,a3,(a2)
  bnez a4,fail
  lw a4,0(a2)
  CHECK a4,a3
  STAGE
  j pass
