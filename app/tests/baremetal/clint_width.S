.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, fail
  csrw mtvec, t0
  csrw mstatus, zero
  csrw mie, zero
  li s0, 0x02004000
#if __riscv_xlen == 64
  li t0, 0x1234567876543210
  sd t0, 0(s0)
#else
  li t0, 0x12345678
  sw t0, 4(s0)
#endif
  fence iorw,iorw
  li t0, 0x34567812
  sw t0, 0(s0)
  fence iorw,iorw
  lw t1, 0(s0)
  bne t1, t0, fail
#if __riscv_xlen == 64
  ld t1, 0(s0)
  li t0, 0x1234567834567812
  bne t1, t0, fail
#endif
  lw t1, 4(s0)
  li t0, 0x12345678
  bne t1, t0, fail
  li t0, 0x23456789
  sw t0, 4(s0)
  fence iorw,iorw
  lw t1, 4(s0)
  bne t1, t0, fail
  lw t1, 0(s0)
  li t0, 0x34567812
  bne t1, t0, fail
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
  j fail
