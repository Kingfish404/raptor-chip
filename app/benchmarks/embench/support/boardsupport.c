/* ============================================================================
 * boardsupport.c — Embench-IoT board support for RISC-V on NPC (via pk + newlib)
 * ============================================================================ */

#include <stdio.h>
#include <stdint.h>
#include <time.h>
#include "support.h"

static clock_t start_time_val;
static clock_t stop_time_val;

void initialise_board(void)
{
  printf("Embench-IoT: NPC pk+newlib (rv%d)\n",
         (int)(sizeof(void *) * 8));
}

void start_trigger(void)
{
  start_time_val = clock();
}

void stop_trigger(void)
{
  stop_time_val = clock();
  long elapsed = (long)(stop_time_val - start_time_val);
  printf("Ticks: %ld (CLOCKS_PER_SEC=%ld)\n", elapsed, (long)CLOCKS_PER_SEC);
}
