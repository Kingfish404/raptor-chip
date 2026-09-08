/* Branch-recovery probe, NOT a constrained LR/SC eventual-progress test.
 * An older DIVU-dependent taken branch may let a wrong-path SC execute.
 * Before retrying, check that the speculative -1 did not replace the old
 * value. An observed-core run must separately require actual cancellation;
 * a pass alone does not prove the branch was mispredicted.
 */
#ifndef TEST_D
#define TEST_D 0
#endif
#if TEST_D
#define LR lr.d
#define SC sc.d
#define LOAD ld
#define STORE sd
#define BYTES 8
#else
#define LR lr.w
#define SC sc.w
#define LOAD lw
#define STORE sw
#define BYTES 4
#endif
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, fail
  csrw mtvec, t0
  csrw mie, zero
  csrw satp, zero
  li s0, 0
region:
  li s1, 0x0f000000
  beqz s0, base_ready
  li s1, 0x80400000
  li t0, 1
  beq s0, t0, base_ready
  li s1, 0xa0000000
base_ready:
  li s2, 0
position:
  mv a0, s1
  beqz s2, address_ready
  addi a0, s1, (64-BYTES)
  li t0, 1
  beq s2, t0, address_ready
  addi a0, s1, 64
  li t0, 2
  beq s2, t0, address_ready
  li t0, (4096-BYTES)
  add a0, s1, t0
address_ready:
  STORE zero, 0(a0)
  li s3, 32
  li s4, 0
increment:
  addi a1, s4, 1
  la t0, recovery_probe
  jalr ra, t0, 0
  addi s4, s4, 1
  LOAD t0, 0(a0)
  bne t0, s4, fail
  addi s3, s3, -1
  bnez s3, increment
  addi s2, s2, 1
  li t0, 4
  bne s2, t0, position
  addi s0, s0, 1
  li t0, 3
  bne s0, t0, region
  li t0, 0x00100000
  li t1, 0x5555
  sw t1, 0(t0)
1: j 1b
fail:
  li t0, 0x00100000
  li t1, 0x3333
  sw t1, 0(t0)
2: j 2b
.balign 4096
.globl recovery_probe, wrong_path_sc, correct_path, retry_sc
recovery_probe:
  LR zero, (a0)
  li a2, -1
  li a3, 7
  divu a4, a2, a3
  bnez a4, correct_path
wrong_path_sc:
  SC t1, a2, (a0)
  j fail
correct_path:
  LOAD t0, 0(a0)
  bne t0, s4, fail
  LR zero, (a0)
retry_sc:
  SC t1, a1, (a0)
  bnez t1, recovery_probe
  ret
