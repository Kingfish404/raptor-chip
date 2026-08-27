  .section .text
  .globl _start
_start:
  la a0, aligned_string
  call strlen_zbb
  li t0, 15
  bne a0, t0, fail

  la a0, unaligned_string
  addi a0, a0, 1
  call strlen_zbb
  li t0, 8
  bne a0, t0, fail

  li a0, 0
  ebreak

fail:
  li a0, 1
  ebreak

strlen_zbb:
  andi t2, a0, 7
  andi t0, a0, -8
  li t3, 8
  sub t3, t3, t2
  slli t2, t2, 3
  ld t1, 0(t0)
  srl t1, t1, t2
  orc.b t1, t1
  not t1, t1
  ctz t1, t1
  srli a0, t1, 3
  bltu a0, t3, strlen_done
  addi t2, t0, 8
  li t3, -1
  .align 3
strlen_loop:
  ld t1, 8(t0)
  addi t0, t0, 8
  orc.b t1, t1
  beq t1, t3, strlen_loop
  not t1, t1
  ctz t1, t1
  srli t1, t1, 3
  sub t2, t0, t2
  add a0, a0, t2
  add a0, a0, t1
strlen_done:
  ret

  .section .rodata
  .balign 8
aligned_string:
  .asciz "0123456789abcde"
  .balign 8
unaligned_string:
  .byte 0xff
  .asciz "/dev/abc"