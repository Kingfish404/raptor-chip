/* Execute a real page at VA zero under Sv32/Sv39. Unexpected traps fail. */
.option norvc
.section .text
.globl _start
#if __riscv_xlen == 64
#define STORE_PTE sd
#else
#define STORE_PTE sw
#endif
_start:
  la t0, trap_fail
  csrw mtvec, t0
  csrw mie, zero
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0

  la t0, target_page
  srli t0, t0, 2
  ori t0, t0, 0x4b       /* V/R/X/A, supervisor leaf */
  la t1, leaf_table
  STORE_PTE t0, 0(t1)
  srli t0, t1, 2
  ori t0, t0, 1
#if __riscv_xlen == 64
  la t1, middle_table
  STORE_PTE t0, 0(t1)
  srli t0, t1, 2
  ori t0, t0, 1
#endif
  la t1, root_table
  STORE_PTE t0, 0(t1)
  srli t0, t1, 12
#if __riscv_xlen == 64
  li t2, 8
  slli t2, t2, 60
#else
  li t2, 0x80000000
#endif
  or t0, t0, t2
  csrw satp, t0
  sfence.vma
  li t0, 0x1800
  csrc mstatus, t0
  li t0, 0x800           /* MPP=S */
  csrs mstatus, t0
  csrw mepc, zero
  li a0, 1
  mret
trap_fail:
  li a0, 1
  ebreak

.balign 4096
target_page:
  li a3, 42
  li a0, 0
  ebreak

.section .bss
.balign 4096
root_table:
  .space 4096
#if __riscv_xlen == 64
middle_table:
  .space 4096
#endif
leaf_table:
  .space 4096
