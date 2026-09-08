/* Save at the branch while retired stores still wait for memory. */
#if __riscv_xlen == 64
#define STORE sd
#define LOAD ld
#define STEP 8
#define VALUE 0x123456789abcdef
#else
#define STORE sw
#define LOAD lw
#define STEP 4
#define VALUE 0x789abcde
#endif
#ifdef CHECKPOINT_FP64
#undef STORE
#undef STEP
#undef VALUE
#define STORE fsd
#define STEP 8
#define VALUE 0x123456789abcdef
#define SOURCE ft0
#else
#define SOURCE t1
#endif
.section .text
.global _start, checkpoint_marker, checkpoint_data
_start:
#ifdef CHECKPOINT_FP64
  li t1, 0x6000
  csrs mstatus, t1
  la t1, expected
  fld ft0, 0(t1)
#else
  li t1, VALUE
#endif
  la t0, checkpoint_data
  .rept 8
  STORE SOURCE, 0(t0)
  addi t0, t0, STEP
  .endr
checkpoint_marker:
  j check
  .space 128
check:
  /* Give split stores time to drain if they cannot be represented by overlay. */
  li t5, 256
1:
  addi t5, t5, -1
  bnez t5, 1b
  la t0, checkpoint_data
  li t2, 8
1:
  la t1, expected
  li t5, STEP
2:
  lbu t3, 0(t0)
  lbu t4, 0(t1)
  bne t3, t4, fail
  addi t0, t0, 1
  addi t1, t1, 1
  addi t5, t5, -1
  bnez t5, 2b
  addi t2, t2, -1
  bnez t2, 1b
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
.section .data
.balign 8
expected:
#if STEP == 8
  .dword VALUE
#else
  .word VALUE
#endif
.balign 64
#ifdef CHECKPOINT_UNALIGNED
  .byte 0
#endif
checkpoint_data:
  .zero 64
