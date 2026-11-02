/* Unequal PMP addresses expose observation-stride mistakes on RV64/PA32. */
.section .text
.globl _start, roi_start, roi_end
_start:
  csrw mie, zero
  csrw satp, zero
  la t0, failed
  csrw mtvec, t0
  csrw pmpcfg0, zero
#if __riscv_xlen == 32
  csrw pmpcfg1, zero
#else
  csrw pmpcfg2, zero
#endif
  li s0, 0x100000
  li s1, 0x200000
  li s2, 0x300000
  li s3, 0x400000
  li s4, 0x500000
  li s5, 0x600000
  li s6, 0x700000
  li s7, 0x800000
  csrw pmpaddr0, s0
  csrw pmpaddr1, s1
  csrw pmpaddr2, s2
  csrw pmpaddr3, s3
  csrw pmpaddr4, s4
  csrw pmpaddr5, s5
  csrw pmpaddr6, s6
  csrw pmpaddr7, s7
  li t2, 1024
roi_start:
  csrr t0, pmpaddr0
  bne t0, s0, failed
  csrr t0, pmpaddr1
  bne t0, s1, failed
  csrr t0, pmpaddr2
  bne t0, s2, failed
  csrr t0, pmpaddr3
  bne t0, s3, failed
  csrr t0, pmpaddr4
  bne t0, s4, failed
  csrr t0, pmpaddr5
  bne t0, s5, failed
  csrr t0, pmpaddr6
  bne t0, s6, failed
  csrr t0, pmpaddr7
  bne t0, s7, failed
  addi t2, t2, -1
  bnez t2, roi_start
roi_end:
  li a0, 0
  ebreak
failed:
  li a0, 1
  ebreak
