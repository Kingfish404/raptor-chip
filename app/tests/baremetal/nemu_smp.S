.section .text.init
.globl _start
.option norelax
_start:
  csrr s0, mhartid
  li t0, HARTS
  bgeu s0, t0, fail
  la t0, trap
  csrw mtvec, t0
  li t0, 0x6000
  csrs mstatus, t0
  andi t0, s0, 3
  csrw frm, t0
  li s2, 0x3f800000
  add s2, s2, s0
  fmv.w.x f0, s2
  li t0, 0x3f800000
  fmv.w.x f1, t0
  li t0, 0x33800000
  fmv.w.x f2, t0
  li s5, 0
  la s3, shared
  li t0, 1
  amoadd.w zero, t0, (s3)
ready:
  lw t0, 0(s3)
  li t1, HARTS
  bne t0, t1, ready
#if HARTS > 1
  beqz s0, reserve
  li t0, 1
  bne s0, t0, wait_phase
wait_lr:
  lw t0, 16(s3)
  beqz t0, wait_lr
  li t0, 0x7f
#if __riscv_xlen == 64
  sb t0, 71(s3)
#else
  sb t0, 67(s3)
#endif
  li t0, 1
  sw t0, 20(s3)
  j wait_phase
reserve:
  addi t0, s3, 64
#if __riscv_xlen == 64
  lr.d s1, (t0)
#else
  lr.w s1, (t0)
#endif
  li t1, 1
  sw t1, 16(s3)
wait_store:
  lw t1, 20(s3)
  beqz t1, wait_store
#if __riscv_xlen == 64
  sc.d t1, s1, (t0)
#else
  sc.w t1, s1, (t0)
#endif
  beqz t1, fail
  li t1, 1
  sw t1, 24(s3)
wait_phase:
  lw t0, 24(s3)
  beqz t0, wait_phase
#endif
  li s1, 2000
atomic_loop:
  addi t0, s3, 4
  li t1, 1
  amoadd.w t2, t1, (t0)
  addi t0, s3, 8
cas_loop:
  lr.w t1, (t0)
  addi t1, t1, 1
  sc.w t2, t1, (t0)
  bnez t2, cas_loop
  fmv.x.w t0, f0
  bne t0, s2, fail
  csrr t0, frm
  andi t1, s0, 3
  bne t0, t1, fail
  csrw fflags, zero
  fadd.s f3, f1, f2, dyn
  fmv.x.w t0, f3
  li t1, 0x3f800000
  andi t2, s0, 3
  li t3, 3
  bne t2, t3, check_rounding
  addi t1, t1, 1
check_rounding:
  bne t0, t1, fail
  csrr t0, fflags
  li t1, 1
  bne t0, t1, fail
  addi s1, s1, -1
  bnez s1, atomic_loop
  addi t0, s3, 12
  li t1, 1
  amoadd.w zero, t1, (t0)
wait_atomic:
  lw t0, 12(s3)
  li t1, HARTS
  bne t0, t1, wait_atomic
  lw t0, 4(s3)
  li t1, HARTS * 2000
  bne t0, t1, fail
  lw t0, 8(s3)
  bne t0, t1, fail
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
  slli t0, s0, 12
  li s6, 0x80010000
  add s6, s6, t0
  li s7, 0x80020000
  add s7, s7, t0
  li s8, 0x80030000
  add s8, s8, t0
  li s9, 0x80040000
  add s9, s9, t0
  addi s10, s0, 1234
  sw s10, 0(s9)
  srli t0, s7, 2
  ori t0, t0, 1
#if __riscv_xlen == 64
  sd t0, 8(s6)
  li t0, 0x200000cf
  sd t0, 16(s6)
  srli t0, s8, 2
  ori t0, t0, 1
  sd t0, 0(s7)
  srli t0, s9, 2
  ori t0, t0, 0xc7
  sd t0, 0(s8)
  srli t0, s6, 12
  li t1, 0x8000000000000000
