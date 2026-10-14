/* Tininess at min-normal: actual FDIV result, static/dynamic rounding and
 * retired sticky flags. Integer word loads compare both halves on RV32 too. */
.option norvc
.option norelax
.macro probe load, store, op, rm, mode, flags, datum, high
  la s1, \datum
  li t0, \mode
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  \load ft0, 0(s1)
  \load ft1, 8(s1)
  \op ft2, ft0, ft1, \rm
  csrr t0, fcsr
  li t1, ((\mode << 5) | \flags)
  bne t0, t1, fail
  \store ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  .if \high
    lw t0, 4(s0)
    lw t1, 20(s1)
    bne t0, t1, fail
  .endif
.endm

/* Each row expands to all five static/dynamic rounding pairs, preserving
 * instruction order and the sticky DZ flag independently of the result. */
.macro division load, store, op, high, flags, a, b, rne, rtz, rdn, rup, rmm
  .pushsection .data
.Lvector\@:
  .irp expected, \rne, \rtz, \rdn, \rup, \rmm
    .rept 2
      .quad \a, \b, \expected
    .endr
  .endr
  .popsection
  .set mode, 0
  .irp rm, rne, rtz, rdn, rup, rmm
    probe \load, \store, \op, \rm, mode, \flags, .Lvector\@+(mode*48), \high
    probe \load, \store, \op, dyn, mode, \flags, .Lvector\@+(mode*48+24), \high
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
  division flw, fsw, fdiv.s, 0, 11, 0x7fffff, 0x3f7fffff, 0x7fffff, 0x7fffff, 0x7fffff, 0x800000, 0x7fffff
  division flw, fsw, fdiv.s, 0, 8, 0x800000, 0x3f800000, 0x800000, 0x800000, 0x800000, 0x800000, 0x800000
  division flw, fsw, fdiv.s, 0, 11, 0x807fffff, 0x3f7fffff, 0x807fffff, 0x807fffff, 0x80800000, 0x807fffff, 0x807fffff
  division flw, fsw, fdiv.s, 0, 8, 0x80800000, 0x3f800000, 0x80800000, 0x80800000, 0x80800000, 0x80800000, 0x80800000
  division fld, fsd, fdiv.d, 1, 11, 0xfffffffffffff, 0x3fefffffffffffff, 0xfffffffffffff, 0xfffffffffffff, 0xfffffffffffff, 0x10000000000000, 0xfffffffffffff
  division fld, fsd, fdiv.d, 1, 8, 0x10000000000000, 0x3ff0000000000000, 0x10000000000000, 0x10000000000000, 0x10000000000000, 0x10000000000000, 0x10000000000000
  division fld, fsd, fdiv.d, 1, 11, 0x800fffffffffffff, 0x3fefffffffffffff, 0x800fffffffffffff, 0x800fffffffffffff, 0x8010000000000000, 0x800fffffffffffff, 0x800fffffffffffff
  division fld, fsd, fdiv.d, 1, 8, 0x8010000000000000, 0x3ff0000000000000, 0x8010000000000000, 0x8010000000000000, 0x8010000000000000, 0x8010000000000000, 0x8010000000000000
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
1: j 1b
