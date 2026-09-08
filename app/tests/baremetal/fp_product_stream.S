/* Scalar shared-product handoff: same-format MUL/FMA, both precisions,
 * every fused opcode, dynamic rounding and completion flag ownership.
 * Exact integer operands keep all five rounding modes self-checking.
 */
.section .text
.globl _start
.macro check value
  li t2, \value
  bne t1, t2, fail
.endm
.macro sequence format
  fmul.\format ft3, ft0, ft1, dyn
  fcvt.w.\format t1, ft3, rtz
  check 6
  fmadd.\format ft3, ft0, ft1, ft2, dyn
  fcvt.w.\format t1, ft3, rtz
  check 7
  fmul.\format ft3, ft0, ft1, dyn
  fmsub.\format ft3, ft0, ft1, ft2, dyn
  fcvt.w.\format t1, ft3, rtz
  check 5
  fmul.\format ft3, ft0, ft1, dyn
  fnmsub.\format ft3, ft0, ft1, ft2, dyn
  fcvt.w.\format t1, ft3, rtz
  check -5
  fmul.\format ft3, ft0, ft1, dyn
  fnmadd.\format ft3, ft0, ft1, ft2, dyn
  fcvt.w.\format t1, ft3, rtz
  check -7
.endm
_start:
  li t0, 0x6000
  csrs mstatus, t0
  csrwi fcsr, 0
  li s0, 16
outer:
  li s1, 0
rounding:
  csrw frm, s1
  li t0, 3
  fcvt.s.w ft0, t0
  li t0, 2
  fcvt.s.w ft1, t0
  li t0, 1
  fcvt.s.w ft2, t0
  sequence s
  fcvt.d.s ft0, ft0
  fcvt.d.s ft1, ft1
  fcvt.d.s ft2, ft2
  sequence d
  csrr t0, fflags
  bnez t0, fail
  addi s1, s1, 1
  li t0, 5
  blt s1, t0, rounding
  addi s0, s0, -1
  bnez s0, outer
  /* Invalid MUL followed by exact FMA; then the converse. */
  li t0, 0x7f800000
  fmv.w.x ft0, t0
  fmv.w.x ft1, zero
  fmul.s ft3, ft0, ft1
  csrr t1, fflags
  check 16
  csrwi fflags, 0
  fmadd.s ft3, ft1, ft1, ft1
  csrr t1, fflags
  check 0
  fmadd.s ft3, ft0, ft1, ft1
  csrr t1, fflags
  check 16
  csrwi fflags, 0
  fmul.s ft3, ft1, ft1
  csrr t1, fflags
  check 0
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
