/* ============================================================================
 * boardsupport.c: Embench-IoT board support for Raptor LiteX SoC
 *
 * Freestanding — no libc dependency. Prints a machine-parseable block around
 * each benchmark so run-embench.sh can compute cycles/ticks and the
 * Embench Score vs Cortex-M4 @ 16 MHz.
 * ============================================================================ */

#include <stdint.h>
#include <stddef.h>
#include "support.h"

/* Benchmark name injected at compile time via -DBENCH_NAME="..." */
#ifndef BENCH_NAME
#define BENCH_NAME "unknown"
#endif

/* LiteX sys_clk frequency (Hz). Passed in via -DSYS_CLK_HZ=... so we can
 * convert cycles <-> wall-clock. Defaults to the Makefile's 50 MHz. */
#ifndef SYS_CLK_HZ
#define SYS_CLK_HZ 50000000UL
#endif

extern int printf(const char *fmt, ...);

/* ---- Cycle / time counters (Zicntr) ---- */
static inline uint64_t rd_cycle(void)
{
#if __riscv_xlen == 64
    uint64_t v;
    __asm__ volatile("rdcycle %0" : "=r"(v));
    return v;
#else
    uint32_t lo, hi, hi2;
    do
    {
        __asm__ volatile("rdcycleh %0" : "=r"(hi));
        __asm__ volatile("rdcycle  %0" : "=r"(lo));
        __asm__ volatile("rdcycleh %0" : "=r"(hi2));
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
#endif
}

static inline uint64_t rd_time(void)
{
#if __riscv_xlen == 64
    uint64_t v;
    __asm__ volatile("rdtime %0" : "=r"(v));
    return v;
#else
    uint32_t lo, hi, hi2;
    do
    {
        __asm__ volatile("rdtimeh %0" : "=r"(hi));
        __asm__ volatile("rdtime  %0" : "=r"(lo));
        __asm__ volatile("rdtimeh %0" : "=r"(hi2));
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
#endif
}

static uint64_t start_cycle, stop_cycle;
static uint64_t start_tick, stop_tick;

/* ---- Embench hooks ---- */
void initialise_board(void)
{
    /* Machine-parseable sentinel: run-embench.sh keys off "--- <name> ---". */
    printf("\n--- %s ---\n", BENCH_NAME);
    printf("Embench-IoT: Raptor LiteX (rv%d) sys_clk=%lu Hz\n",
           (int)(sizeof(void *) * 8),
           (unsigned long)SYS_CLK_HZ);
}

void start_trigger(void)
{
    /* Take time snapshot AFTER warm_caches() */
    start_tick = rd_time();
    start_cycle = rd_cycle();
}

void stop_trigger(void)
{
    stop_cycle = rd_cycle();
    stop_tick = rd_time();

    uint64_t dcycle = stop_cycle - start_cycle;
    uint64_t dtick = stop_tick - start_tick;

    /* Scoring uses Cycles; Ticks is reported for context only.
     * On LiteX Verilator sim, rdtime is driven by sys_clk so Ticks ~ Cycles;
     * on silicon with a proper 1 MHz CLINT, Ticks would be microseconds. */
    printf("Cycles: %lu\n", (unsigned long)dcycle);
    printf("Ticks:  %lu\n", (unsigned long)dtick);
}