#else
  sw t0, 1024(s6)
  li t0, 0x200000cf
  li t1, 2048
  add t1, t1, s6
  sw t0, 0(t1)
  srli t0, s9, 2
  ori t0, t0, 0xc7
  sw t0, 0(s7)
  srli t0, s6, 12
  li t1, 0x80000000
#endif
  or t0, t0, t1
  csrw satp, t0
  sfence.vma
  li t0, 0x1800
  csrc mstatus, t0
  li t0, 0x800
  csrs mstatus, t0
  la t0, supervisor
  csrw mepc, t0
  mret
supervisor:
  li s11, 0
  li t0, 0x50000000
  amoadd.w zero, zero, (t0)
  li t1, 1
  bne s11, t1, supervisor_fail
  sw zero, 0(t0)
  li t1, 2
  bne s11, t1, supervisor_fail
  li s1, 2000
  li t0, 0x40000000
alias_loop:
  lw t1, 0(t0)
  bne t1, s10, supervisor_fail
  addi s1, s1, -1
  bnez s1, alias_loop
  ecall
  j after_mmu
supervisor_fail:
  unimp
after_mmu:
  csrw satp, zero
  sfence.vma
  li t0, 0x88
  csrw mie, t0
  csrsi mstatus, 8
  bnez s0, wait_ipi
  li t0, 0x02000000
  li t1, 1
  li t2, HARTS
send_ipi:
  sw t1, 0(t0)
  addi t0, t0, 4
  addi t2, t2, -1
  bnez t2, send_ipi
wait_ipi:
  andi t0, s5, 1
  bnez t0, program_timer
  wfi
  j wait_ipi
program_timer:
  li t0, 0x0200bff8
  lw t1, 0(t0)
  addi t1, t1, 2000
  li t0, 0x02004000
  slli t2, s0, 3
  add t0, t0, t2
#if __riscv_xlen == 64
  sd t1, 0(t0)
#else
  sw zero, 4(t0)
  sw t1, 0(t0)
#endif
wait_timer:
  andi t0, s5, 2
  bnez t0, completed
  wfi
  j wait_timer
completed:
  csrw mie, zero
  csrci mstatus, 8
  addi t0, s3, 28
  li t1, 1
  amoadd.w zero, t1, (t0)
  bnez s0, parked
wait_complete:
  lw t0, 28(s3)
  li t1, HARTS
  bne t0, t1, wait_complete
  la t0, message
  li t1, 0x10000000
print:
  lbu t2, 0(t0)
  beqz t2, pass
  sb t2, 0(t1)
  addi t0, t0, 1
  j print
pass:
  li t0, 0x100000
  li t1, 0x5555
  sw t1, 0(t0)
parked:
  wfi
  j parked
.balign 4
trap:
  csrr t3, mcause
  li t4, 9
  beq t3, t4, supervisor_return
  li t4, 15
  beq t3, t4, page_fault_return
  bgez t3, fail
  li t4, -1
  srli t4, t4, 1
  and t3, t3, t4
  li t4, 3
  beq t3, t4, ipi_trap
  li t4, 7
  bne t3, t4, fail
  li t5, 0x02004000
  slli t6, s0, 3
  add t5, t5, t6
  li t6, -1
  sw t6, 0(t5)
  sw t6, 4(t5)
  ori s5, s5, 2
  mret
ipi_trap:
  li t5, 0x02000000
  slli t6, s0, 2
  add t5, t5, t6
  sw zero, 0(t5)
  ori s5, s5, 1
  mret
supervisor_return:
  csrr t3, mepc
  addi t3, t3, 4
  csrw mepc, t3
  li t3, 0x1800
  csrs mstatus, t3
  mret
page_fault_return:
  csrr t3, mtval
  li t4, 0x50000000
  bne t3, t4, fail
  addi s11, s11, 1
  csrr t3, mepc
  addi t3, t3, 4
  csrw mepc, t3
  mret
fail:
  li t0, 0x100000
  li t1, 0x13333
  sw t1, 0(t0)
  j fail
.section .rodata
message:
  .asciz "NEMU_SMP_BAREMETAL_PASS\n"
.section .data
.balign 64
shared:
  .zero 128
