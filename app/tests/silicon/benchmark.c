#include <stdint.h>

/* Deterministic integer kernel for the 8 KiB board, with a checked result. */
int main(void) {
  uint32_t value = 0x52415054;
  uint32_t start, stop;
  asm volatile("csrr %0, mcycle" : "=r"(start));
  for (unsigned i = 0; i < 1024; ++i) {
    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
  }
  asm volatile("csrr %0, mcycle" : "=r"(stop));
  volatile uint32_t *result = (void *)0x0f001f00;
  result[5] = value;
  result[6] = stop - start;
  return value != 0xf620d345;
}
