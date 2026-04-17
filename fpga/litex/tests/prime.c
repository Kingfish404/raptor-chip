/*
 * test-prime: count primes < N with trial division.
 * Exercises div/mod path + branch predictor on small hot loops.
 */
#include "io.h"

static int is_prime(uint32_t n) {
    if (n < 2) return 0;
    if ((n & 1) == 0) return n == 2;
    for (uint32_t i = 3; i * i <= n; i += 2) {
        if (n % i == 0) return 0;
    }
    return 1;
}

int main(void) {
    puts_uart("===== Raptor LiteX test-prime =====\n");
    const uint32_t N = 2000;

    uint64_t t0 = rdcycle64();
    uint32_t count = 0;
    for (uint32_t i = 2; i < N; i++)
        if (is_prime(i)) count++;
    uint64_t t1 = rdcycle64();

    puts_uart("primes < "); print_udec(N);
    puts_uart(" = ");       print_udec(count); putc_uart('\n');
    /* Expected: 303 primes below 2000. */
    puts_uart(count == 303 ? "result: OK\n" : "result: FAIL\n");
    print_cycles("elapsed", t1 - t0);
    return 0;
}
