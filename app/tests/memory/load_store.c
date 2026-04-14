/* load_store.c: Test load/store of various widths and sign-extension */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); fail++; } \
    else { pass++; } \
} while (0)

static volatile uint8_t buf[64] __attribute__((aligned(16)));

int main(void) {
    int pass = 0, fail = 0;

    /* ---- Byte load/store (lb/lbu/sb) ---- */
    {
        uint8_t v = 0xAB;
        long loaded;
        asm volatile("sb %1, 0(%2)" : : "m"(buf[0]), "r"(v), "r"(&buf[0]));
        asm volatile("lbu %0, 0(%1)" : "=r"(loaded) : "r"(&buf[0]));
        CHECK(loaded == 0xAB, "sb/lbu: 0xAB roundtrip");

        asm volatile("lb %0, 0(%1)" : "=r"(loaded) : "r"(&buf[0]));
        CHECK(loaded == (long)(int8_t)0xAB, "lb: 0xAB sign-extends to negative");
    }

    /* ---- Halfword load/store (lh/lhu/sh) ---- */
    {
        uint16_t v = 0x8234;
        long loaded;
        asm volatile("sh %1, 0(%2)" : : "m"(buf[0]), "r"(v), "r"(&buf[0]));
        asm volatile("lhu %0, 0(%1)" : "=r"(loaded) : "r"(&buf[0]));
        CHECK(loaded == 0x8234, "sh/lhu: 0x8234 roundtrip");

        asm volatile("lh %0, 0(%1)" : "=r"(loaded) : "r"(&buf[0]));
        CHECK(loaded == (long)(int16_t)0x8234, "lh: 0x8234 sign-extends to negative");
    }

    /* ---- Word load/store (lw/lwu/sw) ---- */
    {
        uint32_t v = 0x80000001;
        long loaded;
        asm volatile("sw %1, 0(%2)" : : "m"(buf[0]), "r"(v), "r"(&buf[0]));
        asm volatile("lw %0, 0(%1)" : "=r"(loaded) : "r"(&buf[0]));
#if __riscv_xlen == 32
        CHECK((uint32_t)loaded == 0x80000001, "sw/lw: 0x80000001 roundtrip");
#else
        CHECK(loaded == (long)(int32_t)0x80000001, "lw: sign-extends on RV64");
        unsigned long uloaded;
        asm volatile("lwu %0, 0(%1)" : "=r"(uloaded) : "r"(&buf[0]));
        CHECK(uloaded == 0x80000001UL, "lwu: zero-extends on RV64");
#endif
    }

#if __riscv_xlen == 64
    /* ---- Doubleword load/store (ld/sd) ---- */
    {
        uint64_t v = 0xDEADBEEFCAFEBABEULL;
        uint64_t loaded;
        asm volatile("sd %1, 0(%2)" : : "m"(buf[0]), "r"(v), "r"(&buf[0]));
        asm volatile("ld %0, 0(%1)" : "=r"(loaded) : "r"(&buf[0]));
        CHECK(loaded == v, "sd/ld: 64-bit roundtrip");
    }
#endif

    /* ---- Offset addressing ---- */
    {
        memset((void *)buf, 0, sizeof(buf));
        long val = 0x42;
        asm volatile("sb %0, 7(%1)" : : "r"(val), "r"(&buf[0]));
        long loaded;
        asm volatile("lbu %0, 7(%1)" : "=r"(loaded) : "r"(&buf[0]));
        CHECK(loaded == 0x42, "offset addressing: sb/lbu at +7");
    }

    /* ---- Adjacent stores and loads (no aliasing bugs) ---- */
    {
        uint32_t a = 0x11111111, b = 0x22222222;
        asm volatile(
            "sw %0, 0(%2)\n\t"
            "sw %1, 4(%2)\n\t"
            : : "r"(a), "r"(b), "r"(&buf[0]) : "memory"
        );
        uint32_t la, lb;
        memcpy(&la, (void *)&buf[0], 4);
        memcpy(&lb, (void *)&buf[4], 4);
        CHECK(la == 0x11111111, "adjacent store: word 0");
        CHECK(lb == 0x22222222, "adjacent store: word 1");
    }

    /* ---- Store-to-load forwarding pattern ---- */
    {
        long v = 0x12345678, loaded;
        asm volatile(
            "sw %1, 0(%2)\n\t"
            "lw %0, 0(%2)\n\t"
            : "=r"(loaded) : "r"(v), "r"(&buf[0]) : "memory"
        );
#if __riscv_xlen == 32
        CHECK(loaded == 0x12345678, "store-to-load forwarding: sw then lw");
#else
        CHECK(loaded == (long)(int32_t)0x12345678, "store-to-load forwarding: sw then lw (RV64)");
#endif
    }

    /* ---- Memory fence ---- */
    {
        buf[0] = 0;
        long v = 0xAA, loaded;
        asm volatile(
            "sb %1, 0(%2)\n\t"
            "fence rw, rw\n\t"
            "lbu %0, 0(%2)\n\t"
            : "=r"(loaded) : "r"(v), "r"(&buf[0]) : "memory"
        );
        CHECK(loaded == 0xAA, "fence between store and load");
    }

    printf("load_store: %d passed, %d failed\n", pass, fail);
    return fail ? EXIT_FAILURE : EXIT_SUCCESS;
}
