.section entry, "ax"
.globl _start
.type _start, @function

_start:
  mv s0, zero
  la sp, _stack_pointer
  mv a0, zero
  sw a0, 0(sp)
  ebreak
  jal _first_stage_bootloader
