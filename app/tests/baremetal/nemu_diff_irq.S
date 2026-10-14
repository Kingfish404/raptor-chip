.option norvc
.section .text
.globl _start
_start:
  csrr s0, mhartid
  li s1, 0
  li s2, 0
  li s7, 0
  li s9, 0
  la t0, machine_vectors
  ori t0, t0, 1
  csrw mtvec, t0
  li t0, 0x222
  csrw mie, t0
  csrw mip, t0
  wfi
  bnez s1, fail
  la s4, machine_resume
  csrsi mstatus, 8
machine_resume:
  csrci mstatus, 8
  li t0, 3
  bne s1, t0, fail
  li t0, 2
  csrw mie, t0
  li t0, 0x220
  csrw mip, t0
  csrsi mstatus, 8
  li t0, 3
  bne s1, t0, fail
  la s4, masked_resume
  csrsi mip, 2
masked_resume:
  li t0, 4
  bne s1, t0, fail
  li t0, 0x220
  la s4, enabled_resume
  csrs mie, t0
enabled_resume:
  csrci mstatus, 8
  li t0, 6
  bne s1, t0, fail
  csrw mie, zero
  csrw mip, zero
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0xf
  csrw pmpcfg0, t0
  la t0, machine_exception
  csrw mtvec, t0
  la t0, supervisor_vectors
  ori t0, t0, 1
  csrw stvec, t0
  li t0, 0x222
  csrw mideleg, t0
  csrw mie, t0
  csrw mip, t0
  csrsi mstatus, 8
  wfi
  li t0, 6
  bne s1, t0, fail
  li t0, 0x180a
  csrc mstatus, t0
  li t0, 0x800
  csrs mstatus, t0
  la t0, supervisor_start
  csrw mepc, t0
  li a0, 0
  mret

supervisor_start:
  bnez s2, fail
  la s4, supervisor_resume
  csrsi sstatus, 2
supervisor_resume:
  csrci sstatus, 2
  li t0, 3
  bne s2, t0, fail
  li t0, 2
  bne s7, t0, fail
  csrsi sip, 2
  wfi
  li t0, 3
  bne s2, t0, fail
  la s4, supervisor_resume_again
  csrsi sstatus, 2
supervisor_resume_again:
  li t0, 4
  bne s2, t0, fail
  li a0, 1
  ecall
  la s4, supervisor_wfi_fault
supervisor_wfi_fault:
  wfi
  li t0, 1
  bne s9, t0, fail
  li t0, 0x100
  csrc sstatus, t0
  la t0, user_start
  csrw sepc, t0
  sret
user_start:
  la s4, user_wfi_fault
user_wfi_fault:
  wfi
  li t0, 2
  bne s9, t0, fail
  ecall
machine_done:
  csrw mie, zero
  csrw mip, zero
  la t0, completed
  li t1, 1
  amoadd.w zero, t1, (t0)
  bnez s0, parked
wait_all:
  lw t1, 0(t0)
  li t2, HARTS
  bne t1, t2, wait_all
  li t2, 1024
delay_finish:
  addi t2, t2, -1
  bnez t2, delay_finish
  li t0, 0x100000
  li t1, 0x5555
  sw t1, 0(t0)
idle:
  j idle
parked:
  wfi
  j parked

.balign 64
machine_vectors:
  j machine_exception
  j machine_ssi
  j fail
  j fail
  j fail
  j machine_sti
  j fail
  j fail
  j fail
  j machine_sei
machine_ssi:
  li t3, 1
  j machine_irq
machine_sti:
  li t3, 5
  j machine_irq
machine_sei:
  li t3, 9
machine_irq:
  li t4, 6
  bgeu s1, t4, fail
  la t4, machine_order
  add t4, t4, s1
  lbu t4, 0(t4)
  bne t3, t4, fail
  li t4, 1
  slli t5, t4, (__riscv_xlen - 1)
  or t5, t5, t3
  csrr t6, mcause
  bne t5, t6, fail
  csrr t5, mepc
  bne t5, s4, fail
  sll t4, t4, t3
  csrc mip, t4
  addi s1, s1, 1
  mret

.balign 64
supervisor_vectors:
  j fail
  j supervisor_ssi
  j fail
  j fail
  j fail
  j supervisor_sti
  j fail
  j fail
  j fail
  j supervisor_sei
supervisor_ssi:
  li t3, 1
  j supervisor_irq
supervisor_sti:
  li t3, 5
  j supervisor_irq
supervisor_sei:
  li t3, 9
supervisor_irq:
  li t4, 4
  bgeu s2, t4, fail
  la t4, supervisor_order
  add t4, t4, s2
  lbu t4, 0(t4)
  bne t3, t4, fail
  li t4, 1
  slli t4, t4, (__riscv_xlen - 1)
  or t4, t4, t3
  csrr t5, scause
  bne t4, t5, fail
  csrr t4, sepc
  bne t4, s4, fail
  addi s2, s2, 1
  li t4, 1
  beq t3, t4, supervisor_clear_ssi
  ecall
  sret
supervisor_clear_ssi:
  csrci sip, 2
  sret

machine_exception:
  csrr t4, mcause
  li t5, 8
  beq t4, t5, finish_user
  li t5, 2
  beq t4, t5, wfi_fault
  li t5, 9
  bne t4, t5, fail
  bnez a0, enable_tw
  li t4, 1
  sll t4, t4, t3
  csrc mip, t4
  addi s7, s7, 1
  j exception_return
enable_tw:
  li t4, 0x200000
  csrs mstatus, t4
  j exception_return
wfi_fault:
  csrr t4, mtval
  li t5, 0x10500073
  bne t4, t5, fail
  csrr t4, mepc
  bne t4, s4, fail
  addi s9, s9, 1
exception_return:
  csrr t4, mepc
  addi t4, t4, 4
  csrw mepc, t4
  mret

finish_user:
  la t4, machine_done
  csrw mepc, t4
  li t4, 0x1800
  csrs mstatus, t4
  mret

fail:
  li t0, 0x100000
  li t1, 0x3333
  sw t1, 0(t0)
  j fail

.section .rodata
machine_order: .byte 9, 1, 5, 1, 9, 5
supervisor_order: .byte 9, 1, 5, 1
.section .data
.balign 4
completed: .word 0
