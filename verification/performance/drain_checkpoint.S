/* Stop with dirty cache lines and younger stores in flight. */
.section .text
.globl _start, roi_start, memory
_start:
  csrw mie, zero
  la sp, memory
  li s0, 0
roi_start:
#if __riscv_xlen == 64
  sd s0, 0(sp)
  sd s0, 8(sp)
  sd s0, 16(sp)
  sd s0, 24(sp)
#else
  sw s0, 0(sp)
  sw s0, 8(sp)
  sw s0, 16(sp)
  sw s0, 24(sp)
#endif
  addi s0, s0, 1
  j roi_start
.section .bss
.balign 64
memory:
  .zero 64
