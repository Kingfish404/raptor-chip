.section .text
.globl _start
_start:
  li t0, 0x6000
  csrs mstatus, t0

  li t0, 0x40000000
  fmv.w.x ft0, t0
  li t0, 0x40400000
  fmv.w.x ft1, t0
  li t0, 0x40800000
  fmv.w.x ft2, t0

  csrw fflags, zero
  fmadd.s ft3, ft0, ft1, ft2, rne
  fmv.x.w t1, ft3
  li t2, 0x41200000
  bne t1, t2, fail_fmadd_s
  csrr t1, fflags
  bnez t1, fail_fmadd_s_flags

  fmsub.s ft3, ft0, ft1, ft2, rne
  fmv.x.w t1, ft3
  li t2, 0x40000000
  bne t1, t2, fail_fmsub_s
  csrr t1, fflags
  bnez t1, fail_fmsub_s_flags

  fnmsub.s ft3, ft0, ft1, ft2, rne
  fmv.x.w t1, ft3
  li t2, 0xc0000000
#if __riscv_xlen == 64
  sext.w t2, t2
#endif
  bne t1, t2, fail_fnmsub_s
  csrr t1, fflags
  bnez t1, fail_fnmsub_s_flags

  fnmadd.s ft3, ft0, ft1, ft2, rne
  fmv.x.w t1, ft3
  li t2, 0xc1200000
#if __riscv_xlen == 64
  sext.w t2, t2
#endif
  bne t1, t2, fail_fnmadd_s
  csrr t1, fflags
  bnez t1, fail_fnmadd_s_flags

  la t0, d_two
  fld ft0, 0(t0)
  la t0, d_three
  fld ft1, 0(t0)
  la t0, d_four
  fld ft2, 0(t0)

  csrw fflags, zero
  fmadd.d ft3, ft0, ft1, ft2, rne
  fcvt.w.d t1, ft3, rne
  li t2, 10
  bne t1, t2, fail_fmadd_d
  csrr t1, fflags
  bnez t1, fail_fmadd_d_flags

  fmsub.d ft3, ft0, ft1, ft2, rne
  fcvt.w.d t1, ft3, rne
  li t2, 2
  bne t1, t2, fail_fmsub_d
  csrr t1, fflags
  bnez t1, fail_fmsub_d_flags

  fnmsub.d ft3, ft0, ft1, ft2, rne
  fcvt.w.d t1, ft3, rne
  li t2, -2
  bne t1, t2, fail_fnmsub_d
  csrr t1, fflags
  bnez t1, fail_fnmsub_d_flags

  fnmadd.d ft3, ft0, ft1, ft2, rne
  fcvt.w.d t1, ft3, rne
  li t2, -10
  bne t1, t2, fail_fnmadd_d
  csrr t1, fflags
  bnez t1, fail_fnmadd_d_flags

  li t0, 0x3f800001
  fmv.w.x ft0, t0
  fmv.w.x ft1, t0
  li t0, 0xbf800002
  fmv.w.x ft2, t0
  csrw fflags, zero
  fmadd.s ft3, ft0, ft1, ft2, rne
  fmv.x.w t1, ft3
  li t2, 0x28800000
  bne t1, t2, fail_fused_s
  csrr t1, fflags
  bnez t1, fail_fused_s_flags

  la t0, d_one_plus_ulp
  fld ft0, 0(t0)
  fld ft1, 0(t0)
  la t0, d_neg_one_plus_two_ulp
  fld ft2, 0(t0)
  csrw fflags, zero
  fmadd.d ft3, ft0, ft1, ft2, rne
  la t0, d_result
  fsd ft3, 0(t0)
  lw t1, 0(t0)
  bnez t1, fail_fused_d
  lw t1, 4(t0)
  li t2, 0x39700000
  bne t1, t2, fail_fused_d
  csrr t1, fflags
  bnez t1, fail_fused_d_flags

  li t0, 0
  csrw frm, t0
  li t0, 0x40000000
  fmv.w.x ft0, t0
  li t0, 0x40400000
  fmv.w.x ft1, t0
  li t0, 0x40800000
  fmv.w.x ft2, t0
  csrw fflags, zero
  fmadd.s ft3, ft0, ft1, ft2, dyn
  fmv.x.w t1, ft3
  li t2, 0x41200000
  bne t1, t2, fail_fmadd_s_dyn
  csrr t1, fflags
  bnez t1, fail_fmadd_s_dyn_flags

  li t0, 0x7f800000
  fmv.w.x ft0, t0
  fmv.w.x ft1, zero
  li t0, 0x3f800000
  fmv.w.x ft2, t0
  csrw fflags, zero
  fmadd.s ft3, ft0, ft1, ft2, rne
  fclass.s t1, ft3
  li t2, 512
  bne t1, t2, fail_fmadd_s_invalid
  csrr t1, fflags
  li t2, 0x10
  bne t1, t2, fail_fmadd_s_invalid_flags

  li t0, 0x7fc00001
  fmv.w.x ft0, t0
  li t0, 0x3f800000
  fmv.w.x ft1, t0
  fmv.w.x ft2, t0
  csrw fflags, zero
  fmadd.s ft3, ft0, ft1, ft2, rne
  fclass.s t1, ft3
  li t2, 512
  bne t1, t2, fail_fmadd_s_qnan
  csrr t1, fflags
  bnez t1, fail_fmadd_s_qnan_flags

  li t0, 0x7f800001
  fmv.w.x ft0, t0
  csrw fflags, zero
  fmadd.s ft3, ft0, ft1, ft2, rne
  fclass.s t1, ft3
  li t2, 512
  bne t1, t2, fail_fmadd_s_snan
  csrr t1, fflags
  li t2, 16
  bne t1, t2, fail_fmadd_s_snan_flags

  la t0, d_pos_inf
  fld ft0, 0(t0)
  la t0, d_zero
  fld ft1, 0(t0)
  la t0, d_one
  fld ft2, 0(t0)
  csrw fflags, zero
  fmadd.d ft3, ft0, ft1, ft2, rne
  fclass.d t1, ft3
  li t2, 512
  bne t1, t2, fail_fmadd_d_invalid
  csrr t1, fflags
  li t2, 0x10
  bne t1, t2, fail_fmadd_d_invalid_flags

