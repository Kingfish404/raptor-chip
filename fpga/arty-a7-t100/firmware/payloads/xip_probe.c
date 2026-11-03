#include "board.h"

int main(void) {
  const volatile uint32_t *header = (const volatile uint32_t *)0x30006000u;
  if (header[0] != 0x52505446u || header[1] != 32) return 1;
  uint32_t (*flash_function)(uint32_t) = (void *)0x30006010u;
  for (uint32_t argument = 0; argument < 5; argument++)
    if (flash_function(argument) != argument + 136) return 2;
  console("flash XIP: PASS\n");
  return 0;
}
