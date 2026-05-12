/* memtest.c: Comprehensive memory subsystem test suite.
 *
 * Adapted from memtest86+ (GPL-2.0) — see third_party/memtest86plus/.
 * Reduced and re-targeted to a single-hart RV32/RV64 user ELF running
 * over a static buffer (we can't probe physical DRAM from user mode).
 *
 * Tests executed (in order):
 *   1. Address bus  — walking-1's address test
 *   2. Own-address  — each cell stores (its address) and inverted
 *   3. Mov-inv-0/-1 — moving inversions with all-0 / all-1 patterns
 *   4. Mov-inv-55   — moving inversions with 0x55../0xAA.. patterns
 *   5. Mov-inv-walk1 — moving inversions with walking-bit pattern
 *   6. Modulo-20    — modulo-N pattern (catches near-neighbour faults)
 *   7. Block-move   — memtest86+ style block-move stress
 *   8. Random-LFSR  — pseudo-random pattern (data-dependent stress)
 *   9. Bit-fade     — write, delay, re-read (cache + retention)
 *
 * Build: picked up automatically by app/tests/memory/Makefile.
 * Override the buffer size at compile time with -DMEMTEST_WORDS=N.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

/* ---------------------------------------------------------------------------
 * Configuration
 * ------------------------------------------------------------------------- */

/* testword_t = native register width (XLEN) */
#if __riscv_xlen == 64
typedef uint64_t testword_t;
#define TW_WIDTH 64
#define TW_FMT   "0x%016lx"
#define PAT_55   0x5555555555555555ULL
#define PAT_AA   0xAAAAAAAAAAAAAAAAULL
#else
typedef uint32_t testword_t;
#define TW_WIDTH 32
#define TW_FMT   "0x%08lx"
#define PAT_55   0x55555555UL
#define PAT_AA   0xAAAAAAAAUL
#endif

/* Default to 16K words = 64KB (RV32) / 128KB (RV64).
 * Sized so the whole buffer overflows L1D and exercises L2/refill paths. */
#ifndef MEMTEST_WORDS
#define MEMTEST_WORDS (16 * 1024)
#endif

#define MAX_ERRORS_PRINT 8

/* Buffer in BSS — aligned to a generous boundary. */
static volatile testword_t buf[MEMTEST_WORDS] __attribute__((aligned(64)));

/* ---------------------------------------------------------------------------
 * Helpers
 * ------------------------------------------------------------------------- */

static int total_passes = 0;
static int total_fails  = 0;

static inline void wr(volatile testword_t *p, testword_t v) { *p = v; }
static inline testword_t rd(volatile testword_t *p)         { return *p; }

static inline void mem_fence(void) { asm volatile("fence rw, rw" ::: "memory"); }

static inline void cache_flush(void) {
    /* No supervisor-mode cache flush from U-mode; fence is the best we can
     * do.  L1 capacity (much smaller than the buffer) ensures most lines
     * are naturally evicted between passes. */
    asm volatile("fence.i" ::: "memory");
    mem_fence();
}

static int report(const char *name, unsigned long errors, testword_t pat) {
    if (errors == 0) {
        printf("  [PASS] %-22s  pattern=" TW_FMT "  errors=0\n",
               name, (unsigned long)pat);
        total_passes++;
        return 0;
    }
    printf("  [FAIL] %-22s  pattern=" TW_FMT "  errors=%lu\n",
           name, (unsigned long)pat, errors);
    total_fails++;
    return 1;
}

static void log_err(unsigned long *err_count, volatile testword_t *p,
                    testword_t expect, testword_t actual) {
    if (*err_count < MAX_ERRORS_PRINT) {
        printf("    err @ %p: expect=" TW_FMT " actual=" TW_FMT
               " xor=" TW_FMT "\n",
               (void *)p, (unsigned long)expect,
               (unsigned long)actual, (unsigned long)(expect ^ actual));
    } else if (*err_count == MAX_ERRORS_PRINT) {
        printf("    ... (suppressing further error prints)\n");
    }
    (*err_count)++;
}

/* ---------------------------------------------------------------------------
 * Test 1: Walking-1 address bus test
 *
 * For each pair (a, b) where a and b are addresses with one bit set,
 * write a unique value to a then b, then verify a hasn't been disturbed.
 * Catches address-line shorts and stuck bits.  O(log^2 N) so cheap.
 * ------------------------------------------------------------------------- */