#if __riscv_xlen == 64
  la t0, d_qnan
  fld ft0, 0(t0)
  la t0, d_one
  fld ft1, 0(t0)
  fld ft2, 0(t0)
  csrw fflags, zero
  fmadd.d ft3, ft0, ft1, ft2, rne
  fclass.d t1, ft3
  li t2, 512
  bne t1, t2, fail_fmadd_d_qnan
  csrr t1, fflags
  bnez t1, fail_fmadd_d_qnan_flags

  la t0, d_snan
  fld ft0, 0(t0)
  csrw fflags, zero
  fmadd.d ft3, ft0, ft1, ft2, rne
  fclass.d t1, ft3
  li t2, 512
  bne t1, t2, fail_fmadd_d_snan
  csrr t1, fflags
  li t2, 16
  bne t1, t2, fail_fmadd_d_snan_flags
#endif

  li t0, 0x40000000
  fmv.w.x ft0, t0
  li t0, 0x40400000
  fmv.w.x ft1, t0
  li t0, 0x40800000
  fmv.w.x ft2, t0
  csrw fflags, zero
  li t0, 0x4000
  csrw mstatus, t0
  fmadd.s ft3, ft0, ft1, ft2, rne
  csrr t1, fflags
  bnez t1, fail_fmadd_fs_flags
  csrr t1, mstatus
  li t2, 0x6000
  and t1, t1, t2
  bne t1, t2, fail_fmadd_fs_dirty

  li t0, 0x00100000
  li t1, 0x5555
  sw t1, 0(t0)

fail_fmadd_s:
  li t0, 0x00100000
  li t1, 0x00013333
  sw t1, 0(t0)
fail_fmadd_s_flags:
  li t0, 0x00100000
  li t1, 0x00023333
  sw t1, 0(t0)
fail_fmsub_s:
  li t0, 0x00100000
  li t1, 0x00033333
  sw t1, 0(t0)
fail_fmsub_s_flags:
  li t0, 0x00100000
  li t1, 0x00043333
  sw t1, 0(t0)
fail_fnmsub_s:
  li t0, 0x00100000
  li t1, 0x00053333
  sw t1, 0(t0)
fail_fnmsub_s_flags:
  li t0, 0x00100000
  li t1, 0x00063333
  sw t1, 0(t0)
fail_fnmadd_s:
  li t0, 0x00100000
  li t1, 0x00073333
  sw t1, 0(t0)
