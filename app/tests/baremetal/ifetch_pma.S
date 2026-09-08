/* Physical device execution is forbidden in Bare and translated modes.
 * PMP and PTE.X allow access, so only execute PMA may reject the request.
 * Restore a RAM mapping and execute it to verify recovery and invalidation. */
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
  li s7, 0
  li s9, 0x02000000
  mv s8, s9
  la s11, bare_resume
  jalr ra, s9, 0
bare_resume:
  li t0, 1
  bne s7, t0, fail
  /* At the last physical halfword, only an uncompressed instruction
   * accesses the next region. The fault PC and faulting VA differ by 2. */
  li s8, 0x8ffffffe
  li s9, 0x90000000
  li t0, 0x0693
  sh t0, 0(s8)
  fence.i
  la s11, boundary_resume
  jalr ra, s8, 0
boundary_resume:
  li t0, 2
  bne s7, t0, fail
  li t0, 0x8082  /* C.JR ra needs no second physical page. */
  sh t0, 0(s8)
  fence.i
  jalr ra, s8, 0
  li t0, 2
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
  li t0, 0x0080004b  /* CLINT PPN, V/R/X/A */
  la t1, level0
  REG_S t0, 0(t1)
  srli t0, s0, 12
  li t1, SATP_MODE
  or t0, t0, t1
  csrw satp, t0
  sfence.vma
  fence.i
  li t0, 0x800
  csrw mstatus, t0
  la t0, supervisor
  csrw mepc, t0
  mret
supervisor:
  li a3, 0
  li s9, 0x40000000
  mv s8, s9
  la s11, supervisor_resume
  jalr ra, s9, 0
supervisor_resume:
  li t0, 3
  bne s7, t0, fail
  bnez a3, fail
  ecall
  j fail
machine_trap:
  csrr t0, mcause
  li t1, 9
  beq t0, t1, restore_mapping
  li t1, 1
  bne t0, t1, fail
  csrr t0, mepc
  bne t0, s8, fail
  csrr t0, mtval
  bne t0, s9, fail
  addi s7, s7, 1
  csrw mepc, s11
  mret
restore_mapping:
  la t0, executable_page
  srli t0, t0, 2
  ori t0, t0, 0x4b
  la t1, level0
  REG_S t0, 0(t1)
  sfence.vma
  fence.i
  la t0, execute_ram
  csrw mepc, t0
  mret
execute_ram:
  li s9, 0x40000000
  jalr ra, s9, 0
  li t0, 1
  bne a3, t0, fail
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
executable_page:
  addi a3, a3, 1
  jalr zero, ra, 0
