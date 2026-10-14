/* Per-instruction FP exception preservation in M/S/U Bare mode.
 * Default: F/D rounding operations, 168 RV32 / 216 RV64 probes per privilege.
 * FP_FAULT_HALF=1: 28 half-precision FS-Off / reserved-rounding probes.
 * Both retain literal encodings, fault metadata and register-state checks. */
#ifndef FP_FAULT_HALF
#define FP_FAULT_HALF 0
#endif
.option norvc
.option norelax
.macro probe encoding, frm, fsvalue, fixture
  la s3, \fixture
  fld ft0, 0(s3)
  fld ft2, 0(s2)
  li s9, ((\frm << 5) | 8)
  csrw fcsr, s9
  li a2, 0x13579
  li a3, 0x2468
  li t0, 0x12345678
  sw t0, 0(s1)
  li t0, 0x76543210
  sw t0, 4(s1)
  li s10, \fsvalue
  li s7, 1
  ecall
  li s7, 0
  la s5, 1f
1: .word \encoding
  addi s4, s4, 1
  bne s4, s6, fail
.endm

/* One legal control plus FS-Off and five reserved-rounding probes per form. */
.macro operation encoding, fixture
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word \encoding
  probe \encoding, 0, 0x0, \fixture
  probe (\encoding | 0x5000), 0, 0x4000, \fixture
  probe (\encoding | 0x6000), 0, 0x4000, \fixture
  .irp mode, 5, 6, 7
    probe (\encoding | 0x7000), \mode, 0x4000, \fixture
  .endr
.endm
.section .text
.globl _start
_start:
  la t0, trap
  csrw mtvec, t0
  csrw mie, zero
  csrw medeleg, zero
  csrw satp, zero
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
  li s0, 3
enter_mode:
  slli t0, s0, 11
  li t1, 0x6000
  or t0, t0, t1
  csrw mstatus, t0
  la t0, body
  csrw mepc, t0
  mret
body:
  la s1, scratch
  la s2, sentinel
  la s8, observed
  li s4, 0
  li s6, 0
  li s7, 0
#if FP_FAULT_HALF
  probe 0x00049107, 4, 0, half_nan
  probe 0x00049027, 4, 0, half_nan
  probe 0xe4000653, 4, 0, half_nan
  probe 0xf4068153, 4, 0, half_nan
  probe 0x40200153, 4, 0, half_nan
  probe 0x42200153, 4, 0, half_nan
  probe 0x44000153, 4, 0, single_nan
  probe 0x44100153, 4, 0, double_nan
  probe 0x40205153, 0, 0x4000, half_nan
  probe 0x40206153, 0, 0x4000, half_nan
  probe 0x40207153, 5, 0x4000, half_nan
  probe 0x40207153, 6, 0x4000, half_nan
  probe 0x40207153, 7, 0x4000, half_nan
  probe 0x42205153, 0, 0x4000, half_nan
  probe 0x42206153, 0, 0x4000, half_nan
  probe 0x42207153, 5, 0x4000, half_nan
  probe 0x42207153, 6, 0x4000, half_nan
  probe 0x42207153, 7, 0x4000, half_nan
  probe 0x44005153, 0, 0x4000, single_nan
  probe 0x44006153, 0, 0x4000, single_nan
  probe 0x44007153, 5, 0x4000, single_nan
  probe 0x44007153, 6, 0x4000, single_nan
  probe 0x44007153, 7, 0x4000, single_nan
  probe 0x44105153, 0, 0x4000, double_nan
  probe 0x44106153, 0, 0x4000, double_nan
  probe 0x44107153, 5, 0x4000, double_nan
  probe 0x44107153, 6, 0x4000, double_nan
  probe 0x44107153, 7, 0x4000, double_nan
#define FP_FAULT_COUNT 28
#else
  operation 0x153, single_nan  /* fadd.s */
  operation 0x8000153, single_nan  /* fsub.s */
  operation 0x10000153, single_nan  /* fmul.s */
  operation 0x18000153, single_nan  /* fdiv.s */
  operation 0x58000153, single_nan  /* fsqrt.s */
  operation 0x143, single_nan  /* fmadd.s */
  operation 0x147, single_nan  /* fmsub.s */
  operation 0x14b, single_nan  /* fnmsub.s */
  operation 0x14f, single_nan  /* fnmadd.s */
  operation 0xc0000653, single_nan  /* fcvt.w.s */
  operation 0xd0068153, single_nan  /* fcvt.s.w */
  operation 0xc0100653, single_nan  /* fcvt.wu.s */
  operation 0xd0168153, single_nan  /* fcvt.s.wu */
