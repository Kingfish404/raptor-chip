/**
 * fence-timing: cost of fence/fence.i AND their efficacy as a mitigation.
 *
 * Beyond cycle cost, this measures whether fence/fence.i actually remove
 * microarchitectural state.  With RAPT_SFENCE_KEEP_STATE=3 (rapt.svh:96) the
 * cache/TLB/BPU invalidate ports are tied off, so a fence drains ordering
 * but leaves a warm cache line warm.  The arm below warms a line, fences,
 * and re-times it: if it is still an L1 hit, fence is NOT a cache-residue
 * mitigation.  A real eviction (cbo.inval or capacity) is shown for contrast.
 */
#include "bench.h"

#define ROUNDS 1000

static uint8_t line_buf[2 * SC_PAGE_BYTES]
    __attribute__((aligned(SC_PAGE_BYTES)));

int main(void) {
  if (sc_time_selfcheck("fence-timing") != 0)
    return 1;
  sc_geom_t g;
  sc_calibrate(&g);

  uint64_t t0, t1;
  t0 = sc_cycle();
  for (volatile int i = 0; i < ROUNDS; i++)
    asm volatile("nop");
  t1 = sc_cycle();
  uint32_t baseline = (uint32_t)(t1 - t0);

  t0 = sc_cycle();
  for (volatile int i = 0; i < ROUNDS; i++)
    asm volatile("fence" ::: "memory");
  t1 = sc_cycle();
  uint32_t fence_cost = (uint32_t)(t1 - t0);

  t0 = sc_cycle();
  for (volatile int i = 0; i < ROUNDS; i++)
    asm volatile("fence.i" ::: "memory");
  t1 = sc_cycle();
  uint32_t fencei_cost = (uint32_t)(t1 - t0);

  printf("[fence-timing] %u rounds\n", (unsigned)ROUNDS);
  report_timing("  nop baseline", baseline);
  report_timing("  fence       ", fence_cost);
  report_timing("  fence.i     ", fencei_cost);
  printf("[fence-timing] fence overhead:   ~%u cycles/call\n",
         (unsigned)((fence_cost - baseline) / ROUNDS));
  printf("[fence-timing] fence.i overhead: ~%u cycles/call\n",
         (unsigned)((fencei_cost - baseline) / ROUNDS));

  /* State-persistence arm: does fence remove a warm cache line? */
  volatile uint8_t *p = line_buf + SC_LINE_BYTES;
  (void)*p;
  (void)*p;
  uint32_t warm = sc_timed_load(p);
  sc_fence();
  uint32_t after_fence = sc_timed_load(p);
  sc_fence_i();
  uint32_t after_fencei = sc_timed_load(p);
  sc_evict_l1((const void *)p, &g);
  sc_evict_l2((const void *)p, &g);
  uint32_t after_evict = sc_timed_load(p);
  int fence_keeps = (after_fence <= (warm + g.t_l1)) &&
                    (after_fencei <= (warm + g.t_l1));
  printf("[fence-timing] residue warm=%u after_fence=%u after_fencei=%u "
         "after_evict=%u fence_keeps_state=%d\n",
         (unsigned)warm, (unsigned)after_fence, (unsigned)after_fencei,
         (unsigned)after_evict, fence_keeps);
  printf("SCRESULT fence-timing INFO fence=%u fencei=%u warm=%u "
         "after_fence=%u after_fencei=%u after_evict=%u keeps=%d rounds=%d\n",
         (unsigned)((fence_cost - baseline) / ROUNDS),
         (unsigned)((fencei_cost - baseline) / ROUNDS),
         (unsigned)warm, (unsigned)after_fence, (unsigned)after_fencei,
         (unsigned)after_evict, fence_keeps, ROUNDS);

  check(fence_cost >= baseline);
  return 0;
}