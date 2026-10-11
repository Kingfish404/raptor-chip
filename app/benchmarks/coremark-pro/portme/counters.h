#ifndef RAPTOR_CMP_COUNTERS_H
#define RAPTOR_CMP_COUNTERS_H

#include <stdint.h>

#if __riscv_xlen == 32
#define COUNTER(name, csr)                                      \
    static inline uint64_t name(void)                           \
    {                                                          \
        uint32_t hi, lo, again;                                 \
        do {                                                   \
            __asm__ volatile("csrr %0, " #csr "h" : "=r"(hi));   \
            __asm__ volatile("csrr %0, " #csr : "=r"(lo));       \
            __asm__ volatile("csrr %0, " #csr "h" : "=r"(again));\
        } while (hi != again);                                 \
        return ((uint64_t)hi << 32) | lo;                        \
    }
#else
#define COUNTER(name, csr)                                      \
    static inline uint64_t name(void)                           \
    {                                                          \
        uint64_t value;                                        \
        __asm__ volatile("csrr %0, " #csr : "=r"(value));         \
        return value;                                          \
    }
#endif
COUNTER(read_cycles, cycle)
COUNTER(read_instructions, instret)
COUNTER(read_time, time)
#undef COUNTER
#endif
