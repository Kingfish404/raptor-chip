#ifndef RAPTOR_UBUNTU_BENCH_PROFILE_H
#define RAPTOR_UBUNTU_BENCH_PROFILE_H
#include <stdint.h>
void profile_init(const char *name);
void profile_begin(void);
void profile_end(void);
void profile_report(void);
uint64_t profile_elapsed_ns(void);
#endif
