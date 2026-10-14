.option norvc
#ifndef NEMU_MULTIDIFF_ITERATIONS
#define NEMU_MULTIDIFF_ITERATIONS 64
#endif
.section .text
.globl _start
_start:
  csrr s0, mhartid
#ifdef REPLAY_FAULTS
  li s6, 0
#endif
  la t0, trap
  csrw mtvec, t0
#ifdef NEGATIVE_FINISHER
  li t0, 0x100000
  li t1, 0x3333
  sw t1, 0(t0)
#endif
#ifdef NEGATIVE_MMIO
  li t0, 0x10000000
  lw t1, 0(t0)
#endif
#ifdef NEGATIVE_WFI
  wfi
#endif
#ifdef NEGATIVE_TIME
  rdtime t0
#endif
#ifdef NEGATIVE_IRQ
  li t0, 2
  csrs mip, t0
  csrs mie, t0
  csrsi mstatus, 8
#endif
  li s1, 0
  ecall
  li t0, 1
  bne s1, t0, fail
  li t0, 0x6000
  csrs mstatus, t0
  addi t0, s0, 1
  fcvt.d.w f0, t0
  fadd.d f1, f0, f0
  fcvt.w.d t1, f1
  slli t0, t0, 1
  bne t0, t1, fail
  la s2, counters
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0xf
  csrw pmpcfg0, t0
  slli t0, s0, 12
  la t1, roots
  add t1, t1, t0
#if __riscv_xlen == 64
  la t2, leaves
  add t2, t2, t0
  srli t3, t2, 12
  slli t3, t3, 10
  ori t3, t3, 1
  sd t3, 0(t1)
  slli t3, s0, 21
#else
  mv t2, t1
  slli t3, s0, 22
#endif
  li t4, 0x80000000
  add t3, t3, t4
  li t4, 0x10000
  add t4, t4, t3
  addi t5, s0, 0x100
  sw t5, 0(t4)
  srli t3, t3, 12
  slli t3, t3, 10
  ori t3, t3, 0xc7
#if __riscv_xlen == 64
  sd t3, 0(t2)
  li t3, 0x8000000000000000
#else
  sw t3, 0(t2)
  li t3, 0x80000000
#endif
  srli t1, t1, 12
  or t1, t1, t3
  csrw satp, t1
  sfence.vma
#ifdef REPLAY_FAULTS
  csrr s9, mstatus
  li s8, 0
  li s7, 0x40000000
  li t0, -6145
  and s10, s9, t0
  li t0, 0x20800
  or s10, s10, t0
  csrw mstatus, s10
  li s6, 15
  sw zero, 0(s7)
  csrw mstatus, s10
  amoadd.w zero, zero, (s7)
  csrw mstatus, s10
  li s6, 13
  lw zero, 0(s7)
  csrw mstatus, s9
  li s6, 0
  li t0, 3
  bne s8, t0, fail
#endif
  li s3, NEMU_MULTIDIFF_ITERATIONS
count_loop:
  csrr s4, mstatus
  li t0, -6145
  and t0, s4, t0
  li t1, 0x20800
  or t0, t0, t1
  csrw mstatus, t0
  li t0, 0x10000
  lw t1, 0(t0)
  csrw mstatus, s4
  bne t1, t5, fail
  li t0, 1
  amoadd.w.aqrl zero, t0, (s2)
  addi t1, s2, 4
retry:
  lr.w.aq t2, (t1)
  addi t2, t2, 1
  sc.w.rl t3, t2, (t1)
  bnez t3, retry
  addi s3, s3, -1
  bnez s3, count_loop
  addi t1, s2, 8
  amoadd.w.aqrl zero, t0, (t1)
wait_done:
  lw t2, 8(s2)
  li t3, HARTS
  bne t2, t3, wait_done
#if HARTS > 1
  beqz s0, reserve
  li t0, 1
  bne s0, t0, wait_finish
wait_reserved:
  lw t0, 12(s2)
  beqz t0, wait_reserved
  sb zero, 19(s2)
  li t0, 2
  sw t0, 12(s2)
  j wait_finish
reserve:
  addi t0, s2, 16
  lr.w t1, (t0)
  li t2, 1
  sw t2, 12(s2)
wait_interference:
  lw t2, 12(s2)
  li t3, 2
  bne t2, t3, wait_interference
  sc.w t2, t1, (t0)
  beqz t2, fail
#endif
  bnez s0, wait_finish
  li t0, HARTS * NEMU_MULTIDIFF_ITERATIONS
  lw t1, 0(s2)
  bne t0, t1, fail
  lw t1, 4(s2)
  bne t0, t1, fail
  fence rw, rw
  li t0, 0x100000
  li t1, 0x5555
  sw t1, 0(t0)
wait_finish:
  j wait_finish
fail:
  li t0, 0x100000
  li t1, 0x3333
  sw t1, 0(t0)
  j fail
trap:
#ifdef REPLAY_FAULTS
  beqz s6, ecall_trap
  csrr t0, mcause
  bne t0, s6, fail
  csrr t0, mtval
  bne t0, s7, fail
  csrr t0, mepc
  addi t0, t0, 4
  csrw mepc, t0
  addi s8, s8, 1
  mret
ecall_trap:
#endif
  csrr t0, mcause
  li t1, 11
  bne t0, t1, fail
  csrr t0, mepc
  addi t0, t0, 4
  csrw mepc, t0
  addi s1, s1, 1
  mret
.section .data
.balign 64
counters:
  .word 0, 0, 0, 0, 0
.section .bss
.balign 4096
roots:
  .skip 16384
leaves:
  .skip 16384
