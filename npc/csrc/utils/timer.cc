#include <time.h>
#include <stdint.h>

uint64_t get_time()
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1e9 + (uint64_t)ts.tv_nsec;
}