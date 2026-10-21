#if __riscv_xlen == 64
#define LOAD ld
#define STORE sd
#define HEXSHIFT 60
#else
#define LOAD lw
#define STORE sw
#define HEXSHIFT 28
#endif
.section .text
.global _start
_start:
  la t0, fail
  csrw mtvec, t0
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
  /* M-mode code stays bare; MPRV supplies S-mode data translation. */
  li t0, 0x80004000
#if __riscv_xlen == 64
  li t1, 0x200000cf
  sd t1, 8(t0)
  li t1, 0x8000000000080004
#else
  li t1, 0x200000cf
  sw t1, 1024(t0)
  li t1, 0x80080004
#endif
  csrw satp, t1
  sfence.vma
  li t0, 0x80008000
  STORE t0, 0(t0)
  fence rw, rw
  .rept 8
    LOAD t0, 0(t0)
  .endr
  csrr s0, mcycle
  .rept 128
    LOAD t0, 0(t0)
  .endr
  csrr s1, mcycle
  sub s1, s1, s0
  la a1, bare_prefix
  jal print
  li t0, 0x80008000
  li t1, 0x40008000
  STORE t1, 0(t0)
  /* Split load and translated LR/SC/AMO correctness before timing. */
  li t2, 0x44332211
  sw t2, 16(t0)
  li t2, 0x88776655
  sw t2, 20(t0)
  li t2, 7
  sw t2, 32(t0)
  fence rw, rw
  li t2, 0x1800
  csrc mstatus, t2
  li t2, 0x20800
  csrs mstatus, t2
  addi t3, t1, 32
  lr.w t4, (t3)
  li t5, 7
  bne t4, t5, fail
  li t4, 9
  sc.w t5, t4, (t3)
  bnez t5, fail
  li t4, 3
  amoadd.w t5, t4, (t3)
  li t4, 9
  bne t5, t4, fail
  lw t5, 0(t3)
  li t4, 12
  bne t5, t4, fail
  lw t5, 19(t1)
  li t4, 0x77665544
  bne t5, t4, fail
  mv t0, t1
  .rept 8
    LOAD t0, 0(t0)
  .endr
  csrr s0, mcycle
  .rept 128
    LOAD t0, 0(t0)
  .endr
  csrr s1, mcycle
  sub s1, s1, s0
  li t2, 0x20000
  csrc mstatus, t2
  la a1, translated_prefix
  jal print
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
print:
  li t1, 0x10000000
1:
  lbu t2, 0(a1)
  beqz t2, 2f
  sb t2, 0(t1)
  addi a1, a1, 1
  j 1b
2:
  li t2, HEXSHIFT
3:
  srl t3, s1, t2
  andi t3, t3, 15
  li t4, 10
  bltu t3, t4, 4f
  addi t3, t3, 39
4:
  addi t3, t3, 48
  sb t3, 0(t1)
  addi t2, t2, -4
  bgez t2, 3b
  li t3, 10
  sb t3, 0(t1)
  fence rw, rw
  ret
.section .rodata
bare_prefix: .asciz "BARE_128_DEPENDENT_LOAD_CYCLES=0x"
translated_prefix: .asciz "S_TRANSLATED_128_DEPENDENT_LOAD_CYCLES=0x"
