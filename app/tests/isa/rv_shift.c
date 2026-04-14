/* rv_shift.c: Test SLL/SRL/SRA/SLLI/SRLI/SRAI instructions */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); fail++; } \
    else { pass++; } \
} while (0)

int main(void) {
    int pass = 0, fail = 0;

    /* sll */
    {
        long a = 1, b = 10, c;
        asm volatile("sll %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 1024, "1 << 10 = 1024");
    }

    /* slli */
    {
        long a = 0xFF, c;
        asm volatile("slli %0, %1, 4" : "=r"(c) : "r"(a));
        CHECK(c == 0xFF0, "0xFF << 4 = 0xFF0");
    }

    /* srl (logical) */
    {
        unsigned long a = 0x80000000UL, b = 4, c;
        asm volatile("srl %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == (a >> 4), "srl: logical right shift inserts zeros");
    }

    /* srli */
    {
        unsigned long a = 0xF0, c;
        asm volatile("srli %0, %1, 4" : "=r"(c) : "r"(a));
        CHECK(c == 0xF, "0xF0 >> 4 = 0xF");
    }

    /* sra (arithmetic) */
    {
        long a = -128, b = 3, c;
        asm volatile("sra %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == (-128 >> 3), "sra: -128 >> 3 preserves sign");
    }

    /* srai */
    {
        long a = -1, c;
        asm volatile("srai %0, %1, 5" : "=r"(c) : "r"(a));
        CHECK(c == -1, "srai: -1 >> 5 = -1");
    }

    /* shift by zero */
    {
        long a = 0xABCD, c;
        asm volatile("sll %0, %1, zero" : "=r"(c) : "r"(a));
        CHECK(c == 0xABCD, "x << 0 = x");
    }

    /* shift amount masking (low bits only) */
    {
        long a = 1;
#if __riscv_xlen == 32
        /* RV32: shift uses low 5 bits; 32 & 0x1F = 0 */
        long b = 32, c;
        asm volatile("sll %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 1, "sll shift amount masked to 5 bits (RV32)");
#else
        /* RV64: shift uses low 6 bits; 64 & 0x3F = 0 */
        long b = 64, c;
        asm volatile("sll %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 1, "sll shift amount masked to 6 bits (RV64)");
#endif
    }

#if __riscv_xlen == 64
    /* RV64: sllw, srlw, sraw */
    {
        long a = 1, b = 31, c;
        asm volatile("sllw %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == (long)(int32_t)0x80000000, "sllw: 1<<31 sign-extends to negative");
    }
    {
        long a = (long)0xFFFFFFFF80000000LL, b = 31, c;
        asm volatile("sraw %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == -1, "sraw: sign-extend 0x80000000 >> 31 = -1");
    }
#endif

    printf("rv_shift: %d passed, %d failed\n", pass, fail);
    return fail ? EXIT_FAILURE : EXIT_SUCCESS;
}
