/* Train one branch, then cancel a younger IO load before external issue. */
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
  la t0, io_payload
  srli t0, t0, 2
  ori t0, t0, 0xcf
  li t2, 2
  slli t2, t2, 61
  or t0, t0, t2
  sd t0, 0(t1)
  la t0, training_payload
  srli t0, t0, 2
  ori t0, t0, 0xcf
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
  li a1, 0x40001000
  li s2, 0x70000000000000d9
  li s3, 7
  li s4, 32
  li s5, 0x1000000000000000
training_loop:
  divu t2, s2, s3
prediction_branch:
  beq t2, s5, resolved_path
wrong_path_load:
  ld t0, 0(a1)
  addi s2, s2, -7
  addi s4, s4, -1
  li t0, 1
  bne s4, t0, training_loop
  // Final iteration predicts the old fallthrough, but the quotient now
  // makes the branch taken. Only this iteration points the load at IO.
  li a1, 0x40000000
  j training_loop
resolved_path:
  li t0, 1
  bne s4, t0, fail
legitimate_load:
  ld t0, 0(a1)
  li t1, 0x123456789abcdef
  bne t0, t1, fail
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
.section .data
.balign 4096
root: .zero 4096
level1: .zero 4096
level0: .zero 4096
io_payload:
  .dword 0x123456789abcdef
  .zero 4088
training_payload:
  .dword 0x1122334455667788
  .zero 4088
