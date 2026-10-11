/* Older writes remain in L2; a newer partial store remains in L1D. No fence
 * publishes the data before the architectural checkpoint marker. */
#if __riscv_xlen == 64
#define STORE sd
#define LOAD ld
#define VALUE 0x123456789abcdef
#else
#define STORE sw
#define LOAD lw
#define VALUE 0x789abcde
#endif
.section .text
.global _start, checkpoint_marker, checkpoint_data
_start:
  la t0, checkpoint_data
  li t4, 4096
  .set index, 0
  .rept 8
  /* Read first so an inclusive L2 owns the complete line before a store. */
  LOAD t3, 0(t0)
  li t1, VALUE + 17 * index
  STORE t1, 0(t0)
  add t0, t0, t4
  .set index, index + 1
  .endr
  la t0, checkpoint_data
  LOAD t3, 0(t0)
  // A critical-word response can precede the remaining refill beats. Let
  // that refill finish so the partial store below is a resident L1D hit.
  li t5, 4096
1:
  addi t5, t5, -1
  bnez t5, 1b
  li t3, 0x5a
  sb t3, 1(t0)
  // Let the partial store leave the SQ without cleaning its dirty cache word.
  li t5, 4096
1:
  addi t5, t5, -1
  bnez t5, 1b
checkpoint_marker:
  j check
  .space 128
check:
  // Harmless CSR serialization exposes empty-ROB boundaries without cleaning
  // caches. Wait here for the marker's instruction refill to finish before
  // verification loads can evict the dirty L1D copy we need to capture.
  li t5, 256
1:
  csrw mscratch, zero
  addi t5, t5, -1
  bnez t5, 1b
  la t0, checkpoint_data
  li t4, 4096
  .set index, 0
  .rept 8
  .if index == 0
  li t1, (VALUE & ~0xff00) | 0x5a00
  .else
  li t1, VALUE + 17 * index
  .endif
  LOAD t3, 0(t0)
  bne t1, t3, fail
  add t0, t0, t4
  .set index, index + 1
  .endr
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
.section .data
.balign 4096
checkpoint_data:
  .zero 32768
