#ifndef __SC_STATS_H__
#define __SC_STATS_H__
/*
 * sc_stats.h: three-class latency scoring, controls and significance tests.
 *
 * The old suite used threshold = baseline_hit*2 from a single sample, with
 * no positive or null control, so "NOT VULNERABLE" could not be told apart
 * from "the test is broken".  Here:
 *  - latency is classified into L1 / L2 / DRAM using calibrated medians;
 *  - a positive control must show signal, else the verdict is INCONCLUSIVE;
 *  - a null arm measures the per-index false-positive base rate;
 *  - VULNERABLE requires the attack argmax (over ALL 256 indices, including
 *    0) to equal the expected secret index AND a two-proportion z-test
 *    against the null arm to pass Bonferroni alpha=0.01/256 AND an effect
 *    size of at least 20 percentage points.
 */

#include "sc_common.h"
#include "sc_probe.h"

typedef enum {
  SC_VULNERABLE,
  SC_NOT_VULNERABLE,
  SC_INCONCLUSIVE,
  SC_ERROR
} sc_verdict_t;

static inline const char *sc_verdict_name(sc_verdict_t v) {
  switch (v) {
    case SC_VULNERABLE: return "VULNERABLE";
    case SC_NOT_VULNERABLE: return "NOT_VULNERABLE";
    case SC_INCONCLUSIVE: return "INCONCLUSIVE";
    default: return "ERROR";
  }
}

/* 0 = L1, 1 = L2, 2 = DRAM.  Midpoints between calibrated medians. */
static inline int sc_class(uint32_t t, const sc_geom_t *g) {
  uint32_t m1 = (g->t_l1 + g->t_l2) / 2;
  uint32_t m2 = (g->t_l2 + g->t_dram) / 2;
  if (t <= m1)
    return 0;
  if (t <= m2)
    return 1;
  return 2;
}

typedef struct {
  uint32_t hits[SC_PROBE_ENTRIES];   /* cached: L1 or L2 */
  uint32_t l1hits[SC_PROBE_ENTRIES]; /* L1 only */
  uint64_t lat_sum[SC_PROBE_ENTRIES];
  uint32_t rounds;
} sc_score_t;

static inline void sc_score_reset(sc_score_t *s) {
  memset(s, 0, sizeof(*s));
}

static inline void sc_score_add(sc_score_t *s, int idx, uint32_t t,
                                const sc_geom_t *g) {
  if (idx < 0 || idx >= SC_PROBE_ENTRIES)
    return;
  int c = sc_class(t, g);
  if (c <= 1)
    s->hits[idx]++;
  if (c == 0)
    s->l1hits[idx]++;
  s->lat_sum[idx] += t;
}

static inline int sc_argmax(const sc_score_t *s) {
  int best = 0;
  for (int i = 1; i < SC_PROBE_ENTRIES; i++)
    if (s->hits[i] > s->hits[best])
      best = i;
  return best;
}

/* Integer sqrt so the suite needs no libm (the pk build does not link -lm). */
static inline uint64_t sc_isqrt64(uint64_t n) {
  if (n == 0)
    return 0;
  uint64_t x = n, y = (x + 1) / 2;
  while (y < x) {
    x = y;
    y = (x + n / x) / 2;
  }
  return x;
}

/* Two-proportion z statistic (attack vs null) scaled by 100, one-sided.
 * z = (h1-h2) * sqrt(2r / ((h1+h2)*(2r-h1-h2))). */
static inline int sc_z100(uint32_t h1, uint32_t h2, uint32_t r) {
  if (r == 0 || h1 <= h2)
    return 0;
  uint64_t sum = (uint64_t)h1 + h2;
  uint64_t rem = 2ull * r - sum;
  if (rem == 0)
    return 0;
  uint64_t q = (2ull * r * 10000ull) / (sum * rem);
  return (int)((uint64_t)(h1 - h2) * sc_isqrt64(q));
}

/* Exact significance test without rounding: z^2 >= 3.95^2 is equivalent to
 * (h1-h2)^2 * 2r * 10000 >= 156025 * (h1+h2) * (2r-h1-h2). */
