#ifndef __SC_COMMON_H__
#define __SC_COMMON_H__
/*
 * sc_common.h: platform, timing and privilege helpers for the side-channel
 * detection suite.
 *
 * Header-only on purpose: app/common.mk compiles every *.c in this directory
 * into its own ELF, so shared code must not live in a .c file.
 *
 * Runs under riscv-pk (U-mode, picolibc) and Linux userspace (glibc).
 * __linux__ distinguishes the two: only Linux has signal machinery, so the
 * Zicbom runtime probe and mmap-based alias arenas are Linux-only.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#if defined(__linux__) || defined(__FreeBSD__) || defined(__NetBSD__)
#define SC_POSIX_OS 1
#include <signal.h>
#include <sys/mman.h>
#include <ucontext.h>
#include <unistd.h>
#ifndef MAP_ANONYMOUS
#define MAP_ANONYMOUS MAP_ANON
#endif
#endif

#define SC_LINE_BYTES 64
#define SC_PAGE_BYTES 4096

/* ---- Counters ----------------------------------------------------------
 * mcycle increments every core clock (rapt_csr.sv:1163) and the U/S `cycle`
 * alias maps onto it.  `time` is CLINT mtime: on FPGA it ticks once per
 * 50-75 core cycles, far too coarse for a ~20-cycle cache hit, so the suite
 * must never use rdtime for latency measurement.
 */
static inline uint64_t sc_cycle(void) {
#if __riscv_xlen == 64
  uint64_t v;
  asm volatile("csrr %0, cycle" : "=r"(v));
  return v;
#else
  uint32_t hi, lo, hi2;
  do {
    asm volatile("csrr %0, cycleh" : "=r"(hi));
    asm volatile("csrr %0, cycle" : "=r"(lo));
    asm volatile("csrr %0, cycleh" : "=r"(hi2));
  } while (hi != hi2);
  return ((uint64_t)hi << 32) | lo;
#endif
}

static inline uint64_t sc_instret(void) {
#if __riscv_xlen == 64
  uint64_t v;
  asm volatile("csrr %0, instret" : "=r"(v));
  return v;
#else
  uint32_t hi, lo, hi2;
  do {
    asm volatile("csrr %0, instreth" : "=r"(hi));
    asm volatile("csrr %0, instret" : "=r"(lo));
    asm volatile("csrr %0, instreth" : "=r"(hi2));
  } while (hi != hi2);
  return ((uint64_t)hi << 32) | lo;
#endif
}

static inline void sc_fence(void) { asm volatile("fence" ::: "memory"); }
static inline void sc_fence_i(void) { asm volatile("fence.i" ::: "memory"); }

/* Time one byte load.  One asm block keeps the two counter reads and the
 * load in program order; a C-level load can be sunk past the second read.
 * rdcycle is not a memory fence, but this is the sequence that separates
 * L1 hits from DRAM misses on this core (the pointer-chase calibration is
 * the ground truth for the three latency classes). */
static inline uint32_t sc_timed_load(const volatile uint8_t *p) {
  uint64_t t0, t1;
  uint64_t v;
  asm volatile(
      "fence rw, rw\n\t"
      "rdcycle %0\n\t"
      "lbu %2, 0(%3)\n\t"
      "rdcycle %1\n\t"
      : "=&r"(t0), "=&r"(t1), "=&r"(v)
      : "r"(p)
      : "memory");
  return (uint32_t)(t1 - t0);
}

/* Spin until `cycles` of the cycle counter have elapsed.  Used to let an
 * in-flight L2 refill finish after a pipeline flush killed the L1D MSHR. */
static inline void sc_wait(uint32_t cycles) {
  uint64_t start = sc_cycle();
  while ((uint32_t)(sc_cycle() - start) < cycles)
    asm volatile("" ::: "memory");
}

/* ---- Timer resolution gate ---------------------------------------------
 * A dependent addi chain retires at ~1 cycle/iteration.  If the counter is
 * unavailable, frozen, or coarse (e.g. accidentally wired to mtime) the
 * measured total collapses.  Fail loudly rather than emit a false negative.
 */
static inline int sc_time_selfcheck(const char *name) {
  enum { N = 1000 };
  uint64_t acc = 1;
  uint64_t t0 = sc_cycle();
  for (int i = 0; i < N; i++)
    asm volatile("addi %0, %0, 1" : "+r"(acc));
  uint64_t t1 = sc_cycle();
  uint64_t el = t1 - t0;
  /* The dangerous failure is a coarse/frozen counter (el < N): it would
   * collapse cache-hit resolution and fake a negative.  No upper bound: on a
   * shared FPGA board preemption can legitimately stretch this loop far beyond
   * its nominal ~1 cycle/iteration, and that must not fail the gate. */
  if (t1 <= t0 || el < N) {
    printf("SCRESULT %s ERROR reason=timer elapsed=%llu expect>=%d\n",
           name, (unsigned long long)el, N);
    return -1;
  }
  return 0;
}

