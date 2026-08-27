.section .text
.globl _start
_start:
  li t0, 0x6000
  csrs mstatus, t0

  li t0, 0x40c00000
  fmv.w.x ft0, t0
  li t0, 0x40000000
  fmv.w.x ft1, t0
  csrw fflags, zero
  fdiv.s ft2, ft0, ft1, rne
  fmv.x.w t1, ft2
  li t2, 0x40400000
  bne t1, t2, fail_fdiv_s
  csrr t1, fflags
  bnez t1, fail_fdiv_s_flags

  li t0, 0x41100000
  fmv.w.x ft0, t0
  csrw fflags, zero
  fsqrt.s ft2, ft0, rne
  fmv.x.w t1, ft2
  li t2, 0x40400000
  bne t1, t2, fail_fsqrt_s
  csrr t1, fflags
  bnez t1, fail_fsqrt_s_flags

  li t0, 0x40c00000
  fmv.w.x ft0, t0
  li t0, 0x40000000
  fmv.w.x ft1, t0
  csrw fflags, zero
  fdiv.s ft2, ft0, ft1, rne
  fdiv.s ft3, ft2, ft2, rne
  fsqrt.s ft4, ft3, rne
  fmv.x.w t1, ft4
  li t2, 0x3f800000
  bne t1, t2, fail_fdivsqrt_s_chain
  csrr t1, fflags
  bnez t1, fail_fdivsqrt_s_chain_flags

  li t0, 2
  csrw frm, t0
  li t0, 0x3f800000
  fmv.w.x ft0, t0
  li t0, 0x40400000
  fmv.w.x ft1, t0
  csrw fflags, zero
  fdiv.s ft2, ft0, ft1, dyn
  fmv.x.w t1, ft2
  li t2, 0x3eaaaaaa
  bne t1, t2, fail_fdiv_s_dyn
  csrr t1, fflags
  li t2, 1
  bne t1, t2, fail_fdiv_s_dyn_flags

  csrw fflags, zero
  fdiv.s ft2, ft0, ft1, rup
  fmv.x.w t1, ft2
  li t2, 0x3eaaaaab
  bne t1, t2, fail_fdiv_s_rup
  csrr t1, fflags
  li t2, 1
  bne t1, t2, fail_fdiv_s_rup_flags

  csrw fflags, zero
  fdiv.s ft2, ft0, ft1, rmm
  fmv.x.w t1, ft2
  li t2, 0x3eaaaaab
  bne t1, t2, fail_fdiv_s_rmm
  csrr t1, fflags
  li t2, 1
  bne t1, t2, fail_fdiv_s_rmm_flags

  li t0, 1
  fmv.w.x ft0, t0
  li t0, 0x40000000
  fmv.w.x ft1, t0
  csrw fflags, zero
  fdiv.s ft2, ft0, ft1, rne
  fmv.x.w t1, ft2
  bnez t1, fail_fdiv_s_rne_halfway
  csrr t1, fflags
  li t2, 3
  bne t1, t2, fail_fdiv_s_rne_halfway_flags

  csrw fflags, zero
  fdiv.s ft2, ft0, ft1, rmm
  fmv.x.w t1, ft2
  li t2, 1
  bne t1, t2, fail_fdiv_s_rmm_halfway
  csrr t1, fflags
  li t2, 3
  bne t1, t2, fail_fdiv_s_rmm_halfway_flags
  csrw frm, zero

  li t0, 0x3f800000
  fmv.w.x ft0, t0
  fmv.w.x ft1, zero
  csrw fflags, zero
  fdiv.s ft2, ft0, ft1, rne
  fclass.s t1, ft2
  li t2, 128
  bne t1, t2, fail_fdiv_s_dz
  csrr t1, fflags
  li t2, 8
  bne t1, t2, fail_fdiv_s_dz_flags

  fmv.w.x ft0, zero
  fmv.w.x ft1, zero
  csrw fflags, zero
  fdiv.s ft2, ft0, ft1, rne
  fclass.s t1, ft2
  li t2, 512
  bne t1, t2, fail_fdiv_s_zero_zero
  csrr t1, fflags
  li t2, 16
  bne t1, t2, fail_fdiv_s_zero_zero_flags

  li t0, 1
  fmv.w.x ft0, t0
  li t0, 0x007fffff
  fmv.w.x ft1, t0
  csrw fflags, zero
  fdiv.s ft2, ft0, ft1, rne
  fmv.x.w t1, ft2
  li t2, 0x34000001
  bne t1, t2, fail_fdiv_s_residual_inexact
  csrr t1, fflags
  li t2, 1
  bne t1, t2, fail_fdiv_s_residual_inexact_flags

  li t0, 0x00800000
  fmv.w.x ft0, t0
  li t0, 0x40000000
  fmv.w.x ft1, t0
  csrw fflags, zero
  fdiv.s ft2, ft0, ft1, rne
  fmv.x.w t1, ft2
  li t2, 0x00400000
  bne t1, t2, fail_fdiv_s_exact_subnormal
  csrr t1, fflags
  bnez t1, fail_fdiv_s_exact_subnormal_flags

  fmv.w.x ft0, zero
  li t0, 0x7f800000
  fmv.w.x ft1, t0
  csrw fflags, zero
  fdiv.s ft2, ft0, ft1, rne
  fmv.x.w t1, ft2
  bnez t1, fail_fdiv_s_zero_inf
  csrr t1, fflags
  bnez t1, fail_fdiv_s_zero_inf_flags

  li t0, 0xbf800000
  fmv.w.x ft0, t0
  csrw fflags, zero
  fsqrt.s ft2, ft0, rne
  fclass.s t1, ft2
  li t2, 512
  bne t1, t2, fail_fsqrt_s_invalid
  csrr t1, fflags
  li t2, 16
  bne t1, t2, fail_fsqrt_s_invalid_flags

  la t0, d_zero
  fld ft0, 0(t0)
  li t0, 0x3f800000
  fmv.w.x ft1, t0
  csrw fflags, zero
  fdiv.s ft2, ft0, ft1, rne
  fclass.s t1, ft2
  li t2, 512
  bne t1, t2, fail_fdiv_s_unboxed_a
  csrr t1, fflags
  bnez t1, fail_fdiv_s_unboxed_a_flags

  li t0, 0x3f800000
  fmv.w.x ft0, t0
  la t0, d_zero
  fld ft1, 0(t0)
  csrw fflags, zero
  fdiv.s ft2, ft0, ft1, rne
  fclass.s t1, ft2
  li t2, 512
  bne t1, t2, fail_fdiv_s_unboxed_b
  csrr t1, fflags
  bnez t1, fail_fdiv_s_unboxed_b_flags

  la t0, d_zero
  fld ft0, 0(t0)
  csrw fflags, zero
  fsqrt.s ft2, ft0, rne
  fclass.s t1, ft2
  li t2, 512
  bne t1, t2, fail_fsqrt_s_unboxed
  csrr t1, fflags
  bnez t1, fail_fsqrt_s_unboxed_flags

  li t0, 0x3f800000
  fmv.w.x ft1, t0
  fsgnj.s ft2, ft0, ft1
  fclass.s t1, ft2
  li t2, 512
  bne t1, t2, fail_fsgnj_s_unboxed
  csrr t1, fflags
  bnez t1, fail_fsgnj_s_unboxed_flags

  la t0, d_six
  fld ft0, 0(t0)
  la t0, d_two
  fld ft1, 0(t0)
  csrw fflags, zero
  fdiv.d ft2, ft0, ft1, rne
  la t0, d_result
  fsd ft2, 0(t0)
  lw t1, 0(t0)
  bnez t1, fail_fdiv_d
  lw t1, 4(t0)
  li t2, 0x40080000
  bne t1, t2, fail_fdiv_d
  csrr t1, fflags
  bnez t1, fail_fdiv_d_flags

  la t0, d_nine
  fld ft0, 0(t0)
  csrw fflags, zero
  fsqrt.d ft2, ft0, rne
  la t0, d_result
  fsd ft2, 0(t0)
  lw t1, 0(t0)
  bnez t1, fail_fsqrt_d
  lw t1, 4(t0)
  li t2, 0x40080000
  bne t1, t2, fail_fsqrt_d
  csrr t1, fflags
  bnez t1, fail_fsqrt_d_flags

  la t0, d_six
  fld ft0, 0(t0)
  la t0, d_two
  fld ft1, 0(t0)
  csrw fflags, zero
  fdiv.d ft2, ft0, ft1, rne
  fdiv.d ft3, ft2, ft2, rne
  fsqrt.d ft4, ft3, rne
  la t0, d_result
  fsd ft4, 0(t0)
  lw t1, 0(t0)
  bnez t1, fail_fdivsqrt_d_chain
  lw t1, 4(t0)
  li t2, 0x3ff00000
  bne t1, t2, fail_fdivsqrt_d_chain
  csrr t1, fflags
  bnez t1, fail_fdivsqrt_d_chain_flags

  la t0, d_one
  fld ft0, 0(t0)
  la t0, d_three
  fld ft1, 0(t0)
  csrw fflags, zero
  fdiv.d ft2, ft0, ft1, rup
  la t0, d_result
  fsd ft2, 0(t0)
  lw t1, 0(t0)
  li t2, 0x55555556
  bne t1, t2, fail_fdiv_d_rup
  lw t1, 4(t0)
  li t2, 0x3fd55555
  bne t1, t2, fail_fdiv_d_rup
  csrr t1, fflags
  li t2, 1
  bne t1, t2, fail_fdiv_d_rup_flags

  csrw fflags, zero
  fdiv.d ft2, ft0, ft1, rmm
  la t0, d_result
  fsd ft2, 0(t0)
  lw t1, 0(t0)
  li t2, 0x55555555
  bne t1, t2, fail_fdiv_d_rmm
  lw t1, 4(t0)
  li t2, 0x3fd55555
  bne t1, t2, fail_fdiv_d_rmm
  csrr t1, fflags
  li t2, 1
  bne t1, t2, fail_fdiv_d_rmm_flags

  la t0, d_min_subnormal
  fld ft0, 0(t0)
  la t0, d_two
  fld ft1, 0(t0)
  csrw fflags, zero
  fdiv.d ft2, ft0, ft1, rne
  la t0, d_result
  fsd ft2, 0(t0)
  lw t1, 0(t0)
  bnez t1, fail_fdiv_d_rne_halfway
  lw t1, 4(t0)
  bnez t1, fail_fdiv_d_rne_halfway
  csrr t1, fflags
  li t2, 3
  bne t1, t2, fail_fdiv_d_rne_halfway_flags

  csrw fflags, zero
  fdiv.d ft2, ft0, ft1, rmm
  fsd ft2, 0(t0)
  lw t1, 0(t0)
  li t2, 1
  bne t1, t2, fail_fdiv_d_rmm_halfway
  lw t1, 4(t0)
  bnez t1, fail_fdiv_d_rmm_halfway
  csrr t1, fflags
  li t2, 3
  bne t1, t2, fail_fdiv_d_rmm_halfway_flags

  la t0, d_one
  fld ft0, 0(t0)
  la t0, d_zero
  fld ft1, 0(t0)
  csrw fflags, zero
  fdiv.d ft2, ft0, ft1, rne
  fclass.d t1, ft2
  li t2, 128
  bne t1, t2, fail_fdiv_d_dz
  csrr t1, fflags
  li t2, 8
  bne t1, t2, fail_fdiv_d_dz_flags

  la t0, d_zero
  fld ft0, 0(t0)
  fld ft1, 0(t0)
  csrw fflags, zero
  fdiv.d ft2, ft0, ft1, rne
  fclass.d t1, ft2
  li t2, 512
  bne t1, t2, fail_fdiv_d_zero_zero
  csrr t1, fflags
  li t2, 16
  bne t1, t2, fail_fdiv_d_zero_zero_flags

  la t0, d_min_subnormal
  fld ft0, 0(t0)
  la t0, d_max_subnormal
  fld ft1, 0(t0)
  csrw fflags, zero
  fdiv.d ft2, ft0, ft1, rne
  la t0, d_result
  fsd ft2, 0(t0)
  lw t1, 0(t0)
  li t2, 1
  bne t1, t2, fail_fdiv_d_residual_inexact
  lw t1, 4(t0)
  li t2, 0x3cb00000
  bne t1, t2, fail_fdiv_d_residual_inexact
  csrr t1, fflags
  li t2, 1
  bne t1, t2, fail_fdiv_d_residual_inexact_flags

  la t0, d_min_normal
  fld ft0, 0(t0)
  la t0, d_two
  fld ft1, 0(t0)
  csrw fflags, zero
  fdiv.d ft2, ft0, ft1, rne
  la t0, d_result
  fsd ft2, 0(t0)
  lw t1, 0(t0)
  bnez t1, fail_fdiv_d_exact_subnormal
  lw t1, 4(t0)
  li t2, 0x00080000
  bne t1, t2, fail_fdiv_d_exact_subnormal
  csrr t1, fflags
  bnez t1, fail_fdiv_d_exact_subnormal_flags

  la t0, d_zero
  fld ft0, 0(t0)
  la t0, d_infinity
  fld ft1, 0(t0)
  csrw fflags, zero
  fdiv.d ft2, ft0, ft1, rne
  la t0, d_result
  fsd ft2, 0(t0)
  lw t1, 0(t0)
  bnez t1, fail_fdiv_d_zero_inf
  lw t1, 4(t0)
  bnez t1, fail_fdiv_d_zero_inf
  csrr t1, fflags
  bnez t1, fail_fdiv_d_zero_inf_flags

  la t0, d_neg_one
  fld ft0, 0(t0)
  csrw fflags, zero
  fsqrt.d ft2, ft0, rne
  fclass.d t1, ft2
  li t2, 512
  bne t1, t2, fail_fsqrt_d_invalid
  csrr t1, fflags
  li t2, 16
  bne t1, t2, fail_fsqrt_d_invalid_flags

  la t0, d_one
  fld ft2, 0(t0)
  fld ft0, 0(t0)
  la t0, d_three
  fld ft1, 0(t0)
  csrw fflags, zero
  la t0, d_branch_zero
  lw t1, 0(t0)
  beqz t1, fdiv_flush_target
  fdiv.d ft2, ft0, ft1, rne
