/* Broad external PMA windows may contain no target on this NPC platform. */
#if __riscv_xlen == 64
#define REG_S sd
#define SATP_MODE 0x8000000000000000
#else
#define REG_S sw
#define SATP_MODE 0x80000000
#endif
#ifdef RAPT_HALF_LOAD_ERROR
#include "fp_half_plic_state.h"
#define BARE_FAULT_COUNT 16
#define TOTAL_FAULT_COUNT 32
#else
#define BARE_FAULT_COUNT 8
#define TOTAL_FAULT_COUNT 16
#endif
.option norvc
.option norelax
.section .text
.globl _start
.macro fault_load op, reg
  la s8, 1f
  la s11, 2f
1:
  \op \reg, 0(s9)
2:
.endm
_start:
  la t0, machine_trap
  csrw mtvec, t0
  csrw medeleg, zero
  csrw mie, zero
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
  li t0, 0x6000
  csrw mstatus, t0
#ifdef RAPT_HALF_LOAD_ERROR
  half_plic_seed
#endif
  li s7, 0
  li s9, 0xc0001000
  jal ra, test_error
  li s9, 0x21000000
  jal ra, test_error
  li t0, BARE_FAULT_COUNT
  bne s7, t0, fail
  la s0, root
  li t0, 0x200000cf
#if __riscv_xlen == 64
  sd t0, 16(s0)
  la t0, level1
  srli t0, t0, 2
  ori t0, t0, 1
  sd t0, 8(s0)
  la t0, level0
  srli t0, t0, 2
  ori t0, t0, 1
  la t1, level1
  sd t0, 0(t1)
#else
  li t1, 2048
  add t1, s0, t1
  sw t0, 0(t1)
  la t0, level0
  srli t0, t0, 2
  ori t0, t0, 1
  sw t0, 1024(s0)
#endif
  la t1, level0
  li t0, 0x300004cf
  REG_S t0, 0(t1)
  li t0, 0x084000cf
  REG_S t0, (__riscv_xlen / 8)(t1)
  srli t0, s0, 12
  li t1, SATP_MODE
  or t0, t0, t1
  csrw satp, t0
  sfence.vma
  li t0, 0x6800
  csrw mstatus, t0
  la t0, supervisor
  csrw mepc, t0
  mret
supervisor:
  li s9, 0x40000000
  jal ra, test_error
  li s9, 0x40001000
  jal ra, test_error
  ecall
  j fail

test_error:
#ifdef RAPT_HALF_LOAD_ERROR
  li s6, 0
half_error_loop:
  fault_load flh, f2
  addi s9, s9, 1
  addi s6, s6, 1
  li t0, 8
  blt s6, t0, half_error_loop
  addi s9, s9, -8
#else
  li s4, 0x55
  fault_load lb, s4
  fault_load lh, s4
  fault_load lw, s4
#if __riscv_xlen == 64
  fault_load ld, s4
#else
  fault_load fld, f0
#endif
  li t0, 0x55
  bne s4, t0, fail
#endif
  ret
machine_trap:
#ifdef RAPT_HALF_LOAD_ERROR
  half_plic_check
#endif
  csrr t0, mcause
  li t1, 9
  beq t0, t1, finish
  li t1, 5
  bne t0, t1, fail
  csrr t0, mepc
  bne t0, s8, fail
  csrr t0, mtval
  bne t0, s9, fail
  addi s7, s7, 1
  csrw mepc, s11
  mret
finish:
  li t0, TOTAL_FAULT_COUNT
  bne s7, t0, fail
#ifdef RAPT_HALF_LOAD_ERROR
  /* Ensure an uncanceled half load updates the entire destination after faults. */
  la t0, data
  flh f2, 0(t0)
  la t0, half_plic_saved
  fsd f2, 0(t0)
  lw t1, 0(t0)
  li t2, -43400          /* sign-extended 0xffff5678 */
  bne t1, t2, fail
  lw t1, 4(t0)
  li t2, -1
  bne t1, t2, fail
  csrr t0, fcsr
  li t1, 0x43
  bne t0, t1, fail
#endif
  /* A valid RAM read after errors must still complete with its own data. */
  la t0, data
  lw t1, 0(t0)
  li t2, 0x12345678
  bne t1, t2, fail
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
.section .data
.balign 8
data: .word 0x12345678, 0x76543210

.balign 4096
root: .zero 4096
level1: .zero 4096
level0: .zero 4096
