.section .text
.globl _start
_start:
  li t0, 0x6000
  csrs mstatus, t0

  la t0, fp_one
  fld ft0, 0(t0)
  la t0, fp_two
  fld ft1, 0(t0)

  fadd.d ft2, ft0, ft1
  la t0, result_add
  fsd ft2, 0(t0)
  lw t1, 0(t0)
  bnez t1, fail_add
  lw t1, 4(t0)
  li t2, 0x40080000
  bne t1, t2, fail_add

  fsub.d ft3, ft2, ft0
  la t0, result_sub
  fsd ft3, 0(t0)
  lw t1, 0(t0)
  bnez t1, fail_sub
  lw t1, 4(t0)
  li t2, 0x40000000
  bne t1, t2, fail_sub

  fmul.d ft4, ft3, ft1
  la t0, result_mul
  fsd ft4, 0(t0)
  lw t1, 0(t0)
  bnez t1, fail_mul
  lw t1, 4(t0)
  li t2, 0x40100000
  bne t1, t2, fail_mul

  li t0, 0x00100000
  li t1, 0x5555
  sw t1, 0(t0)

fail_add:
  li t0, 0x00100000
  li t1, 0x00013333
  sw t1, 0(t0)

fail_sub:
  li t0, 0x00100000
  li t1, 0x00023333
  sw t1, 0(t0)

fail_mul:
  li t0, 0x00100000
  li t1, 0x00033333
  sw t1, 0(t0)

.section .data
.align 3
fp_one:
  .dword 0x3ff0000000000000
fp_two:
  .dword 0x4000000000000000
result_add:
  .dword 0
result_sub:
  .dword 0
result_mul:
  .dword 0