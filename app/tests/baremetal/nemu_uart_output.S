.option norvc
.option norelax
.section .text
.globl _start
_start:
  csrr s0, mhartid
  la s1, turn
  li s2, 0x10000000
wait_turn:
  lw t0, 0(s1)
  bne t0, s0, wait_turn
  la s3, message
write_message:
  lbu t0, 0(s3)
  beqz t0, write_hart
  sb t0, 0(s2)
  addi s3, s3, 1
  j write_message
write_hart:
  addi t0, s0, '0'
  sb t0, 0(s2)
  li t0, 10
  sb t0, 0(s2)
  addi t0, s0, 1
  fence rw, rw
  sw t0, 0(s1)
  bnez s0, parked
wait_done:
  lw t0, 0(s1)
  li t1, HARTS
  bne t0, t1, wait_done
  li t0, 0x100000
  li t1, 0x5555
  sw t1, 0(t0)
parked:
  wfi
  j parked
.section .rodata
message:
  .asciz "NEMU_UART_OUTPUT hart="
.section .data
.balign 8
turn:
  .word 0
