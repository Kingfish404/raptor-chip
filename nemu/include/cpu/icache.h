/*
 * Decoded-instruction cache: PC -> (post-decompression inst word, ilen).
 *
 * Direct-mapped, ISA-agnostic, lives outside isa/ so that both riscv32 and
 * riscv64 share a single implementation. The goal is to skip the per-
 * instruction inst_fetch (vaddr translation, PMP check, paddr_read) AND
 * the C-extension decompress on PCs we've already executed.
 *
 * Cache coherence: maintained by `icache_flush()`, which is piggy-backed
 * onto `soft_tlb_flush()` so every event that invalidates address
 * translations (trap entry, satp write, sfence.vma, paddr remap) also
 * invalidates this cache. The only extra hook is on fence.i, which
 * mutates the instruction stream without touching the TLB.
 *
 * Flush is O(1) via an epoch counter (mirrors the soft-TLB design).
 */
#ifndef __CPU_ICACHE_H__
#define __CPU_ICACHE_H__

#include <common.h>

#define ICACHE_BITS 12
#define ICACHE_SIZE (1u << ICACHE_BITS)
#define ICACHE_MASK (ICACHE_SIZE - 1u)

typedef struct {
  vaddr_t  pc;     /* tag                                            */
  uint32_t inst;   /* post-decompression instruction word            */
  uint16_t ilen;   /* original fetch length: 2 (C-ext) or 4          */
  uint16_t _pad;
  uint32_t epoch;  /* entry valid iff epoch == icache_epoch          */
} icache_entry_t;

extern icache_entry_t icache[ICACHE_SIZE];
extern uint32_t       icache_epoch;

/* O(1) flush. Wrap-to-zero hard-resets all tags so a stale epoch-0
 * entry can never be mistaken as valid. */
void icache_flush(void);

static inline icache_entry_t *icache_slot(vaddr_t pc) {
  return &icache[(pc >> 1) & ICACHE_MASK];
}

static inline bool icache_hit(const icache_entry_t *e, vaddr_t pc) {
  return e->pc == pc && e->epoch == icache_epoch;
}

static inline void icache_fill(icache_entry_t *e, vaddr_t pc,
                               uint32_t inst, uint16_t ilen) {
  e->pc    = pc;
  e->inst  = inst;
  e->ilen  = ilen;
  e->epoch = icache_epoch;
}

#endif
