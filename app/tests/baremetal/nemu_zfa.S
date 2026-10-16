.option norvc
.option norelax
.macro zfa funct7, rs2=2, mode=0, rs1=1, rd=3
  .word (\funct7 << 25) | (\rs2 << 20) | (\rs1 << 15) | (\mode << 12) | (\rd << 7) | 0x53
.endm
.macro flags expected
  csrr t0, fflags
  li t1, \expected
  bne t0, t1, fail
.endm
.section .text
.globl _start
_start:
  csrr s0, mhartid
  la t0, fail
  csrw mtvec, t0
  li t0, 0x6000
  csrs mstatus, t0
  la s2, constants
  li s1, 8
again:
  csrw frm, s0
  csrw fflags, zero
  zfa 0x78, 1, 0, 18, 1
  zfa 0x20, 5, 7
  fcvt.w.s t2, f3, rtz
  li t3, 2
  beqz s0, rounded
  li t0, 3
  beq s0, t0, rounded
  li t3, 1
rounded:
  bne t2, t3, fail
  flags 1
  csrw fflags, zero
  zfa 0x20, 4, 1
  fcvt.w.s t2, f3, rtz
  li t3, 1
  bne t2, t3, fail
  flags 0
  zfa 0x79, 1, 0, 16, 1
  fld f2, 0(s2)
  zfa 0x15, 2, 2
  fclass.d t2, f3
  li t3, 512
  bne t2, t3, fail
  zfa 0x15, 2, 3
  fclass.d t2, f3
  bne t2, t3, fail
  zfa 0x51, 2, 5
  bnez gp, fail
  flags 0
  fld f1, 8(s2)
  zfa 0x78, 1, 0, 16, 2
  zfa 0x50, 2, 4
  bnez gp, fail
  flags 16
  csrw fflags, zero
  zfa 0x79, 1, 0, 18, 1
  zfa 0x21, 4, 0
  fcvt.w.d t2, f3, rtz
  li t3, 2
  bne t2, t3, fail
  flags 0
  zfa 0x21, 5, 2
  fcvt.w.d t2, f3, rtz
  li t3, 1
  bne t2, t3, fail
  flags 1
  csrw fflags, zero
  fld f1, 16(s2)
  zfa 0x61, 8, 1
  li t3, 1
  bne gp, t3, fail
  flags 16
#if __riscv_xlen == 32
  li ra, 0x01234567
  li sp, 0x89abcdef
  zfa 0x59
  zfa 0x71, 1, 0, 3
  li t3, 0x89abcdef
  bne gp, t3, fail
  fmv.x.w t2, f3
  li t3, 0x01234567
  bne t2, t3, fail
#endif
  addi s1, s1, -1
  bnez s1, again
  la t0, finished
  li t1, 1
  amoadd.w.aqrl zero, t1, (t0)
  bnez s0, park
wait:
  lw t1, 0(t0)
  li t2, HARTS
  bne t1, t2, wait
  li t0, 0x100000
  li t1, 0x5555
  sw t1, 0(t0)
park:
  j park
fail:
  li t0, 0x100000
  li t1, 0x3333
  sw t1, 0(t0)
  j fail
.section .data
.balign 8
constants:
  .dword 0x7ff8000000000000, 0xffffffff7f800001, 0x41f0000000100000
.balign 64
finished:
  .word 0
