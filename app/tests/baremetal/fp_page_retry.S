/* RV64 Sv39/Svade: cross-page FP loads fault on the second page's A=0;
 * aligned FP stores fault on D=0. S-mode repairs the leaf and retries the
 * same instruction. Faulting loads must preserve the whole FPR/FCSR.
 */
#if __riscv_xlen != 64
#error This test requires RV64 Sv39
#endif
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, fail
  csrw mtvec, t0
  la t0, handler
  csrw stvec, t0
  li t0, 0xa000
  csrw medeleg, t0
  csrw mie, zero
#ifdef FP_PAGE_NESTED_IRQ
  li t0, 2
  csrw mideleg, t0
  csrw mie, t0
#endif
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
  la s0, root
  li t0, 0x200000cf
  sd t0, 16(s0) /* identity S gigapage at 0x80000000 */
  la t0, l1
  srli t0, t0, 2
  ori t0, t0, 1
  sd t0, 8(s0)
  la t0, l0
  srli t0, t0, 2
  ori t0, t0, 1
  la t1, l1
  sd t0, 0(t1)
  la s1, l0
  la t0, page0
  srli t0, t0, 2
  ori t0, t0, 0xc7
  sd t0, 0(s1)
  la t0, page1
  srli t0, t0, 2
  ori t0, t0, 0xc7
  sd t0, 8(s1)
  srli t0, s0, 12
  li t1, 0x8000000000000000
  or t0, t0, t1
  csrw satp, t0
  sfence.vma
  li t0, 0x6800
  csrw mstatus, t0
  la t0, supervisor
  csrw mepc, t0
  mret
supervisor:
#ifdef FP_PAGE_NESTED_IRQ
  li s0, 0 /* nested interrupt count */
#endif
  li s4, 0 /* case */
  li s5, 0 /* trap count */
  li s6, 0x40001000 /* exact fault VA */
  li s7, 0x123456789abcdef0 /* original FP destination / store source */
next_case:
  fmv.d.x ft0, s7
  li t0, 0x43
  csrw fcsr, t0
  la t0, page1
  li t1, 0x88776655443322
  sd t1, 0(t0)
  la t0, page0
  li t1, 4095
  add t0, t0, t1
  li t1, 0xab
  sb t1, 0(t0)
  la t0, page1
  srli t0, t0, 2
  li t1, 3
  blt s4, t1, load_setup
  ori t0, t0, 0x47 /* valid RW, A=1 D=0 */
  sd t0, 8(s1)
  sfence.vma
  li s2, 15
  li t1, 3
  beq s4, t1, store_d
  li t1, 4
  beq s4, t1, store_w
  la s3, store_h_insn
store_h_insn:
  fsh ft0, 0(s6)
  j store_check
store_d:
  la s3, store_d_insn
store_d_insn:
  fsd ft0, 0(s6)
  j store_check
store_w:
  la s3, store_w_insn
store_w_insn:
  fsw ft0, 0(s6)
store_check:
  la t0, page1
  ld t1, 0(t0)
  li t2, 3
  beq s4, t2, check_d
  li t2, 4
  beq s4, t2, check_w
  li t2, 0x8877665544def0
  j check_value
check_w:
  li t2, 0x8877669abcdef0
  j check_value
check_d:
  mv t2, s7
check_value:
  bne t1, t2, fail
  j done_case
load_setup:
  ori t0, t0, 0x87 /* valid RW, A=0 D=1 */
  sd t0, 8(s1)
  sfence.vma
  li s2, 13
  addi a1, s6, -1
  beqz s4, load_d
  li t1, 1
  beq s4, t1, load_w
  la s3, load_h_insn
load_h_insn:
  flh ft0, 0(a1)
  li t2, 0xffffffffffff22ab
  j load_check
load_d:
  la s3, load_d_insn
load_d_insn:
  fld ft0, 0(a1)
  li t2, 0x88776655443322ab
  j load_check
load_w:
  la s3, load_w_insn
load_w_insn:
  flw ft0, 0(a1)
  li t2, 0xffffffff443322ab
load_check:
  fmv.x.d t1, ft0
  bne t1, t2, fail
done_case:
  addi s4, s4, 1
  bne s4, s5, fail
  li t0, 6
  blt s4, t0, next_case
#ifdef FP_PAGE_NESTED_IRQ
  bne s0, t0, fail
#endif
#ifdef FP_PAGE_SINVAL
  /* Warm a valid load translation, then replace its physical page. A/D
   * repair alone cannot demonstrate eviction of a cached valid entry. */
  ld t0, 0(s6)
  li t1, 0x8877665544def0
  bne t0, t1, fail
  la t0, page0
  li t1, 0x1020304050607080
  sd t1, 0(t0)
  srli t0, t0, 2
  ori t0, t0, 0xc7
  sd t0, 8(s1)
  sfence.w.inval
  sinval.vma s6, zero
  sfence.inval.ir
  ld t0, 0(s6)
  li t1, 0x1020304050607080
  bne t0, t1, fail
#endif
pass:
  li a0, 0
  ebreak
.balign 4
handler:
  csrr t0, scause
#ifdef FP_PAGE_NESTED_IRQ
  bltz t0, nested_interrupt
#endif
  bne t0, s2, fail
  csrr t0, sepc
  bne t0, s3, fail
  csrr t0, stval
  bne t0, s6, fail
  /* A fault must not partly replace the load destination, nor modify
   * the store source or floating-point exception/rounding state. */
  fmv.x.d t0, ft0
  bne t0, s7, fail
  csrr t0, fcsr
  li t1, 0x43
  bne t0, t1, fail
  la t0, page1
  ld t0, 0(t0)
  li t1, 0x88776655443322
  bne t0, t1, fail
#ifdef FP_PAGE_NESTED_IRQ
  /* Save the outer exception CSRs before deliberately allowing a nested
   * S interrupt. The leaf is still faulty during the nested handler. */
  csrr s8, sepc
  csrr s9, sstatus
  csrr s11, stval
  li s10, 1
  csrsi sip, 2
  csrsi sstatus, 2
wait_nested:
  bnez s10, wait_nested
  csrci sstatus, 2
  csrw sepc, s8
  csrw sstatus, s9
  csrw stval, s11
  csrw scause, s2
#endif
  ld t0, 8(s1)
  ori t0, t0, 0xc0
  sd t0, 8(s1)
#ifdef FP_PAGE_SINVAL
  sfence.w.inval
  sinval.vma s6, zero
  sfence.inval.ir
#else
  sfence.vma s6, zero
#endif
  addi s5, s5, 1
  sret
#ifdef FP_PAGE_NESTED_IRQ
nested_interrupt:
  slli t0, t0, 1
  li t1, 2
  bne t0, t1, fail
  csrr t0, sstatus
  andi t0, t0, 0x100 /* SPP=S: the page-fault handler was interrupted */
  beqz t0, fail
  fmv.x.d t0, ft0
  bne t0, s7, fail
  csrr t0, fcsr
  li t1, 0x43
  bne t0, t1, fail
  ld t0, 8(s1)
  andi t0, t0, 0xc0
  li t1, 0xc0
  beq t0, t1, fail /* repair must occur after this interrupt */
  csrci sip, 2
  li s10, 0
  addi s0, s0, 1
  sret
#endif
fail:
  li a0, 1
  ebreak
  j fail
.section .data
.balign 4096
root: .zero 4096
l1: .zero 4096
l0: .zero 4096
page0: .zero 4096
/* A guard forces the second virtual page to be physically nonadjacent. */
guard: .zero 4096
page1: .zero 4096
