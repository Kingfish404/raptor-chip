/* Measure forwarding across ordinary branch recovery with delayed stores.
 * Both paths check the newest value. No fence is needed for this same-hart
 * store/load sequence. Fixed 16-bit LFSR makes branch outcomes reproducible. */
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, fail
  csrw mtvec, t0
  csrw mie, zero
  csrw mstatus, zero
  la s0, area
  li s1, 0xace1
  li t5, 0xb400
  li s3, 512
#if __riscv_xlen == 64
  li s2, 0x1122334455660000
#else
  li s2, 0x11220000
#endif
loop:
  andi t0, s1, 1
  srli s1, s1, 1
  neg t1, t0
  and t1, t1, t5
  xor s1, s1, t1
#if __riscv_xlen == 64
  sd s2, 0(s0)
#else
  sw s2, 0(s0)
#endif
  bnez t0, taken
#if __riscv_xlen == 64
  ld t2, 0(s0)
#else
  lw t2, 0(s0)
#endif
  bne t2, s2, fail
  j join
taken:
#if __riscv_xlen == 64
  ld t3, 0(s0)
#else
  lw t3, 0(s0)
#endif
  bne t3, s2, fail
join:
  addi s2, s2, 1
  addi s3, s3, -1
  bnez s3, loop
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
  j fail
.section .data
.balign 64
area: .zero 64
