.section .text
.globl _start
_start:
  li t0, 0x6000
  csrs mstatus, t0

  li t0, 0x40400000
  fmv.w.x ft0, t0
  li t0, -1073741824
  fmv.w.x ft1, t0
  fmin.s ft2, ft0, ft1
  fmv.x.w t1, ft2
  li t2, -1073741824
  bne t1, t2, fail_s_min

  fmax.s ft2, ft0, ft1
  fmv.x.w t1, ft2
  li t2, 0x40400000
  bne t1, t2, fail_s_max

  li t0, 0
  fmv.w.x ft0, t0
  li t0, -2147483648
  fmv.w.x ft1, t0
  fmin.s ft2, ft0, ft1
  fmv.x.w t1, ft2
  li t2, -2147483648
  bne t1, t2, fail_s_min_zero

  fmax.s ft2, ft0, ft1
  fmv.x.w t1, ft2
  bnez t1, fail_s_max_zero

  csrw fflags, zero
  li t0, 0x7fc00001
  fmv.w.x ft0, t0
  li t0, 0x3fc00000
  fmv.w.x ft1, t0
  fmin.s ft2, ft0, ft1
  fmv.x.w t1, ft2
  li t2, 0x3fc00000
  bne t1, t2, fail_s_qnan
  csrr t1, fflags
  bnez t1, fail_s_qnan_flags

  csrw fflags, zero
  li t0, 0x7fc00001
  fmv.w.x ft0, t0
  li t0, 0xffc00002
  fmv.w.x ft1, t0
  fmax.s ft2, ft0, ft1
  fmv.x.w t1, ft2
  li t2, 0x7fc00000
  bne t1, t2, fail_s_both_nan
  csrr t1, fflags
  bnez t1, fail_s_both_nan_flags

  csrw fflags, zero
  li t0, 0x7f800001
  fmv.w.x ft0, t0
  li t0, 0x3fc00000
  fmv.w.x ft1, t0
  fmax.s ft2, ft0, ft1
  fmv.x.w t1, ft2
  li t2, 0x3fc00000
  bne t1, t2, fail_s_snan
  csrr t1, fflags
  li t2, 0x10
  bne t1, t2, fail_s_snan_flags

  la t0, d_pos_three
  fld ft0, 0(t0)
  la t0, d_neg_two
  fld ft1, 0(t0)
  fmin.d ft2, ft0, ft1
  la t0, result_d
  fsd ft2, 0(t0)
  lw t1, 0(t0)
  bnez t1, fail_d_min
  lw t1, 4(t0)
  li t2, -1073741824
  bne t1, t2, fail_d_min

  fmax.d ft2, ft0, ft1
  fsd ft2, 0(t0)
  lw t1, 0(t0)
  bnez t1, fail_d_max
  lw t1, 4(t0)
  li t2, 0x40080000
  bne t1, t2, fail_d_max

  la t0, d_pos_zero
  fld ft0, 0(t0)
  la t0, d_neg_zero
  fld ft1, 0(t0)
  fmin.d ft2, ft0, ft1
  la t0, result_d
  fsd ft2, 0(t0)
  lw t1, 0(t0)
  bnez t1, fail_d_min_zero
  lw t1, 4(t0)
  li t2, -2147483648
  bne t1, t2, fail_d_min_zero

  fmax.d ft2, ft0, ft1
  fsd ft2, 0(t0)
  lw t1, 0(t0)
  bnez t1, fail_d_max_zero
  lw t1, 4(t0)
  bnez t1, fail_d_max_zero

  csrw fflags, zero
  la t0, d_qnan_a
  fld ft0, 0(t0)
  la t0, d_one_half
  fld ft1, 0(t0)
  fmin.d ft2, ft0, ft1
  la t0, result_d
  fsd ft2, 0(t0)
  lw t1, 0(t0)
  bnez t1, fail_d_qnan
  lw t1, 4(t0)
  li t2, 0x3ff80000
  bne t1, t2, fail_d_qnan
  csrr t1, fflags
  bnez t1, fail_d_qnan_flags

  csrw fflags, zero
  la t0, d_qnan_a
  fld ft0, 0(t0)
  la t0, d_qnan_b
  fld ft1, 0(t0)
  fmax.d ft2, ft0, ft1
  la t0, result_d
  fsd ft2, 0(t0)
  lw t1, 0(t0)
  bnez t1, fail_d_both_nan
  lw t1, 4(t0)
  li t2, 0x7ff80000
  bne t1, t2, fail_d_both_nan
  csrr t1, fflags
  bnez t1, fail_d_both_nan_flags

  csrw fflags, zero
  la t0, d_snan
  fld ft0, 0(t0)
  la t0, d_one_half
  fld ft1, 0(t0)
  fmax.d ft2, ft0, ft1
  la t0, result_d
  fsd ft2, 0(t0)
  lw t1, 0(t0)
  bnez t1, fail_d_snan
  lw t1, 4(t0)
  li t2, 0x3ff80000
  bne t1, t2, fail_d_snan
  csrr t1, fflags
  li t2, 0x10
  bne t1, t2, fail_d_snan_flags

  li t0, 0x00100000
  li t1, 0x5555
  sw t1, 0(t0)

