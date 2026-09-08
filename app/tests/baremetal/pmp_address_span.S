#if __riscv_xlen != 64
#error "PMP high-address regression requires RV64"
#endif
/* A retained high pmpaddr bit must not grant a low-address MPRV/U load. */
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, trap
  csrw mtvec, t0
  csrw mstatus, zero
  li t0, -1
  csrw pmpaddr15, t0
  li t0, 0x1800000000000000  /* background NAPOT, U denied, M bypass */
  csrw pmpcfg2, t0
  la s0, data
  li s1, 46
  li s3, 0
next_bit:
  srli t0, s0, 2
  li t1, 1
  sll t1, t1, s1
  or t0, t0, t1
  csrw pmpaddr0, t0
  csrr t2, pmpaddr0
  bne t2, t0, fail
  li t0, 0x11               /* NA4 read grant at a different, high address */
  csrw pmpcfg0, t0
  sfence.vma
  la s2, denied_load
  li t0, 0x20000           /* MPRV=1, MPP=U */
  csrs mstatus, t0
denied_load:
  lbu t1, 0(s0)
  csrc mstatus, t0
  addi t2, s1, -45
  bne s3, t2, fail
  addi s1, s1, 1
  li t2, 54
  blt s1, t2, next_bit
  /* Positive control: the actual low NA4 range must grant the same access. */
  srli t0, s0, 2
  csrw pmpaddr0, t0
  sfence.vma
  li t0, 0x20000
  csrs mstatus, t0
allowed_load:
  lbu t1, 0(s0)
  csrc mstatus, t0
  li t2, 0x5a
  bne t1, t2, fail
  li a0, 0
  ebreak
trap:
  li t0, 0x20000
  csrc mstatus, t0
  csrr t1, mcause
  li t2, 5
  bne t1, t2, fail
  csrr t1, mtval
  bne t1, s0, fail
  csrr t1, mepc
  bne t1, s2, fail
  addi t1, t1, 4
  csrw mepc, t1
  addi s3, s3, 1
  mret
fail:
  li a0, 1
  ebreak
  j fail
.section .data
.balign 16
data:
  .byte 0x5a
  .space 15
