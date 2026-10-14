/* Reuse a taken branch's ROB entry for a faulting load. A stale btaken
 * must never cause a BTB update for the exception. Sweep each ROB size. */
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, handler
  csrw mtvec, t0
  li s0, 0x40000000
  li s2, 1
  li s4, 0
  la s7, ram_words
.macro exercise filler
  li s1, 256
  li s3, 0
  la s6, load\@
loop\@:
  beq s2, s2, taken\@
  addi s4, s4, 1
 taken\@:
  .rept \filler
  lw t5, 0(s7)
  .endr
load\@:
  lw t1, 0(s0)
  addi s1, s1, -1
  bnez s1, loop\@
  li t2, 256
  bne s3, t2, fail
  bnez s4, fail
.endm
  exercise 3
  exercise 15
  exercise 31
  exercise 63
  exercise 127
  li a0, 0
  ebreak
.balign 4
handler:
  csrr t3, mcause
  li t4, 5
  bne t3, t4, fail
  csrr t3, mtval
  bne t3, s0, fail
  csrr t3, mepc
  bne t3, s6, fail
  addi t3, t3, 4
  csrw mepc, t3
  addi s3, s3, 1
  mret
fail:
  li a0, 1
  ebreak
.section .data
.balign 64
ram_words:
  .word 0
