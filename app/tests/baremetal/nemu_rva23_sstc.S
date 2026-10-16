.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, fail
  csrw mtvec, t0
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 15
  csrw pmpcfg0, t0

  csrr t0, misa
  li t1, 1 << 21
  and t0, t0, t1
  beqz t0, fail
  li t0, 0x200
  csrs mstatus, t0
  li t0, 4
  .word (0xc0 << 20) | (5 << 15) | (7 << 12) | (6 << 7) | 0x57
  li t2, 4
  bne t1, t2, fail

  li t0, 4
  .word (0xd0 << 20) | (5 << 15) | (7 << 12) | (6 << 7) | 0x57
  la t0, vector_source
  addi t0, t0, 1
  .word (1 << 25) | (5 << 15) | (6 << 12) | (8 << 7) | 0x07
  la t0, vector_destination
  addi t0, t0, 1
  .word (1 << 25) | (5 << 15) | (6 << 12) | (8 << 7) | 0x27
  la t0, vector_source
  la t1, vector_destination
  li t2, 18
vector_compare:
  lbu t3, 0(t0)
  lbu t4, 0(t1)
  bne t3, t4, fail
  addi t0, t0, 1
  addi t1, t1, 1
  addi t2, t2, -1
  bnez t2, vector_compare

  li t0, 64
  csrs 0x600, t0
  csrr t1, 0x600
  and t1, t1, t0
  beqz t1, fail
  csrc 0x600, t0
  csrr t1, 0x600
  and t1, t1, t0
  bnez t1, fail

  li t0, 0x8000000000000000
  csrw 0x30a, t0
  li t0, -1
  csrw 0x14d, t0
  csrr t0, time
  addi t0, t0, 1000
  csrw 0x14d, t0
  li t3, 1000000
wait_pending:
  csrr t1, mip
  andi t1, t1, 32
  bnez t1, pending
  addi t3, t3, -1
  bnez t3, wait_pending
  j fail
pending:
  csrw mip, zero
  csrr t1, mip
  andi t1, t1, 32
  beqz t1, fail
  li t0, -1
  csrw 0x14d, t0
  li t3, 1000000
wait_clear:
  csrr t1, mip
  andi t1, t1, 32
  beqz t1, cleared
  addi t3, t3, -1
  bnez t3, wait_clear
  j fail
cleared:
  csrw 0x30a, zero
  li t0, 32
  csrs mip, t0
  csrr t1, mip
  and t1, t1, t0
  beqz t1, fail
  csrc mip, t0
  csrr t1, mip
  and t1, t1, t0
  bnez t1, fail
  li t0, 0x100000
  li t1, 0x5555
  sw t1, 0(t0)
  j fail

fail:
  li t0, 0x100000
  li t1, 0x3333
  sw t1, 0(t0)
  j fail

.section .data
.balign 8
vector_source:
  .byte 0xa5, 1, 2, 3, 4, 5, 6, 7, 8
  .byte 9, 10, 11, 12, 13, 14, 15, 16, 0x5a
.balign 8
vector_destination:
  .byte 0xa5
  .zero 16
  .byte 0x5a
