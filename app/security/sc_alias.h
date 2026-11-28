#ifndef __SC_ALIAS_H__
#define __SC_ALIAS_H__
/*
 * sc_alias.h: exact branch-site aliasing, independent of ASLR/link layout.
 *
 * Verified predictor hash geometry (default-w4-l2):
 *  - ITT: 32 entries, direct-mapped. idx = pc[5:1]^ghr[4:0],
 *    tag = pc[14:6]^ghr[13:5] (rapt_bpu.sv:330-335, IttIdxBits=5,
 *    IttTagBits=9).  A 16 KiB delta flips pc[14] and misses the tag.
 *    A 32 KiB delta leaves pc[14:1] unchanged, so the two JALRs are exact
 *    aliases.  Redirect also needs a BTB INDR tag match
 *    (rapt_bpu.sv:683-691), so the victim site must have been executed.
 *  - BTB: 128 sets, index pc[7:1]^pc[14:8]; 32 KiB stride hits the same set
 *    (capacity conflict).  Exact index+tag alias needs bits 15 AND 24 to
 *    flip together => delta 0x1008000 (~16 MiB), Linux-only.
 *  - TAGE: only pc[18:1] is hashed (ReadPcMsb=18) => full alias at 512 KiB;
 *    bimodal-only alias at 2 KiB.
 *  - Loop predictor: tag pc[20:11] => alias at 2 MiB.
 *
 * Stub templates are assembler-generated and copied into one arena at
 * offsets 0 and delta, so the relative PC is exact regardless of where the
 * arena lands.  Under pk (no mmap exec arena) a pre-spaced .text blob
 * supplies the primary 32 KiB ITT/BTB-set pair; larger deltas report SKIP.
 */

#include "sc_common.h"

#define SC_DELTA_ITT 0x8000u        /* 32 KiB: ITT exact + BTB same set */
#define SC_DELTA_TAGE 0x80000u      /* 512 KiB: full TAGE index+tag */
#define SC_DELTA_BIM 0x800u         /* 2 KiB: bimodal only */
#define SC_DELTA_LP 0x200000u       /* 2 MiB: loop predictor */
#define SC_DELTA_BTB_TAG 0x1008000u /* ~16 MiB: BTB exact index+tag */

typedef void (*sc_stub_fn)(void *);

/* Assembler-generated stub templates.  sc_itt_stub calls *(void**)a0 via an
 * indirect jalr (produces an INDR-typed BTB entry).  sc_cond_stub is a
 * data-dependent conditional branch for direction-predictor aliasing.
 *
 * The jalr links into t1, NOT ra: linking into ra would make the callee
 * return to the stub's own `ret`, which then jumps to itself (ra still holds
 * that address) -> infinite loop.  With t1 as the link, ra keeps the caller's
 * return address, so the callee's `ret` returns straight to the caller and
 * the stub's trailing `ret` is dead code. */
__asm__(
    ".section .text.sc_stub,\"ax\",@progbits\n"
    ".balign 4\n"
    ".globl sc_itt_stub\n"
    "sc_itt_stub:\n"
#if __riscv_xlen == 64
    "  ld t0, 0(a0)\n"
#else
    "  lw t0, 0(a0)\n"
#endif
    "  jalr t1, t0\n"
    "  ret\n"
    ".globl sc_itt_stub_end\n"
    "sc_itt_stub_end:\n"
    ".balign 4\n"
    ".globl sc_cond_stub\n"
    "sc_cond_stub:\n"
    "  beqz a0, 1f\n"
    "  addi a0, a0, 1\n"
    "1:\n"
    "  ret\n"
    ".globl sc_cond_stub_end\n"
    "sc_cond_stub_end:\n");

extern const uint8_t sc_itt_stub[];
extern const uint8_t sc_itt_stub_end[];
extern const uint8_t sc_cond_stub[];
extern const uint8_t sc_cond_stub_end[];

/* Canonical low GHR.  ITT index and tag both XOR ghr[13:0]
 * (rapt_bpu.sv:330-335), so a mismatch silently kills cross-site injection.
 * Eight calls to a noinline hop are sixteen taken branches (jal + ret) and
 * no loop-exit not-taken, which overwrites ghr[15:0] with a fixed pattern.
 * An empty asm loop does not: -O2 emits no branch at all. */
__attribute__((noinline, used))
static void sc_hist_hop(void) {
  asm volatile("" ::: "memory");
}

static inline void sc_hist_prime(void) {
  sc_hist_hop(); sc_hist_hop(); sc_hist_hop(); sc_hist_hop();
  sc_hist_hop(); sc_hist_hop(); sc_hist_hop(); sc_hist_hop();
}

typedef struct {
  sc_stub_fn a;
  sc_stub_fn b;
  void *arena;
  size_t span;
  int from_blob;
} sc_alias_t;

#if !defined(SC_POSIX_OS)
/* pk: pre-spaced .text pair at exactly SC_DELTA_ITT.  .space uses the
 * assembled stub size so site_b = site_a + 32768 exactly. */
__asm__(
    ".section .text.sc_alias,\"ax\",@progbits\n"
    ".balign 64\n"
    ".globl sc_alias_site_a\n"
    "sc_alias_site_a:\n"
#if __riscv_xlen == 64
    "  ld t0, 0(a0)\n"
#else
    "  lw t0, 0(a0)\n"
#endif
    "  jalr t1, t0\n"
    "  ret\n"
    "sc_alias_pad:\n"
    ".space 32768 - (sc_alias_pad - sc_alias_site_a)\n"
    ".globl sc_alias_site_b\n"
    "sc_alias_site_b:\n"
#if __riscv_xlen == 64
    "  ld t0, 0(a0)\n"
#else
    "  lw t0, 0(a0)\n"
#endif
    "  jalr t1, t0\n"
    "  ret\n");
extern const uint8_t sc_alias_site_a[];
extern const uint8_t sc_alias_site_b[];
#endif

/* Build an alias pair at the requested delta.  Returns 0 on success, -1 if
 * the environment cannot supply it (caller should report SKIP). */
static inline int sc_alias_make(sc_alias_t *al, uint32_t delta,
                                const uint8_t *stub, size_t stub_len) {
  memset(al, 0, sizeof(*al));
#if defined(SC_POSIX_OS)
  size_t span = (size_t)delta + SC_PAGE_BYTES;
  void *p = sc_exec_alloc(span);
  if (!p)
    return -1;
  memcpy(p, stub, stub_len);
  memcpy((uint8_t *)p + delta, stub, stub_len);
  if (sc_exec_publish(p, span) != 0) {
    sc_exec_free(p, span);
    return -1;
  }
  al->a = (sc_stub_fn)p;
  al->b = (sc_stub_fn)((uint8_t *)p + delta);
  al->arena = p;
  al->span = span;
  return 0;
#else
  (void)stub;
  (void)stub_len;
  if (delta == SC_DELTA_ITT) {
    al->a = (sc_stub_fn)sc_alias_site_a;
    al->b = (sc_stub_fn)sc_alias_site_b;
    al->from_blob = 1;
    return 0;
  }
  return -1;
#endif
}

static inline void sc_alias_free(sc_alias_t *al) {
#if defined(SC_POSIX_OS)
  if (al->arena)
    sc_exec_free(al->arena, al->span);
#else
  (void)al;
#endif
  al->arena = NULL;
}

static inline size_t sc_itt_stub_len(void) {
  return (size_t)(sc_itt_stub_end - sc_itt_stub);
}

static inline size_t sc_cond_stub_len(void) {
  return (size_t)(sc_cond_stub_end - sc_cond_stub);
}

#endif /* __SC_ALIAS_H__ */