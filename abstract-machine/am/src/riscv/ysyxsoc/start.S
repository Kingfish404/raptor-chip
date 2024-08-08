.section entry, "ax"
.globl _start
.type _start, @function

_start:
  mv s0, zero
  la sp, _stack_pointer
  mv a0, zero
  sw	ra,8(sp)
  mv a0, zero
  ebreak
  jal _first_stage_bootloader
