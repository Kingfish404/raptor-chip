/* Negative-offset FLH must not allocate/write the same-numbered GPR.
 * Both endpoint controls and all32 offending immediates; malformed boxes
 * on FSH exercise raw payload transfer, all result words checked on RV32. */
.option norvc
.option norelax
.macro probe off, freg, xreg
  li \xreg, 0x13579
  fsh ft0, \off(s8)
  li t0, 0x13579
  bne \xreg, t0, fail
  addi t0, s8, \off
  lhu t1, 0(t0)
  bne t1, s3, fail
  flh \freg, \off(s8)
  li t0, 0x13579
  bne \xreg, t0, fail
  fsd \freg, 0(s9)
  lw t0, 0(s9)
  li t1, -65536
  or t1, t1, s3
  bne t0, t1, fail
  lw t0, 4(s9)
  li t1, -1
  bne t0, t1, fail
  csrr t0, fcsr
  li t1, 0x95
  bne t0, t1, fail
  addi s10, s10, 1
.endm
.section .text
.globl _start
_start:
  la t0, fail
  csrw mtvec, t0
  csrw mie, zero
  li t0, 0x6000
  csrs mstatus, t0
  li t0, 0x95
  csrw fcsr, t0
  la s0, cases
  li s1, 16
  la s8, region
  addi s8, s8, 512
  la s9, result
  li s10, 0
next_case:
  fld ft0, 0(s0)
  lhu s3, 0(s0)
  probe -449, ft2, sp
  probe -449, ft11, t6
  probe -448, ft2, sp
  probe -448, ft11, t6
  probe -447, ft2, sp
  probe -447, ft11, t6
  probe -446, ft2, sp
  probe -446, ft11, t6
  probe -445, ft2, sp
  probe -445, ft11, t6
  probe -444, ft2, sp
  probe -444, ft11, t6
  probe -443, ft2, sp
  probe -443, ft11, t6
  probe -442, ft2, sp
  probe -442, ft11, t6
  probe -441, ft2, sp
  probe -441, ft11, t6
  probe -440, ft2, sp
  probe -440, ft11, t6
  probe -439, ft2, sp
  probe -439, ft11, t6
  probe -438, ft2, sp
  probe -438, ft11, t6
  probe -437, ft2, sp
  probe -437, ft11, t6
  probe -436, ft2, sp
  probe -436, ft11, t6
  probe -435, ft2, sp
  probe -435, ft11, t6
  probe -434, ft2, sp
  probe -434, ft11, t6
  probe -433, ft2, sp
  probe -433, ft11, t6
  probe -432, ft2, sp
  probe -432, ft11, t6
  probe -431, ft2, sp
  probe -431, ft11, t6
  probe -430, ft2, sp
  probe -430, ft11, t6
  probe -429, ft2, sp
  probe -429, ft11, t6
  probe -428, ft2, sp
  probe -428, ft11, t6
  probe -427, ft2, sp
  probe -427, ft11, t6
  probe -426, ft2, sp
  probe -426, ft11, t6
  probe -425, ft2, sp
  probe -425, ft11, t6
  probe -424, ft2, sp
  probe -424, ft11, t6
  probe -423, ft2, sp
  probe -423, ft11, t6
  probe -422, ft2, sp
  probe -422, ft11, t6
  probe -421, ft2, sp
  probe -421, ft11, t6
  probe -420, ft2, sp
  probe -420, ft11, t6
  probe -419, ft2, sp
  probe -419, ft11, t6
  probe -418, ft2, sp
  probe -418, ft11, t6
  probe -417, ft2, sp
  probe -417, ft11, t6
  probe -416, ft2, sp
  probe -416, ft11, t6
  addi s0, s0, 8
  addi s1, s1, -1
  bnez s1, next_case
  li t0, 1088
  bne s10, t0, fail
  li a0, 0
  ebreak
1: j 1b
fail:
  li a0, 1
  ebreak
2: j 2b
.section .data
.balign 8
result: .quad 0
cases:
  .quad 0xffffffffffff0000, 0x0123456789ab8000
  .quad 0xffffffffffff0001, 0x0123456789ab8001
  .quad 0xffffffffffff03ff, 0x0123456789ab0400
  .quad 0xffffffffffff3c00, 0x0123456789abbc00
  .quad 0xffffffffffff4000, 0x0123456789ab3bff
  .quad 0xffffffffffff7bff, 0x0123456789abfbff
  .quad 0xffffffffffff7c00, 0x0123456789abfc00
  .quad 0xffffffffffff7c01, 0x0123456789ab7e55
.balign 64
region: .space 640
