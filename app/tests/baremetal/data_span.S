/* Data accesses beginning inside SRAM must not escape its physical backing. */
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
.macro fault_access op, reg, cause
  li s6, \cause
  la s8, 1f
  la s11, 2f
1:
  \op \reg, 0(s9)
2:
.endm
_start:
  la t0, machine_trap
  csrw mtvec, t0
  csrw medeleg, zero
  csrw mie, zero
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
  li t0, 0x6000
  csrw mstatus, t0
  li s7, 0
  li s0, 0x0f001ff0
  li t1, 16
  li t2, 0x5a
fill:
  sb t2, 0(s0)
  addi s0, s0, 1
  addi t1, t1, -1
  bnez t1, fill
  /* Positive unaligned word fully inside SRAM, across an XLEN-word boundary. */
  li s0, 0x0f001ff7
  li t2, 0x5a5a5a5a
  sw t2, 0(s0)
  lw t3, 0(s0)
  bne t2, t3, fail
  li s9, 0x0f001fff
  li s10, 0x0f002000
  fault_access sh, t2, 7
  fault_access sw, t2, 7
#if __riscv_xlen == 64
  fault_access sd, t2, 7
#else
  fmv.w.x f0, t2
  fault_access fsd, f0, 7
#endif
  /* Failed stores must not have altered even the mapped tail byte. */
  li s0, 0x0f001ff0
  li t1, 16
  li t2, 0x5a
check_tail:
  lbu t3, 0(s0)
  bne t3, t2, fail
  addi s0, s0, 1
  addi t1, t1, -1
  bnez t1, check_tail
  li s4, 0x55
  fault_access lh, s4, 5
  fault_access lw, s4, 5
#if __riscv_xlen == 64
  fault_access ld, s4, 5
#else
  fault_access fld, f0, 5
#endif
  li t0, 0x55
  bne s4, t0, fail
  li t0, 6
  bne s7, t0, fail
  /* Identity-map code and install two independently mapped data pages. */
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
  li t0, 0x03c004cf
  REG_S t0, 0(t1)
  la t0, next_page
  srli t0, t0, 2
  ori t0, t0, 0xcf
  REG_S t0, (__riscv_xlen / 8)(t1)
  srli t0, s0, 12
  li t1, SATP_MODE
  or t0, t0, t1
  csrw satp, t0
  sfence.vma
  li t0, 0x6800
  csrw mstatus, t0
  la t0, supervisor
  csrw mepc, t0
  mret
supervisor:
  li s9, 0x40000fff
  li t2, 0x5a5a5a5a
  sw t2, 0(s9)
  lw t3, 0(s9)
  bne t2, t3, fail
  /* Remap only page two to the SRAM hole. The first byte stays writable. */
  la t1, level0
  li t0, 0x03c008cf
  REG_S t0, (__riscv_xlen / 8)(t1)
  sfence.vma
  li s10, 0x40001000
  li t2, 0x12345678
  fault_access sh, t2, 7
  fault_access sw, t2, 7
#if __riscv_xlen == 64
  fault_access sd, t2, 7
#else
  fault_access fsd, f0, 7
#endif
  lbu t3, 0(s9)
  li t0, 0x5a
  bne t3, t0, fail
  li s4, 0x55
  fault_access lh, s4, 5
  fault_access lw, s4, 5
#if __riscv_xlen == 64
  fault_access ld, s4, 5
#else
  fault_access fld, f0, 5
#endif
  li t0, 0x55
  bne s4, t0, fail
  ecall
  j fail
machine_trap:
  csrr t0, mcause
  li t1, 9
  beq t0, t1, finish
  bne t0, s6, fail
  csrr t0, mepc
  bne t0, s8, fail
  csrr t0, mtval
  bne t0, s10, fail
  addi s7, s7, 1
  csrw mepc, s11
  mret
finish:
  li t0, 12
  bne s7, t0, fail
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak

.section .data
.balign 4096
root: .zero 4096
level1: .zero 4096
level0: .zero 4096
next_page: .zero 4096
