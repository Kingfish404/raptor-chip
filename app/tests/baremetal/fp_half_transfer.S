/* Half moves and ordinary-RAM transfers preserve raw payloads and FCSR.
 * Misaligned offsets exercise this platform's RAM support, not MMIO atomicity. */
.option norvc
.option norelax
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
  la s2, result
next_case:
  fld ft0, 0(s0)
  lhu s3, 0(s0)
  slli s4, s3, (__riscv_xlen-16)
  srai s4, s4, (__riscv_xlen-16)
  fmv.x.h t0, ft0
  bne t0, s4, fail
  fmv.x.h zero, ft0
  li t0, 0x5a5a0000
  or t0, t0, s3
  fmv.h.x ft1, t0
  fsd ft1, 0(s2)
  lw t0, 0(s2)
  li t1, -65536
  or t1, t1, s3
  bne t0, t1, fail
  lw t0, 4(s2)
  li t1, -1
  bne t0, t1, fail
  fmv.h.x ft1, zero
  fsd ft1, 0(s2)
  lw t0, 0(s2)
  li t1, -65536
  bne t0, t1, fail
  lw t0, 4(s2)
  li t1, -1
  bne t0, t1, fail
  la s5, offsets
  li s6, 9
next_offset:
  la s7, scratch
  li t0, 0
  li t1, 0xaa
fill:
  add t2, s7, t0
  sb t1, 0(t2)
  addi t0, t0, 1
  li t2, 128
  bne t0, t2, fill
  lbu s8, 0(s5)
  add s9, s7, s8
  fsh ft0, 0(s9)
  flh ft1, 0(s9)
  fsd ft1, 0(s2)
  lw t0, 0(s2)
  li t1, -65536
  or t1, t1, s3
  bne t0, t1, fail
  lw t0, 4(s2)
  li t1, -1
  bne t0, t1, fail
  li t0, 0
scan:
  li t1, 0xaa
  bne t0, s8, not_low
  andi t1, s3, 255
not_low:
  addi t2, s8, 1
  bne t0, t2, not_high
  srli t1, s3, 8
not_high:
  add t2, s7, t0
  lbu t3, 0(t2)
  bne t3, t1, fail
  addi t0, t0, 1
  li t2, 128
  bne t0, t2, scan
  csrr t0, fcsr
  li t1, 0x95
  bne t0, t1, fail
  addi s5, s5, 1
  addi s6, s6, -1
  bnez s6, next_offset
  addi s0, s0, 8
  addi s1, s1, -1
  bnez s1, next_case
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
offsets: .byte 0,1,2,3,4,5,6,7,63
.balign 8
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
scratch: .space 128
