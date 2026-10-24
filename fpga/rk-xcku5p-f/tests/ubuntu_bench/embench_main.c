#include "support.h"
#include "profile.h"
#include <stdio.h>
#include <stdlib.h>

#ifndef BENCH_NAME
#define BENCH_NAME "unknown"
#endif

int main(int argc, char **argv)
{
    long repeats = argc > 1 ? strtol(argv[1], NULL, 10) : 1;
    if (repeats < 1 || repeats > 10000)
        return 2;
    profile_init(BENCH_NAME);
    initialise_benchmark();
    warm_caches(1);
    volatile int result = 0;
    profile_begin();
    for (long i = 0; i < repeats; i++)
        result = benchmark();
    profile_end();
    int correct = verify_benchmark(result);
    profile_report();
    printf("EMBENCH_VERIFY name=%s repeats=%ld result=%d verified=%d\n",
           BENCH_NAME, repeats, result, correct);
    return correct == 1 ? 0 : 1;
}
