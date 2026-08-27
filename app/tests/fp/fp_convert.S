.section .text
.globl _start
_start:
  li t0, 0x6000
  csrs mstatus, t0

  li t0, 0x3fc00000
  fmv.w.x ft0, t0
  csrw fflags, zero
  fcvt.w.s t1, ft0, rne
  li t2, 2
  bne t1, t2, fail_s_f2i_rne
  csrr t1, fflags
  li t2, 1
  bne t1, t2, fail_s_f2i_rne_flags

  csrw fflags, zero
  fcvt.w.s t1, ft0, rtz
  li t2, 1
  bne t1, t2, fail_s_f2i_rtz
  csrr t1, fflags
  li t2, 1
  bne t1, t2, fail_s_f2i_rtz_flags

  li t0, 3
  csrw frm, t0
  csrw fflags, zero
  fcvt.w.s t1, ft0, dyn
  li t2, 2
  bne t1, t2, fail_s_f2i_dyn
  csrr t1, fflags
  li t2, 1
  bne t1, t2, fail_s_f2i_dyn_flags
  csrw frm, zero

  csrw fflags, zero
  li t0, 0x7fc00001
  fmv.w.x ft0, t0
  fcvt.w.s t1, ft0, rne
  li t2, 2147483647
  bne t1, t2, fail_s_f2i_nan
  csrr t1, fflags
  li t2, 0x10
  bne t1, t2, fail_s_f2i_nan_flags

  li t0, 0xbf800000
  fmv.w.x ft0, t0
  csrw fflags, zero
  fcvt.wu.s t1, ft0, rne
  li t2, 0
  bne t1, t2, fail_s_f2i_unsigned
  csrr t1, fflags
  li t2, 0x10
  bne t1, t2, fail_s_f2i_unsigned_flags

  li t0, 0x01000001
  csrw fflags, zero
  fcvt.s.w ft0, t0, rne
  fmv.x.w t1, ft0
  li t2, 0x4b800000
  bne t1, t2, fail_s_i2f_signed
  csrr t1, fflags
  li t2, 1
  bne t1, t2, fail_s_i2f_signed_flags

  li t0, -1
  csrw fflags, zero
  fcvt.s.wu ft0, t0, rne
  fmv.x.w t1, ft0
  li t2, 0x4f800000
  bne t1, t2, fail_s_i2f_unsigned
  csrr t1, fflags
  li t2, 1
  bne t1, t2, fail_s_i2f_unsigned_flags

  la t0, d_two_three_quarters
  fld ft0, 0(t0)
  csrw fflags, zero
  fcvt.w.d t1, ft0, rne
  li t2, 3
  bne t1, t2, fail_d_f2i_rne
  csrr t1, fflags
  li t2, 1
  bne t1, t2, fail_d_f2i_rne_flags

  li t0, -1
  fcvt.d.w ft0, t0
  csrw fflags, zero
  fcvt.wu.d t1, ft0, rne
  li t2, 0
  bne t1, t2, fail_d_f2i_unsigned
  csrr t1, fflags
  li t2, 0x10
  bne t1, t2, fail_d_f2i_unsigned_flags

  li t0, -42
  csrw fflags, zero
  fcvt.d.w ft0, t0
  fcvt.w.d t1, ft0, rne
  bne t1, t0, fail_d_i2f_signed
  csrr t1, fflags
  bnez t1, fail_d_i2f_signed_flags

  li t0, -1
  csrw fflags, zero
  fcvt.d.wu ft0, t0
  fcvt.wu.d t1, ft0, rne
  bne t1, t0, fail_d_i2f_unsigned
  csrr t1, fflags
  bnez t1, fail_d_i2f_unsigned_flags

  li t0, 0x01000001
  fcvt.d.w ft0, t0
  csrw fflags, zero
  fcvt.s.d ft1, ft0, rne
  fmv.x.w t1, ft1
  li t2, 0x4b800000
  bne t1, t2, fail_f2f_narrow
  csrr t1, fflags
  li t2, 1
  bne t1, t2, fail_f2f_narrow_flags

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
  li t2, 512
  bne t1, t2, fail_f2f_narrow_qnan
  csrr t1, fflags
  bnez t1, fail_f2f_narrow_qnan_flags

  li t0, 0x7ff0000000000001
  fmv.d.x ft0, t0
  csrw fflags, zero
  fcvt.s.d ft1, ft0, rne
  fclass.s t1, ft1
  li t2, 512
  bne t1, t2, fail_f2f_narrow_snan
  csrr t1, fflags
  li t2, 16
  bne t1, t2, fail_f2f_narrow_snan_flags

  la t0, d_pos_inf
  fld ft0, 0(t0)
  csrw fflags, zero
  fcvt.s.d ft1, ft0, rne
  fclass.s t1, ft1
  li t2, 128
  bne t1, t2, fail_f2f_narrow_inf
  csrr t1, fflags
  bnez t1, fail_f2f_narrow_inf_flags
