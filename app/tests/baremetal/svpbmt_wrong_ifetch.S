/* Train an indirect IO target, then cancel its mispredicted fetch. */
#if __riscv_xlen != 64
#error Svpbmt requires RV64
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
  la t0, io_code
  srli t0, t0, 2
  ori t0, t0, 0xcb
  li t2, 2
  slli t2, t2, 61
  or t0, t0, t2
  sd t0, 0(t1)
  la t0, unused_page
  srli t0, t0, 2
  ori t0, t0, 0xcb
  li t2, 0
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
  li s3, 7
  li s4, 31
  li s5, 0x40000000
  la s6, after_io
training_loop:
  li t2, 0x7000000000000000
  // A dependency chain leaves time for the predicted IO target's page walk
  // even with delayed PTE responses. The AND retains the data dependency.
  .rept 8
  divu t2, t2, s3
  .endr
  andi t2, t2, 0
  add t2, t2, s5
prediction_jump:
  jalr zero, t2, 0
  j fail
after_io:
  addi s4, s4, -1
  bnez s4, training_loop
  la s5, resolved_path
  j training_loop
resolved_path:
  bnez s4, fail
  ecall
  j fail
machine_trap:
  csrr t0, mcause
  li t1, 9
  bne t0, t1, fail
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
.balign 4096
io_code:
  jr s6
.section .data
.balign 4096
root: .zero 4096
level1: .zero 4096
level0: .zero 4096
unused_page: .zero 4096
