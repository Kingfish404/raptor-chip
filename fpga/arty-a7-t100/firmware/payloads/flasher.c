#include "board.h"

int main(void) {
  const volatile uint32_t *request = (const volatile uint32_t *)REQUEST;
  uint32_t operation = request[1];
  uint32_t offset = request[2];
  uint32_t length = request[3];
  uint32_t buffer = request[4];
  if (request[0] != REQUEST_MAGIC || operation < 1 || operation > 2) return 1;
  if (offset < FLASH_FIRST || offset >= FLASH_END || length == 0
      || length > FLASH_END - offset) return 2;
  if (flash_wait() || REG32(FLASH_CTRL + 8) != 0x002c5b19u) return 3;
  if (operation == 1) {
    if ((offset & 4095) || (length & 4095)) return 4;
    for (uint32_t i = 0; i < length; i += 4096) {
      REG32(FLASH_CTRL + 0x0c) = offset + i;
      REG32(FLASH_CTRL + 0x14) = 0x52410001u;
      if (flash_wait()) return 5;
    }
  } else {
    if ((offset & 3) || (length & 3) || buffer < 0x80020000u
        || buffer >= 0x8003e000u || length > 0x8003e000u - buffer) return 6;
    const volatile uint32_t *source = (const volatile uint32_t *)buffer;
    REG32(FLASH_CTRL + 0x10) = 4;
    for (uint32_t i = 0; i < length; i += 4) {
      uint32_t word = source[i / 4];
      REG32(FLASH_CTRL + 0x0c) = offset + i;
      REG32(FLASH_CTRL + 0x1c) = word;
      REG32(FLASH_CTRL + 0x14) = 0x52410002u;
      if (flash_wait()) return 7;
      // Read through the uncached device interface after every word. Reusing
      // a cached CPU flash-window line could conceal a programming failure.
      REG32(FLASH_CTRL + 0x14) = 0x52410005u;
      if (flash_wait() || REG32(FLASH_CTRL + 0x1c) != word) return 8;
    }
  }
  console("firmware flasher: PASS\n");
  return 0;
}
