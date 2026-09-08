/* PMA fault/recovery matrix: default device CBO.ZERO; PMA_READONLY=1
 * selects ROM/flash store, AMO and CBO.ZERO protection. */
#ifndef PMA_READONLY
#define PMA_READONLY 0
#endif
/* Devices do not support cache-block zero, even with writable PMP/PTEs. */
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
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
  li t0, 0xf0
  csrw menvcfg, t0
  li s7, 0
#if PMA_READONLY
  li s9, 0x20001000
  jal ra, test_readonly
  li s9, 0x30001000
  jal ra, test_readonly
  li t0, 6
#else
  li s9, 0x02000000
  jal ra, test_zero_fault
  li s9, 0x10000000
  jal ra, test_zero_fault
  li t0, 4
#endif
  bne s7, t0, fail
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
#if PMA_READONLY
  li t0, 0x080004cf /* MROM 0x20001000, V/R/W/X/A/D */
#else
  li t0, 0x008000cf /* CLINT 0x02000000, V/R/W/X/A/D */
#endif
  la t1, level0
  REG_S t0, 0(t1)
  srli t0, s0, 12
  li t1, SATP_MODE
  or t0, t0, t1
  csrw satp, t0
  sfence.vma
  li t0, 0x800
  csrw mstatus, t0
  la t0, supervisor
  csrw mepc, t0
  mret
supervisor:
  li s9, 0x40000000
#if PMA_READONLY
  jal ra, test_readonly
  li t0, 9
#else
  jal ra, test_zero_fault
  li t0, 6
#endif
  bne s7, t0, fail
  ecall
  j fail
#if PMA_READONLY
test_readonly:
  lw s3, 0(s9)
  la s8, store_test
  la s11, store_resume
  li t2, 0x123
store_test:
  sw t2, 0(s9)
store_resume:
  li s4, 0x55
  la s8, amo_test
  la s11, amo_resume
amo_test:
  amoadd.w s4, t2, (s9)
amo_resume:
  li t0, 0x55
  bne s4, t0, fail
  addi s9, s9, 3
  la s8, zero_test
  la s11, zero_resume
zero_test:
  .insn i 0x0f, 2, x0, s9, 4 /* cbo.zero, original unaligned operand */
zero_resume:
  addi s9, s9, -3
  .insn i 0x0f, 2, x0, s9, 1 /* cbo.clean: read permission suffices */
  lw t0, 0(s9)
  bne t0, s3, fail
  ret
#else
test_zero_fault:
  la s8, zero_aligned
  la s11, zero_aligned_resume
zero_aligned:
  .insn i 0x0f, 2, x0, s9, 4
zero_aligned_resume:
  addi s9, s9, 63
  la s8, zero_unaligned
  la s11, zero_unaligned_resume
zero_unaligned:
  .insn i 0x0f, 2, x0, s9, 4
zero_unaligned_resume:
  addi s9, s9, -63
  ret
#endif
machine_trap:
  csrr t0, mcause
  li t1, 9
  beq t0, t1, restore_ram
  li t1, 7
  bne t0, t1, fail
  csrr t0, mepc
  bne t0, s8, fail
  csrr t0, mtval
  bne t0, s9, fail
  addi s7, s7, 1
  csrw mepc, s11
  mret
restore_ram:
  la t0, ram_page
  srli t0, t0, 2
  ori t0, t0, 0xcf
  la t1, level0
  REG_S t0, 0(t1)
  sfence.vma
  la t0, test_ram
  csrw mepc, t0
  mret
test_ram:
  li t2, 7
  sw t2, 0(s9)
  li t2, 1
  amoadd.w t3, t2, (s9)
  li t0, 7
  bne t3, t0, fail
  .insn i 0x0f, 2, x0, s9, 4
  lw t0, 0(s9)
  bnez t0, fail
  /* Check every byte and both neighboring blocks after an unaligned zero.
   * This also exercises loads while the committed SQ zero is still draining. */
  mv t1, s9
  li t2, 192
  li t3, 0x5a
fill_ram:
  sb t3, 0(t1)
  addi t1, t1, 1
  addi t2, t2, -1
  bnez t2, fill_ram
  addi t1, s9, 67
  .insn i 0x0f, 2, x0, t1, 4
  li t2, 0
check_ram:
  add t1, s9, t2
  lbu t0, 0(t1)
  li t3, 0x5a
  li t4, 64
  bltu t2, t4, check_byte
  li t4, 128
  bgeu t2, t4, check_byte
  li t3, 0
check_byte:
  bne t0, t3, fail
  addi t2, t2, 1
  li t4, 192
  bltu t2, t4, check_ram
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
ram_page: .zero 4096
