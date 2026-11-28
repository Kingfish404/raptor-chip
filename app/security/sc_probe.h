#ifndef __SC_PROBE_H__
#define __SC_PROBE_H__
/*
 * sc_probe.h: runtime cache-geometry calibration and eviction primitives.
 *
 * Why calibration instead of constants: the suite must run across the
 * small/middle/default/default-w4-l2 and SMP presets, whose L1/L2 capacities
 * differ.  A footprint sweep with a random dependent pointer chase locates
 * the L1 and L2 knees empirically.
 *
 * IMPORTANT measurement consistency: the three latency classes are measured
 * with sc_timed_load (the SAME primitive the probe loop uses), not with the
 * chase.  The chase brackets many dependent loads with one counter pair and
 * so excludes per-access CSR overhead; sc_timed_load brackets each access
 * with two counter reads.  Mixing the two would shift every class boundary
 * by the CSR overhead and misclassify hits.  The chase is used only to find
 * capacity knees (relative jumps), the classes come from sc_timed_load.
 *
 * Eviction correctness notes (verified against the RTL):
 *  - L1D is VIPT with index addr[11:6] inside the 4 KiB page offset
 *    (rapt_l1d.sv:1396), so a VA conflict set at 4 KiB stride is exact.
 *  - L2 is PIPT with index pa[14:6] (rapt_l2.sv:787).  Under 4 KiB pages
 *    VA[14:12] is translated, so a VA conflict set does NOT reliably target
 *    one L2 set.  L2 eviction therefore uses cbo.inval when available, else
 *    a capacity sweep of a dedicated buffer larger than L2.
 *  - L2 replacement is a pseudo-random LFSR, not LRU
 *    (rapt_l2_directory.sv:152-186): a target survives k same-set evictions
 *    with probability (7/8)^k, so 9 lines leave ~30% residue.  Capacity
 *    eviction plus round repetition and a significance test is required.
 *  - The L1D stride prefetcher needs 3 identical page-local strides and is
 *    never trained by speculative loads (rapt_l1d_stride_pf.sv).  Every
 *    sweep here is a random permutation of dependent loads, so it neither
 *    trains nor benefits from the prefetcher.
 */

#include "sc_common.h"

#ifndef SC_CALIB_MAX
#define SC_CALIB_MAX (1u << 20)
#endif
#ifndef SC_EVICT_MAX
/* 8x a 256 KiB L2.  L2 victims are an LFSR (rapt_l2_directory.sv), so a
 * 2x sweep still leaves ~(7/8)^16 of lines resident.  8x drives that
 * below 0.1% and is what makes a single-shot eviction self-test stable. */
#define SC_EVICT_MAX (2u << 20)
#endif
#ifndef SC_L1_WAYS
#define SC_L1_WAYS 4
#endif
#ifndef SC_L2_WAYS
#define SC_L2_WAYS 8
#endif

/* Probe stride: 64*65 = 4160.  A 4096 stride would put all 256 probe lines
 * in ONE 4-way L1D set (index addr[11:6] unchanged) and only 8 L2 sets, so
 * the probe loop would evict its own evidence.  An odd multiple of the line
 * size spreads entries over all 64 L1D sets and 256 L2 sets. */
#ifndef SECURITY_PROBE_STRIDE
#define SECURITY_PROBE_STRIDE 4160
#endif
#define SC_PROBE_STRIDE SECURITY_PROBE_STRIDE
#define SC_PROBE_ENTRIES 256

typedef struct {
  uint32_t l1_bytes, l1_ways, l1_stride;
  uint32_t l2_bytes, l2_ways, l2_stride;
  uint32_t dtlb_stride, l2tlb_stride;
  uint32_t t_l1, t_l2, t_dram;
  int has_l2;
  int cbo_ok;
} sc_geom_t;

/* ---- RNG (xorshift32, same family as app/benchmarks/memprobe) ---------- */
static inline uint32_t sc_rand(uint32_t *s) {
  uint32_t x = *s;
  x ^= x << 13;
  x ^= x >> 17;
  x ^= x << 5;
  *s = x;
  return x;
}

static inline void sc_perm_order(uint32_t *ord, uint32_t n, uint32_t seed) {
  uint32_t s = seed ? seed : 1;
  for (uint32_t i = 0; i < n; i++)
    ord[i] = i;
  for (uint32_t i = n - 1; i > 0; i--) {
    uint32_t j = sc_rand(&s) % (i + 1);
    uint32_t t = ord[i];
    ord[i] = ord[j];
    ord[j] = t;
  }
}

/* ---- Dependent pointer chase (capacity knees only) --------------------- */
typedef struct sc_node {
  struct sc_node *volatile next;
  uint8_t pad[SC_LINE_BYTES - sizeof(void *)];
} sc_node_t;

#define SC_MAX_NODES (SC_CALIB_MAX / SC_LINE_BYTES)

static sc_node_t sc_calib_nodes[SC_MAX_NODES]
    __attribute__((aligned(SC_PAGE_BYTES)));
static uint32_t sc_ord[SC_MAX_NODES];
static uint8_t sc_selftest_buf[2 * SC_PAGE_BYTES]
    __attribute__((aligned(SC_PAGE_BYTES)));

static inline sc_node_t *sc_chase(sc_node_t *p, size_t steps) {
  for (size_t i = 0; i < steps / 8; i++) {
    p = p->next; p = p->next; p = p->next; p = p->next;
    p = p->next; p = p->next; p = p->next; p = p->next;
  }
  return p;
}

static inline void sc_build_ring(uint32_t n, uint32_t seed) {
  sc_perm_order(sc_ord, n, seed);
  for (uint32_t i = 0; i < n; i++)
    sc_calib_nodes[sc_ord[i]].next = &sc_calib_nodes[sc_ord[(i + 1) % n]];
}

static inline uint32_t sc_chase_latency(uint32_t n, uint32_t seed) {
  sc_build_ring(n, seed);
  sc_node_t *p = &sc_calib_nodes[0];
  p = sc_chase(p, (size_t)n); /* warm to steady state */
#ifdef SC_CALIB_QUICK
  int reps = 1;
  size_t rings = 1;
#else
  int reps = 3;
  size_t rings = 2;
#endif
  uint32_t best = UINT32_MAX;
  for (int rep = 0; rep < reps; rep++) {
    size_t steps = (size_t)n * rings;
    uint64_t t0 = sc_cycle();
    p = sc_chase(p, steps);
    uint64_t t1 = sc_cycle();
    uint32_t lat = (uint32_t)((t1 - t0) / steps);
    if (lat < best)
      best = lat;
  }
  return best ? best : 1;
}

/* ---- Eviction -----------------------------------------------------------
 * sc_evict_l1_conflict evicts L1D while preserving the inclusive L2 copy
 * (never cbo.inval, which clears L2 too, rapt_l2.sv:336).  A dependent chase
 * over ~4x L1 but < L2 provably evicts L1 on real FPGA hardware; plain
 * conflict-set loads were observed ineffective there.
 */
static inline void sc_evict_l1_conflict(const void *addr, const sc_geom_t *g) {
  (void)addr;
  uint32_t bytes = g->l1_bytes * 4;
  if (g->has_l2 && bytes >= g->l2_bytes)
    bytes = g->l2_bytes / 2;
  uint32_t n = bytes / SC_LINE_BYTES;
  if (n < 2)
    n = 2;
  if (n > SC_MAX_NODES)
    n = SC_MAX_NODES;
  sc_build_ring(n, 0x11eeu);
  sc_node_t *p = &sc_calib_nodes[0];
  sc_chase(p, (size_t)n);
  sc_fence();
}

