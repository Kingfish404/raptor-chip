/* RV64 S-mode trap fixture, with optional Sv39 entry setup. Callers supply
 * fail/trap_records, and root/level1/level0/page/supervisor for Sv39 entry.
 * s6/s7 track expected/observed traps; prepare_supervisor_fault sets
 * s8/s10/s11 to cause/TVAL/EPC and s9 to the skip-on-fault return address.
 * The repair/retry test provides its own prepare macro and trap handler. */
.macro prepare_supervisor_fault cause, value
  li s8, \cause
  li s10, \value
  la s9, 2f
  la s11, 1f
.endm
.macro check_return
2:
  addi s6, s6, 1
  bne s6, s7, fail
.endm
.macro leaf_flags flags
  la t0, page
  srli t0, t0, 2
  ori t0, t0, \flags
  la t1, level0
  sd t0, 0(t1)
  sfence.vma
.endm

.macro enter_sv39_supervisor
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
.endm

.macro record_and_skip_supervisor_fault
  la t2, trap_records
  slli t3, s7, 6
  add t2, t2, t3
  csrr t0, scause
  sd t0, 0(t2)
  csrr t0, stval
  sd t0, 8(t2)
  csrr t0, sepc
  sd t0, 16(t2)
  sd s8, 24(t2)
  sd s10, 32(t2)
  sd s11, 40(t2)
  csrr t0, scause
  bne t0, s8, fail
  csrr t0, stval
  bne t0, s10, fail
  csrr t0, sepc
  bne t0, s11, fail
  addi s7, s7, 1
  csrw sepc, s9
  sret
.endm
