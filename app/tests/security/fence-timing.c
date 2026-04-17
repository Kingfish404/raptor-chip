/**
 * fence-timing: Measure the cost of RISC-V fence/fence.i instructions.
 *
 * Fences are the architectural mechanism to prevent speculative
 * information leakage. This benchmark measures their cycle cost so
 * designers can evaluate the performance overhead of speculative
 * execution mitigations.
 */
#include "bench.h"

#define ROUNDS 1000

int main(void) {
  uint64_t t0, t1;

  /* ---- Baseline: empty measurement loop ---- */
  t0 = rdcycle();
  for (volatile int i = 0; i < ROUNDS; i++) {
    asm volatile("nop");
  }
  t1 = rdcycle();
  uint32_t baseline = (uint32_t)(t1 - t0);

  /* ---- fence ---- */
  t0 = rdcycle();
  for (volatile int i = 0; i < ROUNDS; i++) {
    asm volatile("fence" ::: "memory");
  }
  t1 = rdcycle();
  uint32_t fence_cost = (uint32_t)(t1 - t0);

  /* ---- fence.i ---- */
  t0 = rdcycle();
  for (volatile int i = 0; i < ROUNDS; i++) {
    asm volatile("fence.i" ::: "memory");
  }
  t1 = rdcycle();
  uint32_t fencei_cost = (uint32_t)(t1 - t0);

  printf("[fence-timing] %u rounds\n", ROUNDS);
  report_timing("  nop baseline", baseline);
  report_timing("  fence       ", fence_cost);
  report_timing("  fence.i     ", fencei_cost);
  printf("[fence-timing] fence overhead:   ~%u cycles/call\n",
         (fence_cost - baseline) / ROUNDS);
  printf("[fence-timing] fence.i overhead: ~%u cycles/call\n",
         (fencei_cost - baseline) / ROUNDS);

  /* fence should complete (not hang), and cost >= baseline */
  check(fence_cost >= baseline);

  return 0;
}
