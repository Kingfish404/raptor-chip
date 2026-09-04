.section .text
.globl _start

.macro check_s freg, expected
  fmv.x.w t1, \freg
  li t2, \expected
  bne t1, t2, fail
.endm

.macro check_d freg, expected_lo, expected_hi
  la t3, scratch
  fsd \freg, 0(t3)
  lw t1, 0(t3)
  li t2, \expected_lo
  bne t1, t2, fail
  lw t1, 4(t3)
  li t2, \expected_hi
  bne t1, t2, fail
.endm

.macro check_half freg, expected, expected_flags
  la t3, scratch
  fsh \freg, 0(t3)
  lhu t1, 0(t3)
  li t2, \expected
  bne t1, t2, fail
  csrr t1, fflags
  li t2, \expected_flags
  bne t1, t2, fail
.endm

_start:
  li t0, 0x6000
  csrs mstatus, t0

  # Exercise every single- and double-precision sign-injection operation.
  li t0, 0x3f800000
  fmv.w.x ft0, t0
  li t0, 0xc0000000
  fmv.w.x ft1, t0
  fsgnj.s ft2, ft0, ft1
  check_s ft2, 0xbf800000
  fsgnjn.s ft2, ft0, ft1
  check_s ft2, 0x3f800000
  fsgnjx.s ft2, ft0, ft1
  check_s ft2, 0xbf800000

  # A deliberately unboxed S operand must be treated as canonical qNaN.
  la t0, unboxed_single
  fld ft0, 0(t0)
  li t0, 0x3f800000
  fmv.w.x ft1, t0
  fsgnj.s ft2, ft0, ft1
  check_s ft2, 0x7fc00000

  la t0, double_values
  fld ft0, 0(t0)
  fld ft1, 8(t0)
  fsgnj.d ft2, ft0, ft1
  check_d ft2, 0x00000000, 0xbff00000
  fsgnjn.d ft2, ft0, ft1
  check_d ft2, 0x00000000, 0x3ff00000
  fsgnjx.d ft2, ft0, ft1
  check_d ft2, 0x00000000, 0xbff00000

  # Widen binary16 special values and both normal/subnormal finite values.
  la t0, half_values
  csrw fflags, zero
  flh ft0, 0(t0)
  fcvt.s.h ft1, ft0
  check_s ft1, 0x00000000
  csrr t1, fflags
  bnez t1, fail

  csrw fflags, zero
  flh ft0, 2(t0)
  fcvt.s.h ft1, ft0
  check_s ft1, 0x80000000
  csrr t1, fflags
  bnez t1, fail

  csrw fflags, zero
  flh ft0, 4(t0)
  fcvt.s.h ft1, ft0
  check_s ft1, 0x3f800000
  csrr t1, fflags
  bnez t1, fail

  csrw fflags, zero
  flh ft0, 6(t0)
  fcvt.s.h ft1, ft0
  check_s ft1, 0xc0000000
  csrr t1, fflags
  bnez t1, fail

  csrw fflags, zero
  flh ft0, 8(t0)
  fcvt.s.h ft1, ft0
  check_s ft1, 0x33800000
  csrr t1, fflags
  bnez t1, fail

  csrw fflags, zero
  flh ft0, 10(t0)
  fcvt.s.h ft1, ft0
  check_s ft1, 0x38800000
  csrr t1, fflags
  bnez t1, fail

  csrw fflags, zero
  flh ft0, 12(t0)
  fcvt.s.h ft1, ft0
  check_s ft1, 0x7f800000
  csrr t1, fflags
  bnez t1, fail

  csrw fflags, zero
  flh ft0, 14(t0)
  fcvt.s.h ft1, ft0
  check_s ft1, 0x7fc00000
  csrr t1, fflags
  li t2, 0x10
  bne t1, t2, fail

  # Widen an exactly loaded, deliberately unboxed half to canonical qNaN.
  csrw fflags, zero
  la t0, unboxed_half
  fld ft0, 0(t0)
  fcvt.s.h ft1, ft0
  check_s ft1, 0x7fc00000
  csrr t1, fflags
  bnez t1, fail

  la t0, half_values
  csrw fflags, zero
  flh ft0, 4(t0)
  fcvt.d.h ft1, ft0
  check_d ft1, 0x00000000, 0x3ff00000
  csrr t1, fflags
  bnez t1, fail

  csrw fflags, zero
  flh ft0, 8(t0)
  fcvt.d.h ft1, ft0
  check_d ft1, 0x00000000, 0x3e700000
  csrr t1, fflags
  bnez t1, fail

  # Narrow binary32 values. These cases drive exact, rounding, underflow,
  # overflow, infinity, NaN, and all directed-rounding paths.
  la t0, single_values

  csrw fflags, zero
  flw ft0, 0(t0)
  fcvt.h.s ft1, ft0, rne
  check_half ft1, 0x3c00, 0

  csrw fflags, zero
  flw ft0, 4(t0)
  fcvt.h.s ft1, ft0, rne
  check_half ft1, 0xc000, 0

  csrw fflags, zero
  flw ft0, 8(t0)
  fcvt.h.s ft1, ft0, rne
  check_half ft1, 0x0400, 0

  csrw fflags, zero
  flw ft0, 12(t0)
  fcvt.h.s ft1, ft0, rne
  check_half ft1, 0x0001, 0

  csrw fflags, zero
  flw ft0, 16(t0)
  fcvt.h.s ft1, ft0, rne
  check_half ft1, 0x7bff, 0

  csrw fflags, zero
  flw ft0, 20(t0)
  fcvt.h.s ft1, ft0, rne
  check_half ft1, 0x7c00, 0x05

  csrw fflags, zero
  flw ft0, 24(t0)
  fcvt.h.s ft1, ft0, rne
  check_half ft1, 0x3c00, 0x01

  csrw fflags, zero
  flw ft0, 24(t0)
  fcvt.h.s ft1, ft0, rmm
  check_half ft1, 0x3c01, 0x01

  csrw fflags, zero
  flw ft0, 28(t0)
  fcvt.h.s ft1, ft0, rne
  check_half ft1, 0x0000, 0x03

  csrw fflags, zero
  flw ft0, 28(t0)
  fcvt.h.s ft1, ft0, rmm
  check_half ft1, 0x0001, 0x03

  # RDN/RUP/RTZ make each rounding-mode branch observable as well.
  csrw fflags, zero
  flw ft0, 24(t0)
  fcvt.h.s ft1, ft0, rtz
  check_half ft1, 0x3c00, 0x01

  csrw fflags, zero
  flw ft0, 24(t0)
  fcvt.h.s ft1, ft0, rup
  check_half ft1, 0x3c01, 0x01

  csrw fflags, zero
  flw ft0, 32(t0)
  fcvt.h.s ft1, ft0, rdn
  check_half ft1, 0xbc01, 0x01

  # Narrow binary64 normal, infinity, and signaling NaN values.
  la t0, narrow_double_values
  csrw fflags, zero
  fld ft0, 0(t0)
  fcvt.h.d ft1, ft0, rne
  check_half ft1, 0x3c00, 0

  csrw fflags, zero
  fld ft0, 8(t0)
  fcvt.h.d ft1, ft0, rne
  check_half ft1, 0x7c00, 0

  csrw fflags, zero
  fld ft0, 16(t0)
  fcvt.h.d ft1, ft0, rne
  check_half ft1, 0x7e00, 0x10

  csrw fflags, zero
  fld ft0, 24(t0)
  fcvt.h.d ft1, ft0, rne
  check_half ft1, 0x0000, 0x03

  # RV32 can still execute D-to-S conversions. Cover double subnormal input,
  # overflow destinations, directed overflow rounding, and special values.
  la t0, narrow_double_to_single_values
  csrw fflags, zero
  fld ft0, 0(t0)
  fcvt.s.d ft1, ft0, rne
  check_s ft1, 0x00000000
  csrr t1, fflags
  li t2, 0x03
  bne t1, t2, fail

  csrw fflags, zero
  fld ft0, 8(t0)
  fcvt.s.d ft1, ft0, rne
  check_s ft1, 0x7f800000
  csrr t1, fflags
  li t2, 0x05
  bne t1, t2, fail

  csrw fflags, zero
  fld ft0, 8(t0)
  fcvt.s.d ft1, ft0, rtz
  check_s ft1, 0x7f7fffff
  csrr t1, fflags
  li t2, 0x05
  bne t1, t2, fail

  csrw fflags, zero
  fld ft0, 16(t0)
  fcvt.s.d ft1, ft0, rne
  check_s ft1, 0x7fc00000
  csrr t1, fflags
  bnez t1, fail

  csrw fflags, zero
  fld ft0, 24(t0)
  fcvt.s.d ft1, ft0, rne
  check_s ft1, 0x7fc00000
  csrr t1, fflags
  li t2, 0x10
  bne t1, t2, fail

  csrw fflags, zero
  fld ft0, 32(t0)
  fcvt.s.d ft1, ft0, rne
  check_s ft1, 0xff800000
  csrr t1, fflags
  bnez t1, fail

  # 1 + 2^-24 is halfway between adjacent binary32 values. Exercise the
  # remaining static rounding modes in the dedicated D-to-S narrowing unit.
  csrw fflags, zero
  fld ft0, 40(t0)
  fcvt.s.d ft1, ft0, rdn
  check_s ft1, 0x3f800000
  csrr t1, fflags
  li t2, 0x01
  bne t1, t2, fail

  csrw fflags, zero
  fld ft0, 40(t0)
  fcvt.s.d ft1, ft0, rup
  check_s ft1, 0x3f800001
  csrr t1, fflags
  li t2, 0x01
  bne t1, t2, fail

  csrw fflags, zero
  fld ft0, 40(t0)
  fcvt.s.d ft1, ft0, rmm
  check_s ft1, 0x3f800001
  csrr t1, fflags
  li t2, 0x01
  bne t1, t2, fail

  # 2^24+1 is exactly halfway between adjacent binary32 values, so every
  # static integer-conversion rounding mode has an observable result.
  li t0, 0x01000001
  csrw fflags, zero
  fcvt.s.w ft1, t0, rtz
  check_s ft1, 0x4b800000
  csrr t1, fflags
  li t2, 0x01
  bne t1, t2, fail

  csrw fflags, zero
  fcvt.s.w ft1, t0, rdn
  check_s ft1, 0x4b800000
  csrr t1, fflags
  li t2, 0x01
  bne t1, t2, fail

  csrw fflags, zero
  fcvt.s.w ft1, t0, rup
  check_s ft1, 0x4b800001
  csrr t1, fflags
  li t2, 0x01
  bne t1, t2, fail

  csrw fflags, zero
  fcvt.s.w ft1, t0, rmm
  check_s ft1, 0x4b800001
  csrr t1, fflags
  li t2, 0x01
  bne t1, t2, fail

  # Non-boxed binary32 is canonical NaN and does not raise invalid.
  csrw fflags, zero
  la t0, unboxed_single
  fld ft0, 0(t0)
  fcvt.h.s ft1, ft0, rne
  check_half ft1, 0x7e00, 0

