.section .text
.globl _start
_start:
  li s0, 0
  li t0, 0x6000
  csrs mstatus, t0

  la t0, trap_handler
  csrw mtvec, t0

  li t0, 5
  csrw frm, t0
  li t0, 0x3f800000
  fmv.w.x ft0, t0
  fmv.w.x ft1, t0

rm_dyn:
  .word 0x00107153

after_dyn:
  csrr t1, fflags
  bnez t1, fail_flags

  csrw frm, zero
rm_static:
  .word 0x00105153

after_static:
  csrr t1, fflags
  bnez t1, fail_flags

rm_fdiv_s_static:
  .word 0x18105153

after_fdiv_s_static:
  csrr t1, fflags
  bnez t1, fail_flags

rm_fsqrt_s_static:
  .word 0x58005153

after_fsqrt_s_static:
  csrr t1, fflags
  bnez t1, fail_flags

rm_fdiv_d_static:
  .word 0x1a105153

after_fdiv_d_static:
  csrr t1, fflags
  bnez t1, fail_flags

rm_fsqrt_d_static:
  .word 0x5a005153

after_fsqrt_d_static:
  csrr t1, fflags
  bnez t1, fail_flags

  li t0, 5
  csrw frm, t0
rm_fcvt_dyn:
  .word 0xc0007353

after_fcvt_dyn:
  csrr t1, fflags
  bnez t1, fail_flags

  csrw frm, zero
rm_fcvt_static:
  .word 0xc0005353

after_fcvt_static:
  csrr t1, fflags
  bnez t1, fail_flags

rm_fcvt_s_d_static:
  .word 0x401050d3

after_fcvt_s_d_static:
  csrr t1, fflags
  bnez t1, fail_flags

rm_fcvt_d_s_static:
  .word 0x420050d3

after_fcvt_d_s_static:
  csrr t1, fflags
  bnez t1, fail_flags
#if __riscv_xlen == 32
rv32_fcvt_l:
  .word 0xc0200353

after_rv32_fcvt_l:
  csrr t1, fflags
  bnez t1, fail_flags
  li t1, 11
#else
  li t1, 10
#endif
  bne s0, t1, fail_count

  li t0, 0x00100000
  li t1, 0x5555
  sw t1, 0(t0)

trap_handler:
  csrr t0, mcause
  li t1, 2
  bne t0, t1, fail_cause

  csrr t0, mtval
  beqz s0, check_dyn_tval
  li t1, 1
  beq s0, t1, check_static_tval
  li t1, 2
  beq s0, t1, check_fdiv_s_static_tval
  li t1, 3
  beq s0, t1, check_fsqrt_s_static_tval
  li t1, 4
  beq s0, t1, check_fdiv_d_static_tval
  li t1, 5
  beq s0, t1, check_fsqrt_d_static_tval
  li t1, 6
  beq s0, t1, check_fcvt_dyn_tval
  li t1, 7
  beq s0, t1, check_fcvt_static_tval
  li t1, 8
  beq s0, t1, check_fcvt_s_d_static_tval
  li t1, 9
  beq s0, t1, check_fcvt_d_s_static_tval
#if __riscv_xlen == 32
  li t1, 10
  beq s0, t1, check_rv32_fcvt_l_tval
#endif
  li t1, 0xc0005353
  bne t0, t1, fail_tval
  j advance_mepc

check_static_tval:
  li t1, 0x00105153
  bne t0, t1, fail_tval
  j advance_mepc

check_dyn_tval:
  li t1, 0x00107153
  bne t0, t1, fail_tval
  j advance_mepc

check_fdiv_s_static_tval:
  li t1, 0x18105153
  bne t0, t1, fail_tval
  j advance_mepc

check_fsqrt_s_static_tval:
  li t1, 0x58005153
  bne t0, t1, fail_tval
  j advance_mepc

check_fdiv_d_static_tval:
  li t1, 0x1a105153
  bne t0, t1, fail_tval
  j advance_mepc

check_fsqrt_d_static_tval:
  li t1, 0x5a005153
  bne t0, t1, fail_tval
  j advance_mepc

check_fcvt_dyn_tval:
  li t1, 0xc0007353
  bne t0, t1, fail_tval
  j advance_mepc

check_fcvt_static_tval:
  li t1, 0xc0005353
  bne t0, t1, fail_tval
  j advance_mepc

check_fcvt_s_d_static_tval:
  li t1, 0x401050d3
  bne t0, t1, fail_tval
  j advance_mepc

check_fcvt_d_s_static_tval:
  li t1, 0x420050d3
  bne t0, t1, fail_tval
  j advance_mepc

#if __riscv_xlen == 32
check_rv32_fcvt_l_tval:
  li t1, 0xc0200353
  bne t0, t1, fail_tval
#endif

advance_mepc:
  csrr t0, mepc
  addi t0, t0, 4
  csrw mepc, t0
  addi s0, s0, 1
  mret

fail_flags:
  li t0, 0x00100000
  li t1, 0x00013333
  sw t1, 0(t0)

fail_count:
  li t0, 0x00100000
  li t1, 0x00023333
  sw t1, 0(t0)

fail_cause:
  li t0, 0x00100000
  li t1, 0x00033333
  sw t1, 0(t0)

fail_tval:
  beqz t0, fail_tval_zero
  li t0, 0x00100000
  li t1, 0x00043333
  sw t1, 0(t0)
fail_tval_zero:
  li t0, 0x00100000
  li t1, 0x003d3333
  sw t1, 0(t0)