fdiv_flush_target:
  la t0, d_result
  fsd ft2, 0(t0)
  lw t1, 0(t0)
  bnez t1, fail_fdiv_flush_data
  lw t1, 4(t0)
  li t2, 0x3ff00000
  bne t1, t2, fail_fdiv_flush_data
  csrr t1, fflags
  bnez t1, fail_fdiv_flush_flags

  li t0, 0x4000
  csrw mstatus, t0
  li t0, 0x40c00000
  fmv.w.x ft0, t0
  li t0, 0x40000000
  fmv.w.x ft1, t0
  csrw fflags, zero
  fdiv.s ft2, ft0, ft1, rne
  csrr t1, fflags
  bnez t1, fail_fdiv_fs_flags
  csrr t1, mstatus
  li t2, 0x6000
  and t1, t1, t2
  bne t1, t2, fail_fdiv_fs_dirty

  li t0, 0x00100000
  li t1, 0x5555
  sw t1, 0(t0)

fail_fdiv_s:
  li t0, 0x00100000
  li t1, 0x00013333
  sw t1, 0(t0)
fail_fdiv_s_flags:
  li t0, 0x00100000
  li t1, 0x00023333
  sw t1, 0(t0)
fail_fsqrt_s:
  li t0, 0x00100000
  li t1, 0x00033333
  sw t1, 0(t0)