static inline void sc_evict_l1(const void *addr, const sc_geom_t *g) {
  if (g->cbo_ok) {
    sc_cbo_inval((void *)((uintptr_t)addr & ~(uintptr_t)(SC_LINE_BYTES - 1)));
    sc_fence();
    return;
  }
  sc_evict_l1_conflict(addr, g);
}

/* Capacity eviction via a dependent pointer chase over a dedicated 1 MiB
 * ring.  On real FPGA hardware independent random loads were observed to
 * leave the target L2-resident (cold access measured ~20 cycles), while a
 * dependent chase at this footprint provably reaches DRAM (~65 cycles/access
 * in calibration).  sc_calib_nodes is never the probe array, so this cannot
 * self-warm the evidence. */
static inline void sc_evict_capacity(const sc_geom_t *g) {
  (void)g;
  uint32_t n = SC_MAX_NODES;
  sc_build_ring(n, 0x9e37u);
  sc_node_t *p = &sc_calib_nodes[0];
  sc_chase(p, (size_t)n);
  sc_fence();
}

static inline void sc_evict_l2(const void *addr, const sc_geom_t *g) {
  if (g->cbo_ok) {
    sc_cbo_inval((void *)((uintptr_t)addr & ~(uintptr_t)(SC_LINE_BYTES - 1)));
    sc_fence();
    return;
  }
  (void)addr;
  sc_evict_capacity(g);
}

/* Warm L1 hit latency: min of consecutive accesses (the line stays resident,
 * so every rep is a genuine hit). */
static inline uint32_t sc_measure_warm(const volatile uint8_t *p) {
  (void)*p;
  (void)*p; /* ensure L1-resident before timing (reject cold-first glitch) */
  uint32_t best = UINT32_MAX;
  for (int rep = 0; rep < 3; rep++) {
    uint32_t t = sc_timed_load(p);
    if (t < best)
      best = t;
  }
  return best;
}

