/* RV32/RV64 whole-core supervisor regression. All opcodes under test use literal
 * encodings so assembler extension defaults cannot silently remove coverage.
 * Execute with NEMU differential checking and delayed AXI responses.
 */
#if __riscv_xlen == 64
#define REG_S sd
#define REG_L ld
#define REG_LU lwu
#define SATP_MODE 0x8000000000000000
#define TIMER_CAUSE 0x8000000000000005
#else
#define REG_S sw
#define REG_L lw
#define REG_LU lw
#define SATP_MODE 0x80000000
#define TIMER_CAUSE 0x80000005
#endif
.option norvc
.option norelax
.section .text
.globl _start

.macro expect_illegal encoding
  la s8, 991f
991:
  .word \encoding
  bnez s8, fail
.endm

_start:
  la t0, machine_trap
  csrw mtvec, t0
  csrw medeleg, zero
  csrw mie, zero
  li t0, 0x20
  csrw mideleg, t0
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
  li s9, 0
  li s8, 0

  /* Identity map the kernel region, then construct a three-level alias
   * whose root non-leaf carries G. This was rejected by the old walker. */
  la s0, root
  li t0, 0x200000cf
#if __riscv_xlen == 64
  REG_S t0, 16(s0)
  la t0, level1
  srli t0, t0, 2
  ori t0, t0, 0x21
  REG_S t0, 8(s0)
  la t0, level0
  srli t0, t0, 2
  ori t0, t0, 1
  la t1, level1
  REG_S t0, 0(t1)
#else
  li t1, 2048
  add t1, t1, s0
  REG_S t0, 0(t1)           /* 4 MiB identity leaf */
  la t0, level0
  srli t0, t0, 2
  ori t0, t0, 0x21
  REG_S t0, 1024(s0)        /* Sv32 global non-leaf at VA 0x40000000 */
#endif
  la t0, page_a
  srli t0, t0, 2
  ori t0, t0, 0xcf
  la s1, level0
  REG_S t0, 0(s1)
  srli t0, s0, 12
  li t1, SATP_MODE
  or t0, t0, t1
  csrw satp, t0
  sfence.vma
  fence.i
  /* Sstc exists, but S access starts with both enable gates closed. */
  csrw 0x30a, zero
  csrw mcounteren, zero
  li t0, 0x800
  csrw mstatus, t0
  la t0, supervisor
  csrw mepc, t0
  mret

supervisor:
  expect_illegal 0x30200073 /* MRET from S */
  expect_illegal 0x14d022f3 /* csrr t0,stimecmp with STCE=0 */
  li a7, 1
  ecall                     /* enable STCE, keep TM clear */
  expect_illegal 0x14d022f3
  li a7, 2
  ecall                     /* enable TM too */
  li t0, -1
#if __riscv_xlen == 32
  csrw 0x15d, t0
#endif
  csrw 0x14d, t0
  csrr t1, 0x14d
  bne t0, t1, fail
#if __riscv_xlen == 64
  expect_illegal 0x15d022f3 /* RV32-only stimecmph */
#else
  expect_illegal 0x31a022f3 /* M-mode-only menvcfgh */
#endif
  li t0, 0x40
  csrw sstatus, t0
  csrr t1, sstatus
  andi t1, t1, 0x40
  bnez t1, fail

  /* Exercise the actual delegated Sstc interrupt, including pending reads
   * with SIE=0 and clearing the comparator in the supervisor handler. */
#ifdef TEST_VECTORED
  la t0, supervisor_vectors
  ori t0, t0, 1
#else
  la t0, supervisor_timer
#endif
  csrw stvec, t0
  li s7, 0
  li t0, 0x20
  csrw sie, t0
  csrw 0x14d, zero
#if __riscv_xlen == 32
  csrw 0x15d, zero
#endif
  csrr t0, sip
  andi t0, t0, 0x20
  beqz t0, fail
  csrsi sstatus, 2
