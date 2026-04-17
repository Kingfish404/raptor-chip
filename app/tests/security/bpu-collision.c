/**
 * bpu-collision: Branch Predictor Unit aliasing / collision test.
 *
 * Exploits the finite size of the PHT (Pattern History Table) and BTB
 * (Branch Target Buffer) to detect aliasing between branches at different
 * addresses.  BPU collisions are a prerequisite for cross-process branch
 * predictor attacks.
 *
 * The test allocates two branch sites that should alias in the PHT/BTB
 * (same index, different tag or no tag), trains one, and checks whether
 * the other's prediction is affected.
 *
 * Detection method: measure misprediction penalty via cycle count.
 */
#include "bench.h"

#define TRAIN_ITERATIONS  200
#define TEST_ITERATIONS   200

/*
 * We use two "branch gadgets" separated by a power-of-2 offset.
 * If the BPU indexes by lower bits of PC, they will alias.
 */

/* Branch gadget A: always-taken branch (trains predictor to "taken") */
__attribute__((noinline, aligned(64)))
static int branch_a(int val) {
  if (val > 0)
    return val + 1;
  return val;
}

/* Branch gadget B: same structure, aliasing address */
__attribute__((noinline, aligned(64)))
static int branch_b(int val) {
  if (val > 0)
    return val + 1;
  return val;
}

int main(void) {
  volatile int sink = 0;

  /* ---- Phase 1: Train branch A to be "always taken" ---- */
  for (int i = 0; i < TRAIN_ITERATIONS; i++)
    sink += branch_a(1);  // taken path

  fence();

  /* ---- Phase 2: Measure branch B prediction (not-taken path) ---- */
  /* If BPU aliases A and B, the predictor wrongly expects "taken"
     for B even when called with val=0 (not-taken), causing a penalty. */
  uint64_t t0 = rdcycle();
  for (int i = 0; i < TEST_ITERATIONS; i++)
    sink += branch_b(0);  // not-taken path
  uint64_t t1 = rdcycle();
  uint32_t aliased_cost = (uint32_t)(t1 - t0);

  /* ---- Phase 3: Baseline: branch B without prior training ---- */
  /* "Cold" predictor for a fresh branch pattern */
  for (int i = 0; i < TRAIN_ITERATIONS; i++)
    sink += branch_b(0);  // retrain B to not-taken
  fence();

  t0 = rdcycle();
  for (int i = 0; i < TEST_ITERATIONS; i++)
    sink += branch_b(0);
  t1 = rdcycle();
  uint32_t baseline_cost = (uint32_t)(t1 - t0);

  (void)sink;

  printf("[bpu-collision] after A-training: %u cycles (%u iters)\n",
         aliased_cost, TEST_ITERATIONS);
  printf("[bpu-collision] after B-retrain:  %u cycles (%u iters)\n",
         baseline_cost, TEST_ITERATIONS);

  int32_t delta = (int32_t)(aliased_cost - baseline_cost);
  printf("[bpu-collision] delta: %d cycles\n", delta);
  if (delta > 0) {
    printf("[bpu-collision] ~%u cycles/iter misprediction penalty\n",
           (uint32_t)delta / TEST_ITERATIONS);
    printf("[bpu-collision] ALIASING DETECTED: branches A and B collide\n");
  } else {
    printf("[bpu-collision] NO ALIASING detected at these addresses\n");
  }

  return 0;
}
