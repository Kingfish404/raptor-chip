/* Self-checking whole-core memory/recovery exercise, shared by RV32/RV64.
 * Bare-mode physical accesses: this is not a page-table permission test.
 */
.section .text
.globl _start
_start:
  la s0, buffer
  li s1, 128
  li s2, 0
loop:
  slli t0, s2, 5
  add t0, s0, t0
  li t1, 0x12345678
  xor t1, t1, s2
  sw t1, 31(t0)
  lw t2, 31(t0)
  bne t1, t2, fail
  li t3, 0x80
  sb t3, 7(t0)
  lbu t2, 7(t0)
  bne t2, t3, fail
  lb t2, 7(t0)
  li t3, -128
  bne t2, t3, fail
  li t3, 0x5678
  sh t3, 63(t0)
  lhu t2, 63(t0)
  bne t2, t3, fail
  addi s2, s2, 1
  blt s2, s1, loop
  fence rw,rw

  /* Precise architectural store ordering around atomics and redirects. */
  li t1, 41
  sw t1, 0(s0)
  li t2, 1
  amoadd.w t3, t2, (s0)
  bne t3, t1, fail
retry:
  lr.w t3, (s0)
  addi t3, t3, 1
  sc.w t4, t3, (s0)
  bnez t4, retry
  lw t5, 0(s0)
  li t6, 43
  bne t5, t6, fail

#if __riscv_xlen == 64
  li t1, 0x1122334455667788
  sd t1, 3(s0)
  ld t2, 3(s0)
  bne t1, t2, fail
#endif

  /* RV32 FSD/FLD can require three beats; cross a physical 4-KiB boundary. */
  li t0, 0x2000
  csrs mstatus, t0
  la t0, fp_pattern
  fld f0, 0(t0)
  li t1, 4093
  add t1, s0, t1
  fsd f0, 0(t1)
  fence rw,rw
  fld f1, 0(t1)
  fsd f1, 0(s0)
  lw t2, 0(s0)
  li t3, 0x55667788
  bne t2, t3, fail
  lw t2, 4(s0)
  li t3, 0x11223344
  bne t2, t3, fail
  fence.i
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
.section .data
.balign 8
fp_pattern:
  .quad 0x1122334455667788
.balign 4096
buffer:
  .zero 8192
