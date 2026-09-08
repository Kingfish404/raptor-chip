/* Tininess at min-normal: actual FDIV result, static/dynamic rounding and
 * retired sticky flags. Integer word loads compare both halves on RV32 too. */
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, fail
  csrw mtvec, t0
  csrw mie, zero
  li t0, 0x6000
  csrs mstatus, t0
  la s0, result
  la s1, case_0
  li t0, 0
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, rne
  csrr t0, fcsr
  li t1, 11
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_1
  li t0, 0
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 11
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_2
  li t0, 1
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, rtz
  csrr t0, fcsr
  li t1, 43
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_3
  li t0, 1
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 43
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_4
  li t0, 2
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, rdn
  csrr t0, fcsr
  li t1, 75
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_5
  li t0, 2
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 75
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_6
  li t0, 3
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, rup
  csrr t0, fcsr
  li t1, 107
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_7
  li t0, 3
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 107
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_8
  li t0, 4
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, rmm
  csrr t0, fcsr
  li t1, 139
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_9
  li t0, 4
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 139
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_10
  li t0, 0
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, rne
  csrr t0, fcsr
  li t1, 8
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_11
  li t0, 0
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 8
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_12
  li t0, 1
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, rtz
  csrr t0, fcsr
  li t1, 40
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_13
  li t0, 1
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 40
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_14
  li t0, 2
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, rdn
  csrr t0, fcsr
  li t1, 72
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_15
  li t0, 2
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 72
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_16
  li t0, 3
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, rup
  csrr t0, fcsr
  li t1, 104
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_17
  li t0, 3
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 104
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_18
  li t0, 4
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, rmm
  csrr t0, fcsr
  li t1, 136
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_19
  li t0, 4
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 136
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_20
  li t0, 0
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, rne
  csrr t0, fcsr
  li t1, 11
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_21
  li t0, 0
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 11
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_22
  li t0, 1
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, rtz
  csrr t0, fcsr
  li t1, 43
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_23
  li t0, 1
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 43
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_24
  li t0, 2
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, rdn
  csrr t0, fcsr
  li t1, 75
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_25
  li t0, 2
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 75
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_26
  li t0, 3
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, rup
  csrr t0, fcsr
  li t1, 107
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_27
  li t0, 3
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 107
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_28
  li t0, 4
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, rmm
  csrr t0, fcsr
  li t1, 139
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_29
  li t0, 4
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 139
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_30
  li t0, 0
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, rne
  csrr t0, fcsr
  li t1, 8
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_31
  li t0, 0
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 8
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_32
  li t0, 1
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, rtz
  csrr t0, fcsr
  li t1, 40
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_33
  li t0, 1
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 40
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_34
  li t0, 2
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, rdn
  csrr t0, fcsr
  li t1, 72
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_35
  li t0, 2
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 72
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_36
  li t0, 3
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, rup
  csrr t0, fcsr
  li t1, 104
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_37
  li t0, 3
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 104
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_38
  li t0, 4
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, rmm
  csrr t0, fcsr
  li t1, 136
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_39
  li t0, 4
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  flw ft0, 0(s1)
  flw ft1, 8(s1)
  fdiv.s ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 136
  bne t0, t1, fail
  fsw ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  la s1, case_40
  li t0, 0
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, rne
  csrr t0, fcsr
  li t1, 11
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_41
  li t0, 0
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 11
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_42
  li t0, 1
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, rtz
  csrr t0, fcsr
  li t1, 43
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_43
  li t0, 1
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 43
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_44
  li t0, 2
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, rdn
  csrr t0, fcsr
  li t1, 75
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_45
  li t0, 2
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 75
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_46
  li t0, 3
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, rup
  csrr t0, fcsr
  li t1, 107
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_47
  li t0, 3
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 107
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_48
  li t0, 4
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, rmm
  csrr t0, fcsr
  li t1, 139
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_49
  li t0, 4
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 139
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_50
  li t0, 0
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, rne
  csrr t0, fcsr
  li t1, 8
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_51
  li t0, 0
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 8
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_52
  li t0, 1
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, rtz
  csrr t0, fcsr
  li t1, 40
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_53
  li t0, 1
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 40
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_54
  li t0, 2
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, rdn
  csrr t0, fcsr
  li t1, 72
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_55
  li t0, 2
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 72
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_56
  li t0, 3
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, rup
  csrr t0, fcsr
  li t1, 104
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_57
  li t0, 3
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 104
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_58
  li t0, 4
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, rmm
  csrr t0, fcsr
  li t1, 136
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_59
  li t0, 4
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 136
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_60
  li t0, 0
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, rne
  csrr t0, fcsr
  li t1, 11
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_61
  li t0, 0
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 11
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_62
  li t0, 1
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, rtz
  csrr t0, fcsr
  li t1, 43
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_63
  li t0, 1
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 43
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_64
  li t0, 2
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, rdn
  csrr t0, fcsr
  li t1, 75
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_65
  li t0, 2
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 75
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_66
  li t0, 3
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, rup
  csrr t0, fcsr
  li t1, 107
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_67
  li t0, 3
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 107
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_68
  li t0, 4
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, rmm
  csrr t0, fcsr
  li t1, 139
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_69
  li t0, 4
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 139
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_70
  li t0, 0
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, rne
  csrr t0, fcsr
  li t1, 8
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_71
  li t0, 0
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 8
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_72
  li t0, 1
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, rtz
  csrr t0, fcsr
  li t1, 40
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_73
  li t0, 1
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 40
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_74
  li t0, 2
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, rdn
  csrr t0, fcsr
  li t1, 72
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_75
  li t0, 2
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 72
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_76
  li t0, 3
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, rup
  csrr t0, fcsr
  li t1, 104
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_77
  li t0, 3
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 104
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_78
  li t0, 4
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, rmm
  csrr t0, fcsr
  li t1, 136
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  la s1, case_79
  li t0, 4
  csrw frm, t0
  li t0, 8
  csrw fflags, t0
  fld ft0, 0(s1)
  fld ft1, 8(s1)
  fdiv.d ft2, ft0, ft1, dyn
  csrr t0, fcsr
  li t1, 136
  bne t0, t1, fail
  fsd ft2, 0(s0)
  lw t0, 0(s0)
  lw t1, 16(s1)
  bne t0, t1, fail
  lw t0, 4(s0)
  lw t1, 20(s1)
  bne t0, t1, fail
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
1: j 1b
.section .data
.balign 8
result: .quad 0
case_0: .quad 0x00000000007fffff, 0x000000003f7fffff, 0x00000000007fffff
case_1: .quad 0x00000000007fffff, 0x000000003f7fffff, 0x00000000007fffff
case_2: .quad 0x00000000007fffff, 0x000000003f7fffff, 0x00000000007fffff
case_3: .quad 0x00000000007fffff, 0x000000003f7fffff, 0x00000000007fffff
case_4: .quad 0x00000000007fffff, 0x000000003f7fffff, 0x00000000007fffff
case_5: .quad 0x00000000007fffff, 0x000000003f7fffff, 0x00000000007fffff
case_6: .quad 0x00000000007fffff, 0x000000003f7fffff, 0x0000000000800000
case_7: .quad 0x00000000007fffff, 0x000000003f7fffff, 0x0000000000800000
case_8: .quad 0x00000000007fffff, 0x000000003f7fffff, 0x00000000007fffff
case_9: .quad 0x00000000007fffff, 0x000000003f7fffff, 0x00000000007fffff
case_10: .quad 0x0000000000800000, 0x000000003f800000, 0x0000000000800000
case_11: .quad 0x0000000000800000, 0x000000003f800000, 0x0000000000800000
case_12: .quad 0x0000000000800000, 0x000000003f800000, 0x0000000000800000
case_13: .quad 0x0000000000800000, 0x000000003f800000, 0x0000000000800000
case_14: .quad 0x0000000000800000, 0x000000003f800000, 0x0000000000800000
case_15: .quad 0x0000000000800000, 0x000000003f800000, 0x0000000000800000
case_16: .quad 0x0000000000800000, 0x000000003f800000, 0x0000000000800000
case_17: .quad 0x0000000000800000, 0x000000003f800000, 0x0000000000800000
case_18: .quad 0x0000000000800000, 0x000000003f800000, 0x0000000000800000
case_19: .quad 0x0000000000800000, 0x000000003f800000, 0x0000000000800000
case_20: .quad 0x00000000807fffff, 0x000000003f7fffff, 0x00000000807fffff
case_21: .quad 0x00000000807fffff, 0x000000003f7fffff, 0x00000000807fffff
case_22: .quad 0x00000000807fffff, 0x000000003f7fffff, 0x00000000807fffff
case_23: .quad 0x00000000807fffff, 0x000000003f7fffff, 0x00000000807fffff
case_24: .quad 0x00000000807fffff, 0x000000003f7fffff, 0x0000000080800000
case_25: .quad 0x00000000807fffff, 0x000000003f7fffff, 0x0000000080800000
case_26: .quad 0x00000000807fffff, 0x000000003f7fffff, 0x00000000807fffff
case_27: .quad 0x00000000807fffff, 0x000000003f7fffff, 0x00000000807fffff
case_28: .quad 0x00000000807fffff, 0x000000003f7fffff, 0x00000000807fffff
case_29: .quad 0x00000000807fffff, 0x000000003f7fffff, 0x00000000807fffff
case_30: .quad 0x0000000080800000, 0x000000003f800000, 0x0000000080800000
case_31: .quad 0x0000000080800000, 0x000000003f800000, 0x0000000080800000
case_32: .quad 0x0000000080800000, 0x000000003f800000, 0x0000000080800000
case_33: .quad 0x0000000080800000, 0x000000003f800000, 0x0000000080800000
case_34: .quad 0x0000000080800000, 0x000000003f800000, 0x0000000080800000
case_35: .quad 0x0000000080800000, 0x000000003f800000, 0x0000000080800000
case_36: .quad 0x0000000080800000, 0x000000003f800000, 0x0000000080800000
case_37: .quad 0x0000000080800000, 0x000000003f800000, 0x0000000080800000
case_38: .quad 0x0000000080800000, 0x000000003f800000, 0x0000000080800000
case_39: .quad 0x0000000080800000, 0x000000003f800000, 0x0000000080800000
case_40: .quad 0x000fffffffffffff, 0x3fefffffffffffff, 0x000fffffffffffff
case_41: .quad 0x000fffffffffffff, 0x3fefffffffffffff, 0x000fffffffffffff
case_42: .quad 0x000fffffffffffff, 0x3fefffffffffffff, 0x000fffffffffffff
case_43: .quad 0x000fffffffffffff, 0x3fefffffffffffff, 0x000fffffffffffff
case_44: .quad 0x000fffffffffffff, 0x3fefffffffffffff, 0x000fffffffffffff
case_45: .quad 0x000fffffffffffff, 0x3fefffffffffffff, 0x000fffffffffffff
case_46: .quad 0x000fffffffffffff, 0x3fefffffffffffff, 0x0010000000000000
case_47: .quad 0x000fffffffffffff, 0x3fefffffffffffff, 0x0010000000000000
case_48: .quad 0x000fffffffffffff, 0x3fefffffffffffff, 0x000fffffffffffff
case_49: .quad 0x000fffffffffffff, 0x3fefffffffffffff, 0x000fffffffffffff
case_50: .quad 0x0010000000000000, 0x3ff0000000000000, 0x0010000000000000
case_51: .quad 0x0010000000000000, 0x3ff0000000000000, 0x0010000000000000
case_52: .quad 0x0010000000000000, 0x3ff0000000000000, 0x0010000000000000
case_53: .quad 0x0010000000000000, 0x3ff0000000000000, 0x0010000000000000
case_54: .quad 0x0010000000000000, 0x3ff0000000000000, 0x0010000000000000
case_55: .quad 0x0010000000000000, 0x3ff0000000000000, 0x0010000000000000
case_56: .quad 0x0010000000000000, 0x3ff0000000000000, 0x0010000000000000
case_57: .quad 0x0010000000000000, 0x3ff0000000000000, 0x0010000000000000
case_58: .quad 0x0010000000000000, 0x3ff0000000000000, 0x0010000000000000
case_59: .quad 0x0010000000000000, 0x3ff0000000000000, 0x0010000000000000
case_60: .quad 0x800fffffffffffff, 0x3fefffffffffffff, 0x800fffffffffffff
case_61: .quad 0x800fffffffffffff, 0x3fefffffffffffff, 0x800fffffffffffff
case_62: .quad 0x800fffffffffffff, 0x3fefffffffffffff, 0x800fffffffffffff
case_63: .quad 0x800fffffffffffff, 0x3fefffffffffffff, 0x800fffffffffffff
case_64: .quad 0x800fffffffffffff, 0x3fefffffffffffff, 0x8010000000000000
case_65: .quad 0x800fffffffffffff, 0x3fefffffffffffff, 0x8010000000000000
case_66: .quad 0x800fffffffffffff, 0x3fefffffffffffff, 0x800fffffffffffff
case_67: .quad 0x800fffffffffffff, 0x3fefffffffffffff, 0x800fffffffffffff
case_68: .quad 0x800fffffffffffff, 0x3fefffffffffffff, 0x800fffffffffffff
case_69: .quad 0x800fffffffffffff, 0x3fefffffffffffff, 0x800fffffffffffff
case_70: .quad 0x8010000000000000, 0x3ff0000000000000, 0x8010000000000000
case_71: .quad 0x8010000000000000, 0x3ff0000000000000, 0x8010000000000000
case_72: .quad 0x8010000000000000, 0x3ff0000000000000, 0x8010000000000000
case_73: .quad 0x8010000000000000, 0x3ff0000000000000, 0x8010000000000000
case_74: .quad 0x8010000000000000, 0x3ff0000000000000, 0x8010000000000000
case_75: .quad 0x8010000000000000, 0x3ff0000000000000, 0x8010000000000000
case_76: .quad 0x8010000000000000, 0x3ff0000000000000, 0x8010000000000000
case_77: .quad 0x8010000000000000, 0x3ff0000000000000, 0x8010000000000000
case_78: .quad 0x8010000000000000, 0x3ff0000000000000, 0x8010000000000000
case_79: .quad 0x8010000000000000, 0x3ff0000000000000, 0x8010000000000000
