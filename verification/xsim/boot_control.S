#ifdef XSPI_VECTOR_BRIDGE
.option norvc
.section .text
.global _start
.global vector_pass
.global vector_fail
_start:
    la t0, trap_handler
    csrw mtvec, t0
    li t0, 0x200
    csrs mstatus, t0
    li s0, 0
    li a1, 0x10000440
    vsetivli zero, 4, e32, m1, tu, mu
#ifdef XSPI_VECTOR_STORE
    vmv.v.i v8, 7
#endif
faulting_access:
#ifdef XSPI_VECTOR_STORE
    vse32.v v8, (a1)
#else
    vle32.v v8, (a1)
#endif
    li t0, 1
    bne s0, t0, vector_fail
    csrr t0, vstart
    bnez t0, vector_fail
#ifndef XSPI_VECTOR_STORE
    vmv.x.s t0, v8
    li t1, 0x43424140
    bne t0, t1, vector_fail
    vslidedown.vi v9, v8, 2
    vmv.x.s t0, v9
    li t1, 0x4b4a4948
    bne t0, t1, vector_fail
#endif
    j vector_pass
trap_handler:
    csrr t0, mcause
#ifdef XSPI_VECTOR_STORE
    li t1, 7
#else
    li t1, 5
#endif
    bne t0, t1, vector_fail
    csrr t0, mtval
    li t1, 0x10000448
    bne t0, t1, vector_fail
    csrr t0, vstart
    li t1, 2
    bne t0, t1, vector_fail
    csrr t0, mepc
    la t1, faulting_access
    bne t0, t1, vector_fail
    addi s0, s0, 1
    mret
vector_pass:
    ebreak
vector_fail:
    ebreak
    j vector_fail
#else
/* ROM-XIP, aperture guards, and a claimed/completed pad IRQ in both XLENs. */
.option norvc
.option norelax
.section .text
.globl _start
_start:
  csrw mie, zero
  csrw mstatus, zero
  la t0, handler
  csrw mtvec, t0
  li t0, 0x00100800
  li t2, 0x00800000
  lw t1, 0x30(t0)
  bne t1, t2, fail
  lw t1, 0x34(t0)
  bne t1, t2, fail
  li t2, 0x01000000
  lw t1, 0x38(t0)
  bne t1, t2, fail
  li t0, 0x0c000004
  li t1, 1
  sw t1, 0(t0)
  li t0, 0x0c002000
  li t1, 2
  sw t1, 0(t0)
  li t0, 0x0c200000
  sw zero, 0(t0)
  li t0, 0x10000200
  sw zero, 12(t0)
  li t1, 7
  sw t1, 8(t0)
  li t1, 1
  sw t1, 4(t0)
  li t0, 0x800
  csrw mie, t0
  csrsi mstatus, 8
  fence iorw, iorw
  ebreak
park:
  j park
.balign 4
handler:
  csrr t0, mcause
  li t1, 3
  beq t0, t1, breakpoint
  bgez t0, fail
  slli t0, t0, 1
  srli t0, t0, 1
  li t1, 11
  bne t0, t1, fail
  li t0, 0x0c200004
  lw t1, 0(t0)
  li t2, 1
  bne t1, t2, fail
  sw t1, 0(t0)
  li t0, 0x10000204
  li t1, 5
  sw t1, 0(t0)
  fence iorw, iorw
  mret
breakpoint:
  la t0, park
  csrw mepc, t0
  mret
fail:
  li t0, 0x10000200
  sw zero, 12(t0)
  li t1, 7
  sw t1, 8(t0)
  li t1, 2
  sw t1, 4(t0)
  fence iorw, iorw
  ebreak
  j fail
#endif
