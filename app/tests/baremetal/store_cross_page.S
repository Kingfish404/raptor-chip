/* Pretranslated stores across noncontiguous pages; includes RV32 FSD's
 * three-beat case where only the third beat crosses the page boundary. */
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
  la s1, level0
  la t0, page_a
  srli t0, t0, 2
  ori t0, t0, 0xcf
  REG_S t0, 0(s1)
  la t0, page_b
  srli t0, t0, 2
  ori t0, t0, 0xcf
  REG_S t0, (__riscv_xlen/8)(s1)
  srli t0, s0, 12
  li t1, SATP_MODE
  or t0, t0, t1
  csrw satp, t0
  sfence.vma
  li t0, 0x6800       /* FS=Dirty, MPP=S */
  csrw mstatus, t0
  la t0, supervisor
  csrw mepc, t0
  mret
supervisor:
  la s0, page_a
  li t0, 4080
  add s0, s0, t0
  la s1, page_b
  la s2, guard
  la s3, pattern
  fld ft0, 0(s3)
  li s4, 4088
again:
  li t0, 0
  li t1, 0x55
clear:
  add t2, s0, t0
  sb t1, 0(t2)
  add t2, s1, t0
  sb t1, 0(t2)
  add t2, s2, t0
  sb t1, 0(t2)
  addi t0, t0, 1
  li t2, 16
  blt t0, t2, clear
  fence iorw, iorw
  li t0, 0x40000000
  add t0, t0, s4
  fsd ft0, 0(t0)
  fence iorw, iorw
  li s5, 0
check_bytes:
  li t0, 4080
  add t0, t0, s5      /* relative virtual byte offset */
  sub t1, t0, s4
  li t3, 8
  li t4, 0x55
  bgeu t1, t3, expected_a
  add t2, s3, t1
  lbu t4, 0(t2)
expected_a:
  add t2, s0, s5
  lbu t5, 0(t2)
  bne t4, t5, fail
  li t0, 4096
  add t0, t0, s5
  sub t1, t0, s4
  li t4, 0x55
  bgeu t1, t3, expected_b
  add t2, s3, t1
  lbu t4, 0(t2)
expected_b:
  add t2, s1, s5
  lbu t5, 0(t2)
  bne t4, t5, fail
  add t2, s2, s5
  lbu t5, 0(t2)
  li t4, 0x55
  bne t4, t5, fail
  addi s5, s5, 1
  li t0, 16
  blt s5, t0, check_bytes
  addi s4, s4, 1
  li t0, 4096
  blt s4, t0, again
  ecall
  j fail
machine_trap:
  csrr t0, mcause
  li t1, 9
  bne t0, t1, fail
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
  j fail
.section .data
.balign 8
pattern: .dword 0xfedcba9876543210
.balign 4096
root: .zero 4096
level1: .zero 4096
level0: .zero 4096
page_a: .zero 4096
guard: .zero 4096
page_b: .zero 4096
