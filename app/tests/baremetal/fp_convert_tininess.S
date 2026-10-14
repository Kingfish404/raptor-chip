/* FCVT tininess: both signs, exact controls, five static/dynamic modes.
 * Store the full FPR to verify NaN boxing and both result words on RV32 too. */
.option norvc
.option norelax
.macro probe op, load, rm, mode, flags, datum
  la s1, \datum
  li t0, ((\mode << 5) | 8)
  csrw fcsr, t0
  \load ft0, 0(s1)
  \op ft2, ft0, \rm
  csrr t0, fcsr
  li t1, ((\mode << 5) | \flags)
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 8(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 12(s1)
  bne t0, t1, fail
.endm

#ifndef CASE_KIND
#define CASE_KIND 0
#endif

/* Keep all literal vectors in the image, including unselected conversions.
 * Each active row emits the five original static/dynamic rounding pairs. */
.macro conversion kind, op, load, flags, value, rne, rtz, rdn, rup, rmm
  .pushsection .data
.Lvector\@:
  .irp expected, \rne, \rtz, \rdn, \rup, \rmm
    .rept 2
      .quad \value, \expected
    .endr
  .endr
  .popsection
  .if CASE_KIND == \kind
    .set mode, 0
    .irp rm, rne, rtz, rdn, rup, rmm
      probe \op, \load, \rm, ((mode+1)%5), \flags, .Lvector\@+(mode*32)
      probe \op, \load, dyn, mode, \flags, .Lvector\@+(mode*32+16)
      .set mode, mode+1
    .endr
  .endif
.endm
.section .data
.balign 8
result: .quad 0
.section .text
.globl _start
_start:
  la t0, fail
  csrw mtvec, t0
  csrw mie, zero
  li t0, 0x6000
  csrs mstatus, t0
  la s0, result
  conversion 0, fcvt.s.d, fld, 11, 0x380fffffe0000000, 0xffffffff00800000, 0xffffffff007fffff, 0xffffffff007fffff, 0xffffffff00800000, 0xffffffff00800000
  conversion 0, fcvt.s.d, fld, 8, 0x3810000000000000, 0xffffffff00800000, 0xffffffff00800000, 0xffffffff00800000, 0xffffffff00800000, 0xffffffff00800000
  conversion 0, fcvt.s.d, fld, 11, 0xb80fffffe0000000, 0xffffffff80800000, 0xffffffff807fffff, 0xffffffff80800000, 0xffffffff807fffff, 0xffffffff80800000
  conversion 0, fcvt.s.d, fld, 8, 0xb810000000000000, 0xffffffff80800000, 0xffffffff80800000, 0xffffffff80800000, 0xffffffff80800000, 0xffffffff80800000
  conversion 1, fcvt.h.s, flw, 11, 0x387fe000, 0xffffffffffff0400, 0xffffffffffff03ff, 0xffffffffffff03ff, 0xffffffffffff0400, 0xffffffffffff0400
  conversion 1, fcvt.h.s, flw, 8, 0x38800000, 0xffffffffffff0400, 0xffffffffffff0400, 0xffffffffffff0400, 0xffffffffffff0400, 0xffffffffffff0400
  conversion 1, fcvt.h.s, flw, 11, 0xb87fe000, 0xffffffffffff8400, 0xffffffffffff83ff, 0xffffffffffff8400, 0xffffffffffff83ff, 0xffffffffffff8400
  conversion 1, fcvt.h.s, flw, 8, 0xb8800000, 0xffffffffffff8400, 0xffffffffffff8400, 0xffffffffffff8400, 0xffffffffffff8400, 0xffffffffffff8400
  conversion 2, fcvt.h.d, fld, 11, 0x3f0ffc0000000000, 0xffffffffffff0400, 0xffffffffffff03ff, 0xffffffffffff03ff, 0xffffffffffff0400, 0xffffffffffff0400
  conversion 2, fcvt.h.d, fld, 8, 0x3f10000000000000, 0xffffffffffff0400, 0xffffffffffff0400, 0xffffffffffff0400, 0xffffffffffff0400, 0xffffffffffff0400
  conversion 2, fcvt.h.d, fld, 11, 0xbf0ffc0000000000, 0xffffffffffff8400, 0xffffffffffff83ff, 0xffffffffffff8400, 0xffffffffffff83ff, 0xffffffffffff8400
  conversion 2, fcvt.h.d, fld, 8, 0xbf10000000000000, 0xffffffffffff8400, 0xffffffffffff8400, 0xffffffffffff8400, 0xffffffffffff8400, 0xffffffffffff8400
  li a0, 0
  ebreak
1: j 1b
fail:
  li a0, 1
  ebreak
2: j 2b
