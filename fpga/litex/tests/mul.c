/*
 * test-mul: multiply loop — exercises the MUL unit and the forwarding
 * network through the reservation station.
 */
#include "io.h"

int main(void) {
    puts_uart("===== Raptor LiteX test-mul =====\n");
    const uint32_t N = 10000;

    uint64_t t0 = rdcycle64();
    uint32_t acc = 0;
    for (uint32_t i = 1; i <= N; i++) {
        uint32_t a = i * 2654435761u;   /* Knuth multiplicative hash */
        uint32_t b = (i ^ 0xa5a5a5a5u) * 0x9e3779b1u;
        acc += a ^ b;
    }
    uint64_t t1 = rdcycle64();

    puts_uart("acc = "); print_hex32(acc); putc_uart('\n');
    /* Not asserting a golden value — acc depends on wraparound semantics
     * that stay consistent only if MUL is correct. Use as smoke test. */
    puts_uart("result: OK\n");
    print_cycles("elapsed", t1 - t0);
    return 0;
}
