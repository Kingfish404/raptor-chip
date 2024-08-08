.section entry, "ax"
.globl _start
.type _start, @function

_start:
  mv s0, zero
  la sp, _stack_pointer
  mv a0, zero
  add	sp,sp,-12
  sw	ra,8(sp)
  li t0, 0x80000000
  add t0, t0, 0x80
  jal _first_stage_bootloader
