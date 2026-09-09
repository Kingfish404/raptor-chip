#include "common.h"
#if __riscv_xlen == 64
#define PTE_STORE sd
#define PTE_BYTES 8
#define ROOT_OFFSET 8
#else
#define PTE_STORE sw
#define PTE_BYTES 4
#define ROOT_OFFSET 1024
#endif
test_main:
  li t0,-1
  csrw pmpaddr0,t0
  li t0,0x1f
  csrw pmpcfg0,t0
  li a0,0x80040000
  li a1,0x80043000
3:
  sw zero,0(a0)
  addi a0,a0,4
  blt a0,a1,3b
  li a0,0x80040000
  li a1,0x20010401 // pointer to 0x80041000
  PTE_STORE a1,ROOT_OFFSET(a0)
#if __riscv_xlen == 64
  li a0,0x80041000
  li a1,0x20010801 // pointer to 0x80042000
  sd a1,0(a0)
  li s8,0x80042000
#else
  li s8,0x80041000
#endif
  li a1,0x200180c7 // VA 0x40000000 -> PA 0x80060000, V/R/W/A/D
  PTE_STORE a1,0(s8)
  li a0,0x80060000
  li a1,0x12345678
  sw a1,0(a0)
  li a0,0x80061000
  li a1,0x23456789
  sw a1,0(a0)
  fence rw,rw
#if __riscv_xlen == 64
  li a0,0x8000000000080040
#else
  li a0,0x80080040
#endif
  csrw satp,a0
  sfence.vma
  // MPRV with MPP=S causes real PTW/TLB data translation.
  li a0,0x1800
  csrc mstatus,a0
  li a0,0x20800
  csrs mstatus,a0
  li a2,0x40000000
  lw a3,0(a2)
  li a0,0x20000
  csrc mstatus,a0
  li a4,0x12345678
  CHECK a3,a4
  STAGE
  // Change physical mapping and invalidate the cached translation.
  li a1,0x200184c7
  PTE_STORE a1,0(s8)
  fence rw,rw
  sfence.vma
  li a0,0x20800
  csrs mstatus,a0
  lw a3,0(a2)
  li a0,0x20000
  csrc mstatus,a0
  li a4,0x23456789
  CHECK a3,a4
  STAGE
  // Svade: missing A/D must fault, and the PTW must not repair the PTE.
  li a1,0x20018407
  PTE_STORE a1,0(s8)
  fence rw,rw
  sfence.vma
  ARM 13,ad_fault,0x40000000,after_ad
  li a0,0x20800
  csrs mstatus,a0
ad_fault:
  lw a3,0(a2)
  j fail
after_ad:
  li a0,0x20000
  csrc mstatus,a0
  lw a3,0(s8)
  li a4,0x20018407
  CHECK a3,a4
  li a4,1
  CHECK s6,a4
  // Read-only mapping: a store must fault with the virtual address.
  li a1,0x20018443
  PTE_STORE a1,0(s8)
  fence rw,rw
  sfence.vma
  ARM 15,write_fault,0x40000000,after_write
  li a0,0x1800
  csrc mstatus,a0
  li a0,0x20800
  csrs mstatus,a0
write_fault:
  sw zero,0(a2)
  j fail
after_write:
  li a0,0x20000
  csrc mstatus,a0
  li a0,0x80061000
  lw a3,0(a0)
  li a4,0x23456789
  CHECK a3,a4
  csrw satp,zero
  sfence.vma
  STAGE
  j pass