fail_fsqrt_s_flags:
  li t0, 0x00100000
  li t1, 0x00043333
  sw t1, 0(t0)
fail_fdivsqrt_s_chain:
  li t0, 0x00100000
  li t1, 0x00233333
  sw t1, 0(t0)
fail_fdivsqrt_s_chain_flags:
  li t0, 0x00100000
  li t1, 0x00243333
  sw t1, 0(t0)
fail_fdiv_s_dyn:
  li t0, 0x00100000
  li t1, 0x00053333
  sw t1, 0(t0)
fail_fdiv_s_dyn_flags:
  li t0, 0x00100000
  li t1, 0x00063333
  sw t1, 0(t0)
fail_fdiv_s_rup:
  li t0, 0x00100000
  li t1, 0x00153333
  sw t1, 0(t0)
fail_fdiv_s_rup_flags:
  li t0, 0x00100000
  li t1, 0x00163333
  sw t1, 0(t0)
fail_fdiv_s_rmm:
  li t0, 0x00100000
  li t1, 0x00173333
  sw t1, 0(t0)
fail_fdiv_s_rmm_flags:
  li t0, 0x00100000
  li t1, 0x00183333
  sw t1, 0(t0)
fail_fdiv_s_rne_halfway:
  li t0, 0x00100000
  li t1, 0x002b3333
  sw t1, 0(t0)
