/* rv_zimop.c: Test Zimop (May-Be-Operations) — MOP.R.n / MOP.RR.n
 *
 * Zimop reserves 40 instruction encodings (32 MOP.R.n + 8 MOP.RR.n) in the
 * SYSTEM opcode space for future extensions. An implementation that does
 * not implement any concrete MOP extension MUST architecturally write 0 to
 * rd (the RISC-V spec mandates this "no-op-with-zero-writeback" behavior
 * so that code probing for MOPs can detect absence).
 *
 * GCC 13 (Ubuntu's riscv64-unknown-elf-gcc) does NOT support the `mop.r.n`
 * / `mop.rr.n` mnemonics (they were added in GCC 14 + binutils 2.42).
 * Therefore this file uses raw `.4byte` encodings.
 *
 * Encoding (RISC-V Unprivileged ISA spec, Zimop chapter):
 *   MOP.R.n  : bits = 1  n4 0 0 n3 n2 0 1 1 1 n1 n0 | rs1 | 100 | rd | 1110011
 *   MOP.RR.n : bits = 1  n2 0 0 n1 n0 1             | rs2 | rs1 | 100 | rd | 1110011
 *
 * Helper macros below construct encodings for rd=a0 (x10), rs1/rs2=x0.
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

/* Build MOP.R.n encoding with rd=a0 (x10), rs1=x0.
 *   bit31=1, bit30=n[4], bit29=0, bit28=0, bit27=n[3], bit26=n[2], bit25=0,
 *   bits24:22=111, bit21=n[1], bit20=n[0], bits19:15=0 (rs1),
 *   bits14:12=100, bits11:7=01010 (a0), bits6:0=1110011.
 */
#define MOP_R_N(n) (                      \
    0x80000000u |                         \
    (((uint32_t)((n) >> 4) & 1u) << 30) | \
    (((uint32_t)((n) >> 3) & 1u) << 27) | \
    (((uint32_t)((n) >> 2) & 1u) << 26) | \
    (0x7u << 22) |                        \
    (((uint32_t)((n) >> 1) & 1u) << 21) | \
    (((uint32_t)((n) >> 0) & 1u) << 20) | \
    (0u << 15) |   /* rs1 = x0 */         \
    (0x4u << 12) | /* funct3 = 100 */     \
    (0x0Au << 7) | /* rd = x10 (a0) */    \
    0x73u)         /* opcode = SYSTEM */

/* Build MOP.RR.n encoding with rd=a0 (x10), rs1=x0, rs2=x0.
 *   bit31=1, bit30=n[2], bit29=0, bit28=0, bit27=n[1], bit26=n[0], bit25=1,
 *   bits24:20=0 (rs2), bits19:15=0 (rs1),
 *   bits14:12=100, bits11:7=01010 (a0), bits6:0=1110011.
 */
#define MOP_RR_N(n) (                     \
    0x80000000u |                         \
    (((uint32_t)((n) >> 2) & 1u) << 30) | \
    (((uint32_t)((n) >> 1) & 1u) << 27) | \
    (((uint32_t)((n) >> 0) & 1u) << 26) | \
    (1u << 25) |                          \
    (0u << 20) |   /* rs2 = x0 */         \
    (0u << 15) |   /* rs1 = x0 */         \
    (0x4u << 12) | /* funct3 = 100 */     \
    (0x0Au << 7) | /* rd = x10 (a0) */    \
    0x73u)

/* Emit a 32-bit instruction word as a raw .4byte. We pre-load a0 with
 * 0xDEADBEEF so that if the implementation failed to write rd, we would
 * observe the poison value and the test would fail. */
#define RUN_MOP(encoding, result_var) \
    do                                \
    {                                 \
        unsigned long _r;             \
        asm volatile(                 \
            "li a0, 0xDEADBEEF\n"     \
            ".4byte %1\n"             \
            "mv %0, a0\n"             \
            : "=r"(_r)                \
            : "i"(encoding)           \
            : "a0");                  \
        (result_var) = _r;            \
    } while (0)

/* Variant: seed rs1 with a nonzero value via x1 to ensure rd still becomes 0
 * regardless of source operands. Uses explicit rs1=x1 (ra) encoding. */
