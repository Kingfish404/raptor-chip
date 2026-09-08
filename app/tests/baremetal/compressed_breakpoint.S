/* Actual retirement traps; run NPC with --trap-on-ebreak and use finisher.
 * C.EBREAK and EBREAK at both IALIGN=16 positions, M/S/U origins, optionally
 * delegated to S. No EBREAK tval value is assumed by this test.
 */
#ifndef BREAK_PRIV
#define BREAK_PRIV 3
#endif
#ifndef BREAK_DELEGATE
#define BREAK_DELEGATE 0
#endif
#ifndef BREAK_CAUSE
#define BREAK_CAUSE 3
#endif
#if BREAK_DELEGATE && BREAK_PRIV == 3
#error M-origin exceptions cannot be delegated
#endif
#if BREAK_DELEGATE
#define CAUSE scause
#define EPC sepc
#define STATUS sstatus
#else
#define CAUSE mcause
#define EPC mepc
#define STATUS mstatus
#endif
.option norvc
.option norelax
.section .text
.globl _start
_start:
  csrw mstatus, zero
  csrw mie, zero
  csrw satp, zero
  la t0, machine_trap
  csrw mtvec, t0
  la t0, breakpoint_trap
  csrw stvec, t0
  li t0, (BREAK_DELEGATE << 3)
  csrw medeleg, t0
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
  li s0, 0x55a
  li s6, 0
  li s7, 0
  li s9, 0
  li s10, 0
  li a0, 1 /* simulator breakpoint halt must not masquerade as success */
  li t0, (BREAK_PRIV << 11)
  csrw mstatus, t0
  la t0, body
  csrw mepc, t0
  mret

.macro probe width, half
  la s7, 991f
  li s8, \width
  .balign 4
  .if \half
  .hword 0x0001
  .endif
991:
  .if \width == 2
  .hword 0x9002
  .else
  .word 0x00100073
  .endif
  bnez s7, fail
  li t0, 0x55a
  bne s0, t0, fail
  addi s6, s6, 1
.endm
.macro compressed_link half
  la t2, 993f
  ori t2, t2, 1 /* JALR clears target bit zero */
  la t3, 992f
  .balign 4
  .if \half
  .hword 0x0001
  .endif
  .hword 0x9382 /* C.JALR t2: link is PC+2, not expanded JALR PC+4 */
992:
  bne ra, t3, fail
  j 994f
993:
  addi s10, s10, 1
  jalr zero, ra, 0
994:
.endm
body:
  probe 2, 0
  probe 2, 1
  probe 4, 0
  probe 4, 1
  compressed_link 0
  compressed_link 1
  ecall
  j fail

.balign 4
machine_trap:
  csrr t0, mcause
  li t1, (8 + BREAK_PRIV)
  beq t0, t1, finish
#if BREAK_DELEGATE
  j fail
#endif
breakpoint_trap:
  csrr t0, CAUSE
  li t1, BREAK_CAUSE
  bne t0, t1, fail
  beqz s7, fail
  csrr t0, EPC
  bne t0, s7, fail
  csrr t0, STATUS
#if BREAK_DELEGATE
  srli t0, t0, 8
  andi t0, t0, 1
#else
  srli t0, t0, 11
  andi t0, t0, 3
#endif
  li t1, BREAK_PRIV
  bne t0, t1, fail
  add t0, s7, s8
  csrw EPC, t0
  li s7, 0
  addi s9, s9, 1
#if BREAK_DELEGATE
  sret
#else
  mret
#endif
finish:
  li t0, 4
  bne s6, t0, fail
  bne s9, t0, fail
  li t0, 2
  bne s10, t0, fail
  li t0, 0x100000
  li t1, 0x5555
  sw t1, 0(t0)
1: j 1b
fail:
  li t0, 0x100000
  li t1, 0x3333
  sw t1, 0(t0)
2: j 2b
