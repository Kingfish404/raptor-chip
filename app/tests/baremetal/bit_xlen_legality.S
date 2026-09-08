/* Selected XLEN legality and native REV8/bit-index controls in M/S/U.
 * Reserved counterpart encodings follow this platform's illegal policy. */
#ifndef BIT_TEST_PRIV
#define BIT_TEST_PRIV 3
#endif
#if BIT_TEST_PRIV != 0 && BIT_TEST_PRIV != 1 && BIT_TEST_PRIV != 3
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
  li t0, (BIT_TEST_PRIV << 11)
  csrw mstatus, t0
  la t0, body
  csrw mepc, t0
  mret
body:
  li t0, 0x01020304
  rev8 t2, t0
#if __riscv_xlen == 64
  li t3, 0x0403020100000000
#else
  li t3, 0x04030201
#endif
  bne t2, t3, fail
  addi s6, s6, 1
  bseti t2, zero, (__riscv_xlen - 1)
  li t3, MIN_INT
  bne t2, t3, fail
  addi s6, s6, 1
#if __riscv_xlen == 32
  /* The 6th shift-immediate bit is reserved for these RV32 operations. */
  illegal 0x02029793
  illegal 0x0202d793
  illegal 0x4202d793
  illegal 0x6202d793
  illegal 0x2a029793
  illegal 0x4a029793
  illegal 0x6a029793
  illegal 0x4a02d793
  illegal 0x6b82d793
#else
  /* The RV32 REV8 encoding is unimplemented in this RV64 platform. */
  illegal 0x6982d793
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
  li t5, BIT_TEST_PRIV
  bne t4, t5, fail
  addi s7, s7, 4
  csrw mepc, s7
  li s7, 0
  addi s9, s9, 1
  mret
finish:
  li t5, (8 + BIT_TEST_PRIV)
  bne t4, t5, fail
#if __riscv_xlen == 64
  li t0, 2
  li t1, 1
#else
  li t0, 2
  li t1, 9
#endif
  bne s6, t0, fail
  bne s9, t1, fail
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
  j fail
