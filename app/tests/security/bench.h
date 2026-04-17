#ifndef __SECURITY_BENCH_H__
#define __SECURITY_BENCH_H__

/*
 * bench.h: Shared helpers for security side-channel / speculative-execution
 *          micro-benchmarks.  Depends only on standard libc + RISC-V CSRs;
 *          no abstract-machine dependency.  Runs under riscv-pk.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

/* ---- Cycle counter helpers ---- */

static inline uint64_t rdcycle(void) {
#if __riscv_xlen == 64
  uint64_t val;
  asm volatile("rdcycle %0" : "=r"(val));
  return val;
#else
  uint32_t lo, hi, hi2;
  do {
    asm volatile("rdcycleh %0" : "=r"(hi));
    asm volatile("rdcycle  %0" : "=r"(lo));
    asm volatile("rdcycleh %0" : "=r"(hi2));
  } while (hi != hi2);
  return ((uint64_t)hi << 32) | lo;
#endif
}

/* ---- Timing measurement ---- */

#define TIMED_ACCESS(addr, cycles) do {                \
  uint64_t _t0 = rdcycle();                            \
  volatile uint8_t _x = *(volatile uint8_t *)(addr);   \
  uint64_t _t1 = rdcycle();                            \
  (void)_x;                                            \
  (cycles) = (uint32_t)(_t1 - _t0);                    \
} while (0)

/* ---- Cache line / page size (typical) ---- */
#define CACHE_LINE_SIZE  64
#define PAGE_SIZE        4096

/* ---- Memory fence helpers ---- */

static inline void fence(void) {
  asm volatile("fence" ::: "memory");
}

static inline void fence_i(void) {
  asm volatile("fence.i" ::: "memory");
}

/* ---- Reporter ---- */

static inline void report(const char *name, uint32_t hit_cycles,
                           uint32_t miss_cycles) {
  uint32_t denom = hit_cycles ? hit_cycles : 1;
  printf("[%s] cache hit: %u cycles, cache miss: %u cycles, ratio: %u.%02ux\n",
         name, hit_cycles, miss_cycles,
         miss_cycles / denom,
         (miss_cycles * 100 / denom) % 100);
}

static inline void report_timing(const char *name, uint32_t cycles) {
  printf("[%s] %u cycles\n", name, cycles);
}

/* ---- Assertion ----
 * Under pk there is no halt(); abort with non-zero exit if condition fails.
 */
__attribute__((noinline))
static void check(bool cond) {
  if (!cond) {
    printf("[check] FAILED\n");
    exit(1);
  }
}

#endif /* __SECURITY_BENCH_H__ */
