/*
 * test-hello: sanity check — print a banner and return.
 * If this doesn't print, the CPU, L1I fill, or UART MMIO path is broken.
 */
#include "io.h"

int main(void) {
    puts_uart("===== Raptor LiteX test-hello =====\n");
    puts_uart("Hello from Raptor LiteX SoC!\n");

    uint64_t t0 = rdcycle64();
    /* Burn a little work so the cycle counter is visibly non-zero. */
    volatile uint32_t acc = 0;
    for (uint32_t i = 0; i < 10000; i++) acc += i;
    uint64_t t1 = rdcycle64();

    puts_uart("sum(0..9999) = "); print_udec(acc); putc_uart('\n');
    print_cycles("elapsed", t1 - t0);
    return 0;
}
