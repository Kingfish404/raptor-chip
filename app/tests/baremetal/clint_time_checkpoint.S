/* Save at checkpoint_time; the resumed stream must see the persisted CLINT
 * through both MMIO and architectural time, including timer pending state. */
.option norvc
.option norelax
.section .text
.globl _start, checkpoint_time
_start:
  csrw mstatus, zero
  csrw mie, zero
  la t0, fail
  csrw mtvec, t0
  li s0, 0x0200bff8
  li s1, 0x02004000
  li t0, -1
  sw t0, 0(s1)
  li t0, 1
  sw t0, 4(s1)
  sw zero, 0(s1)
  li t0, 0x12345678
  sw t0, 4(s0)
  li t0, 0x34560000
  sw t0, 0(s0)
  fence iorw,iorw
#ifdef CHECKPOINT_SSTC
#if __riscv_xlen == 64
  li t0, 0x100000000
  csrw 0x14d, t0
  li t0, 0x8000000000000000
  csrw menvcfg, t0
#else
  li t0, 1
  csrw 0x15d, t0
  csrw 0x14d, zero
  li t0, 0x80000000
  csrw 0x31a, t0
#endif
#endif
checkpoint_time:
  nop
  /* Leave sufficient instructions for the save trigger to quiesce the core. */
  .rept 128
  nop
  .endr
#ifdef CHECKPOINT_SSTC
#if __riscv_xlen == 64
  csrr t0, menvcfg
  li t1, 0x8000000000000000
  bne t0, t1, fail
  csrr t0, 0x14d
  li t1, 0x100000000
#else
  csrr t0, 0x31a
  li t1, 0x80000000
  bne t0, t1, fail
  csrr t0, 0x14d
  bnez t0, fail
  csrr t0, 0x15d
  li t1, 1
#endif
  bne t0, t1, fail
  csrr t0, mip
  andi t0, t0, 32
  beqz t0, fail
#endif
  li t3, 0x12345678
  lw t0, 4(s0)
  bne t0, t3, fail
#if __riscv_xlen == 64
  csrr t0, time
  srli t0, t0, 32
#else
  csrr t0, timeh
#endif
  bne t0, t3, fail
  /* The low word cannot wrap in this bounded test. Fence the MMIO samples
   * around time to check that all three observations share one clock. */
  lw t0, 0(s0)
  fence iorw,iorw
  csrr t1, time
  fence iorw,iorw
  lw t2, 0(s0)
#if __riscv_xlen == 64
  slli t1, t1, 32
  srli t1, t1, 32
#endif
  bltu t1, t0, fail
  bltu t2, t1, fail
  csrr t0, mip
  andi t0, t0, 128
  beqz t0, fail
#ifdef CHECKPOINT_SSTC
  /* A latched software STIP is insufficient: the restored comparator must
   * follow time writes in both directions after resumption. */
  sw zero, 4(s0)
  fence iorw,iorw
  csrr t0, mip
  andi t0, t0, 32
  bnez t0, fail
  li t0, 2
  sw t0, 4(s0)
  fence iorw,iorw
  csrr t0, mip
  andi t0, t0, 32
  beqz t0, fail
#endif
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
  j fail
