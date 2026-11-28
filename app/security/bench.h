#ifndef __SECURITY_BENCH_H__
#define __SECURITY_BENCH_H__

/*
 * bench.h: shared helpers for the side-channel detection suite.
 *
 * The implementation now lives in four header-only modules (the app build
 * compiles every *.c here into its own ELF, so shared code cannot be a .c):
 *   sc_common.h  counters, timer gate, Zicbom probe, executable arenas
 *   sc_probe.h   runtime cache calibration and eviction primitives
 *   sc_stats.h   three-class scoring, controls, significance, SCRESULT
 *   sc_alias.h   exact branch-site aliasing independent of ASLR
 *
 * Legacy names below are kept so existing callers keep compiling.
 */

#include "sc_common.h"
#include "sc_probe.h"
#include "sc_stats.h"
#include "sc_alias.h"

#define CACHE_LINE_SIZE SC_LINE_BYTES
#define PAGE_SIZE SC_PAGE_BYTES

static inline uint64_t rdcycle(void) { return sc_cycle(); }
static inline void fence(void) { sc_fence(); }
static inline void fence_i(void) { sc_fence_i(); }

#define TIMED_ACCESS(addr, cycles) \
  do { (cycles) = sc_timed_load((const volatile uint8_t *)(addr)); } while (0)

static inline void report(const char *name, uint32_t hit_cycles,
                          uint32_t miss_cycles) {
  uint32_t denom = hit_cycles ? hit_cycles : 1;
  printf("[%s] cache hit: %u cycles, cache miss: %u cycles, ratio: %u.%02ux\n",
         name, (unsigned)hit_cycles, (unsigned)miss_cycles,
         (unsigned)(miss_cycles / denom),
         (unsigned)((miss_cycles * 100 / denom) % 100));
}

static inline void report_timing(const char *name, uint32_t cycles) {
  printf("[%s] %u cycles\n", name, (unsigned)cycles);
}

__attribute__((noinline, unused))
static void check(bool cond) {
  if (!cond) {
    printf("[check] FAILED\n");
    exit(1);
  }
}

#endif /* __SECURITY_BENCH_H__ */