/* CSRRS/CSRRC with a non-x0 zero source still write. The explicit minstret
 * write overrides this instruction's implicit increment; x0/uimm=0 do not.
 */
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, fail
  csrw mtvec, t0
  csrw mie, zero
  li t0, 0
  csrrs s0, minstret, t0
  csrr s1, minstret
  bne s0, s1, fail
  csrrc s0, minstret, t0
  csrr s1, minstret
  bne s0, s1, fail
  csrrs s0, minstret, zero
  csrr s1, minstret
  addi s0, s0, 1
  bne s0, s1, fail
  csrrc s0, minstret, zero
  csrr s1, minstret
  addi s0, s0, 1
  bne s0, s1, fail
  csrrsi s0, minstret, 0
  csrr s1, minstret
  addi s0, s0, 1
  bne s0, s1, fail
  csrrci s0, minstret, 0
  csrr s1, minstret
  addi s0, s0, 1
  bne s0, s1, fail
  li t0, 0
  csrrw s0, minstret, t0
  csrr s1, minstret
  bnez s1, fail
  csrrwi s0, minstret, 0
  csrr s1, minstret
  bnez s1, fail
  li t0, 0x100000
  li t1, 0x5555
  sw t1, 0(t0)
1: j 1b
fail:
  li t0, 0x100000
  li t1, 0x3333
  sw t1, 0(t0)
2: j 2b
