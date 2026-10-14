#include "fp_test_macros.h"

.section .text
.globl _start
_start:
  li t0, 0x6000
  csrs mstatus, t0

  li t0, 0x3fc00000
  fmv.w.x ft0, t0
  csrw fflags, zero
  fcvt.w.s t1, ft0, rne
  FP_CHECK_T1 2, fail_s_f2i_rne
  FP_CHECK_FFLAGS 1, fail_s_f2i_rne_flags

  csrw fflags, zero
  fcvt.w.s t1, ft0, rtz
  FP_CHECK_T1 1, fail_s_f2i_rtz
  FP_CHECK_FFLAGS 1, fail_s_f2i_rtz_flags

  li t0, 3
  csrw frm, t0
  csrw fflags, zero
  fcvt.w.s t1, ft0, dyn
  FP_CHECK_T1 2, fail_s_f2i_dyn
  FP_CHECK_FFLAGS 1, fail_s_f2i_dyn_flags
  csrw frm, zero

  csrw fflags, zero
  li t0, 0x7fc00001
  fmv.w.x ft0, t0
  fcvt.w.s t1, ft0, rne
  FP_CHECK_T1 2147483647, fail_s_f2i_nan
  FP_CHECK_FFLAGS 0x10, fail_s_f2i_nan_flags

  li t0, 0xbf800000
  fmv.w.x ft0, t0
  csrw fflags, zero
  fcvt.wu.s t1, ft0, rne
  FP_CHECK_T1 0, fail_s_f2i_unsigned
  FP_CHECK_FFLAGS 0x10, fail_s_f2i_unsigned_flags

  li t0, 0x01000001
  csrw fflags, zero
  fcvt.s.w ft0, t0, rne
  fmv.x.w t1, ft0
  FP_CHECK_T1 0x4b800000, fail_s_i2f_signed
  FP_CHECK_FFLAGS 1, fail_s_i2f_signed_flags

  li t0, -1
  csrw fflags, zero
  fcvt.s.wu ft0, t0, rne
  fmv.x.w t1, ft0
  FP_CHECK_T1 0x4f800000, fail_s_i2f_unsigned
  FP_CHECK_FFLAGS 1, fail_s_i2f_unsigned_flags

  la t0, d_two_three_quarters
  fld ft0, 0(t0)
  csrw fflags, zero
  fcvt.w.d t1, ft0, rne
  FP_CHECK_T1 3, fail_d_f2i_rne
  FP_CHECK_FFLAGS 1, fail_d_f2i_rne_flags

  li t0, -1
  fcvt.d.w ft0, t0
  csrw fflags, zero
  fcvt.wu.d t1, ft0, rne
  FP_CHECK_T1 0, fail_d_f2i_unsigned
  FP_CHECK_FFLAGS 0x10, fail_d_f2i_unsigned_flags

  li t0, -42
  csrw fflags, zero
  fcvt.d.w ft0, t0
  fcvt.w.d t1, ft0, rne
  bne t1, t0, fail_d_i2f_signed
  FP_CHECK_FFLAGS 0, fail_d_i2f_signed_flags

  li t0, -1
  csrw fflags, zero
  fcvt.d.wu ft0, t0
  fcvt.wu.d t1, ft0, rne
  bne t1, t0, fail_d_i2f_unsigned
  FP_CHECK_FFLAGS 0, fail_d_i2f_unsigned_flags

  li t0, 0x01000001
  fcvt.d.w ft0, t0
  csrw fflags, zero
  fcvt.s.d ft1, ft0, rne
  fmv.x.w t1, ft1
  FP_CHECK_T1 0x4b800000, fail_f2f_narrow
  FP_CHECK_FFLAGS 1, fail_f2f_narrow_flags

