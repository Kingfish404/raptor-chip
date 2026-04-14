/* rv_bitmanip.c: Test Zba (sh*add), Zbb (clz/ctz/cpop/min/max/rev8/...), Zbs (bset/bclr/binv/bext) */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); fail++; } \
    else { pass++; } \
} while (0)

int main(void) {
    int pass = 0, fail = 0;

    /* ---- Zba: Address generation ---- */

    /* sh1add: rd = rs2 + (rs1 << 1) */
    {
        long a = 10, b = 100, c;
        asm volatile("sh1add %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 120, "sh1add: 100 + 10*2 = 120");
    }

    /* sh2add: rd = rs2 + (rs1 << 2) */
    {
        long a = 5, b = 1000, c;
        asm volatile("sh2add %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 1020, "sh2add: 1000 + 5*4 = 1020");
    }

    /* sh3add: rd = rs2 + (rs1 << 3) */
    {
        long a = 3, b = 0, c;
        asm volatile("sh3add %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 24, "sh3add: 0 + 3*8 = 24");
    }

    /* ---- Zbb: Basic bit manipulation ---- */

    /* clz: count leading zeros */
    {
        long a = 1, c;
        asm volatile("clz %0, %1" : "=r"(c) : "r"(a));
#if __riscv_xlen == 32
        CHECK(c == 31, "clz(1) = 31 (RV32)");
#else
        CHECK(c == 63, "clz(1) = 63 (RV64)");
#endif
    }
    {
        long a = 0, c;
        asm volatile("clz %0, %1" : "=r"(c) : "r"(a));
        CHECK(c == __riscv_xlen, "clz(0) = XLEN");
    }

    /* ctz: count trailing zeros */
    {
        long a = 8, c; /* 0b1000 */
        asm volatile("ctz %0, %1" : "=r"(c) : "r"(a));
        CHECK(c == 3, "ctz(8) = 3");
    }
    {
        long a = 0, c;
        asm volatile("ctz %0, %1" : "=r"(c) : "r"(a));
        CHECK(c == __riscv_xlen, "ctz(0) = XLEN");
    }

    /* cpop: population count */
    {
        long a = 0xFF, c;
        asm volatile("cpop %0, %1" : "=r"(c) : "r"(a));
        CHECK(c == 8, "cpop(0xFF) = 8");
    }
    {
        long a = 0, c;
        asm volatile("cpop %0, %1" : "=r"(c) : "r"(a));
        CHECK(c == 0, "cpop(0) = 0");
    }

    /* min/max (signed) */
    {
        long a = -5, b = 3, c;
        asm volatile("min %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == -5, "min(-5, 3) = -5");
    }
    {
        long a = -5, b = 3, c;
        asm volatile("max %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 3, "max(-5, 3) = 3");
    }

    /* minu/maxu (unsigned) */
    {
        unsigned long a = 0, b = (unsigned long)-1, c;
        asm volatile("minu %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 0, "minu(0, MAX) = 0");
    }
    {
        unsigned long a = 0, b = (unsigned long)-1, c;
        asm volatile("maxu %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == b, "maxu(0, MAX) = MAX");
    }

    /* sext.b / sext.h */
    {
        long a = 0x80, c; /* sign bit of byte */
        asm volatile("sext.b %0, %1" : "=r"(c) : "r"(a));
        CHECK(c == -128, "sext.b(0x80) = -128");
    }
    {
        long a = 0x8000, c; /* sign bit of halfword */
        asm volatile("sext.h %0, %1" : "=r"(c) : "r"(a));
        CHECK(c == -32768, "sext.h(0x8000) = -32768");
    }

    /* andn / orn / xnor */
    {
        long a = 0xFF, b = 0x0F, c;
        asm volatile("andn %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK((c & 0xFF) == 0xF0, "andn: 0xFF & ~0x0F = 0xF0");
    }
    {
        long a = 0xF0, b = 0x0F, c;
        asm volatile("orn %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == (a | ~b), "orn: 0xF0 | ~0x0F");
    }
    {
        long a = 0xFF, b = 0xFF, c;
        asm volatile("xnor %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == ~(long)0, "xnor: 0xFF ^ ~0xFF = all ones");
    }

    /* rev8: byte reverse */
    {
#if __riscv_xlen == 32
        long a = 0x01020304, c;
        asm volatile("rev8 %0, %1" : "=r"(c) : "r"(a));
        CHECK(c == (long)0x04030201, "rev8(0x01020304) = 0x04030201");
#else
        long a = 0x0102030405060708L, c;
        asm volatile("rev8 %0, %1" : "=r"(c) : "r"(a));
        CHECK(c == 0x0807060504030201L, "rev8(0x0102030405060708)");
#endif
    }

    /* ---- Zbs: Single-bit operations ---- */

    /* bset: set bit */
    {
        long a = 0, b = 5, c;
        asm volatile("bset %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 32, "bset: bit 5 of 0 -> 32");
    }

    /* bclr: clear bit */
    {
        long a = 0xFF, b = 3, c;
        asm volatile("bclr %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK((c & 0xFF) == 0xF7, "bclr: clear bit 3 of 0xFF = 0xF7");
    }

    /* binv: invert bit */
    {
        long a = 0, b = 7, c;
        asm volatile("binv %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 128, "binv: flip bit 7 of 0 -> 128");
    }

    /* bext: extract bit */
    {
        long a = 0xFF, b = 4, c;
        asm volatile("bext %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 1, "bext: bit 4 of 0xFF = 1");
    }
    {
        long a = 0xF0, b = 2, c;
        asm volatile("bext %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 0, "bext: bit 2 of 0xF0 = 0");
    }

    /* bseti / bclri / binvi / bexti (immediate forms) */
    {
        long a = 0, c;
        asm volatile("bseti %0, %1, 10" : "=r"(c) : "r"(a));
        CHECK(c == (1L << 10), "bseti: set bit 10");
    }
    {
        long a = 0xFFFF, c;
        asm volatile("bexti %0, %1, 15" : "=r"(c) : "r"(a));
        CHECK(c == 1, "bexti: bit 15 of 0xFFFF = 1");
    }

    printf("rv_bitmanip: %d passed, %d failed\n", pass, fail);
    return fail ? EXIT_FAILURE : EXIT_SUCCESS;
}
