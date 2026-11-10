/* Same AM TRM/klib interface as the existing bringup programs; local UART and
 * RAM. */
#include <am.h>
#include <klib.h>

#ifndef CORE_CLOCK_HZ
#define CORE_CLOCK_HZ 10000000
#endif

extern char _heap_start;
Area heap = {&_heap_start, (void *)0x0f001600};
static volatile uint8_t *const uart = (void *)0x10000100;
static volatile uint32_t *const result = (void *)0x0f001f00;

void putch(char ch) {
  while (!(uart[5] & 0x20)) {
  }
  uart[0] = ch;
}

void putstr(const char *text) {
  for (size_t i = 0; i < strlen(text); ++i)
    putch(text[i]);
}

void halt(int code) {
  putstr("RAPTOR " PROGRAM_NAME);
  putstr(code ? " FAIL\n" : " PASS\n");
  while (!(uart[5] & 0x40)) {
  }
  uint32_t hi, lo, again;
  do {
    asm volatile("csrr %0, mcycleh" : "=r"(hi));
    asm volatile("csrr %0, mcycle" : "=r"(lo));
    asm volatile("csrr %0, mcycleh" : "=r"(again));
  } while (hi != again);
  result[2] = code;
  result[3] = lo;
  result[4] = hi;
  asm volatile("fence iorw, iorw" ::: "memory");
  result[1] = 0x53494c32;
  for (;;)
    asm volatile("wfi");
}

int main(void);
void _trm_init(void) {
  const unsigned divisor = (CORE_CLOCK_HZ + 8 * 57600) / (16 * 57600);
  uart[3] = 0x83;
  uart[0] = divisor;
  uart[1] = divisor >> 8;
  uart[3] = 3;
  uart[2] = 7;
  result[0] = 0x53494c31;
  result[1] = 0;
  halt(main());
}
