/* rv_zcb.c: Test Zcb (Code Size Reduction — byte/halfword) compressed ops
 *
 * Zcb adds 16-bit encodings for frequent operations:
 *   c.lbu, c.lhu, c.lh, c.sb, c.sh       (byte/halfword memory)
 *   c.zext.b, c.sext.b, c.zext.h, c.sext.h (extensions)
 *   c.not, c.mul                         (logical/mul)
 *   c.zext.w                             (RV64 only)
 *
 * All Zcb forms restrict rd/rs1/rs2 to x8..x15 (3-bit compressed encoding).
 * GCC 12+ supports these mnemonics when -march includes `_zcb`.
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

/* Buffer fixed into x8..x15-usable region via register allocator. Use
 * "r" constraint so GCC picks a GPR then we mv to an x8..x15 reg inside asm. */

int main(void)
{
    int pass = 0, fail = 0;

    /* Storage for memory tests, 4-byte aligned. */
    static uint8_t buf[8] __attribute__((aligned(4))) = {
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88};

    /* ---- c.lbu rd', uimm(rs1') ---- */
    {
        unsigned long v0, v1, v2, v3;
        /* Force rd/rs1 into x8..x15 via explicit register variables. */
        register uint8_t *p asm("a0") = buf; /* a0 = x10 */
        register unsigned long r asm("a1");  /* a1 = x11 */
        asm volatile("c.lbu %0, 0(%1)" : "=r"(r) : "r"(p));
        v0 = r;
        asm volatile("c.lbu %0, 1(%1)" : "=r"(r) : "r"(p));
        v1 = r;
        asm volatile("c.lbu %0, 2(%1)" : "=r"(r) : "r"(p));
        v2 = r;
        asm volatile("c.lbu %0, 3(%1)" : "=r"(r) : "r"(p));
        v3 = r;
        CHECK(v0 == 0x11 && v1 == 0x22 && v2 == 0x33 && v3 == 0x44,
              "c.lbu: read 4 bytes zero-extended");
    }

    /* ---- c.lhu rd', uimm(rs1') — uimm in {0, 2} ---- */
    {
        register uint8_t *p asm("a0") = buf;
        register unsigned long r asm("a1");
        unsigned long v0, v2;
        asm volatile("c.lhu %0, 0(%1)" : "=r"(r) : "r"(p));
        v0 = r;
        asm volatile("c.lhu %0, 2(%1)" : "=r"(r) : "r"(p));
        v2 = r;
        CHECK(v0 == 0x2211, "c.lhu: halfword @0 zero-extended");
        CHECK(v2 == 0x4433, "c.lhu: halfword @2 zero-extended");
    }

    /* ---- c.lh  rd', uimm(rs1') — sign-extended ---- */
    {
        static int8_t neg_buf[4] __attribute__((aligned(4))) = {0x00, (int8_t)0x80, 0x00, 0x00};
        register int8_t *p asm("a0") = neg_buf;
        register long r asm("a1");
        long v0;
        asm volatile("c.lh %0, 0(%1)" : "=r"(r) : "r"(p));
        v0 = r;
        /* Halfword = 0x8000 -> sign-extended negative. */
        CHECK(v0 == (long)(int16_t)0x8000, "c.lh: sign-extended halfword");
    }

    /* ---- c.sb rs2', uimm(rs1') — uimm in 0..3 ---- */
    {
        uint8_t tmp[4] __attribute__((aligned(4))) = {0};
        register uint8_t *p asm("a0") = tmp;
        register unsigned long v asm("a1") = 0xAB;
        asm volatile("c.sb %1, 0(%0)" : : "r"(p), "r"(v) : "memory");
        v = 0xCD;
        asm volatile("c.sb %1, 3(%0)" : : "r"(p), "r"(v) : "memory");
        CHECK(tmp[0] == 0xAB && tmp[3] == 0xCD && tmp[1] == 0 && tmp[2] == 0,
              "c.sb: store byte @0 and @3");
    }

    /* ---- c.sh rs2', uimm(rs1') — uimm in {0, 2} ---- */
    {
        uint8_t tmp[4] __attribute__((aligned(4))) = {0};
        register uint8_t *p asm("a0") = tmp;
        register unsigned long v asm("a1") = 0xBEEF;
        asm volatile("c.sh %1, 0(%0)" : : "r"(p), "r"(v) : "memory");
        CHECK(tmp[0] == 0xEF && tmp[1] == 0xBE, "c.sh: store halfword LE");
        v = 0xCAFE;
        asm volatile("c.sh %1, 2(%0)" : : "r"(p), "r"(v) : "memory");
        CHECK(tmp[2] == 0xFE && tmp[3] == 0xCA, "c.sh: store halfword @2");
    }

    /* ---- c.zext.b rd'  — zero-extend low byte ---- */
    {
        register unsigned long x asm("a0") = 0xFFFFFF80UL;
        asm volatile("c.zext.b %0" : "+r"(x));
        CHECK(x == 0x80, "c.zext.b(0xFFFFFF80) = 0x80");
    }

    /* ---- c.sext.b rd'  — sign-extend low byte ---- */
    {
        register long x asm("a0") = 0x0000007FL;
        asm volatile("c.sext.b %0" : "+r"(x));
        CHECK(x == 0x7F, "c.sext.b(0x7F) = 0x7F (positive)");
        x = 0x00000080L;
        asm volatile("c.sext.b %0" : "+r"(x));
        CHECK(x == (long)(int8_t)0x80, "c.sext.b(0x80) = -128");
    }

    /* ---- c.zext.h rd'  — zero-extend low halfword ---- */
    {
        register unsigned long x asm("a0") = (unsigned long)-1;
        asm volatile("c.zext.h %0" : "+r"(x));
        CHECK(x == 0xFFFF, "c.zext.h(-1) = 0xFFFF");
    }

    /* ---- c.sext.h rd'  — sign-extend low halfword ---- */
    {
        register long x asm("a0") = 0x00008000L;
        asm volatile("c.sext.h %0" : "+r"(x));
        CHECK(x == (long)(int16_t)0x8000, "c.sext.h(0x8000) = -32768");
    }

    /* ---- c.not rd'  — bitwise NOT ---- */
    {
        register unsigned long x asm("a0") = 0;
        asm volatile("c.not %0" : "+r"(x));
        CHECK(x == (unsigned long)-1, "c.not(0) = all ones");
        x = 0xA5A5A5A5UL;
        asm volatile("c.not %0" : "+r"(x));
        CHECK((uint32_t)x == 0x5A5A5A5AU, "c.not(0xA5A5A5A5) = 0x5A5A5A5A");
    }

    /* ---- c.mul rd', rs2'  — low XLEN bits of rd * rs2 ---- */
    {
        register unsigned long x asm("a0") = 6;
        register unsigned long y asm("a1") = 7;
        asm volatile("c.mul %0, %1" : "+r"(x) : "r"(y));
        CHECK(x == 42, "c.mul: 6 * 7 = 42");
    }
    {
        register unsigned long x asm("a0") = 0xFFFFFFFFUL;
        register unsigned long y asm("a1") = 2;
        asm volatile("c.mul %0, %1" : "+r"(x) : "r"(y));
#if __riscv_xlen == 32
        CHECK(x == 0xFFFFFFFEUL, "c.mul RV32: 0xFFFFFFFF*2 truncated");
#else
        CHECK(x == 0x1FFFFFFFEUL, "c.mul RV64: 0xFFFFFFFF*2 = 0x1FFFFFFFE");
#endif
    }

#if __riscv_xlen == 64
    /* ---- c.zext.w rd'  — RV64 only, zero-extend low 32 bits ---- */
    {
        register unsigned long x asm("a0") = 0xFFFFFFFF80000000UL;
        asm volatile("c.zext.w %0" : "+r"(x));
        CHECK(x == 0x80000000UL, "c.zext.w: zero-extend low 32 bits");
    }
#endif

    /* ---- Sanity: compiler-emitted Zcb from normal C ----
     * GCC at -O2 with -march=..._zcb typically emits c.zext.b/c.mul for the
     * below. We only check behavior; whether the compressed form is used
     * is a codegen quality concern (not a correctness concern). */
    {
        volatile unsigned int a = 0x12345;
        volatile unsigned char b = (unsigned char)a; /* zext.b candidate */
        CHECK(b == 0x45, "compiler zext.b path produces 0x45");
    }
    {
        volatile int a = 3, b = 11, c;
        c = a * b;
        CHECK(c == 33, "compiler c.mul path: 3*11=33");
    }

    printf("rv_zcb: %d passed, %d failed\n", pass, fail);
    return fail ? EXIT_FAILURE : EXIT_SUCCESS;
}
