#include "fp_test_macros.h"

.section .text
.globl _start
_start:
  li t0, 0x6000
  csrs mstatus, t0

  csrw fflags, zero
  li t0, 3
  csrw frm, t0

  li t0, 0x3f800000
  fmv.w.x ft0, t0
  li t0, 0x33800000
  fmv.w.x ft1, t0

  fadd.s ft2, ft0, ft1, dyn
  fmv.x.w t1, ft2
  FP_CHECK_T1 0x3f800001, fail_rup

  FP_CHECK_FFLAGS 1, fail_flags

  csrr t1, fcsr
  FP_CHECK_T1 0x61, fail_fcsr

  li t0, 0
  csrw frm, t0
  fadd.s ft3, ft0, ft1, dyn
  fmv.x.w t1, ft3
  FP_CHECK_T1 0x3f800000, fail_rne

  FP_CHECK_FFLAGS 1, fail_sticky

  csrw fflags, zero
  FP_CHECK_FFLAGS 0, fail_clear

  li t0, 0x7f800000
  fmv.w.x ft4, t0
  li t0, 0xff800000
  fmv.w.x ft5, t0
  fadd.s ft6, ft4, ft5

  FP_CHECK_FFLAGS 0x10, fail_nv

  csrr t1, fcsr
  bne t1, t2, fail_nv_fcsr

  li t0, 0x00100000
  li t1, 0x5555
  sw t1, 0(t0)

  FP_FAIL fail_rup, 0x00013333

  FP_FAIL fail_flags, 0x00023333

  FP_FAIL fail_rne, 0x00033333

  FP_FAIL fail_sticky, 0x00043333

  FP_FAIL fail_clear, 0x00053333

  FP_FAIL fail_fcsr, 0x00063333

  FP_FAIL fail_nv, 0x00073333

  FP_FAIL fail_nv_fcsr, 0x00083333