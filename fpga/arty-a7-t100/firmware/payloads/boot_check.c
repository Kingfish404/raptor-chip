#include "board.h"

// Independent of the adapted AM runtime: exercise RAM, console and the finisher.
int main(void) {
  volatile uint32_t *scratch = (volatile uint32_t *)0x80001000u;
  scratch[0] = 0x13579bdfu;
  scratch[1] = ~scratch[0];
  if ((scratch[0] ^ scratch[1]) != 0xffffffffu) return 1;
  console("BOOT_CHECK_PASS\n");
  return 0;
}
