/* FS access control and state changes in M/S/U, Bare, both XLENs.
 * ECALL services only change FS or check Dirty; FP instructions execute
 * in the selected privilege. Illegal cases check cause, PC, instruction
 * bits (the Raptor trap-value contract), and unchanged destination/memory.
 */
.option norvc
.option norelax
.section .text
.globl _start
.macro service n
  li s7, \n
  ecall
  li s7, 0
.endm
.macro denied insn:vararg
  la s5, 1f
1: \insn
  addi s4, s4, 1
  bne s4, s6, fail
.endm
.macro dirty insn:vararg
  service 1
  \insn
  service 2
.endm
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
  csrw mstatus, t0
  la t0, body
  csrw mepc, t0
  mret
body:
  li s4, 0
  li s6, 0
  li s7, 0
  la s1, scratch
  li a2, 0x123
  li a3, 0x123
  denied csrr a2, fflags
  denied csrr a2, frm
  denied csrr a2, fcsr
  denied csrw fflags, a3
  denied csrw frm, a3
  denied csrw fcsr, a3
  denied csrsi fflags, 1
  denied csrci frm, 1
  denied csrrwi a2, fcsr, 0
  denied fmv.w.x f0, a3
  denied fmv.x.w a2, f0
  denied fmv.h.x f0, a3
  denied fmv.x.h a2, f0
  denied fcvt.s.h f0, f0
  denied fcvt.d.h f0, f0
  denied fcvt.h.s f0, f0
  denied fcvt.h.d f0, f0
  denied fadd.s f0, f0, f0
  denied fadd.d f0, f0, f0
  denied flw f0, 0(s1)
  denied fld f0, 0(s1)
  denied flh f0, 0(s1)
  denied fsw f0, 0(s1)
  denied fsd f0, 0(s1)
  denied fsh f0, 0(s1)
  bne a2, a3, fail
  lw t0, 0(s1)
  li t1, 0x12345678
  bne t0, t1, fail
  /* These instructions change FP state, so Dirty is required. Do not
   * demand precise Clean tracking for read-only/no-change operations. */
  service 1
  csrwi fcsr, 31
  dirty csrw fcsr, zero
  dirty csrsi fflags, 1
  dirty csrrwi zero, frm, 2
  dirty fmv.w.x f0, a3
  dirty fld f0, 0(s1)
  dirty flh f0, 0(s1)
  /* A signaling NaN comparison changes flags without an FP destination. */
  service 1
  li t0, 0x7f800001
  fmv.w.x f0, t0
  csrw fcsr, zero
  service 1
  feq.s a2, f0, f0
  service 2
  csrr t0, fflags
  li t1, 16
  bne t0, t1, fail
  /* FS=Off/Initial must not erase the register file or FCSR. */
  li t0, 0x345
  fmv.w.x f0, t0
  li t0, 0x43
  csrw fcsr, t0
  service 4
  service 5
  fmv.x.w t0, f0
  li t1, 0x345
  bne t0, t1, fail
  csrr t0, fcsr
  li t1, 0x43
  bne t0, t1, fail
  service 3
  j fail
.balign 4
trap:
  csrr t0, mcause
  bnez s7, handle_service
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
  csrr t1, mstatus
  li t2, 0x6000
  and t1, t1, t2
  bnez t1, fail
  addi s6, s6, 1
  j resume
handle_service:
  addi t1, s0, 8       /* U=8, S=9, M=11 */
  bne t0, t1, fail
  li t0, 3
  beq s7, t0, next_mode
  li t0, 2
  bne s7, t0, set_fs
  csrr t0, mstatus
  li t1, 0x6000
  and t2, t0, t1
  bne t2, t1, fail
  bgez t0, fail        /* SD must summarize Dirty. */
set_fs:
  li t0, 0x6000
  csrc mstatus, t0
  li t0, 4
  beq s7, t0, resume
  li t1, 0x4000       /* Clean */
  li t0, 5
  bne s7, t0, 1f
  li t1, 0x2000       /* Initial */
1: csrs mstatus, t1
resume:
  csrr t0, mepc
  addi t0, t0, 4
  csrw mepc, t0
  mret
next_mode:
  li t0, 25
  bne s6, t0, fail
  beqz s0, pass
  li t0, 3
  bne s0, t0, 1f
  li s0, 1
  j enter_mode
1: li s0, 0
  j enter_mode
pass:
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
  j fail
.section .data
.balign 8
scratch:
  .word 0x12345678, 0x3ff00000
