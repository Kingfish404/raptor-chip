/* Architectural load bytes, not aligned implementation beats, set the
 * permission footprint. MPRV uses S permissions while the harness stays M. */
#ifdef PMP_TEST_FP
#define LOAD_STATUS 0x22800
#else
#define LOAD_STATUS 0x20800
#endif
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, trap
  csrw mtvec, t0
  csrw mstatus, zero
  li s4, 0
  la s0, area
  srli t0, s0, 2
  csrw pmpaddr0, t0
  li t0, 0x19                 /* NAPOT 8 B, read only */
  csrw pmpcfg0, t0
  sfence.vma
  li t0, LOAD_STATUS
  csrw mstatus, t0
  lw t1, 1(s0)
  lhu t2, 1(s0)
  li t0, 0x20000
  csrc mstatus, t0
  li t3, 0x55443322
  bne t1, t3, fail
  li t3, 0x3322
  bne t2, t3, fail
  /* TOR [area,area+12): an aligned 8 B high beat would overcheck. */
  addi t0, s0, 12
  srli t0, t0, 2
  csrw pmpaddr1, t0
  li t0, 0x0900
  csrw pmpcfg0, t0
  sfence.vma
  li t0, LOAD_STATUS
  csrw mstatus, t0
#if __riscv_xlen == 64
  ld t1, 1(s0)
#endif
  lw t2, 7(s0)
#ifdef PMP_TEST_FP
  fld ft0, 1(s0)
#endif
  li t0, 0x20000
  csrc mstatus, t0
#if __riscv_xlen == 64
  li t3, 0x1908776655443322
  bne t1, t3, fail
#endif
  li t3, 0x3b2a1908
  bne t2, t3, fail
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
  /* Byte 12 is denied: this access must not silently succeed. */
  li s4, 1
  li t0, LOAD_STATUS
  csrw mstatus, t0
bad_load:
  lw t2, 9(s0)
  j fail
trap:
  li t0, 0x20000
  csrc mstatus, t0
  beqz s4, fail
  csrr s1, mcause
  csrr s2, mtval
  csrr s3, mepc
  li t0, 5
  bne s1, t0, fail
  la t0, bad_load
  bne s3, t0, fail
  li a0, 0
  ebreak
fail:
  li t0, 0x20000
  csrc mstatus, t0
  li a0, 1
  ebreak
  j fail
.section .data
.balign 16
area:
  .byte 0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x08
  .byte 0x19,0x2a,0x3b,0x4c,0x5d,0x6e,0x7f,0x10

#ifdef PMP_TEST_FP
.balign 8
fp_result: .zero 8
#endif
