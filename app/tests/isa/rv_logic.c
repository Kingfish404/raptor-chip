/* rv_logic.c: Test AND/OR/XOR/ANDI/ORI/XORI and LUI/AUIPC */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); fail++; } \
    else { pass++; } \
} while (0)

int main(void) {
    int pass = 0, fail = 0;

    /* and */
    {
        long a = 0xFF00, b = 0x0FF0, c;
        asm volatile("and %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 0x0F00, "0xFF00 & 0x0FF0 = 0x0F00");
    }

    /* andi */
    {
        long a = 0xABCD, c;
        asm volatile("andi %0, %1, 0xF" : "=r"(c) : "r"(a));
        CHECK((c & 0xF) == 0xD, "0xABCD & 0xF = 0xD");
    }

    /* or */
    {
        long a = 0xF000, b = 0x000F, c;
        asm volatile("or %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 0xF00F, "0xF000 | 0x000F = 0xF00F");
    }

    /* ori */
    {
        long a = 0, c;
        asm volatile("ori %0, %1, 0x7FF" : "=r"(c) : "r"(a));
        CHECK(c == 0x7FF, "0 | 0x7FF = 0x7FF");
    }

    /* xor */
    {
        long a = 0xFF, b = 0xFF, c;
        asm volatile("xor %0, %1, %2" : "=r"(c) : "r"(a), "r"(b));
        CHECK(c == 0, "0xFF ^ 0xFF = 0");
    }

    /* xori */
    {
        long a = 0xAA, c;
        asm volatile("xori %0, %1, 0xFF" : "=r"(c) : "r"(a));
        CHECK((c & 0xFF) == 0x55, "0xAA ^ 0xFF = 0x55");
    }

    /* xor self = 0 (common idiom) */
    {
        long a = 0x12345678, c;
        asm volatile("xor %0, %1, %1" : "=r"(c) : "r"(a));
        CHECK(c == 0, "x ^ x = 0");
    }

    /* lui */
    {
        long c;
        asm volatile("lui %0, 0x12345" : "=r"(c));
#if __riscv_xlen == 32
        CHECK(c == (long)0x12345000, "lui 0x12345");
#else
        CHECK(c == 0x12345000L, "lui 0x12345");
#endif
    }

    /* auipc: verify it references PC */
    {
        long pc1, pc2;
        asm volatile(
            "auipc %0, 0\n\t"
            "auipc %1, 0\n\t"
            : "=r"(pc1), "=r"(pc2)
        );
        CHECK(pc2 == pc1 + 4, "auipc sequential PCs differ by 4");
    }

    /* not (pseudo: xori rd, rs, -1) */
    {
        long a = 0, c;
        asm volatile("not %0, %1" : "=r"(c) : "r"(a));
        CHECK(c == -1, "not 0 = -1");
    }

    printf("rv_logic: %d passed, %d failed\n", pass, fail);
    return fail ? EXIT_FAILURE : EXIT_SUCCESS;
}
