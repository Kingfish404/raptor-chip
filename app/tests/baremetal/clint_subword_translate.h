#ifndef CLINT_SUBWORD_TRANSLATED
#define CLINT_SUBWORD_TRANSLATED 0
#endif
#if CLINT_SUBWORD_TRANSLATED
#if __riscv_xlen == 64
#define CLINT_VA_DELTA 0x40000000
#else
#define CLINT_VA_DELTA 0x3e000000
#endif
.macro clint_subword_translation_setup
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0xf
  csrw pmpcfg0, t0
  la t0, clint_subword_root
#if __riscv_xlen == 64
  /* VA 0x40000000 -> PA 0, VA 0x80000000 -> PA 0x80000000. */
  li t1, 0xcf
  sd t1, 8(t0)
  li t1, 0x200000cf
  sd t1, 16(t0)
  srli t0, t0, 12
  li t1, 0x8000000000000000
#else
  /* VA 0x40000000 -> PA 0x02000000, identity-map the test's RAM. */
  li t1, 0x008000cf
  sw t1, 1024(t0)
  li t1, 0x200000cf
  li t2, 2048
  add t2, t0, t2
  sw t1, 0(t2)
  srli t0, t0, 12
  li t1, 0x80000000
#endif
  or t0, t0, t1
  fence iorw,iorw
  csrw satp, t0
  sfence.vma
  /* M-mode code, S-mode translated data accesses. */
  li t0, 0x20800
  csrs mstatus, t0
  csrr s7, mstatus
.endm
.pushsection .data
.balign 4096
clint_subword_root:
  .zero 4096
.popsection
#else
#define CLINT_VA_DELTA 0
.macro clint_subword_translation_setup
.endm
#endif
