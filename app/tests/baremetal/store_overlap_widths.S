/* Store footprints at word, cache-line and page boundaries in Bare RAM.
 * FENCE isolates setup only; tested store/load pairs have no added fence. */
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, fail
  csrw mtvec, t0
  li t0, 0x6000
  csrw mstatus, t0
  la s4, pattern
  fld ft0, 0(s4)
#if __riscv_xlen == 64
  ld s7, 0(s4)
#else
  lw s7, 0(s4)
#endif
  la s0, area
  li s2, 8
  li s3, 0
boundary_loop:
  add s6, s0, s2
  li s1, 0
  addi s6, s6, -8
// Each macro clears surrounding bytes then tests the high byte first,
// followed by all stored bytes and the two adjacent guard bytes.
.macro probe insn, reg, bytes
  sw zero, 0(s6)
  sw zero, 4(s6)
  sw zero, 8(s6)
  sw zero, 12(s6)
  fence rw,rw
  add s5, s6, s1
  addi t1, s5, (\bytes-1)
  lbu t2, 0(t1)
  lbu t5, (\bytes-1)(s4)
  \insn \reg, 0(s5)
  lbu t3, 0(t1)
  bne t3, t5, fail
  li t1, 0
byte_loop_\@:
  add t2, s5, t1
  lbu t3, 0(t2)
  add t2, s4, t1
  lbu t5, 0(t2)
  bne t3, t5, fail
  addi t1, t1, 1
  li t2, \bytes
  bltu t1, t2, byte_loop_\@
  lbu t3, -1(s5)
  bnez t3, fail
  lbu t3, \bytes(s5)
  bnez t3, fail
.endm
offset_loop:
  probe sb, s7, 1
  probe sh, s7, 2
  probe sw, s7, 4
#if __riscv_xlen == 64
  probe sd, s7, 8
#endif
  probe fsd, ft0, 8
  addi s1, s1, 1
  li t0, 8
  bltu s1, t0, offset_loop
  addi s3, s3, 1
  li s2, 64
  li t0, 1
  beq s3, t0, boundary_loop
  li s2, 4096
  li t0, 2
  beq s3, t0, boundary_loop
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
  j fail
.section .data
.balign 8
pattern: .byte 0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x08
.balign 4096
.zero 4096
area: .zero 8192
