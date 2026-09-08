/* A younger split load begins before an older byte store and includes it.
 * Cover every byte alignment at word/line/page boundaries in Bare RAM. */
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, fail
  csrw mtvec, t0
  li t0, 0x6000
  csrw mstatus, t0
  la s0, area
  la s4, sink
  li s2, 8
  li s3, 0
boundary_loop:
  add s6, s0, s2
  addi s6, s6, -8
  li s1, 0
.macro setup bytes
  sw zero, 0(s6)
  sw zero, 4(s6)
  sw zero, 8(s6)
  sw zero, 12(s6)
  fence rw,rw
  add s5, s6, s1
  addi t1, s5, (\bytes-1)
  li t0, 0x11
.endm
.macro probe insn, bytes
  setup \bytes
  \insn t3, 0(s5)
  bnez t3, fail
  li t5, (0x11 << (8*(\bytes-1)))
  sb t0, 0(t1)
  \insn t3, 0(s5)
  bne t3, t5, fail
.endm
offset_loop:
  probe lbu, 1
  probe lhu, 2
  probe lw, 4
#if __riscv_xlen == 64
  probe ld, 8
#endif
  setup 8
  fld ft1, 0(s5)
  sb t0, 0(t1)
  fld ft1, 0(s5)
  fsd ft1, 0(s4)
  // Inspect the loaded FP bits through an aligned store, on both XLENs.
  lbu t3, 7(s4)
  bne t3, t0, fail
  lw t3, 0(s4)
  bnez t3, fail
  lhu t3, 4(s4)
  bnez t3, fail
  lbu t3, 6(s4)
  bnez t3, fail
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
sink: .zero 8
.balign 4096
area: .zero 8192
