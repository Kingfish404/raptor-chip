/* mtime is a writable 64-bit MMIO counter. Check high fields, allowing
 * the low counter bits to advance between software accesses. */
.option norvc
.option norelax
.section .text
.globl _start
_start:
  csrw mstatus, zero
  csrw mie, zero
  la t0, fail
  csrw mtvec, t0
  li s0, 0x0200bff8
  li t0, 0x12345678
  sw t0, 4(s0)
  li t1, 0x34560000
  sw t1, 0(s0)
  fence iorw,iorw
  lw t2, 4(s0)
  bne t2, t0, fail
#ifdef CHECK_CSR_TIME
#if __riscv_xlen == 64
  csrr t2, time
  srli t2, t2, 32
#else
  csrr t2, timeh
#endif
  bne t2, t0, fail
#endif
  lw t2, 0(s0)
  srli t2, t2, 16
  li t3, 0x3456
  bne t2, t3, fail
#if __riscv_xlen == 64
  li t0, 0x2345678956780000
  sd t0, 0(s0)
  fence iorw,iorw
  ld t1, 0(s0)
  srli t0, t0, 16
  srli t1, t1, 16
  bne t1, t0, fail
#endif
  li t0, 0x11223344
  sw t0, 4(s0)
  fence iorw,iorw
  lw t1, 4(s0)
  bne t1, t0, fail
#ifdef CHECK_CSR_TIME
  /* Place Sstc's deadline at 2^32. Only mtime high-half writes below
   * change whether STIP is pending; no elapsed-time assumption is needed. */
#if __riscv_xlen == 64
  li t0, 0x8000000000000000
  csrw menvcfg, t0
  li t0, 0x100000000
  csrw 0x14d, t0
#else
  li t0, 0x80000000
  csrw 0x31a, t0
  li t0, 1
  csrw 0x15d, t0
  csrw 0x14d, zero
#endif
  sw zero, 4(s0)
  sw zero, 0(s0)
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
  sw zero, 4(s0)
  fence iorw,iorw
  csrr t0, mip
  andi t0, t0, 32
  bnez t0, fail
#endif
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
  j fail
