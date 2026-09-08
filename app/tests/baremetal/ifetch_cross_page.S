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
  la t0, page_a
  srli t0, t0, 2
  ori t0, t0, 0x4b
  la t1, level0
  REG_S t0, 0(t1)
  /* ADDI a3,zero,1 straddles two virtual pages with noncontiguous PAs.
   * The following JALR returns to the supervisor test code. */
  la t1, page_a
  li t0, 4094
  add t1, t1, t0
  li t0, 0x0693
  sh t0, 0(t1)
  la t1, page_b
  li t0, 0x0010
  sh t0, 0(t1)
  li t0, 0x8067
  sh t0, 2(t1)
  sh zero, 4(t1)
  srli t0, s0, 12
  li t1, SATP_MODE
  or t0, t0, t1
  csrw satp, t0
  li s5, 0
enter:
  li t2, 2
  bne s5, t2, 2f
  la t1, page_a
  li t0, 4094
  add t1, t1, t0
  li t0, 0x8082  /* C.JR ra: must not fetch the inaccessible next page. */
  sh t0, 0(t1)
2:
  la t0, page_b
  srli t0, t0, 2
  ori t0, t0, 0x4b
  li t2, 1
  beq s5, t2, 1f
  li t0, 0
1:la t1, level0
  REG_S t0, (__riscv_xlen/8)(t1)
  sfence.vma
  fence.i
  li t0, 0x800
  csrw mstatus, t0
  la t0, supervisor
  csrw mepc, t0
  mret
supervisor:
  li s7, 0
  li a3, 0
  li s9, 0x40000ffe
  la s11, resumed
  jalr ra, s9, 0
resumed:
  li t0, 2
  beq s5, t0, compressed_case
  beqz s5, fault_case
  bnez s7, fail
  li t0, 1
  bne a3, t0, fail
  j next_case
fault_case:
  li t0, 1
  bne s7, t0, fail
  bnez a3, fail
  j next_case
compressed_case:
  bnez s7, fail
  bnez a3, fail
next_case:
  ecall
  j fail
machine_trap:
  csrr t0, mcause
  li t1, 9
  beq t0, t1, advance
  li t1, 12
  bne t0, t1, fail
  csrr t0, mepc
  bne t0, s9, fail
  csrr t0, mtval
  li t1, 0x40001000
  bne t0, t1, fail
  addi s7, s7, 1
  csrw mepc, s11
  mret
advance:
  addi s5, s5, 1
  li t0, 3
  blt s5, t0, enter
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
page_a: .zero 4096
physical_gap: .zero 4096
page_b: .zero 4096
