/* Reuse a taken branch's ROB entry for an AMO whose completion does not
 * update btaken. Sweep ROB-1 for the 4/16/32/64/128-entry windows. */
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la s0, ram_words
  li s2, 1
  li s3, 0
.macro exercise filler
  sw zero, 0(s0)
  li s1, 256
loop\@:
  beq s2, s2, taken\@
  addi s3, s3, 1
 taken\@:
  .rept \filler
  lw t3, 64(s0)
  .endr
  amoadd.w t1, s2, (s0)
  addi s1, s1, -1
  bnez s1, loop\@
  lw t1, 0(s0)
  li t2, 256
  bne t1, t2, fail
  bnez s3, fail
.endm
  exercise 3
  exercise 15
  exercise 31
  exercise 63
  exercise 127
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
.section .data
.balign 64
ram_words:
  .zero 128
