/* Bare MPRV=S AMO PMP denial: both R/W are required; no rd/data changes. */
.option norvc
.option norelax
.section .text
.globl _start
.macro denied op
  li t0, 0x12345678
  sw t0, 0(s0)
  sw t0, 4(s0)
  fence iorw, iorw
  li t2, 0x55
  la s8, 1f
  mv s10, s7
  li t0, 0x20800
  csrw mstatus, t0
1: \op t2, t0, (s0)
  li t0, 0x20000
  csrc mstatus, t0
  addi s10, s10, 1
  bne s7, s10, fail
  li t0, 0x55
  bne t2, t0, fail
  li t1, 0x12345678
  lw t0, 0(s0)
  bne t0, t1, fail
  lw t0, 4(s0)
  bne t0, t1, fail
.endm
_start:
  la t0, machine_trap
  csrw mtvec, t0
  csrw medeleg, zero
  csrw mie, zero
  csrw satp, zero
  la s0, location
  srli t0, s0, 2
  csrw pmpaddr0, t0
  li t0, -1
  csrw pmpaddr1, t0
  li s7, 0
  li s5, 0
next_permissions:
  li t0, 0x1f18
  or t0, t0, s5
  csrw pmpcfg0, t0
  denied amoswap.w
  denied amoadd.w
  denied amoxor.w
  denied amoand.w
  denied amoor.w
  denied amomin.w
  denied amomax.w
  denied amominu.w
  denied amomaxu.w
#if __riscv_xlen == 64
  denied amoswap.d
  denied amoadd.d
  denied amoxor.d
  denied amoand.d
  denied amoor.d
  denied amomin.d
  denied amomax.d
  denied amominu.d
  denied amomaxu.d
#endif
  addi s5, s5, 1
  li t0, 2
  blt s5, t0, next_permissions
  li a0, 0
  ebreak
machine_trap:
  csrr t0, mcause
  li t1, 7
  bne t0, t1, fail
  csrr t0, mepc
  bne t0, s8, fail
  csrr t1, mtval
  bne t1, s0, fail
  addi s7, s7, 1
  addi t0, t0, 4
  csrw mepc, t0
  mret
fail:
  li a0, 1
  ebreak
  j fail
.section .data
.balign 8
location: .dword 0
