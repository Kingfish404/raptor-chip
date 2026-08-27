.macro TEST_BYTES ptr, fail_label
  lbu t2, 0(\ptr)
  li t3, 0x88
  bne t2, t3, \fail_label
  lbu t2, 1(\ptr)
  li t3, 0x77
  bne t2, t3, \fail_label
  lbu t2, 2(\ptr)
  li t3, 0x66
  bne t2, t3, \fail_label
  lbu t2, 3(\ptr)
  li t3, 0x55
  bne t2, t3, \fail_label
  lbu t2, 4(\ptr)
  li t3, 0x44
  bne t2, t3, \fail_label
  lbu t2, 5(\ptr)
  li t3, 0x33
  bne t2, t3, \fail_label
  lbu t2, 6(\ptr)
  li t3, 0x22
  bne t2, t3, \fail_label
  lbu t2, 7(\ptr)
  li t3, 0x11
  bne t2, t3, \fail_label
.endm

.section .text
.globl _start
_start:
  li t0, 0x6000
  csrs mstatus, t0

  la t0, pattern
  fld ft0, 0(t0)
  nop
  nop
  nop
  nop
  nop
  nop
  nop
  nop
  fmv.x.w t4, ft0
  li t5, 0x55667788
  bne t4, t5, fail_fld

  la t1, scratch
  addi t1, t1, 1
  fsd ft0, 0(t1)
  TEST_BYTES t1, fail_first

  la t1, scratch
  addi t1, t1, 2
  fsd ft0, 0(t1)
  TEST_BYTES t1, fail_second

  la t1, scratch
  addi t1, t1, 3
  fsd ft0, 0(t1)
  TEST_BYTES t1, fail_third

  li t0, 0x00100000
  li t1, 0x5555
  sw t1, 0(t0)

fail_first:
  li t0, 0x00100000
  li t1, 0x00013333
  sw t1, 0(t0)

fail_second:
  li t0, 0x00100000
  li t1, 0x00014333
  sw t1, 0(t0)

fail_third:
  li t0, 0x00100000
  li t1, 0x00015333
  sw t1, 0(t0)

fail_fld:
  li t0, 0x00100000
  li t1, 0x00023333
  sw t1, 0(t0)

.section .data
.align 3
pattern:
  .dword 0x1122334455667788
scratch:
  .fill 32, 1, 0xa5