static int test_addr_walk1(void) {
    unsigned long errors = 0;
    const uintptr_t base = (uintptr_t)&buf[0];
    const uintptr_t end  = (uintptr_t)&buf[MEMTEST_WORDS];

    for (int invert = 0; invert < 2; invert++) {
        testword_t inv = invert ? (testword_t)~(testword_t)0 : 0;
        uintptr_t mask1 = sizeof(testword_t);
        do {
            uintptr_t a1 = base | mask1;
            mask1 <<= 1;
            if (a1 >= end) break;
            volatile testword_t *p1 = (volatile testword_t *)a1;
            testword_t expect = inv ^ (testword_t)(uintptr_t)p1;
            wr(p1, expect);

            uintptr_t mask2 = sizeof(testword_t);
            do {
                uintptr_t a2 = base | mask2;
                mask2 <<= 1;
                if (a2 == a1) continue;
                if (a2 >= end) break;
                volatile testword_t *p2 = (volatile testword_t *)a2;
                wr(p2, ~inv ^ (testword_t)(uintptr_t)p2);

                testword_t actual = rd(p1);
                if (actual != expect) {
                    log_err(&errors, p1, expect, actual);
                    wr(p1, expect);  /* recover */
                }
            } while (mask2);
        } while (mask1);
    }
    return report("addr-walk1", errors, 0);
}

/* ---------------------------------------------------------------------------
 * Test 2: Own-address test
 *
 * Each cell holds its own address (xor optional bias), then verify.
 * Catches address-decoding faults.
 * ------------------------------------------------------------------------- */
static int test_own_addr(testword_t bias) {
    unsigned long errors = 0;
    for (int i = 0; i < MEMTEST_WORDS; i++)
        wr(&buf[i], (testword_t)(uintptr_t)&buf[i] ^ bias);
    cache_flush();
    for (int i = 0; i < MEMTEST_WORDS; i++) {
        testword_t expect = (testword_t)(uintptr_t)&buf[i] ^ bias;
        testword_t actual = rd(&buf[i]);
        if (actual != expect) log_err(&errors, &buf[i], expect, actual);
    }
    return report(bias ? "own-addr (inv)" : "own-addr", errors, bias);
}

/* ---------------------------------------------------------------------------
 * Test 3-5: Moving Inversions
 *
 * Init buffer with `pattern`, then for `iterations` rounds:
 *   forward  : verify == pattern, write ~pattern
 *   backward : verify == ~pattern, write pattern
 * Catches data-line and read/write-back faults.
 * ------------------------------------------------------------------------- */
static int test_mov_inv_fixed(testword_t pattern, int iterations) {
    unsigned long errors = 0;
    const testword_t inv = ~pattern;

    for (int i = 0; i < MEMTEST_WORDS; i++) wr(&buf[i], pattern);
    cache_flush();

    /* Each iteration: forward verifies `pattern` and writes `~pattern`;
     * backward verifies `~pattern` and writes `pattern`.  Memory ends each
     * iteration holding `pattern` again, ready for the next round. */
    for (int it = 0; it < iterations; it++) {
        for (int i = 0; i < MEMTEST_WORDS; i++) {
            testword_t actual = rd(&buf[i]);
            if (actual != pattern) log_err(&errors, &buf[i], pattern, actual);
            wr(&buf[i], inv);
        }
        cache_flush();
        for (int i = MEMTEST_WORDS - 1; i >= 0; i--) {
            testword_t actual = rd(&buf[i]);
            if (actual != inv) log_err(&errors, &buf[i], inv, actual);
            wr(&buf[i], pattern);
        }
        cache_flush();
    }

    return report("mov-inv-fixed", errors, pattern);
}

/* Walking-bit moving inversions: rotates the pattern across all bit positions. */
static int test_mov_inv_walk1(void) {
    unsigned long errors = 0;
    testword_t pattern = 1;

    for (int i = 0; i < MEMTEST_WORDS; i++) {
        wr(&buf[i], pattern);
        pattern = (pattern << 1) | (pattern >> (TW_WIDTH - 1));
    }
    cache_flush();

    pattern = 1;
    for (int i = 0; i < MEMTEST_WORDS; i++) {
        testword_t actual = rd(&buf[i]);
        if (actual != pattern) log_err(&errors, &buf[i], pattern, actual);
        wr(&buf[i], ~pattern);
        pattern = (pattern << 1) | (pattern >> (TW_WIDTH - 1));
    }
    cache_flush();

    /* Reverse pass — re-derive pattern at the end. */
    pattern = 1;
    for (int i = 0; i < MEMTEST_WORDS; i++)
        pattern = (pattern << 1) | (pattern >> (TW_WIDTH - 1));
    /* pattern is now where the forward loop ended; back it off one step. */
    pattern = (pattern >> 1) | (pattern << (TW_WIDTH - 1));

    for (int i = MEMTEST_WORDS - 1; i >= 0; i--) {
        testword_t expect = ~pattern;
        testword_t actual = rd(&buf[i]);
        if (actual != expect) log_err(&errors, &buf[i], expect, actual);
        pattern = (pattern >> 1) | (pattern << (TW_WIDTH - 1));
    }
    return report("mov-inv-walk1", errors, 1);
}

/* ---------------------------------------------------------------------------
 * Test 6: Modulo-N pattern
 *
 * Every Nth word holds `pattern`; all others hold `~pattern`.  Verifies that
 * adjacent cells don't disturb each other.  N=20 follows memtest86+ default.
 * ------------------------------------------------------------------------- */
#define MODULO_N 20
static int test_modulo_n(testword_t pattern) {
    unsigned long errors = 0;
    testword_t inv = ~pattern;

    for (int offset = 0; offset < MODULO_N; offset++) {
        /* 1) write `pattern` at every offset+k*N */
        for (int i = offset; i < MEMTEST_WORDS; i += MODULO_N)
            wr(&buf[i], pattern);
        cache_flush();
        /* 2) write `inv` to every other word (skip the modulo positions) */
        for (int i = 0; i < MEMTEST_WORDS; i++) {
            if ((i % MODULO_N) != offset) wr(&buf[i], inv);
        }
        cache_flush();
        /* 3) verify the modulo positions still hold `pattern` */
        for (int i = offset; i < MEMTEST_WORDS; i += MODULO_N) {
            testword_t actual = rd(&buf[i]);
            if (actual != pattern) log_err(&errors, &buf[i], pattern, actual);
        }
    }
    return report("modulo-20", errors, pattern);
}

/* ---------------------------------------------------------------------------
 * Test 7: Block-move stress
 *
 * Memtest86+ pattern: lay down a bit-shift pattern in 16-word blocks, then
 * memcpy halves of the buffer around.  Stresses sequential burst behaviour.
 * ------------------------------------------------------------------------- */
static int test_block_move(int iterations) {
    unsigned long errors = 0;
    const int blk = 16;
    if (MEMTEST_WORDS < blk * 4) return 0;  /* skip if too small */

    /* Initialise: 16-word "1100 1100 1100 1100" pattern, rotating each block. */
    testword_t pat = 1;
    for (int i = 0; i + blk <= MEMTEST_WORDS; i += blk) {
        testword_t p1 = pat, p2 = ~pat;
        wr(&buf[i +  0], p1); wr(&buf[i +  1], p1);
        wr(&buf[i +  2], p1); wr(&buf[i +  3], p1);
        wr(&buf[i +  4], p2); wr(&buf[i +  5], p2);
        wr(&buf[i +  6], p1); wr(&buf[i +  7], p1);
        wr(&buf[i +  8], p1); wr(&buf[i +  9], p1);
        wr(&buf[i + 10], p2); wr(&buf[i + 11], p2);
        wr(&buf[i + 12], p1); wr(&buf[i + 13], p1);
        wr(&buf[i + 14], p2); wr(&buf[i + 15], p2);
        pat = (pat << 1) | (pat >> (TW_WIDTH - 1));
    }
    cache_flush();

    /* Snapshot expected values for verification.  Use static storage
     * because pk's heap is tiny and we know the size at compile time. */
    static testword_t expect[MEMTEST_WORDS];
    static testword_t scratch[MEMTEST_WORDS];
    for (int i = 0; i < MEMTEST_WORDS; i++) expect[i] = rd(&buf[i]);

    /* Move data: copy first half to second half, then rotate forward by
     * one block.  We perform the rotation through a scratch array so the
     * underlying memcpy never sees overlapping src/dst (avoids -Wrestrict
     * and matches strict memcpy semantics). */
    int half = MEMTEST_WORDS / 2;

    for (int it = 0; it < iterations; it++) {
        memcpy((void *)&buf[half], (const void *)&buf[0], half * sizeof(testword_t));
        memcpy(&expect[half], &expect[0], half * sizeof(testword_t));

        /* Rotate forward by `blk` words via scratch. */
        memcpy(scratch, (const void *)&buf[0], (MEMTEST_WORDS - blk) * sizeof(testword_t));
        memcpy((void *)&buf[blk], scratch, (MEMTEST_WORDS - blk) * sizeof(testword_t));
        memcpy(scratch, &expect[0], (MEMTEST_WORDS - blk) * sizeof(testword_t));
        memcpy(&expect[blk], scratch, (MEMTEST_WORDS - blk) * sizeof(testword_t));
        cache_flush();

        for (int i = 0; i < MEMTEST_WORDS; i++) {
            testword_t actual = rd(&buf[i]);
            if (actual != expect[i]) log_err(&errors, &buf[i], expect[i], actual);
        }
    }
    return report("block-move", errors, 0);
}