#endif

  li t0, 0x01000001
  fcvt.d.w ft0, t0
  fcvt.s.d ft1, ft0, rne
  csrw fflags, zero
  fcvt.d.s ft2, ft1
  csrr t1, fflags
  bnez t1, fail_f2f_widen_early_flags
  fcvt.w.d t1, ft2, rne
  li t2, 0x01000000
  bne t1, t2, fail_f2f_widen
  csrr t1, fflags
  bnez t1, fail_f2f_widen_flags

  li t0, 0x7fc00001
  fmv.w.x ft0, t0
  csrw fflags, zero
  fcvt.d.s ft1, ft0
  fclass.d t1, ft1
  li t2, 512
  bne t1, t2, fail_f2f_widen_qnan
  csrr t1, fflags
  bnez t1, fail_f2f_widen_qnan_flags

  li t0, 0x7f800001
  fmv.w.x ft0, t0
  csrw fflags, zero
  fcvt.d.s ft1, ft0
  fclass.d t1, ft1
  li t2, 512
  bne t1, t2, fail_f2f_widen_snan
  csrr t1, fflags
  li t2, 16
  bne t1, t2, fail_f2f_widen_snan_flags

#if __riscv_xlen == 64
  li t0, -42
  csrw fflags, zero
  fcvt.s.l ft0, t0, rne
  fcvt.l.s t1, ft0, rne
  bne t1, t0, fail_s_l_roundtrip
  csrr t1, fflags
  bnez t1, fail_s_l_roundtrip_flags

  li t0, 0x100000001
  csrw fflags, zero
  fcvt.s.lu ft0, t0, rne
  fcvt.lu.s t1, ft0, rne
  li t2, 0x100000000
  bne t1, t2, fail_s_lu_roundtrip
  csrr t1, fflags
  li t2, 1
  bne t1, t2, fail_s_lu_roundtrip_flags

  li t0, -1234567890123
  csrw fflags, zero
  fcvt.d.l ft0, t0, rne
  fcvt.l.d t1, ft0, rne
  bne t1, t0, fail_d_l_roundtrip
  csrr t1, fflags
  bnez t1, fail_d_l_roundtrip_flags

  li t0, 0x100000001
  csrw fflags, zero
  fcvt.d.lu ft0, t0, rne
  fcvt.lu.d t1, ft0, rne
  bne t1, t0, fail_d_lu_roundtrip
  csrr t1, fflags
  bnez t1, fail_d_lu_roundtrip_flags
