/*
 * test-memcpy: copy a buffer byte-by-byte + verify.
 * Exercises L1D fill/evict + store-buffer throughput.
 */
#include "io.h"

#define BUF_WORDS  (4096)   /* 16 KiB each buffer -> 32 KiB live set */

static uint32_t src[BUF_WORDS];
static uint32_t dst[BUF_WORDS];

int main(void) {
    puts_uart("===== Raptor LiteX test-memcpy =====\n");

    /* Fill source with a deterministic pattern. */
    for (uint32_t i = 0; i < BUF_WORDS; i++)
        src[i] = 0xdeadbe00u ^ i;

    uint64_t t0 = rdcycle64();
    for (uint32_t i = 0; i < BUF_WORDS; i++)
        dst[i] = src[i];
    uint64_t t1 = rdcycle64();

    /* Verify by XOR-folding both buffers; they must match. */
    uint32_t xs = 0, xd = 0;
    for (uint32_t i = 0; i < BUF_WORDS; i++) {
        xs ^= src[i];
        xd ^= dst[i];
    }
    puts_uart("src xor = "); print_hex32(xs); putc_uart('\n');
    puts_uart("dst xor = "); print_hex32(xd); putc_uart('\n');
    puts_uart(xs == xd ? "result: OK\n" : "result: FAIL\n");

    puts_uart("bytes  = "); print_udec((uint64_t)BUF_WORDS * 4); putc_uart('\n');
    print_cycles("elapsed", t1 - t0);
    return 0;
}
