#include "fp_test_macros.h"

.section .text
.globl _start
_start:
  li t0, 0x6000
  csrs mstatus, t0

  li t0, -1082130432
  fmv.w.x ft0, t0
  li t0, 0x3fc00000
  fmv.w.x ft1, t0
  flt.s t1, ft0, ft1
  FP_CHECK_T1 1, fail_s_flt
  fle.s t1, ft0, ft1
  bne t1, t2, fail_s_fle
  feq.s t1, ft0, ft1
  bnez t1, fail_s_feq

  li t0, 0
  fmv.w.x ft0, t0
  li t0, -2147483648
  fmv.w.x ft1, t0
  feq.s t1, ft0, ft1
  FP_CHECK_T1 1, fail_s_zero_eq
  flt.s t1, ft0, ft1
  bnez t1, fail_s_zero_lt
  fle.s t1, ft0, ft1
  bne t1, t2, fail_s_zero_le

  csrw fflags, zero
  li t0, 0x7fc00001
  fmv.w.x ft0, t0
  li t0, 0x3f800000
  fmv.w.x ft1, t0
  feq.s t1, ft0, ft1
  bnez t1, fail_s_qnan_eq
  FP_CHECK_FFLAGS 0, fail_s_qnan_eq_flags

  flt.s t1, ft0, ft1
  bnez t1, fail_s_qnan_lt
  FP_CHECK_FFLAGS 0x10, fail_s_qnan_lt_flags

  csrw fflags, zero
  li t0, 0x7f800001
  fmv.w.x ft0, t0
  feq.s t1, ft0, ft1
  bnez t1, fail_s_snan_eq
  FP_CHECK_FFLAGS 0x10, fail_s_snan_eq_flags

  li t0, -8388608
  fmv.w.x ft0, t0
  fclass.s t1, ft0
  FP_CHECK_T1 1, fail_s_class_neginf
  li t0, -1073741824
  fmv.w.x ft0, t0
  fclass.s t1, ft0
  FP_CHECK_T1 2, fail_s_class_negnorm
  li t0, -2147483647
  fmv.w.x ft0, t0
  fclass.s t1, ft0
  FP_CHECK_T1 4, fail_s_class_negsubnorm
  li t0, -2147483648
  fmv.w.x ft0, t0
  fclass.s t1, ft0
  FP_CHECK_T1 8, fail_s_class_negzero
  li t0, 0
  fmv.w.x ft0, t0
  fclass.s t1, ft0
  FP_CHECK_T1 16, fail_s_class_poszero
  li t0, 1
  fmv.w.x ft0, t0
  fclass.s t1, ft0
  FP_CHECK_T1 32, fail_s_class_possubnorm
  li t0, 0x3f800000
  fmv.w.x ft0, t0
  fclass.s t1, ft0
  FP_CHECK_T1 64, fail_s_class_posnorm
  li t0, 0x7f800000
  fmv.w.x ft0, t0
  fclass.s t1, ft0
  FP_CHECK_T1 128, fail_s_class_posinf
  li t0, 0x7f800001
  fmv.w.x ft0, t0
  fclass.s t1, ft0
  FP_CHECK_T1 256, fail_s_class_snan
  li t0, 0x7fc00001
  fmv.w.x ft0, t0
  fclass.s t1, ft0
  FP_CHECK_T1 512, fail_s_class_qnan

  la t0, d_pos_zero
  fld ft0, 0(t0)
  csrw fflags, zero
  fclass.s t1, ft0
  FP_CHECK_T1 512, fail_s_class_unboxed
  FP_CHECK_FFLAGS 0, fail_s_class_unboxed_flags

  la t0, d_neg_two
  fld ft0, 0(t0)
  la t0, d_pos_three
  fld ft1, 0(t0)
  flt.d t1, ft0, ft1
  FP_CHECK_T1 1, fail_d_flt
  fle.d t1, ft0, ft1
  bne t1, t2, fail_d_fle
  feq.d t1, ft0, ft1
  bnez t1, fail_d_feq

  la t0, d_pos_zero
  fld ft0, 0(t0)
  la t0, d_neg_zero
  fld ft1, 0(t0)
  feq.d t1, ft0, ft1
  FP_CHECK_T1 1, fail_d_zero_eq
  flt.d t1, ft0, ft1
  bnez t1, fail_d_zero_lt
  fle.d t1, ft0, ft1
  bne t1, t2, fail_d_zero_le

  csrw fflags, zero
  la t0, d_qnan
  fld ft0, 0(t0)
  la t0, d_one
  fld ft1, 0(t0)
  feq.d t1, ft0, ft1
  bnez t1, fail_d_qnan_eq
  FP_CHECK_FFLAGS 0, fail_d_qnan_eq_flags

  fle.d t1, ft0, ft1
  bnez t1, fail_d_qnan_le
  FP_CHECK_FFLAGS 0x10, fail_d_qnan_le_flags

  csrw fflags, zero
  la t0, d_snan
  fld ft0, 0(t0)
  feq.d t1, ft0, ft1
  bnez t1, fail_d_snan_eq
  FP_CHECK_FFLAGS 0x10, fail_d_snan_eq_flags

  la t0, d_neginf
  fld ft0, 0(t0)
  fclass.d t1, ft0
  FP_CHECK_T1 1, fail_d_class_neginf
  la t0, d_neg_two
  fld ft0, 0(t0)
  fclass.d t1, ft0
  FP_CHECK_T1 2, fail_d_class_negnorm
  la t0, d_negsubnorm
  fld ft0, 0(t0)
  fclass.d t1, ft0
  FP_CHECK_T1 4, fail_d_class_negsubnorm
  la t0, d_neg_zero
  fld ft0, 0(t0)
  fclass.d t1, ft0
  FP_CHECK_T1 8, fail_d_class_negzero
  la t0, d_poszero
  fld ft0, 0(t0)
  fclass.d t1, ft0
  FP_CHECK_T1 16, fail_d_class_poszero
  la t0, d_possubnorm
  fld ft0, 0(t0)
  fclass.d t1, ft0
  FP_CHECK_T1 32, fail_d_class_possubnorm
  la t0, d_posnorm
  fld ft0, 0(t0)
  fclass.d t1, ft0
  FP_CHECK_T1 64, fail_d_class_posnorm
  la t0, d_posinf
  fld ft0, 0(t0)
  fclass.d t1, ft0
  FP_CHECK_T1 128, fail_d_class_posinf
  la t0, d_snan
  fld ft0, 0(t0)
  fclass.d t1, ft0
  FP_CHECK_T1 256, fail_d_class_snan
  la t0, d_qnan
  fld ft0, 0(t0)
  fclass.d t1, ft0
  FP_CHECK_T1 512, fail_d_class_qnan

  csrw fflags, zero
  la t0, d_qnan
  fld ft0, 0(t0)
  la t0, d_one
  fld ft1, 0(t0)
  li t0, 0x4000
  csrw mstatus, t0
  fclass.d t1, ft0
  FP_CHECK_T1 512, fail_class_fs_result
  csrr t1, mstatus
  li t2, 0x6000
  and t1, t1, t2
  FP_CHECK_T1 0x4000, fail_class_fs_state
  feq.d t1, ft0, ft1
  bnez t1, fail_eq_fs_result
  FP_CHECK_FFLAGS 0, fail_clean_fs_flags
  csrr t1, mstatus
  li t2, 0x6000
  and t1, t1, t2
  FP_CHECK_T1 0x4000, fail_clean_fs_state
  flt.d t1, ft0, ft1
  bnez t1, fail_invalid_result
  FP_CHECK_FFLAGS 0x10, fail_invalid_flags
  csrr t1, mstatus
  li t2, 0x6000
  and t1, t1, t2
  FP_CHECK_T1 0x6000, fail_dirty_fs_state

  li t0, 0x00100000
  li t1, 0x5555
  sw t1, 0(t0)

  FP_FAIL fail_s_flt, 0x00013333
  FP_FAIL fail_s_fle, 0x00023333
  FP_FAIL fail_s_feq, 0x00033333
  FP_FAIL fail_s_zero_eq, 0x00043333
  FP_FAIL fail_s_zero_lt, 0x00053333
  FP_FAIL fail_s_zero_le, 0x00063333
  FP_FAIL fail_s_qnan_eq, 0x00073333
  FP_FAIL fail_s_qnan_eq_flags, 0x00083333
  FP_FAIL fail_s_qnan_lt, 0x00093333
  FP_FAIL fail_s_qnan_lt_flags, 0x000a3333
  FP_FAIL fail_s_snan_eq, 0x000b3333
  FP_FAIL fail_s_snan_eq_flags, 0x000c3333
  FP_FAIL fail_s_class_neginf, 0x000d3333
  FP_FAIL fail_s_class_negnorm, 0x000e3333
  FP_FAIL fail_s_class_negsubnorm, 0x000f3333
  FP_FAIL fail_s_class_negzero, 0x00103333
  FP_FAIL fail_s_class_poszero, 0x00113333
  FP_FAIL fail_s_class_possubnorm, 0x00123333
  FP_FAIL fail_s_class_posnorm, 0x00133333
  FP_FAIL fail_s_class_posinf, 0x00143333
  FP_FAIL fail_s_class_snan, 0x00153333
  FP_FAIL fail_s_class_qnan, 0x00163333
  FP_FAIL fail_s_class_unboxed, 0x00303333
  FP_FAIL fail_s_class_unboxed_flags, 0x00313333
  FP_FAIL fail_d_flt, 0x00173333
  FP_FAIL fail_d_fle, 0x00183333
  FP_FAIL fail_d_feq, 0x00193333
  FP_FAIL fail_d_zero_eq, 0x001a3333
  FP_FAIL fail_d_zero_lt, 0x001b3333
  FP_FAIL fail_d_zero_le, 0x001c3333
  FP_FAIL fail_d_qnan_eq, 0x001d3333
  FP_FAIL fail_d_qnan_eq_flags, 0x001e3333
  FP_FAIL fail_d_qnan_le, 0x001f3333
  FP_FAIL fail_d_qnan_le_flags, 0x00203333
  FP_FAIL fail_d_snan_eq, 0x00213333
  FP_FAIL fail_d_snan_eq_flags, 0x00223333
  FP_FAIL fail_d_class_neginf, 0x00233333
  FP_FAIL fail_d_class_negnorm, 0x002b3333
  FP_FAIL fail_d_class_negsubnorm, 0x00243333
  FP_FAIL fail_d_class_negzero, 0x002c3333
  FP_FAIL fail_d_class_poszero, 0x00253333
  FP_FAIL fail_d_class_possubnorm, 0x00263333
  FP_FAIL fail_d_class_posnorm, 0x00273333
  FP_FAIL fail_d_class_posinf, 0x00283333
  FP_FAIL fail_d_class_snan, 0x00293333
  FP_FAIL fail_d_class_qnan, 0x002a3333
  FP_FAIL fail_class_fs_result, 0x002d3333
  FP_FAIL fail_class_fs_state, 0x00343333
  FP_FAIL fail_eq_fs_result, 0x002e3333
  FP_FAIL fail_clean_fs_flags, 0x002f3333
  FP_FAIL fail_clean_fs_state, 0x00303333
  FP_FAIL fail_invalid_result, 0x00313333
  FP_FAIL fail_invalid_flags, 0x00323333
  FP_FAIL fail_dirty_fs_state, 0x00333333

.section .data
.align 3
d_neg_two:
  .dword 0xc000000000000000
d_pos_three:
  .dword 0x4008000000000000
d_pos_zero:
  .dword 0x0000000000000000
d_neg_zero:
  .dword 0x8000000000000000
d_qnan:
  .dword 0x7ff8000000000001
d_snan:
  .dword 0x7ff0000000000001
d_one:
  .dword 0x3ff0000000000000
d_neginf:
  .dword 0xfff0000000000000
d_negsubnorm:
  .dword 0x8000000000000001
d_poszero:
  .dword 0x0000000000000000
d_possubnorm:
  .dword 0x0000000000000001
d_posnorm:
  .dword 0x3ff0000000000000
d_posinf:
  .dword 0x7ff0000000000000
