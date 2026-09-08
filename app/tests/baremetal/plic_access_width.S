/* Load/store width matrix: PLIC_WIDTH_STORE=0 checks claim preservation;
 * PLIC_WIDTH_STORE=1 checks priority preservation. */
#ifndef PLIC_WIDTH_STORE
#define PLIC_WIDTH_STORE 0
#endif
/* Platform contract under development: PLIC architectural accesses are
 * aligned 32-bit operations. Unsupported widths must fault before claim.
 * CASE 3 is the supported LW control. Pending injection uses the existing
 * platform-specific pending-set register, not a PLIC-standard SW operation. */
#ifndef PLIC_WIDTH_CASE
#define PLIC_WIDTH_CASE 0
#endif
#include "plic_width_translate.h"
#if PLIC_WIDTH_CASE == 4
#include "fp_half_plic_state.h"
#endif
.option norvc
.option norelax
.section .text
.globl _start
_start:
  csrw mstatus, zero
  csrw mie, zero
  li t0, 0x6000
  csrs mstatus, t0
  la t0, trap
  csrw mtvec, t0
#if PLIC_WIDTH_CASE == 4
  half_plic_seed
#endif
  plic_width_translation_setup
  li s0, (0x0c000004 + PLIC_VA_DELTA)
  li s1, (0x0c002000 + PLIC_VA_DELTA)
  li s2, (0x0c001000 + PLIC_VA_DELTA)
  li s3, (0x0c200004 + PLIC_VA_DELTA)
  li t0, 2
  sw t0, 0(s0)
  sw t0, 0(s1)
  sw zero, -4(s3)
  sw t0, 0(s2)
  fence iorw,iorw
  li s5, 0
#if PLIC_WIDTH_STORE
  mv s6, s0
#if PLIC_WIDTH_CASE == 2
  addi s6, s0, -4
  la t1, zero_data
  fld ft0, 0(t1)
#endif
#else
  mv s6, s3
#if PLIC_WIDTH_CASE == 2
  addi s6, s3, -4
#endif
#endif
  la s4, probe
probe:
#if PLIC_WIDTH_STORE
#if PLIC_WIDTH_CASE == 0
  sb zero, 0(s6)
#elif PLIC_WIDTH_CASE == 1
  sh zero, 0(s6)
#elif PLIC_WIDTH_CASE == 2
  fsd ft0, 0(s6)
#elif PLIC_WIDTH_CASE == 3
  sw t0, 0(s6)
#elif PLIC_WIDTH_CASE == 4
  fsh f0, 0(s6)
#else
#error unsupported PLIC_WIDTH_CASE
#endif
#else
#if PLIC_WIDTH_CASE == 0
  lbu t1, 0(s6)
#elif PLIC_WIDTH_CASE == 1
  lhu t1, 0(s6)
#elif PLIC_WIDTH_CASE == 2
  /* Naturally aligned FLD: RV32 splits this into threshold and claim.
   * Reject using the original width before either physical fragment. */
  fld ft0, 0(s6)
#elif PLIC_WIDTH_CASE == 3
  lw t1, 0(s6)
#elif PLIC_WIDTH_CASE == 4
  flh f2, 0(s6)
#else
#error unsupported PLIC_WIDTH_CASE
#endif
#endif
after_probe:
#if PLIC_WIDTH_TRANSLATED
  /* MRET to M changes MPP; restore effective S-mode data translation. */
  csrw mstatus, s7
#endif
#if PLIC_WIDTH_CASE == 4
  half_plic_check
#endif
#if PLIC_WIDTH_STORE
  fence iorw,iorw
#if PLIC_WIDTH_CASE == 3
  bnez s5, fail
#else
  li t2, 1
  bne s5, t2, fail
#endif
  lw t1, 0(s0)
  li t2, 2
  bne t1, t2, fail
  lw t1, 0(s3)
  li t2, 1
  bne t1, t2, fail
#else
#if PLIC_WIDTH_CASE == 3
  bnez s5, fail
  li t2, 1
  bne t1, t2, fail
  lw t1, 0(s3)
  bnez t1, fail
#else
  li t2, 1
  bne s5, t2, fail
  /* The rejected operation must not have consumed source 1. */
  lw t1, 0(s3)
  bne t1, t2, fail
  lw t1, 0(s3)
  bnez t1, fail
#endif
#endif
  li a0, 0
  ebreak
trap:
  bnez s5, fail
  csrr t0, mcause
#if PLIC_WIDTH_STORE
  li t2, 7
#else
  li t2, 5
#endif
  bne t0, t2, fail
  csrr t0, mepc
  bne t0, s4, fail
  csrr t0, mtval
  bne t0, s6, fail
  addi s5, s5, 1
  la t0, after_probe
  csrw mepc, t0
  mret
fail:
  li a0, 1
  ebreak
  j fail

#if PLIC_WIDTH_STORE
.section .rodata
.balign 8
zero_data:
  .dword 0
#endif
