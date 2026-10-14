.option norvc
.option norelax
.section .text
.globl _start
_start:
  csrr s0, mhartid
  li s1, 0
  li s2, 0
  li s3, 0
  li s4, 0
  la t0, machine_trap
  csrw mtvec, t0
  la s10, readonly_time
readonly_time:
  csrw time, zero
#ifdef BAD_MMIO
  li t0, 0x10000000
  lw t1, 0(t0)
#endif
#ifdef BAD_MTIME_WRITE
  li t0, 0x0200bff8
  sw zero, 0(t0)
#endif
#ifdef BAD_MSIP_WIDTH
  li t0, 0x02000000
  sb zero, 0(t0)
#endif
  li t0, 0x02000000
  slli t1, s0, 2
  add t0, t0, t1
  li t1, 2
  sw t1, 0(t0)
  lw t1, 0(t0)
  bnez t1, fail
  li s5, 0x02004000
  slli t1, s0, 3
  add s5, s5, t1
  li t0, 0x12345678
  sw t0, 4(s5)
  lw t1, 4(s5)
  bne t0, t1, fail
  li t0, 0x76543210
  sw t0, 0(s5)
  lw t1, 0(s5)
  bne t0, t1, fail
#if __riscv_xlen == 64
  li t0, 0x0011223344556677
  sd t0, 0(s5)
  ld t1, 0(s5)
  bne t0, t1, fail
#endif
  li t0, -1
  sw t0, 4(s5)
  sw t0, 0(s5)
  la s6, shared
  li t0, 1
  amoadd.w zero, t0, (s6)
ready:
  lw t0, 0(s6)
  li t1, HARTS
  bne t0, t1, ready
  li t0, 8
  csrw mie, t0
  addi t0, s0, 1
  li t1, HARTS
  remu t0, t0, t1
  slli t0, t0, 2
  li t1, 0x02000000
  add t0, t0, t1
  li t1, 1
  sw t1, 0(t0)
wait_ipi:
  csrci mstatus, 8
  bnez s1, setup_timer
  wfi
  csrsi mstatus, 8
  j wait_ipi
setup_timer:
  li t0, 0x80
  csrw mie, t0
  call read_deadline
#ifdef HIGH_TIME
#if __riscv_xlen == 64
  li s7, 0x100000100
#else
  li s7, 0x100
  li s8, 1
#endif
#endif
#if __riscv_xlen == 64
  sd s7, 0(s5)
#else
  li t0, -1
  sw t0, 4(s5)
  sw s7, 0(s5)
  sw s8, 4(s5)
#endif
wait_timer:
  csrci mstatus, 8
  bnez s2, setup_supervisor
  wfi
  csrsi mstatus, 8
  j wait_timer
setup_supervisor:
#ifdef HIGH_TIME
#if __riscv_xlen == 64
  rdtime t0
  srli t0, t0, 32
#else
  rdtimeh t0
#endif
  beqz t0, fail
#endif
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0xf
  csrw pmpcfg0, t0
  li t0, -1
  csrw 0x14d, t0
#if __riscv_xlen == 32
  csrw 0x15d, t0
  li t0, 0x80000000
  csrw 0x31a, t0
#else
  li t0, 0x8000000000000000
  csrw 0x30a, t0
#endif
  csrw mcounteren, zero
  li t0, 0x20
  csrw mideleg, t0
  csrw mie, t0
  la t0, supervisor_vectors
  ori t0, t0, 1
  csrw stvec, t0
  li t0, 0x180a
  csrc mstatus, t0
  li t0, 0x800
  csrs mstatus, t0
  la t0, supervisor_start
  csrw mepc, t0
  mret
supervisor_start:
  la s10, denied_time
denied_time:
  rdtime t0
  call read_deadline
#if __riscv_xlen == 32
  li t0, -1
  csrw 0x15d, t0
  csrw 0x14d, s7
  csrw 0x15d, s8
#else
  csrw 0x14d, s7
#endif
wait_supervisor:
  csrci sstatus, 2
  bnez s3, supervisor_done
  wfi
  csrsi sstatus, 2
  j wait_supervisor
supervisor_done:
  csrr t0, sip
  andi t0, t0, 0x20
  bnez t0, fail
  ecall
machine_done:
  csrw mie, zero
  li t0, 1
  bne s1, t0, fail
  bne s2, t0, fail
  bne s3, t0, fail
  li t0, 2
  bne s4, t0, fail
  li t0, 1
  addi t1, s6, 4
  amoadd.w zero, t0, (t1)
  bnez s0, parked
wait_done:
  lw t0, 0(t1)
  li t2, HARTS
  bne t0, t2, wait_done
  li t2, 1024
delay_finish:
  addi t2, t2, -1
  bnez t2, delay_finish
  li t0, 0x100000
  li t1, 0x5555
  sw t1, 0(t0)
parked:
  wfi
  j parked

read_deadline:
#if __riscv_xlen == 32
  rdtimeh s8
  rdtime s7
  rdtimeh t0
  bne s8, t0, read_deadline
  li t0, 50000
  add t1, s7, t0
  sltu t0, t1, s7
  add s8, s8, t0
  mv s7, t1
#else
  rdtime s7
  li t0, 50000
  add s7, s7, t0
#endif
  li t0, 0x0200bff8
  lw t1, 0(t0)
  lw t1, 4(t0)
#if __riscv_xlen == 64
  ld t1, 0(t0)
#endif
  ret

.balign 4
machine_trap:
  csrr t3, mcause
  li t4, 2
  beq t3, t4, illegal_handler
  li t4, 9
  beq t3, t4, supervisor_return
  bgez t3, fail
  li t4, -1
  srli t4, t4, 1
  and t3, t3, t4
  li t4, 3
  beq t3, t4, ipi_handler
  li t4, 7
  bne t3, t4, fail
  li t3, -1
  sw t3, 4(s5)
  sw t3, 0(s5)
  addi s2, s2, 1
  li t3, 1
  bne s2, t3, fail
  mret
illegal_handler:
  csrr t3, mepc
  bne t3, s10, fail
  csrr t4, mtval
#if __riscv_xlen == 64
  lwu t5, 0(t3)
#else
  lw t5, 0(t3)
#endif
  bne t4, t5, fail
  addi t3, t3, 4
  csrw mepc, t3
  addi s4, s4, 1
  li t3, 2
  csrs mcounteren, t3
  mret
ipi_handler:
  li t3, 0x02000000
  slli t4, s0, 2
  add t3, t3, t4
  sw zero, 0(t3)
  addi s1, s1, 1
  li t3, 1
  bne s1, t3, fail
  mret
supervisor_return:
  la t3, machine_done
  csrw mepc, t3
  li t3, 0x1800
  csrs mstatus, t3
  mret

.balign 64
supervisor_vectors:
  j fail
  j fail
  j fail
  j fail
  j fail
  j supervisor_handler
supervisor_handler:
  csrr t3, scause
  li t4, 1
  slli t4, t4, (__riscv_xlen - 1)
  ori t4, t4, 5
  bne t3, t4, fail
  li t3, -1
#if __riscv_xlen == 32
  csrw 0x15d, t3
#endif
  csrw 0x14d, t3
  addi s3, s3, 1
  li t3, 1
  bne s3, t3, fail
  sret
fail:
  li t0, 0x100000
  li t1, 0x3333
  sw t1, 0(t0)
  j fail
.section .data
.balign 64
shared: .zero 64
