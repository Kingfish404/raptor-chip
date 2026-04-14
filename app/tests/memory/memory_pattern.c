/* memory_pattern.c: Stress patterns for memory subsystem — sequential, stride, random */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); fail++; } \
    else { pass++; } \
} while (0)

#define ARRAY_SIZE  1024
static volatile uint32_t array[ARRAY_SIZE] __attribute__((aligned(64)));

/* Simple LFSR for deterministic pseudo-random */
static uint32_t lfsr_next(uint32_t v) {
    return (v >> 1) ^ (-(v & 1u) & 0xD0000001u);
}

int main(void) {
    int pass = 0, fail = 0;

    /* ---- Sequential write then read ---- */
    {
        for (int i = 0; i < ARRAY_SIZE; i++)
            array[i] = (uint32_t)((unsigned)i * 0x01010101u);
        int ok = 1;
        for (int i = 0; i < ARRAY_SIZE; i++) {
            if (array[i] != (uint32_t)((unsigned)i * 0x01010101u)) { ok = 0; break; }
        }
        CHECK(ok, "sequential write-read: 4KB");
    }

    /* ---- Stride access (cache line stride) ---- */
    {
        /* Write every 16th word (64-byte stride = typical cache line) */
        for (int i = 0; i < ARRAY_SIZE; i += 16)
            array[i] = (uint32_t)(i ^ 0xDEADBABE);
        int ok = 1;
        for (int i = 0; i < ARRAY_SIZE; i += 16) {
            if (array[i] != (uint32_t)(i ^ 0xDEADBABE)) { ok = 0; break; }
        }
        CHECK(ok, "stride access: 64-byte stride");
    }

    /* ---- Pseudo-random access pattern ---- */
    {
        /* Write with LFSR-derived indices, then verify.
         * Because multiple LFSR values can map to the same index,
         * only the LAST write to each slot survives.  Record expected
         * values in a shadow array to handle collisions correctly. */
        uint32_t expect[ARRAY_SIZE];
        for (int i = 0; i < ARRAY_SIZE; i++) expect[i] = array[i];
        uint32_t lfsr = 0xACE1u;
        for (int i = 0; i < 512; i++) {
            uint32_t idx = lfsr % ARRAY_SIZE;
            array[idx] = lfsr;
            expect[idx] = lfsr;
            lfsr = lfsr_next(lfsr);
        }
        int ok = 1;
        for (int i = 0; i < ARRAY_SIZE; i++) {
            if (array[i] != expect[i]) { ok = 0; break; }
        }
        CHECK(ok, "pseudo-random access: LFSR pattern");
    }

    /* ---- Write-after-write (WAW) to same address ---- */
    {
        for (int i = 0; i < 100; i++)
            array[0] = (uint32_t)i;
        CHECK(array[0] == 99, "WAW: last write wins");
    }

    /* ---- Alternating read-write ---- */
    {
        for (int i = 0; i < ARRAY_SIZE; i++)
            array[i] = (uint32_t)i;
        int ok = 1;
        for (int i = 0; i < ARRAY_SIZE; i++) {
            uint32_t v = array[i];
            array[i] = v + 1;
            if (array[i] != (uint32_t)(i + 1)) { ok = 0; break; }
        }
        CHECK(ok, "alternating read-modify-write");
    }

    /* ---- memset / memcpy validation ---- */
    {
        memset((void *)array, 0xA5, sizeof(array));
        int ok = 1;
        uint8_t *p = (uint8_t *)array;
        for (size_t i = 0; i < sizeof(array); i++) {
            if (p[i] != 0xA5) { ok = 0; break; }
        }
        CHECK(ok, "memset: fill with 0xA5");
    }
    {
        uint32_t src[64], dst[64];
        for (int i = 0; i < 64; i++) src[i] = (uint32_t)(i * 7 + 3);
        memcpy(dst, src, sizeof(src));
        int ok = memcmp(src, dst, sizeof(src)) == 0;
        CHECK(ok, "memcpy: 256-byte copy correctness");
    }

    /* ---- Byte-granularity store/load mix ---- */
    {
        uint8_t bytes[16];
        for (int i = 0; i < 16; i++)
            bytes[i] = (uint8_t)(i * 17);
        int ok = 1;
        for (int i = 0; i < 16; i++) {
            if (bytes[i] != (uint8_t)(i * 17)) { ok = 0; break; }
        }
        CHECK(ok, "byte-granularity store/load");
    }

    printf("memory_pattern: %d passed, %d failed\n", pass, fail);
    return fail ? EXIT_FAILURE : EXIT_SUCCESS;
}
