.section entry, "ax"
.globl _start
.type _start, @function

_start:
  li t0, 0xa000004c
  lbu ra, (t0)
  ebreak

  mv s0, zero
  la sp, _stack_pointer
  jal _first_stage_bootloader
