.option norvc
.option norelax
.section .text.start
.globl _start
_start:
  la sp, __stack_top
  la t0, __bss_start
  la t1, __bss_end
1:
  bgeu t0, t1, 2f
#if __riscv_xlen == 64
  sd zero, 0(t0)
  addi t0, t0, 8
#else
  sw zero, 0(t0)
  addi t0, t0, 4
#endif
  j 1b
2:
  call main
  ebreak
3: j 3b