pass:
  li a0, 0
  ebreak

fail:
  li a0, 1
  ebreak

.section .data
.align 3
double_values:
  .dword 0x3ff0000000000000
  .dword 0xc000000000000000

unboxed_single:
  .dword 0x000000003f800000

unboxed_half:
  .dword 0x0000ffffffff3c00

.align 1
half_values:
  .half 0x0000
  .half 0x8000
  .half 0x3c00
  .half 0xc000
  .half 0x0001
  .half 0x0400
  .half 0x7c00
  .half 0x7d00

.align 2
single_values:
  .word 0x3f800000
  .word 0xc0000000
  .word 0x38800000
  .word 0x33800000
  .word 0x477fe000
  .word 0x47800000
  .word 0x3f801000
  .word 0x33000000
  .word 0xbf801000

.align 3
narrow_double_values:
  .dword 0x3ff0000000000000
  .dword 0x7ff0000000000000
  .dword 0x7ff0000000000001
  .dword 0x0000000000000001

.align 3
narrow_double_to_single_values:
  .dword 0x0000000000000001
  .dword 0x7fefffffffffffff
  .dword 0x7ff8000000000001
  .dword 0x7ff0000000000001
  .dword 0xfff0000000000000
  .dword 0x3ff0000010000000

.align 3
scratch:
  .dword 0
