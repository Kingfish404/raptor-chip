.section .text.start
.globl _start
_start:
  li sp, 0x8003fff0
  // Zero and out-of-range divider values are ignored by the SoC register.
  li t2, 0x8003fff0
  lw t1, 0(t2)
  li t0, 0x00100800
  sw t1, 0(t0)
  lw t1, 0(t0)
  sw t1, 4(t2)
  fence iorw, iorw
  call board_boot
1:
  j 1b
