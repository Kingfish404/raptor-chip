/* Naturally aligned native instruction fetch must not tear a word. Without
 * FENCE.I between patches either the old or new instruction is permitted.
 * Eight functions alias the default two-way I-cache set, forcing replacement.
 * Old: addi a0,a1,1 => 11; new: addi a0,a2,2 => 22.
 * Mixed halfwords use a0/a3 and yield 101/202, both forbidden by this test.
 */
#ifndef TEST_PRIV
#define TEST_PRIV 3
#endif
#ifndef TARGET_OFFSET
#define TARGET_OFFSET 0
#endif
#if TARGET_OFFSET != 0 && TARGET_OFFSET != 4
#error TARGET_OFFSET must select an aligned RV64 low/high word lane
#endif
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, fail
  csrw mtvec, t0
  csrw mie, zero
  csrw medeleg, zero
  csrw satp, zero
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
  la t0, run
  csrw mepc, t0
  li t0, (TEST_PRIV << 11)
  csrw mstatus, t0
  mret
run:
  la s0, code
  addi s0, s0, TARGET_OFFSET
  mv s1, s0
  li s2, 8
init:
  li t0, 0x00158513 /* addi a0,a1,1 */
  sw t0, 0(s1)
  li t0, 0x00008067 /* ret */
  sw t0, 4(s1)
  li t0, 2048
  add s1, s1, t0
  addi s2, s2, -1
  bnez s2, init
  fence.i
  li s2, 128
  li s3, 0
  li s4, 0
round:
  mv s1, s0
  li s5, 8
patch:
  andi t0, s2, 1
  li t1, 0x00158513
  beqz t0, selected
  li t1, 0x00260513 /* addi a0,a2,2 */
selected:
#ifdef INJECT_TORN
  li t1, 0x00150513 /* old high + new low: addi a0,a0,1 */
#endif
  sw t1, 0(s1)
  li a0, 100
  li a1, 10
  li a2, 20
  li a3, 200
  jalr ra, s1, 0
  li t0, 11
  beq a0, t0, old
  li t0, 22
  bne a0, t0, fail
  addi s4, s4, 1
  j next
old:
  addi s3, s3, 1
next:
  li t0, 2048
  add s1, s1, t0
  addi s5, s5, -1
  bnez s5, patch
  addi s2, s2, -1
  bnez s2, round
  add t0, s3, s4
  li t1, 1024
  bne t0, t1, fail
  li t0, 0x100000
  li t1, 0x5555
  sw t1, 0(t0)
1: j 1b
fail:
  li t0, 0x100000
  li t1, 0x3333
  sw t1, 0(t0)
2: j 2b
.section .bss
.balign 2048
code:
  .skip 16384
