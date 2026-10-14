/* AMO fault classification, write permission and no write/rd side effects. */
#include "page_fault_macros.h"
.option norvc
.option norelax
.section .text
.globl _start
.macro fault_amo op
  li t0, 0x12345678
  REG_S t0, 0(s0)
  fence iorw, iorw
  li s6, 15
  la s8, 1f
  li s9, 0x40000000
  li t2, 0x55
  mv s10, s7
1: \op t2, t0, (s9)
  addi s10, s10, 1
  bne s7, s10, fail
  li t0, 0x55
  bne t2, t0, fail
  lw t0, 0(s0)
  li t1, 0x12345678
  bne t0, t1, fail
.endm
_start:
  la t0, machine_trap
  csrw mtvec, t0
  csrw medeleg, zero
  csrw mie, zero
  li t0, -1
  csrw pmpaddr1, t0
  li t0, 0x20000000
  csrw pmpaddr0, t0
  /* Deny low physical addresses, including the test VA. Its translated
   * PA and the page tables are above 0x80000000 and permitted by entry 1. */
  li t0, 0x1f08
  csrw pmpcfg0, t0
  map_two_pages_and_enter_s
supervisor:
  la s0, page_a
  la s1, level0
  li s7, 0
  /* Each denied PTE tests every AMO opcode, W and (RV64) D. */
  li s5, 0
next_permissions:
  la t0, flags
  add t0, t0, s5
  lbu s4, 0(t0)
  la t0, page_a
  srli t0, t0, 2
  or t0, t0, s4
  REG_S t0, 0(s1)
  sfence.vma
  fault_amo amoswap.w
  fault_amo amoadd.w
  fault_amo amoxor.w
  fault_amo amoand.w
  fault_amo amoor.w
  fault_amo amomin.w
  fault_amo amomax.w
  fault_amo amominu.w
  fault_amo amomaxu.w
#if __riscv_xlen == 64
  fault_amo amoswap.d
  fault_amo amoadd.d
  fault_amo amoxor.d
  fault_amo amoand.d
  fault_amo amoor.d
  fault_amo amomin.d
  fault_amo amomax.d
  fault_amo amominu.d
  fault_amo amomaxu.d
#endif
  addi s5, s5, 1
  li t0, 5
  blt s5, t0, next_permissions
  /* Restore R/W A/D and check the same translated AMO path succeeds. */
  la t0, page_a
  srli t0, t0, 2
  ori t0, t0, 0xcf
  REG_S t0, 0(s1)
  sfence.vma
  li t0, 7
  sw t0, 0(s0)
  fence iorw, iorw
  li s9, 0x40000000
  li t1, 4
  amoadd.w t2, t1, (s9)
  bne t2, t0, fail
  fence iorw, iorw
  lw t0, 0(s0)
  li t1, 11
  bne t0, t1, fail
  ecall
  j fail
machine_trap:
  check_machine_page_fault
pass:
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
  j fail
.section .data
flags: .byte 0, 0xc9, 0xc3, 0x47, 0x87
.balign 4096
root: .zero 4096
level1: .zero 4096
level0: .zero 4096
page_a: .zero 4096
page_b: .zero 4096
