/* Bare RV64 aliases share data, instruction fetch and PMP permissions.
 * Keep warm copies while switching aliases to expose duplicate cache tags. */
#if __riscv_xlen != 64
#error This test requires RV64
#endif
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, trap
  csrw mtvec, t0
  csrw mstatus, zero
  csrw satp, zero
  li s6, 0
  la s0, data
  slli s0, s0, 32
  srli s0, s0, 32
  li s2, 0xffffffff00000000
  or s1, s0, s2
  /* Warm the same L1D line through both encodings, then write each way. */
  sd zero, 0(s0)
  ld t0, 0(s0)
  ld t1, 0(s1)
  or t0, t0, t1
  bnez t0, fail
  li s3, 0x1122334455667788
  li s4, 16
data_loop:
  sd s3, 0(s0)
  ld t0, 0(s1)
  bne t0, s3, fail
  addi s3, s3, 1
  sd s3, 0(s1)
  ld t0, 0(s0)
  bne t0, s3, fail
  addi s4, s4, -1
  bnez s4, data_loop
  /* Cross-page unaligned stores exercise every SQ physical beat. */
  li t0, 4093
  add t3, s0, t0
  or t4, t3, s2
  sd s3, 0(t3)
  ld t0, 0(t4)
  bne t0, s3, fail
  sd s3, 0(t4)
  ld t0, 0(t3)
  bne t0, s3, fail
  /* LR and SC compare the canonical physical byte set. */
  lr.d t0, (s0)
  sc.d t1, s3, (s1)
  bnez t1, fail
  lr.d t0, (s1)
  sc.d t1, s3, (s0)
  bnez t1, fail
  /* A 32-bit instruction at page+4094 uses the slow Bare translation. */
  la t3, cross_page_code
  slli t3, t3, 32
  srli t3, t3, 32
  jalr ra, t3, 0
  li t0, 37
  bne a0, t0, fail
  or t3, t3, s2
  jalr ra, t3, 0
  li t0, 37
  bne a0, t0, fail
  /* Low-page PMP grant applies to both aliases under MPRV/S. */
  srli t0, s0, 2
  ori t0, t0, 511
  csrw pmpaddr0, t0
  la s7, allowed_code
  slli s7, s7, 32
  srli s7, s7, 32
  srli t0, s7, 2
  ori t0, t0, 511
  csrw pmpaddr2, t0
  la s8, denied_code
  slli s8, s8, 32
  srli s8, s8, 32
  srli t0, s8, 2
  ori t0, t0, 511
  csrw pmpaddr3, t0
  li s9, 0x989d001b          /* data RW; code RX locked; denied code locked */
  csrw pmpcfg0, s9
  li t0, 0x20800            /* MPRV, MPP=S */
  csrw mstatus, t0
  ld t1, 0(s0)
  ld t2, 0(s1)
  bne t1, s3, fail
  bne t2, s3, fail
  addi s3, s3, 1
  sd s3, 0(s1)
  ld t1, 0(s0)
  bne t1, s3, fail
  sd s3, 0(s0)
  ld t1, 0(s1)
  bne t1, s3, fail
  csrw mstatus, zero
  /* Both low and all-ones fetches use the low-address locked PMP grant. */
  li s4, 8
fetch_loop:
  jalr ra, s7, 0
  li t0, 37
  bne a0, t0, fail
  or t1, s7, s2
  jalr ra, t1, 0
  li t0, 37
  bne a0, t0, fail
  addi s4, s4, -1
  bnez s4, fetch_loop
  /* Denied low-page loads/stores trap identically, preserving the VA. */
  li s9, 0x989d0018
  csrw pmpcfg0, s9
  li s5, 5
  mv s10, s0
  la s11, after_low_load
  li t0, 0x20800
  csrw mstatus, t0
  ld t1, 0(s0)
  j fail
after_low_load:
  mv s10, s1
  la s11, after_alias_load
  li t0, 0x20800
  csrw mstatus, t0
  ld t1, 0(s1)
  j fail
after_alias_load:
  li s5, 7
  mv s10, s0
  la s11, after_low_store
  li t0, 0x20800
  csrw mstatus, t0
  sd s3, 0(s0)
  j fail
after_low_store:
  mv s10, s1
  la s11, after_alias_store
  li t0, 0x20800
  csrw mstatus, t0
  sd s3, 0(s1)
  j fail
after_alias_store:
  li s5, 1
  mv s10, s8
  la s11, after_low_fetch
  jalr ra, s8, 0
  j fail
after_low_fetch:
  or s10, s8, s2
  la s11, after_alias_fetch
  jalr ra, s10, 0
  j fail
after_alias_fetch:
  /* An unrelated upper half must never alias the mapped low address. */
  li t0, 0x200000000
  or s10, s0, t0
  li s5, 5
  la s11, after_invalid_load
  ld t1, 0(s10)
  j fail
after_invalid_load:
  li s5, 7
  la s11, after_invalid_store
  sd s3, 0(s10)
  j fail
after_invalid_store:
  li t0, 0x200000000
  or s10, s7, t0
  li s5, 1
  la s11, after_invalid_fetch
  jalr ra, s10, 0
  j fail
after_invalid_fetch:
  li t0, 9
  bne s6, t0, fail
  li a0, 0
  ebreak
trap:
  li t0, 0x20000
  csrc mstatus, t0
  csrr t0, mcause
  bne t0, s5, fail
  csrr t0, mtval
  bne t0, s10, fail
  csrw mepc, s11
  addi s6, s6, 1
  mret
fail:
  csrw mstatus, zero
  li a0, 1
  ebreak
  j fail
.balign 4096
allowed_code:
  li a0, 37
  ret
.balign 4096
denied_code:
  j fail
.balign 4096
  .space 4094
cross_page_code:
  li a0, 37
  ret
.section .data
.balign 4096
data:
  .dword 0
