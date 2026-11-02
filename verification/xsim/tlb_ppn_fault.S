/* Full architectural PPNs must fault before compact TLB storage or PA casts. */
#ifndef PA_BITS
#define PA_BITS 32
#endif
#if __riscv_xlen == 64
#define STORE sd
#define PTE_BYTES 8
#define CODE_INDEX 2
#define DATA_INDEX 1
#define LAST_PPN_BIT 44
#else
#define STORE sw
#define PTE_BYTES 4
#define CODE_INDEX 512
#define DATA_INDEX 256
#define LAST_PPN_BIT 22
#endif
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, trap
  csrw mtvec, t0
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
  la s4, root
  li t0, CODE_INDEX * PTE_BYTES
  add t0, s4, t0
  li t1, 0x200000cf
  STORE t1, 0(t0)
  li t0, DATA_INDEX * PTE_BYTES
  add s4, s4, t0
  la t0, root
  srli t0, t0, 12
#if __riscv_xlen == 64
  li t1, 8
  slli t1, t1, 60
#else
  li t1, 1
  slli t1, t1, 31
#endif
  or t0, t0, t1
  mv s7, t0
  csrw satp, t0
  sfence.vma
  li s3, PA_BITS - 12
  li s5, 0
1:
  li t0, 1
  sll t0, t0, s3
  slli t0, t0, 10
  li t1, 0x200000cf
  or t0, t0, t1
  STORE t0, 0(s4)
  sfence.vma
  li s0, 5
  li s1, 0x40001000
  la s2, 2f
  li t0, 0x1800
  csrc mstatus, t0
  li t0, 0x20800
  csrs mstatus, t0
  lw t1, 0(s1)
  j fail
2:
  li s0, 7
  la s2, 3f
  li t0, 0x1800
  csrc mstatus, t0
  li t0, 0x20800
  csrs mstatus, t0
  sw zero, 0(s1)
  j fail
3:
  /* A valid X-only leaf fails the load permission check before PA checking. */
  li t0, 1
  sll t0, t0, s3
  slli t0, t0, 10
  li t1, 0x200000c9
  or t0, t0, t1
  STORE t0, 0(s4)
  sfence.vma
  li s0, 13
  la s2, 4f
  li t0, 0x1800
  csrc mstatus, t0
  li t0, 0x20800
  csrs mstatus, t0
  lw t1, 0(s1)
  j fail
4:
  /* Enter S mode at the same VA to cover the main ITLB/fetch fault path. */
  li t0, 1
  sll t0, t0, s3
  slli t0, t0, 10
  li t1, 0x200000cf
  or t0, t0, t1
  STORE t0, 0(s4)
  sfence.vma
  li s0, 1
  la s2, 5f
  li t0, 0x21800
  csrc mstatus, t0
  li t0, 0x800
  csrs mstatus, t0
  csrw mepc, s1
  mret
  j fail
5:
  /* Execute permission wins over the unsupported physical target. */
  li t0, 1
  sll t0, t0, s3
  slli t0, t0, 10
  li t1, 0x200000c7
  or t0, t0, t1
  STORE t0, 0(s4)
  sfence.vma
  li s0, 12
  la s2, 55f
  li t0, 0x21800
  csrc mstatus, t0
  li t0, 0x800
  csrs mstatus, t0
  csrw mepc, s1
  mret
  j fail
55:
  addi s3, s3, 1
  li t0, LAST_PPN_BIT
  blt s3, t0, 1b
  li t0, 0x200000cf
  STORE t0, 0(s4)
  /* A high SATP root must fault without reading its low-address alias. */
  li t0, 1
  slli t0, t0, PA_BITS - 12
  or t0, t0, s7
  csrw satp, t0
  sfence.vma
  li s0, 5
  li s1, 0x40001000
  la s2, 6f
  li t0, 0x1800
  csrc mstatus, t0
  li t0, 0x20800
  csrs mstatus, t0
  lw t1, 0(s1)
  j fail
6:
  li s0, 7
  la s2, 7f
  li t0, 0x1800
  csrc mstatus, t0
  li t0, 0x20800
  csrs mstatus, t0
  sw zero, 0(s1)
  j fail
7:
  li s0, 1
  la s2, 8f
  li t0, 0x21800
  csrc mstatus, t0
  li t0, 0x800
  csrs mstatus, t0
  csrw mepc, s1
  mret
  j fail
8:
  csrw satp, s7
  /* The same check applies when a valid non-leaf installs a bad PPN. */
  li t0, 1
  slli t0, t0, PA_BITS - 2
  li t1, 0x20000001
  or t0, t0, t1
  STORE t0, 0(s4)
  sfence.vma
  li s0, 5
  la s2, 9f
  li t0, 0x1800
  csrc mstatus, t0
  li t0, 0x20800
  csrs mstatus, t0
  lw t1, 0(s1)
  j fail
9:
  li s0, 7
  la s2, 10f
  li t0, 0x1800
  csrc mstatus, t0
  li t0, 0x20800
  csrs mstatus, t0
  sw zero, 0(s1)
  j fail
10:
  li s0, 1
  la s2, 11f
  li t0, 0x21800
  csrc mstatus, t0
  li t0, 0x800
  csrs mstatus, t0
  csrw mepc, s1
  mret
  j fail
11:
  la t0, marker
  lw t1, 0(t0)
  li t2, 0x12345678
  bne t1, t2, fail
#if __riscv_xlen == 64
  li t1, 0xffffffff00000000
  or t0, t0, t1
  lw t1, 0(t0)
  bne t1, t2, fail
#endif
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
trap:
  csrr t0, mcause
  bne t0, s0, fail
  csrr t0, mtval
  bne t0, s1, fail
  addi s5, s5, 1
  li t0, 0x20000
  csrc mstatus, t0
  li t0, 0x1800
  csrs mstatus, t0
  csrw mepc, s2
  mret
.section .data
.balign 4096
root:
  .zero 4096
marker:
  .word 0x12345678