#if __riscv_xlen == 64
  li t0, 0x7ff8000000000001
  fmv.d.x ft0, t0
  nop
  nop
  csrw fflags, zero
  fcvt.s.d ft1, ft0, rne
  nop
  nop
  fclass.s t1, ft1
  FP_CHECK_T1 512, fail_f2f_narrow_qnan
  FP_CHECK_FFLAGS 0, fail_f2f_narrow_qnan_flags

  li t0, 0x7ff0000000000001
  fmv.d.x ft0, t0
  csrw fflags, zero
  fcvt.s.d ft1, ft0, rne
  fclass.s t1, ft1
  FP_CHECK_T1 512, fail_f2f_narrow_snan
  FP_CHECK_FFLAGS 16, fail_f2f_narrow_snan_flags

  la t0, d_pos_inf
  fld ft0, 0(t0)
  csrw fflags, zero
  fcvt.s.d ft1, ft0, rne
  fclass.s t1, ft1
  FP_CHECK_T1 128, fail_f2f_narrow_inf
  FP_CHECK_FFLAGS 0, fail_f2f_narrow_inf_flags
#endif

  li t0, 0x01000001
  fcvt.d.w ft0, t0
  fcvt.s.d ft1, ft0, rne
  csrw fflags, zero
  fcvt.d.s ft2, ft1
  FP_CHECK_FFLAGS 0, fail_f2f_widen_early_flags
  fcvt.w.d t1, ft2, rne
  FP_CHECK_T1 0x01000000, fail_f2f_widen
  FP_CHECK_FFLAGS 0, fail_f2f_widen_flags

  li t0, 0x7fc00001
  fmv.w.x ft0, t0
  csrw fflags, zero
  fcvt.d.s ft1, ft0
  fclass.d t1, ft1
  FP_CHECK_T1 512, fail_f2f_widen_qnan
  FP_CHECK_FFLAGS 0, fail_f2f_widen_qnan_flags

  li t0, 0x7f800001
  fmv.w.x ft0, t0
  csrw fflags, zero
  fcvt.d.s ft1, ft0
  fclass.d t1, ft1
  FP_CHECK_T1 512, fail_f2f_widen_snan
  FP_CHECK_FFLAGS 16, fail_f2f_widen_snan_flags

#if __riscv_xlen == 64
  li t0, -42
  csrw fflags, zero
  fcvt.s.l ft0, t0, rne
  fcvt.l.s t1, ft0, rne
  bne t1, t0, fail_s_l_roundtrip
  FP_CHECK_FFLAGS 0, fail_s_l_roundtrip_flags

  li t0, 0x100000001
  csrw fflags, zero
  fcvt.s.lu ft0, t0, rne
  fcvt.lu.s t1, ft0, rne
  FP_CHECK_T1 0x100000000, fail_s_lu_roundtrip
  FP_CHECK_FFLAGS 1, fail_s_lu_roundtrip_flags

  li t0, -1234567890123
  csrw fflags, zero
  fcvt.d.l ft0, t0, rne
  fcvt.l.d t1, ft0, rne
  bne t1, t0, fail_d_l_roundtrip
  FP_CHECK_FFLAGS 0, fail_d_l_roundtrip_flags

  li t0, 0x100000001
  csrw fflags, zero
  fcvt.d.lu ft0, t0, rne
  fcvt.lu.d t1, ft0, rne
  bne t1, t0, fail_d_lu_roundtrip
  FP_CHECK_FFLAGS 0, fail_d_lu_roundtrip_flags
