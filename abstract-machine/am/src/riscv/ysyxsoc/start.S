.section entry, "ax"
.globl _start
.type _start, @function

_start:
  mv s0, zero
  la sp, _stack_pointer
  lui	a5,0x80001
  li	a4,66
  sb	a4,0(a5)
  jal _first_stage_bootloader
