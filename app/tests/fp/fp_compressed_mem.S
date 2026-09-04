/* RVA20 C-extension floating-point memory instructions.
 *
 * RV32 exercises C.FLW/C.FSW and their SP forms in addition to the D forms.
 * RV64 exercises the D forms; the corresponding single-width encodings are
 * occupied by C.LD/C.SD in RV64C.
 */
.option rvc
.section .text
.globl _start
_start:
  /* Enable architectural floating-point state. */
  li t0, 0x6000
  csrs mstatus, t0

  /* Compact-register C.FLD/C.FSD. */
  la a0, double_a
  c.fld fs0, 0(a0)
  la a1, double_out_a
  c.fsd fs0, 0(a1)
  lw t1, 0(a1)
  /* LW sign-extends on RV64, so use the signed 32-bit spelling. */
  li t2, -1985229329 /* 0x89abcdef */
  bne t1, t2, fail
  lw t1, 4(a1)
  li t2, 0x01234567
  bne t1, t2, fail

  /* Full FPR-index C.FLDSP/C.FSDSP. */
  la sp, stack_area
  addi sp, sp, 64
  la t0, double_b
  fld ft3, 0(t0)
  c.fsdsp ft3, 8(sp)
  c.fldsp ft4, 8(sp)
  la t0, double_out_b
  fsd ft4, 0(t0)
  lw t1, 0(t0)
  li t2, 0x76543210
  bne t1, t2, fail
  lw t1, 4(t0)
  li t2, -19088744 /* 0xfedcba98 */
  bne t1, t2, fail

#if __riscv_xlen == 32
  /* RV32-only compact-register C.FLW/C.FSW. */
  la a0, single_a
  c.flw fs1, 0(a0)
  la a1, single_out_a
  c.fsw fs1, 0(a1)
  lw t1, 0(a1)
  li t2, 0x40490fdb
  bne t1, t2, fail

  /* RV32-only C.FLWSP/C.FSWSP. */
  la t0, single_b
  flw ft5, 0(t0)
  c.fswsp ft5, 24(sp)
  c.flwsp ft6, 24(sp)
  la t0, single_out_b
  fsw ft6, 0(t0)
  lw t1, 0(t0)
  li t2, 0xbf800000
  bne t1, t2, fail
#endif

  /* Zicclsm regression: split FP and integer accesses across a 4 KiB page. */
  la t0, double_a
  fld ft0, 0(t0)
  la t1, cross_page_slot
  fsd ft0, 0(t1)
  fld ft1, 0(t1)
  la t0, cross_page_out
  fsd ft1, 0(t0)
  lw t2, 0(t0)
  li t3, -1985229329 /* 0x89abcdef */
  bne t2, t3, fail
  lw t2, 4(t0)
  li t3, 0x01234567
  bne t2, t3, fail

#if __riscv_xlen == 64
  li t2, 0x76543210fedcba98
  addi t1, t1, -4 /* page offsets 4089..4095 => dword offsets 1..7 */
  li t4, 7
1:
  sd t2, 0(t1)
  ld t3, 0(t1)
  bne t2, t3, fail
  addi t1, t1, 1
  addi t4, t4, -1
  bnez t4, 1b
#else
  li t2, 0xfedcba98
  li t4, 3 /* page offsets 4093..4095 => word offsets 1..3 */
1:
  sw t2, 0(t1)
  lw t3, 0(t1)
  bne t2, t3, fail
  addi t1, t1, 1
  addi t4, t4, -1
  bnez t4, 1b
#endif

  li a0, 0
  li t0, 0x00100000
  li t1, 0x5555
  sw t1, 0(t0)
2:
  j 2b

fail:
  li a0, 1
  li t0, 0x00100000
  li t1, 0x13333
  sw t1, 0(t0)
3:
  j 3b

.section .data
.align 3
double_a:
  .dword 0x0123456789abcdef
double_b:
  .dword 0xfedcba9876543210
double_out_a:
  .dword 0
double_out_b:
  .dword 0
.align 2
single_a:
  .word 0x40490fdb
single_b:
  .word 0xbf800000
single_out_a:
  .word 0
single_out_b:
  .word 0
.align 4
stack_area:
  .space 128

/* Place the target at page offset 4093 so every word/dword access crosses. */
.balign 4096
  .space 4093
cross_page_slot:
  .space 8
.balign 8
cross_page_out:
  .dword 0
