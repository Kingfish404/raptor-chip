#include "common.h"
#if __riscv_xlen == 64
#define PTE_STORE sd
#else
#define PTE_STORE sw
#endif
test_main:
  li t0,-1
  csrw pmpaddr0,t0
  li t0,0x1f
  csrw pmpcfg0,t0
  li a0,0x80040000
  li a1,0x80043000
1:
  sw zero,0(a0)
  addi a0,a0,4
  blt a0,a1,1b
  li a0,0x80040000
#if __riscv_xlen == 64
  li a1,0xcf // identity 1 GiB for ROM and mailbox
  sd a1,0(a0)
  li a1,0x200000c7 // identity RAM, RW/AD
  sd a1,16(a0)
  li a1,0x20010401
  sd a1,8(a0)
  li a0,0x80041000
  li a1,0x20010801
  sd a1,0(a0)
  li s8,0x80042000
#else
  li a1,0x080000cb // identity ROM, RX/AD
  sw a1,512(a0)
  li a1,0x040000c7 // identity mailbox, RW/AD
  sw a1,256(a0)
  li a1,0x20010401
  sw a1,1024(a0)
  li a0,0x80040800 // root entry 512, identity RAM
  li a1,0x200000c7
  sw a1,0(a0)
  li s8,0x80041000
#endif
  li a1,0x200180cb // executable alias -> PA 0x80060000
  PTE_STORE a1,0(s8)
  li a0,0x80060000
  li a1,0x02a00693 // addi a3,zero,42
  sw a1,0(a0)
  li a1,0x00008067 // ret
  sw a1,4(a0)
  fence.i
#if __riscv_xlen == 64
  li a0,0x8000000000080040
#else
  li a0,0x80080040
#endif
  csrw satp,a0
  sfence.vma
  la t0,s_entry
  csrw mepc,t0
  li t0,0x1800
  csrc mstatus,t0
  li t0,0x800
  csrs mstatus,t0
  mret
s_entry:
  STAGE
  li a0,0x40000000
  jalr ra,a0,0
  li a1,42
  CHECK a3,a1
  STAGE
  // Revoking execute permission plus SFENCE must invalidate I-side state.
  li a1,0x200180c7
  PTE_STORE a1,0(s8)
  fence rw,rw
  sfence.vma
  li s2,12
  li s3,0x40000000
  li s4,0x40000000
  la s5,after_fault
  li s7,1
  li a0,0x40000000
  jr a0
after_fault:
  li a0,1
  CHECK s6,a0
  STAGE
  j pass
