#include "common.h"
test_main:
  li a2,0x80060000
  li a3,0x12345678
  sw a3,0(a2)
  li t0,0x200181ff // 4 KiB NAPOT window at 0x80060000
  csrw pmpaddr0,t0
  li t0,-1
  csrw pmpaddr1,t0
  li t0,0x1f19 // entry 0: read-only; entry 1: permit remaining address space
  csrw pmpcfg0,t0
  li t0,0x1800
  csrc mstatus,t0
  li t0,0x20800
  csrs mstatus,t0
  lw a4,0(a2)
  li t0,0x20000
  csrc mstatus,t0
  CHECK a3,a4
  ARM 7,pmp_store,0x80060000,pmp_store_resume
  li t0,0x20800
  csrs mstatus,t0
pmp_store:
  sw zero,0(a2)
  j fail
pmp_store_resume:
  li t0,0x20000
  csrc mstatus,t0
  lw a4,0(a2)
  CHECK a3,a4
  STAGE
  li t0,0x1f98 // locked no-access window applies to M-mode too
  csrw pmpcfg0,t0
  csrw pmpaddr0,zero
  csrr a3,pmpaddr0
  li a4,0x200181ff
  CHECK a3,a4
  csrw pmpcfg0,zero
  csrr a3,pmpcfg0
  andi a3,a3,255
  li a4,0x98
  CHECK a3,a4
  ARM 5,pmp_load,0x80060000,pmp_load_resume
pmp_load:
  lw a4,0(a2)
  j fail
pmp_load_resume:
  STAGE
  li s2,1
  li s3,0x80060000
  li s4,0x80060000
  la s5,pmp_fetch_resume
  li s7,1
  jr a2
pmp_fetch_resume:
  li a3,3
  CHECK a3,s6
  STAGE
  j pass
