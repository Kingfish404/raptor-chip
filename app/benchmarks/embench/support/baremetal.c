#define UART_BASE 0x10000000UL
#define RAPT_RUNTIME_HALT_PRINT_STATUS 1
#define RAPT_RUNTIME_FINISHER_BASE 0x100000UL

#include <stdint.h>

#include "../../../lib/runtime/runtime.c"

static uint64_t read_cycle(void)
{
#if __riscv_xlen == 32
    uint32_t high_before;
    uint32_t low;
    uint32_t high_after;

    do {
        __asm__ volatile("rdcycleh %0" : "=r"(high_before));
        __asm__ volatile("rdcycle %0" : "=r"(low));
        __asm__ volatile("rdcycleh %0" : "=r"(high_after));
    } while (high_before != high_after);
    return ((uint64_t)high_before << 32) | low;
#else
    uint64_t value;
    __asm__ volatile("rdcycle %0" : "=r"(value));
    return value;
#endif
}

static uint64_t start_cycle;

void initialise_board(void)
{
    printf("Embench-IoT: NPC bare metal (rv%d)\n",
           (int)(sizeof(void *) * 8));
}

void start_trigger(void)
{
    start_cycle = read_cycle();
}

void stop_trigger(void)
{
    uint64_t elapsed = read_cycle() - start_cycle;
    printf("Cycles: %llu\n", (unsigned long long)elapsed);
}