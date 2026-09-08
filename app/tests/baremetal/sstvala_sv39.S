/* Sv39 S-mode STVAL/SEPC checks, including second-page instruction/data
 * faults and software-managed A/D bits. No hardware A/D update assumed. */
.option norvc
.option norelax
.section .text
.globl _start
.macro prepare cause, value
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
  li a0, 0x40001000
  prepare 13, 0x40001000
1: ld t1, 0(a0)
  check_return
  prepare 15, 0x40001000
1: sd zero, 0(a0)
  check_return
  prepare 12, 0x40001000
  mv s11, a0
1: jalr zero, a0, 0
  check_return
  li a0, 0x40000ffc
  prepare 13, 0x40001000
1: ld t1, 0(a0)
  check_return
  prepare 15, 0x40001000
1: sd zero, 0(a0)
  check_return
  li a0, 0x40000ffe
  prepare 12, 0x40001000
  mv s11, a0
1: jalr zero, a0, 0
  check_return
  /* A clear for read/write/execute; then A set, D clear for store. */
  leaf_flags 0x0f
  li a0, 0x40000000
  prepare 13, 0x40000000
1: ld t1, 0(a0)
  check_return
  prepare 15, 0x40000000
1: sd zero, 0(a0)
  check_return
  prepare 12, 0x40000000
  mv s11, a0
1: jalr zero, a0, 0
  check_return
  leaf_flags 0x4f
  prepare 15, 0x40000000
1: sd zero, 0(a0)
  check_return
  li t0, 10
  bne s7, t0, fail
  li t0, 0x00100000
  li t1, 0x5555
  sw t1, 0(t0)
3: j 3b
.balign 4, 0
supervisor_trap:
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
.balign 4, 0
fail:
  li t0, 0x00100000
  li t1, 0x3333
  sw t1, 0(t0)
4: j 4b

.section .data
.balign 4096
root: .zero 4096
level1: .zero 4096
level0: .zero 4096
page: .zero 4094
  .2byte 0x0013
.balign 8
.globl trap_records, trap_records_end
trap_records: .zero 768
trap_records_end:
