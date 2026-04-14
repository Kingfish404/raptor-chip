/* rv_branch.c: Test BEQ/BNE/BLT/BGE/BLTU/BGEU and JAL/JALR */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); fail++; } \
    else { pass++; } \
} while (0)

static int pass = 0, fail = 0;

/* Use noinline to force real branch instructions */
__attribute__((noinline)) int test_beq(long a, long b) {
    int r;
    asm volatile(
        "beq %1, %2, 1f\n\t"
        "li %0, 0\n\t"
        "j 2f\n"
        "1: li %0, 1\n"
        "2:\n"
        : "=r"(r) : "r"(a), "r"(b)
    );
    return r;
}

__attribute__((noinline)) int test_bne(long a, long b) {
    int r;
    asm volatile(
        "bne %1, %2, 1f\n\t"
        "li %0, 0\n\t"
        "j 2f\n"
        "1: li %0, 1\n"
        "2:\n"
        : "=r"(r) : "r"(a), "r"(b)
    );
    return r;
}

__attribute__((noinline)) int test_blt(long a, long b) {
    int r;
    asm volatile(
        "blt %1, %2, 1f\n\t"
        "li %0, 0\n\t"
        "j 2f\n"
        "1: li %0, 1\n"
        "2:\n"
        : "=r"(r) : "r"(a), "r"(b)
    );
    return r;
}

__attribute__((noinline)) int test_bge(long a, long b) {
    int r;
    asm volatile(
        "bge %1, %2, 1f\n\t"
        "li %0, 0\n\t"
        "j 2f\n"
        "1: li %0, 1\n"
        "2:\n"
        : "=r"(r) : "r"(a), "r"(b)
    );
    return r;
}

__attribute__((noinline)) int test_bltu(unsigned long a, unsigned long b) {
    int r;
    asm volatile(
        "bltu %1, %2, 1f\n\t"
        "li %0, 0\n\t"
        "j 2f\n"
        "1: li %0, 1\n"
        "2:\n"
        : "=r"(r) : "r"(a), "r"(b)
    );
    return r;
}

__attribute__((noinline)) int test_bgeu(unsigned long a, unsigned long b) {
    int r;
    asm volatile(
        "bgeu %1, %2, 1f\n\t"
        "li %0, 0\n\t"
        "j 2f\n"
        "1: li %0, 1\n"
        "2:\n"
        : "=r"(r) : "r"(a), "r"(b)
    );
    return r;
}

int main(void) {
    /* BEQ */
    CHECK(test_beq(0, 0) == 1, "beq: 0 == 0 taken");
    CHECK(test_beq(1, 0) == 0, "beq: 1 != 0 not taken");
    CHECK(test_beq(-1, -1) == 1, "beq: -1 == -1 taken");

    /* BNE */
    CHECK(test_bne(1, 0) == 1, "bne: 1 != 0 taken");
    CHECK(test_bne(5, 5) == 0, "bne: 5 == 5 not taken");

    /* BLT (signed) */
    CHECK(test_blt(-1, 0) == 1, "blt: -1 < 0 taken");
    CHECK(test_blt(0, -1) == 0, "blt: 0 < -1 not taken");
    CHECK(test_blt(5, 5) == 0, "blt: 5 < 5 not taken");

    /* BGE (signed) */
    CHECK(test_bge(0, -1) == 1, "bge: 0 >= -1 taken");
    CHECK(test_bge(5, 5) == 1, "bge: 5 >= 5 taken");
    CHECK(test_bge(-2, -1) == 0, "bge: -2 >= -1 not taken");

    /* BLTU (unsigned) */
    CHECK(test_bltu(0, 1) == 1, "bltu: 0 < 1 taken");
    CHECK(test_bltu((unsigned long)-1, 0) == 0, "bltu: MAX < 0 not taken");

    /* BGEU (unsigned) */
    CHECK(test_bgeu((unsigned long)-1, 0) == 1, "bgeu: MAX >= 0 taken");
    CHECK(test_bgeu(0, 1) == 0, "bgeu: 0 >= 1 not taken");

    /* JAL: test that ra gets correct return address */
    {
        long ra_val, next_pc;
        asm volatile(
            "jal %0, 1f\n"
            "1: auipc %1, 0\n"
            : "=r"(ra_val), "=r"(next_pc)
        );
        CHECK(ra_val == next_pc, "jal stores correct return address");
    }

    /* JALR */
    {
        long target, ra_val, pc_after;
        asm volatile(
            "la %0, 1f\n\t"
            "jalr %1, %0, 0\n"
            "1: auipc %2, 0\n"
            : "=r"(target), "=r"(ra_val), "=r"(pc_after)
        );
        CHECK(ra_val == pc_after, "jalr stores correct return address");
    }

    printf("rv_branch: %d passed, %d failed\n", pass, fail);
    return fail ? EXIT_FAILURE : EXIT_SUCCESS;
}