wait_timer:
  beqz s7, wait_timer
  csrci sstatus, 2
  li t0, 1
  bne s7, t0, fail
  csrr t0, sip
  andi t0, t0, 0x20
  bnez t0, fail

  /* With TVM=1, invalidate traps but the two ordering-only fences do not. */
  li a7, 3
  ecall
  expect_illegal 0x16000073
  .word 0x18000073
  .word 0x18100073
  li a7, 4
  ecall

  li s2, 0x40000000
  REG_L t0, 0(s2)
  li t1, 0x1122
  bne t0, t1, fail
  addi t0, s2, 64
  jalr ra, t0, 0
  li t0, 19
  bne a1, t0, fail
  li s3, 32
  li s4, 0
remap:
  /* Change data and executable translation at the same VA. Alternate back
   * and forth to force both ITLB and DTLB to discard old cached entries. */
  xori s4, s4, 1
  la t0, page_a
  li s5, 0x1122
  li s6, 19
  beqz s4, install
  la t0, page_b
  li s5, 0x3344
  li s6, 23
install:
  srli t0, t0, 2
  ori t0, t0, 0xcf
  REG_S t0, 0(s1)
  .word 0x18000073           /* SFENCE.W.INVAL */
  .word 0x16090073           /* SINVAL.VMA s2,x0 (includes global translations) */
  .word 0x18100073           /* SFENCE.INVAL.IR */
  REG_L t0, 0(s2)
  bne t0, s5, fail
  addi t0, s2, 64
  jalr ra, t0, 0
  bne a1, s6, fail
  addi s3, s3, -1
  bnez s3, remap
  li t0, 5
  bne s9, t0, fail
  li a7, 5
  ecall
  j fail

.balign 4
supervisor_timer:
  csrr t3, scause
  li t4, TIMER_CAUSE
  bne t3, t4, fail
  csrr t3, stval
  bnez t3, fail
  li t3, -1
#if __riscv_xlen == 32
  csrw 0x15d, t3
#endif
  csrw 0x14d, t3
  addi s7, s7, 1
  sret

.balign 4
machine_trap:
  csrr t0, mcause
  li t1, 9
  beq t0, t1, service
  li t1, 2
  bne t0, t1, fail
  beqz s8, fail
  csrr t0, mepc
  bne t0, s8, fail
  REG_LU t1, 0(s8)
  csrr t2, mtval
  bne t1, t2, fail
  li s8, 0
  addi s9, s9, 1
  j return_s
service:
  li t0, 1
  beq a7, t0, enable_stce
  li t0, 2
  beq a7, t0, enable_tm
  li t0, 3
  beq a7, t0, set_tvm
  li t0, 4
  beq a7, t0, clear_tvm
  li t0, 5
  beq a7, t0, pass
  j fail
enable_stce:
#if __riscv_xlen == 64
  li t0, 0x8000000000000000
  csrw 0x30a, t0
#else
  li t0, 0x80000000
  csrw 0x31a, t0
#endif
  j return_s
enable_tm:
  li t0, 2
  csrw mcounteren, t0
  j return_s
set_tvm:
  li t0, 0x100000
  csrs mstatus, t0
  j return_s
clear_tvm:
  li t0, 0x100000
  csrc mstatus, t0
return_s:
  csrr t0, mepc
  addi t0, t0, 4
  csrw mepc, t0
  mret
pass:
  li a0, 0
  ebreak
  j pass
fail:
  li a0, 1
  ebreak
  j fail

.section .data
.balign 4096
root: .zero 4096
level1: .zero 4096
level0: .zero 4096
page_a:
  .dword 0x1122
  .zero 56
  addi a1, zero, 19
  ret
  .zero 4024
page_b:
  .dword 0x3344
  .zero 56
  addi a1, zero, 23
  ret
  .zero 4024

#ifdef TEST_VECTORED
.section .text
.balign 128
supervisor_vectors:
  .rept 5
  j fail
  .endr
  j supervisor_timer
#endif
