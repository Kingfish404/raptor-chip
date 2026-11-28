/**
 * bpu-collision: branch-predictor aliasing stride sweep.
 *
 * The original separated two functions by 64 bytes, which guarantees
 * different BTB sets, and measured its "baseline" after retraining B, so it
 * could never see aliasing.  This version places stubs at exact PC deltas
 * and measures the single-execution mispredict penalty of a victim site
 * after an attacker site trains the shared entry.
 *
 * Predictive geometry (default-w4-l2): the ITT index is pc[5:1]^ghr[4:0] and
 * tag pc[13:5]^ghr[13:5], so ANY delta that is a multiple of 16 KiB leaves
 * pc[13:1] unchanged and aliases the direct-mapped ITT.  Deltas of 64 B or
 * 4 KiB change pc[13:1] and must NOT alias.  The sweep below checks exactly
 * that signature instead of assuming a single arbitrary spacing.
 */
#include "bench.h"

#define REPS 31
#define TRAIN 20

static uint8_t probe_pad[SC_LINE_BYTES]; /* distinct cheap targets */
static uint8_t probe_pad2[SC_LINE_BYTES];

__attribute__((noinline))
static void gadget_a(void) { probe_pad[0]++; }
__attribute__((noinline))
static void gadget_b(void) { probe_pad2[0]++; }

static void *ta;
static void *tb;

static inline void call_primed(sc_stub_fn fn, void *arg) {
  sc_hist_prime();
  fn(arg);
}

static uint32_t median31(uint32_t *v, int n) {
  for (int i = 1; i < n; i++) {
    uint32_t x = v[i];
    int j = i - 1;
    while (j >= 0 && v[j] > x) { v[j + 1] = v[j]; j--; }
    v[j + 1] = x;
  }
  return v[n / 2];
}

/* Measure the penalty of one victim execution after attacker training. */
static void measure_delta(uint32_t delta, int *supported) {
  sc_alias_t al;
  if (sc_alias_make(&al, delta, sc_itt_stub, sc_itt_stub_len()) != 0) {
    printf("SCRESULT bpu-collision SKIP delta=0x%x reason=no-arena\n",
           (unsigned)delta);
    *supported = 0;
    return;
  }
  *supported = 1;
  uint32_t base[REPS], aliased[REPS];
  for (int r = 0; r < REPS; r++) {
    /* Baseline: victim trained to its own target, then timed. */
    for (int t = 0; t < TRAIN; t++)
      call_primed(al.b, &tb);
    sc_hist_prime();
    uint64_t t0 = sc_cycle();
    al.b(&tb);
    uint64_t t1 = sc_cycle();
    base[r] = (uint32_t)(t1 - t0);
    /* Aliased: retrain victim, then attacker trains the shared entry. */
    for (int t = 0; t < TRAIN; t++)
      call_primed(al.b, &tb);
    for (int t = 0; t < TRAIN; t++)
      call_primed(al.a, &ta);
    sc_hist_prime();
    t0 = sc_cycle();
    al.b(&tb);
    t1 = sc_cycle();
    aliased[r] = (uint32_t)(t1 - t0);
  }
  uint32_t bm = median31(base, REPS);
  uint32_t am = median31(aliased, REPS);
  int32_t d = (int32_t)am - (int32_t)bm;
  printf("[bpu-collision] delta=0x%08x baseline=%u aliased=%u penalty=%d "
         "%s\n", (unsigned)delta, (unsigned)bm, (unsigned)am, d,
         d > 4 ? "ALIASING" : "no-alias");
  printf("SCRESULT bpu-collision-0x%x %s delta=0x%x base=%u aliased=%u "
         "penalty=%d alias=%d\n", (unsigned)delta,
         d > 4 ? "ALIASING" : "NO_ALIAS", (unsigned)delta, (unsigned)bm,
         (unsigned)am, d, d > 4 ? 1 : 0);
  sc_alias_free(&al);
}

int main(void) {
  if (sc_time_selfcheck("bpu-collision") != 0)
    return 1;
  ta = (void *)gadget_a;
  tb = (void *)gadget_b;
  static const uint32_t deltas[] = {
      64, 4096, 16384, 32768, 524288, 2097152};
  int any = 0;
  for (unsigned i = 0; i < sizeof(deltas) / sizeof(deltas[0]); i++) {
    int sup = 0;
    measure_delta(deltas[i], &sup);
    any |= sup;
  }
  if (!any) {
    printf("SCRESULT bpu-collision ERROR reason=no-alias-arena\n");
    return 1;
  }
  printf("[bpu-collision] signature: multiples of 16 KiB alias the ITT; "
         "64 B / 4 KiB must not\n");
  return 0;
}