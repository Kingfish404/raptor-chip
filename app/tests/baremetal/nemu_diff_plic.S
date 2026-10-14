.option norvc
.option norelax
.section .text
.globl _start
_start:
  csrr s0, mhartid
  la t0, machine_trap
  csrw mtvec, t0
  li s1, 0x0c200000
  slli t0, s0, 13
  add s1, s1, t0
  li s2, 0x0c002000
  slli t0, s0, 8
  add s2, s2, t0
  la s3, shared
  li s4, 0
  li s5, 0
  li s6, 0x0c001000
#ifdef BAD_WIDTH
  lb t0, 0(s1)
#endif
#ifdef BAD_CONTEXT
  li t0, 0x0c200000 + HARTS * 0x2000
  lw t1, 0(t0)
#endif
#ifdef BAD_HOLE
  lw t0, 8(s1)
#endif
  bnez s0, configure_competition
  rdtime t0
  li t0, 0x0c000000
  sw zero, 0(t0)
  li t1, 3
  sw t1, 4(t0)
  sw t1, 8(t0)
  li t1, 5
  sw t1, 12(t0)
  li t1, 1
  sw t1, 32(t0)
  sw t1, 36(t0)
  sw t1, 40(t0)
  sw t1, 44(t0)
  sw t1, 124(t0)
  sw t1, 128(t0)
  li t1, 0x40e
  sw t1, 0(s2)
  li t1, 15
  sw t1, 0(s6)
  lw t1, 0(s6)
  andi t1, t1, 1
  bnez t1, fail
  lw t1, 4(s1)
  li t2, 3
  bne t1, t2, fail
  sw t1, 4(s1)
  sw t2, 0(s1)
  lw t1, 4(s1)
  bnez t1, fail
  lw t1, 0(s6)
  andi t1, t1, 6
  li t2, 6
  bne t1, t2, fail
  sw zero, 0(s1)
  lw t1, 4(s1)
  li t2, 1
  bne t1, t2, fail
  sw t1, 4(s1)
  lw t1, 4(s1)
  li t2, 2
  bne t1, t2, fail
  sw t1, 4(s1)
  lw t1, 4(s1)
  li t2, 10
  bne t1, t2, fail
  sw t1, 4(s1)
  lw t1, 4(s1)
  bnez t1, fail
configure_competition:
  li t0, 0xb00
  sw t0, 0(s2)
  li t0, 1
  amoadd.w zero, t0, (s3)
ready:
  lw t0, 0(s3)
  li t1, HARTS
  bne t0, t1, ready
  bnez s0, wait_one
  li t0, 0x100
  sw t0, 0(s6)
  li t0, 1
  sw t0, 4(s3)
wait_one:
  lw t0, 4(s3)
  beqz t0, wait_one
  lw t0, 4(s1)
  beqz t0, one_done
  li t1, 8
  bne t0, t1, fail
  addi t1, s3, 8
  li t2, 1
  amoadd.w zero, t2, (t1)
  sw t0, 4(s1)
one_done:
  addi t0, s3, 12
  li t1, 1
  amoadd.w zero, t1, (t0)
wait_one_done:
  lw t0, 12(s3)
  li t1, HARTS
  bne t0, t1, wait_one_done
  lw t0, 8(s3)
  li t1, 1
  bne t0, t1, fail
  addi t0, s3, 16
  amoadd.w zero, t1, (t0)
ready_two:
  lw t0, 16(s3)
  li t1, HARTS
  bne t0, t1, ready_two
  bnez s0, wait_two
  li t0, 0xa00
  sw t0, 0(s6)
  li t0, 2
  sw t0, 4(s3)
wait_two:
  lw t0, 4(s3)
  li t1, 2
  bne t0, t1, wait_two
claim_two:
  lw t0, 4(s1)
  beqz t0, two_done
  li t1, 9
  beq t0, t1, valid_two
  li t1, 11
  bne t0, t1, fail
valid_two:
  li t1, 1
  sll t1, t1, t0
  addi t2, s3, 20
  amoor.w t2, t1, (t2)
  and t2, t2, t1
  bnez t2, fail
  sw t0, 4(s1)
  j claim_two
two_done:
  addi t0, s3, 24
  li t1, 1
  amoadd.w zero, t1, (t0)