fail_fdiv_s_rne_halfway_flags:
  li t0, 0x00100000
  li t1, 0x002c3333
  sw t1, 0(t0)
fail_fdiv_s_rmm_halfway:
  li t0, 0x00100000
  li t1, 0x002d3333
  sw t1, 0(t0)
fail_fdiv_s_rmm_halfway_flags:
  li t0, 0x00100000
  li t1, 0x002e3333
  sw t1, 0(t0)
fail_fdiv_s_dz:
  li t0, 0x00100000
  li t1, 0x00073333
  sw t1, 0(t0)
fail_fdiv_s_dz_flags:
  li t0, 0x00100000
  li t1, 0x00083333
  sw t1, 0(t0)
fail_fdiv_s_zero_zero:
  li t0, 0x00100000
  li t1, 0x00333333
  sw t1, 0(t0)
fail_fdiv_s_zero_zero_flags:
  li t0, 0x00100000
  li t1, 0x00343333
  sw t1, 0(t0)
fail_fdiv_s_residual_inexact:
  li t0, 0x00100000
  li t1, 0x00373333
  sw t1, 0(t0)
fail_fdiv_s_residual_inexact_flags:
  li t0, 0x00100000
  li t1, 0x00383333
  sw t1, 0(t0)
fail_fdiv_s_exact_subnormal:
  li t0, 0x00100000
  li t1, 0x00393333
  sw t1, 0(t0)
