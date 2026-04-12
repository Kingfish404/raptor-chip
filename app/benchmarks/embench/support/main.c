/* ============================================================================
 * main.c — Embench-IoT main wrapper for bare-metal RISC-V on NPC
 *
 * Replaces embench-iot/support/main.c with NPC board support.
 * ============================================================================ */

#include "support.h"

int __attribute__((used))
main(int argc __attribute__((unused)),
     char *argv[] __attribute__((unused)))
{
  int i;
  volatile int result;
  int correct;

  initialise_board();
  initialise_benchmark();
  warm_caches(WARMUP_HEAT);

  start_trigger();
  result = benchmark();
  stop_trigger();

  correct = verify_benchmark(result);

  return (!correct);
}
