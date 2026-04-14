/* crc32.c: CRC-32 computation — exercises table lookup, XOR, shifts */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); fail++; } \
    else { pass++; } \
} while (0)

static uint32_t crc_table[256];

static void crc32_init(void) {
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t crc = i;
        for (int j = 0; j < 8; j++)
            crc = (crc >> 1) ^ ((crc & 1) ? 0xEDB88320u : 0);
        crc_table[i] = crc;
    }
}

static uint32_t crc32(const void *data, size_t len) {
    const uint8_t *p = (const uint8_t *)data;
    uint32_t crc = 0xFFFFFFFF;
    for (size_t i = 0; i < len; i++)
        crc = crc_table[(crc ^ p[i]) & 0xFF] ^ (crc >> 8);
    return crc ^ 0xFFFFFFFF;
}

int main(void) {
    int pass = 0, fail = 0;

    crc32_init();

    /* Known CRC-32 values (IEEE 802.3 polynomial) */
    {
        const char *s = "";
        CHECK(crc32(s, 0) == 0x00000000, "crc32 of empty string");
    }
    {
        const char *s = "123456789";
        uint32_t c = crc32(s, 9);
        CHECK(c == 0xCBF43926, "crc32(\"123456789\") = 0xCBF43926");
    }
    {
        const char *s = "The quick brown fox jumps over the lazy dog";
        uint32_t c = crc32(s, strlen(s));
        CHECK(c == 0x414FA339, "crc32 of quick brown fox");
    }
    {
        /* Single byte */
        uint8_t b = 0xFF;
        uint32_t c = crc32(&b, 1);
        CHECK(c == 0xFF000000, "crc32 of 0xFF");
    }
    {
        /* All zeros */
        uint8_t z[16] = {0};
        uint32_t c = crc32(z, 16);
        CHECK(c == 0xECBB4B55, "crc32 of 16 zero bytes");
    }
    {
        /* Incremental consistency: crc(a+b) should be deterministic */
        uint8_t data[256];
        for (int i = 0; i < 256; i++) data[i] = (uint8_t)i;
        uint32_t c1 = crc32(data, 256);
        uint32_t c2 = crc32(data, 256);
        CHECK(c1 == c2, "crc32 determinism");
    }

    printf("crc32: %d passed, %d failed\n", pass, fail);
    return fail ? EXIT_FAILURE : EXIT_SUCCESS;
}
