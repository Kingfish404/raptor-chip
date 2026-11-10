// AM cpu-tests use the public finisher instead of the simulator-only EBREAK tap.
#include <am.h>
#include <stdint.h>
extern char _heap_start;
Area heap = {(void *)&_heap_start, (void *)0x8007f000};
void putch(char ch) { *(volatile uint8_t *)0x10000000 = ch; }
void halt(int code) {
  uint32_t value = code ? ((uint32_t)code << 16) | 0x3333 : 0x5555;
  asm volatile("fence iorw, iorw" ::: "memory");
  *(volatile uint32_t *)0x00100000 = value;
  asm volatile("fence iorw, iorw" ::: "memory");
  for (;;) asm volatile("wfi");
}
int main(void);
void _trm_init(void) { halt(main()); }
