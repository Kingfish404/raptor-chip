/* ============================================================================
 * main.c: Embench-IoT entry point for Raptor LiteX SoC (freestanding)
 *
 * Mirrors embench-iot/support/main.c but uses our freestanding print path.
 * Verdict is printed so the log parser can classify PASS/FAIL.
 * ============================================================================ */

#include "support.h"

extern int printf(const char *fmt, ...);

/* Sentinel halt: spin at the end so run-embench.sh exits via SIM_TIMEOUT
 * (same convention as the coremark port — no CSR-finisher on LiteX sim). */
static __attribute__((noreturn)) void hang(void)
{
    for (;;)
    {
        __asm__ volatile("nop");
    }
}

int __attribute__((used))
main(int argc __attribute__((unused)),
     char *argv[] __attribute__((unused)))
{
    volatile int result;
    int correct;

    initialise_board();
    initialise_benchmark();
    warm_caches(WARMUP_HEAT);

    start_trigger();
    result = benchmark();
    stop_trigger();

    correct = verify_benchmark(result);

    printf("Result: %s\n", correct ? "PASS" : "FAIL");
    printf("--- done ---\n");
    hang();
    return 0;
}