#define MOP_R_N_RS1RA(n) (                \
    0x80000000u |                         \
    (((uint32_t)((n) >> 4) & 1u) << 30) | \
    (((uint32_t)((n) >> 3) & 1u) << 27) | \
    (((uint32_t)((n) >> 2) & 1u) << 26) | \
    (0x7u << 22) |                        \
    (((uint32_t)((n) >> 1) & 1u) << 21) | \
    (((uint32_t)((n) >> 0) & 1u) << 20) | \
    (0x01u << 15) | /* rs1 = x1 (ra) */   \
    (0x4u << 12) |                        \
    (0x0Au << 7) |                        \
    0x73u)

int main(void)
{
    int pass = 0, fail = 0;

    /* ---- MOP.R.0 through MOP.R.31 — all must write 0 to rd ---- */
    {
        /* Unrolled so the .4byte constant is fixed per instance. */
        unsigned long v;
#define ONE(n)                                        \
    do                                                \
    {                                                 \
        RUN_MOP(MOP_R_N(n), v);                       \
        CHECK(v == 0, "MOP.R." #n " writes 0 to rd"); \
    } while (0)
        ONE(0);
        ONE(1);
        ONE(2);
        ONE(3);
        ONE(4);
        ONE(5);
        ONE(6);
        ONE(7);
        ONE(8);
        ONE(9);
        ONE(10);
        ONE(11);
        ONE(12);
        ONE(13);
        ONE(14);
        ONE(15);
        ONE(16);
        ONE(17);
        ONE(18);
        ONE(19);
        ONE(20);
        ONE(21);
        ONE(22);
        ONE(23);
        ONE(24);
        ONE(25);
        ONE(26);
        ONE(27);
        ONE(28);
        ONE(29);
        ONE(30);
        ONE(31);
#undef ONE
    }

    /* ---- MOP.RR.0 through MOP.RR.7 — all must write 0 to rd ---- */
    {
        unsigned long v;
#define ONE(n)                                         \
    do                                                 \
    {                                                  \
        RUN_MOP(MOP_RR_N(n), v);                       \
        CHECK(v == 0, "MOP.RR." #n " writes 0 to rd"); \
    } while (0)
        ONE(0);
        ONE(1);
        ONE(2);
        ONE(3);
        ONE(4);
        ONE(5);
        ONE(6);
        ONE(7);
#undef ONE
    }

    /* ---- MOP.R.n with nonzero rs1 must still write 0 to rd ---- */
    {
        unsigned long v;
        asm volatile(
            "li a0, 0xDEADBEEF\n"
            "li ra, 0x12345678\n"
            ".4byte %1\n"
            "mv %0, a0\n"
            : "=r"(v)
            : "i"(MOP_R_N_RS1RA(0))
            : "a0", "ra");
        CHECK(v == 0, "MOP.R.0 with rs1=ra(nonzero) still writes 0");
    }
    {
        unsigned long v;
        asm volatile(
            "li a0, 0xDEADBEEF\n"
            "li ra, 0x12345678\n"
            ".4byte %1\n"
            "mv %0, a0\n"
            : "=r"(v)
            : "i"(MOP_R_N_RS1RA(17))
            : "a0", "ra");
        CHECK(v == 0, "MOP.R.17 with rs1=ra(nonzero) still writes 0");
    }

    /* ---- MOP is not a trap: surrounding program state is preserved ---- */
    {
        volatile int counter = 0;
        unsigned long v;
        for (int i = 0; i < 10; i++)
        {
            counter++;
            RUN_MOP(MOP_R_N(0), v);
            CHECK(v == 0, "MOP.R.0 inside loop writes 0");
            counter++;
        }
        CHECK(counter == 20, "MOP.R.n does not disturb loop counter");
    }

    /* ---- Mixed with ordinary arithmetic: MOP does not clobber GPRs
     * other than its declared rd ---- */
    {
        unsigned long acc = 0;
        unsigned long v;
        for (unsigned long i = 1; i <= 5; i++)
        {
            acc += i;
            RUN_MOP(MOP_RR_N(3), v);
            CHECK(v == 0, "MOP.RR.3 writes 0");
        }
        CHECK(acc == 15, "sum 1..5 == 15 across MOP.RR sequence");
    }

    printf("rv_zimop: %d passed, %d failed\n", pass, fail);
    return fail ? EXIT_FAILURE : EXIT_SUCCESS;
}
