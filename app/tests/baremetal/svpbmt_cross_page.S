/* Mixed PBMT, independently translated noncontiguous physical pages. */
#if __riscv_xlen != 64
#error Svpbmt requires RV64
#endif
#ifndef PBMT_FIRST
#define PBMT_FIRST 0
#endif
#ifndef PBMT_SECOND
#define PBMT_SECOND 0
#endif
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, machine_trap
  csrw mtvec, t0
  csrw medeleg, zero
  csrw mideleg, zero
  csrw mie, zero
  csrw mstatus, zero
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
  li t0, 0x4000000000000000
  csrw menvcfg, t0
  csrr t1, menvcfg
  bne t0, t1, fail
  la s0, root
  li t0, 0x200000cf
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
  la t1, level0
  la t0, payload_first
  srli t0, t0, 2
  ori t0, t0, 0xcf
  li t2, PBMT_FIRST
  slli t2, t2, 61
  or t0, t0, t2
  sd t0, 0(t1)
  la t0, payload_second
  srli t0, t0, 2
  ori t0, t0, 0xcf
  li t2, PBMT_SECOND
  slli t2, t2, 61
  or t0, t0, t2
  sd t0, 8(t1)
  srli t0, s0, 12
  li t1, 0x8000000000000000
  or t0, t0, t1
  csrw satp, t0
  sfence.vma
  li s7, 0
  la t0, supervisor
  csrw mepc, t0
  li t0, 0x800
  csrw mstatus, t0
  mret
supervisor:
  li a1, 0x40000ffd
#if PBMT_FIRST == 2 || PBMT_SECOND == 2
#if PBMT_FIRST == 2
  mv s9, a1
#else
  li s9, 0x40001000
#endif
  li s10, 5
  la s8, fault_load
  la s11, after_load
fault_load:
  ld t0, 0(a1)
after_load:
  li s10, 7
  la s8, fault_store
  la s11, after_store
  li t1, 0x123456789abcdef
fault_store:
  sd t1, 0(a1)
after_store:
  li t0, 2
  bne s7, t0, fail
#else
  ld t0, 0(a1)
  li t1, 0x8877665544332211
  bne t0, t1, fail
  li s1, 0x123456789abcdef
  sd s1, 0(a1)
  fence iorw,iorw
  ld t0, 0(a1)
  bne t0, s1, fail
  bnez s7, fail
#endif
  ecall
  j fail
machine_trap:
  csrr t0, mcause
  li t1, 9
  beq t0, t1, finish
  bne t0, s10, fail
  csrr t0, mepc
  bne t0, s8, fail
  csrr t0, mtval
  bne t0, s9, fail
  addi s7, s7, 1
  csrw mepc, s11
  mret
finish:
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
.section .data
.balign 4096
root: .zero 4096
level1: .zero 4096
level0: .zero 4096
payload_first:
  .zero 4093
  .byte 0x11,0x22,0x33
physical_gap: .zero 4096
payload_second:
  .byte 0x44,0x55,0x66,0x77,0x88
  .zero 4091
