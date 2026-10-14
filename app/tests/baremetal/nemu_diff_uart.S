.option norvc
.option norelax
.section .text
.globl _start
_start:
  csrr s0, mhartid
  li s1, 0x10000000
  la s2, shared
  li s3, 0
  li s4, 0
  li s5, 0x0c200000
  li s6, 0x0c201000
  la t0, machine_trap
  csrw mtvec, t0
#ifdef BAD_WIDTH
  lw t0, 0(s1)
#endif
#ifdef BAD_OFFSET
  lbu t0, 8(s1)
#endif
#ifdef BAD_LITEX
  li t0, 0x11001800
  lw t1, 0(t0)
#endif
  bnez s0, wait_start
  rdtime t0
  lbu t0, 4(s1)
  li t1, 8
  bne t0, t1, fail
  lbu t0, 6(s1)
  li t1, 0xb0
  bne t0, t1, fail
  li t0, 0x5a
  sb t0, 7(s1)
  lbu t1, 7(s1)
  bne t0, t1, fail
  li t0, 0x80
  sb t0, 3(s1)
  li t0, 0x34
  sb t0, 0(s1)
  lbu t1, 0(s1)
  bne t0, t1, fail
  li t0, 0x12
  sb t0, 1(s1)
  lbu t1, 1(s1)
  bne t0, t1, fail
  li t0, 3
  sb t0, 3(s1)
  lbu t1, 3(s1)
  bne t0, t1, fail
  li t0, 0xff
  sb t0, 1(s1)
  lbu t0, 1(s1)
  li t1, 15
  bne t0, t1, fail
  sb zero, 1(s1)
  li t0, 16
  sb t0, 4(s1)
  li t0, 'X'
  sb t0, 0(s1)
  li t0, 8
  sb t0, 4(s1)
  li t0, 7
  sb t0, 2(s1)
#ifndef NO_INPUT
  lbu t0, 5(s1)
  li t1, 0x61
  bne t0, t1, fail
  li t2, 0
drain_initial:
  lbu t0, 0(s1)
  bne t0, t2, fail
  addi t2, t2, 1
  li t1, 255
  bne t2, t1, drain_initial
#endif
  lbu t0, 0(s1)
  bnez t0, fail
  lbu t0, 5(s1)
  li t1, 0x60
  bne t0, t1, fail
  lbu t0, 2(s1)
  li t1, 0xc1
  bne t0, t1, fail
  li t0, 0x0c000028
  li t1, 1
  sw t1, 0(t0)
  li t0, 0x0c002000
  li t1, 0x400
  sw t1, 0(t0)
  lw t0, 4(s5)
#ifdef NO_INPUT
  bnez t0, fail
#else
  li t1, 10
  bne t0, t1, fail
  sw t0, 4(s5)
#endif
  li t0, 'A'
  sb t0, 0(s1)
  li t0, 2
  sb t0, 1(s1)
  lbu t0, 2(s1)
  li t1, 0xc2
  bne t0, t1, fail
  lbu t0, 2(s1)
  li t1, 0xc1
  bne t0, t1, fail
  lw t0, 4(s5)
  li t1, 10
  bne t0, t1, fail
  sw t0, 4(s5)
  sb zero, 1(s1)
  li t0, 1
  sw t0, 0(s2)
wait_start:
  lw t0, 0(s2)
  beqz t0, wait_start
  addi t2, s2, 4
lock:
  li t0, 1
  amoswap.w.aq t1, t0, (t2)
  bnez t1, lock
  addi t0, s0, 0x40
  sb t0, 7(s1)
  lbu t1, 7(s1)
  bne t0, t1, fail
  addi t0, s0, 'a'
  sb t0, 0(s1)
  amoswap.w.rl zero, zero, (t2)
  addi t2, s2, 8
  li t0, 1
  amoadd.w zero, t0, (t2)
  bnez s0, parked
wait_senders:
  lw t0, 8(s2)
  li t1, HARTS
  bne t0, t1, wait_senders
#ifdef NO_INPUT
  j machine_done
#else
  la a0, machine_prompt
  call print_prompt
  li t0, 1
  sb t0, 1(s1)
  li t0, 0x800
  csrw mie, t0
wait_rx:
  csrci mstatus, 8
  bnez s3, setup_supervisor
  wfi
  csrsi mstatus, 8
  j wait_rx
setup_supervisor:
  li t0, 0x0c002000
  sw zero, 0(t0)
  li t1, 0x400
  sw t1, 0x80(t0)
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0xf
  csrw pmpcfg0, t0
  li t0, 0x200
  csrw mie, t0
  csrw mideleg, t0
  la t0, supervisor_trap
  csrw stvec, t0
  la a0, supervisor_prompt
  call print_prompt
  li t0, 1
  sb t0, 1(s1)
  li t0, 0x180a
  csrc mstatus, t0
  li t0, 0x800
  csrs mstatus, t0
  la t0, supervisor_start
  csrw mepc, t0
  mret
supervisor_start:
  csrci sstatus, 2
  bnez s4, supervisor_done
  wfi
  csrsi sstatus, 2
  j supervisor_start
supervisor_done:
  li t0, 'Z'
  sb t0, 0(s1)
  ecall
#endif
machine_done:
  csrw mie, zero
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
print_prompt:
  lbu a1, 0(a0)
  beqz a1, prompt_done
  sb a1, 0(s1)
  addi a0, a0, 1
  j print_prompt
prompt_done:
  ret
.balign 4
machine_trap:
  csrr t3, mcause
  li t4, 9
  beq t3, t4, return_machine
  li t4, 1
  slli t4, t4, (__riscv_xlen - 1)
  ori t4, t4, 11
  bne t3, t4, fail
  lw t3, 4(s5)
  li t4, 10
  bne t3, t4, fail
  sw t3, 4(s5)
  lbu t3, 2(s1)
  li t4, 0xc4
  bne t3, t4, fail
  sb zero, 1(s1)
  lbu t3, 0(s1)
  li t4, 'K'
  bne t3, t4, fail
  lbu t3, 0(s1)
  li t4, 'L'
  bne t3, t4, fail
  addi s3, s3, 1
  li t3, 1
  bne s3, t3, fail
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
  lw t3, 4(s6)
  li t4, 10
  bne t3, t4, fail
  sw t3, 4(s6)
  lbu t3, 2(s1)
  li t4, 0xc4
  bne t3, t4, fail
  sb zero, 1(s1)
  lbu t3, 0(s1)
  li t4, 0x80
  bne t3, t4, fail
  lbu t3, 0(s1)
  li t4, 0xff
  bne t3, t4, fail
  addi s4, s4, 1
  li t3, 1
  bne s4, t3, fail
  sret
fail:
  li t0, 0x100000
  li t1, 0x3333
  sw t1, 0(t0)
  j fail
.section .rodata
machine_prompt:
  .asciz "@UART:RX-M@\n"
supervisor_prompt:
  .asciz "@UART:RX-S@\n"
.section .bss
.balign 64
shared:
  .zero 64