fail_fdiv_s_exact_subnormal_flags:
  li t0, 0x00100000
  li t1, 0x003a3333
  sw t1, 0(t0)
fail_fdiv_s_zero_inf:
  li t0, 0x00100000
  li t1, 0x003b3333
  sw t1, 0(t0)
fail_fdiv_s_zero_inf_flags:
  li t0, 0x00100000
  li t1, 0x003c3333
  sw t1, 0(t0)
fail_fsqrt_s_invalid:
  li t0, 0x00100000
  li t1, 0x00093333
  sw t1, 0(t0)
fail_fsqrt_s_invalid_flags:
  li t0, 0x00100000
  li t1, 0x000a3333
  sw t1, 0(t0)
fail_fdiv_s_unboxed_a:
  li t0, 0x00100000
  li t1, 0x001d3333
  sw t1, 0(t0)
fail_fdiv_s_unboxed_a_flags:
  li t0, 0x00100000
  li t1, 0x001e3333
  sw t1, 0(t0)
fail_fdiv_s_unboxed_b:
  li t0, 0x00100000
  li t1, 0x001f3333
  sw t1, 0(t0)
fail_fdiv_s_unboxed_b_flags:
  li t0, 0x00100000
  li t1, 0x00203333
  sw t1, 0(t0)
fail_fsqrt_s_unboxed:
  li t0, 0x00100000
  li t1, 0x00213333
  sw t1, 0(t0)
fail_fsqrt_s_unboxed_flags:
  li t0, 0x00100000
  li t1, 0x00223333
  sw t1, 0(t0)
fail_fsgnj_s_unboxed:
  li t0, 0x00100000
  li t1, 0x00273333
  sw t1, 0(t0)
fail_fsgnj_s_unboxed_flags:
  li t0, 0x00100000
  li t1, 0x00283333
  sw t1, 0(t0)
fail_fdiv_d:
  li t0, 0x00100000
  li t1, 0x000b3333
  sw t1, 0(t0)
fail_fdiv_d_flags:
  li t0, 0x00100000
  li t1, 0x000c3333
  sw t1, 0(t0)
fail_fsqrt_d:
  li t0, 0x00100000
  li t1, 0x000d3333
  sw t1, 0(t0)
fail_fsqrt_d_flags:
  li t0, 0x00100000
  li t1, 0x000e3333
  sw t1, 0(t0)
fail_fdivsqrt_d_chain:
  li t0, 0x00100000
  li t1, 0x00253333
  sw t1, 0(t0)
