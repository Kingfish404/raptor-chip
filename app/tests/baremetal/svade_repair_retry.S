/* Svade S-mode repair/retry. Tests PTE unchanged on fault, then software
 * sets A/D and retries the SAME EPC. Includes real instruction-page retry. */
.option norvc
.option norelax
.section .text
.globl _start
.macro leaf_flags flags
  la t0, page
  srli t0, t0, 2
  ori t0, t0, \flags
  la t1, level0
  sd t0, 0(t1)
  sfence.vma
.endm
.macro prepare cause, flags, address
  leaf_flags \flags
  mv s5, t0
  li s8, \cause
  li s10, \address
  la s11, 1f
  addi s6, s6, 1
.endm
.macro check_count
  bne s6, s7, fail
.endm
_start:
  la t0, fail
  csrw mtvec, t0
  csrw mie, zero
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
  li t0, 0xb3ff
  csrw medeleg, t0
  la t0, supervisor_trap
  csrw stvec, t0
  la t0, root
  li t1, 0xcf
  sd t1, 0(t0)
  li t1, 0x200000cf
  sd t1, 16(t0)
  la t1, level1
  srli t1, t1, 2
  ori t1, t1, 1
  sd t1, 8(t0)
  la t0, level1
  la t1, level0
  srli t1, t1, 2
  ori t1, t1, 1
  sd t1, 0(t0)
  leaf_flags 0xcf
  la t0, root
  srli t0, t0, 12
  li t1, (8 << 60)
  or t0, t0, t1
  csrw satp, t0
  csrr t1, satp
  bne t0, t1, fail
  sfence.vma
  la t0, supervisor
  csrw mepc, t0
  li t0, 0x800
  csrw mstatus, t0
  li s6, 0
  li s7, 0
  mret
supervisor:
  li a0, 0x40000040
  li a1, 0x12345678
  prepare 13, 0x0f, 0x40000040
1: ld a2, 0(a0)
  check_count
  li t0, 0x11223344
  bne a2, t0, fail
  /* A clear, D set isolates the A requirement for stores. */
  prepare 15, 0x8f, 0x40000040
1: sd a1, 0(a0)
  check_count
  ld a2, 0(a0)
  bne a1, a2, fail
  li a1, 0x55667788
  prepare 15, 0x4f, 0x40000040
  /* A=1/D=0 loads succeed and cross-fill the store TLB. Do not fence
   * between this load and store: cached permissions must still require D. */
  ld a3, 0(a0)
  li t0, 0x12345678
  bne a3, t0, fail
1: sd a1, 0(a0)
  check_count
  ld a2, 0(a0)
  bne a1, a2, fail
  li a5, 0
  li a0, 0x40000000
  prepare 12, 0x0f, 0x40000000
  mv s11, a0
1: jalr ra, a0, 0
  check_count
  li t0, 1
  bne a5, t0, fail
  li t0, 4
  bne s7, t0, fail
  li t0, 0x00100000
  li t1, 0x5555
  sw t1, 0(t0)
3: j 3b
.balign 4, 0
supervisor_trap:
  /* Fault must not set any A/D bit in the actual leaf. */
  la t1, level0
  ld t0, 0(t1)
  bne t0, s5, fail
  la t2, trap_records
  slli t3, s7, 6
  add t2, t2, t3
  csrr t0, scause
  sd t0, 0(t2)
  bne t0, s8, fail
  csrr t0, stval
  sd t0, 8(t2)
  bne t0, s10, fail
  csrr t0, sepc
  sd t0, 16(t2)
  bne t0, s11, fail
  sd s5, 24(t2)
  /* Check data through the identity mapping before repairing the fault. */
  la t0, page
  ld t3, 64(t0)
  sd t3, 32(t2)
  li t4, 0x11223344
  li t5, 2
  bltu s7, t5, 4f
  li t4, 0x12345678
  beq s7, t5, 4f
  li t4, 0x55667788
4: bne t3, t4, fail
  ori t0, s5, 0xc0
  sd t0, 0(t1)
  sfence.vma
  addi s7, s7, 1
  /* Do not advance SEPC: the faulting access must complete on retry. */
  sret
.balign 4, 0
fail:
  li t0, 0x00100000
  li t1, 0x3333
  sw t1, 0(t0)
5: j 5b
.section .data
.balign 4096
root: .zero 4096
level1: .zero 4096
level0: .zero 4096
page:
  .4byte 0x00178793 /* addi a5,a5,1 */
  .4byte 0x00008067 /* ret */
  .zero 56
  .dword 0x11223344
  .zero (4096-72)
.balign 8
.globl trap_records, trap_records_end
trap_records: .zero 512
trap_records_end:
