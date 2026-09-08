/* Native ZEXT.H and all eight C.ZEXT.H register encodings, plus the
 * opposite-XLEN native encoding following platform illegal policy. */
#ifndef ZEXTH_TEST_PRIV
#define ZEXTH_TEST_PRIV 3
#endif
#if ZEXTH_TEST_PRIV != 0 && ZEXTH_TEST_PRIV != 1 && ZEXTH_TEST_PRIV != 3
#error invalid privilege
#endif
#if __riscv_xlen == 64
#define MIN_INT 0x8000000000000000
#else
#define MIN_INT 0x80000000
#endif
.option norvc
.option norelax
.section .text
.globl _start
.macro check_op op, a, b, expected
  li t0, \a
  li t1, \b
  \op t2, t0, t1
  li t3, \expected
  bne t2, t3, fail
  /* Destination/source overlap exercises rename and dependent consumption. */
  \op t0, t0, t1
  bne t0, t3, fail
  addi s6, s6, 1
.endm
.macro illegal encoding
  li s8, \encoding
  la s7, 991f
  li a5, 0x55a
991:
  .word \encoding
  bnez s7, fail
  li t0, 0x55a
  bne a5, t0, fail
.endm
_start:
  csrw mstatus, zero
  csrw mie, zero
  csrw medeleg, zero
  csrw satp, zero
  la t0, trap
  csrw mtvec, t0
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
  li s6, 0
  li s7, 0
  li s9, 0
  li t0, (ZEXTH_TEST_PRIV << 11)
  csrw mstatus, t0
  la t0, body
  csrw mepc, t0
  mret
body:
  li t0, -32767
  zext.h t2,t0
  li t3, 0x8001
  bne t2,t3,fail
  addi s6,s6,1
  li s0, -32767
  .hword 0x9c69
  bne s0,t3,fail
  addi s6,s6,1
  li s1, -32767
  .hword 0x9ce9
  bne s1,t3,fail
  addi s6,s6,1
  li a0, -32767
  .hword 0x9d69
  bne a0,t3,fail
  addi s6,s6,1
  li a1, -32767
  .hword 0x9de9
  bne a1,t3,fail
  addi s6,s6,1
  li a2, -32767
  .hword 0x9e69
  bne a2,t3,fail
  addi s6,s6,1
  li a3, -32767
  .hword 0x9ee9
  bne a3,t3,fail
  addi s6,s6,1
  li a4, -32767
  .hword 0x9f69
  bne a4,t3,fail
  addi s6,s6,1
  li a5, -32767
  .hword 0x9fe9
  bne a5,t3,fail
  addi s6,s6,1
#if __riscv_xlen == 64
  illegal 0x0802c7b3
#else
  illegal 0x0802c7bb
#endif
  li s7, 0
  ecall
  j fail
.balign 4
trap:
  csrr t4, mcause
  li t5, 2
  bne t4, t5, finish
  beqz s7, fail
  csrr t4, mepc
  bne t4, s7, fail
  csrr t4, mtval
  bne t4, s8, fail
  csrr t4, mstatus
  srli t4, t4, 11
  andi t4, t4, 3
  li t5, ZEXTH_TEST_PRIV
  bne t4, t5, fail
  addi s7, s7, 4
  csrw mepc, s7
  li s7, 0
  addi s9, s9, 1
  mret
finish:
  li t5, (8 + ZEXTH_TEST_PRIV)
  bne t4, t5, fail
  li t0, 9
  li t1, 1
  bne s6, t0, fail
  bne s9, t1, fail
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
  j fail
