/* rv_zicsr.c: Test Zicsr (CSR read/write) + Zicntr (cycle/time/instret counters)
 *
 * Running under riscv-pk in U-mode: only the unprivileged counter CSRs
 * (cycle=0xC00, time=0xC01, instret=0xC02, and their *h counterparts on RV32)
 * are readable via csrr/rdcycle/rdinstret/rdtime pseudo-instructions.
 * Writes to unprivileged CSRs are not attempted (would trap illegal-inst).
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#define CHECK(cond, msg)                                   \
    do                                                     \
    {                                                      \
        if (!(cond))                                       \
        {                                                  \
            printf("FAIL: %s (line %d)\n", msg, __LINE__); \
            fail++;                                        \
        }                                                  \
        else                                               \
        {                                                  \
            pass++;                                        \
        }                                                  \
    } while (0)

/* Read a 64-bit counter CSR safely on both RV32 and RV64.
 * On RV32 uses the double-read loop from the RISC-V Unprivileged spec
 * to avoid the low-half carry race. */
static inline uint64_t read_ctr64(unsigned csr_lo, unsigned csr_hi)
{
#if __riscv_xlen == 64
    unsigned long v;
    /* Select the CSR explicitly so this does not depend on the rdcycle,
     * rdtime, or rdinstret pseudo-instructions. */
    switch (csr_lo)
    {
    case 0xC00:
        asm volatile("csrr %0, cycle" : "=r"(v));
        break;
    case 0xC01:
        asm volatile("csrr %0, time" : "=r"(v));
        break;
    case 0xC02:
        asm volatile("csrr %0, instret" : "=r"(v));
        break;
    default:
        v = 0;
        break;
    }
    (void)csr_hi;
    return (uint64_t)v;
#else
    uint32_t lo, hi, hi2;
    do
    {
        switch (csr_hi)
        {
        case 0xC80:
            asm volatile("csrr %0, cycleh" : "=r"(hi));
            break;
        case 0xC81:
            asm volatile("csrr %0, timeh" : "=r"(hi));
            break;
        case 0xC82:
            asm volatile("csrr %0, instreth" : "=r"(hi));
            break;
        default:
            hi = 0;
            break;
        }
        switch (csr_lo)
        {
        case 0xC00:
            asm volatile("csrr %0, cycle" : "=r"(lo));
            break;
        case 0xC01:
            asm volatile("csrr %0, time" : "=r"(lo));
            break;
        case 0xC02:
            asm volatile("csrr %0, instret" : "=r"(lo));
            break;
        default:
            lo = 0;
            break;
        }
        switch (csr_hi)
        {
        case 0xC80:
            asm volatile("csrr %0, cycleh" : "=r"(hi2));
            break;
        case 0xC81:
            asm volatile("csrr %0, timeh" : "=r"(hi2));
            break;
        case 0xC82:
            asm volatile("csrr %0, instreth" : "=r"(hi2));
            break;
        default:
            hi2 = 0;
            break;
        }
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
#endif
}

/* Force a handful of retired instructions between counter samples. */
__attribute__((noinline)) static unsigned long spin_work(unsigned long seed)
{
    unsigned long x = seed;
    for (int i = 0; i < 64; i++)
    {
        x = x * 1103515245UL + 12345UL;
        x ^= (x >> 5);
    }
    return x;
}

int main(void)
{
    int pass = 0, fail = 0;
    volatile unsigned long sink = 0;

    /* ---- rdcycle: monotonically non-decreasing ---- */
    {
        uint64_t c1 = read_ctr64(0xC00, 0xC80);
        sink += spin_work(0x1234);
        uint64_t c2 = read_ctr64(0xC00, 0xC80);
        CHECK(c2 >= c1, "rdcycle: c2 >= c1");
        CHECK(c2 != c1, "rdcycle: advanced across work");
    }

    /* ---- rdinstret: monotonically non-decreasing, advances ---- */
    {
        uint64_t i1 = read_ctr64(0xC02, 0xC82);
        sink += spin_work(0x5678);
        uint64_t i2 = read_ctr64(0xC02, 0xC82);
        CHECK(i2 >= i1, "rdinstret: i2 >= i1");
        CHECK(i2 - i1 >= 10, "rdinstret: retired >= 10 insns across spin_work");
    }

    /* ---- rdtime: readable, monotonically non-decreasing ----
     * Some platforms alias time to cycle or to mtime; either is acceptable
     * as long as it is readable and non-decreasing. */
    {
        uint64_t t1 = read_ctr64(0xC01, 0xC81);
        sink += spin_work(0xabcd);
        uint64_t t2 = read_ctr64(0xC01, 0xC81);
        CHECK(t2 >= t1, "rdtime: t2 >= t1");
    }

    /* ---- cycle-vs-instret ordering: cycles >= retired insns (IPC <= 1
     * for this workload's window; looser bound here to tolerate OoO effects
     * between counter sample points). ---- */
    {
        uint64_t c1 = read_ctr64(0xC00, 0xC80);
        uint64_t i1 = read_ctr64(0xC02, 0xC82);
        sink += spin_work(0xdead);
        uint64_t c2 = read_ctr64(0xC00, 0xC80);
        uint64_t i2 = read_ctr64(0xC02, 0xC82);
        uint64_t dc = c2 - c1, di = i2 - i1;
        /* IPC cap: dc * IPC_MAX >= di. We cap IPC at 4 to allow dual-issue
         * OoO cores plus noise tolerance. */
        CHECK(dc * 4 >= di, "cycles*4 >= retired instructions");
    }

    /* ---- Zicsr read with explicit csrrs rd, csr, x0 pattern ----
     * csrrs x5, cycle, x0 reads cycle without writing (since rs1=x0). */
    {
        unsigned long v1, v2;
        asm volatile("csrrs %0, cycle, x0" : "=r"(v1));
        asm volatile("csrrs %0, cycle, x0" : "=r"(v2));
        CHECK(v2 >= v1, "csrrs cycle, x0 non-decreasing");
    }

    /* ---- csrrc rd, csr, x0 is also a pure read (rs1=x0) ---- */
    {
        unsigned long v1, v2;
        asm volatile("csrrc %0, instret, x0" : "=r"(v1));
        asm volatile("csrrc %0, instret, x0" : "=r"(v2));
        CHECK(v2 >= v1, "csrrc instret, x0 non-decreasing");
    }

    (void)sink;
    printf("rv_zicsr: %d passed, %d failed\n", pass, fail);
    return fail ? EXIT_FAILURE : EXIT_SUCCESS;
}