#if __riscv_xlen == 64
  operation 0xc0200653, single_nan  /* fcvt.l.s */
  operation 0xd0268153, single_nan  /* fcvt.s.l */
  operation 0xc0300653, single_nan  /* fcvt.lu.s */
  operation 0xd0368153, single_nan  /* fcvt.s.lu */
#endif
  operation 0x2000153, double_nan  /* fadd.d */
  operation 0xa000153, double_nan  /* fsub.d */
  operation 0x12000153, double_nan  /* fmul.d */
  operation 0x1a000153, double_nan  /* fdiv.d */
  operation 0x5a000153, double_nan  /* fsqrt.d */
  operation 0x2000143, double_nan  /* fmadd.d */
  operation 0x2000147, double_nan  /* fmsub.d */
  operation 0x200014b, double_nan  /* fnmsub.d */
  operation 0x200014f, double_nan  /* fnmadd.d */
  operation 0xc2000653, double_nan  /* fcvt.w.d */
  operation 0xd2068153, double_nan  /* fcvt.d.w */
  operation 0xc2100653, double_nan  /* fcvt.wu.d */
  operation 0xd2168153, double_nan  /* fcvt.d.wu */
#if __riscv_xlen == 64
  operation 0xc2200653, double_nan  /* fcvt.l.d */
  operation 0xd2268153, double_nan  /* fcvt.d.l */
  operation 0xc2300653, double_nan  /* fcvt.lu.d */
  operation 0xd2368153, double_nan  /* fcvt.d.lu */
#endif
  operation 0x40100153, double_nan  /* fcvt.s.d */
  operation 0x42000153, single_nan  /* fcvt.d.s */
#if __riscv_xlen == 64
#define FP_FAULT_COUNT 216
#else
#define FP_FAULT_COUNT 168
#endif
#endif
  li s7, 3
  ecall
  j fail
.balign 4
trap:
  csrr t0, mcause
  bnez s7, service
  li t1, 2
  bne t0, t1, fail
  csrr t0, mepc
  bne t0, s5, fail
  csrr t1, mtval
#if __riscv_xlen == 64
  lwu t2, 0(t0)
#else
  lw t2, 0(t0)
#endif
  bne t1, t2, fail
  csrr t0, mstatus
  li t1, 0x6000
  and t0, t0, t1
  bne t0, s10, fail
  li t0, 0x13579
  bne a2, t0, fail
  li t0, 0x4000
  csrs mstatus, t0
  csrr t0, fcsr
  bne t0, s9, fail
  fsd ft0, 0(s8)
  lw t0, 0(s8)
  lw t1, 0(s3)
  bne t0, t1, fail
  lw t0, 4(s8)
  lw t1, 4(s3)
  bne t0, t1, fail
  fsd ft2, 0(s8)
  lw t0, 0(s8)
  lw t1, 0(s2)
  bne t0, t1, fail
  lw t0, 4(s8)
  lw t1, 4(s2)
  bne t0, t1, fail
  lw t0, 0(s1)
  li t1, 0x12345678
  bne t0, t1, fail
  lw t0, 4(s1)
  li t1, 0x76543210
  bne t0, t1, fail
  addi s6, s6, 1
  j resume
service:
  addi t1, s0, 8
  bne t0, t1, fail
  li t0, 3
  beq s7, t0, next_mode
  li t0, 1
  bne s7, t0, fail
  li t0, 0x6000
  csrc mstatus, t0
  csrs mstatus, s10
resume:
  csrr t0, mepc
  addi t0, t0, 4
  csrw mepc, t0
  mret
next_mode:
  li t0, FP_FAULT_COUNT
  bne s6, t0, fail
  beqz s0, pass
  li t0, 3
  bne s0, t0, 1f
  li s0, 1
  j enter_mode
1:li s0, 0
  j enter_mode
pass:
  li a0, 0
  ebreak
1:j 1b
fail:
  li a0, 1
  ebreak
2:j 2b
.section .data
.balign 8
sentinel: .quad 0x0123456789abcdef
half_nan: .quad 0xffffffffffff7c01
single_nan: .quad 0xffffffff7f800001
double_nan: .quad 0x7ff0000000000001
scratch: .quad 0
observed: .quad 0
