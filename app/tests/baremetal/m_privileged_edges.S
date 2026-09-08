/* M 2.0 architectural edge cases in M/S/U, with literal expected values.
 * Reserved OP-32 funct3=1/2/3 checks are the selected platform's illegal
 * encoding policy, not a claim that all reserved encodings must trap. */
#ifndef M_TEST_PRIV
#define M_TEST_PRIV 3
#endif
#if M_TEST_PRIV != 0 && M_TEST_PRIV != 1 && M_TEST_PRIV != 3
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
  li t0, (M_TEST_PRIV << 11)
  csrw mstatus, t0
  la t0, body
  csrw mepc, t0
  mret
body:
  check_op mul, -7, 3, -21
  check_op mulh, -7, 3, -1
  check_op mulhsu, -1, -1, -1
  check_op mulhu, -1, -1, -2
  check_op div, -7, 3, -2
  check_op rem, -7, 3, -1
  check_op div, 7, -3, -2
  check_op rem, 7, -3, 1
  check_op divu, -1, 1, -1
  check_op remu, -1, 1, 0
  check_op div, MIN_INT, -1, MIN_INT
  check_op rem, MIN_INT, -1, 0
  check_op div, 7, 0, -1
  check_op divu, 7, 0, -1
  check_op rem, -7, 0, -7
  check_op remu, -7, 0, -7
#if __riscv_xlen == 64
  /* Upper halves deliberately disagree with the low-word interpretation. */
  check_op mulw, 0x1234567880000001, 3, -2147483645
  check_op divw, 0x1234567880000000, -1, -2147483648
  check_op remw, 0x1234567880000000, -1, 0
  check_op divuw, 0x12345678ffffffff, 1, -1
  check_op remuw, 0x1234567880000001, 0, -2147483647
  check_op divw, 0x12345678fffffff9, 0xabcdef0000000003, -2
  check_op remw, 0x12345678fffffff9, 0xabcdef0000000003, -1
  check_op divw, 0x1234567800000007, 0xabcdef0000000000, -1
  check_op divuw, 0x1234567800000007, 0xabcdef0000000000, -1
  check_op remw, 0x1234567880000001, 0xabcdef0000000000, -2147483647
  /* rs1=t0, rs2=t1, rd=a5, funct7=1, OP-32. */
  illegal 0x026297bb
  illegal 0x0262a7bb
  illegal 0x0262b7bb
#else
  /* All five RV64 M word operations must be rejected in RV32. */
  illegal 0x026287bb
  illegal 0x0262c7bb
  illegal 0x0262d7bb
  illegal 0x0262e7bb
  illegal 0x0262f7bb
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
  li t5, M_TEST_PRIV
  bne t4, t5, fail
  addi s7, s7, 4
  csrw mepc, s7
  li s7, 0
  addi s9, s9, 1
  mret
finish:
  li t5, (8 + M_TEST_PRIV)
  bne t4, t5, fail
#if __riscv_xlen == 64
  li t0, 26
  li t1, 3
#else
  li t0, 16
  li t1, 5
#endif
  bne s6, t0, fail
  bne s9, t1, fail
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
  j fail
