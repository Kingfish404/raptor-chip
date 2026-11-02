/* The first resumed instruction must update REF memory as well as DUT memory. */
.section .text
.globl _start, roi_start, roi_end
_start:
  csrw mie, zero
  la sp, memory
  li s0, 0x12345678
  li s1, 1024
roi_start:
#if __riscv_xlen == 64
  sd s0, 0(sp)
#else
  sw s0, 0(sp)
#endif
loop:
#if __riscv_xlen == 64
  ld t0, 0(sp)
#else
  lw t0, 0(sp)
#endif
  bne t0, s0, failed
  addi s1, s1, -1
  bnez s1, loop
roi_end:
  li a0, 0
  ebreak
failed:
  li a0, 1
  ebreak
.section .bss
.balign 8
memory:
  .zero 8
