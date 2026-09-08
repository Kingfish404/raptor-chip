/* Runtime DECERR after store retirement: platform interrupt 16, first-error
 * diagnostics, masked accumulation, W1C and valid-memory recovery. */
#if __riscv_xlen == 64
#define REG_S sd
#define SATP_MODE 0x8000000000000000
#else
#define REG_S sw
#define SATP_MODE 0x80000000
#endif
#ifdef RAPT_HALF_STORE_ERROR
#include "fp_half_plic_state.h"
#define ERROR_PENDING 0x0301
#define ERROR_OVERFLOW 0x0303
#define ERROR_CLEARED 0x0300
#define SUPERVISOR_STATUS 0x6800
#else
#define ERROR_PENDING 0x0f01
#define ERROR_OVERFLOW 0x0f03
#define ERROR_CLEARED 0x0f00
#define SUPERVISOR_STATUS 0x800
#endif
.macro error_store data, base
#ifdef RAPT_HALF_STORE_ERROR
  fsh f0, 0(\base)
#else
  sw \data, 0(\base)
#endif
.endm
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, handler
  csrw mtvec, t0
  csrw mstatus, zero
#ifdef RAPT_HALF_STORE_ERROR
  li t0, 0x6000
  csrs mstatus, t0
  half_plic_seed
#endif
  csrw medeleg, zero
  csrw mideleg, zero
  csrw mie, zero
  li t0, 3
  csrw 0x7c0, t0
  li s8, 0x1800
  li s3, 0
  li s4, 0xc0001000
  li s5, ERROR_OVERFLOW
  li s6, 0x10000
  li t0, 0x12345678
  error_store t0, s4
  fence rw, rw
  csrr t0, 0x7c0
  li t1, ERROR_PENDING
  bne t0, t1, fail
  csrr t0, 0xfc0
  bne t0, s4, fail
  csrr t0, mip
  and t0, t0, s6
  bne t0, s6, fail
  bnez s3, fail
  li t0, 0x21000000
  error_store zero, t0
  fence rw, rw
  csrr t0, 0x7c0
  bne t0, s5, fail
  csrr t0, 0xfc0
  bne t0, s4, fail
#ifdef RAPT_CKPT_ERROR
  li s9, 64
.globl checkpoint_pending
checkpoint_pending:
  addi s9, s9, -1
  fence.i
  bnez s9, checkpoint_pending
  csrr t0, 0x7c0
  bne t0, s5, fail
  csrr t0, 0xfc0
  bne t0, s4, fail
#endif
  csrw mie, s6
  csrsi mstatus, 8
1:beqz s3, 1b
  csrr t0, 0x7c0
  li t1, ERROR_CLEARED
  bne t0, t1, fail
  csrr t0, mip
  and t0, t0, s6
  bnez t0, fail
#ifdef RAPT_CKPT_ERROR
  li s9, 64
.globl checkpoint_acknowledged
checkpoint_acknowledged:
  addi s9, s9, -1
  fence.i
  bnez s9, checkpoint_acknowledged
  csrr t0, 0x7c0
  li t1, ERROR_CLEARED
  bne t0, t1, fail
  csrr t0, 0xfc0
  bne t0, s4, fail
#endif
  li s4, 0x21000000
  li s5, ERROR_PENDING
  error_store zero, s4
  li s7, 2
2:bne s3, s7, 2b
  /* With global MIE clear, locally enabled pending IRQ must wake WFI
   * without taking the trap until MIE is set. */
  csrci mstatus, 8
  error_store zero, s4
  fence rw, rw
  wfi
  li t0, 2
  bne s3, t0, fail
  csrsi mstatus, 8
  li s7, 3
3:bne s3, s7, 3b
  csrw mie, zero
  la t0, good
  li t1, 0x13572468
  sw t1, 0(t0)
  fence rw, rw
  lw t2, 0(t0)
  bne t1, t2, fail
  /* Identity-map executable RAM and translate 0x40000000 to a physical
   * device hole. Diagnostics must contain the PA, not this store's VA. */
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
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
  la t1, level0
  li t0, 0x300004cf
  REG_S t0, 0(t1)
  srli t0, s0, 12
  li t1, SATP_MODE
  or t0, t0, t1
  csrw satp, t0
  sfence.vma
  li s4, 0xc0001000
  li s8, 0x800
  csrw mie, s6
  li t0, SUPERVISOR_STATUS
  csrw mstatus, t0
  la t0, supervisor
  csrw mepc, t0
  mret
supervisor:
  li t0, 0x40000000
  error_store zero, t0
  li s7, 4
4:bne s3, s7, 4b
  la t0, good
  lw t1, 0(t0)
  li t2, 0x13572468
  bne t1, t2, fail
  ecall
  j fail
machine_done:
  csrw mie, zero
  csrw satp, zero
  sfence.vma
  li a0, 0
  ebreak
handler:
#ifdef RAPT_HALF_STORE_ERROR
  half_plic_check
#endif
  csrr t0, mcause
  li t1, 9
  beq t0, t1, supervisor_done
  csrr t0, mcause
#if __riscv_xlen == 64
  li t1, 0x8000000000000010
#else
  li t1, 0x80000010
#endif
  bne t0, t1, fail
  csrr t0, mstatus
  li t1, 0x1800
  and t0, t0, t1
  bne t0, s8, fail
  csrr t0, mtval
  bnez t0, fail
  csrr t0, 0x7c0
  bne t0, s5, fail
  csrr t0, 0xfc0
  bne t0, s4, fail
  li t0, 3
  csrw 0x7c0, t0
  addi s3, s3, 1
  mret
supervisor_done:
  li t0, 4
  bne s3, t0, fail
  csrr t0, mstatus
  li t1, 0x1800
  and t0, t0, t1
  li t1, 0x800
  bne t0, t1, fail
  la t0, machine_done
  csrw mepc, t0
  li t0, 0x1800
  csrw mstatus, t0
  mret
fail:
  li a0, 1
  ebreak
.section .data
.balign 8
good: .dword 0

.balign 4096
root: .zero 4096
level1: .zero 4096
level0: .zero 4096
