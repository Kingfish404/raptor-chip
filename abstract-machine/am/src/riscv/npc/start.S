.section entry, "ax"
.globl _start
.type _start, @function

_start:
  mv s0, zero
  la sp, _stack_pointer
  mv ra, zero
  mv a0, zero
  ebreak
  jal _trm_init
