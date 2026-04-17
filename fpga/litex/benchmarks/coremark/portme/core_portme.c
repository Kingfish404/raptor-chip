/* ============================================================================
 * core_portme.c: CoreMark port implementation for Raptor LiteX SoC
 *
 * Freestanding — no libc dependency.
 * ============================================================================ */

#include "coremark.h"

/* ---- Seed values (PERFORMANCE_RUN) ---- */
#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif

volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

ee_u32 default_num_contexts = 1;

/* ---- Timing ---- */
static CORETIMETYPE start_time_val, stop_time_val;

void start_time(void)
{
    GETMYTIME(&start_time_val);
}

void stop_time(void)
{
    GETMYTIME(&stop_time_val);
}

CORE_TICKS get_time(void)
{
    CORE_TICKS elapsed = (CORE_TICKS)MYTIMEDIFF(stop_time_val, start_time_val);
    return elapsed;
}

secs_ret time_in_secs(CORE_TICKS ticks)
{
    secs_ret retval = ((secs_ret)ticks) / (secs_ret)EE_TICKS_PER_SEC;
    return retval;
}

/* ---- Portable init/fini ---- */
void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)p;
    (void)argc;
    (void)argv;

    ee_printf("CoreMark: Raptor LiteX SoC (rv%d)\n",
              (int)(sizeof(void *) * 8));
    ee_printf("Iterations: %d\n", ITERATIONS);
}

void portable_fini(core_portable *p)
{
    (void)p;
    ee_printf("CoreMark: done.\n");
}