fail_fnmadd_s_flags:
  li t0, 0x00100000
  li t1, 0x00083333
  sw t1, 0(t0)
fail_fmadd_d:
  li t0, 0x00100000
  li t1, 0x00093333
  sw t1, 0(t0)
fail_fmadd_d_flags:
  li t0, 0x00100000
  li t1, 0x000a3333
  sw t1, 0(t0)
fail_fmsub_d:
  li t0, 0x00100000
  li t1, 0x000b3333
  sw t1, 0(t0)
fail_fmsub_d_flags:
  li t0, 0x00100000
  li t1, 0x000c3333
  sw t1, 0(t0)
fail_fnmsub_d:
  li t0, 0x00100000
  li t1, 0x000d3333
  sw t1, 0(t0)
fail_fnmsub_d_flags:
  li t0, 0x00100000
  li t1, 0x000e3333
  sw t1, 0(t0)
fail_fnmadd_d:
  li t0, 0x00100000
  li t1, 0x000f3333
  sw t1, 0(t0)
fail_fnmadd_d_flags:
  li t0, 0x00100000
  li t1, 0x00103333
  sw t1, 0(t0)
fail_fused_s:
  li t0, 0x00100000
  li t1, 0x00113333
  sw t1, 0(t0)
fail_fused_s_flags:
  li t0, 0x00100000
  li t1, 0x00123333
  sw t1, 0(t0)
fail_fused_d:
  li t0, 0x00100000
  li t1, 0x00133333
  sw t1, 0(t0)
fail_fused_d_flags:
  li t0, 0x00100000
  li t1, 0x00143333
  sw t1, 0(t0)
fail_fmadd_s_dyn:
  li t0, 0x00100000
  li t1, 0x00153333
  sw t1, 0(t0)
fail_fmadd_s_dyn_flags:
  li t0, 0x00100000
  li t1, 0x00163333
  sw t1, 0(t0)
fail_fmadd_s_invalid:
  li t0, 0x00100000
  li t1, 0x00173333
  sw t1, 0(t0)
fail_fmadd_s_invalid_flags:
  li t0, 0x00100000
  li t1, 0x00183333
  sw t1, 0(t0)
fail_fmadd_d_invalid:
  li t0, 0x00100000
  li t1, 0x00193333
  sw t1, 0(t0)
fail_fmadd_d_invalid_flags:
  li t0, 0x00100000
  li t1, 0x001a3333
  sw t1, 0(t0)
fail_fmadd_d_qnan:
  li t0, 0x00100000
  li t1, 0x003e3333
  sw t1, 0(t0)
fail_fmadd_d_qnan_flags:
  li t0, 0x00100000
  li t1, 0x003f3333
  sw t1, 0(t0)
fail_fmadd_d_snan:
  li t0, 0x00100000
  li t1, 0x00403333
  sw t1, 0(t0)
fail_fmadd_d_snan_flags:
  li t0, 0x00100000
  li t1, 0x00413333
  sw t1, 0(t0)
fail_fmadd_s_qnan:
  li t0, 0x00100000
  li t1, 0x00363333
  sw t1, 0(t0)
fail_fmadd_s_qnan_flags:
  li t0, 0x00100000
  li t1, 0x00373333
  sw t1, 0(t0)
fail_fmadd_s_snan:
  li t0, 0x00100000
  li t1, 0x00383333
  sw t1, 0(t0)
fail_fmadd_s_snan_flags:
  li t0, 0x00100000
  li t1, 0x00393333
  sw t1, 0(t0)
fail_fmadd_fs_flags:
  li t0, 0x00100000
  li t1, 0x001b3333
  sw t1, 0(t0)
fail_fmadd_fs_dirty:
  li t0, 0x00100000
  li t1, 0x001c3333
  sw t1, 0(t0)

.section .data
.align 3
d_two:
  .dword 0x4000000000000000
d_three:
  .dword 0x4008000000000000
d_four:
  .dword 0x4010000000000000
d_one_plus_ulp:
  .dword 0x3ff0000000000001
d_neg_one_plus_two_ulp:
  .dword 0xbff0000000000002
d_pos_inf:
  .dword 0x7ff0000000000000
d_qnan:
  .dword 0x7ff8000000000001
d_snan:
  .dword 0x7ff0000000000001
d_zero:
  .dword 0x0000000000000000
d_one:
  .dword 0x3ff0000000000000
d_result:
  .dword 0