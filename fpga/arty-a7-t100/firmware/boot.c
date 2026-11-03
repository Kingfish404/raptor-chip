#include <stdint.h>

#define REG32(address) (*(volatile uint32_t *)(address))
#define RAM_BASE 0x80000000u
#define FLASH_BASE 0x30000000u
#define FLASH_CTRL 0x10002000u
#define MAX_IMAGE 0x3e000u

static void puts_uart(const char *text) {
  volatile uint8_t *uart = (volatile uint8_t *)0x10000000u;
  while (*text) {
    while (!(uart[5] & 0x20)) {}
    uart[0] = (uint8_t)*text++;
  }
}

static uint32_t crc_byte(uint32_t crc, uint8_t data) {
  crc ^= data;
  for (unsigned bit = 0; bit < 8; bit++)
    crc = (crc >> 1) ^ ((0u - (crc & 1)) & 0xedb88320u);
  return crc;
}

static void jump_ram(uint32_t entry) {
  __asm__ volatile("fence iorw, iorw\n\tfence.i" ::: "memory");
  ((void (*)(void))entry)();
  for (;;) {}
}

void board_boot(void) {
  if (REG32(FLASH_CTRL + 0x20) & 1) {
    const volatile uint32_t *header = (const volatile uint32_t *)FLASH_BASE;
    uint32_t magic = header[0];
    uint32_t length = header[1];
    uint32_t expected_crc = header[2];
    uint32_t entry = header[3];
    if (magic == 0x52505446u && length > 0 && length <= MAX_IMAGE
        && entry >= RAM_BASE && entry - RAM_BASE < length && !(entry & 1)) {
      volatile uint32_t *destination = (volatile uint32_t *)RAM_BASE;
      const volatile uint32_t *source = header + 4;
      uint32_t crc = 0xffffffffu;
      for (uint32_t offset = 0; offset < length; offset += 4) {
        uint32_t word = source[offset / 4];
        for (unsigned byte = 0; byte < 4 && offset + byte < length; byte++)
          crc = crc_byte(crc, (uint8_t)(word >> (8 * byte)));
      }
      if ((crc ^ 0xffffffffu) == expected_crc) {
        for (uint32_t offset = 0; offset < length; offset += 4)
          destination[offset / 4] = source[offset / 4];
        puts_uart("flash: CRC OK; boot RAM\n");
        jump_ram(entry);
      }
      puts_uart("flash: bad CRC; RAM fallback\n");
    } else {
      puts_uart("flash: bad header; RAM fallback\n");
    }
  }
  if (REG32(RAM_BASE) != 0 && REG32(RAM_BASE) != 0xffffffffu)
    jump_ram(RAM_BASE);
  puts_uart("RAM: waiting for UART load and reset\n");
  for (;;) {}
}