/* ---- Zicbom ------------------------------------------------------------
 * The app -march string lacks zicbom, so emit raw encodings: MISC-MEM
 * (0x0F), funct3=010, rd=x0, funct12 = 0x000 inval / 0x002 flush
 * (rapt_decode_slot.sv:330-341).
 *
 * U-mode legality needs menvcfg.CBIE && senvcfg.CBIE for inval, and
 * menvcfg.CBCFE && senvcfg.CBCFE for flush (rapt_decode_slot.sv:343-350).
 * pk deliberately skips those senvcfg bits (app/pk/src/pk.c:59-60), so CBO
 * is illegal under pk and the conflict-set fallback is mandatory there.
 */
static inline void sc_cbo_inval(void *line) {
  asm volatile(".insn i 0x0F, 0x2, x0, %0, 0x000" ::"r"(line) : "memory");
}

static inline void sc_cbo_flush(void *line) {
  asm volatile(".insn i 0x0F, 0x2, x0, %0, 0x002" ::"r"(line) : "memory");
}

#if (defined(__linux__) && defined(REG_PC)) || defined(__FreeBSD__) || \
    (defined(__NetBSD__) && defined(_UC_MACHINE_SET_PC))
#define SC_HAS_SIGILL_SKIP 1
static volatile int sc_ill_armed;
static volatile int sc_ill_hit;

static void sc_ill_handler(int sig, siginfo_t *si, void *ucv) {
  ucontext_t *uc = (ucontext_t *)ucv;
  (void)si;
  if (sc_ill_armed) {
    sc_ill_armed = 0;
    sc_ill_hit = 1;
    /* .insn i is a fixed 4-byte instruction: skip it and resume. */
#if defined(__linux__) && defined(REG_PC)
    uc->uc_mcontext.__gregs[REG_PC] += 4;
#elif defined(__FreeBSD__)
    uc->uc_mcontext.mc_gpregs.gp_sepc += 4;
#elif defined(__NetBSD__)
    _UC_MACHINE_SET_PC(uc, _UC_MACHINE_PC(uc) + 4);
#endif
    return;
  }
  signal(sig, SIG_DFL);
  raise(sig);
}
#endif

/* One-shot runtime probe on a scratch line.  Returns true only if cbo.inval
 * actually executed.  Never traps under pk (no probe is attempted). */
static inline bool sc_cbo_probe(void) {
#if defined(SC_HAS_SIGILL_SKIP)
  static int done, ok;
  static uint8_t scratch[SC_LINE_BYTES] __attribute__((aligned(SC_LINE_BYTES)));
  if (done)
    return ok != 0;
  done = 1;
  struct sigaction sa, old;
  memset(&sa, 0, sizeof(sa));
  sa.sa_sigaction = sc_ill_handler;
  sa.sa_flags = SA_SIGINFO;
  sigemptyset(&sa.sa_mask);
  if (sigaction(SIGILL, &sa, &old) != 0)
    return false;
  scratch[0] = 1;
  sc_ill_hit = 0;
  sc_ill_armed = 1;
  sc_cbo_inval(scratch);
  sc_ill_armed = 0;
  ok = sc_ill_hit ? 0 : 1;
  sigaction(SIGILL, &old, NULL);
  return ok != 0;
#else
  return false;
#endif
}

/* ---- Executable arena ---------------------------------------------------
 * Alias sites must sit at an exact PC delta regardless of ASLR or link
 * layout, so they are placed as hand-assembled stubs inside one arena.
 * Linux: mmap RW, write stubs, mprotect RX, fence.i.  pk has no mmap-backed
 * exec arena; sc_alias.h supplies a .text blob for the primary 32 KiB delta.
 */
static inline void *sc_exec_alloc(size_t bytes) {
#if defined(SC_POSIX_OS)
  int prot = PROT_READ | PROT_WRITE;
#ifdef PROT_MPROTECT
  prot |= PROT_MPROTECT(PROT_EXEC);
#endif
  void *p = mmap(NULL, bytes, prot, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  return (p == MAP_FAILED) ? NULL : p;
#else
  (void)bytes;
  return NULL;
#endif
}

static inline int sc_exec_publish(void *p, size_t bytes) {
#if defined(SC_POSIX_OS)
  if (mprotect(p, bytes, PROT_READ | PROT_EXEC) != 0)
    return -1;
  sc_fence_i();
  return 0;
#else
  (void)p;
  (void)bytes;
  return -1;
#endif
}

static inline void sc_exec_free(void *p, size_t bytes) {
#if defined(SC_POSIX_OS)
  if (p)
    munmap(p, bytes);
#else
  (void)p;
  (void)bytes;
#endif
}

#endif /* __SC_COMMON_H__ */