/* Compressed integer nonzero-register policy and precise raw tval. */
#ifndef C_REGISTER_TEST_PRIV
#define C_REGISTER_TEST_PRIV 3
#endif
#if C_REGISTER_TEST_PRIV != 0 && C_REGISTER_TEST_PRIV != 1 && C_REGISTER_TEST_PRIV != 3
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
.macro illegal encoding
  li s8, \encoding
  la s7, 991f
  li a5, 0x55a
991:
  .hword \encoding
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
  li t0, (C_REGISTER_TEST_PRIV << 11)
  csrw mstatus, t0
  la t0, body
  csrw mepc, t0
  mret
body:
  la sp, scratch
  li t0, 0x12345678
  sw t0, 0(sp)
  .hword 0x4402 /* C.LWSP s0,0(sp) */
  bne s0,t0,fail
  addi s6,s6,1
  la s0, 1f
  .hword 0x8402 /* C.JR s0 */
  j fail
1:
  addi s6,s6,1
#if __riscv_xlen == 64
  li s0,-1
  .hword 0x2401 /* C.ADDIW s0,0 is legal */
  li t0,-1
  bne s0,t0,fail
#else
  .hword 0x2011 /* C.JAL +4, rd field zero in overlapping RV64 encoding */
  .hword 0x0000
#endif
  addi s6,s6,1
  illegal 0x4002
  illegal 0x507e
  illegal 0x8002
#if __riscv_xlen == 64
  illegal 0x6002
  illegal 0x707e
  illegal 0x2001
  illegal 0x307d
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
  li t5, C_REGISTER_TEST_PRIV
  bne t4, t5, fail
  addi s7, s7, 2
  csrw mepc, s7
  li s7, 0
  addi s9, s9, 1
  mret
finish:
  li t5, (8 + C_REGISTER_TEST_PRIV)
  bne t4, t5, fail
  li t0, 3
#if __riscv_xlen == 64
  li t1, 7
#else
  li t1, 3
#endif
  bne s6, t0, fail
  bne s9, t1, fail
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
  j fail

.section .bss
.balign 16
scratch: .space 512
