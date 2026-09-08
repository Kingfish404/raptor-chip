/* Per-instruction synchronous exception preservation, M/S/U on Bare RAM.
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
  li t0, 28
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
