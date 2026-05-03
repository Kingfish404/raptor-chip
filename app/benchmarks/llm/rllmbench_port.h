#ifndef RLLMBENCH_PORT_H
#define RLLMBENCH_PORT_H

#include <stdint.h>

#if defined(RLLMBENCH_NATIVE)
#include <sys/time.h>
#include <time.h>
#endif

typedef uint64_t rllmbench_time_us_t;

#ifndef RLLMBENCH_TIMEBASE_HZ
#define RLLMBENCH_TIMEBASE_HZ 1000000ULL
#endif

static inline rllmbench_time_us_t rllmbench_get_time_us(void)
{
#if defined(RLLMBENCH_READ_TIME_US)
    return (rllmbench_time_us_t)RLLMBENCH_READ_TIME_US();
#elif defined(RLLMBENCH_NATIVE)
#if defined(CLOCK_MONOTONIC)
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0)
    {
        return (rllmbench_time_us_t)ts.tv_sec * 1000000ULL + (rllmbench_time_us_t)(ts.tv_nsec / 1000ULL);
    }
#endif
    struct timeval tv;
    gettimeofday(&tv, 0);
    return (rllmbench_time_us_t)tv.tv_sec * 1000000ULL + (rllmbench_time_us_t)tv.tv_usec;
#elif defined(__riscv)
#if __riscv_xlen == 64
    rllmbench_time_us_t value;
    __asm__ volatile("rdtime %0" : "=r"(value));
#else
    uint32_t hi0, lo, hi1;
    do
    {
        __asm__ volatile("rdtimeh %0" : "=r"(hi0));
        __asm__ volatile("rdtime %0" : "=r"(lo));
        __asm__ volatile("rdtimeh %0" : "=r"(hi1));
    } while (hi0 != hi1);
    rllmbench_time_us_t value = ((rllmbench_time_us_t)hi1 << 32) | lo;
#endif
#if RLLMBENCH_TIMEBASE_HZ == 1000000ULL
    return value;
#elif defined(__SIZEOF_INT128__)
    return (rllmbench_time_us_t)(((unsigned __int128)value * 1000000ULL) / RLLMBENCH_TIMEBASE_HZ);
#else
    return (value / RLLMBENCH_TIMEBASE_HZ) * 1000000ULL + ((value % RLLMBENCH_TIMEBASE_HZ) * 1000000ULL) / RLLMBENCH_TIMEBASE_HZ;
#endif
#else
    return 0;
#endif
}

#endif