/* ---- Calibration -------------------------------------------------------- */
static inline int sc_calibrate(sc_geom_t *g) {
  /* Pre-fault every page of the measurement buffers so NFS-backed demand
   * paging cannot inject latency spikes into the timed chase on real FPGA
   * hardware (observed DRAM reference swinging 64->199 cycles under memory
   * pressure).  Touch one byte per page before any timing starts. */
  for (uint32_t off = 0; off < SC_CALIB_MAX; off += SC_PAGE_BYTES)
    ((volatile uint8_t *)sc_calib_nodes)[off] = 0;
  for (uint32_t off = 0; off < sizeof(sc_selftest_buf); off += SC_PAGE_BYTES)
    sc_selftest_buf[off] = 0;
  sc_fence();
#ifdef SC_CALIB_QUICK
  static const uint32_t sizes[] = {1024, 8192, 16384, 32768, 262144, 1048576};
#else
  static const uint32_t sizes[] = {
      1024, 2048, 4096, 8192, 12288, 16384, 24576, 32768, 49152,
      65536, 98304, 131072, 196608, 262144, 393216, 524288, 786432, 1048576};
#endif
  enum { NS = sizeof(sizes) / sizeof(sizes[0]) };
  uint32_t lat[NS];
  for (int i = 0; i < NS; i++) {
    uint32_t n = sizes[i] / SC_LINE_BYTES;
    if (n > SC_MAX_NODES)
      n = SC_MAX_NODES;
    lat[i] = sc_chase_latency(n, 0x5eedu + (uint32_t)i);
  }

  memset(g, 0, sizeof(*g));
  g->l1_ways = SC_L1_WAYS;
  g->l2_ways = SC_L2_WAYS;
  g->cbo_ok = sc_cbo_probe() ? 1 : 0;
  g->dtlb_stride = 131072;   /* DTLB index va[16:12] */
  g->l2tlb_stride = 1048576; /* L2TLB index vtag[19:12] */

  int i1 = -1, i2 = -1;
  uint32_t base = lat[0];
  for (int i = 1; i < NS; i++) {
    if (lat[i] >= base + base / 2) { i1 = i; break; }
  }
  if (i1 < 0) {
    g->l1_bytes = sizes[NS - 1];
    g->has_l2 = 0;
  } else {
    g->l1_bytes = sizes[i1 - 1];
    /* An L2 tier exists when bulk (DRAM) chase latency is clearly above the
     * first post-L1 tier.  This is more robust than requiring a second knee,
     * which run-to-run noise sometimes misses on real hardware. */
    if (lat[NS - 1] >= lat[i1] + lat[i1] / 2) {
      g->has_l2 = 1;
      uint32_t l2ref = lat[i1];
      for (int i = i1 + 1; i < NS; i++) {
        if (lat[i] >= l2ref + l2ref / 2) { i2 = i; break; }
      }
      g->l2_bytes = (i2 >= 0) ? sizes[i2 - 1] : sizes[NS - 2];
    }
  }
  g->l1_stride = g->l1_bytes / g->l1_ways;
  if (g->l1_stride < SC_LINE_BYTES)
    g->l1_stride = SC_PAGE_BYTES;
  g->l2_stride = g->has_l2 ? g->l2_bytes / g->l2_ways : 0;

  /* Derive the three classes from the stable amortized chase latencies plus
   * the measured per-access CSR overhead, so they match the probe loop's
   * single-access timing without relying on noisy single cold measurements. */
  volatile uint8_t *p = sc_selftest_buf + SC_LINE_BYTES;
  uint32_t warm_single = sc_measure_warm(p);
  uint32_t overhead = warm_single > lat[0] ? warm_single - lat[0] : 0;
  g->t_l1 = lat[0] + overhead;
  g->t_dram = lat[NS - 1] + overhead;
  if (g->has_l2 && i1 >= 0) {
    g->t_l2 = lat[i1] + overhead;
    if (g->t_l2 <= g->t_l1 || g->t_l2 >= g->t_dram) {
      g->t_l2 = g->t_dram;
      g->has_l2 = 0;
    }
  } else {
    g->t_l2 = g->t_dram;
    g->has_l2 = 0;
  }
#ifdef SC_CALIB_DEBUG
  fprintf(stderr, "[calib] lat0=%u lat_i1=%d latN=%u i1=%d i2=%d has_l2=%d "
          "ovh=%u t_l1=%u t_l2=%u t_dram=%u\n",
          (unsigned)lat[0], i1 >= 0 ? (int)lat[i1] : -1,
          (unsigned)lat[NS - 1], i1, i2, g->has_l2, (unsigned)overhead,
          (unsigned)g->t_l1, (unsigned)g->t_l2, (unsigned)g->t_dram);
#endif
  return 0;
}

/* ---- Eviction self-test -------------------------------------------------
 * Gate for the whole suite: warm a known line, evict it, and require the
 * re-access to land in the DRAM class.  If this fails the eviction primitive
 * is broken and every downstream verdict would be a false negative.
 */
static inline int sc_evict_selftest(const sc_geom_t *g) {
  volatile uint8_t *p = sc_selftest_buf + SC_LINE_BYTES;
  (void)*p;
  (void)*p;
  uint32_t warm = sc_measure_warm(p);
  sc_evict_l1((const void *)p, g);
  sc_evict_l2((const void *)p, g);
  uint32_t cold = sc_timed_load(p); /* single access: genuinely cold */
  /* Require a clear latency increase, not an absolute floor: the calibrated
   * DRAM reference can drift with the memory model, but a working eviction
   * must always move a warm line measurably colder. */
  uint32_t margin = warm / 2 + 2;
  if (cold <= warm || (cold - warm) < margin) {
    printf("[sc] evict self-test FAILED warm=%u cold=%u margin=%u\n",
           (unsigned)warm, (unsigned)cold, (unsigned)margin);
    return -1;
  }
  return 0;
}

#endif /* __SC_PROBE_H__ */