#endif

  li t0, 0x3f800000
  fmv.w.x ft0, t0
  csrw fflags, zero
  li t0, 0x4000
  csrw mstatus, t0
  fcvt.w.s t1, ft0, rne
  li t2, 1
  bne t1, t2, fail_f2i_clean_result
  csrr t1, fflags
  bnez t1, fail_f2i_clean_flags
  csrr t1, mstatus
  li t2, 0x6000
  and t1, t1, t2
  li t2, 0x4000
  bne t1, t2, fail_f2i_clean_fs

  li t0, 0x7fc00001
  fmv.w.x ft0, t0
  csrw fflags, zero
  li t0, 0x4000
  csrw mstatus, t0
  fcvt.w.s t1, ft0, rne
  li t2, 2147483647
  bne t1, t2, fail_f2i_dirty_result
  csrr t1, fflags
  li t2, 0x10
  bne t1, t2, fail_f2i_dirty_flags
  csrr t1, mstatus
  li t2, 0x6000
  and t1, t1, t2
  bne t1, t2, fail_f2i_dirty_fs

  li t0, 0x00100000
  li t1, 0x5555
  sw t1, 0(t0)

fail_s_f2i_rne:
  li t0, 0x00100000
  li t1, 0x00013333
  sw t1, 0(t0)
fail_s_f2i_rne_flags:
  li t0, 0x00100000
  li t1, 0x00023333
  sw t1, 0(t0)
fail_s_f2i_rtz:
  li t0, 0x00100000
  li t1, 0x00033333
  sw t1, 0(t0)
fail_s_f2i_rtz_flags:
  li t0, 0x00100000
  li t1, 0x00043333
  sw t1, 0(t0)
fail_s_f2i_dyn:
  li t0, 0x00100000
  li t1, 0x00053333
  sw t1, 0(t0)
fail_s_f2i_dyn_flags:
  li t0, 0x00100000
  li t1, 0x00063333
  sw t1, 0(t0)
fail_s_f2i_nan:
  li t0, 0x00100000
  li t1, 0x00073333
  sw t1, 0(t0)
fail_s_f2i_nan_flags:
  li t0, 0x00100000
  li t1, 0x00083333
  sw t1, 0(t0)
fail_s_i2f_signed:
  li t0, 0x00100000
  li t1, 0x00093333
  sw t1, 0(t0)
fail_s_i2f_signed_flags:
  li t0, 0x00100000
  li t1, 0x000a3333
  sw t1, 0(t0)
fail_s_i2f_unsigned:
  li t0, 0x00100000
  li t1, 0x000b3333
  sw t1, 0(t0)
fail_s_i2f_unsigned_flags:
  li t0, 0x00100000
  li t1, 0x000c3333
  sw t1, 0(t0)
fail_d_f2i_rne:
  li t0, 0x00100000
  li t1, 0x000d3333
  sw t1, 0(t0)
fail_d_f2i_rne_flags:
  li t0, 0x00100000
  li t1, 0x000e3333
  sw t1, 0(t0)
fail_d_i2f_signed:
  li t0, 0x00100000
  li t1, 0x000f3333
  sw t1, 0(t0)
fail_d_i2f_signed_flags:
  li t0, 0x00100000
  li t1, 0x00103333
  sw t1, 0(t0)
fail_d_i2f_unsigned:
  li t0, 0x00100000
  li t1, 0x00113333
  sw t1, 0(t0)
fail_d_i2f_unsigned_flags:
  li t0, 0x00100000
  li t1, 0x00123333
  sw t1, 0(t0)
fail_f2f_narrow:
  li t0, 0x00100000
  li t1, 0x00133333
  sw t1, 0(t0)
fail_f2f_narrow_flags:
  li t0, 0x00100000
  li t1, 0x00143333
  sw t1, 0(t0)
fail_f2f_narrow_qnan:
  li t0, 0x00100000
  li t1, 0x00363333
  sw t1, 0(t0)
fail_f2f_narrow_qnan_flags:
  li t0, 0x00100000
  li t1, 0x00373333
  sw t1, 0(t0)
fail_f2f_narrow_snan:
  li t0, 0x00100000
  li t1, 0x00383333
  sw t1, 0(t0)
