/* Real page-table walk: PMP grants only physical data and page tables.
 * The virtual alias is outside both grants. */
#ifdef PMP_TEST_FP
#define LOAD_STATUS 0x22800
#else
#define LOAD_STATUS 0x20800
#endif
#ifdef PMP_TEST_HALF
#include "fp_half_plic_state.h"
#endif
.option norvc
.option norelax
#if __riscv_xlen == 64
#define PTE_STORE sd
#define PTE_SHIFT 3
#else
#define PTE_STORE sw
#define PTE_SHIFT 2
#endif
.section .text
.globl _start
_start:
  la t0, trap
  csrw mtvec, t0
  csrw mstatus, zero
  li s4, 0
  la s0, area
  la s1, root
  la s2, leaves
  srli t0, s0, 12
  slli t0, t0, 10
#ifdef PMP_HALF_STORE
  ori t0, t0, 0xc7
#else
  ori t0, t0, 0xc3
#endif
  PTE_STORE t0, (1 << PTE_SHIFT)(s2)
  srli t0, s2, 12
  slli t0, t0, 10
  ori t0, t0, 1
#if __riscv_xlen == 64
  la t1, middle
  sd t0, 0(t1)
  srli t0, t1, 12
  slli t0, t0, 10
  ori t0, t0, 1
  sd t0, 8(s1)
#else
  sw t0, 1024(s1)
#endif
  fence rw,rw
  srli t0, s0, 2
  csrw pmpaddr0, t0
  addi t0, s0, 12
  srli t0, t0, 2
  csrw pmpaddr1, t0
  srli t0, s1, 2
  ori t0, t0, 2047
  csrw pmpaddr2, t0
#ifdef PMP_HALF_STORE
  li t0, 0x190b00
#else
  li t0, 0x190900
#endif
  csrw pmpcfg0, t0
  srli t0, s1, 12
#if __riscv_xlen == 64
  li t1, 0x8000000000000000
#else
  li t1, 0x80000000
#endif
  or t0, t0, t1
  csrw satp, t0
  sfence.vma
  li s0, 0x40001000
  li t0, LOAD_STATUS
  csrw mstatus, t0
  lw t1, 1(s0)
  lw t2, 7(s0)
#ifdef PMP_TEST_FP
  fld ft0, 1(s0)
#endif
#if __riscv_xlen == 64
  ld t3, 1(s0)
#endif
  li t0, 0x20000
  csrc mstatus, t0
  li t0, 0x55443322
  bne t1, t0, fail
  li t0, 0x3b2a1908
  bne t2, t0, fail
#if __riscv_xlen == 64
  li t0, 0x1908776655443322
  bne t3, t0, fail
#endif
#ifdef PMP_TEST_FP
  la t4, fp_result
  fsd ft0, 0(t4)
  lw t5, 0(t4)
  li t6, 0x55443322
  bne t5, t6, fail
  lw t5, 4(t4)
  li t6, 0x19087766
  bne t5, t6, fail
#endif
#ifdef PMP_TEST_HALF
  half_plic_seed
  li t0, LOAD_STATUS
  csrw mstatus, t0
  flh f2, 1(s0)
#ifdef PMP_HALF_STORE
  /* Write back the same two bytes: the final guard remains unchanged. */
  fsh f2, 1(s0)
#endif
  li t0, 0x20000
  csrc mstatus, t0
  la t0, half_plic_saved
  fsd f2, 0(t0)
  lw t1, 0(t0)
  li t2, -52446             /* ffff3322 */
  bne t1, t2, fail
  lw t1, 4(t0)
  li t2, -1
  bne t1, t2, fail
  csrr t1, fcsr
  li t2, 0x43
  bne t1, t2, fail
  half_plic_seed
#endif
  /* After PMP update and SFENCE, the new walk must enforce denial. */
#ifdef PMP_HALF_PTE_DENY
  /* Keep data permitted, but deny the walker its physical table reads. */
#ifdef PMP_HALF_STORE
  li t0, 0x180b00
#else
  li t0, 0x180900
#endif
#else
  li t0, 0x190800
#endif
  csrw pmpcfg0, t0
  sfence.vma
  li s4, 1
  li t0, LOAD_STATUS
  csrw mstatus, t0
bad_load:
#ifdef PMP_HALF_STORE
  fsh f0, 1(s0)
#elif defined(PMP_TEST_HALF)
  flh f2, 1(s0)
#else
  lw t1, 1(s0)
#endif
  j fail
trap:
  li t0, 0x20000
  csrc mstatus, t0
  beqz s4, fail
  csrr s1, mcause
  csrr s2, mtval
  csrr s3, mepc
#ifdef PMP_HALF_STORE
  li t0, 7
#else
  li t0, 5
#endif
  bne s1, t0, fail
  li t0, 0x40001001
  bne s2, t0, fail
  la t0, bad_load
  bne s3, t0, fail
#ifdef PMP_TEST_HALF
  half_plic_check
  /* Check all sixteen bytes, including both neighbors of the denied store. */
  la t0, area
  la t1, half_area_expected
  li t2, 16
1: lbu t3, 0(t0)
  lbu t4, 0(t1)
  bne t3, t4, fail
  addi t0, t0, 1
  addi t1, t1, 1
  addi t2, t2, -1
  bnez t2, 1b
#endif
  li a0, 0
  ebreak
fail:
  li t0, 0x20000
  csrc mstatus, t0
  li a0, 1
  ebreak
  j fail
.section .data
.balign 4096
area:
  .byte 0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x08
  .byte 0x19,0x2a,0x3b,0x4c,0x5d,0x6e,0x7f,0x10
.balign 16384
root: .zero 4096
middle: .zero 4096
leaves: .zero 4096
.zero 4096

#ifdef PMP_TEST_FP
.balign 8
fp_result: .zero 8
#endif
#ifdef PMP_TEST_HALF
half_area_expected:
  .byte 0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x08
  .byte 0x19,0x2a,0x3b,0x4c,0x5d,0x6e,0x7f,0x10
#endif
