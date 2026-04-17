/*
 * test-fib: iterative fib(N) to exercise ALU + branch predictor.
 * Uses u64 to avoid overflow; N chosen so sim finishes in a few seconds.
 */
#include "io.h"

static uint64_t fib(uint32_t n) {
    uint64_t a = 0, b = 1;
    for (uint32_t i = 0; i < n; i++) {
        uint64_t t = a + b;
        a = b;
        b = t;
    }
    return a;
}

int main(void) {
    puts_uart("===== Raptor LiteX test-fib =====\n");
    const uint32_t N = 40;

    uint64_t t0 = rdcycle64();
    uint64_t r  = fib(N);
    uint64_t t1 = rdcycle64();

    puts_uart("fib(");  print_udec(N); puts_uart(") = ");
    print_udec(r); putc_uart('\n');
    /* Expected: fib(40) = 102334155 */
    puts_uart(r == 102334155ull ? "result: OK\n" : "result: FAIL\n");
    print_cycles("elapsed", t1 - t0);
    return 0;
}
