/**
 * cache-timing: Measure cache hit vs. miss latency.
 *
 * Establishes a baseline timing difference between cached and uncached memory
 * accesses. This is the fundamental primitive for cache side-channel attacks
 * (Flush+Reload, Prime+Probe, etc.).
 *
 * Expected: cache hit << cache miss (typically 3-10x difference).
 */
#include "bench.h"

#define PROBE_ARRAY_SIZE  (256 * PAGE_SIZE)

static uint8_t probe_array[PROBE_ARRAY_SIZE]
    __attribute__((aligned(PAGE_SIZE)));

#define ROUNDS 64

int main(void) {
  /* Initialize probe array to ensure pages are mapped */
  for (int i = 0; i < PROBE_ARRAY_SIZE; i += PAGE_SIZE)
    probe_array[i] = (uint8_t)i;

  fence();

  /* ---- Measure cache miss (cold access) ---- */
  uint64_t miss_total = 0;
  for (int r = 0; r < ROUNDS; r++) {
    /* Access a different page-aligned slot each round to avoid prefetch */
    int idx = ((r * 37) % 256) * PAGE_SIZE;
    fence();
    uint32_t t;
    TIMED_ACCESS(&probe_array[idx], t);
    miss_total += t;

    /* Evict: touch enough other lines to flush from cache */
    for (int e = 0; e < PROBE_ARRAY_SIZE; e += CACHE_LINE_SIZE)
      ((volatile uint8_t *)probe_array)[e];
    fence();
  }

  /* ---- Measure cache hit (warm access) ---- */
  volatile uint8_t sink = probe_array[0];
  (void)sink;
  fence();

  uint64_t hit_total = 0;
  for (int r = 0; r < ROUNDS; r++) {
    uint32_t t;
    TIMED_ACCESS(&probe_array[0], t);
    hit_total += t;
  }

  uint32_t avg_hit  = (uint32_t)(hit_total  / ROUNDS);
  uint32_t avg_miss = (uint32_t)(miss_total / ROUNDS);
  report("cache-timing", avg_hit, avg_miss);

  /* Sanity: cache hit should be measurably faster than cache miss */
  check(avg_hit < avg_miss);

  return 0;
}
