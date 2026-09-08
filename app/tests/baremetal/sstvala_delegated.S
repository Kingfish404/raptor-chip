/* Direct S-mode trap-value checks. Fixed RV64 Bare/PMP scope.
 * Page faults and split-instruction portions require separate Sv39 tests.
 */
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
_start:
  la t0, fail
  csrw mtvec, t0
  csrw mie, zero
  csrw satp, zero
  li t0, 0x3ff
  csrw medeleg, t0
  /* Deny one physical word, with a lower-priority all-memory allow. */
  li t0, (0x80400000 >> 2)
  csrw pmpaddr0, t0
  li t0, -1
  csrw pmpaddr1, t0
  li t0, 0x1f10
  csrw pmpcfg0, t0
  la t0, supervisor_trap
  csrw stvec, t0
  la t0, supervisor
  csrw mepc, t0
  li t0, 0x800
  csrw mstatus, t0
  li s6, 0
  li s7, 0
  mret
supervisor:
  prepare 2, 0x0000000b
1: .4byte 0x0000000b
  check_return
  /* C.ADDI4SPN with zero immediate and rd=x9: reserved, nonzero bits. */
  prepare 2, 0x0004
1: .2byte 0x0004
  check_return
  li a0, 0x80200001
  /* This core reports access faults for non-emulatable misaligned LR/SC. */
  prepare 5, 0x80200001
1: lr.w t1, (a0)
  check_return
  prepare 7, 0x80200001
1: sc.w t1, zero, (a0)
  check_return
  li a0, 0x80400000
  prepare 5, 0x80400000
1: lw t1, 0(a0)
  check_return
  prepare 7, 0x80400000
1: sw zero, 0(a0)
  check_return
  prepare 1, 0x80400000
  mv s11, a0
1: jalr zero, a0, 0
  check_return
  li t0, 7
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
.balign 8
.globl trap_records, trap_records_end
trap_records: .zero 512
trap_records_end:
