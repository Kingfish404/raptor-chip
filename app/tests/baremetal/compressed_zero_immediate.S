/* Compressed zero-immediate policy, legal HINT and all eight C.MOP controls. */
#ifndef C_IMMEDIATE_TEST_PRIV
#define C_IMMEDIATE_TEST_PRIV 3
#endif
#if C_IMMEDIATE_TEST_PRIV != 0 && C_IMMEDIATE_TEST_PRIV != 1 && C_IMMEDIATE_TEST_PRIV != 3
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
  li t0, (C_IMMEDIATE_TEST_PRIV << 11)
  csrw mstatus, t0
  la t0, body
  csrw mepc, t0
  mret
body:
  la sp,scratch
  addi t3,sp,4
  .hword 0x0040 /* C.ADDI4SPN s0,sp,4 */
  bne s0,t3,fail
  addi s6,s6,1
  mv t3,sp
  .option rvc
  c.addi16sp sp,16
  c.addi16sp sp,-16
  .option norvc
  bne sp,t3,fail
  addi s6,s6,1
  .hword 0x6405 /* C.LUI s0,1 */
  li t3,4096
  bne s0,t3,fail
  addi s6,s6,1
  .hword 0x6005 /* C.LUI x0,1 HINT */
  .hword 0x707d /* C.LUI x0,-1 HINT */
  addi s6,s6,1
  li x1,0x55a
  .hword 0x6081 /* C.MOP.1 */
  li t3,0x55a
  bne x1,t3,fail
  addi s6,s6,1
  li x3,0x55a
  .hword 0x6181 /* C.MOP.3 */
  li t3,0x55a
  bne x3,t3,fail
  addi s6,s6,1
  li x5,0x55a
  .hword 0x6281 /* C.MOP.5 */
  li t3,0x55a
  bne x5,t3,fail
  addi s6,s6,1
  li x7,0x55a
  .hword 0x6381 /* C.MOP.7 */
  li t3,0x55a
  bne x7,t3,fail
  addi s6,s6,1
  li x9,0x55a
  .hword 0x6481 /* C.MOP.9 */
  li t3,0x55a
  bne x9,t3,fail
  addi s6,s6,1
  li x11,0x55a
  .hword 0x6581 /* C.MOP.11 */
  li t3,0x55a
  bne x11,t3,fail
  addi s6,s6,1
  li x13,0x55a
  .hword 0x6681 /* C.MOP.13 */
  li t3,0x55a
  bne x13,t3,fail
  addi s6,s6,1
  li x15,0x55a
  .hword 0x6781 /* C.MOP.15 */
  li t3,0x55a
  bne x15,t3,fail
  addi s6,s6,1
  illegal 0x0000
  illegal 0x0004
  illegal 0x0008
  illegal 0x000c
  illegal 0x0010
  illegal 0x0014
  illegal 0x0018
  illegal 0x001c
  illegal 0x6001
  illegal 0x6101
  illegal 0x6201
  illegal 0x6301
  illegal 0x6401
  illegal 0x6501
  illegal 0x6601
  illegal 0x6701
  illegal 0x6801
  illegal 0x6881
  illegal 0x6901
  illegal 0x6981
  illegal 0x6a01
  illegal 0x6a81
  illegal 0x6b01
  illegal 0x6b81
  illegal 0x6c01
  illegal 0x6c81
  illegal 0x6d01
  illegal 0x6d81
  illegal 0x6e01
  illegal 0x6e81
  illegal 0x6f01
  illegal 0x6f81
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
  li t5, C_IMMEDIATE_TEST_PRIV
  bne t4, t5, fail
  addi s7, s7, 2
  csrw mepc, s7
  li s7, 0
  addi s9, s9, 1
  mret
finish:
  li t5, (8 + C_IMMEDIATE_TEST_PRIV)
  bne t4, t5, fail
  li t0,12
  li t1,32
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
