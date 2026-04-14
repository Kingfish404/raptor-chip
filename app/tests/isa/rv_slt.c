/* rv_slt.c: Test SLT/SLTU/SLTI/SLTIU instructions */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); fail++; } \
    else { pass++; } \
} while (0)

int main(void) {
    int pass = 0, fail = 0;

    /* slt: signed less than */
    {
        long a = -1, b = 0, c;
        asm volatile("slt %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 1, "slt: -1 < 0");
    }
    {
        long a = 0, b = -1, c;
        asm volatile("slt %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 0, "slt: 0 not < -1");
    }
    {
        long a = 5, b = 5, c;
        asm volatile("slt %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 0, "slt: 5 not < 5");
    }

    /* sltu: unsigned less than */
    {
        unsigned long a = 0, b = 1, c;
        asm volatile("sltu %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 1, "sltu: 0 < 1");
    }
    {
        /* -1 as unsigned is MAX, should not be < 0 */
        unsigned long a = (unsigned long)-1, b = 0, c;
        asm volatile("sltu %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 0, "sltu: MAX not < 0");
    }

    /* slti */
    {
        long a = 10, c;
        asm volatile("slti %0, %1, 11" : "=r"(c) : "r"(a));
        CHECK(c == 1, "slti: 10 < 11");
    }
    {
        long a = 10, c;
        asm volatile("slti %0, %1, 10" : "=r"(c) : "r"(a));
        CHECK(c == 0, "slti: 10 not < 10");
    }
    {
        long a = 10, c;
        asm volatile("slti %0, %1, -1" : "=r"(c) : "r"(a));
        CHECK(c == 0, "slti: 10 not < -1");
    }

    /* sltiu */
    {
        unsigned long a = 10, c;
        asm volatile("sltiu %0, %1, 11" : "=r"(c) : "r"(a));
        CHECK(c == 1, "sltiu: 10 < 11");
    }
    /* sltiu with -1 (sign extended -> large unsigned): rd = 1 iff rs1 < ~0 */
    {
        unsigned long a = 0, c;
        asm volatile("sltiu %0, %1, -1" : "=r"(c) : "r"(a));
        CHECK(c == 1, "sltiu: 0 < MAX (imm -1 sign-extends)");
    }

    /* snez pseudo (sltiu rd, rs, 1) */
    {
        long a = 5, c;
        asm volatile("snez %0, %1" : "=r"(c) : "r"(a));
        CHECK(c == 1, "snez: 5 != 0");
    }
    {
        long a = 0, c;
        asm volatile("snez %0, %1" : "=r"(c) : "r"(a));
        CHECK(c == 0, "snez: 0 == 0");
    }

    /* seqz pseudo (sltiu rd, rs, 1) */
    {
        long a = 0, c;
        asm volatile("seqz %0, %1" : "=r"(c) : "r"(a));
        CHECK(c == 1, "seqz: 0 == 0");
    }
    {
        long a = 42, c;
        asm volatile("seqz %0, %1" : "=r"(c) : "r"(a));
        CHECK(c == 0, "seqz: 42 != 0");
    }

    printf("rv_slt: %d passed, %d failed\n", pass, fail);
    return fail ? EXIT_FAILURE : EXIT_SUCCESS;
}