#endif

  li t0, 0x3f800000
  fmv.w.x ft0, t0
  csrw fflags, zero
  li t0, 0x4000
  csrw mstatus, t0
  fcvt.w.s t1, ft0, rne
  FP_CHECK_T1 1, fail_f2i_clean_result
  FP_CHECK_FFLAGS 0, fail_f2i_clean_flags
  csrr t1, mstatus
  li t2, 0x6000
  and t1, t1, t2
  FP_CHECK_T1 0x4000, fail_f2i_clean_fs

  li t0, 0x7fc00001
  fmv.w.x ft0, t0
  csrw fflags, zero
  li t0, 0x4000
  csrw mstatus, t0
  fcvt.w.s t1, ft0, rne
  FP_CHECK_T1 2147483647, fail_f2i_dirty_result
  FP_CHECK_FFLAGS 0x10, fail_f2i_dirty_flags
  csrr t1, mstatus
  li t2, 0x6000
  and t1, t1, t2
  bne t1, t2, fail_f2i_dirty_fs

  li t0, 0x00100000
  li t1, 0x5555
  sw t1, 0(t0)

  FP_FAIL fail_s_f2i_rne, 0x00013333
  FP_FAIL fail_s_f2i_rne_flags, 0x00023333
  FP_FAIL fail_s_f2i_rtz, 0x00033333
  FP_FAIL fail_s_f2i_rtz_flags, 0x00043333
  FP_FAIL fail_s_f2i_dyn, 0x00053333
  FP_FAIL fail_s_f2i_dyn_flags, 0x00063333
  FP_FAIL fail_s_f2i_nan, 0x00073333
  FP_FAIL fail_s_f2i_nan_flags, 0x00083333
  FP_FAIL fail_s_i2f_signed, 0x00093333
  FP_FAIL fail_s_i2f_signed_flags, 0x000a3333
  FP_FAIL fail_s_i2f_unsigned, 0x000b3333
  FP_FAIL fail_s_i2f_unsigned_flags, 0x000c3333
  FP_FAIL fail_d_f2i_rne, 0x000d3333
  FP_FAIL fail_d_f2i_rne_flags, 0x000e3333
  FP_FAIL fail_d_i2f_signed, 0x000f3333
  FP_FAIL fail_d_i2f_signed_flags, 0x00103333
  FP_FAIL fail_d_i2f_unsigned, 0x00113333
  FP_FAIL fail_d_i2f_unsigned_flags, 0x00123333
  FP_FAIL fail_f2f_narrow, 0x00133333
  FP_FAIL fail_f2f_narrow_flags, 0x00143333
  FP_FAIL fail_f2f_narrow_qnan, 0x00363333
  FP_FAIL fail_f2f_narrow_qnan_flags, 0x00373333
  FP_FAIL fail_f2f_narrow_snan, 0x00383333
  FP_FAIL fail_f2f_narrow_snan_flags, 0x00393333
  FP_FAIL fail_f2f_narrow_inf, 0x003a3333
  FP_FAIL fail_f2f_narrow_inf_flags, 0x003b3333
  FP_FAIL fail_f2f_widen, 0x00153333
  FP_FAIL fail_f2f_widen_flags, 0x00163333
  FP_FAIL fail_f2f_widen_early_flags, 0x003c3333
  FP_FAIL fail_f2f_widen_qnan, 0x00323333
  FP_FAIL fail_f2f_widen_qnan_flags, 0x00333333
  FP_FAIL fail_f2f_widen_snan, 0x00343333
  FP_FAIL fail_f2f_widen_snan_flags, 0x00353333
  FP_FAIL fail_s_lu_roundtrip, 0x00173333
  FP_FAIL fail_s_lu_roundtrip_flags, 0x00183333
  FP_FAIL fail_d_l_roundtrip, 0x00193333
  FP_FAIL fail_d_l_roundtrip_flags, 0x001a3333
  FP_FAIL fail_d_lu_roundtrip, 0x001b3333
  FP_FAIL fail_d_lu_roundtrip_flags, 0x001c3333
  FP_FAIL fail_f2i_clean_result, 0x001d3333
  FP_FAIL fail_f2i_clean_flags, 0x001e3333
  FP_FAIL fail_f2i_clean_fs, 0x001f3333
  FP_FAIL fail_s_f2i_unsigned, 0x00203333
  FP_FAIL fail_s_f2i_unsigned_flags, 0x00213333
  FP_FAIL fail_d_f2i_unsigned, 0x00223333
  FP_FAIL fail_d_f2i_unsigned_flags, 0x00233333
  FP_FAIL fail_s_l_roundtrip, 0x00243333
  FP_FAIL fail_s_l_roundtrip_flags, 0x00253333
  FP_FAIL fail_f2i_dirty_result, 0x00263333
  FP_FAIL fail_f2i_dirty_flags, 0x00273333
  FP_FAIL fail_f2i_dirty_fs, 0x00283333

.section .data
.align 3
d_two_three_quarters:
  .dword 0x4006000000000000

.align 3
d_pos_inf:
  .dword 0x7ff0000000000000