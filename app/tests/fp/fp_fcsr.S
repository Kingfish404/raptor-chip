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
  li t2, 0x3f800001
  bne t1, t2, fail_rup

  csrr t1, fflags
  li t2, 1
  bne t1, t2, fail_flags

  csrr t1, fcsr
  li t2, 0x61
  bne t1, t2, fail_fcsr

  li t0, 0
  csrw frm, t0
  fadd.s ft3, ft0, ft1, dyn
  fmv.x.w t1, ft3
  li t2, 0x3f800000
  bne t1, t2, fail_rne

  csrr t1, fflags
  li t2, 1
  bne t1, t2, fail_sticky

  csrw fflags, zero
  csrr t1, fflags
  bnez t1, fail_clear

  li t0, 0x7f800000
  fmv.w.x ft4, t0
  li t0, 0xff800000
  fmv.w.x ft5, t0
  fadd.s ft6, ft4, ft5

  csrr t1, fflags
  li t2, 0x10
  bne t1, t2, fail_nv

  csrr t1, fcsr
  bne t1, t2, fail_nv_fcsr

  li t0, 0x00100000
  li t1, 0x5555
  sw t1, 0(t0)

fail_rup:
  li t0, 0x00100000
  li t1, 0x00013333
  sw t1, 0(t0)

fail_flags:
  li t0, 0x00100000
  li t1, 0x00023333
  sw t1, 0(t0)

fail_rne:
  li t0, 0x00100000
  li t1, 0x00033333
  sw t1, 0(t0)

fail_sticky:
  li t0, 0x00100000
  li t1, 0x00043333
  sw t1, 0(t0)

fail_clear:
  li t0, 0x00100000
  li t1, 0x00053333
  sw t1, 0(t0)

fail_fcsr:
  li t0, 0x00100000
  li t1, 0x00063333
  sw t1, 0(t0)

fail_nv:
  li t0, 0x00100000
  li t1, 0x00073333
  sw t1, 0(t0)

fail_nv_fcsr:
  li t0, 0x00100000
  li t1, 0x00083333
  sw t1, 0(t0)