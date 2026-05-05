#ifndef RAGENTBENCH_PORT_H
#define RAGENTBENCH_PORT_H

#include <stdint.h>

#if defined(RAGENTBENCH_NATIVE)
#include <sys/time.h>
#include <time.h>
#endif

typedef uint64_t ragentbench_time_us_t;

#ifndef RAGENTBENCH_TIMEBASE_HZ
#define RAGENTBENCH_TIMEBASE_HZ 1000000ULL
#endif

static inline ragentbench_time_us_t ragentbench_get_time_us(void)
{
#if defined(RAGENTBENCH_READ_TIME_US)
    return (ragentbench_time_us_t)RAGENTBENCH_READ_TIME_US();
#elif defined(RAGENTBENCH_NATIVE)
#if defined(CLOCK_MONOTONIC)
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0)
    {
        return (ragentbench_time_us_t)ts.tv_sec * 1000000ULL + (ragentbench_time_us_t)(ts.tv_nsec / 1000ULL);
    }
#endif
    struct timeval tv;
    gettimeofday(&tv, 0);
    return (ragentbench_time_us_t)tv.tv_sec * 1000000ULL + (ragentbench_time_us_t)tv.tv_usec;
#elif defined(__riscv)
#if __riscv_xlen == 64
    ragentbench_time_us_t value;
    __asm__ volatile("rdtime %0" : "=r"(value));
#else
    uint32_t hi0, lo, hi1;
    do
    {
        __asm__ volatile("rdtimeh %0" : "=r"(hi0));
        __asm__ volatile("rdtime %0" : "=r"(lo));
        __asm__ volatile("rdtimeh %0" : "=r"(hi1));
    } while (hi0 != hi1);
    ragentbench_time_us_t value = ((ragentbench_time_us_t)hi1 << 32) | lo;
#endif
#if RAGENTBENCH_TIMEBASE_HZ == 1000000ULL
    return value;
#elif defined(__SIZEOF_INT128__)
    return (ragentbench_time_us_t)(((unsigned __int128)value * 1000000ULL) / RAGENTBENCH_TIMEBASE_HZ);
#else
    return (value / RAGENTBENCH_TIMEBASE_HZ) * 1000000ULL + ((value % RAGENTBENCH_TIMEBASE_HZ) * 1000000ULL) / RAGENTBENCH_TIMEBASE_HZ;
#endif
#else
    return 0;
#endif
}

#endif
