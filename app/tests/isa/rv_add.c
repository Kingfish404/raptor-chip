/* rv_add.c: Test ADD/ADDI/SUB instructions */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); fail++; } \
    else { pass++; } \
} while (0)

int main(void) {
    int pass = 0, fail = 0;

    /* basic add */
    {
        long a = 1, b = 2, c;
        asm volatile("add %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 3, "1 + 2 = 3");
    }

    /* add negative */
    {
        long a = 100, b = -50, c;
        asm volatile("add %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 50, "100 + (-50) = 50");
    }

    /* addi */
    {
        long a = 10, c;
        asm volatile("addi %0, %1, 42" : "=r"(c) : "r"(a));
        CHECK(c == 52, "10 + 42 = 52");
    }

    /* addi negative immediate */
    {
        long a = 100, c;
        asm volatile("addi %0, %1, -1" : "=r"(c) : "r"(a));
        CHECK(c == 99, "100 + (-1) = 99");
    }

    /* sub */
    {
        long a = 10, b = 3, c;
        asm volatile("sub %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 7, "10 - 3 = 7");
    }

    /* overflow (unsigned wrap) */
    {
        unsigned long a = 0, b = 1, c;
        asm volatile("sub %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == (unsigned long)-1, "0 - 1 = ULONG_MAX");
    }

    /* add zero */
    {
        long a = 0x12345678, c;
        asm volatile("add %0, %1, zero" : "=r"(c) : "r"(a));
        CHECK(c == 0x12345678, "x + 0 = x");
    }

#if __riscv_xlen == 32
    /* addw is RV64 only, test 32-bit wraparound instead */
    {
        uint32_t a = 0xFFFFFFFF, b = 1;
        uint32_t c = a + b;
        CHECK(c == 0, "0xFFFFFFFF + 1 wraps to 0 (32-bit)");
    }
#else
    /* RV64: addw / subw */
    {
        long a = 0x7FFFFFFF, b = 1, c;
        asm volatile("addw %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == (long)(int32_t)0x80000000, "addw 0x7FFFFFFF+1 sign-extends");
    }
    {
        long a = 0, b = 1, c;
        asm volatile("subw %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == -1, "subw 0 - 1 = -1 (sign-extended)");
    }
#endif

    printf("rv_add: %d passed, %d failed\n", pass, fail);
    return fail ? EXIT_FAILURE : EXIT_SUCCESS;
}
