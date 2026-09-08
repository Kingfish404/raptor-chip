/* All 29 zero HPM counters/event selectors, both XLENs and M/S/U.
 * Machine writes must remain zero; user aliases are read-only and remain
 * inaccessible below M because their enable bits are WARL-zero.
 */
.option norvc
.option norelax
.macro denied insn:vararg
  li a1, 0x123
  la s5, 1f
1: \insn
  li t0, 0x123
  bne a1, t0, fail
  addi s4, s4, 1
  bne s4, s6, fail
.endm
.macro zero_csr csr
  csrrw a1, \csr, a2
  bnez a1, fail
  csrrs a1, \csr, a2
  bnez a1, fail
  csrrc a1, \csr, a2
  bnez a1, fail
  csrrwi a1, \csr, 31
  bnez a1, fail
  csrrsi a1, \csr, 31
  bnez a1, fail
  csrrci a1, \csr, 31
  bnez a1, fail
  csrr a1, \csr
  bnez a1, fail
.endm
.macro forbidden_csr csr
  denied csrrw a1, \csr, a2
  denied csrrs a1, \csr, a2
  denied csrrc a1, \csr, a2
  denied csrrwi a1, \csr, 31
  denied csrrsi a1, \csr, 31
  denied csrrci a1, \csr, 31
  denied csrr a1, \csr
.endm
.macro readonly_alias csr
  csrr a1, \csr
  bnez a1, fail
  csrrc a1, \csr, zero
  bnez a1, fail
  denied csrrw a1, \csr, a2
  denied csrrs a1, \csr, a2
  denied csrrc a1, \csr, a2
  denied csrrwi a1, \csr, 31
  denied csrrsi a1, \csr, 31
  denied csrrci a1, \csr, 31
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
  csrw mcounteren, t0
  csrw scounteren, t0
  csrr t0, mcounteren
  li t1, 7
  bne t0, t1, fail
  csrr t0, scounteren
  bne t0, t1, fail
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
  li a2, -1
  li t0, 3
  bne s0, t0, lower_mode
  .irp n,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    zero_csr (0xb00+\n)
    zero_csr (0x320+\n)
    readonly_alias (0xc00+\n)
#if __riscv_xlen == 32
    zero_csr (0xb80+\n)
    readonly_alias (0xc80+\n)
#else
    forbidden_csr (0xb80+\n)
    forbidden_csr (0xc80+\n)
#endif
  .endr
  j end_mode
lower_mode:
  .irp n,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    forbidden_csr (0xb00+\n)
    forbidden_csr (0x320+\n)
    forbidden_csr (0xc00+\n)
    forbidden_csr (0xb80+\n)
    forbidden_csr (0xc80+\n)
  .endr
end_mode:
  ecall
  j fail
.balign 4
trap:
  csrr t0, mcause
  li t1, 2
  bne t0, t1, switch_mode
  csrr t0, mepc
  bne t0, s5, fail
  csrr t1, mtval
#if __riscv_xlen == 64
  lwu t2, 0(t0)
#else
  lw t2, 0(t0)
#endif
  bne t1, t2, fail
  addi s6, s6, 1
  addi t0, t0, 4
  csrw mepc, t0
  mret
switch_mode:
  addi t1, s0, 8
  bne t0, t1, fail
  li t0, 3
  bne s0, t0, 1f
#if __riscv_xlen == 64
  li t0, 580 /* 29 * (6 read-only writes + 14 RV64 high-half traps) */
#else
  li t0, 348 /* 29 * 12 read-only alias writes */
#endif
  bne s6, t0, fail
  li s0, 1
  j enter_mode
1: li t0, 1015 /* 29 * 5 ranges * 7 CSR operations */
  bne s6, t0, fail
  beqz s0, pass
  li s0, 0
  j enter_mode
pass:
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
  j fail