wait_two_done:
  lw t0, 24(s3)
  li t1, HARTS
  bne t0, t1, wait_two_done
  lw t0, 20(s3)
  li t1, 0xa00
  bne t0, t1, fail
  addi t0, s0, 16
  li t1, 1
  sll t1, t1, t0
  sw t1, 0(s2)
  slli t0, t0, 2
  li t1, 0x0c000000
  add t0, t0, t1
  li t1, 2
  sw t1, 0(t0)
  li t0, 0x800
  csrw mie, t0
  addi t0, s3, 28
  li t1, 1
  amoadd.w zero, t1, (t0)
ready_irq:
  lw t0, 28(s3)
  li t1, HARTS
  bne t0, t1, ready_irq
  bnez s0, wait_machine
  li t0, ((1 << HARTS) - 1) << 16
  sw t0, 0(s6)
wait_machine:
  csrci mstatus, 8
  bnez s4, machine_received
  wfi
  csrsi mstatus, 8
  j wait_machine
machine_received:
  bnez s0, setup_supervisor
  li t0, 0x80000000
  sw t0, 0(s2)
wait_external:
  csrci mstatus, 8
  li t0, 2
  beq s4, t0, setup_supervisor
  wfi
  csrsi mstatus, 8
  j wait_external
setup_supervisor:
  sw zero, 0(s2)
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0xf
  csrw pmpcfg0, t0
  li s7, 0x1000
  add s7, s1, s7
  addi s8, s2, 0x80
  addi t0, s0, 20
  li s9, 1
  sll s9, s9, t0
  sw s9, 0(s8)
  slli t0, t0, 2
  li t1, 0x0c000000
  add t0, t0, t1
  li t1, 2
  sw t1, 0(t0)
  li t0, 0x200
  csrw mideleg, t0
  csrw mie, t0
  la t0, supervisor_trap
  csrw stvec, t0
  li t0, 0x180a
  csrc mstatus, t0
  li t0, 0x800
  csrs mstatus, t0
  la t0, supervisor_start
  csrw mepc, t0
  mret
supervisor_start:
  sw s9, 0(s6)
wait_supervisor:
  csrci sstatus, 2
  bnez s5, supervisor_received
  wfi
  csrsi sstatus, 2
  j wait_supervisor
supervisor_received:
  bnez s0, supervisor_done
  sw zero, 0(s8)
  li t0, 1
  sw t0, 4(s8)
wait_source32:
  csrci sstatus, 2
  li t0, 2
  beq s5, t0, supervisor_done
  wfi
  csrsi sstatus, 2
  j wait_source32
supervisor_done:
  ecall
machine_done:
  csrw mie, zero
  addi t0, s3, 32
  li t1, 1
  amoadd.w zero, t1, (t0)
  bnez s0, parked
wait_done:
  lw t0, 32(s3)
  li t1, HARTS
  bne t0, t1, wait_done
  li t0, 1024
delay:
  addi t0, t0, -1
  bnez t0, delay
  li t0, 0x100000
  li t1, 0x5555
  sw t1, 0(t0)
parked:
  wfi
  j parked
.balign 4
machine_trap:
  csrr t3, mcause
  li t4, 9
  beq t3, t4, return_machine
  li t4, 1
  slli t4, t4, (__riscv_xlen - 1)
  ori t4, t4, 11
  bne t3, t4, fail
  lw t3, 4(s1)
  addi t4, s0, 16
  beqz s4, check_machine_id
  bnez s0, fail
  li t4, 31
check_machine_id:
  bne t3, t4, fail
  sw t3, 4(s1)
  addi s4, s4, 1
  mret
return_machine:
  la t3, machine_done
  csrw mepc, t3
  li t3, 0x1800
  csrs mstatus, t3
  mret
.balign 4
supervisor_trap:
  csrr t3, scause
  li t4, 1
  slli t4, t4, (__riscv_xlen - 1)
  ori t4, t4, 9
  bne t3, t4, fail
  lw t3, 4(s7)
  addi t4, s0, 20
  beqz s5, check_supervisor_id
  bnez s0, fail
  li t4, 32
check_supervisor_id:
  bne t3, t4, fail
  sw t3, 4(s7)
  addi s5, s5, 1
  sret
fail:
  li t0, 0x100000
  li t1, 0x3333
  sw t1, 0(t0)
  j fail
.section .bss
.balign 64
shared:
  .zero 64
