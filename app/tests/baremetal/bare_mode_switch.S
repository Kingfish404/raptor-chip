/* Sv39 <-> Bare takes effect immediately, with no SFENCE between switches.
 * VA 0x80400000 maps to PA 0x80200000 in Sv39 and to itself in Bare.
 * The text executing SATP writes is identity mapped in both modes.
 * Code and page tables stay immutable after initial FENCE.I/SFENCE.VMA.
 */
#if __riscv_xlen != 64
#error This mode-switch test requires RV64
#endif
.option norvc
.option norelax
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
  li t0, 15
  csrw pmpcfg0, t0
  la t0, root
  la t1, level1
  srli t2, t1, 2
  ori t2, t2, 1
  sd t2, 16(t0)
  li t2, 0x200000cf
  sd t2, 0(t1) /* main text/data 0x80000000 identity */
  li t2, 0x200800cf
  sd t2, 16(t1) /* 0x80400000 -> 0x80200000 */
  li s0, 0x80200000
  li s2, 0x80400000
  li t0, 0x00100513
  sw t0, 0(s0)
  li t0, 0x00200513
  sw t0, 0(s2)
  li t0, 0x00008067
  sw t0, 4(s0)
  sw t0, 4(s2)
  li t0, 11
  li t1, 0x80201000
  sw t0, 0(t1)
  sw zero, 8(t1)
  li t0, 22
  li t1, 0x80401000
  sw t0, 0(t1)
  sw zero, 8(t1)
  fence.i
  sfence.vma
  la s1, root
  srli s1, s1, 12
  li t0, 0x8000000000000000
  or s1, s1, t0
  li t0, 0x800
  csrw mstatus, t0
  la t0, run
  csrw mepc, t0
  mret
run:
  li s4, 1
next:
  csrw satp, s1
  jalr ra, s2, 0
  li t0, 1
  bne a0, t0, fail
  li t0, 0x80401000
  lw t1, 0(t0)
  li t2, 11
  bne t1, t2, fail
  sw s4, 8(t0)
  csrw satp, zero
  li t0, 0x80201000
  lw t1, 8(t0)
  bne t1, s4, fail
  jalr ra, s2, 0
  li t0, 2
  bne a0, t0, fail
  li t0, 0x80401000
  lw t1, 0(t0)
  li t2, 22
  bne t1, t2, fail
  addi t2, s4, 100
  sw t2, 8(t0)
  lw t1, 8(t0)
  bne t1, t2, fail
  li t0, 0x80201000
  lw t1, 8(t0)
  bne t1, s4, fail
  addi s4, s4, 1
  li t0, 17
  bne s4, t0, next
  li a0, 0
  ecall
fail:
  li a0, 1
  ecall
trap:
  bnez a0, bad
  csrr t0, mcause
  li t1, 9
  bne t0, t1, bad
  li t0, 17
  bne s4, t0, bad
  ebreak
bad:
  li a0, 1
  ebreak
  j bad
.section .data
.balign 4096
root: .zero 4096
level1: .zero 4096