fail_f2f_narrow_snan_flags:
  li t0, 0x00100000
  li t1, 0x00393333
  sw t1, 0(t0)
fail_f2f_narrow_inf:
  li t0, 0x00100000
  li t1, 0x003a3333
  sw t1, 0(t0)
fail_f2f_narrow_inf_flags:
  li t0, 0x00100000
  li t1, 0x003b3333
  sw t1, 0(t0)
fail_f2f_widen:
  li t0, 0x00100000
  li t1, 0x00153333
  sw t1, 0(t0)
fail_f2f_widen_flags:
  li t0, 0x00100000
  li t1, 0x00163333
  sw t1, 0(t0)
fail_f2f_widen_early_flags:
  li t0, 0x00100000
  li t1, 0x003c3333
  sw t1, 0(t0)
fail_f2f_widen_qnan:
  li t0, 0x00100000
  li t1, 0x00323333
  sw t1, 0(t0)
fail_f2f_widen_qnan_flags:
  li t0, 0x00100000
  li t1, 0x00333333
  sw t1, 0(t0)
fail_f2f_widen_snan:
  li t0, 0x00100000
  li t1, 0x00343333
  sw t1, 0(t0)
fail_f2f_widen_snan_flags:
  li t0, 0x00100000
  li t1, 0x00353333
  sw t1, 0(t0)
fail_s_lu_roundtrip:
  li t0, 0x00100000
  li t1, 0x00173333
  sw t1, 0(t0)
fail_s_lu_roundtrip_flags:
  li t0, 0x00100000
  li t1, 0x00183333
  sw t1, 0(t0)
fail_d_l_roundtrip:
  li t0, 0x00100000
  li t1, 0x00193333
  sw t1, 0(t0)
fail_d_l_roundtrip_flags:
  li t0, 0x00100000
  li t1, 0x001a3333
  sw t1, 0(t0)
fail_d_lu_roundtrip:
  li t0, 0x00100000
  li t1, 0x001b3333
  sw t1, 0(t0)
fail_d_lu_roundtrip_flags:
  li t0, 0x00100000
  li t1, 0x001c3333
  sw t1, 0(t0)
fail_f2i_clean_result:
  li t0, 0x00100000
  li t1, 0x001d3333
  sw t1, 0(t0)
fail_f2i_clean_flags:
  li t0, 0x00100000
  li t1, 0x001e3333
  sw t1, 0(t0)
fail_f2i_clean_fs:
  li t0, 0x00100000
  li t1, 0x001f3333
  sw t1, 0(t0)
fail_s_f2i_unsigned:
  li t0, 0x00100000
  li t1, 0x00203333
  sw t1, 0(t0)
fail_s_f2i_unsigned_flags:
  li t0, 0x00100000
  li t1, 0x00213333
  sw t1, 0(t0)
fail_d_f2i_unsigned:
  li t0, 0x00100000
  li t1, 0x00223333
  sw t1, 0(t0)
fail_d_f2i_unsigned_flags:
  li t0, 0x00100000
  li t1, 0x00233333
  sw t1, 0(t0)
fail_s_l_roundtrip:
  li t0, 0x00100000
  li t1, 0x00243333
  sw t1, 0(t0)
fail_s_l_roundtrip_flags:
  li t0, 0x00100000
  li t1, 0x00253333
  sw t1, 0(t0)
fail_f2i_dirty_result:
  li t0, 0x00100000
  li t1, 0x00263333
  sw t1, 0(t0)
fail_f2i_dirty_flags:
  li t0, 0x00100000
  li t1, 0x00273333
  sw t1, 0(t0)
fail_f2i_dirty_fs:
  li t0, 0x00100000
  li t1, 0x00283333
  sw t1, 0(t0)

.section .data
.align 3
d_two_three_quarters:
  .dword 0x4006000000000000

.align 3
d_pos_inf:
  .dword 0x7ff0000000000000