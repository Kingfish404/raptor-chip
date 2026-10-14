/* Real Sv39 SUM/MXR transitions, including permission changes on hot
 * TLB entries without SFENCE.VMA. S-mode traps check cause, VA and EPC. */
.option norvc
.option norelax
.section .text
.globl _start
#include "supervisor_trap_macros.h"
_start:
  enter_sv39_supervisor
supervisor:
  /* Execute-only user page: S reads require BOTH SUM and MXR. */
  leaf_flags 0xd9
  li a0, 0x40000000
  li t0, (1 << 18)
  csrc sstatus, t0
  li t0, (1 << 19)
  csrs sstatus, t0
  prepare_supervisor_fault 13, 0x40000000
1: ld a2, 0(a0)
  check_return
  li t0, (1 << 19)
  csrc sstatus, t0
  li t0, (1 << 18)
  csrs sstatus, t0
  prepare_supervisor_fault 13, 0x40000000
1: ld a2, 0(a0)
  check_return
  li t0, (1 << 19)
  csrs sstatus, t0
  ld a2, 0(a0)
  li t0, 0x11223344
  bne a2, t0, fail
  /* Keep the mapping; turning MXR off must revoke the primed read. */
  li t0, (1 << 19)
  csrc sstatus, t0
  prepare_supervisor_fault 13, 0x40000000
1: ld a2, 0(a0)
  check_return
  /* A writable user page: SUM controls S-mode stores as well. */
  leaf_flags 0xd7
  li t0, (1 << 18)
  csrc sstatus, t0
  li a1, 0x55667788
  prepare_supervisor_fault 15, 0x40000000
1: sd a1, 0(a0)
  check_return
  la t0, page
  ld t1, 0(t0)
  li t0, 0x11223344
  bne t0, t1, fail
  li t0, (1 << 18)
  csrs sstatus, t0
  sd a1, 0(a0)
  ld a2, 0(a0)
  bne a1, a2, fail
  /* No fence here: both load and store translations are already primed. */
  li t0, (1 << 18)
  csrc sstatus, t0
  prepare_supervisor_fault 13, 0x40000000
1: ld a2, 0(a0)
  check_return
  li a1, -1
  prepare_supervisor_fault 15, 0x40000000
1: sd a1, 0(a0)
  check_return
  la t0, page
  ld t1, 0(t0)
  li t0, 0x55667788
  bne t0, t1, fail
  /* SUM permits data access, never S-mode instruction fetch from U pages. */
  leaf_flags 0xdf
  li t0, (1 << 18)
  csrs sstatus, t0
  prepare_supervisor_fault 12, 0x40000000
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
.balign 4096
root: .zero 4096
level1: .zero 4096
level0: .zero 4096
page: .dword 0x11223344
  .zero (4096-8)
.balign 8
.globl trap_records, trap_records_end
trap_records: .zero 512
trap_records_end:
