#include "fp_test_macros.h"

.section .text
.globl _start
_start:
  li t0, 0x6000
  csrs mstatus, t0

  li t0, 0x3f800000
  fmv.w.x ft0, t0
  fadd.s ft1, ft0, ft0
  fmv.x.w t1, ft1
  FP_CHECK_T1 0x40000000, fail_fadd

  fsub.s ft2, ft1, ft0
  fmv.x.w t1, ft2
  FP_CHECK_T1 0x3f800000, fail_fsub

  li t0, 0x3fc00000
  fmv.w.x ft3, t0
  li t0, 0x40000000
  fmv.w.x ft4, t0
  fmul.s ft5, ft3, ft4
  fmv.x.w t1, ft5
  FP_CHECK_T1 0x40400000, fail_fmul

  li t0, 0x00100000
  li t1, 0x5555
  sw t1, 0(t0)
  FP_FAIL fail_fadd, 0x00013333

  FP_FAIL fail_fsub, 0x00023333

  FP_FAIL fail_fmul, 0x00033333
