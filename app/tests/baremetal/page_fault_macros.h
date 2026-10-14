/* Two-page Sv32/Sv39 fixture. Callers provide root/level1/level0,
 * page_a/page_b, supervisor and machine_trap; s0/s1 and t0/t1 are clobbered.
 * The fault handler checks cause=s6, EPC=s8, TVAL=s9, increments s7, and
 * skips one 32-bit instruction. Successful S-mode ECALL branches to pass. */
#if __riscv_xlen == 64
#define REG_S sd
#define SATP_MODE 0x8000000000000000
#else
#define REG_S sw
#define SATP_MODE 0x80000000
#endif
.macro map_two_pages_and_enter_s
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
.endm

.macro check_machine_page_fault
  csrr t0, mcause
  li t1, 9
  beq t0, t1, pass
  bne t0, s6, fail
  csrr t0, mepc
  bne t0, s8, fail
  csrr t1, mtval
  bne t1, s9, fail
  addi s7, s7, 1
  addi t0, t0, 4
  csrw mepc, t0
  mret
.endm
