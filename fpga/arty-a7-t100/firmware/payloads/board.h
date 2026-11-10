#include <stdint.h>

#define REG32(address) (*(volatile uint32_t *)(address))
#define FLASH_CTRL 0x10002000u
#define FLASH_FIRST 0x00800000u
#define FLASH_END 0x01000000u
#define REQUEST 0x8001f000u
#define REQUEST_MAGIC 0x5241464cu

static inline void console(const char *text) {
  volatile uint8_t *uart = (volatile uint8_t *)0x10003000u;
  while (*text) {
    while (!(uart[5] & 0x20)) {}
    uart[0] = (uint8_t)*text++;
  }
}

static inline int flash_wait(void) {
  for (unsigned count = 0; count < 1000000; count++) {
    uint32_t status = REG32(FLASH_CTRL + 4);
    if (!(status & 1)) return (status & 2) ? 1 : 0;
  }
  return 1;
}