fail_s_min:
  li t0, 0x00100000
  li t1, 0x00013333
  sw t1, 0(t0)

fail_s_max:
  li t0, 0x00100000
  li t1, 0x00023333
  sw t1, 0(t0)

fail_s_min_zero:
  li t0, 0x00100000
  li t1, 0x00033333
  sw t1, 0(t0)

fail_s_max_zero:
  li t0, 0x00100000
  li t1, 0x00043333
  sw t1, 0(t0)

fail_s_qnan:
  li t0, 0x00100000
  li t1, 0x00053333
  sw t1, 0(t0)

fail_s_qnan_flags:
  li t0, 0x00100000
  li t1, 0x00063333
  sw t1, 0(t0)

fail_s_both_nan:
  li t0, 0x00100000
  li t1, 0x00073333
  sw t1, 0(t0)

fail_s_both_nan_flags:
  li t0, 0x00100000
  li t1, 0x00083333
  sw t1, 0(t0)

fail_s_snan:
  li t0, 0x00100000
  li t1, 0x00093333
  sw t1, 0(t0)

fail_s_snan_flags:
  li t0, 0x00100000
  li t1, 0x000a3333
  sw t1, 0(t0)

fail_d_min:
  li t0, 0x00100000
  li t1, 0x000b3333
  sw t1, 0(t0)

fail_d_max:
  li t0, 0x00100000
  li t1, 0x000c3333
  sw t1, 0(t0)

fail_d_min_zero:
  li t0, 0x00100000
  li t1, 0x000d3333
  sw t1, 0(t0)

fail_d_max_zero:
  li t0, 0x00100000
  li t1, 0x000e3333
  sw t1, 0(t0)

fail_d_qnan:
  li t0, 0x00100000
  li t1, 0x000f3333
  sw t1, 0(t0)

fail_d_qnan_flags:
  li t0, 0x00100000
  li t1, 0x00103333
  sw t1, 0(t0)

fail_d_both_nan:
  li t0, 0x00100000
  li t1, 0x00113333
  sw t1, 0(t0)

fail_d_both_nan_flags:
  li t0, 0x00100000
  li t1, 0x00123333
  sw t1, 0(t0)

fail_d_snan:
  li t0, 0x00100000
  li t1, 0x00133333
  sw t1, 0(t0)

fail_d_snan_flags:
  li t0, 0x00100000
  li t1, 0x00143333
  sw t1, 0(t0)

.section .data
.align 3
d_pos_three:
  .dword 0x4008000000000000
d_neg_two:
  .dword 0xc000000000000000
d_pos_zero:
  .dword 0x0000000000000000
d_neg_zero:
  .dword 0x8000000000000000
d_qnan_a:
  .dword 0x7ff8000000000001
d_qnan_b:
  .dword 0xfff8000000000002
d_snan:
  .dword 0x7ff0000000000001
d_one_half:
  .dword 0x3ff8000000000000
result_d:
  .dword 0
