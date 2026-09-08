/* F/D rounding-op FS-Off and reserved-rm rejection contract, M/S/U Bare.
 * 28 RV32 / 36 RV64 operation forms, six probes/form/privilege.
 * Positive controls require legal execution, not numeric correctness.
 * Handler enables FS only after checking exception metadata and entry FS;
 * inspecting a preserved register is separate from the faulting operation. */
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
  /* fadd.s: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0x153
  probe 0x153, 0, 0x0, single_nan
  probe 0x5153, 0, 0x4000, single_nan
  probe 0x6153, 0, 0x4000, single_nan
  probe 0x7153, 5, 0x4000, single_nan
  probe 0x7153, 6, 0x4000, single_nan
  probe 0x7153, 7, 0x4000, single_nan
  /* fsub.s: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0x8000153
  probe 0x8000153, 0, 0x0, single_nan
  probe 0x8005153, 0, 0x4000, single_nan
  probe 0x8006153, 0, 0x4000, single_nan
  probe 0x8007153, 5, 0x4000, single_nan
  probe 0x8007153, 6, 0x4000, single_nan
  probe 0x8007153, 7, 0x4000, single_nan
  /* fmul.s: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0x10000153
  probe 0x10000153, 0, 0x0, single_nan
  probe 0x10005153, 0, 0x4000, single_nan
  probe 0x10006153, 0, 0x4000, single_nan
  probe 0x10007153, 5, 0x4000, single_nan
  probe 0x10007153, 6, 0x4000, single_nan
  probe 0x10007153, 7, 0x4000, single_nan
  /* fdiv.s: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0x18000153
  probe 0x18000153, 0, 0x0, single_nan
  probe 0x18005153, 0, 0x4000, single_nan
  probe 0x18006153, 0, 0x4000, single_nan
  probe 0x18007153, 5, 0x4000, single_nan
  probe 0x18007153, 6, 0x4000, single_nan
  probe 0x18007153, 7, 0x4000, single_nan
  /* fsqrt.s: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0x58000153
  probe 0x58000153, 0, 0x0, single_nan
  probe 0x58005153, 0, 0x4000, single_nan
  probe 0x58006153, 0, 0x4000, single_nan
  probe 0x58007153, 5, 0x4000, single_nan
  probe 0x58007153, 6, 0x4000, single_nan
  probe 0x58007153, 7, 0x4000, single_nan
  /* fmadd.s: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0x143
  probe 0x143, 0, 0x0, single_nan
  probe 0x5143, 0, 0x4000, single_nan
  probe 0x6143, 0, 0x4000, single_nan
  probe 0x7143, 5, 0x4000, single_nan
  probe 0x7143, 6, 0x4000, single_nan
  probe 0x7143, 7, 0x4000, single_nan
  /* fmsub.s: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0x147
  probe 0x147, 0, 0x0, single_nan
  probe 0x5147, 0, 0x4000, single_nan
  probe 0x6147, 0, 0x4000, single_nan
  probe 0x7147, 5, 0x4000, single_nan
  probe 0x7147, 6, 0x4000, single_nan
  probe 0x7147, 7, 0x4000, single_nan
  /* fnmsub.s: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0x14b
  probe 0x14b, 0, 0x0, single_nan
  probe 0x514b, 0, 0x4000, single_nan
  probe 0x614b, 0, 0x4000, single_nan
  probe 0x714b, 5, 0x4000, single_nan
  probe 0x714b, 6, 0x4000, single_nan
  probe 0x714b, 7, 0x4000, single_nan
  /* fnmadd.s: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0x14f
  probe 0x14f, 0, 0x0, single_nan
  probe 0x514f, 0, 0x4000, single_nan
  probe 0x614f, 0, 0x4000, single_nan
  probe 0x714f, 5, 0x4000, single_nan
  probe 0x714f, 6, 0x4000, single_nan
  probe 0x714f, 7, 0x4000, single_nan
  /* fcvt.w.s: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0xc0000653
  probe 0xc0000653, 0, 0x0, single_nan
  probe 0xc0005653, 0, 0x4000, single_nan
  probe 0xc0006653, 0, 0x4000, single_nan
  probe 0xc0007653, 5, 0x4000, single_nan
  probe 0xc0007653, 6, 0x4000, single_nan
  probe 0xc0007653, 7, 0x4000, single_nan
  /* fcvt.s.w: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0xd0068153
  probe 0xd0068153, 0, 0x0, single_nan
  probe 0xd006d153, 0, 0x4000, single_nan
  probe 0xd006e153, 0, 0x4000, single_nan
  probe 0xd006f153, 5, 0x4000, single_nan
  probe 0xd006f153, 6, 0x4000, single_nan
  probe 0xd006f153, 7, 0x4000, single_nan
  /* fcvt.wu.s: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0xc0100653
  probe 0xc0100653, 0, 0x0, single_nan
  probe 0xc0105653, 0, 0x4000, single_nan
  probe 0xc0106653, 0, 0x4000, single_nan
  probe 0xc0107653, 5, 0x4000, single_nan
  probe 0xc0107653, 6, 0x4000, single_nan
  probe 0xc0107653, 7, 0x4000, single_nan
  /* fcvt.s.wu: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0xd0168153
  probe 0xd0168153, 0, 0x0, single_nan
  probe 0xd016d153, 0, 0x4000, single_nan
  probe 0xd016e153, 0, 0x4000, single_nan
  probe 0xd016f153, 5, 0x4000, single_nan
  probe 0xd016f153, 6, 0x4000, single_nan
  probe 0xd016f153, 7, 0x4000, single_nan
#if __riscv_xlen == 64
  /* fcvt.l.s: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0xc0200653
  probe 0xc0200653, 0, 0x0, single_nan
  probe 0xc0205653, 0, 0x4000, single_nan
  probe 0xc0206653, 0, 0x4000, single_nan
  probe 0xc0207653, 5, 0x4000, single_nan
  probe 0xc0207653, 6, 0x4000, single_nan
  probe 0xc0207653, 7, 0x4000, single_nan
#endif
#if __riscv_xlen == 64
  /* fcvt.s.l: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0xd0268153
  probe 0xd0268153, 0, 0x0, single_nan
  probe 0xd026d153, 0, 0x4000, single_nan
  probe 0xd026e153, 0, 0x4000, single_nan
  probe 0xd026f153, 5, 0x4000, single_nan
  probe 0xd026f153, 6, 0x4000, single_nan
  probe 0xd026f153, 7, 0x4000, single_nan
#endif
#if __riscv_xlen == 64
  /* fcvt.lu.s: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0xc0300653
  probe 0xc0300653, 0, 0x0, single_nan
  probe 0xc0305653, 0, 0x4000, single_nan
  probe 0xc0306653, 0, 0x4000, single_nan
  probe 0xc0307653, 5, 0x4000, single_nan
  probe 0xc0307653, 6, 0x4000, single_nan
  probe 0xc0307653, 7, 0x4000, single_nan
#endif
#if __riscv_xlen == 64
  /* fcvt.s.lu: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0xd0368153
  probe 0xd0368153, 0, 0x0, single_nan
  probe 0xd036d153, 0, 0x4000, single_nan
  probe 0xd036e153, 0, 0x4000, single_nan
  probe 0xd036f153, 5, 0x4000, single_nan
  probe 0xd036f153, 6, 0x4000, single_nan
  probe 0xd036f153, 7, 0x4000, single_nan
#endif
  /* fadd.d: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0x2000153
  probe 0x2000153, 0, 0x0, double_nan
  probe 0x2005153, 0, 0x4000, double_nan
  probe 0x2006153, 0, 0x4000, double_nan
  probe 0x2007153, 5, 0x4000, double_nan
  probe 0x2007153, 6, 0x4000, double_nan
  probe 0x2007153, 7, 0x4000, double_nan
  /* fsub.d: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0xa000153
  probe 0xa000153, 0, 0x0, double_nan
  probe 0xa005153, 0, 0x4000, double_nan
  probe 0xa006153, 0, 0x4000, double_nan
  probe 0xa007153, 5, 0x4000, double_nan
  probe 0xa007153, 6, 0x4000, double_nan
  probe 0xa007153, 7, 0x4000, double_nan
  /* fmul.d: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0x12000153
  probe 0x12000153, 0, 0x0, double_nan
  probe 0x12005153, 0, 0x4000, double_nan
  probe 0x12006153, 0, 0x4000, double_nan
  probe 0x12007153, 5, 0x4000, double_nan
  probe 0x12007153, 6, 0x4000, double_nan
  probe 0x12007153, 7, 0x4000, double_nan
  /* fdiv.d: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0x1a000153
  probe 0x1a000153, 0, 0x0, double_nan
  probe 0x1a005153, 0, 0x4000, double_nan
  probe 0x1a006153, 0, 0x4000, double_nan
  probe 0x1a007153, 5, 0x4000, double_nan
  probe 0x1a007153, 6, 0x4000, double_nan
  probe 0x1a007153, 7, 0x4000, double_nan
  /* fsqrt.d: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0x5a000153
  probe 0x5a000153, 0, 0x0, double_nan
  probe 0x5a005153, 0, 0x4000, double_nan
  probe 0x5a006153, 0, 0x4000, double_nan
  probe 0x5a007153, 5, 0x4000, double_nan
  probe 0x5a007153, 6, 0x4000, double_nan
  probe 0x5a007153, 7, 0x4000, double_nan
  /* fmadd.d: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0x2000143
  probe 0x2000143, 0, 0x0, double_nan
  probe 0x2005143, 0, 0x4000, double_nan
  probe 0x2006143, 0, 0x4000, double_nan
  probe 0x2007143, 5, 0x4000, double_nan
  probe 0x2007143, 6, 0x4000, double_nan
  probe 0x2007143, 7, 0x4000, double_nan
  /* fmsub.d: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0x2000147
  probe 0x2000147, 0, 0x0, double_nan
  probe 0x2005147, 0, 0x4000, double_nan
  probe 0x2006147, 0, 0x4000, double_nan
  probe 0x2007147, 5, 0x4000, double_nan
  probe 0x2007147, 6, 0x4000, double_nan
  probe 0x2007147, 7, 0x4000, double_nan
  /* fnmsub.d: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0x200014b
  probe 0x200014b, 0, 0x0, double_nan
  probe 0x200514b, 0, 0x4000, double_nan
  probe 0x200614b, 0, 0x4000, double_nan
  probe 0x200714b, 5, 0x4000, double_nan
  probe 0x200714b, 6, 0x4000, double_nan
  probe 0x200714b, 7, 0x4000, double_nan
  /* fnmadd.d: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0x200014f
  probe 0x200014f, 0, 0x0, double_nan
  probe 0x200514f, 0, 0x4000, double_nan
  probe 0x200614f, 0, 0x4000, double_nan
  probe 0x200714f, 5, 0x4000, double_nan
  probe 0x200714f, 6, 0x4000, double_nan
  probe 0x200714f, 7, 0x4000, double_nan
  /* fcvt.w.d: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0xc2000653
  probe 0xc2000653, 0, 0x0, double_nan
  probe 0xc2005653, 0, 0x4000, double_nan
  probe 0xc2006653, 0, 0x4000, double_nan
  probe 0xc2007653, 5, 0x4000, double_nan
  probe 0xc2007653, 6, 0x4000, double_nan
  probe 0xc2007653, 7, 0x4000, double_nan
  /* fcvt.d.w: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0xd2068153
  probe 0xd2068153, 0, 0x0, double_nan
  probe 0xd206d153, 0, 0x4000, double_nan
  probe 0xd206e153, 0, 0x4000, double_nan
  probe 0xd206f153, 5, 0x4000, double_nan
  probe 0xd206f153, 6, 0x4000, double_nan
  probe 0xd206f153, 7, 0x4000, double_nan
  /* fcvt.wu.d: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0xc2100653
  probe 0xc2100653, 0, 0x0, double_nan
  probe 0xc2105653, 0, 0x4000, double_nan
  probe 0xc2106653, 0, 0x4000, double_nan
  probe 0xc2107653, 5, 0x4000, double_nan
  probe 0xc2107653, 6, 0x4000, double_nan
  probe 0xc2107653, 7, 0x4000, double_nan
  /* fcvt.d.wu: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0xd2168153
  probe 0xd2168153, 0, 0x0, double_nan
  probe 0xd216d153, 0, 0x4000, double_nan
  probe 0xd216e153, 0, 0x4000, double_nan
  probe 0xd216f153, 5, 0x4000, double_nan
  probe 0xd216f153, 6, 0x4000, double_nan
  probe 0xd216f153, 7, 0x4000, double_nan
#if __riscv_xlen == 64
  /* fcvt.l.d: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0xc2200653
  probe 0xc2200653, 0, 0x0, double_nan
  probe 0xc2205653, 0, 0x4000, double_nan
  probe 0xc2206653, 0, 0x4000, double_nan
  probe 0xc2207653, 5, 0x4000, double_nan
  probe 0xc2207653, 6, 0x4000, double_nan
  probe 0xc2207653, 7, 0x4000, double_nan
#endif
#if __riscv_xlen == 64
  /* fcvt.d.l: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0xd2268153
  probe 0xd2268153, 0, 0x0, double_nan
  probe 0xd226d153, 0, 0x4000, double_nan
  probe 0xd226e153, 0, 0x4000, double_nan
  probe 0xd226f153, 5, 0x4000, double_nan
  probe 0xd226f153, 6, 0x4000, double_nan
  probe 0xd226f153, 7, 0x4000, double_nan
#endif
#if __riscv_xlen == 64
  /* fcvt.lu.d: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0xc2300653
  probe 0xc2300653, 0, 0x0, double_nan
  probe 0xc2305653, 0, 0x4000, double_nan
  probe 0xc2306653, 0, 0x4000, double_nan
  probe 0xc2307653, 5, 0x4000, double_nan
  probe 0xc2307653, 6, 0x4000, double_nan
  probe 0xc2307653, 7, 0x4000, double_nan
#endif
#if __riscv_xlen == 64
  /* fcvt.d.lu: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0xd2368153
  probe 0xd2368153, 0, 0x0, double_nan
  probe 0xd236d153, 0, 0x4000, double_nan
  probe 0xd236e153, 0, 0x4000, double_nan
  probe 0xd236f153, 5, 0x4000, double_nan
  probe 0xd236f153, 6, 0x4000, double_nan
  probe 0xd236f153, 7, 0x4000, double_nan
#endif
  /* fcvt.s.d: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0x40100153
  probe 0x40100153, 0, 0x0, double_nan
  probe 0x40105153, 0, 0x4000, double_nan
  probe 0x40106153, 0, 0x4000, double_nan
  probe 0x40107153, 5, 0x4000, double_nan
  probe 0x40107153, 6, 0x4000, double_nan
  probe 0x40107153, 7, 0x4000, double_nan
  /* fcvt.d.s: legal control, FS-Off, five reserved modes. */
  csrw fcsr, zero
  fld ft0, 0(s2)
  .word 0x42000153
  probe 0x42000153, 0, 0x0, single_nan
  probe 0x42005153, 0, 0x4000, single_nan
  probe 0x42006153, 0, 0x4000, single_nan
  probe 0x42007153, 5, 0x4000, single_nan
  probe 0x42007153, 6, 0x4000, single_nan
  probe 0x42007153, 7, 0x4000, single_nan
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
#if __riscv_xlen == 64
  li t0, 216
#else
  li t0, 168
#endif
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
