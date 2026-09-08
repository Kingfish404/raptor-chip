.option norvc
.option norelax
.section .text
.globl _start
_start:
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 15
  csrw pmpcfg0, t0
  li t0, 0x80070000
  li t1, 0x200000cf
  sd t1, 16(t0)
  li t0, 0x8000000000080070
  csrw satp, t0
  sfence.vma
  li t0, 0x800
  csrw mstatus, t0
  la t0, supervisor
  csrw mepc, t0
  mret
supervisor:
  li t1, 0x12345678
  li t0, 0x80200008
  sd t1, 0(t0)
  li t0, 0x80400008
  sd t1, 0(t0)
  li t0, 0x82000008
  sd t1, 0(t0)
  li t0, 0x83e00008
  sd t1, 0(t0)
  li t0, 0x87e00008
  sd t1, 0(t0)
  li t0, 0x80080000
  sd t1, 0(t0)
  li a0, 0
  ebreak
