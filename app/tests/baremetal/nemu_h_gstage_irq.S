.option norvc
.option norelax
.section .text
.globl _start
_start:
  csrr s0, mhartid
  li s1, 0
  la t0, machine_trap
  csrw mtvec, t0
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0xf
  csrw pmpcfg0, t0
  li t0, 0x8000000000000000
  csrw 0x30a, t0
  csrw 0x60a, t0
  li t0, 0x40
  csrw 0x603, t0
  csrw mie, t0
  li t0, 0x100
  csrw medeleg, t0
  csrw 0x602, t0
  csrr t1, 0x602
  bne t0, t1, fail
  li t0, 2
  csrw mcounteren, t0
  csrw 0x606, t0
  la t0, guest_trap
  csrw 0x205, t0
  li t0, 2
  csrw 0x200, t0
#ifdef NEMU_H_IRQ_CLOCK
  rdtime t0
#ifdef NEMU_H_IRQ_DELTA
  li t1, -4096
  slli t2, s0, 8
  sub t1, t1, t2
  csrw 0x605, t1
  add t0, t0, t1
#endif
  addi t0, t0, 1000
  csrw 0x24d, t0
#else
  csrw 0x24d, zero
#endif
  csrr t0, 0x644
  andi t0, t0, 0x40
#ifdef NEMU_H_IRQ_CLOCK
  bnez t0, fail
#else
  beqz t0, fail
#endif
  li t0, 0x1800
  csrc mstatus, t0
  li t0, 0x8000000800
  csrs mstatus, t0
  la t0, guest_start
  csrw mepc, t0
  mret

guest_start:
  li t0, 1
  beq s1, t0, guest_done
  wfi
  j guest_start
guest_done:
  la t0, vu_guest
  csrw sepc, t0
  li t0, 0x100
  csrc sstatus, t0
  sret
vu_guest:
  ecall
  j fail

guest_trap:
  csrr t0, scause
  li t1, 8
  beq t0, t1, guest_ecall
  li t1, 0x8000000000000005
  bne t0, t1, fail
  csrr t0, sepc
  la t1, guest_start
#ifdef NEMU_H_IRQ_CLOCK
  bltu t0, t1, fail
  la t1, guest_done
  bgeu t0, t1, fail
  andi t0, t0, 3
  bnez t0, fail
#else
  bne t0, t1, fail
#endif
  li t0, -1
  csrw 0x14d, t0
  addi s1, s1, 1
  sret

guest_ecall:
  csrr t0, sepc
  la t1, vu_guest
  bne t0, t1, fail
  li s1, 2
  ecall
  j fail

machine_trap:
  csrr t0, mcause
  li t1, 10
  bne t0, t1, fail
  li t0, 2
  bne s1, t0, fail
  csrw mie, zero
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
parked:
  wfi
  j parked

fail:
  li t0, 0x100000
  li t1, 0x3333
  sw t1, 0(t0)
  j fail

.section .bss
.align 2
completed:
  .word 0
