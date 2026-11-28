/**
 * cache-timing: calibration canary for the side-channel detection suite.
 *
 * This is the gate every other test depends on.  It measures the L1/L2/DRAM
 * latency ladder with a random dependent pointer chase, probes whether
 * Zicbom eviction is usable, and verifies that the eviction primitive really
 * moves a warm line to the DRAM class.  If any of these fail, downstream
 * "NOT VULNERABLE" verdicts would be meaningless, so this test exits non-zero
 * on ERROR rather than reporting a reassuring green.
 */
#include "bench.h"

#ifndef SECURITY_CACHE_ROUNDS
#define SECURITY_CACHE_ROUNDS 64
#endif

static uint8_t demo_line[2 * SC_PAGE_BYTES]
    __attribute__((aligned(SC_PAGE_BYTES)));

int main(void) {
  if (sc_time_selfcheck("cache-timing") != 0)
    return 1;

  sc_geom_t g;
  sc_calibrate(&g);

  printf("[cache-timing] measured L1=%u B (ways=%u stride=%u) "
         "L2=%u B (ways=%u stride=%u) has_l2=%d cbo=%d\n",
         (unsigned)g.l1_bytes, (unsigned)g.l1_ways, (unsigned)g.l1_stride,
         (unsigned)g.l2_bytes, (unsigned)g.l2_ways, (unsigned)g.l2_stride,
         g.has_l2, g.cbo_ok);
  printf("[cache-timing] latency ladder L1=%u L2=%u DRAM=%u cycles\n",
         (unsigned)g.t_l1, (unsigned)g.t_l2, (unsigned)g.t_dram);
  printf("[cache-timing] probe stride=%u entries=%d "
         "(4096 would collapse to 1 L1D set / 8 L2 sets)\n",
         (unsigned)SC_PROBE_STRIDE, SC_PROBE_ENTRIES);

  int sep_ok = (g.t_l1 < g.t_l2) && (g.t_l2 < g.t_dram) &&
               (g.t_l2 >= g.t_l1 + g.t_l1 / 2) &&
               (g.t_dram >= g.t_l2 + g.t_l2 / 2);
  if (!g.has_l2)
    sep_ok = (g.t_l1 < g.t_dram) && (g.t_dram >= g.t_l1 + g.t_l1 / 2);

  /* Demonstrate the ladder on one line: warm -> L1, evict L1 only -> L2,
   * evict L2 -> DRAM.  sc_evict_l1_conflict never uses CBO, so it leaves the
   * inclusive L2 copy intact (cbo.inval would clear L2 too). */
  volatile uint8_t *p = demo_line + SC_LINE_BYTES;
  (void)*p;
  (void)*p;
  uint32_t t_warm = sc_timed_load(p);
  sc_evict_l1_conflict((const void *)p, &g);
  uint32_t t_l1ev = sc_timed_load(p);
  sc_evict_l2((const void *)p, &g);
  uint32_t t_cold = sc_timed_load(p);
  printf("[cache-timing] single-line ladder warm=%u l1evicted=%u cold=%u\n",
         (unsigned)t_warm, (unsigned)t_l1ev, (unsigned)t_cold);

  /* Diagnostic: a NEVER-touched line is guaranteed cold (no eviction needed).
   * Its first-access latency is the true DRAM reference.  If this is large
   * but t_cold above is small, the eviction primitive is not reaching DRAM. */
  static uint8_t cold_ref[4 * SC_LINE_BYTES]
      __attribute__((aligned(SC_PAGE_BYTES)));
  uint32_t fresh0 = sc_timed_load(cold_ref);
  uint32_t fresh1 = sc_timed_load(cold_ref + SC_LINE_BYTES);
  uint32_t fresh2 = sc_timed_load(cold_ref + 2 * SC_LINE_BYTES);
  printf("[cache-timing] guaranteed-cold fresh lines: %u %u %u cycles\n",
         (unsigned)fresh0, (unsigned)fresh1, (unsigned)fresh2);
  printf("[cache-timing] chase bulk latency 1MiB=%u cycles/access\n",
         (unsigned)sc_chase_latency(SC_CALIB_MAX / SC_LINE_BYTES, 0xdead));
  report("cache-timing", t_warm, t_cold);

  int evict_ok = sc_evict_selftest(&g) == 0;

  /* Prefetcher sensitivity: a constant-stride sweep trains the degree-2
   * IP-stride prefetcher (3 identical strides), a random permutation does
   * not.  Reporting the gap documents why the suite probes in random order. */
  uint32_t seq_best = UINT32_MAX, rnd_best = UINT32_MAX;
  for (int rep = 0; rep < 3; rep++) {
    uint64_t t0 = sc_cycle();
    for (int i = 0; i < SC_PROBE_ENTRIES; i++) {
      volatile uint8_t *q = demo_line + (i % 2) * SC_LINE_BYTES;
      (void)*q;
    }
    uint64_t t1 = sc_cycle();
    uint32_t avg = (uint32_t)((t1 - t0) / SC_PROBE_ENTRIES);
    if (avg < seq_best) seq_best = avg;
    sc_perm_order(sc_ord, SC_PROBE_ENTRIES, 0x1234u + rep);
    t0 = sc_cycle();
    for (int i = 0; i < SC_PROBE_ENTRIES; i++) {
      volatile uint8_t *q = demo_line + (sc_ord[i] % 2) * SC_LINE_BYTES;
      (void)*q;
    }
    t1 = sc_cycle();
    avg = (uint32_t)((t1 - t0) / SC_PROBE_ENTRIES);
    if (avg < rnd_best) rnd_best = avg;
  }
  printf("[cache-timing] same-line sweep seq=%u rnd=%u cycles/access "
         "(prefetcher reference)\n", (unsigned)seq_best, (unsigned)rnd_best);

  int ok = sep_ok && evict_ok;
  printf("SCRESULT cache-timing %s pos=%d l1=%u l2=%u dram=%u cbo=%d "
         "evict=%d sep=%d rounds=%u\n",
         ok ? "PASS" : "ERROR", ok, (unsigned)g.t_l1, (unsigned)g.t_l2,
         (unsigned)g.t_dram, g.cbo_ok, evict_ok, sep_ok,
         (unsigned)SECURITY_CACHE_ROUNDS);
  if (!ok) {
    printf("[cache-timing] ERROR: calibration gate failed; "
           "downstream verdicts are not trustworthy\n");
    return 1;
  }
  return 0;
}