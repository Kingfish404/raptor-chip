/* Physical device PMA forbids splitting an ordinary misaligned access. */
#ifndef ACCESS_BYTES
#define ACCESS_BYTES 4
#endif
#if ACCESS_BYTES == 2
#define FAULT_LOAD lh
#define FAULT_STORE sh
#elif ACCESS_BYTES == 4
#define FAULT_LOAD lw
#define FAULT_STORE sw
#elif ACCESS_BYTES == 8 && __riscv_xlen == 64
#define FAULT_LOAD ld
#define FAULT_STORE sd
#else
#error Unsupported access width
#endif
#ifndef TRANSLATED
#define TRANSLATED 0
#endif
#ifndef PAGE_TYPE
#define PAGE_TYPE 0
#endif
#if __riscv_xlen == 64
#define STORE sd
#define ENTRY_BYTES 8
#else
#define STORE sw
#define ENTRY_BYTES 4
#endif
.option norvc
.section .text
.globl _start
_start:
  la t0, trap
  csrw mtvec, t0
  csrw mie, zero
  csrw medeleg, zero
  csrw mideleg, zero
#if TRANSLATED
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
  la t0, root
  li t1, 0x200000cf
#if __riscv_xlen == 64
  sd t1, 16(t0)
  la t1, middle
  srli t1, t1, 2
  ori t1, t1, 1
  sd t1, 8(t0)
  la t0, middle
#else
  li t2, 2048
  add t2, t0, t2
  sw t1, 0(t2)
  addi t0, t0, 1024
#endif
  la t1, leaf
  srli t1, t1, 2
  ori t1, t1, 1
  STORE t1, 0(t0)
  la t0, leaf
  li t1, 0x3c0004cf
#if __riscv_xlen == 64
  li t2, PAGE_TYPE
  slli t2, t2, 61
  or t1, t1, t2
  li t2, 0x4000000000000000
  csrw menvcfg, t2
#endif
  STORE t1, 0(t0)
  la t0, root
  srli t0, t0, 12
#if __riscv_xlen == 64
  li t1, 0x8000000000000000
#else
  li t1, 0x80000000
#endif
  or t0, t0, t1
  csrw satp, t0
  sfence.vma
  la t0, access_test
  csrw mepc, t0
  li t0, 0x800
  csrw mstatus, t0
  mret
#endif
access_test:
  li s0, 0
#if TRANSLATED
  li s1, 0x40000001
#else
  li s1, 0xf0001001
#endif
  li s2, 5
  la s3, bad_load
  la s4, after_load
bad_load:
  FAULT_LOAD t0, 0(s1)
after_load:
  li s2, 7
  la s3, bad_store
  la s4, after_store
  li t0, 0x44434241
bad_store:
  FAULT_STORE t0, 0(s1)
after_store:
  fence iorw,iorw
  li t0, 2
  bne s0, t0, fail
#if TRANSLATED
  ecall
  j fail
#else
  j finish
#endif
trap:
  csrr t0, mcause
#if TRANSLATED
  li t1, 9
  beq t0, t1, finish
#endif
  bne t0, s2, fail
  csrr t0, mepc
  bne t0, s3, fail
  csrr t0, mtval
  bne t0, s1, fail
  addi s0, s0, 1
  csrw mepc, s4
  mret
finish:
  li t0, 2
  bne s0, t0, fail
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak

.section .data
.balign 4096
root: .zero 4096
middle: .zero 4096
leaf: .zero 4096