fail_fdivsqrt_d_chain_flags:
  li t0, 0x00100000
  li t1, 0x00263333
  sw t1, 0(t0)
fail_fdiv_d_rup:
  li t0, 0x00100000
  li t1, 0x00193333
  sw t1, 0(t0)
fail_fdiv_d_rup_flags:
  li t0, 0x00100000
  li t1, 0x001a3333
  sw t1, 0(t0)
fail_fdiv_d_rmm:
  li t0, 0x00100000
  li t1, 0x001b3333
  sw t1, 0(t0)
fail_fdiv_d_rmm_flags:
  li t0, 0x00100000
  li t1, 0x001c3333
  sw t1, 0(t0)
fail_fdiv_d_rne_halfway:
  li t0, 0x00100000
  li t1, 0x002f3333
  sw t1, 0(t0)
fail_fdiv_d_rne_halfway_flags:
  li t0, 0x00100000
  li t1, 0x00303333
  sw t1, 0(t0)
fail_fdiv_d_rmm_halfway:
  li t0, 0x00100000
  li t1, 0x00313333
  sw t1, 0(t0)
fail_fdiv_d_rmm_halfway_flags:
  li t0, 0x00100000
  li t1, 0x00323333
  sw t1, 0(t0)
fail_fdiv_d_dz:
  li t0, 0x00100000
  li t1, 0x000f3333
  sw t1, 0(t0)
fail_fdiv_d_dz_flags:
  li t0, 0x00100000
  li t1, 0x00103333
  sw t1, 0(t0)
fail_fdiv_d_zero_zero:
  li t0, 0x00100000
  li t1, 0x00353333
  sw t1, 0(t0)
fail_fdiv_d_zero_zero_flags:
  li t0, 0x00100000
  li t1, 0x00363333
  sw t1, 0(t0)
fail_fdiv_d_residual_inexact:
  li t0, 0x00100000
  li t1, 0x003d3333
  sw t1, 0(t0)
fail_fdiv_d_residual_inexact_flags:
  li t0, 0x00100000
  li t1, 0x003e3333
  sw t1, 0(t0)
fail_fdiv_d_exact_subnormal:
  li t0, 0x00100000
  li t1, 0x003f3333
  sw t1, 0(t0)
fail_fdiv_d_exact_subnormal_flags:
  li t0, 0x00100000
  li t1, 0x00403333
  sw t1, 0(t0)
fail_fdiv_d_zero_inf:
  li t0, 0x00100000
  li t1, 0x00413333
  sw t1, 0(t0)
fail_fdiv_d_zero_inf_flags:
  li t0, 0x00100000
  li t1, 0x00423333
  sw t1, 0(t0)
fail_fsqrt_d_invalid:
  li t0, 0x00100000
  li t1, 0x00113333
  sw t1, 0(t0)
fail_fsqrt_d_invalid_flags:
  li t0, 0x00100000
  li t1, 0x00123333
  sw t1, 0(t0)
fail_fdiv_flush_data:
  li t0, 0x00100000
  li t1, 0x00293333
  sw t1, 0(t0)
fail_fdiv_flush_flags:
  li t0, 0x00100000
  li t1, 0x002a3333
  sw t1, 0(t0)
fail_fdiv_fs_flags:
  li t0, 0x00100000
  li t1, 0x00133333
  sw t1, 0(t0)
fail_fdiv_fs_dirty:
  li t0, 0x00100000
  li t1, 0x00143333
  sw t1, 0(t0)

.section .data
.align 3
d_six:
  .dword 0x4018000000000000
d_two:
  .dword 0x4000000000000000
d_nine:
  .dword 0x4022000000000000
d_one:
  .dword 0x3ff0000000000000
d_three:
  .dword 0x4008000000000000
d_zero:
  .dword 0x0000000000000000
d_neg_one:
  .dword 0xbff0000000000000
d_min_subnormal:
  .dword 0x0000000000000001
d_max_subnormal:
  .dword 0x000fffffffffffff
d_min_normal:
  .dword 0x0010000000000000
d_infinity:
  .dword 0x7ff0000000000000
d_result:
  .dword 0
.align 6
d_branch_zero:
  .word 0