/* ---------------------------------------------------------------------------
 * Test 8: Pseudo-random (LFSR) pattern
 *
 * Fill with reproducible LFSR stream, then verify by rerunning the LFSR.
 * Catches pattern-sensitive faults missed by simple geometric patterns.
 * ------------------------------------------------------------------------- */
static testword_t lfsr_step(testword_t v) {
#if __riscv_xlen == 64
    /* x^64 + x^63 + x^61 + x^60 + 1 */
    testword_t bit = ((v >> 63) ^ (v >> 62) ^ (v >> 60) ^ (v >> 59)) & 1;
    return (v << 1) | bit;
#else
    /* x^32 + x^22 + x^2 + x + 1 */
    testword_t bit = ((v >> 31) ^ (v >> 21) ^ (v >> 1) ^ v) & 1;
    return (v << 1) | bit;
#endif
}

static int test_random_lfsr(testword_t seed) {
    unsigned long errors = 0;
    if (seed == 0) seed = 0xACE1ACE1U;

    testword_t v = seed;
    for (int i = 0; i < MEMTEST_WORDS; i++) { wr(&buf[i], v); v = lfsr_step(v); }
    cache_flush();
    v = seed;
    for (int i = 0; i < MEMTEST_WORDS; i++) {
        testword_t actual = rd(&buf[i]);
        if (actual != v) log_err(&errors, &buf[i], v, actual);
        v = lfsr_step(v);
    }
    return report("random-lfsr", errors, seed);
}

/* ---------------------------------------------------------------------------
 * Test 9: Bit-fade (short)
 *
 * Write, do unrelated work, re-read.  Real memtest86+ sleeps minutes; we
 * only burn some cycles to provoke cache-eviction races.
 * ------------------------------------------------------------------------- */
static int test_bit_fade(void) {
    unsigned long errors = 0;
    for (int i = 0; i < MEMTEST_WORDS; i++) wr(&buf[i], (testword_t)i ^ PAT_55);
    cache_flush();

    /* Burn cycles touching unrelated memory to try to evict cache lines. */
    volatile uint32_t scratch[1024];
    for (int rep = 0; rep < 8; rep++) {
        for (int i = 0; i < 1024; i++) scratch[i] = scratch[i] + (uint32_t)i;
    }
    cache_flush();

    for (int i = 0; i < MEMTEST_WORDS; i++) {
        testword_t expect = (testword_t)i ^ PAT_55;
        testword_t actual = rd(&buf[i]);
        if (actual != expect) log_err(&errors, &buf[i], expect, actual);
    }
    return report("bit-fade", errors, PAT_55);
}

/* ---------------------------------------------------------------------------
 * Driver
 * ------------------------------------------------------------------------- */
int main(void) {
    printf("memtest: XLEN=%d, buffer=%d words (%lu KiB) @ %p\n",
           TW_WIDTH, MEMTEST_WORDS,
           (unsigned long)(MEMTEST_WORDS * sizeof(testword_t) / 1024),
           (void *)&buf[0]);

    test_addr_walk1();
    test_own_addr(0);
    test_own_addr((testword_t)~(testword_t)0);
    test_mov_inv_fixed(0, 2);
    test_mov_inv_fixed((testword_t)~(testword_t)0, 2);
    test_mov_inv_fixed(PAT_55, 2);
    test_mov_inv_fixed(PAT_AA, 2);
    test_mov_inv_walk1();
    test_modulo_n(0);
    test_modulo_n((testword_t)~(testword_t)0);
    test_modulo_n(PAT_55);
    test_block_move(2);
    test_random_lfsr(0xACE1ACE1U);
    test_bit_fade();

    printf("memtest: %d passed, %d failed\n", total_passes, total_fails);
    return total_fails ? EXIT_FAILURE : EXIT_SUCCESS;
}
