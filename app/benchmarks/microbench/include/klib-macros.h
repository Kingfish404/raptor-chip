#ifndef RAPTOR_MICROBENCH_SE_KLIB_MACROS_H
#define RAPTOR_MICROBENCH_SE_KLIB_MACROS_H

#include <stdint.h>

#define ROUNDUP(a, sz) ((((uintptr_t)(a) + (sz) - 1) & ~((uintptr_t)(sz) - 1)))
#define LENGTH(arr) (sizeof(arr) / sizeof((arr)[0]))

#endif
