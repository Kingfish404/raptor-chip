/* Direct S-mode trap-value checks. Fixed RV64 Bare/PMP scope.
 * Page faults and split-instruction portions require separate Sv39 tests.
 */
.option norvc
.option norelax
.section .text
.globl _start
#include "supervisor_trap_macros.h"
_start:
  la t0, fail
  csrw mtvec, t0
  csrw mie, zero
  csrw satp, zero
  li t0, 0x3ff
  csrw medeleg, t0
  /* Deny one physical page, with a lower-priority all-memory allow. */
  li t0, (0x80400000 >> 2)
  csrw pmpaddr0, t0
  li t0, -1
  csrw pmpaddr1, t0
  li t0, 0x1f18
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
  prepare_supervisor_fault 2, 0x0000000b
1: .4byte 0x0000000b
  check_return
  /* C.ADDI4SPN with zero immediate and rd=x9: reserved, nonzero bits. */
  prepare_supervisor_fault 2, 0x0004
1: .2byte 0x0004
  check_return
  li a0, 0x80200001
  /* This core reports access faults for non-emulatable misaligned LR/SC. */
  prepare_supervisor_fault 5, 0x80200001
1: lr.w t1, (a0)
  check_return
  prepare_supervisor_fault 7, 0x80200001
1: sc.w t1, zero, (a0)
  check_return
  li a0, 0x80400000
  prepare_supervisor_fault 5, 0x80400000
1: lw t1, 0(a0)
  check_return
  prepare_supervisor_fault 7, 0x80400000
1: sw zero, 0(a0)
  check_return
  prepare_supervisor_fault 1, 0x80400000
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
  record_and_skip_supervisor_fault
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
