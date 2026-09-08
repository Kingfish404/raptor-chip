/* Atomic compare-width regression. Check rd, selected low word, and
 * preservation of the adjacent word; then check signed/unsigned AMO.D.
 */
.option norvc
.option norelax
.section .text
.globl _start
.macro check_w op, old, operand, expected
  li t0, \old
  sw t0, 0(s0)
#if __riscv_xlen == 64
  li t1, \operand
#else
  li t1, (\operand & 0xffffffff)
#endif
  \op t2, t1, (s0)
#if __riscv_xlen == 64
  sext.w t3, t0
#else
  mv t3, t0
#endif
  bne t2, t3, fail
  lw t2, 0(s0)
  li t3, \expected
#if __riscv_xlen == 64
  sext.w t3, t3
#endif
  bne t2, t3, fail
#if __riscv_xlen == 64
  lwu t2, 4(s0)
#else
  lw t2, 4(s0)
#endif
  bne t2, s1, fail
.endm
.macro check_d op, old, operand, expected
  li t0, \old
  sd t0, 0(s0)
  li t1, \operand
  \op t2, t1, (s0)
  bne t2, t0, fail
  ld t2, 0(s0)
  li t3, \expected
  bne t2, t3, fail
.endm
_start:
  la t0, fail
  csrw mtvec, t0
  la s0, location
  li s1, 0x55aa33cc
  sw s1, 4(s0)
  check_w amomin.w, 0xffffffff, 0x0000000080000000, 0x80000000
  check_w amomax.w, 1, 0xffffffff7fffffff, 0x7fffffff
  check_w amominu.w, 0x80000000, 0x00000000ffffffff, 0x80000000
  check_w amomaxu.w, 0x80000000, 0x00000000ffffffff, 0xffffffff
  check_w amomin.w, 1, 0xffffffff00000000, 0
  check_w amomax.w, 0xffffffff, 0x0000000080000000, 0xffffffff
  check_w amominu.w, 0xffffffff, 0xffffffff00000001, 1
  check_w amomaxu.w, 0x7fffffff, 0xffffffff00000000, 0x7fffffff
#if __riscv_xlen == 64
  check_d amomin.d, 0x8000000000000000, 1, 0x8000000000000000
  check_d amomax.d, 0x8000000000000000, 1, 1
  check_d amominu.d, 0x8000000000000000, 1, 1
  check_d amomaxu.d, 0x8000000000000000, 1, 0x8000000000000000
#endif
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
  j fail
.section .data
.balign 8
location:
  .dword 0
