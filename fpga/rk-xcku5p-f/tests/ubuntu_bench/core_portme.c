#include "coremark.h"
#include "profile.h"

volatile ee_s32 seed1_volatile = 0;
volatile ee_s32 seed2_volatile = 0;
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;
ee_u32 default_num_contexts = 1;

void portable_init(core_portable *p, int *argc, char *argv[])
{
    p->portable_id = 1;
    if (*argc > 1) {
        long iterations = strtol(argv[1], NULL, 10);
        if (iterations < 1 || iterations > 1000000) {
            fputs("iterations must be between 1 and 1000000\n", stderr);
            exit(2);
        }
        seed4_volatile = iterations;
    }
    profile_init("coremark");
    puts("Native KU5P Ubuntu/glibc; CLOCK_MONOTONIC; single process");
}

void start_time(void) { profile_begin(); }
void stop_time(void) { profile_end(); }
CORE_TICKS get_time(void) { return profile_elapsed_ns(); }
secs_ret time_in_secs(CORE_TICKS ticks) { return (secs_ret)ticks / 1000000000.0; }
void portable_fini(core_portable *p)
{
    p->portable_id = 0;
    profile_report();
}
