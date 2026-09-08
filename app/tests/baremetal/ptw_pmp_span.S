/* A first-match PMP region covering only half of an Sv39 PTE must reject
 * instruction/load/store/AMO translation. Sv32 PTEs fit in that same NA4.
 * A second pass expands the entry to NAPOT8 and must succeed on both XLENs. */
#if __riscv_xlen == 64
#define REG_S sd
#define SATP_MODE 0x8000000000000000
#else
#define REG_S sw
#define SATP_MODE 0x80000000
#endif
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, machine_trap
  csrw mtvec, t0
  csrw medeleg, zero
  csrw mie, zero
  li t0, -1
  csrw pmpaddr1, t0
  la t0, level0
  srli t0, t0, 2
#ifdef PTW_PMA_TEST
  li t0, -1
#endif
  csrw pmpaddr0, t0
  la s0, root
  li t0, 0x200000cf
#if __riscv_xlen == 64
  sd t0, 16(s0)
  la t0, level1
  srli t0, t0, 2
  ori t0, t0, 1
  sd t0, 8(s0)
  la t0, level0
  srli t0, t0, 2
  ori t0, t0, 1
  la t1, level1
  sd t0, 0(t1)
#else
  li t1, 2048
  add t1, s0, t1
  sw t0, 0(t1)
  la t0, level0
  srli t0, t0, 2
  ori t0, t0, 1
  sw t0, 1024(s0)
#endif
  la t0, alias_page
  srli t0, t0, 2
  ori t0, t0, 0xcf
  la t1, level0
  REG_S t0, 0(t1)
  srli t0, s0, 12
  li t1, SATP_MODE
  or t0, t0, t1
  csrw satp, t0
  li s5, 0
enter_supervisor:
#ifdef PTW_PMA_TEST
  /* First point the final table at CLINT, then restore ordinary RAM.
   * All PMP entries permit access: failure must come from physical PMA. */
  li t0, 0x02000000
  beqz s5, 2f
  la t0, level0
2:srli t0, t0, 2
  ori t0, t0, 1
#if __riscv_xlen == 64
  la t1, level1
  sd t0, 0(t1)
#else
  sw t0, 1024(s0)
#endif
  li t0, 0x1f
#else
  li t0, 0x1f11  /* NA4 R, then unrestricted NAPOT RWX */
  beqz s5, 1f
  li t0, 0x1f19  /* NAPOT8 R */
1:
#endif
  csrw pmpcfg0, t0
  sfence.vma
  fence.i
  li t0, 0x800
  csrw mstatus, t0
  la t0, supervisor
  csrw mepc, t0
  mret
supervisor:
  li s7, 0
  li s9, 0x40000000
  li s6, 5
  la s8, load_test
  la s11, load_resume
  li s4, 0x55
load_test:
  lw s4, 0(s9)
load_resume:
  li s9, 0x40000040
  li s6, 7
  la s8, store_test
  la s11, store_resume
  li t2, 7
store_test:
  sw t2, 0(s9)
store_resume:
  la s8, amo_test
  la s11, amo_resume
  li t2, 1
amo_test:
  amoadd.w t3, t2, (s9)
amo_resume:
  li s9, 0x40000000
  li s6, 1
  mv s8, s9
  la s11, fetch_resume
  li a3, 0
  jalr ra, s9, 0
fetch_resume:
#if __riscv_xlen == 64 || defined(PTW_PMA_TEST)
  bnez s5, successful
  li t0, 4
  bne s7, t0, fail
  bnez a3, fail
  li t0, 0x55
  bne s4, t0, fail
  j next_case
#endif
successful:
  bnez s7, fail
  li t0, 1
  bne a3, t0, fail
  li s9, 0x40000040
  lw t0, 0(s9)
  li t1, 8
  bne t0, t1, fail
next_case:
  ecall
  j fail
machine_trap:
  csrr t0, mcause
  li t1, 9
  beq t0, t1, advance
  bne t0, s6, fail
  csrr t0, mepc
  bne t0, s8, fail
  csrr t0, mtval
  bne t0, s9, fail
  addi s7, s7, 1
  csrw mepc, s11
  mret
advance:
  addi s5, s5, 1
  li t0, 2
  blt s5, t0, enter_supervisor
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
  j fail
.section .data
.balign 4096
root: .zero 4096
level1: .zero 4096
level0: .zero 4096
.section .text.alias,"ax"
.balign 4096
alias_page:
  addi a3, a3, 1
  jalr zero, ra, 0
  .zero 4096-8
