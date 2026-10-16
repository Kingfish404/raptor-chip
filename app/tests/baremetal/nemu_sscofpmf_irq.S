.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, machine_trap
  csrw mtvec, t0
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0xf
  csrw pmpcfg0, t0
  li t0, 0x2000
  csrw mie, t0
  csrsi mstatus, 8
  csrw mip, t0
  la t0, machine_count
  lw t1, 0(t0)
  li t2, 1
  bne t1, t2, fail
  la t0, supervisor_trap
  csrw stvec, t0
  li t0, 0x2000
  csrw mideleg, t0
  li t0, 0x1800
  csrc mstatus, t0
  li t0, 0x800
  csrs mstatus, t0
  la t0, supervisor
  csrw mepc, t0
  mret

supervisor:
  csrsi sstatus, 2
  li t0, 0x2000
  csrs sip, t0
  la t0, supervisor_count
  lw t1, 0(t0)
  li t2, 1
  bne t1, t2, fail
  li t0, 0x100000
  li t1, 0x5555
  sw t1, 0(t0)
  j fail

machine_trap:
  csrr t0, mcause
#if __riscv_xlen == 64
  li t1, 0x800000000000000d
#else
  li t1, 0x8000000d
#endif
  bne t0, t1, fail
  li t0, 0x2000
  csrc mip, t0
  la t0, machine_count
  lw t1, 0(t0)
  addi t1, t1, 1
  sw t1, 0(t0)
  mret

supervisor_trap:
  csrr t0, scause
#if __riscv_xlen == 64
  li t1, 0x800000000000000d
#else
  li t1, 0x8000000d
#endif
  bne t0, t1, fail
  li t0, 0x2000
  csrc sip, t0
  la t0, supervisor_count
  lw t1, 0(t0)
  addi t1, t1, 1
  sw t1, 0(t0)
  sret

fail:
  li t0, 0x100000
  li t1, 0x3333
  sw t1, 0(t0)
  j fail

.section .bss
.align 2
machine_count:
  .word 0
supervisor_count:
  .word 0
