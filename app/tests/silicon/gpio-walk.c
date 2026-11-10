#include <stdint.h>

int main(void) {
  volatile uint32_t *gpio = (void *)0x10000200;
  gpio[2] = 0;
  gpio[3] = 0;
  gpio[1] = 0;
  gpio[2] = 7;
  int failed = 0;
  for (unsigned pattern = 1; pattern <= 4; pattern <<= 1) {
    gpio[1] = pattern;
    for (volatile unsigned wait = 0; wait < 32; ++wait) {
    }
    if ((gpio[0] & 7) != pattern)
      failed = 1;
  }
  gpio[2] = 0;
  gpio[1] = 0;
  gpio[3] = 7;
  return failed;
}
