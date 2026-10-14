/* FMUL and four fused variants: midpoint tininess, exact controls,
 * static rounding overrides frm; dynamic rounding follows frm. */
.option norvc
.option norelax
.macro probe op, load, store, rm, mode, flags, datum, high, fused
  la s1, \datum
  li t0, ((\mode << 5) | 8)
  csrw fcsr, t0
  \load ft0, 0(s1)
  \load ft1, 8(s1)
  .if \fused
    \load ft3, 16(s1)
    \op ft2, ft0, ft1, ft3, \rm
  .else
    \op ft2, ft0, ft1, \rm
  .endif
  csrr t0, fcsr
  li t1, ((\mode << 5) | \flags)
  bne t0, t1, fail
  \store ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 24(s1)
  bne t0, t1, fail
  .if \high
    lw t0, 4(s0)
    lw t1, 28(s1)
    bne t0, t1, fail
  .endif
.endm

/* Literal expected words remain independent of the RTL/reference model.
 * Static rm deliberately differs from frm; dyn uses the selected frm. */
.macro product op, load, store, high, fused, flags, a, b, c, rne, rtz, rdn, rup, rmm
  .pushsection .data
.Lvector\@:
  .irp expected, \rne, \rtz, \rdn, \rup, \rmm
    .rept 2
      .quad \a, \b, \c, \expected
    .endr
  .endr
  .popsection
  .set mode, 0
  .irp rm, rne, rtz, rdn, rup, rmm
    probe \op, \load, \store, \rm, ((mode+1)%5), \flags, .Lvector\@+(mode*64), \high, \fused
    probe \op, \load, \store, dyn, mode, \flags, .Lvector\@+(mode*64+32), \high, \fused
    .set mode, mode+1
  .endr
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
  product fmul.s, flw, fsw, 0, 0, 11, 0x800000, 0x3f7fffff, 0, 0x800000, 0x7fffff, 0x7fffff, 0x800000, 0x800000
  product fmul.s, flw, fsw, 0, 0, 8, 0x800000, 0x3f800000, 0, 0x800000, 0x800000, 0x800000, 0x800000, 0x800000
  product fmul.s, flw, fsw, 0, 0, 11, 0x80800000, 0x3f7fffff, 0, 0x80800000, 0x807fffff, 0x80800000, 0x807fffff, 0x80800000
  product fmul.s, flw, fsw, 0, 0, 8, 0x80800000, 0x3f800000, 0, 0x80800000, 0x80800000, 0x80800000, 0x80800000, 0x80800000
  product fmadd.s, flw, fsw, 0, 1, 11, 0x800000, 0x3f7fffff, 0, 0x800000, 0x7fffff, 0x7fffff, 0x800000, 0x800000
  product fmadd.s, flw, fsw, 0, 1, 8, 0x800000, 0x3f800000, 0, 0x800000, 0x800000, 0x800000, 0x800000, 0x800000
  product fmadd.s, flw, fsw, 0, 1, 11, 0x80800000, 0x3f7fffff, 0, 0x80800000, 0x807fffff, 0x80800000, 0x807fffff, 0x80800000
  product fmadd.s, flw, fsw, 0, 1, 8, 0x80800000, 0x3f800000, 0, 0x80800000, 0x80800000, 0x80800000, 0x80800000, 0x80800000
  product fmsub.s, flw, fsw, 0, 1, 11, 0x800000, 0x3f7fffff, 0, 0x800000, 0x7fffff, 0x7fffff, 0x800000, 0x800000
  product fmsub.s, flw, fsw, 0, 1, 8, 0x800000, 0x3f800000, 0, 0x800000, 0x800000, 0x800000, 0x800000, 0x800000
  product fmsub.s, flw, fsw, 0, 1, 11, 0x80800000, 0x3f7fffff, 0, 0x80800000, 0x807fffff, 0x80800000, 0x807fffff, 0x80800000
  product fmsub.s, flw, fsw, 0, 1, 8, 0x80800000, 0x3f800000, 0, 0x80800000, 0x80800000, 0x80800000, 0x80800000, 0x80800000
  product fnmsub.s, flw, fsw, 0, 1, 11, 0x800000, 0x3f7fffff, 0, 0x80800000, 0x807fffff, 0x80800000, 0x807fffff, 0x80800000
  product fnmsub.s, flw, fsw, 0, 1, 8, 0x800000, 0x3f800000, 0, 0x80800000, 0x80800000, 0x80800000, 0x80800000, 0x80800000
  product fnmsub.s, flw, fsw, 0, 1, 11, 0x80800000, 0x3f7fffff, 0, 0x800000, 0x7fffff, 0x7fffff, 0x800000, 0x800000
  product fnmsub.s, flw, fsw, 0, 1, 8, 0x80800000, 0x3f800000, 0, 0x800000, 0x800000, 0x800000, 0x800000, 0x800000
  product fnmadd.s, flw, fsw, 0, 1, 11, 0x800000, 0x3f7fffff, 0, 0x80800000, 0x807fffff, 0x80800000, 0x807fffff, 0x80800000
  product fnmadd.s, flw, fsw, 0, 1, 8, 0x800000, 0x3f800000, 0, 0x80800000, 0x80800000, 0x80800000, 0x80800000, 0x80800000
  product fnmadd.s, flw, fsw, 0, 1, 11, 0x80800000, 0x3f7fffff, 0, 0x800000, 0x7fffff, 0x7fffff, 0x800000, 0x800000
  product fnmadd.s, flw, fsw, 0, 1, 8, 0x80800000, 0x3f800000, 0, 0x800000, 0x800000, 0x800000, 0x800000, 0x800000
  product fmul.d, fld, fsd, 1, 0, 11, 0x10000000000000, 0x3fefffffffffffff, 0, 0x10000000000000, 0xfffffffffffff, 0xfffffffffffff, 0x10000000000000, 0x10000000000000
  product fmul.d, fld, fsd, 1, 0, 8, 0x10000000000000, 0x3ff0000000000000, 0, 0x10000000000000, 0x10000000000000, 0x10000000000000, 0x10000000000000, 0x10000000000000
  product fmul.d, fld, fsd, 1, 0, 11, 0x8010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000, 0x800fffffffffffff, 0x8010000000000000, 0x800fffffffffffff, 0x8010000000000000
  product fmul.d, fld, fsd, 1, 0, 8, 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000, 0x8010000000000000, 0x8010000000000000, 0x8010000000000000, 0x8010000000000000
  product fmadd.d, fld, fsd, 1, 1, 11, 0x10000000000000, 0x3fefffffffffffff, 0, 0x10000000000000, 0xfffffffffffff, 0xfffffffffffff, 0x10000000000000, 0x10000000000000
  product fmadd.d, fld, fsd, 1, 1, 8, 0x10000000000000, 0x3ff0000000000000, 0, 0x10000000000000, 0x10000000000000, 0x10000000000000, 0x10000000000000, 0x10000000000000
  product fmadd.d, fld, fsd, 1, 1, 11, 0x8010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000, 0x800fffffffffffff, 0x8010000000000000, 0x800fffffffffffff, 0x8010000000000000
  product fmadd.d, fld, fsd, 1, 1, 8, 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000, 0x8010000000000000, 0x8010000000000000, 0x8010000000000000, 0x8010000000000000
  product fmsub.d, fld, fsd, 1, 1, 11, 0x10000000000000, 0x3fefffffffffffff, 0, 0x10000000000000, 0xfffffffffffff, 0xfffffffffffff, 0x10000000000000, 0x10000000000000
  product fmsub.d, fld, fsd, 1, 1, 8, 0x10000000000000, 0x3ff0000000000000, 0, 0x10000000000000, 0x10000000000000, 0x10000000000000, 0x10000000000000, 0x10000000000000
  product fmsub.d, fld, fsd, 1, 1, 11, 0x8010000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000, 0x800fffffffffffff, 0x8010000000000000, 0x800fffffffffffff, 0x8010000000000000
  product fmsub.d, fld, fsd, 1, 1, 8, 0x8010000000000000, 0x3ff0000000000000, 0, 0x8010000000000000, 0x8010000000000000, 0x8010000000000000, 0x8010000000000000, 0x8010000000000000
  product fnmsub.d, fld, fsd, 1, 1, 11, 0x10000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000, 0x800fffffffffffff, 0x8010000000000000, 0x800fffffffffffff, 0x8010000000000000
  product fnmsub.d, fld, fsd, 1, 1, 8, 0x10000000000000, 0x3ff0000000000000, 0, 0x8010000000000000, 0x8010000000000000, 0x8010000000000000, 0x8010000000000000, 0x8010000000000000
  product fnmsub.d, fld, fsd, 1, 1, 11, 0x8010000000000000, 0x3fefffffffffffff, 0, 0x10000000000000, 0xfffffffffffff, 0xfffffffffffff, 0x10000000000000, 0x10000000000000
  product fnmsub.d, fld, fsd, 1, 1, 8, 0x8010000000000000, 0x3ff0000000000000, 0, 0x10000000000000, 0x10000000000000, 0x10000000000000, 0x10000000000000, 0x10000000000000
  product fnmadd.d, fld, fsd, 1, 1, 11, 0x10000000000000, 0x3fefffffffffffff, 0, 0x8010000000000000, 0x800fffffffffffff, 0x8010000000000000, 0x800fffffffffffff, 0x8010000000000000
  product fnmadd.d, fld, fsd, 1, 1, 8, 0x10000000000000, 0x3ff0000000000000, 0, 0x8010000000000000, 0x8010000000000000, 0x8010000000000000, 0x8010000000000000, 0x8010000000000000
  product fnmadd.d, fld, fsd, 1, 1, 11, 0x8010000000000000, 0x3fefffffffffffff, 0, 0x10000000000000, 0xfffffffffffff, 0xfffffffffffff, 0x10000000000000, 0x10000000000000
  product fnmadd.d, fld, fsd, 1, 1, 8, 0x8010000000000000, 0x3ff0000000000000, 0, 0x10000000000000, 0x10000000000000, 0x10000000000000, 0x10000000000000, 0x10000000000000
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
1: j 1b
