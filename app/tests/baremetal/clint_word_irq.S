/* 32-bit mtimecmp updates must preserve the other half and control MTIP
 * on both XLENs. Exercise real trap entry and return, not only readback. */
.option norvc
.option norelax
.section .text
.globl _start
_start:
  csrw mstatus, zero
  csrw mie, zero
#ifdef TEST_VECTORED
  la t0, vector_table
  ori t0, t0, 1
#else
  la t0, timer
#endif
  csrw mtvec, t0
  li s0, 0x02004000
  li s1, 0
  li t0, -1
#if __riscv_xlen == 64
  sd t0, 0(s0)
#else
  sw t0, 0(s0)
  sw t0, 4(s0)
#endif
  fence iorw,iorw
  sw zero, 0(s0)
  fence iorw,iorw
  csrr t0, mip
  andi t0, t0, 128
  bnez t0, fail
  li t0, 128
  csrw mie, t0
  csrsi mstatus, 8
  sw zero, 4(s0)
  fence iorw,iorw
wait_timer:
  beqz s1, wait_timer
  csrci mstatus, 8
  li t0, 1
  bne s1, t0, fail
  csrr t0, mip
  andi t0, t0, 128
  bnez t0, fail
  li a0, 0
  ebreak
timer:
  bnez s1, fail
  csrr t3, mcause
#if __riscv_xlen == 64
  li t4, 0x8000000000000007
#else
  li t4, 0x80000007
#endif
  bne t3, t4, fail
  csrr t3, mtval
  bnez t3, fail
  li t3, -1
  sw t3, 4(s0)
  fence iorw,iorw
  addi s1, s1, 1
  mret
fail:
  csrci mstatus, 8
  csrw mie, zero
  li a0, 1
  ebreak
  j fail

#ifdef TEST_VECTORED
.balign 128
vector_table:
  .rept 7
  j fail
  .endr
  j timer
#endif
