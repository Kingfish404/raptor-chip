#include <am.h>
#include <klib.h>
#include <klib-macros.h>
#include <stdint.h>

static volatile uint32_t initialized = 0x1234abcd;
static volatile uint32_t zeroed[33];

int main(const char *args) {
  ioe_init();
  uint64_t start_us = io_read(AM_TIMER_UPTIME).us;
  if (initialized != 0x1234abcd) return 1;
  for (int i = 0; i < 33; i++) if (zeroed[i] != 0) return 2;
  const uintptr_t regions[] = {0x0f000000, 0x80000000, 0xa1000000};
  for (int region = 0; region < 3; region++) {
    volatile uint32_t *words = (volatile uint32_t *)regions[region];
    for (unsigned i = 0; i < 128; i++) words[i] = 0x13579bdf ^ (i * 0x10203);
    asm volatile("fence" ::: "memory");
    for (unsigned i = 0; i < 128; i++)
      if (words[i] != (0x13579bdf ^ (i * 0x10203))) return 3 + region;
    volatile uint8_t *bytes = (volatile uint8_t *)words;
    for (unsigned i = 0; i < 4; i++) bytes[i] = 0x31 + i;
    asm volatile("fence" ::: "memory");
    if (words[0] != 0x34333231) return 6 + region;
  }
  uint64_t end_us = io_read(AM_TIMER_UPTIME).us;
  printf("timer us: %u -> %u\n", (unsigned)start_us, (unsigned)end_us);
  if (end_us <= start_us) return 9;
  printf("ysyxSoC memory smoke PASS\n");
  // The failure variant verifies that the simulator reads the real nested a0
  // and propagates a non-zero halt status through both adapter layers.
  return args[0] == 'f' ? 7 : 0;
}
