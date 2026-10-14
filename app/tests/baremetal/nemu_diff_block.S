.option norvc
.option norelax
.section .text
.globl _start
_start:
  csrr a0, mhartid
  la sp, nemu_block_stacks
  addi t0, a0, 1
  slli t0, t0, 12
  add sp, sp, t0
  la t0, nemu_block_trap
  csrw mtvec, t0
  call nemu_block_main
nemu_block_trap:
  li t0, 0x100000
  li t1, 0x3333
  sw t1, 0(t0)
  j nemu_block_trap
