.section .text
.globl _start
_start:
  li t0, 0x6000
  csrs mstatus, t0

  la t0, one_double
  fld ft0, 0(t0)
  la t0, two_double
  fld ft1, 0(t0)
  fadd.d ft2, ft0, ft1
  la t0, result_double
  fsd ft2, 0(t0)

  lw t1, 0(t0)
  lw t2, 4(t0)
  li t3, 0x00000000
  bne t1, t3, fail
  li t3, 0x40080000
  bne t2, t3, fail

  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak

.section .data
.align 3
one_double:
  .dword 0x3ff0000000000000
two_double:
  .dword 0x4000000000000000
result_double:
  .dword 0
