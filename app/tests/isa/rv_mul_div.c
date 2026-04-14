/* rv_mul_div.c: Test MUL/MULH/MULHU/MULHSU/DIV/DIVU/REM/REMU (M extension) */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); fail++; } \
    else { pass++; } \
} while (0)

int main(void) {
    int pass = 0, fail = 0;

    /* mul: low bits */
    {
        long a = 7, b = 6, c;
        asm volatile("mul %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 42, "7 * 6 = 42");
    }

    /* mul: negative */
    {
        long a = -3, b = 5, c;
        asm volatile("mul %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == -15, "-3 * 5 = -15");
    }

    /* mul: zero */
    {
        long a = 999, c;
        asm volatile("mul %0, %1, zero" : "=r"(c) : "r"(a));
        CHECK(c == 0, "x * 0 = 0");
    }

    /* mulh: signed high bits */
    {
#if __riscv_xlen == 32
        long a = 0x40000000, b = 4, c; /* 2^30 * 4 = 2^32 -> high word = 1 */
        asm volatile("mulh %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 1, "mulh: 0x40000000 * 4 high = 1");
#else
        long a = 0x4000000000000000L, b = 4, c;
        asm volatile("mulh %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 1, "mulh: 0x4000...0 * 4 high = 1");
#endif
    }

    /* mulhu: unsigned high bits */
    {
#if __riscv_xlen == 32
        unsigned long a = 0x80000000U, b = 2, c;
        asm volatile("mulhu %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 1, "mulhu: 0x80000000 * 2 high = 1");
#else
        unsigned long a = 0x8000000000000000UL, b = 2, c;
        asm volatile("mulhu %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 1, "mulhu: 0x8000...0 * 2 high = 1");
#endif
    }

    /* div */
    {
        long a = 42, b = 7, c;
        asm volatile("div %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 6, "42 / 7 = 6");
    }

    /* div: negative */
    {
        long a = -20, b = 6, c;
        asm volatile("div %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == -3, "-20 / 6 = -3 (truncated toward zero)");
    }

    /* div by zero: result = -1 per RISC-V spec */
    {
        long a = 42, c;
        asm volatile("div %0, %1, zero" : "=r"(c) : "r"(a));
        CHECK(c == -1, "div by zero returns -1");
    }

    /* divu by zero: result = all-ones per RISC-V spec */
    {
        unsigned long a = 42, c;
        asm volatile("divu %0, %1, zero" : "=r"(c) : "r"(a));
        CHECK(c == (unsigned long)-1, "divu by zero returns ULONG_MAX");
    }

    /* div overflow: LONG_MIN / -1 = LONG_MIN */
    {
#if __riscv_xlen == 32
        long a = (long)0x80000000, b = -1, c;
#else
        long a = (long)0x8000000000000000L, b = -1, c;
#endif
        asm volatile("div %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == a, "div overflow: LONG_MIN / -1 = LONG_MIN");
    }

    /* rem */
    {
        long a = 20, b = 6, c;
        asm volatile("rem %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 2, "20 %% 6 = 2");
    }

    /* remu */
    {
        unsigned long a = 20, b = 6, c;
        asm volatile("remu %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 2, "20u %% 6u = 2");
    }

    /* rem by zero = dividend */
    {
        long a = 42, c;
        asm volatile("rem %0, %1, zero" : "=r"(c) : "r"(a));
        CHECK(c == 42, "rem by zero returns dividend");
    }

#if __riscv_xlen == 64
    /* mulw / divw / remw */
    {
        long a = 0x7FFFFFFF, b = 2, c;
        asm volatile("mulw %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == (long)(int32_t)(0x7FFFFFFFU * 2U), "mulw sign extends 32-bit result");
    }
    {
        long a = 100, b = 7, c;
        asm volatile("divw %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 14, "divw: 100 / 7 = 14");
    }
    {
        long a = 100, b = 7, c;
        asm volatile("remw %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 2, "remw: 100 %% 7 = 2");
    }
#endif

    printf("rv_mul_div: %d passed, %d failed\n", pass, fail);
    return fail ? EXIT_FAILURE : EXIT_SUCCESS;
}