static inline int sc_significant(uint32_t h1, uint32_t h2, uint32_t r) {
  if (r == 0 || h1 <= h2)
    return 0;
  uint64_t d = h1 - h2;
  uint64_t sum = (uint64_t)h1 + h2;
  uint64_t rem = 2ull * r - sum;
  if (rem == 0)
    return 0;
  return d * d * 2ull * r * 10000ull >= 156025ull * sum * rem;
}

typedef struct {
  sc_verdict_t verdict;
  int got;          /* attack argmax */
  int nullmax;      /* null argmax: exposes artifacts like the old 0xf7 */
  uint32_t hit;     /* attack hits at expected index */
  uint32_t nullhit; /* null hits at expected index */
  int z100;
  int effect_pp;    /* effect size in percentage points */
} sc_decision_t;

/* Bonferroni alpha = 0.01/256 ~ 3.9e-5 one-sided => z >= 3.95. */
#define SC_Z_CRIT100 395
/* Practical-significance floor.  The Bonferroni z-test above already guarantees
 * statistical rigor; this only filters trivially small effects.  10 pp with a
 * near-zero null arm is a clear leak (a 20 pp floor rejected real 19 pp leaks). */
#define SC_EFFECT_PP 10

static inline sc_decision_t sc_decide(const sc_score_t *atk,
                                      const sc_score_t *nul,
                                      int expect_idx, int pos_ok) {
  sc_decision_t d;
  memset(&d, 0, sizeof(d));
  d.got = sc_argmax(atk);
  d.nullmax = sc_argmax(nul);
  uint32_t r = atk->rounds;
  if (expect_idx >= 0 && expect_idx < SC_PROBE_ENTRIES) {
    d.hit = atk->hits[expect_idx];
    d.nullhit = nul->hits[expect_idx];
  }
  d.z100 = sc_z100(d.hit, d.nullhit, r);
  if (r)
    d.effect_pp = (int)(((int64_t)d.hit - (int64_t)d.nullhit) * 100 / (int)r);
  if (!pos_ok) {
    d.verdict = SC_INCONCLUSIVE;
    return d;
  }
  if (d.got == expect_idx && sc_significant(d.hit, d.nullhit, r) &&
      d.effect_pp >= SC_EFFECT_PP)
    d.verdict = SC_VULNERABLE;
  else
    d.verdict = SC_NOT_VULNERABLE;
  return d;
}

static inline void sc_result(const char *name, const sc_decision_t *d,
                             int pos_ok, int expect_idx, uint32_t rounds,
                             const sc_geom_t *g) {
  printf("SCRESULT %s %s pos=%d expect=%d got=%d hit=%u/%u nullhit=%u/%u "
         "nullmax=%d z=%d effect=%dpp l1=%u l2=%u dram=%u rounds=%u "
         "cbo=%d stride=%u\n",
         name, sc_verdict_name(d->verdict), pos_ok, expect_idx, d->got,
         (unsigned)d->hit, (unsigned)rounds, (unsigned)d->nullhit,
         (unsigned)rounds, d->nullmax, d->z100, d->effect_pp,
         (unsigned)g->t_l1, (unsigned)g->t_l2, (unsigned)g->t_dram,
         (unsigned)rounds, g->cbo_ok, (unsigned)SC_PROBE_STRIDE);
}

/* Probe every entry once in random order and score it.  Random permutation
 * defeats the IP-stride prefetcher; the 4160 stride spreads entries across
 * all L1D sets so the probe loop does not evict its own evidence. */
static inline void sc_probe_array(uint8_t *probe, const sc_geom_t *g,
                           sc_score_t *s, uint32_t seed) {
  sc_perm_order(sc_ord, SC_PROBE_ENTRIES, seed);
  for (int i = 0; i < SC_PROBE_ENTRIES; i++) {
    int idx = (int)sc_ord[i];
    uint32_t t = sc_timed_load(probe + (uintptr_t)idx * SC_PROBE_STRIDE);
    sc_score_add(s, idx, t, g);
  }
}

#endif /* __SC_STATS_H__ */