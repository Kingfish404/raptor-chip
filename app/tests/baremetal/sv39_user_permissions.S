/* Actual U-mode Sv39 data/execute ownership. Trap handler remains on a
 * supervisor-only identity mapping; user code has its own U-page alias. */
#ifndef DATA_USER
#define DATA_USER 1
#endif
#ifndef EXEC_USER
#define EXEC_USER 1
#endif
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, fail
  csrw mtvec, t0
  csrw mie, zero
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
  li t0, 0xb100
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
  la t0, level0
  la t1, data_page
  srli t1, t1, 2
  ori t1, t1, (0xc7 | (DATA_USER << 4))
  sd t1, 0(t0)
  la t1, execute_page
  srli t1, t1, 2
  ori t1, t1, (0xcb | (EXEC_USER << 4))
  sd t1, 8(t0)
  la t1, user_page
  srli t1, t1, 2
  ori t1, t1, 0xdb
  sd t1, 16(t0)
  la t0, root
  srli t0, t0, 12
  li t1, (8 << 60)
  or t0, t0, t1
  csrw satp, t0
  csrr t1, satp
  bne t0, t1, fail
  sfence.vma
  li t0, 0x40002000
  csrw mepc, t0
  csrw mstatus, zero
  li s7, 0
  mret
.balign 4, 0
supervisor_trap:
  csrr t0, scause
  li t1, 8
  beq t0, t1, complete
  bne t0, s8, fail
  la t2, trap_records
  slli t3, s7, 5
  add t2, t2, t3
  sd t0, 0(t2)
  csrr t0, stval
  sd t0, 8(t2)
  bne t0, s10, fail
  csrr t0, sepc
  sd t0, 16(t2)
  bne t0, s11, fail
  addi s7, s7, 1
  csrw sepc, s9
  sret
complete:
  li t0, (2 * (1-DATA_USER) + (1-EXEC_USER))
  bne s7, t0, fail
  li t0, EXEC_USER
  bne a5, t0, fail
  la t0, data_page
  ld t1, 0(t0)
#if DATA_USER
  li t0, 0x55667788
#else
  li t0, 0x11223344
#endif
  bne t0, t1, fail
  li t0, 0x00100000
  li t1, 0x5555
  sw t1, 0(t0)
1: j 1b
.balign 4, 0
fail:
  li t0, 0x00100000
  li t1, 0x3333
  sw t1, 0(t0)
2: j 2b
.balign 4096, 0
user_page:
  li a0, 0x40000000
  li a2, -1
  li s8, 13
  mv s10, a0
  la s11, user_load
  la s9, after_load
user_load:
  ld a2, 0(a0)
after_load:
#if DATA_USER
  li t0, 0x11223344
#else
  li t0, -1
#endif
  bne a2, t0, user_fail
  li a1, 0x55667788
  li s8, 15
  la s11, user_store
  la s9, after_store
user_store:
  sd a1, 0(a0)
after_store:
  li a0, 0x40001000
  li a5, 0
  li s8, 12
  mv s10, a0
  mv s11, a0
  la s9, after_execute
  jalr ra, a0, 0
after_execute:
  ecall
user_fail:
  /* Force an unexpected load page fault, never pretend this is completion. */
  li a0, 0x50000000
  ld zero, 0(a0)
  j user_fail
.section .data
.balign 4096
root: .zero 4096
level1: .zero 4096
level0: .zero 4096
data_page: .dword 0x11223344
  .zero (4096-8)
execute_page:
  .4byte 0x00178793
  .4byte 0x00008067
  .zero (4096-8)
.balign 8
.globl trap_records, trap_records_end
trap_records: .zero 128
trap_records_end:
