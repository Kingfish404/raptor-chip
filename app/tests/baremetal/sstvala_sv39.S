/* Sv39 S-mode STVAL/SEPC checks, including second-page instruction/data
 * faults and software-managed A/D bits. No hardware A/D update assumed. */
.option norvc
.option norelax
.section .text
.globl _start
#include "supervisor_trap_macros.h"
_start:
  enter_sv39_supervisor
supervisor:
  li a0, 0x40001000
  prepare_supervisor_fault 13, 0x40001000
1: ld t1, 0(a0)
  check_return
  prepare_supervisor_fault 15, 0x40001000
1: sd zero, 0(a0)
  check_return
  prepare_supervisor_fault 12, 0x40001000
  mv s11, a0
1: jalr zero, a0, 0
  check_return
  li a0, 0x40000ffc
  prepare_supervisor_fault 13, 0x40001000
1: ld t1, 0(a0)
  check_return
  prepare_supervisor_fault 15, 0x40001000
1: sd zero, 0(a0)
  check_return
  li a0, 0x40000ffe
  prepare_supervisor_fault 12, 0x40001000
  mv s11, a0
1: jalr zero, a0, 0
  check_return
  /* A clear for read/write/execute; then A set, D clear for store. */
  leaf_flags 0x0f
  li a0, 0x40000000
  prepare_supervisor_fault 13, 0x40000000
1: ld t1, 0(a0)
  check_return
  prepare_supervisor_fault 15, 0x40000000
1: sd zero, 0(a0)
  check_return
  prepare_supervisor_fault 12, 0x40000000
  mv s11, a0
1: jalr zero, a0, 0
  check_return
  leaf_flags 0x4f
  prepare_supervisor_fault 15, 0x40000000
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
  record_and_skip_supervisor_fault
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
